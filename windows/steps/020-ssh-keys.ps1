# Install public SSH keys from a GitHub account into the OpenSSH Server.
#
# GitHub publishes every account's public keys at https://github.com/<user>.keys.
# Only public keys are exposed there, so nothing secret is downloaded.
#
# Windows OpenSSH does NOT use a normal ~/.ssh/authorized_keys file for members
# of the Administrators group. The default sshd_config contains:
#
#     Match Group administrators
#         AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
#
# so keys for administrator accounts must go in the machine-wide file below,
# which also requires restrictive ACLs or sshd silently refuses to use it.
#
# The step is idempotent: existing keys are preserved and duplicates are never
# appended. No reboot is required and sshd does not need a restart, because
# authorized key files are read on every incoming connection.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$GitHubUser = 'mdelgert'
$KeysUrl = "https://github.com/$GitHubUser.keys"
$SshDataDir = Join-Path $env:ProgramData 'ssh'
$AuthorizedKeysFile = Join-Path $SshDataDir 'administrators_authorized_keys'

# Well-known SIDs are used instead of names such as BUILTIN\Administrators so
# the ACL is applied correctly on non-English Windows installations.
$AdministratorsSid = 'S-1-5-32-544'
$SystemSid = 'S-1-5-18'

Write-Host "Fetching public SSH keys for GitHub user '$GitHubUser'..."

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$response = Invoke-WebRequest -UseBasicParsing -Uri $KeysUrl -ErrorAction Stop
$downloaded = [string]$response.Content

# Accept the key types GitHub can publish; reject anything unexpected so a
# captive portal or error page is never written into an authorized key file.
$keyPattern = '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) '

$newKeys = @()

foreach ($line in ($downloaded -split "`r?`n")) {
    $key = $line.Trim()

    if ($key.Length -eq 0) {
        continue
    }

    if ($key -notmatch $keyPattern) {
        throw "Unexpected content at ${KeysUrl}: '$key'"
    }

    $newKeys += $key
}

if ($newKeys.Count -eq 0) {
    throw "No public SSH keys were published at $KeysUrl."
}

Write-Host "Found $($newKeys.Count) public key(s)."

if (-not (Test-Path -LiteralPath $SshDataDir)) {
    throw "The OpenSSH data directory was not found: $SshDataDir. Run the OpenSSH step first."
}

$existingKeys = @()

if (Test-Path -LiteralPath $AuthorizedKeysFile) {
    foreach ($line in (Get-Content -LiteralPath $AuthorizedKeysFile)) {
        $key = $line.Trim()

        if ($key.Length -gt 0) {
            $existingKeys += $key
        }
    }
}

# Keep any keys that were already present, in their original order, and append
# only the ones that are genuinely missing.
$finalKeys = @()
$finalKeys += $existingKeys
$added = 0

foreach ($key in $newKeys) {
    if ($finalKeys -notcontains $key) {
        $finalKeys += $key
        $added++
    }
}

if ($added -gt 0) {
    Write-Host "Adding $added new key(s) to $AuthorizedKeysFile"
}
else {
    Write-Host 'All downloaded keys are already authorized.'
}

# Always rewrite the file so encoding and ACLs are corrected even when no new
# key was added. ASCII with LF endings avoids the UTF-8 BOM that sshd rejects.
$content = ($finalKeys -join "`n") + "`n"
[IO.File]::WriteAllText($AuthorizedKeysFile, $content, (New-Object Text.ASCIIEncoding))

# sshd refuses an administrators_authorized_keys file that is writable by
# anyone other than Administrators and SYSTEM, so inheritance is removed.
$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'

& $icacls $AuthorizedKeysFile /inheritance:r /grant "*${AdministratorsSid}:F" /grant "*${SystemSid}:F" | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "icacls failed to set permissions on $AuthorizedKeysFile (exit code $LASTEXITCODE)."
}

# Verify the desired end state instead of assuming the writes worked.
$verifyKeys = @()

foreach ($line in (Get-Content -LiteralPath $AuthorizedKeysFile)) {
    $key = $line.Trim()

    if ($key.Length -gt 0) {
        $verifyKeys += $key
    }
}

foreach ($key in $newKeys) {
    if ($verifyKeys -notcontains $key) {
        throw "A downloaded key is missing from $AuthorizedKeysFile after the update."
    }
}

Write-Host "$AuthorizedKeysFile now contains $($verifyKeys.Count) authorized key(s)."
Write-Host 'GitHub SSH keys are installed for administrator accounts.'

# Request a reboot to ensure all changes take effect.
Request-Reboot