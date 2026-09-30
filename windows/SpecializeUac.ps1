# Paste this script into the Unattend Generator's "System" script section, so
# it runs as SYSTEM during the specialize pass, before the first user logon.
#
# Why this exists:
#   UserOnce runs under the logged-on user's *non-elevated* token, even when
#   that user is a member of Administrators. windows/UserOnce.ps1 therefore
#   calls "Start-Process -Verb RunAs" to launch the bootstrap elevated. With
#   default UAC settings that raises a consent dialog on the secure desktop, and
#   the first logon is unattended, so nobody is there to click "Yes" - the
#   bootstrap silently never starts.
#
#   ConsentPromptBehaviorAdmin = 0 means "elevate without prompting" for
#   administrators, which makes that RunAs succeed unattended.
#
# EnableLUA is deliberately left at 1. Turning UAC off entirely breaks Appx and
# Store servicing, which the WinGet bootstrap steps depend on.
#
# The weakened setting is needed for exactly one launch. Every later resume
# comes from the SYSTEM startup task, which does not need UAC at all, so
# windows/bootstrap.ps1 restores the Windows default (5) as soon as that task is
# registered - before any customization step runs. A failed or abandoned run
# therefore cannot leave the machine with prompt-free elevation.

$ErrorActionPreference = 'Stop'

$key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

reg.exe add $key /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f
