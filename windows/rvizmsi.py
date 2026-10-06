#!/usr/bin/env python3
"""rvizmsi.py - payload staging helpers for the RViz MSI build.

Runs on Windows under the build's private "tools" conda environment
(Python 3 + conda-pack + Pillow). Pure standard library except for the
optional Pillow import used by the ``assets`` sub-command.

Sub-commands
------------
version   Print the MSI ProductVersion derived from rviz/package.xml.
check-env Sanity-check the rviz build environment before compiling.
finalize  Turn a conda-pack'ed directory into the MSI payload: third-party
          notices + licenses, strip build-only packages, prune, launchers,
          required-file verification, manifest.
verify-runtime  Check that every ROS package and DLL rviz/roscore need is in
          the payload (also run automatically by finalize).
assets    Build MSI UI assets (icon .ico, license .rtf).
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import stat
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath

# Files that MUST exist in the payload or the MSI is useless.
REQUIRED_FILES = [
    "python.exe",
    "Library/bin/rviz.exe",
    "Library/bin/rviz.dll",
    "Library/bin/rospack.exe",
    "Library/bin/RenderSystem_GL.dll",
    "Library/bin/Plugin_OctreeSceneManager.dll",
    "Library/bin/Plugin_ParticleFX.dll",
    "Library/share/rviz/package.xml",
    "Library/share/rviz/plugin_description.xml",
    "Library/share/rviz/ogre_media",
    "Library/bin/rosbag",          # launchers\rosbag.cmd (bag review)
    "Library/plugins/platforms/qwindows.dll",
    # ROS environment chain run by launchers\ros_env.bat (same as RoboStack's
    # activation). catkin's setup.bat does `exit 22` - closing the launcher's
    # window without a message - if _setup_util.py is missing.
    "etc/conda/activate.d/ros-noetic-catkin_activate.bat",
    "Library/local_setup.bat",
    "Library/setup.bat",
    "Library/_setup_util.py",
]

# ROS packages that must be present (Library/share/<pkg>/package.xml) for rviz
# to run and for roscore to start a master: rviz's run dependencies from its
# package.xml plus the roscore chain.
REQUIRED_ROS_PACKAGES = [
    # rviz run dependencies
    "geometry_msgs", "image_transport", "interactive_markers", "laser_geometry",
    "map_msgs", "message_filters", "nav_msgs", "pluginlib", "python_qt_binding",
    "resource_retriever", "rosconsole", "roscpp", "roslib", "rospy",
    "sensor_msgs", "std_msgs", "std_srvs", "tf2_ros", "tf2_geometry_msgs",
    "urdf", "visualization_msgs", "media_export", "message_runtime",
    # ROS master / core tools
    "roslaunch", "rosmaster", "rosout", "rosgraph", "rosgraph_msgs",
    "rosparam", "rospack", "rostopic", "rosnode", "rosservice",
    # bag review: launchers\rosbag.cmd
    "rosbag",
]

# rosdep keys that are system libraries (provided by conda packages, not ROS
# packages). Anything else a ROS package depends on must be a ROS package.
SYSTEM_DEP_PREFIXES = ("lib", "python3-", "python-", "qt")
SYSTEM_DEPS = {
    "assimp", "assimp-dev", "boost", "bzip2", "cmake", "console_bridge", "curl",
    "eigen", "gpgme", "gtest", "graphviz", "lz4", "opengl", "openssl",
    "pkg-config", "poco", "python3", "qtbase5-dev", "sbcl", "tango-icon-theme",
    "tinyxml", "tinyxml2", "uuid", "yaml-cpp", "zlib", "google-mock", "procps",
    "hddtemp", "git", "wget", "unzip", "gnupg", "ca-certificates",
}

# Starting points of the DLL dependency closure check (globs, payload-relative).
DLL_ROOTS = [
    "python.exe", "Library/bin/rviz.exe", "Library/bin/rviz*.dll",
    "Library/bin/rospack.exe", "Library/lib/rosout/rosout.exe",
    "Library/bin/RenderSystem_GL.dll", "Library/bin/Plugin_*.dll",
    "Library/bin/Codec_*.dll", "Library/plugins/platforms/*.dll",
    "Library/plugins/imageformats/*.dll", "Library/bin/*image_transport*.dll",
    "Library/mesa/*.exe", "Library/mesa/*.dll",
]
# Directories searched for a DLL besides the importing binary's own folder,
# in the same order as the PATH set by launchers/ros_env.bat. Library/lib is
# there because some ROS packages (e.g. image_transport) install their DLLs with
# a plain `DESTINATION lib`, which on Windows puts them next to the .lib files.
DLL_SEARCH_DIRS = ["", "Library/mingw-w64/bin", "Library/usr/bin", "Library/bin",
                   "Scripts", "bin", "DLLs", "Library/lib"]

# Software OpenGL (Mesa llvmpipe, conda package mesa-llvmpipe). Windows loads
# opengl32.dll from the executable's folder before System32, so Mesa's copy must
# NOT stay next to Library\bin\rviz.exe (it would replace the GPU driver for
# every launch). finalize moves it to MESA_DIR, next to a copy of rviz.exe that
# only launchers\rviz-software.cmd starts. rviz.exe's other DLLs and the OGRE
# plugins are found through PATH; OGRE 1.10 loads plugins with the standard
# search order, so RenderSystem_GL.dll also gets Mesa's opengl32.dll.
MESA_DIR = "Library/mesa"
MESA_DLLS = ["opengl32.dll", "libgallium_wgl.dll"]
MESA_OPTIONAL_DLLS = ["libglapi.dll"]          # older Mesa builds split this out

# ROS command-line tools that get a thin launcher in <prefix>\launchers\.
# rosbag: replay bag files from the Admin Portal into RViz (bag review).
ROS_TOOLS = [
    "roscore", "roslaunch", "rostopic", "rosnode", "rosservice", "rosparam",
    "rosmsg", "rossrv", "rospack",
]


def log(msg: str) -> None:
    print(f"[rvizmsi] {msg}", flush=True)


def die(msg: str, code: int = 1) -> None:
    print(f"[rvizmsi] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def read_list(path: Path) -> list[str]:
    """Read a config list: one entry per line, '#' comments, blanks ignored."""
    out = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out


def _on_rm_error(func, path, _exc):
    # Windows: read-only files cannot be deleted until the bit is cleared.
    os.chmod(path, stat.S_IWRITE)
    func(path)


def remove_path(p: Path) -> None:
    if p.is_symlink() or p.is_file():
        try:
            p.unlink()
        except PermissionError:
            os.chmod(p, stat.S_IWRITE)
            p.unlink()
    elif p.is_dir():
        shutil.rmtree(p, onerror=_on_rm_error)


# --------------------------------------------------------------------------- #
# version
# --------------------------------------------------------------------------- #
def rviz_version(src: Path) -> str:
    root = ET.parse(src / "package.xml").getroot()
    ver = (root.findtext("version") or "").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
        die(f"unexpected rviz version in package.xml: {ver!r}")
    return ver


def msi_version(rviz_ver: str, build_number: int) -> str:
    major, minor, patch = (int(x) for x in rviz_ver.split("."))
    if not 0 <= build_number <= 99:
        die("BUILD_NUMBER must be between 0 and 99")
    field3 = patch * 100 + build_number
    if major > 255 or minor > 255 or field3 > 65535:
        die(f"version {rviz_ver}+{build_number} does not fit MSI limits")
    return f"{major}.{minor}.{field3}"


def cmd_version(a) -> None:
    v = rviz_version(Path(a.rviz_src))
    print(msi_version(v, a.build_number) if not a.raw else v)


# --------------------------------------------------------------------------- #
# conda metadata helpers
# --------------------------------------------------------------------------- #
def load_conda_meta(prefix: Path) -> dict[str, dict]:
    meta_dir = prefix / "conda-meta"
    if not meta_dir.is_dir():
        die(f"no conda-meta directory in {prefix}")
    pkgs = {}
    for f in sorted(meta_dir.glob("*.json")):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            die(f"cannot parse {f}: {exc}")
        if "name" in data:
            data["_meta_file"] = f.name
            pkgs[data["name"]] = data
    return pkgs


def dep_name(spec: str) -> str:
    return re.split(r"[\s=<>!~\[]", spec.strip(), maxsplit=1)[0]


def cmd_check_env(a) -> None:
    prefix = Path(a.prefix)
    pkgs = load_conda_meta(prefix)
    if "ros-noetic-rviz" in pkgs:
        die("ros-noetic-rviz is installed in the build environment; it would "
            "clash with the from-source build. Remove it from the package list.")
    missing = [n for n in ("python", "ros-noetic-catkin", "ogre", "qt-main")
               if n not in pkgs]
    if missing:
        die(f"build environment is missing: {', '.join(missing)}")
    log(f"environment OK: {len(pkgs)} packages, python "
        f"{pkgs['python']['version']}, ogre {pkgs['ogre']['version']}, "
        f"qt-main {pkgs['qt-main']['version']}")
    blas = pkgs.get("libblas", {}).get("build", "-")
    cv = pkgs.get("libopencv", {}).get("build", "-")
    log(f"libblas build {blas}, libopencv build {cv}, mkl {'present' if 'mkl' in pkgs else 'absent'}, "
        f"qt6-main {'present' if 'qt6-main' in pkgs else 'absent'}")


# --------------------------------------------------------------------------- #
# finalize
# --------------------------------------------------------------------------- #
def find_extracted_dir(pkg: dict, pkgs_dirs: list[Path], env_meta: dict | None = None) -> Path | None:
    # conda-pack blanks extracted_package_dir in the packed conda-meta, so also
    # look it up in the build environment's own metadata.
    for meta in (pkg, (env_meta or {}).get(pkg["name"], {})):
        cand = meta.get("extracted_package_dir")
        if cand and Path(cand).is_dir():
            return Path(cand)
    stem = f"{pkg['name']}-{pkg['version']}-{pkg.get('build', '')}"
    for d in pkgs_dirs:
        if (d / stem).is_dir():
            return d / stem
    return None


def is_robostack(pkg: dict) -> bool:
    return ("robostack" in str(pkg.get("channel", "")) or pkg["name"].startswith("ros-noetic-")
            or pkg["name"] == "ros-distro-mutex")


def collect_licenses(stage: Path, pkgs: dict, pkgs_dirs: list[Path], env_meta: dict | None = None,
                     robostack_license: Path | None = None) -> None:
    lic_root = stage / "licenses"
    lic_root.mkdir(parents=True, exist_ok=True)
    lines = [
        "THIRD-PARTY SOFTWARE NOTICES",
        "============================",
        "",
        "This installer bundles the following packages (from conda-forge and",
        "RoboStack). Full license texts, where provided by the package, are in",
        "the 'licenses' folder next to this file.",
        "",
        "RoboStack packages (ros-noetic-*) ship no license files of their own. They",
        "are covered by the RoboStack ros-noetic repository license (MIT, in",
        "licenses/RoboStack-ros-noetic, https://github.com/RoboStack/ros-noetic);",
        "the ROS source code inside them keeps the upstream license shown below.",
        "Packages marked (metapackage) install no files.",
        "",
        f"{'Package':<45} {'Version':<22} License",
        f"{'-' * 45} {'-' * 22} {'-' * 30}",
    ]
    without, robostack, meta_only = [], [], []
    if robostack_license and robostack_license.is_file():
        (lic_root / "RoboStack-ros-noetic").mkdir(parents=True, exist_ok=True)
        shutil.copy2(robostack_license, lic_root / "RoboStack-ros-noetic" / "LICENSE")
    else:
        robostack_license = None
    for name in sorted(pkgs):
        p = pkgs[name]
        note = ""
        src = find_extracted_dir(p, pkgs_dirs, env_meta)
        has_own = bool(src and ((src / "info" / "licenses").is_dir() or list((src / "info").glob("LICENSE*"))))
        if not has_own and robostack_license and is_robostack(p):
            note = "  [packaging: RoboStack, MIT]"
        elif not has_own and not p.get("files"):
            note = "  (metapackage)"
        lines.append(f"{name:<45} {p.get('version', '?'):<22} "
                     f"{p.get('license', 'UNKNOWN')}{note}")
        lic_dir = src / "info" / "licenses" if src else None
        if lic_dir and lic_dir.is_dir():
            shutil.copytree(lic_dir, lic_root / name, dirs_exist_ok=True)
        elif src and list((src / "info").glob("LICENSE*")):
            (lic_root / name).mkdir(parents=True, exist_ok=True)
            for f in (src / "info").glob("LICENSE*"):
                shutil.copy2(f, lic_root / name / f.name)
        elif note.startswith("  [packaging"):
            robostack.append(name)
        elif note:
            meta_only.append(name)
        else:
            without.append(name)
    lines += ["", "RViz itself is BSD-3-Clause licensed (see licenses/rviz)."]
    (stage / "THIRD_PARTY_NOTICES.txt").write_text(
        "\r\n".join(lines) + "\r\n", encoding="utf-8")
    own = len(pkgs) - len(without) - len(robostack) - len(meta_only)
    log(f"licenses: {own} packages with their own license files, {len(robostack)} RoboStack "
        f"packages under the RoboStack license, {len(meta_only)} metapackages, {len(without)} without")
    if without:
        log("no license files in package cache for: " + ", ".join(without[:20])
            + (" ..." if len(without) > 20 else ""))
        for d in pkgs_dirs:
            n = sum(1 for x in d.iterdir() if x.is_dir()) if d.is_dir() else 0
            log(f"  package cache {d}: {'missing' if not d.is_dir() else f'{n} extracted packages'}")


def strip_build_only(stage: Path, pkgs: dict, names: list[str]) -> set[str]:
    stripped = set()
    for name in names:
        pkg = pkgs.get(name)
        if not pkg:
            continue
        users = sorted(other for other, p in pkgs.items()
                       if other != name and other not in names
                       and any(dep_name(d) == name for d in p.get("depends", [])))
        if users:
            log(f"keeping build-only package {name}: required by {', '.join(users[:5])}")
            continue
        removed = 0
        for rel in pkg.get("files", []):
            target = stage / rel
            if target.is_file() or target.is_symlink():
                remove_path(target)
                removed += 1
        stripped.add(name)
        log(f"stripped {name} ({removed} files)")
    return stripped


def matches(rel: str, pattern: str) -> bool:
    """fnmatch with '**' meaning 'any number of path segments'."""
    rel_parts = rel.split("/")
    pat_parts = pattern.split("/")

    def rec(i: int, j: int) -> bool:
        if j == len(pat_parts):
            return i == len(rel_parts)
        if pat_parts[j] == "**":
            return any(rec(k, j + 1) for k in range(i, len(rel_parts) + 1))
        if i == len(rel_parts):
            return False
        return (fnmatch.fnmatchcase(rel_parts[i].lower(), pat_parts[j].lower())
                and rec(i + 1, j + 1))

    return rec(0, 0)


def prune(stage: Path, patterns: list[str], keep_pdb: bool) -> None:
    pats = [p.strip("/").replace("\\", "/") for p in patterns]
    if not keep_pdb:
        pats.append("**/*.pdb")
    removed = 0
    # Walk top-down so that a matched directory is removed in one go.
    for dirpath, dirnames, filenames in os.walk(stage, topdown=True):
        base = Path(dirpath)
        rel_base = base.relative_to(stage).as_posix()
        rel_base = "" if rel_base == "." else rel_base + "/"
        keep_dirs = []
        for d in dirnames:
            rel = rel_base + d
            if any(matches(rel, p) for p in pats):
                remove_path(base / d)
                removed += 1
            else:
                keep_dirs.append(d)
        dirnames[:] = keep_dirs
        for f in filenames:
            if any(matches(rel_base + f, p) for p in pats):
                remove_path(base / f)
                removed += 1
    # Drop directories left empty by stripping/pruning (MSI would create them).
    for dirpath, dirnames, filenames in os.walk(stage, topdown=False):
        p = Path(dirpath)
        if p != stage and not any(p.iterdir()):
            p.rmdir()
    log(f"pruned {removed} paths")


def verify_required(stage: Path) -> None:
    missing = [r for r in REQUIRED_FILES if not (stage / r).exists()]
    lib = stage / "Library"
    if not any((lib / "bin" / n).exists()
               for n in ("roscore", "roscore.exe", "roscore.bat", "roscore-script.py")):
        missing.append("Library/bin/roscore (any of: none/.exe/.bat/-script.py)")
    if lib.is_dir() and not any(lib.rglob("rosout.exe")):
        missing.append("rosout.exe (rosout node, needed by roscore)")
    if missing:
        die("payload is missing required files:\n  " + "\n  ".join(missing))
    log("all required runtime files present")


def isolate_mesa(stage: Path) -> None:
    """Move Mesa's OpenGL DLLs from Library/bin to MESA_DIR and put a copy of
    rviz.exe (and Qt's qt.conf, whose relative prefix stays valid one level
    below Library) next to them."""
    bin_dir, mesa = stage / "Library" / "bin", stage / MESA_DIR
    missing = [n for n in MESA_DLLS + ["rviz.exe"] if not (bin_dir / n).is_file()]
    if missing:
        die("software rendering: missing in Library/bin: " + ", ".join(missing)
            + " (is mesa-llvmpipe in config/conda-packages.txt?)")
    mesa.mkdir(parents=True, exist_ok=True)
    for name in MESA_DLLS + MESA_OPTIONAL_DLLS:
        if (bin_dir / name).is_file():
            shutil.move(str(bin_dir / name), str(mesa / name))
    for name in ("rviz.exe", "qt.conf"):
        if (bin_dir / name).is_file():
            shutil.copy2(bin_dir / name, mesa / name)
    log(f"software rendering: Mesa OpenGL + rviz.exe copy in {MESA_DIR}")


def verify_gpu_path(stage: Path) -> None:
    """The default rviz.exe must use the system's (GPU vendor's) OpenGL."""
    leftovers = [n for n in MESA_DLLS + MESA_OPTIONAL_DLLS
                 if (stage / "Library" / "bin" / n).exists()]
    if leftovers:
        die("Library/bin must not contain Mesa's " + ", ".join(leftovers)
            + ": Library/bin/rviz.exe would use software OpenGL even with a GPU")


# --------------------------------------------------------------------------- #
# ROS package dependency check
# --------------------------------------------------------------------------- #
def ros_run_deps(package_xml: Path) -> set[str]:
    """Run-time dependencies declared in a package.xml (format 1, 2 or 3)."""
    try:
        root = ET.parse(package_xml).getroot()
    except ET.ParseError:
        return set()
    tags = ("depend", "exec_depend", "run_depend", "build_export_depend")
    out = set()
    for t in tags:
        for el in root.findall(t):
            if el.attrib.get("condition", "").replace(" ", "") in ("$ROS_PYTHON_VERSION==2",):
                continue
            if el.text:
                out.add(el.text.strip())
    return out


def is_system_dep(name: str) -> bool:
    return name in SYSTEM_DEPS or name.startswith(SYSTEM_DEP_PREFIXES)


def check_ros_packages(stage: Path, conda_names: set[str] | None = None) -> list[str]:
    """Return problems: missing required ROS packages, and ROS run-dependencies
    (followed transitively from rviz and the core tools) that are absent.
    A dependency that names an installed conda package (rosdep keys such as
    apr or log4cxx map 1:1 onto conda-forge packages) counts as satisfied."""
    conda_names = conda_names or set()
    share = stage / "Library" / "share"
    installed = {p.parent.name for p in share.glob("*/package.xml")}
    problems = [f"ROS package '{p}' is not in the payload"
                for p in REQUIRED_ROS_PACKAGES if p not in installed]
    seen, queue = set(), ["rviz"] + [p for p in REQUIRED_ROS_PACKAGES if p in installed]
    while queue:
        pkg = queue.pop()
        if pkg in seen:
            continue
        seen.add(pkg)
        for dep in sorted(ros_run_deps(share / pkg / "package.xml")):
            if dep in installed:
                queue.append(dep)
            elif not (is_system_dep(dep) or dep in conda_names):
                problems.append(f"'{pkg}' needs ROS package '{dep}', which is not in the payload")
    log(f"ROS packages: {len(installed)} installed, {len(seen)} in rviz/roscore closure")
    return sorted(set(problems))


# --------------------------------------------------------------------------- #
# DLL dependency check (pure-Python PE import reader)
# --------------------------------------------------------------------------- #
def pe_imports(path: Path, delay: bool = False) -> list[str]:
    """DLL names imported by a PE file (normal imports, or delay-load imports)."""
    data = path.read_bytes()
    if data[:2] != b"MZ":
        raise ValueError(f"{path}: not a PE file")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"{path}: bad PE signature")
    n_sections, opt_size = struct.unpack_from("<H", data, pe + 6)[0], struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    dd = opt + (112 if magic == 0x20B else 96)          # data directories
    n_dirs = struct.unpack_from("<I", data, dd - 4)[0]
    index = 13 if delay else 1
    if index >= n_dirs:
        return []
    rva, size = struct.unpack_from("<II", data, dd + 8 * index)
    if not rva:
        return []
    sections = []
    sec = opt + opt_size
    for i in range(n_sections):
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, sec + 40 * i + 8)
        sections.append((vaddr, max(vsize, rsize), raddr))

    def off(r):
        for vaddr, length, raddr in sections:
            if vaddr <= r < vaddr + length:
                return r - vaddr + raddr
        raise ValueError(f"{path}: RVA {r:#x} outside sections")

    def cstr(r):
        o = off(r)
        return data[o:data.index(b"\0", o)].decode("ascii", "replace")

    names, pos = [], off(rva)
    step, name_field = (32, 4) if delay else (20, 12)
    while pos + step <= len(data):
        entry = data[pos:pos + step]
        if not any(entry):
            break
        name_rva = struct.unpack_from("<I", entry, name_field)[0]
        if name_rva:
            names.append(cstr(name_rva))
        pos += step
    return names


def _system_dll(name: str, system_dirs: list[Path]) -> bool:
    lower = name.lower()
    if lower.startswith(("api-ms-win-", "ext-ms-")):
        return True                                       # API sets, resolved by the loader
    return any((d / name).exists() for d in system_dirs)


# Present on every Windows 10/11 install (used when checking off-Windows).
KNOWN_SYSTEM_DLLS = {n.lower() for n in """
advapi32.dll bcrypt.dll comctl32.dll comdlg32.dll crypt32.dll d3d11.dll d3d9.dll
dbghelp.dll dnsapi.dll dwmapi.dll dwrite.dll dxgi.dll gdi32.dll gdiplus.dll glu32.dll
imm32.dll iphlpapi.dll kernel32.dll mpr.dll msimg32.dll msvcrt.dll netapi32.dll
ntdll.dll ole32.dll oleaut32.dll opengl32.dll powrprof.dll psapi.dll rpcrt4.dll
secur32.dll setupapi.dll shell32.dll shlwapi.dll ucrtbase.dll user32.dll userenv.dll
uxtheme.dll version.dll winmm.dll winspool.drv ws2_32.dll wsock32.dll wtsapi32.dll
mswsock.dll normaliz.dll wldap32.dll authz.dll ncrypt.dll cfgmgr32.dll hid.dll
""".split()}


def check_dll_closure(stage: Path, system_dirs: list[Path] | None = None,
                      imports=None) -> tuple[list[str], int]:
    """Follow imports from DLL_ROOTS; return (problems, binaries checked).
    A DLL is satisfied if found next to the importer, in DLL_SEARCH_DIRS of the
    payload, or in the Windows system directories."""
    if system_dirs is None:
        windir = Path(os.environ.get("SystemRoot", r"C:\Windows"))
        system_dirs = [windir / "System32", windir] if (windir / "System32").is_dir() else []
    imports = imports or pe_imports
    search = [stage / d for d in DLL_SEARCH_DIRS]
    index: dict[str, Path] = {}
    for d in search:
        if d.is_dir():
            for f in d.iterdir():
                if f.suffix.lower() in (".dll", ".pyd", ".exe"):
                    index.setdefault(f.name.lower(), f)

    queue = []
    for pattern in DLL_ROOTS:
        queue += sorted(stage.glob(pattern))
    problems, seen = [], set()
    while queue:
        binary = queue.pop()
        key = str(binary).lower()
        if key in seen:
            continue
        seen.add(key)
        try:
            names = imports(binary)
        except (OSError, ValueError, struct.error) as exc:
            problems.append(f"cannot read imports of {binary.relative_to(stage)}: {exc}")
            continue
        for name in names:
            local = binary.parent / name
            if local.exists():
                queue.append(local)
            elif name.lower() in index:
                queue.append(index[name.lower()])
            elif _system_dll(name, system_dirs) or (not system_dirs and name.lower() in KNOWN_SYSTEM_DLLS):
                continue
            else:
                elsewhere = sorted(stage.rglob(name))
                hint = (f" (it is at {elsewhere[0].relative_to(stage).as_posix()}, which is not on the DLL search path)"
                        if elsewhere else "")
                problems.append(f"{binary.relative_to(stage).as_posix()} needs {name}, which is not in the payload or Windows{hint}")
    return sorted(set(problems)), len(seen)


def verify_runtime(stage: Path, conda_names: set[str] | None = None) -> None:
    if conda_names is None:
        listing = stage / "share" / "rviz-msi" / "packages.txt"
        conda_names = ({ln.split("=", 1)[0] for ln in listing.read_text(encoding="utf-8").splitlines() if ln}
                       if listing.is_file() else set())
    problems = check_ros_packages(stage, conda_names)
    dll_problems, checked = check_dll_closure(stage)
    log(f"DLL closure: {checked} binaries checked from {len(DLL_ROOTS)} root patterns")
    problems += dll_problems
    if problems:
        die("runtime dependency check failed:\n  " + "\n  ".join(problems))
    log("runtime dependency check passed: every ROS package and DLL rviz/roscore need is bundled")


def cmd_verify_runtime(a) -> None:
    verify_runtime(Path(a.stage))


ROS_ENV_BAT = r"""@echo off
rem ---------------------------------------------------------------------------
rem ros_env.bat - environment for the bundled ROS Noetic + RViz.
rem CALL this from your own scripts:  call "{prefix}\launchers\ros_env.bat"
rem Paths are computed from this file's location, so the tree is relocatable
rem for smoke tests even though the MSI installs to a fixed prefix.
rem ---------------------------------------------------------------------------
for %%I in ("%~dp0..") do set "RVIZ_ROOT=%%~fI"
if /i "%RVIZ_ENV_ACTIVE%"=="%RVIZ_ROOT%" goto :ros_vars
set "PATH=%RVIZ_ROOT%;%RVIZ_ROOT%\Library\mingw-w64\bin;%RVIZ_ROOT%\Library\usr\bin;%RVIZ_ROOT%\Library\bin;%RVIZ_ROOT%\Scripts;%RVIZ_ROOT%\bin;%RVIZ_ROOT%\DLLs;%RVIZ_ROOT%\Library\lib;%RVIZ_ROOT%\launchers;%PATH%"
set "RVIZ_ENV_ACTIVE=%RVIZ_ROOT%"
set "CONDA_PREFIX=%RVIZ_ROOT%"
rem Run package activation hooks exactly like 'conda activate' would. Their
rem output goes to a log (conda shows it; a Start menu window would not).
set "RVIZ_LOG_DIR=%LOCALAPPDATA%\RVizNoetic"
if not defined LOCALAPPDATA set "RVIZ_LOG_DIR=%TEMP%\RVizNoetic"
if not exist "%RVIZ_LOG_DIR%" mkdir "%RVIZ_LOG_DIR%" >nul 2>&1
set "RVIZ_ACTIVATE_LOG=%RVIZ_LOG_DIR%\activate.log"
(echo activation of %RVIZ_ROOT%) > "%RVIZ_ACTIVATE_LOG%" 2>nul || set "RVIZ_ACTIVATE_LOG=nul"
rem catkin's setup.bat reads _CATKIN_ENVIRONMENT_HOOKS_COUNT from a FOR /F
rem subshell, which runs cmd AutoRun even though we were started with /d. If
rem AutoRun exits, the count stays undefined, `if 0 LSS  (` is a syntax error
rem and cmd aborts every batch level with exit code 255 and no output. A
rem default of 0 keeps going; the ROS variables below are set either way.
set "_CATKIN_ENVIRONMENT_HOOKS_COUNT=0"
if exist "%RVIZ_ROOT%\etc\conda\activate.d" (
  for %%F in ("%RVIZ_ROOT%\etc\conda\activate.d\*.bat") do call :run_hook "%%~fF"
)
:ros_vars
rem Authoritative ROS variables (override anything the hooks computed).
set "CONDA_PREFIX=%RVIZ_ROOT%"
set "ROS_DISTRO=noetic"
set "ROS_VERSION=1"
set "ROS_PYTHON_VERSION=3"
set "ROS_ROOT=%RVIZ_ROOT%\Library\share\ros"
set "ROS_PACKAGE_PATH=%RVIZ_ROOT%\Library\share"
set "ROS_ETC_DIR=%RVIZ_ROOT%\Library\etc\ros"
set "ROS_OS_OVERRIDE=conda:win64"
set "CMAKE_PREFIX_PATH=%RVIZ_ROOT%\Library"
set "PYTHONPATH=%RVIZ_ROOT%\Library\lib\site-packages"
set "PYTHONHOME="
set "PYTHONNOUSERSITE=1"
set "PYTHONDONTWRITEBYTECODE=1"
set "QT_PLUGIN_PATH=%RVIZ_ROOT%\Library\plugins"
set "RVIZ_OGRE_PLUGIN_DIR=%RVIZ_ROOT%\Library\bin"
if not defined ROS_MASTER_URI set "ROS_MASTER_URI=http://localhost:11311"
exit /b 0

:run_hook
>> "%RVIZ_ACTIVATE_LOG%" 2>&1 echo --- %~nx1
call "%~1" >> "%RVIZ_ACTIVATE_LOG%" 2>&1
exit /b 0
"""

RVIZ_CMD = r"""@echo off
rem ---------------------------------------------------------------------------
rem rviz.cmd - start RViz with the bundled ROS environment (Start menu > RViz).
rem If ROS_MASTER_URI is the local default and no master is running, a roscore
rem is started in a minimized window first and stopped again when RViz exits.
rem A remote master (a robot) is never touched: RViz just connects to it.
rem   RVIZ_AUTO_ROSCORE=0   never start a local roscore
rem   RVIZ_KEEP_ROSCORE=1   leave the auto-started roscore running after RViz
rem   RVIZ_NO_PAUSE=1       do not keep the window open after a failure
rem   RVIZ_SOFTWARE_GL=1    software OpenGL (Mesa llvmpipe), see rviz-software.cmd
rem If RViz fails, the window stays open with the error and the log location,
rem so a Start menu launch never just flashes and disappears.
rem (goto, not blocks, so that arguments containing parentheses survive.)
rem ---------------------------------------------------------------------------
setlocal
title RViz (ROS Noetic)
call "%~dp0ros_env.bat"
if errorlevel 1 goto env_failed
set "RVIZ_STARTED_ROSCORE="
set "RVIZ_INTERACTIVE=1"
if /i "%~1"=="--help" set "RVIZ_INTERACTIVE="
if /i "%~1"=="-h" set "RVIZ_INTERACTIVE="
if "%RVIZ_NO_PAUSE%"=="1" set "RVIZ_INTERACTIVE="
set "RVIZ_EXE=%RVIZ_ROOT%\Library\bin\rviz.exe"
if not "%RVIZ_SOFTWARE_GL%"=="1" goto gl_chosen
rem Library\mesa holds Mesa's opengl32.dll next to a copy of rviz.exe; Windows
rem loads opengl32.dll from the executable's folder before System32.
set "RVIZ_EXE=%RVIZ_ROOT%\Library\mesa\rviz.exe"
set "GALLIUM_DRIVER=llvmpipe"
title RViz (ROS Noetic, software rendering)
echo [rviz] software rendering (Mesa llvmpipe): slower, but needs no GPU driver
:gl_chosen
echo [rviz] ROS_MASTER_URI=%ROS_MASTER_URI%
if /i "%~1"=="--help" goto run
if /i "%~1"=="-h" goto run
if "%RVIZ_AUTO_ROSCORE%"=="0" goto run
set "U=%ROS_MASTER_URI%"
if "%U:~-1%"=="/" set "U=%U:~0,-1%"
if /i "%U%"=="http://localhost:11311" goto local_master
if /i "%U%"=="http://127.0.0.1:11311" goto local_master
goto run
:local_master
call :master_online
if not errorlevel 1 goto run
echo [rviz] no ROS master at %ROS_MASTER_URI% - starting roscore (minimized window)
start "roscore (started by RViz)" /min "%ComSpec%" /d /c ""%~dp0roscore.cmd""
set "RVIZ_STARTED_ROSCORE=1"
set /a N=0
:wait_master
call :master_online
if not errorlevel 1 goto master_up
set /a N+=1
if %N% geq 60 goto master_late
ping -n 2 127.0.0.1 >nul
goto wait_master
:master_late
echo [rviz] roscore is not up after 60 s; starting RViz anyway (it waits for the master) 1>&2
goto run
:master_up
echo [rviz] roscore is up
:run
if "%RVIZ_LAUNCHER_DRYRUN%"=="1" goto dry_run
echo [rviz] starting RViz ...
"%RVIZ_EXE%" %*
set "RC=%ERRORLEVEL%"
goto finish
:dry_run
echo [rviz] dry run: rviz.exe not started
set "RC=0"
:finish
if not defined RVIZ_STARTED_ROSCORE goto report
if "%RVIZ_KEEP_ROSCORE%"=="1" goto report
call :stop_roscore
:report
if "%RC%"=="0" exit /b 0
echo.
echo [rviz] RViz exited with error code %RC%.
echo [rviz] The messages above show why. RViz's own log files are in:
set "RH=%ROS_HOME%"
if not defined RH set "RH=%USERPROFILE%\.ros"
echo [rviz]   %RH%\log
echo [rviz] A common cause is a missing or too old OpenGL graphics driver
echo [rviz] (e.g. some remote desktop sessions and virtual machines).
if not "%RVIZ_SOFTWARE_GL%"=="1" echo [rviz] Without a working GPU driver, use Start menu - RViz (software rendering).
if defined RVIZ_ACTIVATE_LOG echo [rviz] Environment setup log: %RVIZ_ACTIVATE_LOG%
if defined RVIZ_INTERACTIVE pause
exit /b %RC%

:env_failed
echo [rviz] could not set up the ROS environment (launchers\ros_env.bat failed).
if defined RVIZ_ACTIVATE_LOG echo [rviz] Environment setup log: %RVIZ_ACTIVATE_LOG%
if not "%RVIZ_NO_PAUSE%"=="1" pause
exit /b 1

:master_online
"%RVIZ_ROOT%\python.exe" -c "import sys, rosgraph; sys.exit(0 if rosgraph.is_master_online() else 1)" >nul 2>&1
exit /b %ERRORLEVEL%

:stop_roscore
rem roslaunch writes its PID to <ROS_HOME>\roscore-11311.pid; this launch just
rem (re)wrote it, so it is ours. /T also ends rosmaster and rosout.
set "RH=%ROS_HOME%"
if not defined RH set "RH=%USERPROFILE%\.ros"
if not exist "%RH%\roscore-11311.pid" exit /b 0
set /p RPID=<"%RH%\roscore-11311.pid"
echo [rviz] stopping the roscore it started (PID %RPID%)
taskkill /T /F /PID %RPID% >nul 2>&1
del "%RH%\roscore-11311.pid" >nul 2>&1
exit /b 0
"""

RVIZ_SOFTWARE_CMD = r"""@echo off
rem ---------------------------------------------------------------------------
rem rviz-software.cmd - RViz with software OpenGL (Mesa llvmpipe, on the CPU)
rem (Start menu > RViz (software rendering)). For PCs without a usable GPU
rem driver: virtual machines, some remote desktop sessions. Slower than
rem rviz.cmd; otherwise the same (local roscore, arguments, error window).
rem ---------------------------------------------------------------------------
setlocal
set "RVIZ_SOFTWARE_GL=1"
call "%~dp0rviz.cmd" %*
exit /b %ERRORLEVEL%
"""

ROSBAG_CMD = r"""@echo off
rem ---------------------------------------------------------------------------
rem rosbag.cmd - the bundled rosbag (bag review: rosbag info / rosbag play).
rem "rosbag play" goes through rosbag_play.py: it runs play.exe and, where
rem Windows blocks play.exe (Smart App Control), a Python player instead.
rem RVIZ_BAG_PLAYER=python always uses the Python player.
rem -W ignore::SyntaxWarning hides Python 3.12's warnings about old escape
rem sequences in rosbag (shown on every run: the launchers keep no .pyc).
rem ---------------------------------------------------------------------------
setlocal
call "%~dp0ros_env.bat" || exit /b 1
if /i "%~1"=="play" goto play
"%RVIZ_ROOT%\python.exe" -W ignore::SyntaxWarning "%RVIZ_ROOT%\Library\bin\rosbag" %*
exit /b %ERRORLEVEL%
:play
"%RVIZ_ROOT%\python.exe" -W ignore::SyntaxWarning "%~dp0rosbag_play.py" %*
exit /b %ERRORLEVEL%
"""

TOOL_SHIM = r"""@echo off
rem {tool}.cmd - run the bundled ROS tool '{tool}' whether it was installed as
rem .exe, .bat or an extension-less Python script. (goto, not blocks, so that
rem arguments containing parentheses survive.)
setlocal
call "%~dp0ros_env.bat" || exit /b 1
set "B=%RVIZ_ROOT%\Library\bin\{tool}"
if exist "%B%.exe" goto run_exe
if exist "%B%.bat" goto run_bat
if exist "%B%-script.py" goto run_pyscript
if exist "%B%" goto run_py
echo {tool}: not part of this RViz bundle 1>&2
exit /b 9009
:run_exe
"%B%.exe" %*
exit /b %ERRORLEVEL%
:run_bat
call "%B%.bat" %*
exit /b %ERRORLEVEL%
:run_pyscript
"%RVIZ_ROOT%\python.exe" "%B%-script.py" %*
exit /b %ERRORLEVEL%
:run_py
"%RVIZ_ROOT%\python.exe" "%B%" %*
exit /b %ERRORLEVEL%
"""

ROS_SHELL_CMD = r"""@echo off
call "%~dp0ros_env.bat" || exit /b 1
if /i "%~1"=="--home" cd /d "%USERPROFILE%"
title ROS Noetic shell (RViz bundle)
echo ROS Noetic environment ready  [%RVIZ_ROOT%]
echo   ROS_MASTER_URI=%ROS_MASTER_URI%
echo   Commands: rviz, rviz-software, roscore, roslaunch, rostopic, rosnode, rosservice, rosparam, rospack, rosbag
rem /d: do not run the user's cmd AutoRun (a stale conda/micromamba hook there
rem makes every cmd exit at once).
"%ComSpec%" /d /k
"""


def write_launchers(stage: Path, prefix: str) -> None:
    d = stage / "launchers"
    d.mkdir(parents=True, exist_ok=True)

    def w(name: str, text: str) -> None:
        # .bat/.cmd must be CRLF and ASCII for cmd.exe.
        (d / name).write_bytes(text.replace("\r\n", "\n").replace("\n", "\r\n")
                               .encode("ascii"))

    w("ros_env.bat", ROS_ENV_BAT.replace("{prefix}", prefix))
    w("rviz.cmd", RVIZ_CMD)
    w("rviz-software.cmd", RVIZ_SOFTWARE_CMD)
    w("rosbag.cmd", ROSBAG_CMD)
    # Python side of rosbag.cmd play (play.exe, or a Python player where
    # Windows blocks play.exe); kept next to this script in the repository.
    shutil.copy2(Path(__file__).with_name("rosbag_play.py"), d / "rosbag_play.py")
    w("ros_shell.cmd", ROS_SHELL_CMD)
    for tool in ROS_TOOLS:
        w(f"{tool}.cmd", TOOL_SHIM.replace("{tool}", tool))
    log(f"launchers written to {d}")


def write_manifest(stage: Path, pkgs: dict, out_dir: Path) -> tuple[int, int]:
    """Build records installed with the MSI, in <prefix>\\share\\rviz-msi\\:
    packages.txt (conda packages), conda-lock-win-64.txt (exact environment, for
    -LockFile rebuilds) and payload-files.tsv (size and path of every payload
    file). The file list is also written to out_dir for the build reports."""
    info = stage / "share" / "rviz-msi"
    info.mkdir(parents=True, exist_ok=True)
    (info / "packages.txt").write_text(
        "".join(f"{n}={p.get('version')}={p.get('build')}\n"
                for n, p in sorted(pkgs.items())), encoding="utf-8")
    lock = out_dir / "conda-lock-win-64.txt"
    if lock.is_file():
        shutil.copy2(lock, info / "conda-lock-win-64.txt")
    count = size = 0
    rows = []
    for dirpath, _dirs, files in os.walk(stage):
        for f in files:
            p = Path(dirpath) / f
            s = p.stat().st_size
            count += 1
            size += s
            rows.append(f"{s}\t{p.relative_to(stage).as_posix()}")
    listing = "\n".join(sorted(rows)) + "\n"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "payload-files.tsv").write_text(listing, encoding="utf-8")
    (info / "payload-files.tsv").write_text(listing, encoding="utf-8")   # lists every file but itself
    return count + 1, size + len(listing.encode("utf-8"))


def cmd_finalize(a) -> None:
    stage = Path(a.stage)
    cfg = Path(a.config_dir)
    if not stage.is_dir():
        die(f"stage dir not found: {stage}")
    pkgs = load_conda_meta(stage)
    pkgs_dirs = [Path(p) for p in a.pkgs_dir]
    env_meta = load_conda_meta(Path(a.env_prefix)) if a.env_prefix else {}

    collect_licenses(stage, pkgs, pkgs_dirs, env_meta,
                     robostack_license=cfg / "licenses" / "RoboStack-ros-noetic-LICENSE.txt")
    rviz_lic = Path(a.rviz_src) / "LICENSE"
    if rviz_lic.is_file():
        (stage / "licenses" / "rviz").mkdir(parents=True, exist_ok=True)
        shutil.copy2(rviz_lic, stage / "licenses" / "rviz" / "LICENSE")

    stripped = strip_build_only(stage, pkgs, read_list(cfg / "build-only-packages.txt"))
    kept = {n: p for n, p in pkgs.items() if n not in stripped}
    remove_path(stage / "conda-meta")
    # conda-pack's own activate scripts assume a conda-style shell; we ship
    # launchers instead, so drop them to avoid confusing users.
    for rel in ("Scripts/activate.bat", "Scripts/deactivate.bat",
                "Scripts/activate", "Scripts/deactivate", "Scripts/conda-unpack.exe",
                "Scripts/conda-unpack-script.py"):
        remove_path(stage / rel)

    prune(stage, read_list(cfg / "prune.txt"), keep_pdb=bool(a.keep_pdb))
    isolate_mesa(stage)
    verify_required(stage)
    verify_gpu_path(stage)
    verify_runtime(stage, set(pkgs))
    write_launchers(stage, a.prefix)
    count, size = write_manifest(stage, kept, Path(a.report_dir))
    log(f"payload: {count} files, {size / 2**20:.0f} MiB uncompressed")
    if count > 60000:
        log("WARNING: >60k files - MSI install/repair will be slow; "
            "consider extending config/prune.txt")


# --------------------------------------------------------------------------- #
# assets
# --------------------------------------------------------------------------- #
def rtf_escape(text: str) -> str:
    out = []
    for ch in text:
        if ch in "\\{}":
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\par\n")
        elif ch == "\r":
            continue
        elif ord(ch) > 127:
            code = ord(ch)
            out.append(f"\\u{code if code < 32768 else code - 65536}?")
        else:
            out.append(ch)
    return "".join(out)


def build_license_rtf(rviz_license: str, product: str) -> str:
    body = (
        f"{product}\n\n"
        "This package contains RViz built from source together with a private "
        "ROS Noetic runtime (RoboStack / conda-forge). Each component is "
        "distributed under its own license; see THIRD_PARTY_NOTICES.txt and "
        "the 'licenses' folder in the installation directory. Notable "
        "components include Qt 5 (LGPL-3.0), OGRE (MIT), Boost (BSL-1.0) and "
        "Python (PSF).\n\n"
        "RViz license:\n\n" + rviz_license.strip() + "\n"
    )
    return ("{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{\\fonttbl{\\f0\\fswiss Segoe UI;}}"
            "\\viewkind4\\pard\\f0\\fs17 " + rtf_escape(body) + "}")


def cmd_assets(a) -> None:
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    src = Path(a.rviz_src)
    raw = (src / "LICENSE").read_bytes()
    try:
        lic = raw.decode("utf-8")
    except UnicodeDecodeError:          # legacy 8-bit license file
        lic = raw.decode("cp1252", errors="replace")
    (out / "license.rtf").write_text(build_license_rtf(lic, a.product_name),
                                     encoding="ascii")
    icon_src = None
    for cand in ("icons/package.png", "icons/default_package_icon.png", "images/splash.png"):
        if (src / cand).is_file():
            icon_src = src / cand
            break
    ico = out / "rviz.ico"
    if a.icon and Path(a.icon).is_file():
        shutil.copy2(a.icon, ico)
    else:
        try:
            from PIL import Image  # noqa: PLC0415
        except ImportError:
            die("Pillow is required to build the icon (or pass --icon)")
        if icon_src is None:
            die("no icon source found in rviz sources; pass --icon")
        img = Image.open(icon_src).convert("RGBA")
        side = max(img.size)
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
        # Pillow only emits ICO sizes <= the source, so scale up to 256 first.
        canvas = canvas.resize((256, 256), Image.LANCZOS)
        canvas.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                                (64, 64), (128, 128), (256, 256)])
    log(f"assets written to {out} (icon from {a.icon or icon_src})")


# --------------------------------------------------------------------------- #
def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("version")
    p.add_argument("--rviz-src", required=True)
    p.add_argument("--build-number", type=int, default=0)
    p.add_argument("--raw", action="store_true", help="print rviz version only")
    p.set_defaults(func=cmd_version)

    p = sub.add_parser("check-env")
    p.add_argument("--prefix", required=True)
    p.set_defaults(func=cmd_check_env)

    p = sub.add_parser("finalize")
    p.add_argument("--stage", required=True)
    p.add_argument("--config-dir", required=True)
    p.add_argument("--rviz-src", required=True)
    p.add_argument("--prefix", required=True, help="final install prefix")
    p.add_argument("--pkgs-dir", action="append", default=[])
    p.add_argument("--env-prefix", help="build environment (for its unpacked conda-meta)")
    p.add_argument("--report-dir", required=True)
    p.add_argument("--keep-pdb", type=int, default=0)
    p.set_defaults(func=cmd_finalize)

    p = sub.add_parser("verify-runtime", help="re-run the ROS package + DLL dependency check")
    p.add_argument("--stage", required=True)
    p.set_defaults(func=cmd_verify_runtime)

    p = sub.add_parser("assets")
    p.add_argument("--rviz-src", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--product-name", required=True)
    p.add_argument("--icon", default="")
    p.set_defaults(func=cmd_assets)

    a = ap.parse_args(argv)
    a.func(a)


if __name__ == "__main__":
    main()
