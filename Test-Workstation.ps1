<#
.SYNOPSIS
    Checks that this workstation is set up for the VS Code + GitHub + Claude Code workflow.

.DESCRIPTION
    Read-only. Reports Pass / Warn / Fail for each check with a suggested fix,
    and exits 1 if anything fails. Edit config\workstation.json to change what is required.

.PARAMETER PassThru
    Return the result objects instead of printing a report.

.EXAMPLE
    .\Test-Workstation.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$PassThru
)

# $PSScriptRoot isn't available in param defaults under Windows PowerShell 5.1 -File.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\workstation.json' }

Import-Module (Join-Path $root 'lib\Workstation.psm1') -Force
$config  = Import-WorkstationConfig -Path $ConfigPath
$results = @(Get-WorkstationStatus -Config $config)

if ($PassThru) { return $results }

$colors = @{ Pass = 'Green'; Warn = 'Yellow'; Fail = 'Red' }
$area = ''
foreach ($r in $results) {
    if ($r.Area -ne $area) {
        $area = $r.Area
        Write-Host ''
        Write-Host $area -ForegroundColor Cyan
    }
    Write-Host ('  [{0}] ' -f $r.Status.ToUpper()) -ForegroundColor $colors[$r.Status] -NoNewline
    Write-Host ('{0,-22} {1}' -f $r.Check, $r.Detail)
    if ($r.Status -ne 'Pass' -and $r.Fix) {
        Write-Host ('         fix: {0}' -f $r.Fix) -ForegroundColor DarkGray
    }
}

$fail = @($results | Where-Object Status -eq 'Fail').Count
$warn = @($results | Where-Object Status -eq 'Warn').Count
$pass = @($results | Where-Object Status -eq 'Pass').Count
Write-Host ''
$summaryColor = 'Green'
if ($warn) { $summaryColor = 'Yellow' }
if ($fail) { $summaryColor = 'Red' }
Write-Host ("{0} passed, {1} warning(s), {2} failed" -f $pass, $warn, $fail) -ForegroundColor $summaryColor
if ($fail) {
    Write-Host 'Run .\Install-Workstation.ps1 to fix what it can.' -ForegroundColor DarkGray
    exit 1
}
exit 0
