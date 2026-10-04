<#
  tests/Test-Build.ps1 - tests for build-rviz-msi.ps1 + windows/RvizMsi.Build.ps1
  (no Pester needed). Runs on Windows PowerShell 5.1 or PowerShell 7, any OS:

      pwsh -NoProfile -File tests/Test-Build.ps1

  Part 1 checks the pure helpers. Part 2 checks the Git for Windows pre-check
  and verified download. Part 3 is a full dry run of the pipeline: every
  external program (git, micromamba, cmake, conda-pack, python, wix, signtool,
  cmd.exe) is replaced by a recorder that simulates its side effects, so step
  order, exact command lines, resume/invalidation and error handling are
  verified without Windows.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Passes = 0; $script:Failures = 0

function Assert([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:Passes++; Write-Host "  ok   $Name" }
    else { $script:Failures++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function Assert-Throws([scriptblock]$Block, [string]$Pattern, [string]$Name) {
    try { & $Block | Out-Null; Assert $false "$Name (did not throw)" }
    catch { Assert ($_.Exception.Message -match $Pattern) "$Name [$($_.Exception.Message)]" }
}

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'build-rviz-msi.ps1')        # dot-source: defines functions, runs nothing
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('rvb-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
if (-not $env:SystemRoot) { $env:SystemRoot = $tmp }      # non-Windows test host
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = $tmp }

# =============================================================================
Write-Host 'Part 1: configuration and helpers'
$base = Read-BuildConfig (Join-Path $repo 'config\build.psd1')
Assert ($base.RvizRef -eq '1.14.26' -and $base.WixVersion -eq '5.0.2') 'config\build.psd1 loads'
Assert ($base.CondaChannels[0] -eq 'robostack-noetic') 'RoboStack channel has priority'

$m = Merge-BuildConfig $base @{ Prefix = 'D:\ros\rviz'; Manufacturer = 'Relay Robotics'; BuildNumber = 0; ExtraPackages = @('a b', 'c');
    NoPythonBindings = [switch]$true; KeepPdb = [switch]$false }
Assert ($m.InstallPrefix -eq 'D:\ros\rviz') '-Prefix overrides InstallPrefix'
Assert ($m.Manufacturer -eq 'Relay Robotics') '-Manufacturer overrides'
Assert ($m.BuildNumber -eq 0) 'BuildNumber 0 kept'
Assert (($m.ExtraCondaPackages -join ',') -eq 'a,b,c') 'extra packages split on spaces'
Assert ($m.BuildPythonBindings -eq $false -and $m.KeepPdb -eq $false) 'switches mapped'
Assert ($m.RvizCommit -eq $base.RvizCommit) 'pinned commit kept by default'
Assert ((Merge-BuildConfig $base @{ RvizRef = 'noetic-devel' }).RvizCommit -eq '') 'other ref disables commit pin'
Assert ((Merge-BuildConfig $base @{ NoCommitCheck = [switch]$true }).RvizCommit -eq '') '-NoCommitCheck'
Assert ($base.ContainsKey('InstallPrefix') -and $base.InstallPrefix -eq 'C:\opt\rviz\noetic') 'config not mutated by merge'

$ok = Merge-BuildConfig $base @{}
Assert-BuildConfig $ok; Assert $true 'default config validates'
foreach ($bad in @(
        @{ Prefix = 'C:\Program Files\RViz'; Why = 'spaces' }, @{ Prefix = 'C:\opt'; Why = 'too shallow' },
        @{ Prefix = 'C:\Windows\rviz'; Why = 'system location' }, @{ Prefix = 'opt\rviz'; Why = 'absolute Windows path' },
        @{ WorkDir = 'C:\my build'; Why = 'spaces' }, @{ Manufacturer = 'A&B'; Why = 'must not contain' })) {
    $why = $bad.Why; $bad.Remove('Why')
    Assert-Throws { Assert-BuildConfig (Merge-BuildConfig $base $bad) } $why "rejects $(($bad.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"
}
$trail = Merge-BuildConfig $base @{ Prefix = 'C:\opt\rviz\noetic\' }
Assert-BuildConfig $trail
Assert ($trail.InstallPrefix -eq 'C:\opt\rviz\noetic') 'trailing backslash trimmed'
Assert-Throws { Assert-BuildConfig (Merge-BuildConfig $base @{ ExtraPackages = @('ok', 'x"y') }) } 'invalid conda package' 'quote in package spec rejected'

Assert ((Get-MsiVersion '1.14.26' 0) -eq '1.14.2600') 'MSI version 1.14.2600'
Assert ((Get-MsiVersion '1.14.26' 7) -eq '1.14.2607') 'MSI version with build number'
Assert-Throws { Get-MsiVersion '1.14' 0 } 'unexpected rviz version' 'bad rviz version rejected'
Assert ((Get-Fingerprint @('a', 1)) -eq (Get-Fingerprint @('a', 1)) -and (Get-Fingerprint @('a', 1)) -ne (Get-Fingerprint @('a', 2))) 'fingerprints stable and input-sensitive'

$specs = Get-CondaSpecList (Join-Path $repo 'config\conda-packages.txt') @('extra-pkg')
Assert (-not ($specs -match '#')) 'specs have no comments'
Assert ($specs -contains 'ogre >=1.10.12,<1.11' -and $specs -contains 'ros-noetic-roscpp' -and $specs[-1] -eq 'extra-pkg') 'specs from config + extras'
Assert (-not ($specs -contains 'ros-noetic-rviz')) 'binary ros-noetic-rviz is never requested'

$vars = ConvertFrom-SetOutput @('PATH=C:\a;C:\b', 'VCToolsVersion=14.44.35207', 'EMPTY=', 'garbage line', '=C:=C:\x')
Assert ($vars.PATH -eq 'C:\a;C:\b' -and $vars.VCToolsVersion -eq '14.44.35207' -and $vars.ContainsKey('EMPTY')) 'set output parsed'
Assert (-not $vars.ContainsKey('')) 'cmd internal =C: variables ignored'

$md = "| Git-2.56.0-64-bit.exe | bfe94e7b419b16eee9fecbd1253a98e3d4f49ba8f029630549052278ffe286a6 |"
Assert ((Get-ReleaseSha256 $md 'Git-2.56.0-64-bit.exe') -eq 'bfe94e7b419b16eee9fecbd1253a98e3d4f49ba8f029630549052278ffe286a6') 'release checksum (markdown)'
Assert ((Get-ReleaseSha256 "<td>Git-2.56.0-64-bit.exe</td><td>BFE94E7B419B16EEE9FECBD1253A98E3D4F49BA8F029630549052278FFE286A6</td>" 'Git-2.56.0-64-bit.exe') -match '^bfe9') 'release checksum (html)'
Assert ($null -eq (Get-ReleaseSha256 $md 'Git-2.56.0-64-bit.ex')) 'no partial-name checksum match'
Assert-Throws { Get-StepIndex 'nope' } 'unknown step' 'unknown step rejected'

Write-Host 'Invoke-Native (real) and path resolution'
$logFile = Join-Path $tmp 'native.log'
Start-BuildLog $logFile
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT   # $IsWindows does not exist in 5.1
if (-not $onWindows) { $echo = (Get-Command echo -CommandType Application | Select-Object -First 1).Source; $echoArgs = @('hello', 's3cret')
    $false_ = (Get-Command false -CommandType Application | Select-Object -First 1).Source; $falseArgs = @() }
else { $echo = 'cmd.exe'; $echoArgs = @('/d', '/c', 'echo', 'hello', 's3cret'); $false_ = 'cmd.exe'; $falseArgs = @('/d', '/c', 'exit 3') }
Invoke-Native -FilePath $echo -ArgumentList $echoArgs -What 'echo' -Redact @('s3cret') 6>$null
Assert-Throws { Invoke-Native -FilePath $false_ -ArgumentList $falseArgs -What 'failing tool' 6>$null } 'failing tool failed \(exit code [1-9]' 'non-zero exit code throws'
$cap = Invoke-NativeCapture -FilePath $echo -ArgumentList $echoArgs -What 'capture'
Stop-BuildLog
$logText = Get-Content -LiteralPath $logFile -Raw
Assert ($logText -match '\*\*\*\*\*\*\*\*' -and $logText -match 'hello') 'command line logged with secret masked'
Assert (($cap -join ' ') -match 'hello') 'captured output returned'
Push-Location $tmp
Assert ((Resolve-UserPath 'lock.txt') -eq (Join-Path $tmp 'lock.txt')) 'relative paths resolve against the current PowerShell location'
Pop-Location

Write-Host '.NET SDK release metadata'
function Invoke-RestMethod { param($Uri, $Headers, [switch]$UseBasicParsing)
    $script:metaUri = $Uri
    [pscustomobject]@{ 'latest-sdk' = '8.0.425'; releases = @(
            [pscustomobject]@{ sdk = [pscustomobject]@{ version = '8.0.122'; files = @() }
                sdks = @([pscustomobject]@{ version = '8.0.425'; files = @(
                            [pscustomobject]@{ name = 'dotnet-sdk-win-arm64.zip'; url = 'https://x/arm'; hash = 'aa' },
                            [pscustomobject]@{ name = 'dotnet-sdk-win-x64.zip'; url = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.425/dotnet-sdk-8.0.425-win-x64.zip'; hash = 'f0b6' }) }) }) } }
$sdk = Get-DotnetSdkRelease '8.0'
Assert ($script:metaUri -eq 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json') 'official .NET release metadata URL'
Assert ($sdk.Version -eq '8.0.425' -and $sdk.Url -like '*win-x64.zip' -and $sdk.Sha512 -eq 'f0b6') 'latest SDK found under "sdks" with its SHA-512'
Remove-Item function:Invoke-RestMethod

Write-Host 'Use-Environment'
$env:RVB_KEEP = 'orig'
Use-Environment @{ RVB_KEEP = 'changed'; RVB_NEW = '1' } { Assert ($env:RVB_KEEP -eq 'changed' -and $env:RVB_NEW -eq '1') 'variables applied inside' }
Assert ($env:RVB_KEEP -eq 'orig' -and -not (Test-Path env:RVB_NEW)) 'environment restored afterwards'
try { Use-Environment @{ RVB_KEEP = 'x' } { throw 'boom' } } catch { Write-Verbose 'expected' }
Assert ($env:RVB_KEEP -eq 'orig') 'restored after an exception'

# =============================================================================
Write-Host 'Part 2: Git for Windows pre-check and verified install'
$sha = 'bfe94e7b419b16eee9fecbd1253a98e3d4f49ba8f029630549052278ffe286a6'
$script:apiFails = $false; $script:hashToReturn = $sha; $script:sigStatus = 'Valid'; $script:signer = $null
$script:started = $null; $script:admin = $false
function Invoke-RestMethod { param($Uri, $Headers, [switch]$UseBasicParsing)
    if ($script:apiFails) { throw 'API rate limit exceeded' }
    [pscustomobject]@{ tag_name = 'v2.56.0.windows.1'; body = $md
        assets = @([pscustomobject]@{ name = 'Git-2.56.0-arm64.exe'; browser_download_url = 'https://x/arm' },
            [pscustomobject]@{ name = 'Git-2.56.0-64-bit.exe'; browser_download_url = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.1/Git-2.56.0-64-bit.exe' }) } }
function Invoke-WebRequest { param($Uri, $OutFile, $Headers, [switch]$UseBasicParsing)
    if ($OutFile) { [IO.File]::WriteAllText($OutFile, 'fake'); $script:downloaded = $Uri; return }
    [pscustomobject]@{ Content = '<a href="/git-for-windows/git/releases/tag/v2.47.1.windows.2"><td>Git-2.47.1.2-64-bit.exe</td><td>' + $sha + '</td>' } }
function Get-FileHash { param($Algorithm, $LiteralPath) [pscustomobject]@{ Hash = $script:hashToReturn.ToUpper() } }
function Get-AuthenticodeSignature { param($LiteralPath)
    [pscustomobject]@{ Status = $script:sigStatus; SignerCertificate = [pscustomobject]@{ Subject = $(if ($script:signer) { $script:signer } else { 'CN=Johannes Schindelin, O=Johannes Schindelin' }) } } }
function Start-Process { param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
    $script:started = @{ File = $FilePath; Args = $ArgumentList }; [pscustomobject]@{ ExitCode = 0 } }
function Test-IsAdmin { $script:admin }

$rel = Get-GitForWindowsRelease
Assert ($rel.Name -eq 'Git-2.56.0-64-bit.exe' -and $rel.Sha256 -eq $sha) 'API: x64 installer + checksum'
$script:apiFails = $true
$rel = Get-GitForWindowsRelease 3>$null
Assert ($rel.Name -eq 'Git-2.47.1.2-64-bit.exe' -and $rel.Sha256 -eq $sha) 'page fallback: name + checksum'
$script:apiFails = $false
Install-GitForWindows 6>$null
Assert ($script:downloaded -like 'https://github.com/git-for-windows/*') 'downloads from github.com/git-for-windows'
Assert ((($script:started.Args -join ' ') -match '/VERYSILENT') -and (($script:started.Args -join ' ') -match '/DIR=')) 'silent per-user install when not elevated'
$script:admin = $true; Install-GitForWindows 6>$null
Assert (-not (($script:started.Args -join ' ') -match '/DIR=')) 'all-users install when elevated'
$script:hashToReturn = '0' * 64; $script:started = $null
Assert-Throws { Install-GitForWindows 6>$null } 'SHA-256 mismatch' 'hash mismatch aborts'
Assert ($null -eq $script:started) 'installer not run after hash mismatch'
$script:hashToReturn = $sha; $script:signer = 'CN=Someone Else'
Assert-Throws { Install-GitForWindows 6>$null } 'not .Johannes Schindelin' 'unexpected signer aborts'
$script:signer = $null; $script:sigStatus = 'NotSigned'
Assert-Throws { Install-GitForWindows 6>$null } 'Authenticode' 'invalid signature aborts'
$script:sigStatus = 'Valid'

$fakeGit = [pscustomobject]@{ Root = 'C:\Program Files\Git'; Git = 'C:\Program Files\Git\cmd\git.exe'; Bash = 'C:\Program Files\Git\bin\bash.exe'; Ssh = 'x' }
$script:gitPresent = $true; $script:installs = 0
function Find-GitForWindows { if ($script:gitPresent) { $fakeGit } else { $null } }
function Install-GitForWindows { $script:installs++; $script:gitPresent = $true }
Assert ((Resolve-Git $false $true).Bash -like '*bash.exe') 'existing Git Bash is used (no install)'
Assert ($script:installs -eq 0) 'nothing installed when Git Bash exists'
$script:gitPresent = $false
Assert ((Resolve-Git $true $false).Git -like '*git.exe' -and $script:installs -eq 1) '-InstallGit installs when missing'
$script:gitPresent = $false
function Get-Command { param($Name, $CommandType, $ErrorAction) $null }
Assert-Throws { Resolve-Git $false $true } 'Git for Windows \(Git Bash\) is required' '-NoInstallGit + missing -> clear error'
Remove-Item function:Get-Command

# =============================================================================
Write-Host 'Part 3: full pipeline dry run with recorded tools'
$script:calls = New-Object System.Collections.Generic.List[string]
$script:stubAdmin = $false
$script:failOn = $null
$commit = 'c4964de840d97b1377456a2054662551816b0a54'

function Get-HostInfo { param($WorkDir) [pscustomobject]@{ WindowsBuild = 22631; WindowsName = 'Windows 11 Pro'; Is64Bit = $true; Cpus = 8
        IsAdmin = $script:stubAdmin; FreeGB = 200; LongPaths = $true; SignTool = 'C:\Kits\signtool.exe'
        VisualStudio = [pscustomobject]@{ Name = 'Visual Studio Build Tools 2022'; Version = '17.14.1'; VcVars = 'C:\VS\vcvars64.bat' }
        Git = $fakeGit } }
function Find-GitForWindows { $fakeGit }
function Assert-WindowsDirectory { param($Name, $Value, $MinDepth) }   # temp dirs are POSIX paths on the test host
function Find-LinkExe { 'C:\VS\VC\Tools\MSVC\14.44\bin\Hostx64\x64\link.exe' }
function Save-Download { param($Uri, $OutFile, $Sha256, $Sha512)
    $v = if ($Sha512) { 'sha512' } elseif ($Sha256) { 'sha256' } else { 'UNVERIFIED' }
    $script:calls.Add("download $Uri [$v]"); [IO.File]::WriteAllText($OutFile, 'x') }
function Get-DotnetSdkRelease { param($Channel) [pscustomobject]@{ Version = '8.0.425'; Sha512 = 'f0b6'
        Url = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.425/dotnet-sdk-8.0.425-win-x64.zip' } }
function Expand-ZipFile { param($Zip, $Destination) $script:calls.Add("extract $(Split-Path -Leaf $Zip)"); Touch (Join-Path $Destination 'dotnet.exe') }
function Touch([string]$Path) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null; [IO.File]::WriteAllText($Path, 'x') }

function Invoke-Native {
    param($FilePath, [string[]]$ArgumentList = @(), $WorkingDirectory, $What, [int[]]$OkExitCodes = @(0))
    $line = "$What :: $(Split-Path -Leaf $FilePath) $($ArgumentList -join ' ')"
    $script:calls.Add($line)
    if ($script:failOn -and $What -like $script:failOn) { throw "$What failed (exit code 2): $FilePath" }
    $P = $script:ctxPaths
    switch -Wildcard ($What) {
        'git clone' {
            $dest = $ArgumentList[-1]; New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Set-Content -LiteralPath (Join-Path $dest 'package.xml') -Value '<package><version>1.14.26</version></package>' }
        'micromamba create (tools env)' { Touch (Join-Path $P.ToolsEnv 'Scripts\conda-pack.exe'); Touch $P.ToolsPy }
        'micromamba create*' { New-Item -ItemType Directory -Force -Path $P.Env | Out-Null }
        'install' { Touch (Join-Path $P.Env 'Library\bin\rviz.exe') }
        'conda-pack' { New-Item -ItemType Directory -Force -Path (Join-Path $P.Stage 'conda-meta') | Out-Null }
        'finalize payload' { Touch (Join-Path $P.Out 'payload-files.tsv'); Remove-Item -LiteralPath (Join-Path $P.Stage 'conda-meta') -Recurse -Force }
        'dotnet tool install wix' { Touch $P.Wix }
        'wix build' {
            $rsp = Get-Content -LiteralPath $P.Rsp
            $o = [array]::IndexOf($rsp, '-o'); Touch ($rsp[$o + 1].Trim('"')) }
    }
}
function Invoke-NativeCapture {
    param($FilePath, [string[]]$ArgumentList = @(), $WorkingDirectory, $What, [switch]$AllowFailure)
    $script:calls.Add("$What :: $(Split-Path -Leaf $FilePath) $($ArgumentList -join ' ')")
    switch ($What) {
        'git rev-parse' { return , @($script:headCommit) }
        'micromamba env export' { return , @('@EXPLICIT', 'https://conda.anaconda.org/x.conda') }
        'wix --version' { return , @('5.0.2+aa65968') }
    }
    return , @()
}
function Invoke-BatchSnippet {
    param($Body, $TempDir, $What = 'batch snippet')
    $script:calls.Add("batch :: $What :: $(($Body -split "`n")[-1].Trim())")
    if ($What -like 'conda activation*') {
        $script:lastActivation = $Body
        return [pscustomobject]@{ ExitCode = 0; Lines = @('VCToolsVersion=14.44.35207', 'PATH=C:\VS\bin;C:\rvb\envs\rviz', 'INCLUDE=C:\VS\include') } }
    if ($Body -match 'rviz.cmd') { return [pscustomobject]@{ ExitCode = 0; Lines = @('Allowed options:', '-h [ --help ]  Produce this help message') } }
    if ($Body -match 'rospack plugins') { return [pscustomobject]@{ ExitCode = 0; Lines = @('rviz C:\opt\rviz\noetic\Library\share\rviz\plugin_description.xml') } }
    return [pscustomobject]@{ ExitCode = 0; Lines = @('C:\opt\rviz\noetic\Library\share\rviz') }
}

$work = Join-Path $tmp 'rvb'
$dist = Join-Path $tmp 'dist'
$script:headCommit = $commit
function Run([hashtable]$Extra) {
    $script:calls.Clear()
    $b = @{ WorkDir = $work; OutputDir = $dist } + $Extra
    $script:ctxPaths = Get-BuildPath (Merge-BuildConfig (Read-BuildConfig (Join-Path $repo 'config\build.psd1')) $b) $repo
    $r = @(Invoke-Main $b $repo 6>$null)
    return $r[-1]
}
function Get-StepOrder { @($script:calls | ForEach-Object { ($_ -split ' :: ')[0] }) }

$rc = Run @{ BuildNumber = 3; Manufacturer = 'Relay Robotics' }
Assert ($rc -eq 0) 'full run succeeds'
$order = Get-StepOrder
$expected = @('download https://github.com/mamba-org/micromamba-releases/releases/download/2.9.0-0/micromamba-win-64 [sha256]',
    'download https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.425/dotnet-sdk-8.0.425-win-x64.zip [sha512]', 'extract dotnet-sdk-8.0.425-win-x64.zip',
    'dotnet tool install wix', 'wix extension add',
    'git clone', 'git rev-parse', 'patch check 0001-windows-msvc-relocatable.patch', 'patch 0001-windows-msvc-relocatable.patch',
    'micromamba create (tools env)', 'micromamba create (rviz env)', 'micromamba env export', 'environment check',
    'batch', 'CMake configure', 'compile', 'install', 'conda-pack', 'finalize payload', 'compileall', 'MSI assets',
    'batch', 'batch', 'batch', 'wix build', 'ICE validation (use -SkipValidate to bypass)')
Assert (($order -join '|') -eq ($expected -join '|')) "step order + commands ($($order.Count) calls)"
if (($order -join '|') -ne ($expected -join '|')) { $order | ForEach-Object { Write-Host "     $_" } }

$all = $script:calls -join "`n"
Assert ($all -match 'git clone :: git.exe -c advice.detachedHead=false clone -q --depth 1 --branch 1.14.26 --config core.autocrlf=false') 'clone pinned tag with LF checkout'
Assert ($all -match "micromamba create \(rviz env\) :: micromamba.exe create -y -r \S+ -p \S+ --override-channels -c robostack-noetic -c conda-forge --strict-channel-priority --file") 'env solved with RoboStack first + strict priority'
Assert ($all -match 'CMake configure :: cmake.exe .*-G Ninja --compile-no-warning-as-error -DCMAKE_BUILD_TYPE=Release') 'CMake: Ninja, Release'
Assert ($all -match '-DCATKIN_BUILD_BINARY_PACKAGE=1' -and $all -match '-DRVIZ_BUILD_PYTHON_BINDINGS=ON') 'CMake: catkin binary package, python bindings ON'
Assert ($all -match 'compile :: cmake.exe --build \S+ --parallel 8') 'compile uses all cores'
Assert ($all -match 'conda-pack :: conda-pack.exe -p \S+ -o \S+ --format no-archive --dest-prefix C:\\opt\\rviz\\noetic') 'conda-pack relocates to install prefix'
Assert ($all -match 'finalize payload :: python.exe \S+rvizmsi.py finalize .*--prefix C:\\opt\\rviz\\noetic .*--keep-pdb 0') 'finalize invoked with prefix'
Assert ($all -match 'wix build :: wix.exe build @') 'wix build uses response file'
Assert (-not ($all -match 'UNVERIFIED')) 'every download is checksum-verified'
Assert (($all -match 'MSI assets :: python.exe \S+ assets ') -and -not ($all -match '--icon')) 'no empty --icon argument by default'
Assert ($script:lastActivation -match 'activate\.d' -and $script:lastActivation -match 'call "C:\\VS\\vcvars64.bat"') 'build env = conda activation then vcvars64'
$rsp = Get-Content -LiteralPath $script:ctxPaths.Rsp
Assert ($rsp -contains '"Manufacturer=Relay Robotics"' -and $rsp -contains '"ProductVersion=1.14.2603"' -and $rsp -contains '"InstallPrefix=C:\opt\rviz\noetic"') 'WiX defines (manufacturer, version, prefix)'
Assert (-not ($rsp -match '\\"$')) 'no response-file value ends in a backslash'
$msiName = 'RVizNoetic-1.14.26-1.14.2603-x64.msi'
Assert ((Test-Path (Join-Path $dist $msiName)) -and (Test-Path (Join-Path $dist "$msiName.sha256"))) 'MSI + .sha256 copied to OutputDir'
Assert ((Get-Content (Join-Path $dist "$msiName.sha256")) -match "^[0-9a-f]{64}  $([regex]::Escape($msiName))$") 'sha256 file in standard format'
Assert (Test-Path (Join-Path $dist 'RVizNoetic-1.14.26-1.14.2603-x64.conda-lock-win-64.txt')) 'lock file published next to the MSI'
$log = Get-ChildItem (Join-Path $work 'out') -Filter 'build-*.log' | Select-Object -Last 1
Assert ($log -and ((Get-Content $log.FullName -Raw) -match '==> msi')) 'build log written'
Assert ($env:CL -ne '/DROS_BUILD_SHARED_LIBS=1 /DNOGDI=1') 'build-only variables do not leak into the session'

Write-Host 'resume / invalidation'
$rc = Run @{ BuildNumber = 3 }
Assert ($rc -eq 0 -and ((Get-StepOrder) -join '|') -eq 'wix build|ICE validation (use -SkipValidate to bypass)') 'unchanged inputs: only the MSI is rebuilt'
$rc = Run @{ FromStep = 'pack' }
Assert (((Get-StepOrder) -join '|') -match '^conda-pack\|finalize payload\|compileall\|MSI assets\|batch\|batch\|batch\|wix build') '-FromStep pack reruns pack and later steps'
$rc = Run @{ ExtraPackages = @('ros-noetic-rviz-imu-plugin') }
Assert (((Get-StepOrder)[0..1] -join '|') -eq 'micromamba create (rviz env)|micromamba env export') 'extra package re-solves the environment...'
Assert ((Get-StepOrder) -contains 'CMake configure' -and (Get-StepOrder) -contains 'wix build') '...and rebuilds everything after it'
Assert ((Get-Content $script:ctxPaths.Specs) -contains 'ros-noetic-rviz-imu-plugin') 'extra package in specs'
$rc = Run @{ ExtraPackages = @('ros-noetic-rviz-imu-plugin'); NoPythonBindings = [switch]$true }
Assert (((Get-StepOrder)[0..1] -join '|') -eq 'batch|CMake configure' -and ($script:calls -join ' ') -match 'RVIZ_BUILD_PYTHON_BINDINGS=OFF') '-NoPythonBindings rebuilds from the compile step'
$rc = Run @{ ExtraPackages = @('ros-noetic-rviz-imu-plugin'); NoPythonBindings = [switch]$true; OnlyStep = 'smoke' }
Assert (((Get-StepOrder) -join '|') -eq 'batch|batch|batch') '-OnlyStep smoke runs just the smoke test'
$rc = Run @{ ExtraPackages = @('ros-noetic-rviz-imu-plugin'); NoPythonBindings = [switch]$true; SkipValidate = [switch]$true; SignThumbprint = 'ABC123' }
Assert (($script:calls -join "`n") -match 'signtool sign :: signtool.exe sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /d RViz \(ROS Noetic\) /sha1 ABC123') 'signing with a store certificate'
Assert (-not ((Get-StepOrder) -match 'ICE validation')) '-SkipValidate skips ICE'

Write-Host 'finalize / icon / pfx'
$icon = Join-Path $tmp 'my.ico'; Set-Content -LiteralPath $icon -Value 'x'
$rc = Run @{ ExtraPackages = @('ros-noetic-rviz-imu-plugin'); NoPythonBindings = [switch]$true; IconFile = $icon }
Assert (((Get-StepOrder)[0..1] -join '|') -eq 'conda-pack|finalize payload') 'finalize re-run re-packs a pristine stage first'
Assert (($script:calls -join ' ') -match ('--icon ' + [regex]::Escape($icon))) 'custom icon passed to assets'
$env:SIGN_PFX_PASSWORD = 'pfx-s3cret'
$rc = Run @{ ExtraPackages = @('ros-noetic-rviz-imu-plugin'); NoPythonBindings = [switch]$true; IconFile = $icon; SignPfx = (Join-Path $tmp 'c.pfx') }
Assert ($rc -eq 0 -and ($script:calls -join ' ') -match '/f \S+c.pfx /p pfx-s3cret') 'signing with a .pfx'
Remove-Item env:SIGN_PFX_PASSWORD
$rc = Run @{ ExtraPackages = @('ros-noetic-rviz-imu-plugin'); NoPythonBindings = [switch]$true; IconFile = $icon; SignPfx = (Join-Path $tmp 'c.pfx') }
Assert ($rc -eq 1) '.pfx without $env:SIGN_PFX_PASSWORD is refused up front'

Write-Host 'failures and guards'
$script:failOn = 'compile'
$rc = Run @{ Clean = [switch]$true }
Assert ($rc -eq 1) 'compile failure -> exit code 1'
$log = Get-ChildItem (Join-Path $work 'out') -Filter 'build-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1
Assert ((Get-Content $log.FullName -Raw) -match 'ERROR: compile failed') 'failure recorded in the log'
$script:failOn = $null
$rc = Run @{}
Assert ($rc -eq 0 -and (((Get-StepOrder)[0..1]) -join '|') -eq 'batch|CMake configure') 'next run resumes at the failed (build) step'
Assert (-not ((Get-StepOrder) -contains 'git clone')) 'completed steps are not repeated after a failure'
$script:headCommit = '1111111111111111111111111111111111111111'
$rc = Run @{ FromStep = 'source' }
Assert ($rc -eq 1) 'moved tag (commit mismatch) stops the build'
$script:headCommit = $commit
$rc = Run @{ LockFile = (Join-Path $tmp 'missing.txt') }
Assert ($rc -eq 1) 'missing lock file rejected'
$rc = Run @{ OnlyStep = 'test-install'; TestInstall = [switch]$true; HeadlessTest = [switch]$true }
Assert ($rc -eq 0 -and $script:calls.Count -eq 0) '-TestInstall without elevation is skipped, not failed'
$script:stubAdmin = $true
$rc = Run @{ OnlyStep = 'test-install'; TestInstall = [switch]$true; HeadlessTest = [switch]$true }
Assert ($rc -eq 0 -and ($script:calls -join ' ') -match 'install/run/uninstall test :: \S+ .*test_install.ps1 -Msi \S+RVizNoetic-1.14.26-1.14.2600-x64.msi -Prefix C:\\opt\\rviz\\noetic .*-SkipGui') '-TestInstall -HeadlessTest runs test_install.ps1 -SkipGui'
$script:stubAdmin = $false
$fresh = Join-Path $tmp 'fresh'
$script:calls.Clear()
$rc = @(Invoke-Main @{ WorkDir = $fresh; OutputDir = $dist; OnlyStep = 'tools' } $repo 6>$null)[-1]
Assert ($rc -eq 0 -and (Get-StepOrder) -contains 'wix extension add' -and -not ((Get-StepOrder) -contains 'git clone')) '-OnlyStep tools works on a fresh work dir'
Push-Location $tmp
Set-Content -LiteralPath (Join-Path $tmp 'rel-lock.txt') -Value @('@EXPLICIT', 'https://x/y.conda')
$rc = Run @{ LockFile = 'rel-lock.txt'; FromStep = 'env' }
Pop-Location
Assert ($rc -eq 0 -and ($script:calls -join ' ') -match 'micromamba create \(from lock\)') 'relative -LockFile resolved and used'
$rc = Run @{ CheckOnly = [switch]$true }
Assert ($rc -eq 0 -and $script:calls.Count -eq 0) '-CheckOnly runs no tools'

if (-not $env:KEEP_TMP) { Remove-Item -Recurse -Force $tmp } else { Write-Host "kept $tmp" }
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:Passes, $script:Failures)
if ($script:Failures) { exit 1 } else { exit 0 }
