<#
    Install applications with winget.

    Anything newly installed changes PATH for future sessions, so this step
    asks for a reboot only when it actually installed something. Re-running it
    on a machine that already has everything is a no-op that exits 0.
#>
. "$PSScriptRoot\_lib.ps1"

$packages = @(
    'Git.Git'
    'Microsoft.PowerShell'
    '7zip.7zip'
)

$installedSomething = $false
foreach ($package in $packages) {
    if (Install-WingetPackage -Id $package) { $installedSomething = $true }
}

if ($installedSomething) {
    Write-Info 'New software was installed; requesting a reboot.'
    exit 3010
}

Write-Info 'All packages were already present.'
exit 0
