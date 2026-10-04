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
    for name in ["ros_env.bat", "rviz.cmd", "roscore.cmd", "rostopic.cmd", "ros_shell.cmd"]:
        data = (st / "launchers" / name).read_bytes()
        assert b"\r\n" in data and b"\n" not in data.replace(b"\r\n", b"")
        data.decode("ascii")
    assert b"roscore" in (st / "launchers/roscore.cmd").read_bytes()
    pk_list = (st / "share/rviz-msi/packages.txt").read_text()
    assert "cmake=" not in pk_list and "sip=" in pk_list
    assert (tmp / "out/payload-files.tsv").exists()


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
