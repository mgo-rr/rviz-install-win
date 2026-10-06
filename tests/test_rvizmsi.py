"""Unit tests for windows/rvizmsi.py (run anywhere: python -m pytest tests)."""
import json
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "windows"))
import rvizmsi  # noqa: E402

REPO = Path(__file__).resolve().parents[1]


def make_pkg(stage, pkgs_dir, name, files, depends=(), license_="BSD-3-Clause"):
    meta = stage / "conda-meta"
    meta.mkdir(parents=True, exist_ok=True)
    extracted = pkgs_dir / f"{name}-1.0-h0_0"
    (extracted / "info" / "licenses").mkdir(parents=True, exist_ok=True)
    (extracted / "info" / "licenses" / "LICENSE.txt").write_text(f"{name} license")
    for rel in files:
        p = stage / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x")
    (meta / f"{name}-1.0-h0_0.json").write_text(json.dumps({
        "name": name, "version": "1.0", "build": "h0_0", "license": license_,
        "depends": list(depends), "files": list(files),
        "extracted_package_dir": str(extracted),
    }))


@pytest.fixture
def stage(tmp_path):
    st, pk = tmp_path / "stage", tmp_path / "pkgs"
    required = [r for r in rvizmsi.REQUIRED_FILES if r != "Library/share/rviz/ogre_media"]
    make_pkg(st, pk, "python", ["python.exe", "Lib/test/test_x.py", "include/Python.h",
                                "Lib/os.py", "Lib/__pycache__/os.cpython-312.pyc"])
    make_pkg(st, pk, "qt-main", ["Library/plugins/platforms/qwindows.dll",
                                 "Library/lib/Qt5Core.lib", "Library/bin/designer.exe"])
    make_pkg(st, pk, "cmake", ["Library/bin/cmake.exe", "Library/share/cmake-3.31/x.cmake"])
    make_pkg(st, pk, "sip", ["Scripts/sip-build.exe"])
    make_pkg(st, pk, "pyqt", ["Lib/site-packages/PyQt5/QtCore.pyd"], depends=["sip >=6"])
    make_pkg(st, pk, "ogre", ["Library/bin/RenderSystem_GL.dll",
                              "Library/bin/Plugin_OctreeSceneManager.dll",
                              "Library/bin/Plugin_ParticleFX.dll",
                              "Library/include/OGRE/Ogre.h", "Library/bin/OgreMain.pdb"])
    make_pkg(st, pk, "mesa-llvmpipe", ["Library/bin/opengl32.dll", "Library/bin/libgallium_wgl.dll",
                                       "Library/lib/opengl32.lib"], license_="MIT")
    (st / "Library/bin/qt.conf").write_text("[Paths]\nPrefix = ../\n")
    # rviz build output is unmanaged (no conda-meta entry)
    for rel in required + ["Library/share/rviz/ogre_media/x.material",
                           "Library/share/rviz/cmake/rvizConfig.cmake",
                           "Library/bin/rospack.exe"]:
        p = st / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x")
    # ROS packages (package.xml) for the runtime closure check
    for pkg in rvizmsi.REQUIRED_ROS_PACKAGES + ["rviz"]:
        d = st / "Library/share" / pkg
        d.mkdir(parents=True, exist_ok=True)
        deps = "<depend>roscpp</depend><exec_depend>libogre</exec_depend>" if pkg == "rviz" else ""
        (d / "package.xml").write_text(f"<package format='2'><name>{pkg}</name>{deps}</package>")
    for rel in ["Library/bin/roscore", "Library/lib/rosout/rosout.exe"]:
        (st / rel).parent.mkdir(parents=True, exist_ok=True)
        (st / rel).write_text("x")
    src = tmp_path / "src"
    (src / "icons").mkdir(parents=True)
    (src / "package.xml").write_text("<package><version>1.14.26</version></package>")
    (src / "LICENSE").write_text("Copyright (c) 2011 Willow Garage {BSD} \\ test é", encoding="utf-8")
    from PIL import Image
    Image.new("LA", (128, 128), (128, 255)).save(src / "icons" / "package.png")
    return st, pk, src, tmp_path


def test_msi_version():
    assert rvizmsi.msi_version("1.14.26", 0) == "1.14.2600"
    assert rvizmsi.msi_version("1.14.26", 7) == "1.14.2607"
    with pytest.raises(SystemExit):
        rvizmsi.msi_version("1.14.26", 100)


@pytest.mark.parametrize("rel,pat,expected", [
    ("Library/share/rviz/cmake", "Library/share/*/cmake", True),
    ("Library/share/rviz/ogre_media", "Library/share/*/cmake", False),
    ("Lib/site-packages/a/__pycache__", "**/__pycache__", True),
    ("__pycache__", "**/__pycache__", True),
    ("Library/lib/Qt5Core.lib", "Library/lib/*.lib", True),
    ("Library/lib/site-packages/x.lib", "Library/lib/*.lib", False),
    ("Library/bin/OgreMain.PDB", "**/*.pdb", True),
])
def test_matches(rel, pat, expected):
    assert rvizmsi.matches(rel, pat) is expected


FAKE_IMPORTS = {"rviz.exe": ["rviz.dll", "KERNEL32.dll"], "rviz.dll": ["OgreMain.dll", "api-ms-win-crt-runtime-l1-1-0.dll"],
                "OgreMain.dll": ["USER32.dll"]}


def fake_imports(path, delay=False):
    return FAKE_IMPORTS.get(path.name, [])


def test_finalize_end_to_end(stage, monkeypatch):
    st, pk, src, tmp = stage
    monkeypatch.setattr(rvizmsi, "pe_imports", fake_imports)
    (st / "Library/bin/OgreMain.dll").write_text("x")
    (tmp / "out").mkdir(parents=True, exist_ok=True)
    (tmp / "out/conda-lock-win-64.txt").write_text("@EXPLICIT\nhttps://conda.anaconda.org/x.conda\n")
    rvizmsi.main(["finalize", "--stage", str(st), "--config-dir", str(REPO / "config"),
                  "--rviz-src", str(src), "--prefix", r"C:\opt\rviz\noetic",
                  "--pkgs-dir", str(pk), "--report-dir", str(tmp / "out")])
    # build-only package without dependents stripped; sip kept (pyqt needs it)
    assert not (st / "Library/bin/cmake.exe").exists()
    assert (st / "Scripts/sip-build.exe").exists()
    # pruning
    assert not (st / "conda-meta").exists()
    assert not (st / "include").exists()
    assert not (st / "Library/include").exists()
    assert not (st / "Lib/test").exists()
    assert not (st / "Library/lib/Qt5Core.lib").exists()
    assert not (st / "Library/bin/designer.exe").exists()
    # software rendering: Mesa's OpenGL is moved away from the default rviz.exe
    mesa = st / "Library/mesa"
    for name in ("opengl32.dll", "libgallium_wgl.dll", "rviz.exe", "qt.conf"):
        assert (mesa / name).is_file(), name
    assert not (st / "Library/bin/opengl32.dll").exists()
    assert not (st / "Library/bin/libgallium_wgl.dll").exists()
    assert (st / "Library/bin/rviz.exe").is_file()
    assert (st / "launchers/rviz-software.cmd").is_file()
    assert not (st / "Library/bin/OgreMain.pdb").exists()
    assert not (st / "Lib/__pycache__").exists()
    assert not (st / "Library/share/rviz/cmake").exists()
    assert (st / "Library/share/rviz/ogre_media/x.material").exists()
    assert (st / "Lib/os.py").exists()
    # notices + licenses
    notices = (st / "THIRD_PARTY_NOTICES.txt").read_text()
    assert "qt-main" in notices and "ogre" in notices
    assert (st / "licenses/ogre/LICENSE.txt").exists()
    assert (st / "licenses/rviz/LICENSE").exists()
    # launchers: CRLF, ascii
    for name in ["ros_env.bat", "rviz.cmd", "roscore.cmd", "rostopic.cmd", "rosbag.cmd", "ros_shell.cmd"]:
        data = (st / "launchers" / name).read_bytes()
        assert b"\r\n" in data and b"\n" not in data.replace(b"\r\n", b"")
        data.decode("ascii")
    assert b"roscore" in (st / "launchers/roscore.cmd").read_bytes()
    pk_list = (st / "share/rviz-msi/packages.txt").read_text()
    assert "cmake=" not in pk_list and "sip=" in pk_list
    assert (tmp / "out/payload-files.tsv").exists()
    # build records travel inside the MSI
    listed = (st / "share/rviz-msi/payload-files.tsv").read_text(encoding="utf-8")
    assert listed == (tmp / "out/payload-files.tsv").read_text(encoding="utf-8")
    assert "\tshare/rviz-msi/packages.txt" in listed
    assert (st / "share/rviz-msi/conda-lock-win-64.txt").read_text().startswith("@EXPLICIT")
    assert "\tshare/rviz-msi/conda-lock-win-64.txt" in listed


def test_finalize_detects_missing_rviz(stage, monkeypatch):
    st, pk, src, tmp = stage
    monkeypatch.setattr(rvizmsi, "pe_imports", fake_imports)
    (st / "Library/bin/rviz.exe").unlink()
    with pytest.raises(SystemExit):
        rvizmsi.main(["finalize", "--stage", str(st), "--config-dir", str(REPO / "config"),
                      "--rviz-src", str(src), "--prefix", r"C:\opt\rviz\noetic",
                      "--pkgs-dir", str(pk), "--report-dir", str(tmp / "out")])


def test_check_env_rejects_binary_rviz(stage):
    st, pk, _src, _tmp = stage
    make_pkg(st, pk, "ros-noetic-catkin", [])
    rvizmsi.main(["check-env", "--prefix", str(st)])
    make_pkg(st, pk, "ros-noetic-rviz", [])
    with pytest.raises(SystemExit):
        rvizmsi.main(["check-env", "--prefix", str(st)])


def test_assets(stage):
    _st, _pk, src, tmp = stage
    out = tmp / "assets"
    rvizmsi.main(["assets", "--rviz-src", str(src), "--out", str(out),
                  "--product-name", "RViz (ROS Noetic)"])
    rtf = (out / "license.rtf").read_text(encoding="ascii")
    assert rtf.startswith("{\\rtf1") and rtf.endswith("}")
    assert "\\{BSD\\}" in rtf and "\\\\ test" in rtf and "\\u233?" in rtf
    from PIL import Image
    ico = Image.open(out / "rviz.ico")
    assert ico.format == "ICO" and (256, 256) in ico.info["sizes"]


# --------------------------------------------------------------------------- #
# runtime dependency checks
# --------------------------------------------------------------------------- #
def write_pkg(share, name, deps=(), exec_deps=()):
    d = share / name
    d.mkdir(parents=True, exist_ok=True)
    body = "".join(f"<depend>{x}</depend>" for x in deps) + "".join(f"<exec_depend>{x}</exec_depend>" for x in exec_deps)
    (d / "package.xml").write_text(f"<?xml version='1.0'?><package format='2'><name>{name}</name>{body}</package>")


def test_ros_package_closure(tmp_path):
    share = tmp_path / "Library/share"
    for p in rvizmsi.REQUIRED_ROS_PACKAGES:
        write_pkg(share, p)
    write_pkg(share, "rviz", deps=["roscpp", "eigen", "libogre-dev", "yaml-cpp"], exec_deps=["libqt5-core", "python3-yaml"])
    write_pkg(share, "roscpp", deps=["xmlrpcpp", "boost"])          # xmlrpcpp missing -> problem
    probs = rvizmsi.check_ros_packages(tmp_path)
    assert probs == ["'roscpp' needs ROS package 'xmlrpcpp', which is not in the payload"]
    write_pkg(share, "xmlrpcpp", deps=["cpp_common"])
    write_pkg(share, "cpp_common")
    assert rvizmsi.check_ros_packages(tmp_path) == []
    (share / "rosmaster" / "package.xml").unlink()
    assert "ROS package 'rosmaster' is not in the payload" in rvizmsi.check_ros_packages(tmp_path)
    # rosdep keys that are conda packages (apr, log4cxx) are satisfied by them
    write_pkg(share, "rosmaster")
    write_pkg(share, "rosconsole", deps=["apr", "log4cxx"])
    write_pkg(share, "rviz", deps=["roscpp", "rosconsole"])
    assert len(rvizmsi.check_ros_packages(tmp_path)) == 2
    assert rvizmsi.check_ros_packages(tmp_path, {"apr", "log4cxx"}) == []


def test_dll_closure(tmp_path):
    st = tmp_path
    for rel in ["python.exe", "python312.dll", "Library/bin/rviz.exe", "Library/bin/rviz.dll",
                "Library/bin/Qt5Core.dll", "Library/plugins/platforms/qwindows.dll",
                "Library/bin/RenderSystem_GL.dll", "Library/bin/OgreMain.dll", "vcruntime140.dll"]:
        (st / rel).parent.mkdir(parents=True, exist_ok=True)
        (st / rel).write_bytes(b"MZ")
    sysdir = tmp_path / "win"
    sysdir.mkdir()
    (sysdir / "KERNEL32.dll").write_bytes(b"MZ")
    (sysdir / "OPENGL32.dll").write_bytes(b"MZ")
    graph = {"python.exe": ["python312.dll"], "python312.dll": ["vcruntime140.dll", "KERNEL32.dll"],
             "rviz.exe": ["rviz.dll", "Qt5Core.dll"], "rviz.dll": ["OgreMain.dll", "api-ms-win-crt-heap-l1-1-0.dll"],
             "qwindows.dll": ["Qt5Core.dll"], "RenderSystem_GL.dll": ["OgreMain.dll", "OPENGL32.dll"],
             "OgreMain.dll": ["vcruntime140.dll"], "Qt5Core.dll": ["KERNEL32.dll"], "vcruntime140.dll": []}
    imports = lambda p, delay=False: graph[p.name]  # noqa: E731
    probs, n = rvizmsi.check_dll_closure(st, system_dirs=[sysdir], imports=imports)
    assert probs == [] and n == 9
    graph["OgreMain.dll"] = ["vcruntime140.dll", "zlib.dll"]      # missing transitive DLL
    probs, _ = rvizmsi.check_dll_closure(st, system_dirs=[sysdir], imports=imports)
    assert probs == ["Library/bin/OgreMain.dll needs zlib.dll, which is not in the payload or Windows"]
    # DLLs installed to Library/lib (plain `DESTINATION lib`) are on the search path
    graph["OgreMain.dll"] = ["vcruntime140.dll", "image_transport.dll"]
    graph["image_transport.dll"] = []
    (st / "Library/lib").mkdir(parents=True, exist_ok=True)
    (st / "Library/lib/image_transport.dll").write_bytes(b"MZ")
    probs, _ = rvizmsi.check_dll_closure(st, system_dirs=[sysdir], imports=imports)
    assert probs == []
    # a DLL elsewhere in the payload is reported with where it was found
    (st / "Library/share").mkdir(parents=True, exist_ok=True)
    (st / "Library/lib/image_transport.dll").rename(st / "Library/share/image_transport.dll")
    probs, _ = rvizmsi.check_dll_closure(st, system_dirs=[sysdir], imports=imports)
    assert probs == ["Library/bin/OgreMain.dll needs image_transport.dll, which is not in the payload or Windows"
                     " (it is at Library/share/image_transport.dll, which is not on the DLL search path)"]


def test_licenses_from_env_meta(tmp_path):
    stage, env, cache = tmp_path / "stage", tmp_path / "env", tmp_path / "pkgs"
    ext = cache / "foo-1.0-h0_0"
    (ext / "info" / "licenses").mkdir(parents=True)
    (ext / "info" / "licenses" / "LICENSE").write_text("MIT")
    bar = tmp_path / "elsewhere" / "bar-2.0-x"
    (bar / "info").mkdir(parents=True)
    (bar / "info" / "LICENSE.txt").write_text("BSD")
    pkgs = {"foo": {"name": "foo", "version": "1.0", "build": "h0_0", "extracted_package_dir": ""},
            "bar": {"name": "bar", "version": "2.0", "build": "x", "extracted_package_dir": ""}}
    env_meta = {"bar": {"name": "bar", "extracted_package_dir": str(bar)}}
    stage.mkdir()
    rvizmsi.collect_licenses(stage, pkgs, [cache], env_meta)
    assert (stage / "licenses/foo/LICENSE").read_text() == "MIT"
    assert (stage / "licenses/bar/LICENSE.txt").read_text() == "BSD"


def test_licenses_robostack_and_metapackages(tmp_path):
    stage, cache = tmp_path / "stage", tmp_path / "pkgs"
    stage.mkdir()
    (cache / "ros-noetic-roscpp-1.17.4-np2_24" / "info").mkdir(parents=True)
    rs = tmp_path / "RoboStack-LICENSE.txt"
    rs.write_text("MIT License (RoboStack)")
    pkgs = {"ros-noetic-roscpp": {"name": "ros-noetic-roscpp", "version": "1.17.4", "build": "np2_24",
                                  "license": "BSD-3-Clause", "files": ["Library/bin/roscpp.dll"],
                                  "channel": "https://conda.anaconda.org/robostack-noetic/win-64"},
            "vc": {"name": "vc", "version": "14.5", "build": "h0", "license": "BSD-3-Clause", "files": []},
            "libsqlite": {"name": "libsqlite", "version": "3.5", "build": "h1", "license": "blessing",
                          "files": ["Library/bin/sqlite3.dll"]}}
    rvizmsi.collect_licenses(stage, pkgs, [cache], {}, robostack_license=rs)
    assert (stage / "licenses/RoboStack-ros-noetic/LICENSE").read_text() == "MIT License (RoboStack)"
    notices = (stage / "THIRD_PARTY_NOTICES.txt").read_text(encoding="utf-8")
    assert "BSD-3-Clause  [packaging: RoboStack, MIT]" in notices
    assert "(metapackage)" in notices.split("vc ")[1].splitlines()[0]
    assert "blessing" in notices and "libsqlite" in notices


@pytest.mark.skipif(not os.environ.get("RVIZMSI_PE_SAMPLES"), reason="set RVIZMSI_PE_SAMPLES to a dir of Windows binaries")
def test_pe_imports_matches_pefile():
    pefile = pytest.importorskip("pefile")
    files = [p for p in Path(os.environ["RVIZMSI_PE_SAMPLES"]).rglob("*") if p.suffix.lower() in (".dll", ".pyd", ".exe")]
    assert files
    for f in files:
        pe = pefile.PE(str(f), fast_load=True)
        pe.parse_data_directories(directories=[1, 13])
        assert rvizmsi.pe_imports(f) == [e.dll.decode() for e in getattr(pe, "DIRECTORY_ENTRY_IMPORT", [])], f
        assert rvizmsi.pe_imports(f, delay=True) == [e.dll.decode() for e in getattr(pe, "DIRECTORY_ENTRY_DELAY_IMPORT", [])], f


def test_rviz_launcher_auto_roscore(tmp_path):
    rvizmsi.write_launchers(tmp_path, r"C:\opt\rviz\noetic")
    cmd = (tmp_path / "launchers" / "rviz.cmd").read_bytes()
    assert b"\r\n" in cmd and b"\n" not in cmd.replace(b"\r\n", b"")      # CRLF only
    text = cmd.decode("ascii")
    # only the local default master is auto-started; remote masters are left alone
    assert 'if /i "%U%"=="http://localhost:11311" goto local_master' in text
    assert 'if "%RVIZ_AUTO_ROSCORE%"=="0" goto run' in text
    assert 'start "roscore (started by RViz)" /min' in text
    assert "rosgraph.is_master_online()" in text
    # it only stops a roscore it started itself
    assert "if not defined RVIZ_STARTED_ROSCORE goto report" in text
    assert "taskkill /T /F /PID %RPID%" in text
    # no `timeout` (fails without a console); ping is used to wait
    assert "timeout /t" not in text and "ping -n 2 127.0.0.1" in text
    # a failed start keeps the window open (but never for --help / tests)
    assert "if errorlevel 1 goto env_failed" in text
    assert "if defined RVIZ_INTERACTIVE pause" in text
    assert 'if /i "%~1"=="--help" set "RVIZ_INTERACTIVE="' in text
    assert 'if "%RVIZ_NO_PAUSE%"=="1" set "RVIZ_INTERACTIVE="' in text
    # activation hook output goes to a log, not to nul; the shell skips AutoRun
    env = (tmp_path / "launchers" / "ros_env.bat").read_bytes().decode("ascii")
    assert 'call :run_hook "%%~fF"' in env and ">nul 2>&1\r\n)" not in env
    assert 'set "RVIZ_ACTIVATE_LOG=%RVIZ_LOG_DIR%\\activate.log"' in env
    # a broken AutoRun must not turn catkin's hook loop into a syntax error
    assert env.index('set "_CATKIN_ENVIRONMENT_HOOKS_COUNT=0"') < env.index("call :run_hook")
    assert "Environment setup log: %RVIZ_ACTIVATE_LOG%" in text
    shell = (tmp_path / "launchers" / "ros_shell.cmd").read_bytes().decode("ascii")
    assert '"%ComSpec%" /d /k' in shell


def test_finalize_requires_mesa(stage, monkeypatch):
    st, pk, src, tmp = stage
    monkeypatch.setattr(rvizmsi, "pe_imports", fake_imports)
    (st / "Library/bin/opengl32.dll").unlink()
    with pytest.raises(SystemExit):
        rvizmsi.main(["finalize", "--stage", str(st), "--config-dir", str(REPO / "config"),
                      "--rviz-src", str(src), "--prefix", r"C:\opt\rviz\noetic",
                      "--pkgs-dir", str(pk), "--report-dir", str(tmp / "out")])


def test_verify_gpu_path_rejects_mesa_next_to_rviz(tmp_path):
    (tmp_path / "Library/bin").mkdir(parents=True)
    rvizmsi.verify_gpu_path(tmp_path)
    (tmp_path / "Library/bin/opengl32.dll").write_text("x")
    with pytest.raises(SystemExit):
        rvizmsi.verify_gpu_path(tmp_path)


def test_rviz_software_launcher(tmp_path):
    rvizmsi.write_launchers(tmp_path, r"C:\opt\rviz\noetic")
    sw = (tmp_path / "launchers" / "rviz-software.cmd").read_bytes().decode("ascii")
    assert 'set "RVIZ_SOFTWARE_GL=1"' in sw and 'call "%~dp0rviz.cmd" %*' in sw
    text = (tmp_path / "launchers" / "rviz.cmd").read_bytes().decode("ascii")
    # the default path is the GPU rviz.exe; only RVIZ_SOFTWARE_GL=1 switches
    gpu = text.index('set "RVIZ_EXE=%RVIZ_ROOT%\\Library\\bin\\rviz.exe"')
    assert text.index('if not "%RVIZ_SOFTWARE_GL%"=="1" goto gl_chosen') > gpu
    assert 'set "RVIZ_EXE=%RVIZ_ROOT%\\Library\\mesa\\rviz.exe"' in text
    assert '"%RVIZ_EXE%" %*' in text and "Library\\bin\\rviz.exe\" %*" not in text
    assert "use Start menu - RViz (software rendering)" in text


# rviz 1.14 gave these property classes templated (header-inline) constructors.
# Unless the class is RVIZ_EXPORT (dllimport in plugins), MSVC compiles the
# constructor into the plugin with the import thunk's address as the vtable and
# rviz.exe crashes at start-up in QObjectPrivate::connectImpl.
PROPERTY_CLASSES_NEEDING_EXPORT = {
    "string_property.h": "StringProperty", "float_property.h": "FloatProperty",
    "int_property.h": "IntProperty", "color_property.h": "ColorProperty",
    "quaternion_property.h": "QuaternionProperty", "enum_property.h": "EnumProperty",
    "editable_enum_property.h": "EditableEnumProperty",
    "display_visibility_property.h": "DisplayVisibilityProperty",
    "display_group_visibility_property.h": "DisplayGroupVisibilityProperty",
}


def test_rviz_patch_exports_property_classes():
    patch = (REPO / "patches/1.14.26/0001-windows-msvc-relocatable.patch").read_text(encoding="utf-8")
    for header, cls in PROPERTY_CLASSES_NEEDING_EXPORT.items():
        assert f"+++ b/src/rviz/properties/{header}" in patch, header
        assert f"+class RVIZ_EXPORT {cls} : public" in patch, cls


# --- rosbag play: play.exe, or the Python player where Windows blocks it ----
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("rosbag_play", REPO / "windows" / "rosbag_play.py")
rosbag_play = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rosbag_play)


def test_rosbag_play_parse_args():
    a = rosbag_play.parse_args(["--clock", "--pause", "-r", "0.5", "-s", "60", "a_0.bag", "a_1.bag"])
    assert a.clock and a.pause and a.rate == 0.5 and a.start == 60 and a.bagfiles == ["a_0.bag", "a_1.bag"]
    a = rosbag_play.parse_args(["--topics", "/tf", "/scan", "--bags", "x.bag"])
    assert a.topics == ["/tf", "/scan"] and a.bagfiles == ["x.bag"]
    for bad in (["--immediate", "x.bag"], [], ["-r", "0", "x.bag"]):
        with pytest.raises(SystemExit):
            rosbag_play.parse_args(bad)


def test_rosbag_play_latching_flag():
    assert rosbag_play.header_flag({"latching": b"1"}, "latching")
    assert rosbag_play.header_flag({"latching": "1"}, "latching")
    assert not rosbag_play.header_flag({"latching": b"0"}, "latching")
    assert not rosbag_play.header_flag({}, "latching")


def _fake_rosbag(monkeypatch, error):
    import types
    calls = []

    def rosbagmain(argv):
        calls.append(argv)
        if error:
            raise error
    monkeypatch.setitem(sys.modules, "rosbag", types.SimpleNamespace(rosbagmain=rosbagmain))
    played = []
    monkeypatch.setattr(rosbag_play, "python_play", lambda args: played.append(args.bagfiles))
    return calls, played


def test_rosbag_play_falls_back_only_when_windows_blocks_play_exe(monkeypatch):
    monkeypatch.delenv("RVIZ_BAG_PLAYER", raising=False)
    blocked = OSError(22, "An Application Control policy has blocked this file")
    blocked.winerror = 4551
    calls, played = _fake_rosbag(monkeypatch, blocked)
    assert rosbag_play.main(["play", "--clock", "x.bag"]) == 0
    assert calls == [["rosbag", "play", "--clock", "x.bag"]] and played == [["x.bag"]]
    # play.exe works: no Python player
    calls, played = _fake_rosbag(monkeypatch, None)
    rosbag_play.main(["play", "x.bag"])
    assert calls and not played
    # any other error is not hidden
    other = OSError(2, "not found")
    other.winerror = 2
    _fake_rosbag(monkeypatch, other)
    with pytest.raises(OSError):
        rosbag_play.main(["play", "x.bag"])
    # RVIZ_BAG_PLAYER=python skips play.exe
    monkeypatch.setenv("RVIZ_BAG_PLAYER", "python")
    calls, played = _fake_rosbag(monkeypatch, None)
    rosbag_play.main(["play", "x.bag"])
    assert not calls and played == [["x.bag"]]


def test_rosbag_launcher(tmp_path):
    rvizmsi.write_launchers(tmp_path, r"C:\opt\rviz\noetic")
    cmd = (tmp_path / "launchers" / "rosbag.cmd").read_bytes().decode("ascii")
    assert 'if /i "%~1"=="play" goto play' in cmd
    assert '"%~dp0rosbag_play.py" %*' in cmd and "-W ignore::SyntaxWarning" in cmd
    assert (tmp_path / "launchers" / "rosbag_play.py").read_text() == (REPO / "windows/rosbag_play.py").read_text()
