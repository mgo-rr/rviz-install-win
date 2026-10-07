# CLAUDE.md: rviz-install-win

Context for Claude Code sessions in this repository. The project started in a
Claude (Cowork) chat; this file carries over what a new session needs to know.
Keep it current when decisions change.

## What this is

A PowerShell build (`build-rviz-msi.ps1`, steps in `windows/RvizMsi.Build.ps1`)
that compiles **RViz 1.14.26 (ROS 1 Noetic)** from upstream source with MSVC.
It bundles a private ROS Noetic runtime from **RoboStack** (conda) and produces
a self-contained **x64 MSI** (WiX 5.0.2) that installs to the fixed prefix
`C:\opt\rviz\noetic`.

- Target users: the Relay Robotics Robo Care Team (Windows 10/11).
- Public repo: https://github.com/mgo-rr/rviz-install-win (BSD-3-Clause).
- Releases at `/releases/latest` contain only the MSI and its `.sha256`.

Pipeline steps:

1. tools
2. source (git tag + pinned commit + `patches/1.14.26/*.patch`)
3. env (micromamba, `robostack-noetic` + `conda-forge`, strict priority)
4. build (CMake/Ninja)
5. pack (conda-pack `--format tar`, unpacked with Windows `tar.exe`)
6. finalize (`windows/rvizmsi.py`: prune, licenses, ROS-package + DLL closure check, launchers, manifest)
7. smoke
8. msi
9. test-install

## Conventions

- Commit author and committer: `Robo Care Support Team <support@relayrobotics.com>` (public repo: no personal details; set in the repo-local git config). Earlier commits keep Mahal's personal address (history is not rewritten).
- Multi-line commit messages via a quoted heredoc (`git commit -F - <<'MSG'`), never `-m`.
- Messages explain why, what was tried and what is still unproven.
- End every commit message with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- Push only when Mahal says so. He has been pushing himself (`git push`).
- Tags `v*` publish a GitHub Release through CI.
- Line endings follow `.gitattributes`: ps1/psd1/wxs are CRLF; py/txt/md/yml are LF.

## Tests (run before every commit)

```
pwsh -NoProfile -File tests/Test-Build.ps1     # 103 checks, stubbed tools, PS 5.1 + 7
python -m pytest -q tests                      # 27 passed, 1 skipped (PE sample test needs Windows DLLs)
python tests/check_wxs_schema.py <wix-v5.0.2 source checkout>
git -C <rviz 1.14.26 clone> apply --check patches/1.14.26/0001-windows-msvc-relocatable.patch
```

CI (`.github/workflows/ci.yml`, windows-2022):

- `checks` job: all of the above.
- `build` job: full MSI build plus `-TestInstall -HeadlessTest`, about 30 min.
- `release` job: on `v*` tags only.

`.github/workflows/env-benchmark.yml` (manual) times micromamba vs pixi vs conda for the env step.

## Hard-won facts (do not regress)

**Windows PowerShell 5.1:**

- It drops empty native arguments and doesn't escape embedded quotes.
- `$IsWindows` / `$IsLinux` do not exist.
- Variable names are case-insensitive.
- All external programs go through `Invoke-Native` / `Invoke-NativeCapture`.

**Build:**

- catkin's install `.bat` does a plain `cd` (no `/d`), so CMake must run from the source dir (same drive).
- conda-pack `no-archive` (hardlinks) died silently at ~10k files on CI. We pack to `tar` and unpack with `tar.exe`.

**Patch fixes for conda-forge/RoboStack on MSVC:**

- OGRE bare library names
- `yaml-cpp::yaml-cpp` (0.8.0 config bug)
- Boost lib dir for the sip/qmake link (header autolinking)
- `RVIZ_EXPORT` on every property class with a templated constructor (String, Float, Int, Color, Quaternion, Enum, EditableEnum, DisplayVisibility, DisplayGroupVisibility). Otherwise MSVC compiles the constructor into rviz_default_plugin with the import thunk's address as vtable, and rviz.exe crashes at start-up: 0xC0000005 in `Qt5Core_conda!QObjectPrivate::connectImpl+0x2b2` (offset 0x1e1922) from `rviz::InitialPoseTool::InitialPoseTool`. Releases v1.14.26-1..-4 and RoboStack's own win-64 rviz 1.14.26 build 24 have this crash (proved with `robostack-rviz-check.yml` + cdb). pytest guards the hunks.
- Null check `rend &&` in `SelectionManager::handleSchemeNotFound` (selection_manager.cpp:1056, unfixed upstream). On Mesa (llvmpipe and the D3D12 Compatibility Pack) the Sphere/FlatSquare point cloud materials log `No techniques available`; OGRE then calls the handler with rend == nullptr and rviz crashed in `OgreMain!Ogre::UserObjectBindings::getUserAny` (offset 0x21daea) during bag playback. test-install renders a cloud in both styles with rviz-software.
- `ros_env.bat` defaults `OPENBLAS_NUM_THREADS=1` (keeps a user value). With the D3D12 Compatibility Pack and the ops layout, rviz.exe crashed in `openblas.dll` (offset 0x27e390, right after `blas_thread_init`, at a function's first `push`) when the camera displays loaded OpenCV; with the variable set, the same layout loaded fine (one run, 2026-10-07). Still open: Mesa rejects `indexed_8bit_image` (map displays not drawn: `active samplers with a different type refer to the same texture image unit`) and has no technique for the Sphere/FlatSquare point cloud styles, which logs two errors per point cloud message.

**Packages:**

- `libblas=*=*openblas` saves ~540 MiB of MKL.
- Do **not** pin `libopencv=*=headless*`: no headless build matches current RoboStack, and the solver silently fell back to Python 3.11 and older ROS builds.
- `python 3.12.*` is pinned to catch that.
- `image_transport.dll` lives in `Library\lib`, so `Library\lib` and `DLLs` are on the launcher PATH.

**Launchers** (`ROS_ENV_BAT`, `RVIZ_CMD`, `TOOL_SHIM` in `windows/rvizmsi.py`):

- `rviz.cmd` auto-starts a local roscore only for the default `localhost:11311` master and stops only the one it started (PID from `%ROS_HOME%\roscore-11311.pid`).
- It keeps the window open on failure (skipped for `--help` and `RVIZ_NO_PAUSE=1`).
- Shortcuts run `cmd.exe /d /c ""<launcher>""`. `/d` skips cmd AutoRun; a stale conda/micromamba AutoRun makes every plain `cmd` exit at once.
- `/d` does not reach child cmds: catkin's `setup.bat` uses `FOR /F`, whose subshell runs AutoRun. If AutoRun exits, `if 0 LSS  (` is a syntax error and the launcher dies with 255 and no output. `ros_env.bat` presets `_CATKIN_ENVIRONMENT_HOOKS_COUNT=0` to survive that (test-install sets `AutoRun=exit 1`).
- Activation hook output goes to `%LOCALAPPDATA%\RVizNoetic\activate.log`.
- Software rendering (`rviz-software.cmd`, Start menu *RViz (software rendering)*): conda `mesa-llvmpipe`. finalize moves Mesa's `opengl32.dll` + `libgallium_wgl.dll` from `Library\bin` to `Library\mesa` next to a copy of `rviz.exe` (+ `qt.conf`); Windows loads opengl32 from the exe's folder first, so Mesa next to `Library\bin\rviz.exe` would replace the GPU driver for everyone (finalize refuses that). OGRE 1.10 loads plugins with `LoadLibraryEx(name, NULL, 0)` (standard search), so `RenderSystem_GL.dll` stays in `Library\bin`. test-install opens a real rviz window with it on CI and checks the loaded `opengl32.dll` path.
- `rosbag.cmd` (TOOL_SHIM runs the extension-less `Library\bin\rosbag` script with the bundled python) is for bag review: roscore shortcut, `rosparam set use_sim_time true`, `rviz`, then `rosbag play --clock --pause <_0.bag> <_1.bag>` (README "Reviewing a bag file"). `rosbag.cmd play` goes through `launchers\rosbag_play.py` (source `windows/rosbag_play.py`): it runs `rosbag play` (RoboStack's unsigned `Library\lib\rosbag\play.exe`) and, on WinError 4551/1260 (Smart App Control blocks play.exe; seen on a teammate's personal Windows 11 laptop where rviz.exe and python.exe ran), falls back to a Python player that publishes raw bytes with the bag's types and latching plus `/clock`. `RVIZ_BAG_PLAYER=python` forces it. test-install writes a bz2-chunked bag (the Admin Portal's requested-bag format), runs `rosbag info` + `play`, and checks a listener gets all 5 messages and `/clock` from the forced Python player. The ops RViz layout (`savibot_vis/config/ops_rviz_simplified.rviz`, private `savioke/relay-ros`) is not shipped in this public repo.
- Never use `timeout` in launchers (it fails without a console); use `ping -n 2 127.0.0.1`.

**CI quirks:**

- Hosted runners have no OpenGL, so the rviz window is never tested in CI.
- Each XML-RPC call on the runner takes ~4 s (host name resolution).

**RoboStack comparison** (`docs/robostack-windows-launch-comparison.md`):

- Same binaries and same activation scripts (byte sizes match vinca templates).
- RoboStack itself has no shortcuts.
- conda/micromamba in PowerShell do not set the ROS 1 environment, because catkin has no `.ps1`.

## Current state / next steps (2026-10-08)

- Releases: `v1.14.26-6` is the first stable public release (`/releases/latest`). `v1.14.26-1` to `-4` crashed at RViz start-up (missing `RVIZ_EXPORT`, see above); `-5` (export fix, software rendering, signed MSI) could still crash during bag review (OpenBLAS with camera displays; handleSchemeNotFound on Mesa). All their GitHub Releases and tags were deleted (2026-10-06 and 2026-10-08) at Mahal's request. Never reuse a tag number. `-6` adds: `rosbag.cmd` with the Python fallback player (Smart App Control), the handleSchemeNotFound null check, `OPENBLAS_NUM_THREADS=1`, README "Reviewing a bag file". Verified by Mahal 2026-10-08 in the KVM VM: ops layout + a real delivery bag played through in both RViz and RViz (software rendering).
- Verified 2026-10-06 in a QEMU/KVM Windows 11 VM: the normal *RViz* shortcut renders through Microsoft's OpenCL/OpenGL/Vulkan Compatibility Pack (D3D12, OpenGL 4.6), and *RViz (software rendering)* renders with llvmpipe (LLVM 22.1.8, OpenGL 4.6). CI opens a real rviz window with Mesa on every build.
- Open issue: a teammate's Start menu RViz (Windows 11, v1.14.26-1) flashed and closed. Likely this start-up crash rather than AutoRun; ask them to try `v1.14.26-6`. The AutoRun `reg query` is still useful.
- Open question: the same teammate reported the installer "asked for installation with Conda". Nothing in the MSI or launchers does that (the license screen only mentions RoboStack / conda-forge). Waiting for a screenshot or the exact wording.
- Upstream (later, Mahal's call): report the stack trace and the `RVIZ_EXPORT` fix on RoboStack/ros-noetic#534 or as a PR to their `patch/ros-noetic-rviz.patch`.
- Cosmetic: OGRE's hidden helper window shows as "OgreWindow(0)" in the taskbar.
- Not yet verified on a real PC with a GPU: the rviz window itself, opened from the Start menu.
- QEMU/KVM with virtio 3D gives Windows guests no OpenGL of their own: use the software-rendering shortcut or the Compatibility Pack.
- Code signing (every release from v1.14.26-6): internal self-signed cert `certs/robo-care-code-signing.cer` (SHA-1 `F8CB7F5A10EBE5DDC4F2CDCBCE3598E0FF97899F`, valid to 2031-10-06). CI secrets `SIGN_PFX_BASE64` / `SIGN_PFX_PASSWORD`; a `v*` tag fails without them. The private key exists only in those secrets and in one backup kept by the Robo Care Team; never recreate, move or delete it without asking Mahal. IT must deploy the .cer to Root + TrustedPublisher (docs/code-signing.md). SmartScreen can still warn on browser downloads; Intune deployment avoids it.
- Env benchmark (run 37421285797, windows-2022, one sample each), total cold seconds: micromamba 218, pixi via prefix.dev 223, conda (Miniforge) 307, pixi via conda.anaconda.org 504. Same python/ogre/qt/libblas/roscpp builds; pixi installs 297 packages vs 299 (difference not checked). Decision: stay on micromamba. The download host matters more than the tool.
