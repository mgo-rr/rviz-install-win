# RoboStack (pixi / micromamba / conda) vs. rviz-install-win: how RViz and roscore are launched on Windows

Date: 2026-10-06. Scope: ROS 1 Noetic, Windows 10/11 x64.

Compared:

- RoboStack's Getting Started page ([robostack.github.io/GettingStarted](https://robostack.github.io/GettingStarted.html), source `docs/GettingStarted.md` in `RoboStack/robostack.github.io`)
- the RoboStack recipe generator ([RoboStack/vinca](https://github.com/RoboStack/vinca)) and its activation and build templates
- RoboStack's Noetic patches ([RoboStack/ros-noetic](https://github.com/RoboStack/ros-noetic))
- upstream catkin 0.8.12, ros_environment 1.3.2 and ros_comm 1.17.4, which are the versions in our build
- our MSI v1.14.26-2 (payload list from CI run 14, launcher templates in `windows/rvizmsi.py`, shortcuts in `windows/rviz.wxs`)

**About "byte-for-byte":** RoboStack's package files (`conda.anaconda.org` / `prefix.dev`) cannot be downloaded from this environment. Byte identity was therefore checked from the source templates plus the file sizes recorded in our payload list. Wherever both are available, the sizes match exactly (see §3.1).

---

## 1. Summary

| Aspect | RoboStack: pixi | RoboStack: micromamba | RoboStack: conda | Our MSI |
|---|---|---|---|---|
| Start-menu / desktop shortcuts | **none** | **none** | **none** | RViz, roscore, ROS Noetic Shell, Third-party notices (+ optional desktop RViz) |
| How the user starts RViz | `pixi run -e noetic rviz`, or `pixi shell -e noetic` then `rviz` | `micromamba activate ros_env` then `rviz` | `conda activate ros_env` then `rviz` | Start menu > RViz, which runs `launchers\rviz.cmd` |
| roscore | user starts it in a **second terminal** (`roscore`) | same | same | auto-started by `rviz.cmd` when `ROS_MASTER_URI` is the local default and no master answers; stopped again on exit |
| Who runs package activation (`etc\conda\activate.d\*.bat`) | pixi, always under **cmd.exe** | micromamba hook: `.bat` in cmd, `.ps1` in PowerShell | conda: `.bat` in cmd, `.ps1` in PowerShell | `ros_env.bat` calls every `activate.d\*.bat` (cmd), then sets the ROS variables itself |
| ROS 1 env in **PowerShell** | ✅ (pixi activates via cmd) | ❌ ROS variables not set: `ros-noetic-catkin` ships no `.ps1` | ❌ same | ✅ (launchers are `.cmd`, independent of the user's shell) |
| Binaries executed | `Library\bin\rviz.exe`, `Library\bin\roscore.exe` (catkin Python wrapper) | same | same | **same files** (`rviz.cmd` → `Library\bin\rviz.exe`; `roscore.cmd` → `Library\bin\roscore.exe`) |
| Errors visible? | yes, the user's own terminal stays open | yes | yes | v1.14.26-1/-2: **no**, a failing Start-menu launch closes its window. Fixed in `fc4e050` (window stays open) |
| Affected by `cmd` AutoRun | activation runs inside cmd | `micromamba shell init -s cmd.exe` **writes** AutoRun | `conda init cmd.exe` **writes** AutoRun | shortcut → `rviz.cmd` runs via `cmd /c` *without* `/d`, so a broken AutoRun can kill it (see §5) |

**Bottom line:**

- At the level of executables, environment-variable values and activation scripts, our MSI runs the same RoboStack-built files.
- The differences are all in the launch path:
  - RoboStack has no shortcuts and relies on an interactive, already-open, activated terminal.
  - We add a fixed-prefix environment, Start-menu shortcuts and roscore auto-start.
  - That launch path brought a failure mode RoboStack users never see: a Start-menu launch that dies before showing anything.

---

## 2. RoboStack's documented Windows workflow (verbatim from `docs/GettingStarted.md`)

### 2.1 Install

**micromamba:**

```
micromamba create -n ros_env -c conda-forge -c robostack-noetic ros-noetic-desktop
micromamba activate ros_env
micromamba config append channels robostack-noetic --env
```

**conda** (Miniforge recommended; the `defaults` channel is to be removed):

```
conda create -n ros_env -c conda-forge -c robostack-noetic ros-noetic-desktop
conda activate ros_env
conda config --env --add channels robostack-noetic
```

**pixi:**

- Install with `winget install prefix-dev.pixi`, which puts the binary in `%LOCALAPPDATA%\pixi\bin`.
- `pixi init robostack`, then a `pixi.toml` containing:
  - `[target.win.activation] scripts = ["install/setup.bat"]`
  - `[feature.noetic] channels = ["https://prefix.dev/robostack-noetic"]`
  - `[feature.noetic.dependencies] ros-noetic-desktop = "*", catkin_tools = "*"`
  - the environment `noetic = { features = ["noetic", "build"] }`
- then `pixi install`.

**Prerequisite in all three:** "Windows users need Visual Studio 2022 with C++ support". This is only needed for building, not for running RViz.

### 2.2 Run (ROS 1)

| Tool | First terminal | Second terminal |
|---|---|---|
| micromamba | `micromamba activate ros_env` / `roscore` | `micromamba activate ros_env` / `rviz` |
| conda | `conda activate ros_env` / `roscore` | `conda activate ros_env` / `rviz` |
| pixi | `cd robostack` / `pixi run -e noetic roscore` (or `pixi shell -e noetic`, then `roscore`) | `cd robostack` / `pixi run -e noetic rviz` (or `pixi shell -e noetic`, then `rviz`) |

The page notes "The ROS environment activation is included automatically. There is no need to add a `source` command". There is no mention anywhere of shortcuts, Start menu entries or GUI launchers. A search of `RoboStack/ros-noetic` and `RoboStack/vinca` finds no `menuinst` and no `Menu/*.json`, and our payload (built from the same packages) contains no `Menu/` directory. **RoboStack provides no shortcuts at all.**

---

## 3. What "activation" actually does on Windows (code review)

### 3.1 Activation scripts installed by RoboStack packages (Noetic env, from our payload list)

`etc\conda\activate.d\` contains exactly these `.bat` files. cmd runs them in alphabetical order:

| File | Bytes | Origin |
|---|---|---|
| `khronos-opencl-icd-loader_activate.bat` | 398 | conda-forge |
| `libxml2-split_activate.bat` | 384 | conda-forge |
| `openssl_activate-win.bat` | 277 | conda-forge |
| `pkg-config_activate.bat` | 261 | conda-forge |
| **`ros-noetic-catkin_activate.bat`** | **520** | RoboStack (`vinca/templates/activate.bat.in`) |

**Byte check:**

- Rendering `activate.bat.in` (empy `@@` → `@`) with CRLF line endings gives exactly 520 bytes. With LF it would be 505.
- `deactivate.bat.in` renders to 436 bytes, matching `ros-noetic-catkin_deactivate.bat` (436).
- Our MSI therefore ships RoboStack's activation scripts unchanged.

**No `.ps1` exists for catkin.**

- `bld_catkin.bat.in` copies only `%%F.bat` for `ros-noetic-catkin`.
- It copies `.bat` **and** `.ps1` only for the ROS 2 `ros-workspace` package.
- Consequence: in PowerShell, conda and micromamba run `*.ps1` activation scripts only, so **none of the ROS 1 variables get set** (`ROS_PACKAGE_PATH`, `ROS_DISTRO`, `ROS_MASTER_URI`, …). `rviz` then starts but cannot find its plugins or packages.
- pixi is not affected: it executes activation under `cmd.exe` on Windows ([pixi docs](https://pixi.prefix.dev/dev/workspace/environment/)).

### 3.2 `ros-noetic-catkin_activate.bat` (rendered from vinca `activate.bat.in`)

```
:: Generated by vinca http://github.com/RoboStack/vinca.
:: DO NOT EDIT!
@if not defined CONDA_PREFIX goto:eof
@REM Don't do anything when we are in conda build.
@if defined SYS_PREFIX exit /b 0
@set "QT_PLUGIN_PATH=%CONDA_PREFIX%\Library\plugins"
@call "%CONDA_PREFIX%\Library\local_setup.bat"
@set PYTHONHOME=
@set "ROS_OS_OVERRIDE=conda:win64"
@set "ROS_ETC_DIR=%CONDA_PREFIX%\Library\etc\ros"
@set "AMENT_PREFIX_PATH=%CONDA_PREFIX%\Library"
@set "AMENT_PYTHON_EXECUTABLE=%CONDA_PREFIX%\python.exe"
```

### 3.3 The chain behind it (catkin 0.8.12 + ros_environment 1.3.2 + roslaunch)

1. **`Library\local_setup.bat`** (201 B) runs `call <prefix>/Library/setup.bat --extend --local`.

2. **`Library\setup.bat`** (2,183 B, catkin `setup.bat.in`):
   - **sets `PYTHONHOME` to the python directory.** catkin_activate clears it again afterwards.
   - prepends `PYTHONHOME;PYTHONHOME\Scripts` to `PATH` if needed.
   - runs `python _setup_util.py --extend --local` and `call`s every line it prints. These are exports of `CMAKE_PREFIX_PATH`, `PATH`, `PKG_CONFIG_PATH` and `PYTHONPATH=<prefix>\Library\lib\site-packages`.
   - loops over `_CATKIN_ENVIRONMENT_HOOKS_*`.
   - ⚠️ contains `exit 22` (**without `/b`**) if `_setup_util.py` is missing. That would terminate the whole calling `cmd`, whether RoboStack's terminal or our launcher.

3. **Environment hooks** in `Library\etc\catkin\profile.d\`:
   - `1.ros_distro.bat` → `ROS_DISTRO=noetic`
   - `1.ros_etc_dir.bat` → `ROS_ETC_DIR=<prefix>/Library/etc/ros`
   - `1.ros_package_path.bat` → `ROS_PACKAGE_PATH` computed by `_parent_package_path.py` (the `Library\share` of each workspace)
   - `1.ros_python_version.bat` → `3`
   - `1.ros_version.bat` → `1`
   - `10.roslaunch.bat` → `if "%ROS_MASTER_URI%" == "" set ROS_MASTER_URI=http://localhost:11311`
   - `10.rosbuild.bat`

4. Conda/micromamba core activation also sets:
   - `CONDA_PREFIX`, `CONDA_DEFAULT_ENV`, `CONDA_SHLVL`, `CONDA_PROMPT_MODIFIER`
   - `PATH` = `<prefix>;<prefix>\Library\mingw-w64\bin;<prefix>\Library\usr\bin;<prefix>\Library\bin;<prefix>\Scripts;<prefix>\bin;<condabin>;…`

   pixi sets `CONDA_PREFIX`, `CONDA_DEFAULT_ENV`, `PATH` and `PIXI_*` instead.

### 3.4 How the commands resolve after activation (identical for all three tools and for us)

- **`rviz`** → `Library\bin\rviz.exe` (found on `PATH`).
- **`roscore`** → `Library\bin\roscore.exe` (48,640 B). This is catkin's `python_win32_wrapper`:
  - It reads the shebang of the sibling script `Library\bin\roscore`, which is `#!<prefix>\python.exe` after prefix relocation.
  - It falls back to `python.exe` on `PATH` if that file does not exist.
  - It runs `"python" "…\roscore" args` with `CreateProcess` and waits for it.
- **RoboStack's rviz patch** (`ros-noetic-rviz.patch`, `render_system.cpp`) loads OGRE plugins from `std::getenv("CONDA_PREFIX") + "\\Library\\bin\\"`.
  - With **no `CONDA_PREFIX`** this is `std::string(nullptr)`: undefined behaviour and in practice a crash.
  - So RoboStack's rviz.exe **only works from an activated environment**.
  - Our patch uses `RVIZ_OGRE_PLUGIN_DIR`, then `CONDA_PREFIX`, then the compile-time path, so it does not crash.

---

## 4. Our MSI side by side

### 4.1 Shortcuts (exact `Target` / `Arguments`, from `windows/rviz.wxs`)

| Shortcut | Target | Arguments | WorkingDirectory |
|---|---|---|---|
| RViz | `[INSTALLFOLDER]launchers\rviz.cmd` | – | INSTALLFOLDER |
| roscore | `[INSTALLFOLDER]launchers\roscore.cmd` | – | INSTALLFOLDER |
| ROS Noetic Shell | `[INSTALLFOLDER]launchers\ros_shell.cmd` | `--home` | INSTALLFOLDER |
| Third-party notices | `[INSTALLFOLDER]THIRD_PARTY_NOTICES.txt` | – | – |
| Desktop: RViz (ROS Noetic) | `[INSTALLFOLDER]launchers\rviz.cmd` | – | INSTALLFOLDER |

`INSTALLFOLDER` = `C:\opt\rviz\noetic\`. RoboStack has no equivalent of any of these.

### 4.2 `launchers\ros_env.bat` (1,791 B) compared with RoboStack activation

**What `ros_env.bat` does:**

1. Sets `RVIZ_ROOT` from its own location.
2. `PATH` = `%RVIZ_ROOT%;…\Library\mingw-w64\bin;…\Library\usr\bin;…\Library\bin;…\Scripts;…\bin;…\DLLs;…\Library\lib;…\launchers;%PATH%`. This is the same order as conda, plus `DLLs`, `Library\lib` and `launchers`, and without `condabin`.
3. Sets `CONDA_PREFIX=%RVIZ_ROOT%`.
4. Runs **every `etc\conda\activate.d\*.bat`**, i.e. the same five files RoboStack runs, including `ros-noetic-catkin_activate.bat`. Output goes to `>nul 2>&1`.
5. Then sets the ROS variables explicitly. These are authoritative, so the hook results do not matter.

**Variable by variable:**

| Variable | RoboStack value | Ours |
|---|---|---|
| `CONDA_PREFIX` | env prefix | `C:\opt\rviz\noetic` |
| `ROS_DISTRO` / `ROS_VERSION` / `ROS_PYTHON_VERSION` | `noetic` / `1` / `3` (hooks) | same (explicit) |
| `ROS_PACKAGE_PATH` | `_parent_package_path.py` → `<prefix>/Library/share` (forward slashes) | `C:\opt\rviz\noetic\Library\share` |
| `ROS_ETC_DIR` | `%CONDA_PREFIX%\Library\etc\ros` | same |
| `ROS_ROOT` | not set by catkin/ros_environment | `…\Library\share\ros` (extra; only rosbuild uses it) |
| `ROS_OS_OVERRIDE` | `conda:win64` | same |
| `ROS_MASTER_URI` | default `http://localhost:11311` if unset (roslaunch hook) | same rule |
| `CMAKE_PREFIX_PATH` | `<prefix>\Library` (`_setup_util`) | same |
| `PYTHONPATH` | `<prefix>\Library\lib\site-packages` | same |
| `PYTHONHOME` | cleared | cleared |
| `PYTHONNOUSERSITE` / `PYTHONDONTWRITEBYTECODE` | not set | `1` / `1` (extra: isolates from the user's `%APPDATA%\Python` site-packages; no `.pyc` writes into Program-Files-like prefix) |
| `QT_PLUGIN_PATH` | `%CONDA_PREFIX%\Library\plugins` | same |
| `RVIZ_OGRE_PLUGIN_DIR` | – | `…\Library\bin` (used by our patch) |
| `AMENT_*` | set (ROS 2 only, unused by Noetic) | not set (harmless) |
| `CONDA_DEFAULT_ENV`, `CONDA_SHLVL` | set | not set (nothing in rviz/roscore reads them) |

### 4.3 Launch logic

**RoboStack:** two manual terminals. The order and the master address are the user's responsibility.

**Ours (`rviz.cmd`, 3,688 B in `fc4e050`):**

- If `ROS_MASTER_URI` is `http://localhost:11311` or `http://127.0.0.1:11311` and `rosgraph.is_master_online()` is false:
  1. `start "roscore (started by RViz)" /min "%ComSpec%" /d /c ""…\roscore.cmd""`
  2. poll up to 60 s
  3. run `rviz.exe`
  4. when it exits, `taskkill /T /F` the PID from `%ROS_HOME%\roscore-11311.pid`
- A remote `ROS_MASTER_URI` is left alone.
- Since `fc4e050`, a non-zero exit code keeps the window open with the code and the log location.
- **`roscore.cmd`** is the TOOL_SHIM (751 B): it prefers `Library\bin\roscore.exe`, which is the same catkin wrapper a RoboStack user runs.

---

## 5. Findings and recommendations (code review)

### F1. Most likely cause of the teammate's "window flashes and closes" (Windows 11, v1.14.26-1)

**Shortcut execution path:**

- Explorer opens `.cmd` files with `cmd.exe /c "file.cmd"`, **without `/d`**.
- `cmd` therefore first runs `HKCU\…\Command Processor\AutoRun` and `HKLM\…\Command Processor\AutoRun`.
- `conda init cmd.exe` and `micromamba shell init -s cmd.exe` write exactly that value.
- A **stale or malformed AutoRun makes every new cmd exit at once** ("Process exited with code 1", "& was unexpected at this time"). This typically happens after an Anaconda/Miniconda uninstall or a moved micromamba. See [scivision](https://scivision.dev/windows-command-prompt-instant-fail) and [winhelponline](https://www.winhelponline.com/blog/cant-open-cmd-after-uninstalling-python-anaconda/).

**Why this fits:**

- It matches the recording: a blank terminal titled "RViz" closed within ~0.5 s, before our first `echo`.
- It also explains why CI never saw it: every CI and test invocation uses `cmd /d`.

**Why RoboStack users never hit this:** they type commands into a terminal that is already open. If AutoRun were broken, their terminal would not open in the first place, and they would notice.

**Check (teammate):**

```
reg query "HKCU\Software\Microsoft\Command Processor" /v AutoRun
reg query "HKLM\Software\Microsoft\Command Processor" /v AutoRun
```

**Fix (installer):** make the RViz, roscore and ROS Shell shortcuts start `cmd` with AutoRun disabled:

- `Target="[System64Folder]cmd.exe"`
- `Arguments='/d /c ""[INSTALLFOLDER]launchers\rviz.cmd""'` (and the same for the others)
- Keep `Icon="rviz.ico"`.

This removes the user's AutoRun from the launch path entirely.

### F2. Errors swallowed during activation

`ros_env.bat` calls the activate.d hooks with `>nul 2>&1`. conda, micromamba and pixi show those messages.

Recommendation: send them to a log file instead, for example `%LOCALAPPDATA%\RVizNoetic\activate.log`, and mention that path in the `rviz.cmd` failure message added in `fc4e050`.

### F3. `exit 22` in catkin's `setup.bat`

If `_setup_util.py` were ever missing, this line would kill the launcher's cmd silently, as in F1. It is present in our payload (13,622 B) and CI exercises it.

Recommendation: keep `_setup_util.py` in `REQUIRED_FILES` in `rvizmsi.py` so a future prune can never remove it.

### F4. PowerShell users of RoboStack (relevant for teammates comparing setups)

With conda or micromamba in PowerShell, ROS 1 variables are missing because catkin has no `.ps1`. Advise teammates who use RoboStack directly to:

- use `cmd`, or
- use pixi (activation runs via cmd), or
- run `cmd /c "%CONDA_PREFIX%\etc\conda\activate.d\ros-noetic-catkin_activate.bat && set"`-style workarounds.

Our MSI is unaffected.

### F5. `CONDA_PREFIX` dependency

RoboStack's rviz.exe crashes without `CONDA_PREFIX`; ours does not (patched fallback). We still set `CONDA_PREFIX`, because the activation hooks require it (`if not defined CONDA_PREFIX goto:eof`). Keep it.

### F6. pixi's template activation script

RoboStack's `pixi.toml` activates `install/setup.bat`, which is a colcon/ROS 2 layout. A Noetic catkin workspace produces `devel\setup.bat` or `install\setup.bat` only after a build. On a fresh project the referenced script does not exist yet. Irrelevant for running the stock rviz, but worth knowing if a teammate builds their own packages with pixi.

### F7. Things we do that RoboStack does not

These are deliberate. None changes which binaries run.

- fixed install prefix, shortcuts and PATH entry
- `PYTHONNOUSERSITE`
- roscore auto-start and auto-stop
- `RVIZ_OGRE_PLUGIN_DIR`

---

## 6. Next steps

1. Implement F1: shortcuts via `cmd.exe /d /c`. Optionally add a launcher self-check that prints a warning when AutoRun is set.
2. Implement F2: activation log file.
3. Ask the teammate for the two `reg query` results to confirm F1 before tagging `v1.14.26-3`.

### Sources

- RoboStack Getting Started (`RoboStack/robostack.github.io`, `docs/GettingStarted.md`), RoboStack FAQ (`docs/FAQ.md`)
- `RoboStack/vinca`: `vinca/templates/activate.bat.in`, `deactivate.bat.in`, `activate.ps1.in`, `bld_catkin.bat.in`, `vinca/template.py`
- `RoboStack/ros-noetic`: `patch/ros-noetic-rviz.patch`, `ros-noetic-catkin.patch`, `ros-noetic-catkin.win.patch`, `ros-noetic-ros-environment.patch`
- `ros/catkin` 0.8.12: `cmake/templates/setup.bat.in`, `local_setup.bat.in`, `env.bat.in`, `python_win32_wrapper.cpp.in`, `cmake/platform/windows.cmake`
- `ros/ros_environment` 1.3.2: `env-hooks/*.bat.*`; `ros/ros_comm` 1.17.4: `tools/roslaunch/env-hooks/10.roslaunch.bat`
- pixi environment docs: https://pixi.prefix.dev/dev/workspace/environment/
- Broken cmd AutoRun: https://scivision.dev/windows-command-prompt-instant-fail, https://www.winhelponline.com/blog/cant-open-cmd-after-uninstalling-python-anaconda/
- Our repo: `windows/rviz.wxs`, `windows/rvizmsi.py`, CI run 14 payload list
