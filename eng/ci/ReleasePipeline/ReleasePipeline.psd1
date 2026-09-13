@{
    RootModule = 'ReleasePipeline.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'b80792d6-8b52-4b14-9a67-650a6cdb1b2a'
    Author = 'Repository contributors'
    Description = 'Provider-neutral Windows release planning and packaging tools.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Import-ReleaseConfig', 'Get-ReleaseChannel', 'Get-ComponentVersion',
        'Get-ChangedComponents', 'New-ReleasePlan', 'New-ArtifactPromotionPlan', 'Invoke-ComponentPackage', 'Invoke-ComponentContainerPackage', 'Invoke-ComponentBuild',
        'New-ReleaseTag'
    )
}
