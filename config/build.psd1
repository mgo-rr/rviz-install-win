# build.psd1 - pinned inputs for build-rviz-msi.ps1 (PowerShell data file:
# values only, no code runs). Command-line parameters override these values.
@{
    # --- Source ------------------------------------------------------------------
    RvizRepo            = 'https://github.com/ros-visualization/rviz.git'
    RvizRef             = '1.14.26'
    # Expected commit of RvizRef; '' skips the check. Tag 1.14.26 == noetic-devel
    # HEAD as of 2025-05-02.
    RvizCommit          = 'c4964de840d97b1377456a2054662551816b0a54'

    # --- Layout ------------------------------------------------------------------
    # The bundled environment is relocated to exactly this path at build time,
    # so the MSI always installs here. No spaces (ROS 1 tooling breaks on them).
    InstallPrefix       = 'C:\opt\rviz\noetic'
    # Build work area: no spaces, keep it short (MAX_PATH = 260).
    WorkDir             = 'C:\rvb'

    # --- Product metadata -----------------------------------------------------------
    ProductName         = 'RViz (ROS Noetic)'
    ProductKey          = 'RVizNoetic'          # registry key / file-name stem
    Manufacturer        = 'RViz MSI Builder'    # set your organisation (-Manufacturer)
    # NEVER change UpgradeCode once an MSI has shipped: it ties all versions
    # together so newer MSIs upgrade older ones in place. Forks that publish
    # their own MSIs should generate a new one once: [guid]::NewGuid()
    UpgradeCode         = 'AAE172F2-3929-414B-8F91-7520B9CDD4F8'
    # MSI ProductVersion = <major>.<minor>.<patch * 100 + BuildNumber>
    BuildNumber         = 0
    AboutUrl            = 'https://github.com/ros-visualization/rviz'
    IconFile            = ''                    # optional .ico; default is rviz's icon

    # --- Toolchain pins --------------------------------------------------------------
    MicromambaVersion   = '2.9.0-0'
    MicromambaSha256    = 'a6d804394b2418991c4e29562853eaace2f2ce9d9da661a98e74e02e8dbb44b0'
    # WiX 5.0.2 is MS-RL licensed. WiX >= 6 binaries fall under the Open Source
    # Maintenance Fee EULA for revenue-generating users - review before bumping.
    WixVersion          = '5.0.2'
    DotnetChannel       = '8.0'
    # conda channels, highest priority first (strict priority is enforced)
    CondaChannels       = @('robostack-noetic', 'conda-forge')

    # --- Build knobs -------------------------------------------------------------------
    Jobs                = 0                     # 0 = all cores
    MinFreeGB           = 25
    BuildPythonBindings = $true
    KeepPdb             = $false
    ExtraCondaPackages  = @()                   # extra runtime packages to ship

    # --- Code signing (optional) ---------------------------------------------------------
    SignThumbprint      = ''                    # certificate in the Windows store (SHA1)
    SignPfx             = ''                    # or a .pfx file; password in $env:SIGN_PFX_PASSWORD
    SignTimestampUrl    = 'http://timestamp.digicert.com'
}
