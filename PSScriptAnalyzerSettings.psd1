@{
    Severity = @('Error', 'Warning')
    IncludeDefaultRules = $true
    ExcludeRules = @(
        'PSAvoidUsingCmdletAliases',
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
