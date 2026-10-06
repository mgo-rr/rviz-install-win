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

- Commit author: `Mahalalel Dan Go <mgo@relayrobotics.com>`.
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
python -m pytest -q tests                      # 17 passed, 1 skipped (PE sample test needs Windows DLLs)
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

**Packages:**

- `libblas=*=*openblas` saves ~540 MiB of MKL.
- Do **not** pin `libopencv=*=headless*`: no headless build matches current RoboStack, and the solver silently fell back to Python 3.11 and older ROS builds.
- `python 3.12.*` is pinned to catch that.
- `image_transport.dll` lives in `Library\lib`, so `Library\lib` and `DLLs` are on the launcher PATH.

**Launchers** (`ROS_ENV_BAT`, `RVIZ_CMD`, `TOOL_SHIM` in `windows/rvizmsi.py`):

- `rviz.cmd` auto-starts a local roscore only for the default `localhost:11311` master and stops only the one it started (PID from `%ROS_HOME%\roscore-11311.pid`).
- It keeps the window open on failure (skipped for `--help` and `RVIZ_NO_PAUSE=1`).
- Shortcuts run `cmd.exe /d /c ""<launcher>""`. `/d` skips cmd AutoRun; a stale conda/micromamba AutoRun makes every plain `cmd` exit at once.
- Activation hook output goes to `%LOCALAPPDATA%\RVizNoetic\activate.log`.
- Never use `timeout` in launchers (it fails without a console); use `ping -n 2 127.0.0.1`.

**CI quirks:**

- Hosted runners have no OpenGL, so the rviz window is never tested in CI.
- Each XML-RPC call on the runner takes ~4 s (host name resolution).

**RoboStack comparison** (`docs/robostack-windows-launch-comparison.md`):

- Same binaries and same activation scripts (byte sizes match vinca templates).
- RoboStack itself has no shortcuts.
- conda/micromamba in PowerShell do not set the ROS 1 environment, because catkin has no `.ps1`.

## Current state / next steps (2026-10-06)

- Releases: `v1.14.26-1`, `v1.14.26-2`. The next release `v1.14.26-3` should include the launcher hardening (window stays open, `cmd /d` shortcuts, activation log). Tag it after `main` CI is green.
- Open issue: a teammate's Start menu RViz (Windows 11, v1.14.26-1) flashed and closed. Suspected cause: a stale cmd AutoRun. Waiting for `reg query "HKCU\Software\Microsoft\Command Processor" /v AutoRun` (and HKLM).
- Not yet verified on a real PC with a GPU: the rviz window itself, opened from the Start menu.
- Benchmark: run `gh workflow run env-benchmark.yml` and read the summary table. Switching from micromamba only pays off if the difference is significant; the rest of the build takes about 24 min whichever tool is used.
