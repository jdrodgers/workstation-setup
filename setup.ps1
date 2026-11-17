<#
.SYNOPSIS
    Windows bootstrap: makes sure Git and Python 3.9+ are installed, then runs the Python setup.

.DESCRIPTION
    Uses winget (part of Windows 10/11 "App Installer") for anything missing, then runs
    `python -m workstation <command>` from this folder. Everything after the bootstrap is
    the same Python code that runs on macOS and Linux.

    With no arguments it runs `install`. Pass `check` for the read-only report, or
    `install --dry-run` to see what would change (the bootstrap then installs nothing either).

.EXAMPLE
    .\setup.ps1 check
    .\setup.ps1 install --dry-run
    .\setup.ps1 install --git-name "Jane Doe" --git-email "jane@example.com"
#>
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

$ErrorActionPreference = 'Stop'
if (-not $Arguments) { $Arguments = @('install') }
$dryRun = ($Arguments -contains '--dry-run') -or ($Arguments[0] -eq 'check')

# winget updates the registry PATH, not this session's.
function Sync-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# Returns the command (as an array) that starts Python 3.9+, or $null. Tries the py launcher
# first; plain `python` may be the Microsoft Store alias, which only opens the Store.
function Find-Python {
    $ErrorActionPreference = 'Continue'
    foreach ($candidate in @(@('py', '-3'), @('python'))) {
        if (-not (Get-Command $candidate[0] -ErrorAction SilentlyContinue)) { continue }
        $pyArgs = @($candidate | Select-Object -Skip 1) + @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)')
        & $candidate[0] @pyArgs 2>$null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    $null
}

# Installs a winget package unless a dry run; fails clearly when winget is missing.
function Install-Package([string]$Name, [string]$Id) {
    if ($dryRun) { Write-Host "    would install $Name (winget $Id)"; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "$Name is missing and winget is not available. Install ""App Installer"" from the Microsoft Store, then re-run."
    }
    Write-Host "==> Installing $Name"
    winget install --id $Id --exact --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install $Id failed (exit code $LASTEXITCODE)" }
    Sync-SessionPath
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Install-Package 'Git' 'Git.Git' }
$python = Find-Python
if (-not $python) {
    Install-Package 'Python 3' 'Python.Python.3.13'
    $python = Find-Python
    if (-not $python) {
        if ($dryRun) { Write-Host '    (the Python setup runs once Python is installed)'; exit 0 }
        throw 'Python was installed but is not on PATH yet. Open a new terminal and re-run .\setup.ps1'
    }
}

Push-Location $PSScriptRoot
try {
    $pyArgs = @($python | Select-Object -Skip 1) + @('-m', 'workstation') + $Arguments
    & $python[0] @pyArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
