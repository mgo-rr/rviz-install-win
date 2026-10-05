<#
  RvizMsi.Build.ps1 - build library for build-rviz-msi.ps1 (dot-sourced).

  Every step of the pipeline is a function here. External programs are only
  started through Invoke-Native / Invoke-NativeCapture / Invoke-BatchSnippet,
  so the whole pipeline can be dry-run with stub tools (tests/Test-Build.ps1).

  Steps (in order):
    preflight  host checks, Git for Windows (Git Bash) pre-check
    tools      micromamba (SHA-256 pinned), private .NET SDK, WiX
    source     git clone rviz at the pinned tag/commit, apply patches
    env        conda environment from RoboStack + conda-forge, lock file
    build      MSVC + CMake/Ninja, install rviz into the environment
    pack       conda-pack, relocate prefixes to the install path
    finalize   notices, strip/prune, dependency checks, launchers, assets
    smoke      run the staged rviz.exe / rospack
    msi        WiX build, ICE validation, optional signing, checksums
    test-install  optional install/run/uninstall cycle (elevated)
#>

Set-StrictMode -Version 2.0

$script:Steps = @('preflight', 'tools', 'source', 'env', 'build', 'pack', 'finalize', 'smoke', 'msi', 'test-install')
$script:GitReleaseApi = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
$script:GitReleasePage = 'https://github.com/git-for-windows/git/releases/latest'
$script:GitSigner = 'Johannes Schindelin'   # publisher of the official Git for Windows binaries
$script:UserAgent = 'rviz-msi-builder (PowerShell)'
$script:LogWriter = $null

# =============================================================================
# Logging
# =============================================================================
function Write-LogLine([string]$Text) {
    if ($script:LogWriter) { $script:LogWriter.WriteLine($Text) }
}
function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Green
    Write-LogLine "==> $Message"
}
function Write-Info([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    Write-LogLine $line
}
function Write-Warn([string]$Message) {
    Write-Warning $Message
    Write-LogLine "WARNING: $Message"
}
function Start-BuildLog([string]$Path) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $script:LogWriter = New-Object System.IO.StreamWriter($Path, $true, (New-Object System.Text.UTF8Encoding($false)))
    $script:LogWriter.AutoFlush = $true
}
function Stop-BuildLog {
    if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null }
}

# =============================================================================
# Running external programs
# =============================================================================

# Run a program, stream its output to the console and the log, throw on a
# non-zero exit code. Native stderr is never treated as a PowerShell error.
function Invoke-Native {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [Parameter(Mandatory)] [string]$What,
        [int[]]$OkExitCodes = @(0),
        [string[]]$Redact = @()          # secrets that must never reach the log
    )
    $ErrorActionPreference = 'Continue'
    $shown = foreach ($a in $ArgumentList) { if ($Redact -contains $a) { '********' } else { $a } }
    Write-LogLine "> $FilePath $($shown -join ' ')"
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            Write-Host $line
            Write-LogLine $line
        }
        $code = $LASTEXITCODE
    }
    finally { if ($WorkingDirectory) { Pop-Location } }
    if ($OkExitCodes -notcontains $code) { throw "$What failed (exit code $code): $FilePath" }
}

# Run a program and return its stdout lines (stderr goes to the log only).
function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [Parameter(Mandatory)] [string]$What,
        [switch]$AllowFailure
    )
    $ErrorActionPreference = 'Continue'
    Write-LogLine "> $FilePath $($ArgumentList -join ' ')"
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        $out = New-Object System.Collections.Generic.List[string]
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-LogLine $_.Exception.Message }
            else { $out.Add("$_") }
        }
        $code = $LASTEXITCODE
    }
    finally { if ($WorkingDirectory) { Pop-Location } }
    if ($code -ne 0 -and -not $AllowFailure) { throw "$What failed (exit code $code): $FilePath" }
    return , $out.ToArray()
}

# Run a few lines of batch code in a fresh cmd.exe (only for .bat-based tools:
# the ROS launchers and Visual Studio's vcvars). Returns stdout+stderr lines.
function Invoke-BatchSnippet {
    param([Parameter(Mandatory)] [string]$Body, [Parameter(Mandatory)] [string]$TempDir, [string]$What = 'batch snippet')
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
    $tmp = Join-Path $TempDir ('snippet-{0}.cmd' -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tmp, "@echo off`r`n$($Body -replace "`r?`n", "`r`n")`r`n", [Text.Encoding]::ASCII)
    Write-LogLine "> [$What] cmd.exe /d /c $tmp"
    try {
        $ErrorActionPreference = 'Continue'
        $lines = & cmd.exe /d /c $tmp 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
        }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Save-Download {
    param([Parameter(Mandatory)] [string]$Uri, [Parameter(Mandatory)] [string]$OutFile, [string]$Sha256, [string]$Sha512)
    $algo = if ($Sha512) { 'SHA512' } elseif ($Sha256) { 'SHA256' } else { $null }
    $want = if ($Sha512) { $Sha512.ToUpperInvariant() } elseif ($Sha256) { $Sha256.ToUpperInvariant() } else { $null }
    if ($algo -and (Test-Path -LiteralPath $OutFile) -and ((Get-FileHash -Algorithm $algo -LiteralPath $OutFile).Hash -eq $want)) { return }
    Enable-Tls12
    Write-Info "download $Uri"
    $part = "$OutFile.part"
    $old = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'      # the progress bar makes IWR very slow on 5.1
        for ($attempt = 1; ; $attempt++) {
            try { Invoke-WebRequest -Uri $Uri -OutFile $part -Headers @{ 'User-Agent' = $script:UserAgent } -UseBasicParsing; break }
            catch { if ($attempt -ge 4) { throw "download failed: $Uri ($($_.Exception.Message))" }; Start-Sleep -Seconds (5 * $attempt) }
        }
    }
    finally { $ProgressPreference = $old }
    if ($algo) {
        $actual = (Get-FileHash -Algorithm $algo -LiteralPath $part).Hash
        if ($actual -ne $want) {
            Remove-Item -LiteralPath $part -Force
            throw "$algo mismatch for $Uri (expected $want, got $actual)"
        }
    }
    Move-Item -LiteralPath $part -Destination $OutFile -Force
}

function Enable-Tls12 {
    # Windows PowerShell 5.1 on older Windows 10 builds may default to TLS 1.0.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
    catch { Write-Verbose 'TLS 1.2 already enabled' }
}

# Path to the PowerShell executable running this script (5.1 or 7).
function Get-PowerShellExe { (Get-Process -Id $PID).Path }

# Latest .NET SDK of a channel from Microsoft's official release metadata,
# with the SHA-512 Microsoft publishes for the win-x64 zip.
function Get-DotnetSdkRelease([string]$Channel) {
    Enable-Tls12
    $meta = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = $script:UserAgent } `
        -Uri "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$Channel/releases.json"
    $latest = $meta.'latest-sdk'
    # A release lists its SDKs under "sdk" (newest) and "sdks" (all feature bands).
    $sdk = $null
    foreach ($r in $meta.releases) {
        $cands = @()
        if ($r.PSObject.Properties.Name -contains 'sdk' -and $r.sdk) { $cands += $r.sdk }
        if ($r.PSObject.Properties.Name -contains 'sdks' -and $r.sdks) { $cands += @($r.sdks) }
        $sdk = $cands | Where-Object { $_.version -eq $latest } | Select-Object -First 1
        if ($sdk) { break }
    }
    if (-not $sdk) { throw ".NET $Channel release metadata has no entry for SDK $latest" }
    $file = @($sdk.files | Where-Object { $_.name -eq 'dotnet-sdk-win-x64.zip' }) | Select-Object -First 1
    if (-not $file -or -not $file.hash) { throw ".NET SDK $latest has no win-x64 zip with a hash in the release metadata" }
    return [pscustomobject]@{ Version = $latest; Url = $file.url; Sha512 = $file.hash }
}

function Expand-ZipFile([string]$Zip, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Destination)
}

# =============================================================================
# Configuration and validation (pure; unit-tested)
# =============================================================================
function Read-BuildConfig([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "config file not found: $Path" }
    return Import-PowerShellDataFile -LiteralPath $Path     # data only: no code execution
}

# Merge bound command-line parameters over the config file values.
function Merge-BuildConfig([hashtable]$Config, [hashtable]$Bound) {
    $c = @{} + $Config
    $map = @{
        WorkDir = 'WorkDir'; Prefix = 'InstallPrefix'; Manufacturer = 'Manufacturer'; BuildNumber = 'BuildNumber'
        RvizRef = 'RvizRef'; RvizRepo = 'RvizRepo'; Jobs = 'Jobs'; ExtraPackages = 'ExtraCondaPackages'
        SignThumbprint = 'SignThumbprint'; SignPfx = 'SignPfx'; TimestampUrl = 'SignTimestampUrl'; IconFile = 'IconFile'
    }
    foreach ($k in $map.Keys) { if ($Bound.ContainsKey($k)) { $c[$map[$k]] = $Bound[$k] } }
    if ($Bound.ContainsKey('RvizRef')) { $c.RvizCommit = '' }                  # a different ref: no pinned commit
    if ($Bound.ContainsKey('NoCommitCheck') -and $Bound.NoCommitCheck) { $c.RvizCommit = '' }
    if ($Bound.ContainsKey('NoPythonBindings') -and $Bound.NoPythonBindings) { $c.BuildPythonBindings = $false }
    if ($Bound.ContainsKey('KeepPdb') -and $Bound.KeepPdb) { $c.KeepPdb = $true }
    foreach ($k in 'SignThumbprint', 'SignPfx', 'IconFile') { if (-not $c.ContainsKey($k)) { $c[$k] = '' } }
    $c.ExtraCondaPackages = @($c.ExtraCondaPackages | ForEach-Object { "$_" -split '\s+' } | Where-Object { $_ })
    return $c
}

function Assert-WindowsDirectory([string]$Name, [string]$Value, [int]$MinDepth) {
    if ($Value -notmatch '^[A-Za-z]:\\') { throw "$Name must be an absolute Windows path like C:\foo (got '$Value')" }
    if ($Value -notmatch '^[A-Za-z]:(\\[A-Za-z0-9_.-]+)+$') {
        throw "$Name may only contain letters, digits, '_', '.', '-' and no trailing backslash or spaces: '$Value'"
    }
    if (([regex]::Matches($Value, '\\')).Count -lt $MinDepth) {
        throw "$Name is too shallow ('$Value'); use at least $MinDepth levels below the drive"
    }
    if ($Value.Substring(2).ToLowerInvariant() -match '^\\(windows|program files|programdata)(\\|$)|^\\users(\\[^\\]+)?(\\appdata\\roaming.*)?$') {
        throw "$Name must not point into a system location: '$Value'"
    }
}

function Assert-BuildConfig([hashtable]$C) {
    $C.WorkDir = ([string]$C.WorkDir).TrimEnd('\')
    $C.InstallPrefix = ([string]$C.InstallPrefix).TrimEnd('\')
    Assert-WindowsDirectory 'WorkDir' $C.WorkDir 1
    Assert-WindowsDirectory 'InstallPrefix' $C.InstallPrefix 2
    foreach ($k in 'ProductName', 'ProductKey', 'Manufacturer', 'AboutUrl') {
        if ([string]$C[$k] -match '[%"<>&^!]') { throw "$k must not contain any of: % `" < > & ^ !" }
    }
    if ($C.ProductKey -notmatch '^[A-Za-z0-9_.-]+$') { throw 'ProductKey may only contain letters, digits, . _ -' }
    if ($C.UpgradeCode -notmatch '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$') { throw 'UpgradeCode is not a GUID' }
    if ([int]$C.BuildNumber -lt 0 -or [int]$C.BuildNumber -gt 99) { throw 'BuildNumber must be 0-99' }
    if ([int]$C.Jobs -lt 0) { throw 'Jobs must be >= 0' }
    foreach ($pkg in $C.ExtraCondaPackages) { if ($pkg -match '[\s"]') { throw "invalid conda package spec: '$pkg'" } }
}

function Get-BuildPath([hashtable]$C, [string]$RepoRoot) {
    $w = $C.WorkDir
    [pscustomobject]@{
        Repo       = $RepoRoot
        Config     = Join-Path $RepoRoot 'config'
        WinDir     = Join-Path $RepoRoot 'windows'
        Patches    = Join-Path $RepoRoot 'patches'
        Work       = $w
        Tools      = Join-Path $w 'tools'
        Micromamba = Join-Path $w 'tools\micromamba.exe'
        Dotnet     = Join-Path $w 'tools\dotnet'
        Wix        = Join-Path $w 'tools\wix\wix.exe'
        MambaRoot  = Join-Path $w 'mamba'
        Env        = Join-Path $w 'envs\rviz'
        ToolsEnv   = Join-Path $w 'envs\tools'
        ToolsPy    = Join-Path $w 'envs\tools\python.exe'
        Src        = Join-Path $w 'src\rviz'
        Build      = Join-Path $w 'b'
        Stage      = Join-Path $w 'stage'
        Assets     = Join-Path $w 'assets'
        Out        = Join-Path $w 'out'
        Stamps     = Join-Path $w 'stamps'
        Temp       = Join-Path $w 'tmp'
        Specs      = Join-Path $w 'specs.txt'
        Lock       = Join-Path $w 'lock.txt'
        Rsp        = Join-Path $w 'wix.rsp'
    }
}

# MSI ProductVersion: major.minor.(patch*100 + build)
function Get-MsiVersion([string]$RvizVersion, [int]$BuildNumber) {
    if ($RvizVersion -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "unexpected rviz version '$RvizVersion'" }
    $f3 = [int]$Matches[3] * 100 + $BuildNumber
    if ([int]$Matches[1] -gt 255 -or [int]$Matches[2] -gt 255 -or $f3 -gt 65535) { throw "version $RvizVersion+$BuildNumber exceeds MSI limits" }
    return '{0}.{1}.{2}' -f $Matches[1], $Matches[2], $f3
}

function Get-RvizVersion([string]$SrcDir) {
    $xml = [xml](Get-Content -LiteralPath (Join-Path $SrcDir 'package.xml') -Raw)
    return ([string]$xml.package.version).Trim()
}

function Get-Fingerprint([object[]]$Parts) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((($Parts | ForEach-Object { "$_" }) -join "`n"))
        return (-join ($sha.ComputeHash($bytes)[0..7] | ForEach-Object { $_.ToString('x2') }))
    }
    finally { $sha.Dispose() }
}
function Get-FileFingerprint([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.Substring(0, 16) }
    return 'none'
}

# Plain-text conda spec list from config + extras (comments removed).
function Get-CondaSpecList([string]$PackagesFile, [string[]]$Extra) {
    $specs = foreach ($raw in Get-Content -LiteralPath $PackagesFile) {
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line) { $line }
    }
    return @($specs) + @($Extra | Where-Object { $_ })
}

# WiX response file: one argument per line; values never end with '\'.
function Get-WixArgumentList([hashtable]$C, $P, [string]$MsiVersion, [string]$MsiPath) {
    $q = '"'
    $lines = @('-arch', 'x64', '-culture', 'en-US', '-pdbtype', 'none',
        '-ext', "WixToolset.UI.wixext/$($C.WixVersion)", '-ext', "WixToolset.Util.wixext/$($C.WixVersion)",
        '-bindpath', "${q}payload=$($P.Stage)${q}")
    $defines = [ordered]@{
        ProductName = $C.ProductName; ProductKey = $C.ProductKey; Manufacturer = $C.Manufacturer
        ProductVersion = $MsiVersion; UpgradeCode = $C.UpgradeCode; InstallPrefix = $C.InstallPrefix
        AssetsDir = $P.Assets; AboutUrl = $C.AboutUrl
    }
    foreach ($k in $defines.Keys) { $lines += '-d'; $lines += "${q}$k=$($defines[$k])${q}" }
    $lines += '-o'; $lines += "${q}$MsiPath${q}"
    $lines += "${q}$(Join-Path $P.WinDir 'rviz.wxs')${q}"
    return $lines
}

function Get-ReleaseSha256([string]$Notes, [string]$FileName) {
    if (-not $Notes) { return $null }
    $text = $Notes -replace '<[^>]+>', ' '
    $m = [regex]::Match($text, [regex]::Escape($FileName) + '[\s|]+([0-9a-fA-F]{64})\b')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return $null
}

# Parse "NAME=VALUE" lines (output of cmd's `set`) into a hashtable.
function ConvertFrom-SetOutput([string[]]$Lines) {
    $h = @{}
    foreach ($l in $Lines) {
        if ($l -match '^([^=\s][^=]*)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
    }
    return $h
}

# =============================================================================
# Host probing
# =============================================================================
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Git for Windows (Git Bash) - RoboCare teams already have it for SSH to robots.
function Find-GitForWindows {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($hive in 'HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') {
        $item = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue
        if ($item -and ($item.PSObject.Properties.Name -contains 'InstallPath')) { $roots.Add($item.InstallPath) }
    }
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $dir = Split-Path -Parent $git.Source
        for ($i = 0; $i -lt 3 -and $dir; $i++) { $roots.Add($dir); $dir = Split-Path -Parent $dir }
    }
    foreach ($base in @($env:ProgramFiles, $env:LOCALAPPDATA, ${env:ProgramFiles(x86)})) {
        if ($base) { $roots.Add((Join-Path $base 'Git')); $roots.Add((Join-Path $base 'Programs\Git')) }
    }
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $bash = Join-Path $root 'bin\bash.exe'
        $gitExe = Join-Path $root 'cmd\git.exe'
        if (-not (Test-Path -LiteralPath $gitExe)) { $gitExe = Join-Path $root 'bin\git.exe' }
        if ((Test-Path -LiteralPath $bash) -and (Test-Path -LiteralPath $gitExe) -and ($bash -notlike "$env:SystemRoot*")) {
            return [pscustomobject]@{ Root = $root; Git = $gitExe; Bash = $bash; Ssh = (Join-Path $root 'usr\bin\ssh.exe') }
        }
    }
    return $null
}

function Find-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $null }
    $ErrorActionPreference = 'Continue'
    $json = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json
    $vs = @($json | Out-String | ConvertFrom-Json)
    if (-not $vs -or -not $vs[0]) { return $null }
    $vcvars = Join-Path $vs[0].installationPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) { return $null }
    return [pscustomobject]@{ Name = $vs[0].displayName; Version = $vs[0].installationVersion; VcVars = $vcvars }
}

function Get-HostInfo([string]$WorkDir) {
    $qual = $WorkDir.Substring(0, 2)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$qual'" -ErrorAction SilentlyContinue
    $lp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $signtool = Get-ChildItem -Path $kits -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'x64' } | Sort-Object FullName | Select-Object -Last 1
    [pscustomobject]@{
        WindowsBuild = [Environment]::OSVersion.Version.Build
        WindowsName  = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        Is64Bit      = [Environment]::Is64BitOperatingSystem -and $env:PROCESSOR_ARCHITECTURE -eq 'AMD64'
        Cpus         = [Environment]::ProcessorCount
        IsAdmin      = Test-IsAdmin
        FreeGB       = if ($disk) { [math]::Floor($disk.FreeSpace / 1GB) } else { -1 }
        LongPaths    = [bool]($lp -and $lp.LongPathsEnabled -eq 1)
        VisualStudio = Find-VisualStudio
        SignTool     = if ($signtool) { $signtool.FullName } else { '' }
        Git          = Find-GitForWindows
    }
}

# =============================================================================
# Git for Windows download + install (verified)
# =============================================================================
function Get-GitForWindowsRelease {
    Enable-Tls12
    try {
        $rel = Invoke-RestMethod -Uri $script:GitReleaseApi -Headers @{ 'User-Agent' = $script:UserAgent; 'Accept' = 'application/vnd.github+json' } -UseBasicParsing
        $asset = $rel.assets | Where-Object { $_.name -match '^Git-[\d.]+-64-bit\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw 'no 64-bit installer asset in the latest release' }
        return [pscustomobject]@{ Tag = $rel.tag_name; Name = $asset.name; Url = $asset.browser_download_url
            Sha256 = Get-ReleaseSha256 -Notes $rel.body -FileName $asset.name }
    }
    catch {
        # Anonymous GitHub API calls are rate-limited; the release page has the same table.
        Write-Warn "GitHub API unavailable ($($_.Exception.Message)); reading $script:GitReleasePage"
        $page = Invoke-WebRequest -Uri $script:GitReleasePage -Headers @{ 'User-Agent' = $script:UserAgent } -UseBasicParsing
        $m = [regex]::Match($page.Content, 'releases/tag/(v[\d.]+\.windows\.\d+)')
        if (-not $m.Success) { throw 'could not determine the latest Git for Windows release' }
        $tag = $m.Groups[1].Value
        $ver = ($tag -replace '^v', '') -replace '\.windows\.1$', '' -replace '\.windows\.(\d+)$', '.$1'
        $name = "Git-$ver-64-bit.exe"
        return [pscustomobject]@{ Tag = $tag; Name = $name
            Url = "https://github.com/git-for-windows/git/releases/download/$tag/$name"
            Sha256 = Get-ReleaseSha256 -Notes $page.Content -FileName $name }
    }
}

function Install-GitForWindows {
    Write-Step 'Installing Git for Windows (Git Bash)'
    $rel = Get-GitForWindowsRelease
    Write-Info "release : $($rel.Tag)"
    Write-Info "file    : $($rel.Url)"
    if (-not $rel.Sha256) { throw "No SHA-256 for $($rel.Name) found in the release notes; refusing to install an unverified download." }
    $dir = Join-Path ([IO.Path]::GetTempPath()) 'rviz-msi-builder'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $exe = Join-Path $dir $rel.Name
    $old = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $rel.Url -OutFile $exe -Headers @{ 'User-Agent' = $script:UserAgent } -UseBasicParsing
    }
    finally { $ProgressPreference = $old }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
    if ($actual -ne $rel.Sha256) {
        Remove-Item -LiteralPath $exe -Force
        throw "SHA-256 mismatch for $($rel.Name): expected $($rel.Sha256), got $actual"
    }
    Write-Info "sha256  : $actual (matches release notes)"
    $sig = Get-AuthenticodeSignature -LiteralPath $exe
    if ($sig.Status -ne 'Valid') { throw "Authenticode signature of $($rel.Name) is $($sig.Status); refusing to run it." }
    $subject = $sig.SignerCertificate.Subject
    Write-Info "signer  : $subject"
    if ($subject -notmatch [regex]::Escape($script:GitSigner)) {
        throw "$($rel.Name) is signed by '$subject', not '$($script:GitSigner)'; refusing to run it. Install Git for Windows manually if this is expected."
    }
    $log = Join-Path $dir 'git-install.log'
    $innoArgs = @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES', "/LOG=`"$log`"")
    if (-not (Test-IsAdmin)) {
        $target = Join-Path $env:LOCALAPPDATA 'Programs\Git'
        $innoArgs += "/DIR=`"$target`""
        Write-Info "scope   : current user ($target)"
    }
    else { Write-Info 'scope   : all users (Program Files)' }
    $proc = Start-Process -FilePath $exe -ArgumentList $innoArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Git for Windows installer exited with $($proc.ExitCode) (log: $log)" }
    Write-Info 'Git for Windows installed.'
}

function Confirm-GitInstall([bool]$Install, [bool]$NoInstall) {
    if ($Install) { return $true }
    if ($NoInstall) { return $false }
    $interactive = [Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() -match '^-NonInteractive$')
    if (-not $interactive) { return $false }
    Write-Host ''
    Write-Host 'Git for Windows (Git Bash) was not found.' -ForegroundColor Yellow
    Write-Host 'It provides git for fetching the rviz source (and ssh for robot access).'
    Write-Host "It can be downloaded from $script:GitReleasePage, checked against its"
    Write-Host 'published SHA-256 and code signature, and installed silently.'
    return ((Read-Host 'Install Git for Windows now? [y/N]') -match '^(y|yes)$')
}

# Returns the git.exe to use; installs Git for Windows if allowed.
function Resolve-Git([bool]$Install, [bool]$NoInstall) {
    $g = Find-GitForWindows
    if ($g) { return $g }
    if (Confirm-GitInstall $Install $NoInstall) {
        Install-GitForWindows
        $g = Find-GitForWindows
        if ($g) { return $g }
        throw 'Git for Windows was installed but git.exe could not be located.'
    }
    $other = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($other) {
        Write-Warn "Git for Windows (Git Bash) not found; using $($other.Source). Install Git for Windows for SSH access to robots."
        return [pscustomobject]@{ Root = (Split-Path -Parent $other.Source); Git = $other.Source; Bash = $null; Ssh = $null }
    }
    throw "Git for Windows (Git Bash) is required. Re-run with -InstallGit to install it from $script:GitReleasePage."
}

# =============================================================================
# Step bookkeeping: fingerprint stamps; re-running a step invalidates later ones
# =============================================================================
function Get-StepIndex([string]$Step) {
    $i = [array]::IndexOf($script:Steps, $Step)
    if ($i -lt 0) { throw "unknown step '$Step' (valid: $($script:Steps -join ', '))" }
    return $i
}

function Test-StepNeeded($Ctx, [string]$Step, [string]$Fingerprint) {
    $idx = Get-StepIndex $Step
    if ($Ctx.OnlyStep) { return ($Ctx.OnlyStep -eq $Step) }
    if ($Ctx.FromStep -and $idx -ge (Get-StepIndex $Ctx.FromStep)) { return $true }
    $stamp = Join-Path $Ctx.Paths.Stamps $Step
    if (-not (Test-Path -LiteralPath $stamp)) { return $true }
    return ((Get-Content -LiteralPath $stamp -Raw).Trim() -ne $Fingerprint)
}

function Set-StepDone($Ctx, [string]$Step, [string]$Fingerprint) {
    New-Item -ItemType Directory -Force -Path $Ctx.Paths.Stamps | Out-Null
    Set-Content -LiteralPath (Join-Path $Ctx.Paths.Stamps $Step) -Value $Fingerprint -Encoding ASCII
    for ($i = (Get-StepIndex $Step) + 1; $i -lt $script:Steps.Count; $i++) {
        Remove-Item -LiteralPath (Join-Path $Ctx.Paths.Stamps $script:Steps[$i]) -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Step($Ctx, [string]$Step, [string]$Fingerprint, [scriptblock]$Action) {
    if (-not (Test-StepNeeded $Ctx $Step $Fingerprint)) { Write-Info "skip $Step (up to date)"; return }
    Write-Step $Step
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Action
    Set-StepDone $Ctx $Step $Fingerprint
    Write-Info ("{0} finished in {1:mm\:ss}" -f $Step, $sw.Elapsed)
}

# =============================================================================
# Steps
# =============================================================================
function Invoke-PreflightStep($Ctx) {
    $C = $Ctx.Config; $h = $Ctx.HostInfo
    Write-Info "windows    : $($h.WindowsName) build $($h.WindowsBuild) ($($h.Cpus) CPUs)"
    if (-not $h.Is64Bit) { throw 'an x64 Windows host is required' }
    if ($h.WindowsBuild -lt 17763) { Write-Warn "Windows build $($h.WindowsBuild) is older than 10 1809; untested" }
    Write-Info ("powershell : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    if (-not $h.VisualStudio) {
        throw ('Visual Studio 2022 (or Build Tools) with the C++ workload was not found. Install with:' +
            "`n  winget install Microsoft.VisualStudio.2022.BuildTools --override `"--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`"")
    }
    Write-Info "compiler   : $($h.VisualStudio.Name) $($h.VisualStudio.Version)"
    if ([int](([string]$h.VisualStudio.Version).Split('.')[0]) -lt 17) { Write-Warn 'Visual Studio older than 2022 (17.x); conda-forge binaries expect >= 17' }
    $gitInfo = $Ctx.Git
    Write-Info "git        : $($gitInfo.Git)"
    if ($gitInfo.Bash) { Write-Info "git bash   : $($gitInfo.Bash)" }
    if ($h.FreeGB -ge 0 -and $h.FreeGB -lt [int]$C.MinFreeGB) { throw "only $($h.FreeGB) GB free on $($C.WorkDir.Substring(0,2)); need >= $($C.MinFreeGB) GB" }
    Write-Info "disk       : $($h.FreeGB) GB free on $($C.WorkDir.Substring(0,2))"
    if (-not $h.LongPaths) { Write-Warn "Win32 long paths are disabled; keep WorkDir short (current: $($C.WorkDir))" }
    if (($C.SignThumbprint -or $C.SignPfx) -and -not $h.SignTool) { throw 'signing requested but signtool.exe (Windows SDK) was not found' }
    if ($C.SignPfx -and -not $env:SIGN_PFX_PASSWORD) { throw 'SignPfx needs the certificate password in $env:SIGN_PFX_PASSWORD' }
    Write-Info "work dir   : $($C.WorkDir)"
    Write-Info "install to : $($C.InstallPrefix)"
}

function Invoke-ToolsStep($Ctx) {
    $C = $Ctx.Config; $P = $Ctx.Paths
    New-Item -ItemType Directory -Force -Path $P.Tools | Out-Null
    Save-Download -Uri "https://github.com/mamba-org/micromamba-releases/releases/download/$($C.MicromambaVersion)/micromamba-win-64" `
        -OutFile $P.Micromamba -Sha256 $C.MicromambaSha256

    $wixOk = $false
    if (Test-Path -LiteralPath $P.Wix) {
        $v = Invoke-NativeCapture -FilePath $P.Wix -ArgumentList @('--version') -What 'wix --version' -AllowFailure
        $wixOk = (($v -join ' ') -match ('^' + [regex]::Escape($C.WixVersion)))
    }
    if (-not $wixOk) {
        $dotnet = Join-Path $P.Dotnet 'dotnet.exe'
        if (-not (Test-Path -LiteralPath $dotnet)) {
            # Private SDK from the official zip, verified against Microsoft's SHA-512.
            $sdk = Get-DotnetSdkRelease $C.DotnetChannel
            $zip = Join-Path $P.Tools "dotnet-sdk-$($sdk.Version)-win-x64.zip"
            Write-Info "installing .NET SDK $($sdk.Version) into $($P.Dotnet)"
            Save-Download -Uri $sdk.Url -OutFile $zip -Sha512 $sdk.Sha512
            Expand-ZipFile $zip $P.Dotnet
            if (-not (Test-Path -LiteralPath $dotnet)) { throw "dotnet.exe missing after extracting $zip" }
        }
        $wixDir = Split-Path -Parent $P.Wix
        if (Test-Path -LiteralPath $wixDir) { Remove-Item -LiteralPath $wixDir -Recurse -Force }
        Invoke-Native -FilePath $dotnet -What 'dotnet tool install wix' -ArgumentList @(
            'tool', 'install', 'wix', '--version', $C.WixVersion, '--tool-path', $wixDir)
    }
    # Extensions are cached in <WorkDir>\.wix\extensions (cwd-relative).
    Invoke-Native -FilePath $P.Wix -WorkingDirectory $P.Work -What 'wix extension add' -ArgumentList @(
        'extension', 'add', "WixToolset.UI.wixext/$($C.WixVersion)", "WixToolset.Util.wixext/$($C.WixVersion)")
}

function Invoke-SourceStep($Ctx) {
    $C = $Ctx.Config; $P = $Ctx.Paths; $git = $Ctx.Git.Git
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $P.Src) | Out-Null
    if (Test-Path -LiteralPath $P.Src) { Remove-Item -LiteralPath $P.Src -Recurse -Force }
    $cfg = @('-c', 'advice.detachedHead=false')
    if ($C.RvizRef -match '^[0-9a-f]{40}$') {
        Invoke-Native -FilePath $git -What 'git init' -ArgumentList @('init', '-q', $P.Src)
        foreach ($kv in @('core.autocrlf=false', 'core.symlinks=false')) {
            $k, $v = $kv -split '=', 2
            Invoke-Native -FilePath $git -What 'git config' -ArgumentList @('-C', $P.Src, 'config', $k, $v)
        }
        Invoke-Native -FilePath $git -What 'git fetch' -ArgumentList @('-C', $P.Src, 'fetch', '-q', '--depth', '1', $C.RvizRepo, $C.RvizRef)
        Invoke-Native -FilePath $git -What 'git checkout' -ArgumentList ($cfg + @('-C', $P.Src, 'checkout', '-q', 'FETCH_HEAD'))
    }
    else {
        Invoke-Native -FilePath $git -What 'git clone' -ArgumentList ($cfg + @('clone', '-q', '--depth', '1', '--branch', $C.RvizRef,
                '--config', 'core.autocrlf=false', '--config', 'core.eol=lf', '--config', 'core.symlinks=false', $C.RvizRepo, $P.Src))
    }
    $head = (Invoke-NativeCapture -FilePath $git -ArgumentList @('-C', $P.Src, 'rev-parse', 'HEAD') -What 'git rev-parse') | Select-Object -First 1
    Write-Info "rviz $($C.RvizRef) @ $head"
    if ($C.RvizCommit -and $head -ne $C.RvizCommit) {
        throw "rviz $($C.RvizRef) resolved to $head but the config pins $($C.RvizCommit) (tag moved? use -NoCommitCheck to accept)"
    }
    $version = Get-RvizVersion $P.Src
    $patches = @(Get-ChildItem -LiteralPath (Join-Path $P.Patches $version) -Filter '*.patch' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $patches) { Write-Warn "no patches for rviz $version in patches\$version - the Windows build will likely fail" }
    # NB: PowerShell variable names are case-insensitive - never reuse $p next to $P.
    foreach ($patch in $patches) {
        Invoke-Native -FilePath $git -What "patch check $($patch.Name)" -ArgumentList @('-C', $P.Src, 'apply', '--check', '--whitespace=nowarn', $patch.FullName)
        Invoke-Native -FilePath $git -What "patch $($patch.Name)" -ArgumentList @('-C', $P.Src, 'apply', '--whitespace=nowarn', $patch.FullName)
        Write-Info "applied $($patch.Name)"
    }
}

function Invoke-EnvStep($Ctx) {
    $C = $Ctx.Config; $P = $Ctx.Paths
    $mm = $P.Micromamba
    $env:MAMBA_NO_BANNER = '1'
    $env:CONDA_PKGS_DIRS = Join-Path $P.MambaRoot 'pkgs'
    $specs = Get-CondaSpecList (Join-Path $P.Config 'conda-packages.txt') $C.ExtraCondaPackages
    [IO.File]::WriteAllLines($P.Specs, [string[]]$specs, (New-Object Text.UTF8Encoding($false)))

    if (-not (Test-Path -LiteralPath (Join-Path $P.ToolsEnv 'Scripts\conda-pack.exe'))) {
        Write-Info 'creating tools environment (python, conda-pack, pillow)'
        Invoke-Native -FilePath $mm -What 'micromamba create (tools env)' -ArgumentList @(
            'create', '-y', '-r', $P.MambaRoot, '-p', $P.ToolsEnv, '--override-channels', '-c', 'conda-forge',
            'python=3.12', 'conda-pack>=0.7', 'pillow')
    }
    if (Test-Path -LiteralPath $P.Env) { Write-Info 'removing previous rviz environment'; Remove-Item -LiteralPath $P.Env -Recurse -Force }
    if ($Ctx.LockFile) {
        if (-not (Select-String -LiteralPath $Ctx.LockFile -Pattern '^@EXPLICIT' -Quiet)) { throw "$($Ctx.LockFile) is not an explicit (@EXPLICIT) lock file" }
        Copy-Item -LiteralPath $Ctx.LockFile -Destination $P.Lock -Force
        Write-Info "creating rviz environment from lock file $($Ctx.LockFile)"
        Invoke-Native -FilePath $mm -What 'micromamba create (from lock)' -ArgumentList @(
            'create', '-y', '-r', $P.MambaRoot, '-p', $P.Env, '--file', $P.Lock)
    }
    else {
        $channelArgs = @(); foreach ($ch in $C.CondaChannels) { $channelArgs += @('-c', $ch) }
        Write-Info "solving rviz environment ($($C.CondaChannels -join ', '), strict priority)"
        Invoke-Native -FilePath $mm -What 'micromamba create (rviz env)' -ArgumentList (@(
                'create', '-y', '-r', $P.MambaRoot, '-p', $P.Env, '--override-channels') + $channelArgs + @(
                '--strict-channel-priority', '--file', $P.Specs))
    }
    New-Item -ItemType Directory -Force -Path $P.Out | Out-Null
    $lock = Invoke-NativeCapture -FilePath $mm -What 'micromamba env export' -ArgumentList @(
        'env', 'export', '-r', $P.MambaRoot, '-p', $P.Env, '--explicit')
    $lockOut = Join-Path $P.Out 'conda-lock-win-64.txt'
    [IO.File]::WriteAllLines($lockOut, [string[]]$lock, (New-Object Text.UTF8Encoding($false)))
    Write-Info "lock file: $lockOut"
    Invoke-Native -FilePath $P.ToolsPy -What 'environment check' -ArgumentList @(
        (Join-Path $P.WinDir 'rvizmsi.py'), 'check-env', '--prefix', $P.Env)
}

# Environment of "conda activate <env>" followed by vcvars64.bat, captured
# from cmd.exe (both are batch files) and returned as a hashtable.
function Get-BuildEnvironment($Ctx) {
    $P = $Ctx.Paths
    $body = @"
set "CONDA_PREFIX=$($P.Env)"
set "PATH=$($P.Env);$($P.Env)\Library\mingw-w64\bin;$($P.Env)\Library\usr\bin;$($P.Env)\Library\bin;$($P.Env)\Scripts;$($P.Env)\bin;%PATH%"
for %%F in ("$($P.Env)\etc\conda\activate.d\*.bat") do call "%%~fF" >nul 2>&1
call "$($Ctx.HostInfo.VisualStudio.VcVars)" >nul
if errorlevel 1 exit /b 1
set
"@
    $r = Invoke-BatchSnippet -Body $body -TempDir $P.Temp -What 'conda activation + vcvars64'
    if ($r.ExitCode -ne 0) { throw "vcvars64.bat failed (exit code $($r.ExitCode))" }
    $vars = ConvertFrom-SetOutput $r.Lines
    if (-not $vars.ContainsKey('VCToolsVersion')) { throw 'vcvars64.bat did not set up the MSVC environment' }
    return $vars
}

# First link.exe on PATH (must be MSVC's, not e.g. a coreutils link.exe).
function Find-LinkExe {
    $c = Get-Command link.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Use-Environment([hashtable]$Vars, [scriptblock]$Action) {
    $saved = @{}
    foreach ($e in Get-ChildItem env:) { $saved[$e.Name] = $e.Value }
    try {
        foreach ($k in $Vars.Keys) { Set-Item -LiteralPath "env:$k" -Value $Vars[$k] }
        & $Action
    }
    finally {
        foreach ($e in Get-ChildItem env:) { if (-not $saved.ContainsKey($e.Name)) { Remove-Item -LiteralPath "env:$($e.Name)" } }
        foreach ($k in $saved.Keys) { Set-Item -LiteralPath "env:$k" -Value $saved[$k] }
    }
}

function Invoke-BuildStep($Ctx) {
    $C = $Ctx.Config; $P = $Ctx.Paths
    $vars = Get-BuildEnvironment $Ctx
    $vars['CC'] = 'cl.exe'; $vars['CXX'] = 'cl.exe'
    $vars['CL'] = '/DROS_BUILD_SHARED_LIBS=1 /DNOGDI=1'           # as RoboStack builds ROS 1 on Windows
    $vars['PYTHONPATH'] = Join-Path $P.Env 'Library\lib\site-packages'
    $jobs = if ([int]$C.Jobs -gt 0) { [int]$C.Jobs } else { [int]$Ctx.HostInfo.Cpus }
    $envF = $P.Env -replace '\\', '/'
    $bindings = if ($C.BuildPythonBindings) { 'ON' } else { 'OFF' }
    if (Test-Path -LiteralPath $P.Build) { Remove-Item -LiteralPath $P.Build -Recurse -Force }
    Use-Environment $vars {
        $link = Find-LinkExe
        Write-Info "MSVC $($env:VCToolsVersion); link.exe: $(if ($link) { $link } else { 'NOT FOUND' })"
        if (-not $link -or $link -notmatch '\\Tools\\MSVC\\') { throw 'MSVC link.exe is not first on PATH (another link.exe shadows it)' }
        $cmake = Join-Path $P.Env 'Library\bin\cmake.exe'
        # Run CMake from the source tree: catkin's generated python_distutils_install.bat
        # does a plain `cd "<source dir>"` (no /d), which cannot switch drives, so an
        # install started from another drive (e.g. D:\a\... on CI runners) runs rviz's
        # setup.py in the wrong folder ("Path '.' is neither a directory containing a
        # package.xml"). Same drive as the source => the cd works.
        Invoke-Native -FilePath $cmake -WorkingDirectory $P.Src -What 'CMake configure' -ArgumentList @(
            '-S', ($P.Src -replace '\\', '/'), '-B', ($P.Build -replace '\\', '/'), '-G', 'Ninja',
            '--compile-no-warning-as-error',
            '-DCMAKE_BUILD_TYPE=Release',
            "-DCMAKE_INSTALL_PREFIX=$envF/Library",
            "-DCMAKE_PREFIX_PATH=$envF/Library",
            '-DCMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP=ON',
            '-DBUILD_SHARED_LIBS=ON',
            "-DPYTHON_EXECUTABLE=$envF/python.exe",
            "-DPython_EXECUTABLE=$envF/python.exe",
            "-DPython3_EXECUTABLE=$envF/python.exe",
            '-DSETUPTOOLS_DEB_LAYOUT=OFF',
            '-DBoost_USE_STATIC_LIBS=OFF',
            '-DCATKIN_BUILD_BINARY_PACKAGE=1',
            '-DCATKIN_SKIP_TESTING=ON',
            "-DRVIZ_BUILD_PYTHON_BINDINGS=$bindings")
        Invoke-Native -FilePath $cmake -WorkingDirectory $P.Src -What 'compile' -ArgumentList @('--build', $P.Build, '--parallel', "$jobs")
        Invoke-Native -FilePath $cmake -WorkingDirectory $P.Src -What 'install' -ArgumentList @('--install', $P.Build)
    }
    if (-not (Test-Path -LiteralPath (Join-Path $P.Env 'Library\bin\rviz.exe'))) { throw 'rviz.exe was not installed' }
    Write-Info "rviz installed into $($P.Env)\Library"
}

function Invoke-PackStep($Ctx) {
    $P = $Ctx.Paths
    if (Test-Path -LiteralPath $P.Stage) { Remove-Item -LiteralPath $P.Stage -Recurse -Force }
    $packDir = Join-Path $P.Work 'pack'
    $tarball = Join-Path $packDir 'rviz-env.tar'
    if (Test-Path -LiteralPath $packDir) { Remove-Item -LiteralPath $packDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $packDir, $P.Stage | Out-Null
    # conda-pack's no-archive format hardlinks files into the output folder, and
    # in CI it twice stopped after ~10k of the environment's files with exit code
    # 0 and no message (stage without conda-meta). Pack to an uncompressed tar
    # instead: conda-pack only moves the archive into place after every file was
    # written, so a missing archive means conda-pack itself failed. The tools
    # Python runs it directly (no Scripts\conda-pack.exe launcher), with
    # faulthandler on so a native crash prints a stack trace.
    Invoke-Native -FilePath $P.ToolsPy -What 'conda-pack' -ArgumentList @(
        '-X', 'faulthandler', '-c', 'import sys; from conda_pack.cli import main; sys.exit(main())',
        '-p', $P.Env, '-o', $tarball, '--format', 'tar', '--dest-prefix', $Ctx.Config.InstallPrefix,
        '--ignore-missing-files', '--force', '--quiet')
    if (-not (Test-Path -LiteralPath $tarball)) { throw "conda-pack reported success but wrote no archive ($tarball)" }
    Write-Info ("packed archive: {0:N0} MB" -f ((Get-Item -LiteralPath $tarball).Length / 1MB))
    Invoke-Native -FilePath "$env:SystemRoot\System32\tar.exe" -What 'unpack stage' -ArgumentList @(
        '-xf', $tarball, '-C', $P.Stage)
    Remove-Item -LiteralPath $packDir -Recurse -Force
    # Never trust exit codes alone: the stage must be complete.
    foreach ($rel in 'conda-meta', 'python.exe', 'Library\bin\rviz.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $P.Stage $rel))) {
            $n = @(Get-ChildItem -LiteralPath $P.Stage -Recurse -File -ErrorAction SilentlyContinue).Count
            throw "packing left an incomplete stage ($rel missing, $n files in $($P.Stage))"
        }
    }
    $metaCount = @(Get-ChildItem -LiteralPath (Join-Path $P.Stage 'conda-meta') -Filter '*.json').Count
    Write-Info "stage packed: $metaCount packages in $($P.Stage)"
}

function Invoke-FinalizeStep($Ctx) {
    $C = $Ctx.Config; $P = $Ctx.Paths
    # finalize prunes the stage in place (and removes conda-meta), so a re-run
    # must start again from a freshly packed copy.
    if (-not (Test-Path -LiteralPath (Join-Path $P.Stage 'conda-meta'))) {
        Write-Info 'stage was already finalized - re-packing the environment first'
        Invoke-PackStep $Ctx
    }
    $py = Join-Path $P.WinDir 'rvizmsi.py'
    if (Test-Path -LiteralPath $P.Assets) { Remove-Item -LiteralPath $P.Assets -Recurse -Force }
    Invoke-Native -FilePath $P.ToolsPy -What 'finalize payload' -ArgumentList @(
        $py, 'finalize', '--stage', $P.Stage, '--config-dir', $P.Config, '--rviz-src', $P.Src,
        '--prefix', $C.InstallPrefix, '--pkgs-dir', (Join-Path $P.MambaRoot 'pkgs'), '--env-prefix', $P.Env, '--report-dir', $P.Out,
        '--keep-pdb', $(if ($C.KeepPdb) { '1' } else { '0' }))
    # Pre-compile bytecode with the payload's own interpreter, embedding the final
    # install path. Some upstream files are intentionally invalid -> warning only.
    try {
        Invoke-Native -FilePath (Join-Path $P.Stage 'python.exe') -What 'compileall' -ArgumentList @(
            '-I', '-m', 'compileall', '-q', '-j', '0', '-s', $P.Stage, '-p', $C.InstallPrefix,
            (Join-Path $P.Stage 'Lib'), (Join-Path $P.Stage 'Library\lib\site-packages'))
    }
    catch { Write-Warn "compileall reported errors (non-fatal): $($_.Exception.Message)" }
    # Never pass empty strings to native programs: PowerShell 5.1 drops them.
    $assetArgs = @($py, 'assets', '--rviz-src', $P.Src, '--out', $P.Assets, '--product-name', $C.ProductName)
    if ($C.IconFile) { $assetArgs += @('--icon', [string]$C.IconFile) }
    Invoke-Native -FilePath $P.ToolsPy -What 'MSI assets' -ArgumentList $assetArgs
}

function Invoke-SmokeStep($Ctx) {
    $P = $Ctx.Paths
    if ($Ctx.SkipSmoke) { Write-Warn 'smoke test skipped (-SkipSmoke)'; return }
    $log = Join-Path $P.Out 'smoke'
    New-Item -ItemType Directory -Force -Path $log | Out-Null
    $launchers = Join-Path $P.Stage 'launchers'

    Write-Info 'rviz --help (staged payload)'
    $r = Invoke-BatchSnippet -TempDir $P.Temp -Body "call `"$launchers\rviz.cmd`" --help"
    Set-Content -LiteralPath (Join-Path $log 'rviz-help.txt') -Value $r.Lines
    if (-not ($r.Lines -match 'Produce this help message')) { $r.Lines | ForEach-Object { Write-LogLine $_ }; throw 'smoke: rviz.exe did not start (see out\smoke\rviz-help.txt)' }

    Write-Info 'rospack find rviz'
    $r = Invoke-BatchSnippet -TempDir $P.Temp -Body "call `"$launchers\ros_env.bat`"`nrospack find rviz"
    Set-Content -LiteralPath (Join-Path $log 'rospack-find.txt') -Value $r.Lines
    if ($r.ExitCode -ne 0) { throw 'smoke: rospack cannot find rviz (see out\smoke\rospack-find.txt)' }
    Write-Info "  $(@($r.Lines)[-1])"

    Write-Info 'rospack plugins --attrib=plugin rviz'
    $r = Invoke-BatchSnippet -TempDir $P.Temp -Body "call `"$launchers\ros_env.bat`"`nrospack plugins --attrib=plugin rviz"
    Set-Content -LiteralPath (Join-Path $log 'rospack-plugins.txt') -Value $r.Lines
    if (-not ($r.Lines -match 'plugin_description\.xml')) { throw 'smoke: rviz plugin manifest not discoverable (see out\smoke\rospack-plugins.txt)' }
    Write-Info 'smoke test passed'
}

function Invoke-MsiStep($Ctx) {
    $C = $Ctx.Config; $P = $Ctx.Paths
    New-Item -ItemType Directory -Force -Path $P.Out | Out-Null
    $msi = Join-Path $P.Out $Ctx.MsiName
    if (Test-Path -LiteralPath $msi) { Remove-Item -LiteralPath $msi -Force }
    $rsp = Get-WixArgumentList $C $P $Ctx.MsiVersion $msi
    [IO.File]::WriteAllLines($P.Rsp, [string[]]$rsp, (New-Object Text.UTF8Encoding($false)))
    $env:DOTNET_ROOT = $P.Dotnet
    Invoke-Native -FilePath $P.Wix -WorkingDirectory $P.Work -What 'wix build' -ArgumentList @('build', "@$($P.Rsp)")
    if (-not $Ctx.SkipValidate) {
        Invoke-Native -FilePath $P.Wix -WorkingDirectory $P.Work -What 'ICE validation (use -SkipValidate to bypass)' -ArgumentList @('msi', 'validate', $msi)
    }
    if ($C.SignThumbprint -or $C.SignPfx) {
        $st = $Ctx.HostInfo.SignTool
        $common = @('sign', '/fd', 'SHA256', '/tr', $C.SignTimestampUrl, '/td', 'SHA256', '/d', $C.ProductName)
        $secret = @()
        if ($C.SignThumbprint) { $signArgs = $common + @('/sha1', $C.SignThumbprint, $msi) }
        else {
            if (-not $env:SIGN_PFX_PASSWORD) { throw 'SignPfx needs the certificate password in $env:SIGN_PFX_PASSWORD' }
            $signArgs = $common + @('/f', $C.SignPfx, '/p', $env:SIGN_PFX_PASSWORD, $msi)
            $secret = @($env:SIGN_PFX_PASSWORD)
        }
        Write-Info 'signing MSI'
        Invoke-Native -FilePath $st -What 'signtool sign' -ArgumentList $signArgs -Redact $secret
        Invoke-Native -FilePath $st -What 'signtool verify' -ArgumentList @('verify', '/pa', $msi)
    }
    if (-not (Test-Path -LiteralPath $msi)) { throw 'MSI was not produced' }
    $size = (Get-Item -LiteralPath $msi).Length
    if ($size -ge 2000000000) { throw ("MSI is {0:N0} MiB - Windows Installer cannot open MSI files >= 2 GB; extend config\prune.txt" -f ($size / 1MB)) }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $msi).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$msi.sha256" -Value "$hash  $($Ctx.MsiName)" -Encoding ASCII
    New-Item -ItemType Directory -Force -Path $Ctx.OutputDir | Out-Null
    Copy-Item -LiteralPath $msi, "$msi.sha256" -Destination $Ctx.OutputDir -Force
    $stem = [IO.Path]::GetFileNameWithoutExtension($Ctx.MsiName)
    foreach ($f in 'conda-lock-win-64.txt', 'payload-files.tsv') {
        $src = Join-Path $P.Out $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Ctx.OutputDir "$stem.$f") -Force }
    }
    Write-Info ("MSI: {0} ({1:N0} MiB, sha256 {2})" -f (Join-Path $Ctx.OutputDir $Ctx.MsiName), ($size / 1MB), $hash)
}

function Invoke-TestInstallStep($Ctx) {
    if (-not $Ctx.TestInstall) { Write-Info 'not requested (use -TestInstall from an elevated PowerShell)'; return }
    if (-not $Ctx.HostInfo.IsAdmin) { Write-Warn '-TestInstall needs an elevated PowerShell (Run as administrator); skipping'; return }
    $P = $Ctx.Paths
    $testArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $P.WinDir 'test_install.ps1'),
        '-Msi', (Join-Path $P.Out $Ctx.MsiName), '-Prefix', $Ctx.Config.InstallPrefix, '-LogDir', (Join-Path $P.Out 'test-install'))
    if ($Ctx.ContainsKey('HeadlessTest') -and $Ctx.HeadlessTest) { $testArgs += '-SkipGui' }
    Invoke-Native -FilePath (Get-PowerShellExe) -What 'install/run/uninstall test' -ArgumentList $testArgs
}

# =============================================================================
# Pipeline
# =============================================================================
function Clear-WorkDir($P) {
    if (-not (Test-Path -LiteralPath $P.Work)) { return }
    Write-Info "cleaning $($P.Work) (keeping tools and package cache)"
    foreach ($item in Get-ChildItem -LiteralPath $P.Work -Force) {
        if ($item.Name -in @('tools', 'mamba', '.wix')) { continue }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}

function Invoke-Pipeline($Ctx) {
    $C = $Ctx.Config; $P = $Ctx.Paths
    Invoke-PreflightStep $Ctx                        # always: cheap, validates the host

    $patchFp = Get-Fingerprint @(Get-ChildItem -LiteralPath $P.Patches -Filter '*.patch' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName | ForEach-Object { Get-FileFingerprint $_.FullName })
    Invoke-Step $Ctx 'tools' (Get-Fingerprint @($C.MicromambaVersion, $C.MicromambaSha256, $C.WixVersion, $C.DotnetChannel)) { Invoke-ToolsStep $Ctx }
    Invoke-Step $Ctx 'source' (Get-Fingerprint @($C.RvizRepo, $C.RvizRef, $C.RvizCommit, $patchFp)) { Invoke-SourceStep $Ctx }

    if (-not (Test-Path -LiteralPath (Join-Path $P.Src 'package.xml'))) {
        if ($Ctx.OnlyStep -eq 'tools') { Write-Step 'done'; return }
        throw "rviz source not found in $($P.Src); run the 'source' step first (e.g. without -OnlyStep)"
    }
    $Ctx.RvizVersion = Get-RvizVersion $P.Src
    $Ctx.MsiVersion = Get-MsiVersion $Ctx.RvizVersion ([int]$C.BuildNumber)
    $Ctx.MsiName = '{0}-{1}-{2}-x64.msi' -f $C.ProductKey, $Ctx.RvizVersion, $Ctx.MsiVersion
    Write-Info "rviz $($Ctx.RvizVersion) -> MSI ProductVersion $($Ctx.MsiVersion) ($($Ctx.MsiName))"

    Invoke-Step $Ctx 'env' (Get-Fingerprint @((Get-FileFingerprint (Join-Path $P.Config 'conda-packages.txt')),
            ($C.ExtraCondaPackages -join ' '), ($C.CondaChannels -join ' '), (Get-FileFingerprint $Ctx.LockFile))) { Invoke-EnvStep $Ctx }
    Invoke-Step $Ctx 'build' (Get-Fingerprint @($C.BuildPythonBindings)) { Invoke-BuildStep $Ctx }
    Invoke-Step $Ctx 'pack' (Get-Fingerprint @($C.InstallPrefix)) { Invoke-PackStep $Ctx }
    Invoke-Step $Ctx 'finalize' (Get-Fingerprint @((Get-FileFingerprint (Join-Path $P.Config 'prune.txt')),
            (Get-FileFingerprint (Join-Path $P.Config 'build-only-packages.txt')),
            (Get-FileFingerprint (Join-Path $P.WinDir 'rvizmsi.py')), $C.KeepPdb, $C.ProductName, $C.IconFile)) { Invoke-FinalizeStep $Ctx }
    Invoke-Step $Ctx 'smoke' (Get-Fingerprint @($Ctx.SkipSmoke)) { Invoke-SmokeStep $Ctx }
    # Always rebuild the MSI and re-run the optional install test (metadata may change).
    Invoke-Step $Ctx 'msi' ([guid]::NewGuid().ToString()) { Invoke-MsiStep $Ctx }
    Invoke-Step $Ctx 'test-install' ([guid]::NewGuid().ToString()) { Invoke-TestInstallStep $Ctx }

    Write-Step 'done'
    Write-Info "installer : $(Join-Path $Ctx.OutputDir $Ctx.MsiName)"
    Write-Info "installs  : $($C.InstallPrefix)  (Start menu > $($C.ProductName) > RViz)"
}
