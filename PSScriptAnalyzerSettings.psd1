@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The scripts are interactive console tools; colored Write-Host output is intended.
        'PSAvoidUsingWriteHost'
    )
}
