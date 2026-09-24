#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host 'Cloning Git repositories.'

$git = Get-Command git.exe -ErrorAction SilentlyContinue

if ($null -eq $git) {
    throw 'git.exe is not available. Install Git before this step.'
}

$repoRoot = Join-Path $env:USERPROFILE 'source\repos'

New-Item `
    -ItemType Directory `
    -Path $repoRoot `
    -Force | Out-Null

# Add repositories here.
$repos = @(
    @{
        Url  = 'https://github.com/mdelgert/proxmox-win11.git'
        Name = 'proxmox-win11'
    }
    @{
        Url  = 'https://github.com/example/win11.git'
        Name = 'win11'
    }
)

foreach ($repo in $repos) {

    $destination = Join-Path $repoRoot $repo.Name

    if (Test-Path -LiteralPath (Join-Path $destination '.git')) {
        Write-Host "Repository already exists: $($repo.Name)"
        continue
    }

    if (Test-Path -LiteralPath $destination) {
        throw "Destination exists but is not a Git repository: $destination"
    }

    Write-Host "Cloning $($repo.Url)"
    Write-Host "Destination: $destination"

    & git.exe clone `
        $repo.Url `
        $destination

    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed for '$($repo.Url)' with exit code $LASTEXITCODE"
    }
}

Write-Host 'Repository cloning completed.'