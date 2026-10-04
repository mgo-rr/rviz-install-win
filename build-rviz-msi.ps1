<#
.SYNOPSIS
    Build RViz (ROS 1 Noetic) from the GitHub source into a Windows x64 MSI.

.DESCRIPTION
    One PowerShell script drives the whole build; no bash, WSL or batch-file
    layer is involved. The steps are:

      preflight     Windows x64, Visual Studio 2022 C++ tools, disk space, and
                    Git for Windows (Git Bash) - installed from the official
                    release page if missing (asks first unless -InstallGit).
      tools         micromamba (SHA-256 pinned), a private .NET SDK and WiX 5,
                    all inside -WorkDir.
      source        git clone of rviz at the pinned tag + commit; Windows patch.
      env           conda environment from RoboStack + conda-forge (rviz's build
                    and runtime dependencies), with a reproducible lock file.
      build         MSVC + CMake/Ninja; rviz installed into the environment.
      pack          conda-pack relocates the environment to -Prefix.
      finalize      license notices, prune build-only files, verify every ROS
                    package and DLL rviz/roscore need, launchers, icon/license.
      smoke         run the staged rviz.exe and rospack.
      msi           WiX build, ICE validation, optional signing, SHA-256.
      test-install  optional (-TestInstall): install, run roscore + rviz,
                    uninstall.

    Steps are resumable: a re-run skips steps whose inputs did not change.
    Pinned defaults live in config\build.psd1.

.PARAMETER WorkDir
    Build directory: an absolute Windows path without spaces (default C:\rvb).

.PARAMETER Prefix
    Fixed install location baked into the MSI (default C:\opt\rviz\noetic).

.PARAMETER Manufacturer
    MSI manufacturer / registry key name (default "RViz MSI Builder").

.PARAMETER BuildNumber
    Packaging revision 0-99 -> MSI version <major>.<minor>.<patch*100+N>.

.PARAMETER OutputDir
    Folder that receives the MSI, its .sha256, the lock file and payload list
    (default: .\dist next to this script).

.PARAMETER RvizRef
    rviz tag, branch or commit (default 1.14.26). Disables the pinned-commit check.

.PARAMETER RvizRepo
    rviz git URL (default: upstream ros-visualization/rviz).

.PARAMETER NoCommitCheck
    Do not verify the rviz tag against the pinned commit.

.PARAMETER LockFile
    Re-create the conda environment from the lock file of an earlier build.

.PARAMETER ExtraPackages
    Additional conda packages to ship, e.g. ros-noetic-rviz-imu-plugin.

.PARAMETER NoPythonBindings
    Skip rviz's sip/PyQt bindings.

.PARAMETER Jobs
    Parallel compile jobs (default: all cores).

.PARAMETER FromStep
    Re-run this step and all later ones.

.PARAMETER OnlyStep
    Run a single step (earlier steps must have completed before).

.PARAMETER Clean
    Wipe the work dir first (keeps downloaded tools and the package cache).

.PARAMETER KeepPdb
    Keep .pdb debug symbols in the payload.

.PARAMETER SkipSmoke
    Skip the pre-packaging smoke test.

.PARAMETER SkipValidate
    Skip ICE validation of the MSI.

.PARAMETER TestInstall
    After building, install the MSI, run roscore + rviz from it and uninstall
    (requires an elevated PowerShell).

.PARAMETER HeadlessTest
    With -TestInstall: skip the part that opens the rviz window (for machines
    without an OpenGL-capable GPU, such as CI runners). roscore, rostopic,
    rospack and the bundled Python are still tested from the installed copy.

.PARAMETER SignThumbprint
    Authenticode-sign the MSI with this certificate from the Windows store.

.PARAMETER SignPfx
    Sign with a .pfx file; put the password in $env:SIGN_PFX_PASSWORD.

.PARAMETER TimestampUrl
    RFC 3161 timestamp server used when signing.

.PARAMETER IconFile
    Custom .ico for shortcuts and Apps & features (default: rviz's icon).

.PARAMETER InstallGit
    Install Git for Windows without prompting if it is missing.

.PARAMETER NoInstallGit
    Never install Git for Windows; fail instead.

.PARAMETER CheckOnly
    Report what was detected (PowerShell, Windows, Visual Studio, Git Bash,
    disk) and the effective configuration. Builds nothing.

.PARAMETER ConfigFile
    Alternative configuration file (default config\build.psd1).

.EXAMPLE
    .\build-rviz-msi.ps1 -CheckOnly

.EXAMPLE
    .\build-rviz-msi.ps1 -BuildNumber 1 -Manufacturer "Relay Robotics"

.EXAMPLE
    .\build-rviz-msi.ps1 -ExtraPackages ros-noetic-rviz-imu-plugin -FromStep env

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-rviz-msi.ps1 -InstallGit -BuildNumber 2

.NOTES
    Requires Windows 10/11 x64, Windows PowerShell 5.1 or PowerShell 7, and
    Visual Studio 2022 (or Build Tools) with the C++ workload.
#>
[CmdletBinding()]
param(
    [string]$WorkDir,
    [string]$Prefix,
    [string]$Manufacturer,
    [ValidateRange(0, 99)] [int]$BuildNumber,
    [string]$OutputDir,
    [string]$RvizRef,
    [string]$RvizRepo,
    [switch]$NoCommitCheck,
    [string]$LockFile,
    [string[]]$ExtraPackages,
    [switch]$NoPythonBindings,
    [ValidateRange(0, 1024)] [int]$Jobs,
    [ValidateSet('tools', 'source', 'env', 'build', 'pack', 'finalize', 'smoke', 'msi', 'test-install')]
    [string]$FromStep,
    [ValidateSet('tools', 'source', 'env', 'build', 'pack', 'finalize', 'smoke', 'msi', 'test-install')]
    [string]$OnlyStep,
    [switch]$Clean,
    [switch]$KeepPdb,
    [switch]$SkipSmoke,
    [switch]$SkipValidate,
    [switch]$TestInstall,
    [switch]$HeadlessTest,
    [string]$SignThumbprint,
    [string]$SignPfx,
    [string]$TimestampUrl,
    [string]$IconFile,
    [switch]$InstallGit,
    [switch]$NoInstallGit,
    [switch]$CheckOnly,
    [string]$ConfigFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows\RvizMsi.Build.ps1')

# Resolve a user-supplied path against PowerShell's current location (5.1 does
# not keep the process working directory in sync with Set-Location).
function Resolve-UserPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function New-BuildContext([hashtable]$Bound, [string]$RepoRoot) {
    $cfgPath = if ($Bound.ContainsKey('ConfigFile')) { Resolve-UserPath $Bound.ConfigFile } else { Join-Path $RepoRoot 'config\build.psd1' }
    $config = Merge-BuildConfig (Read-BuildConfig $cfgPath) $Bound
    Assert-BuildConfig $config
    $paths = Get-BuildPath $config $RepoRoot
    $out = if ($Bound.ContainsKey('OutputDir')) { Resolve-UserPath $Bound.OutputDir } else { Join-Path $RepoRoot 'dist' }
    $lock = if ($Bound.ContainsKey('LockFile')) { Resolve-UserPath $Bound.LockFile } else { '' }
    if ($lock -and -not (Test-Path -LiteralPath $lock)) { throw "lock file not found: $lock" }
    foreach ($k in 'SignPfx', 'IconFile') { if ($config[$k]) { $config[$k] = Resolve-UserPath $config[$k] } }
    return @{
        Config = $config; Paths = $paths; OutputDir = $out; LockFile = $lock
        FromStep = [string]$Bound['FromStep']; OnlyStep = [string]$Bound['OnlyStep']
        SkipSmoke = [bool]$Bound['SkipSmoke']; SkipValidate = [bool]$Bound['SkipValidate']; TestInstall = [bool]$Bound['TestInstall']; HeadlessTest = [bool]$Bound['HeadlessTest']
        HostInfo = $null; Git = $null; RvizVersion = ''; MsiVersion = ''; MsiName = ''
    }
}

function Show-CheckOnly($Ctx) {
    $h = $Ctx.HostInfo; $C = $Ctx.Config
    Write-Step 'Environment'
    Write-Info ("PowerShell     : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    Write-Info ("Windows        : {0} build {1}, x64={2}, {3} CPUs" -f $h.WindowsName, $h.WindowsBuild, $h.Is64Bit, $h.Cpus)
    Write-Info ("Elevated       : {0}" -f $h.IsAdmin)
    if ($h.VisualStudio) { Write-Info "Visual Studio  : $($h.VisualStudio.Name) $($h.VisualStudio.Version)" }
    else { Write-Info 'Visual Studio  : NOT FOUND (install VS 2022 Build Tools with the C++ workload)' }
    if ($h.Git) { Write-Info "Git Bash       : $($h.Git.Bash)"; Write-Info "git            : $($h.Git.Git)" }
    else { Write-Info 'Git Bash       : NOT FOUND (would be offered for install)' }
    Write-Info ("Disk           : {0} GB free on {1} (need {2})" -f $h.FreeGB, $C.WorkDir.Substring(0, 2), $C.MinFreeGB)
    Write-Info ("Long paths     : {0}" -f $h.LongPaths)
    Write-Step 'Configuration'
    foreach ($k in 'WorkDir', 'InstallPrefix', 'ProductName', 'Manufacturer', 'RvizRef', 'RvizCommit', 'BuildNumber', 'WixVersion') {
        Write-Info ("{0,-14} : {1}" -f $k, $C[$k])
    }
    Write-Info ("{0,-14} : {1}" -f 'OutputDir', $Ctx.OutputDir)
}

function Invoke-Main([hashtable]$Bound, [string]$RepoRoot) {
    try { $ctx = New-BuildContext $Bound $RepoRoot }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; return 1 }
    $P = $ctx.Paths
    if ($RepoRoot -match '\s') { Write-Warn 'The repository path contains spaces; that is fine, but WorkDir must not.' }
    $ctx.HostInfo = Get-HostInfo $ctx.Config.WorkDir
    if ($Bound.ContainsKey('CheckOnly') -and $Bound.CheckOnly) { Show-CheckOnly $ctx; return 0 }

    if ($Bound.ContainsKey('Clean') -and $Bound.Clean) { Clear-WorkDir $P }
    New-Item -ItemType Directory -Force -Path $P.Work, $P.Out | Out-Null
    $log = Join-Path $P.Out ('build-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Start-BuildLog $log
    try {
        Write-Info "log file: $log"
        $ctx.Git = Resolve-Git ([bool]$Bound['InstallGit']) ([bool]$Bound['NoInstallGit'])
        $env:DOTNET_ROOT = $P.Dotnet
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        $env:DOTNET_NOLOGO = '1'
        $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
        Invoke-Pipeline $ctx
        return 0
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-LogLine "ERROR: $($_.Exception.Message)"
        Write-LogLine $_.ScriptStackTrace
        Write-Host "Full log: $log"
        return 1
    }
    finally { Stop-BuildLog }
}

# Run only when executed, not when dot-sourced by the tests.
if ($MyInvocation.InvocationName -ne '.') {
    # Take the last pipeline value only, in case a step leaks output.
    try { $code = [int](Invoke-Main (@{} + $PSBoundParameters) $PSScriptRoot | Select-Object -Last 1) }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; $code = 1 }
    exit $code
}
