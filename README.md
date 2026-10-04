# RViz MSI installer for Windows 10/11

Builds **RViz 1.14.26 (ROS 1 Noetic)** from the upstream GitHub source
([ros-visualization/rviz](https://github.com/ros-visualization/rviz)) with MSVC
and packages it, together with a private ROS Noetic runtime, as a
self-contained **x64 MSI**.

The whole build is one **PowerShell** script. No bash, WSL or batch-file
layer is involved:

```powershell
.\build-rviz-msi.ps1                # -> dist\RVizNoetic-1.14.26-1.14.2600-x64.msi
```

`Get-Help .\build-rviz-msi.ps1 -Full` documents every option.

> **Status:** the build logic is tested with stubbed tools: a full pipeline
> dry run, unit tests, the PowerShell linter, a WiX schema check and the patch
> check (see [Testing](#testing)). The first real Windows build still needs to
> be run: expect a round of fixes on the compile and WiX-validation steps.

---

## How it works

| # | Step | What happens |
|---|---|---|
| 0 | preflight | Windows x64, Visual Studio 2022 C++ toolset (vswhere), free disk, long paths, signtool, and **Git for Windows (Git Bash)**: used if present, otherwise installed from the official release page after its SHA-256 and code signature are checked |
| 1 | tools | **micromamba** (pinned version + SHA-256), a private **.NET 8 SDK** (official zip, checked against Microsoft's SHA-512) and **WiX 5.0.2** + UI/Util extensions, all inside the work dir. Nothing else is installed globally |
| 2 | source | `git clone --branch 1.14.26`, checks the pinned commit, applies `patches\1.14.26\*.patch` |
| 3 | env | One conda env from **RoboStack** (`robostack-noetic`) + `conda-forge` with strict channel priority, holding rviz's build + runtime dependencies. Writes `conda-lock-win-64.txt` |
| 4 | build | Conda activation + `vcvars64`, then CMake/Ninja with the flags RoboStack uses for ROS 1 on Windows; rviz is installed into `<env>\Library` |
| 5 | pack | `conda-pack --dest-prefix C:\opt\rviz\noetic` copies the env and rewrites every recorded prefix to the final install path |
| 6 | finalize | Third-party notices + license texts, strips build-only packages, prunes headers/import libs/docs, **checks the ROS package + DLL dependency closure**, writes launchers, precompiles `.pyc`, builds the icon + license RTF |
| 7 | smoke | Runs the staged `rviz.exe --help` (loads Qt, ROS, Boost DLLs) and `rospack find/plugins rviz` |
| 8 | msi | `wix build` with `<Files>` harvesting, ICE validation, optional Authenticode signing, SHA-256, size check (< 2 GB) |
| 9 | test-install | Optional (`-TestInstall`, elevated): silent install, start roscore + rviz from the installed copy, uninstall, verify cleanup |

Steps are **resumable**. Each completed step leaves a fingerprint of its
inputs. A re-run skips steps whose inputs haven't changed, and changing a
step's inputs re-runs it and every step after it. Use `-FromStep` or
`-OnlyStep` to control this by hand. Every external program runs through one
helper that streams its output, logs the command line (secrets masked) and
stops the build with the step name on a non-zero exit code.

### Why RoboStack + a patch?

rviz needs about 100 ROS/Qt5/OGRE 1.10/Boost libraries. RoboStack publishes
these for `win-64`, built with MSVC, and its own `ros-noetic-rviz` win-64
package proves the toolchain works. rviz itself is compiled from the GitHub
source. The patch (`patches\1.14.26\0001-windows-msvc-relocatable.patch`) is
based on RoboStack's Windows patch:

* MSVC fixes: `NOGDI`, `RVIZ_EXPORT` on `EnumProperty`, sip `.pyd` naming,
  OpenGL lookup, OGRE 1.10 font definition.
* **Relocatable OGRE plugins.** Upstream bakes the build machine's plugin
  path into `rviz.exe`. The patched lookup order is `RVIZ_OGRE_PLUGIN_DIR`,
  then `CONDA_PREFIX`, then the compiled-in path.
* A `RVIZ_BUILD_PYTHON_BINDINGS` option (`-NoPythonBindings`).

---

## Prerequisites (build machine)

* Windows 10 1809+ or Windows 11, x64, about **25 GB** free disk.
* Windows PowerShell 5.1 (built in) or PowerShell 7.
* **Visual Studio 2022** or **Build Tools 2022** with *Desktop development
  with C++*:
  ```
  winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
  ```
* **Git for Windows (Git Bash)**. RoboCare engineers already have it for SSH
  access to robots, and the script uses that install as it is. If it's
  missing, the script offers to install it (or does so silently with
  `-InstallGit`), per-user without UAC when not elevated. Only its `git.exe`
  is used by the build.
* Internet access to: github.com (+ api.github.com), conda.anaconda.org,
  builds.dotnet.microsoft.com, api.nuget.org.
* Recommended: add the work dir (`C:\rvb`) to the Microsoft Defender
  exclusions. Creating the env unpacks tens of thousands of files.

## Quick start

```powershell
git clone <this repo> C:\src\rviz-installer     # or download the zip
cd C:\src\rviz-installer
.\build-rviz-msi.ps1 -CheckOnly                  # what was detected + effective config
.\build-rviz-msi.ps1 -BuildNumber 1 -Manufacturer "Your Company"
```

* If script execution is disabled:
  `powershell -ExecutionPolicy Bypass -File .\build-rviz-msi.ps1 -BuildNumber 1`.
* For a zip downloaded with a browser, run
  `Get-ChildItem -Recurse | Unblock-File` first.

The first run takes about 30–60 min (env solve + downloads + compile). The
MSI, its `.sha256`, the conda lock file and a payload file list are copied to
`.\dist\`. The full log is in `C:\rvb\out\build-*.log`.

### Options

| Option | Meaning |
|---|---|
| `-CheckOnly` | report the environment and effective configuration, build nothing |
| `-WorkDir C:\rvb` | build directory (no spaces) |
| `-Prefix C:\opt\rviz\noetic` | install location baked into the MSI |
| `-Manufacturer NAME` | MSI manufacturer (default "RViz MSI Builder") |
| `-BuildNumber N` | packaging revision → MSI version 1.14.(26*100+N) |
| `-OutputDir DIR` | where the MSI + reports are copied (default `.\dist`) |
| `-RvizRef REF`, `-RvizRepo URL`, `-NoCommitCheck` | rviz source |
| `-LockFile FILE` | rebuild with the exact package set of an earlier build |
| `-ExtraPackages a,b` | ship more RoboStack packages (e.g. `ros-noetic-rviz-imu-plugin`) |
| `-NoPythonBindings` | skip the sip/PyQt bindings |
| `-Jobs N` | compile jobs |
| `-FromStep S`, `-OnlyStep S` | re-run from a step / run only one step |
| `-Clean` | wipe the work dir (keeps downloaded tools + package cache) |
| `-KeepPdb`, `-SkipSmoke`, `-SkipValidate` | |
| `-TestInstall` | install/run/uninstall check (elevated PowerShell) |
| `-HeadlessTest` | with `-TestInstall`: skip the rviz window (no GPU, e.g. CI) |
| `-SignThumbprint T` / `-SignPfx FILE` | Authenticode-sign (PFX password in `$env:SIGN_PFX_PASSWORD`; never logged) |
| `-IconFile FILE` | custom .ico |
| `-InstallGit` / `-NoInstallGit` | install Git for Windows without asking / never |
| `-ConfigFile FILE` | alternative to `config\build.psd1` |

Pinned defaults (versions, hashes, product identity, UpgradeCode) live in
`config\build.psd1`, a PowerShell data file: values only, no code runs.

---

## What the MSI installs

* Per-machine install to the **fixed** path `C:\opt\rviz\noetic`. The path is
  set at build time because the conda prefixes inside the payload are
  rewritten to it. To change it, rebuild with `-Prefix`.
* **Start menu > RViz (ROS Noetic)**: *RViz*, *roscore*, *ROS Noetic Shell*,
  *Third-party notices*.
* Optional features (feature-tree UI):
  * *Add launchers to system PATH* (on by default). Only
    `C:\opt\rviz\noetic\launchers` is added, at the end of PATH, so an
    existing ROS install keeps priority and the bundled DLLs never shadow
    other software.
  * *Desktop shortcut* (off by default).
* Launchers in `launchers\`: `rviz.cmd`, `roscore.cmd`, `roslaunch.cmd`,
  `rostopic.cmd`, `rosnode.cmd`, `rosservice.cmd`, `rosparam.cmd`,
  `rosmsg.cmd`, `rossrv.cmd`, `rospack.cmd`, `ros_shell.cmd`, and
  `ros_env.bat` (call this from your own scripts to get the ROS environment).
* `ROS_MASTER_URI` defaults to `http://localhost:11311` when it isn't already
  set. To connect to a robot, set it (plus `ROS_IP`/`ROS_HOSTNAME`) before
  starting rviz.
* Upgrades: same `UpgradeCode` + higher version means an in-place major
  upgrade (old version removed first). Downgrades are blocked.
* Uninstall removes everything, including runtime `.pyc` caches, shortcuts
  and the PATH entry.

### The bundled ROS runtime

The MSI is self-contained: the target PC needs **no ROS install, no Python,
no Visual C++ redistributable and no conda**. Everything RViz needs is in
`C:\opt\rviz\noetic`:

* **ROS Noetic core** (RoboStack win-64 builds): roscpp, rospy, rosconsole,
  pluginlib, tf2_ros, image_transport (+ compressed plugin), message packages
  (std/geometry/sensor/nav/visualization/map msgs), urdf, interactive_markers,
  laser_geometry, resource_retriever, media_export.
* **A ROS master and CLI tools**: roscore (rosmaster + rosout), roslaunch,
  rostopic, rosnode, rosservice, rosparam, rosmsg/rossrv, rospack.
* **Libraries**: Qt 5.15, OGRE 1.10 (OpenGL render system), Boost, Assimp,
  urdfdom, yaml-cpp, OpenCV, Python 3.12, and the MSVC/UCRT runtime DLLs.
* **Environment**: `launchers\ros_env.bat` sets `ROS_PACKAGE_PATH`,
  `ROS_DISTRO`, `PYTHONPATH`, `QT_PLUGIN_PATH`, the OGRE plugin path and a
  default `ROS_MASTER_URI`, isolated from any other Python/ROS on the PC.

The PC itself must provide a **GPU driver with OpenGL** (OGRE's render
system). Your robot's own description and mesh packages, needed to show a
RobotModel, are not part of RViz. Add them with `-ExtraPackages` if they're
on RoboStack, or point `ROS_PACKAGE_PATH` at them.

How this is verified:

| When | Check |
|---|---|
| finalize (every build) | **ROS package closure**: every ROS package rviz and roscore need is present, following package.xml run dependencies transitively |
| finalize (every build) | **DLL closure**: starting from rviz.exe, its plugins, the OGRE and Qt plugins, rospack, rosout and python.exe, every imported DLL must be in the payload or be a Windows system DLL (pure-Python PE reader, cross-checked against `pefile` on 181 real Windows binaries) |
| smoke (every build) | staged `rviz.exe --help` loads; `rospack` resolves rviz and its plugin manifest |
| `-TestInstall` | after a real install: roscore starts and `/rosout` appears, `rostopic list` works, rviz starts, registers with the master, stays up and logs no plugin/OGRE errors; bundled python imports rospy; uninstall leaves nothing behind |

Silent install / uninstall:

```
msiexec /i RVizNoetic-1.14.26-1.14.2601-x64.msi /qn /l*v install.log
msiexec /i ... /qn ADDLOCAL=Main,StartMenu          (no PATH change)
msiexec /x RVizNoetic-1.14.26-1.14.2601-x64.msi /qn
```

---

## Repository layout

```
build-rviz-msi.ps1            entry point: parameters, help, config, main
windows\RvizMsi.Build.ps1     all build steps (dot-sourced library)
windows\rvizmsi.py            payload staging: notices, strip, prune, dependency checks, launchers, assets
windows\rviz.wxs              WiX v5 MSI definition
windows\test_install.ps1      install/run/uninstall test (-TestInstall)
config\build.psd1             pinned versions, product identity, UpgradeCode
config\conda-packages.txt     conda specs (RoboStack names of rviz deps + tools)
config\build-only-packages.txt  stripped from the payload after the build
config\prune.txt              glob patterns removed from the payload
patches\1.14.26\              source patches applied to that rviz version
tests\                        PowerShell dry run, pytest, WiX schema check
.github\workflows\ci.yml       GitHub Actions: checks + full build on windows-2022
PSScriptAnalyzerSettings.psd1 lint settings
```

Work dir (`C:\rvb`): `tools\` (micromamba, dotnet, wix), `mamba\pkgs`
(package cache), `envs\rviz`, `envs\tools`, `src\rviz`, `b\` (build),
`stage\` (MSI payload), `assets\`, `out\` (MSI, logs, lock, reports).

## Reproducible / CI builds

* Every build writes `out\conda-lock-win-64.txt` (also copied to `dist\`).
  Commit it, then rebuild with the same dependencies using `-LockFile <file>`.
* rviz is pinned by tag **and** commit. micromamba is pinned by version +
  SHA-256, WiX by version, and the .NET SDK is checked against Microsoft's
  SHA-512.
* **GitHub Actions** (`.github/workflows/ci.yml`, `windows-2022` runner):
  * `checks` (every push and PR, ~5 min): the dry run under Windows
    PowerShell 5.1 **and** PowerShell 7, PSScriptAnalyzer, the Python tests
    (PE reader cross-checked on real Windows DLLs), the WiX schema check and
    the patch check.
  * `build` (pushes to `main` and manual runs, ~1–2 h): the full build under
    Windows PowerShell 5.1, then `-TestInstall -HeadlessTest`: a real
    install, roscore/rostopic/rospack/rospy from the installed copy, then
    uninstall. The rviz window is skipped because hosted runners have no
    OpenGL-capable GPU. Run `-TestInstall` without `-HeadlessTest` on a real
    PC for that part.
  * The MSI, checksum, lock file and all logs are uploaded as artifacts, the
    logs even from failed runs. The conda package cache is cached between
    runs.
  * Windows minutes count double on private repositories.

## Testing

```powershell
pwsh -NoProfile -File tests/Test-Build.ps1     # 99 checks, PowerShell 5.1 or 7, any OS
python -m pytest tests                         # staging + dependency checks
python tests/check_wxs_schema.py <wix-v5.0.2-source>
Invoke-ScriptAnalyzer -Path build-rviz-msi.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
```

`Test-Build.ps1` covers the config helpers and validation, and the Git for
Windows pre-check and verified install. It then dry-runs the **whole
pipeline** with every external tool replaced by a recorder:

* exact command lines and step order;
* the generated WiX response file;
* resume after an unchanged run and after a failure;
* reruns when the config changes, `-FromStep` / `-OnlyStep`;
* signing, with the password masked in the log;
* relative paths;
* error exit codes.

`-TestInstall` adds a real install/run/uninstall cycle on Windows.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `... cannot be loaded because running scripts is disabled` | `powershell -ExecutionPolicy Bypass -File .\build-rviz-msi.ps1 ...` (and `Unblock-File` for downloaded zips) |
| `Git for Windows (Git Bash) is required` | Install Git for Windows, or re-run with `-InstallGit` |
| Git download: `SHA-256 mismatch`, signature not `Valid`, or unexpected signer | The download was corrupted, tampered with, or not published by the Git for Windows maintainer; nothing was installed |
| `Visual Studio ... was not found` | Install the VS 2022 C++ workload (see Prerequisites) |
| `MSVC link.exe is not first on PATH` | Another `link.exe` (e.g. from a Unix tools package) shadows MSVC's; remove it from PATH |
| env step: solver conflict | A RoboStack update moved pins. Re-run with a known-good `-LockFile`, or relax a pin in `config\conda-packages.txt` |
| build: sip / python bindings errors | `-NoPythonBindings -FromStep build` |
| build: path too long | Use a shorter `-WorkDir` (e.g. `C:\b`) or enable Win32 long paths |
| smoke: rviz.exe did not start | See `C:\rvb\out\smoke\rviz-help.txt`. Usually a missing DLL: check that `config\prune.txt` / `build-only-packages.txt` didn't remove it |
| finalize: `runtime dependency check failed` | The message lists the missing ROS package or DLL; add the conda package to `config\conda-packages.txt` or `-ExtraPackages` |
| rviz window black / crashes on start (target PC) | OGRE needs a real OpenGL driver. VMs and RDP sessions without GPU support fail. Update the GPU driver |
| ICE validation errors | Inspect the output; `-SkipValidate` for a quick test build |

## Notes & licensing

* **ROS 1 Noetic reached end-of-life in May 2025.** RoboStack still publishes
  win-64 Noetic packages (rviz 1.14.26 built March 2026), but there are no
  upstream security fixes. For new deployments, consider RViz2 (ROS 2).
* The MSI redistributes Qt 5 (LGPL-3.0), OGRE (MIT), Boost, Python, OpenCV and
  others. `THIRD_PARTY_NOTICES.txt` and `licenses\` are generated from the
  conda metadata and installed next to rviz. Review them before external
  distribution.
* Defaults are neutral for public use: set `-Manufacturer` to your
  organisation. Forks that publish their own MSIs should also generate a new
  `UpgradeCode` in `config\build.psd1`.
* WiX is pinned to **5.0.2** (MS-RL). WiX ≥ 6 binaries are under the Open
  Source Maintenance Fee EULA for revenue-generating users. Check that before
  you bump `WixVersion`.
* The rviz patch is derived from [RoboStack/ros-noetic](https://github.com/RoboStack/ros-noetic) (BSD-3-Clause).
