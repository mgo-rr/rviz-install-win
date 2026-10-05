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
  foreach ($f in 'rviz.cmd', 'roscore.cmd', 'ros_env.bat', 'rospack.cmd') {
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
  }
  finally {
    foreach ($p in $procs) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null }
    Get-Process -Name rviz, rosmaster, rosout -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Prefix\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2                                 # release file locks before uninstall
  }

  # ---- Start menu path: rviz.cmd must bring up its own roscore when none runs ----
  # (dry run: everything rviz.cmd does except opening the rviz window)
  Write-Host '[test-install] rviz.cmd auto-starts and stops roscore (launcher dry run)'
  Check (-not ((Invoke-Batch "call `"$launchers\rosnode.cmd`" list") -match '/rosout')) 'a ROS master is still running before the launcher test'
  $env:RVIZ_LAUNCHER_DRYRUN = '1'
  try { $launch = Invoke-Batch "call `"$launchers\rviz.cmd`"" }
  finally { Remove-Item env:RVIZ_LAUNCHER_DRYRUN -ErrorAction SilentlyContinue }
  $launch | Set-Content "$LogDir\rviz-launcher.txt"
  if (-not ($launch -match 'roscore is up')) { Write-Host $launch }
  Check ($launch -match 'starting roscore' -and $launch -match 'roscore is up') 'rviz.cmd did not start a local roscore (see rviz-launcher.txt)'
  Check ($launch -match 'dry run: rviz.exe not started') 'rviz.cmd did not reach the rviz.exe step'
  Check ($launch -match 'stopping the roscore it started') 'rviz.cmd did not stop the roscore it started'
  Start-Sleep -Seconds 3
  Check (-not ((Invoke-Batch "call `"$launchers\rosnode.cmd`" list") -match '/rosout')) 'roscore started by rviz.cmd is still running after it exited'
  # never leave bundled processes behind (they would lock files during uninstall)
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Prefix\*" } | Stop-Process -Force -ErrorAction SilentlyContinue

  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  Check ($machinePath -like "*$launchers*") 'launchers folder was not added to the system PATH'

  $lnk = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
  Check (Get-ChildItem -Path $lnk -Recurse -Filter 'RViz.lnk') 'Start menu shortcut not found'
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
