# Lint settings: Invoke-ScriptAnalyzer -Path <file> -Settings ./PSScriptAnalyzerSettings.psd1
@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                       # console tool: output is for humans
        'PSUseShouldProcessForStateChangingFunctions', # internal helpers, not exported cmdlets
        'PSAvoidUsingPositionalParameters'             # internal helpers called with fixed arity
    )
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.4') }
    }
}
