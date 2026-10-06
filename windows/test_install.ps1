<#
  test_install.ps1 - install the MSI silently, exercise it, uninstall it.
  Must run elevated (per-machine MSI). Used by: build-rviz-msi.ps1 -TestInstall

  Exit codes: 0 ok, 1 failure, 2 not elevated, 3 prefix already in use.
#>
param(
  [Parameter(Mandatory)] [string]$Msi,
  [Parameter(Mandatory)] [string]$Prefix,
  [Parameter(Mandatory)] [string]$LogDir,
  # Skip opening the rviz window (no OpenGL-capable GPU, e.g. CI runners).
  [switch]$SkipGui
)
$ErrorActionPreference = 'Stop'
$env:RVIZ_NO_PAUSE = '1'   # rviz.cmd must never wait for a key press in this test

function Fail($msg) { Write-Host "[test-install] FAIL: $msg"; exit 1 }

# Print the end of a log file into the console, so a CI failure can be
# diagnosed from the job log alone (artifacts are a separate download).
function Show-Tail([string]$Path, [int]$Lines = 40) {
  if (Test-Path -LiteralPath $Path) {
    Write-Host "[test-install] ---- last $Lines lines of $(Split-Path -Leaf $Path) ----"
    Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
  }
  else { Write-Host "[test-install] ($(Split-Path -Leaf $Path) was not written)" }
}
function Check($cond, $msg) { if (-not $cond) { throw $msg } }

# Re-run a crashing program under cdb (Windows SDK debugger, preinstalled on
# GitHub's Windows runners) and print the stack at the first access violation
# plus loaded/unloaded modules. Batch code in $Setup prepares the environment.
function Show-CrashStack([string]$Exe, [string]$Setup, [int]$TimeoutSec = 180) {
  $cdb = @("${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
           "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\cdb.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $cdb) { Write-Host '[test-install] (cdb.exe not found; no stack trace)'; return }
  $out = Join-Path $LogDir ("{0}-cdb.txt" -f [IO.Path]::GetFileNameWithoutExtension($Exe))
  $tmp = Join-Path $env:TEMP ("rviz-cdb-{0}.cmd" -f [guid]::NewGuid())
  # -g: skip the initial breakpoint, so the commands run at the first exception
  $cmds = '.ecxr; kn 40; lm; q'
  Set-Content -Path $tmp -Encoding ASCII -Value "@echo off`r`n$Setup`r`n`"$cdb`" -g -G -c `"$cmds`" `"$Exe`" > `"$out`" 2>&1"
  $p = Start-Process -FilePath cmd.exe -ArgumentList '/d', '/c', "`"$tmp`"" -PassThru -WindowStyle Hidden
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    & cmd.exe /d /c "taskkill /T /F /PID $($p.Id) >nul 2>&1"
    Write-Host "[test-install] (no crash under cdb within $TimeoutSec s)"
  }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $out) {
    $text = Get-Content -LiteralPath $out
    $from = [Math]::Max(0, ($text | Select-String -Pattern 'Access violation|\(.*\): ' | Select-Object -First 1).LineNumber - 3)
    Write-Host "[test-install] ---- cdb: $(Split-Path -Leaf $Exe) (full log: $(Split-Path -Leaf $out)) ----"
    $text | Select-Object -Skip $from | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 120 | ForEach-Object { Write-Host "  $_" }
  }
}

# Windows Error Reporting's record of the latest crashes (faulting module and
# offset), so a crash with no output of its own can still be diagnosed.
function Show-CrashEvent([datetime]$Since) {
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; StartTime = $Since } -MaxEvents 3 -ErrorAction SilentlyContinue)
  if (-not $events) { Write-Host '[test-install] (no Application Error event recorded)'; return }
  foreach ($e in $events) {
    Write-Host "[test-install] ---- crash recorded at $($e.TimeCreated.ToString('HH:mm:ss')) ----"
    ($e.Message -split "`r?`n") | Where-Object { $_ } | Select-Object -First 12 | ForEach-Object { Write-Host "  $_" }
  }
}

# Run a snippet of batch code in a fresh cmd.exe and return its output.
# -Paths turns '/' into '\' for comparing printed file paths; it must not be
# used for ROS output, where '/rosout' would become '\rosout'.
function Invoke-Batch([string]$Body, [switch]$Paths) {
  $tmp = Join-Path $env:TEMP ("rviz-test-{0}.cmd" -f [guid]::NewGuid())
  Set-Content -Path $tmp -Value "@echo off`r`n$Body" -Encoding ASCII
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # native stderr is not an error
  try {
    $out = (& cmd.exe /d /c $tmp 2>&1 | Out-String)
    if ($Paths) { $out = $out -replace '/', '\' }
    return $out
  }
  finally { $ErrorActionPreference = $old; Remove-Item $tmp -Force }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host '[test-install] needs an elevated shell (Run as administrator).'
  exit 2
}
if (Test-Path $Prefix) {
  Write-Host "[test-install] $Prefix already exists - refusing to install over an existing copy."
  exit 3
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Invoke-Msi([string[]]$ArgList) {
  $p = Start-Process -FilePath msiexec.exe -ArgumentList $ArgList -Wait -PassThru
  return $p.ExitCode
}

Write-Host "[test-install] installing $Msi"
$rc = Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart', 'ADDLOCAL=ALL', '/l*v', "`"$LogDir\install.log`"")
if ($rc -ne 0 -and $rc -ne 3010) { Fail "msiexec /i returned $rc (see $LogDir\install.log)" }

$failure = $null
try {
  $launchers = Join-Path $Prefix 'launchers'
  foreach ($f in 'rviz.cmd', 'rviz-software.cmd', 'roscore.cmd', 'ros_env.bat', 'rospack.cmd') {
    Check (Test-Path (Join-Path $launchers $f)) "missing $f"
  }

  Write-Host '[test-install] rviz --help (installed copy)'
  $help = Invoke-Batch "call `"$launchers\rviz.cmd`" --help"
  $help | Set-Content "$LogDir\rviz-help.txt"
  Check ($help -match 'Produce this help message') 'installed rviz.exe did not start'

  Write-Host '[test-install] rospack find rviz (installed copy)'
  $found = (Invoke-Batch "call `"$launchers\rospack.cmd`" find rviz 2>nul" -Paths).Trim()
  Check ($found -like "$Prefix*") "rospack find rviz returned '$found'"

  Write-Host '[test-install] bundled python + rospy import'
  $py = (Invoke-Batch "call `"$launchers\ros_env.bat`"`r`npython -c `"import rospy, sys; print(sys.prefix)`" 2>nul" -Paths).Trim()
  Check ($py -like "$Prefix*") "bundled python/rospy check returned '$py'"

  # ---- live runtime: roscore from the bundle, then rviz connecting to it ----
  Write-Host '[test-install] roscore + rviz live check (bundled ROS runtime only)'
  $env:ROS_MASTER_URI = 'http://localhost:11311'
  $env:ROS_HOME = Join-Path $LogDir 'ros_home'          # keep logs out of the user profile
  $procs = @()
  try {
    $procs += Start-Process -FilePath cmd.exe -ArgumentList '/d', '/c', "`"$launchers\roscore.cmd`"" -PassThru -NoNewWindow `
      -RedirectStandardOutput "$LogDir\roscore.out.txt" -RedirectStandardError "$LogDir\roscore.err.txt"
    $master = $false
    $nodes = ''
    for ($i = 0; $i -lt 60 -and -not $master; $i++) {
      Start-Sleep -Seconds 2
      $nodes = Invoke-Batch "call `"$launchers\rosnode.cmd`" list"
      $master = $nodes -match '/rosout'
    }
    if (-not $master) {
      Write-Host "[test-install] roscore process running: $(-not $procs[0].HasExited)$(if ($procs[0].HasExited) { " (exit code $($procs[0].ExitCode))" })"
      Write-Host "[test-install] last 'rosnode list' output:"
      ($nodes -split "`r?`n" | Select-Object -Last 20) | ForEach-Object { Write-Host "  $_" }
      Show-Tail "$LogDir\roscore.out.txt"; Show-Tail "$LogDir\roscore.err.txt"
      $rosLogs = Join-Path $env:ROS_HOME 'log'
      Get-ChildItem -LiteralPath $rosLogs -Recurse -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 3 | ForEach-Object { Show-Tail $_.FullName 25 }
    }
    Check $master 'roscore did not come up (no /rosout node within 120 s; see roscore.*.txt)'

    $topics = Invoke-Batch "call `"$launchers\rostopic.cmd`" list 2>nul"
    Check ($topics -match '/rosout') "rostopic list does not show /rosout: $topics"

    if ($SkipGui) {
      Write-Host '[test-install] -SkipGui: not opening the rviz window (roscore/rostopic checked above)'
    }
    else {
    $procs += Start-Process -FilePath cmd.exe -ArgumentList '/d', '/c', "`"$launchers\rviz.cmd`"" -PassThru -NoNewWindow `
      -RedirectStandardOutput "$LogDir\rviz.out.txt" -RedirectStandardError "$LogDir\rviz.err.txt"
    $node = $false
    for ($i = 0; $i -lt 45 -and -not $node; $i++) {
      Start-Sleep -Seconds 2
      $node = (Invoke-Batch "call `"$launchers\rosnode.cmd`" list 2>nul") -match '/rviz'
    }
    if (-not $node) { Show-Tail "$LogDir\rviz.out.txt"; Show-Tail "$LogDir\rviz.err.txt" }
    Check $node 'rviz did not register with the master within 90 s (see rviz.*.txt; a GPU/OpenGL driver is required)'
    Start-Sleep -Seconds 10                                # let it load the default displays
    Check ($null -ne (Get-Process -Name rviz -ErrorAction SilentlyContinue)) 'rviz.exe exited after starting (see rviz.*.txt)'
    $rvizLog = (Get-Content "$LogDir\rviz.out.txt", "$LogDir\rviz.err.txt" -Raw -ErrorAction SilentlyContinue) -join "`n"
    Check (-not ($rvizLog -match 'failed to load|PluginlibFactory|Could not load|Ogre::.*Exception')) 'rviz reported plugin/OGRE load errors (see rviz.*.txt)'
    Write-Host '[test-install] roscore, rostopic and rviz (default displays) run from the bundle'
    }

    # ---- RViz (software rendering): Mesa llvmpipe needs no GPU, so this opens
    # a real rviz window even on CI runners. It must run Library\mesa\rviz.exe
    # with Mesa's opengl32.dll, and the default rviz.exe must not.
    Write-Host '[test-install] RViz (software rendering): rviz window with Mesa llvmpipe'
    Get-Process -Name rviz -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $swStart = Get-Date
    # --help exits before any OpenGL work: a crash here is a loader problem
    # (DLLs next to the copied rviz.exe), not a rendering one.
    $swHelp = Invoke-Batch "call `"$launchers\ros_env.bat`"`r`n`"%RVIZ_ROOT%\Library\mesa\rviz.exe`" --help >nul 2>&1`r`necho exit=%ERRORLEVEL%"
    Write-Host "[test-install]   Library\mesa\rviz.exe --help: $($swHelp.Trim())"
    $before = @((Invoke-Batch "call `"$launchers\rosnode.cmd`" list 2>nul") -split "`r?`n" | Where-Object { $_ -match '^/rviz' })
    $sw = "$LogDir\rviz-software"
    $procs += Start-Process -FilePath cmd.exe -ArgumentList '/d', '/c', "`"$launchers\rviz-software.cmd`"" -PassThru -NoNewWindow `
      -RedirectStandardOutput "$sw.out.txt" -RedirectStandardError "$sw.err.txt"
    $node = $false
    for ($i = 0; $i -lt 60 -and -not $node; $i++) {
      Start-Sleep -Seconds 2
      $now = @((Invoke-Batch "call `"$launchers\rosnode.cmd`" list 2>nul") -split "`r?`n" | Where-Object { $_ -match '^/rviz' })
      $node = @($now | Where-Object { $before -notcontains $_ }).Count -gt 0
    }
    if (-not $node) {
      Show-Tail "$sw.out.txt"; Show-Tail "$sw.err.txt"; Show-CrashEvent $swStart
      Show-CrashStack (Join-Path $Prefix 'Library\mesa\rviz.exe') "call `"$launchers\ros_env.bat`"`r`nset GALLIUM_DRIVER=llvmpipe"
    }
    Check $node 'software-rendering rviz did not register with the master within 120 s (see rviz-software.*.txt)'
    Start-Sleep -Seconds 15                                # let it render the default displays
    $rv = Get-Process -Name rviz -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $rv) {
      Show-Tail "$sw.out.txt"; Show-Tail "$sw.err.txt"; Show-CrashEvent $swStart
      Show-CrashStack (Join-Path $Prefix 'Library\mesa\rviz.exe') "call `"$launchers\ros_env.bat`"`r`nset GALLIUM_DRIVER=llvmpipe"
    }
    Check ($null -ne $rv) 'software-rendering rviz.exe exited after starting (see rviz-software.*.txt)'
    Check ($rv.Path -eq (Join-Path $Prefix 'Library\mesa\rviz.exe')) "rviz-software.cmd started $($rv.Path), not Library\mesa\rviz.exe"
    $gl = @($rv.Modules | Where-Object { $_.ModuleName -eq 'opengl32.dll' } | ForEach-Object { $_.FileName })
    Check ($gl.Count -eq 1 -and $gl[0] -eq (Join-Path $Prefix 'Library\mesa\opengl32.dll')) "software-rendering rviz uses opengl32.dll from '$($gl -join ', ')', not Library\mesa"
    $swText = (Get-Content "$sw.out.txt", "$sw.err.txt" -Raw -ErrorAction SilentlyContinue) -join "`n"
    Check ($swText -match 'OpenGl version') 'software-rendering rviz printed no OpenGL version (see rviz-software.*.txt)'
    Check (-not ($swText -match 'failed to load|PluginlibFactory|Could not load|Ogre::.*Exception')) 'software-rendering rviz reported plugin/OGRE load errors (see rviz-software.*.txt)'
    ($swText -split "`r?`n") | Where-Object { $_ -match 'software rendering|OpenGL device|OpenGl version' } | ForEach-Object { Write-Host "[test-install]   $($_.Trim())" }
    Write-Host '[test-install] software-rendering rviz runs and renders with Mesa from Library\mesa'
  }
  finally {
    # via cmd: under Windows PowerShell 5.1, `taskkill ... 2>&1` with
    # $ErrorActionPreference = 'Stop' throws on "process not found" (a launcher
    # that already exited), and that error would replace the real failure.
    foreach ($p in $procs) { & cmd.exe /d /c "taskkill /T /F /PID $($p.Id) >nul 2>&1" }
    Get-Process -Name rviz, rosmaster, rosout -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Prefix\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2                                 # release file locks before uninstall
  }

  # ---- Start menu path: rviz.cmd must bring up its own roscore when none runs ----
  # (dry run: everything rviz.cmd does except opening the rviz window)
  # The Start menu shortcut itself is executed (its exact target + arguments),
  # with a deliberately broken cmd AutoRun in place: a stale conda/micromamba
  # AutoRun makes every `cmd` without /d exit at once, which is how a Start menu
  # launch can flash and close. The shortcut must be immune to it.
  Write-Host '[test-install] Start menu RViz shortcut, with a broken cmd AutoRun, auto-starts and stops roscore (launcher dry run)'
  $menu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
  $rvizLnk = Get-ChildItem -Path $menu -Recurse -Filter 'RViz.lnk' | Select-Object -First 1
  Check $rvizLnk 'Start menu shortcut not found'
  $swLnk = Get-ChildItem -Path $menu -Recurse -Filter 'RViz (software rendering).lnk' | Select-Object -First 1
  Check $swLnk 'Start menu shortcut "RViz (software rendering)" not found'
  $swSc = (New-Object -ComObject WScript.Shell).CreateShortcut($swLnk.FullName)
  Check ($swSc.TargetPath -like '*\cmd.exe' -and $swSc.Arguments -match '^/d /c ' -and $swSc.Arguments -like "*$launchers\rviz-software.cmd*") "software-rendering shortcut is not 'cmd.exe /d /c ...rviz-software.cmd' ($($swSc.TargetPath) $($swSc.Arguments))"
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($rvizLnk.FullName)
  Write-Host "[test-install]   shortcut: $($sc.TargetPath) $($sc.Arguments)"
  Check ($sc.TargetPath -like '*\cmd.exe' -and (Test-Path -LiteralPath $sc.TargetPath)) "RViz shortcut does not start cmd.exe ($($sc.TargetPath))"
  Check ($sc.Arguments -match '^/d /c ' -and $sc.Arguments -like "*$launchers\rviz.cmd*") "RViz shortcut arguments are not '/d /c ...rviz.cmd' ($($sc.Arguments))"
  Check (-not ((Invoke-Batch "call `"$launchers\rosnode.cmd`" list") -match '/rosout')) 'a ROS master is still running before the launcher test'
  $autoRunKey = 'HKCU:\Software\Microsoft\Command Processor'
  $oldAutoRun = (Get-ItemProperty -Path $autoRunKey -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
  if (-not (Test-Path $autoRunKey)) { New-Item -Path $autoRunKey -Force | Out-Null }
  Set-ItemProperty -Path $autoRunKey -Name AutoRun -Value 'exit 1'
  $env:RVIZ_LAUNCHER_DRYRUN = '1'
  try {
    $p = Start-Process -FilePath $sc.TargetPath -ArgumentList $sc.Arguments -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput "$LogDir\rviz-launcher.txt" -RedirectStandardError "$LogDir\rviz-launcher.err.txt"
    $launch = (Get-Content "$LogDir\rviz-launcher.txt", "$LogDir\rviz-launcher.err.txt" -Raw -ErrorAction SilentlyContinue) -join "`n"
  }
  finally {
    Remove-Item env:RVIZ_LAUNCHER_DRYRUN -ErrorAction SilentlyContinue
    if ($null -eq $oldAutoRun) { Remove-ItemProperty -Path $autoRunKey -Name AutoRun -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $autoRunKey -Name AutoRun -Value $oldAutoRun }
  }
  if (-not ($launch -match 'roscore is up')) { Write-Host $launch }
  Check ($p.ExitCode -eq 0) "Start menu shortcut command exited with $($p.ExitCode) (see rviz-launcher*.txt)"
  Check ($launch -match 'starting roscore' -and $launch -match 'roscore is up') 'rviz.cmd did not start a local roscore (see rviz-launcher.txt)'
  Check ($launch -match 'dry run: rviz.exe not started') 'rviz.cmd did not reach the rviz.exe step'
  Check ($launch -match 'stopping the roscore it started') 'rviz.cmd did not stop the roscore it started'
  $actLog = Join-Path $env:LOCALAPPDATA 'RVizNoetic\activate.log'
  Check ((Test-Path -LiteralPath $actLog) -and ((Get-Content -LiteralPath $actLog -Raw) -match 'ros-noetic-catkin_activate\.bat')) "activation log not written ($actLog)"
  Start-Sleep -Seconds 3
  Check (-not ((Invoke-Batch "call `"$launchers\rosnode.cmd`" list") -match '/rosout')) 'roscore started by rviz.cmd is still running after it exited'
  # never leave bundled processes behind (they would lock files during uninstall)
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Prefix\*" } | Stop-Process -Force -ErrorAction SilentlyContinue

  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  Check ($machinePath -like "*$launchers*") 'launchers folder was not added to the system PATH'


}
catch { $failure = "$_" }
finally {
  Write-Host '[test-install] uninstalling'
  $rcx = Invoke-Msi @('/x', "`"$Msi`"", '/qn', '/norestart', '/l*v', "`"$LogDir\uninstall.log`"")
  if ($rcx -ne 0 -and $rcx -ne 3010) { $failure = "$failure; msiexec /x returned $rcx" }
}
if ($failure) { Fail $failure }

if (Test-Path $Prefix) { Fail "$Prefix still exists after uninstall" }
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -like "*$Prefix*") { Fail 'system PATH still references the install prefix' }

Write-Host '[test-install] install / run / uninstall cycle passed'
exit 0
