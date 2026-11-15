# Runs at Claude Code session start (SessionStart hook in ~/.claude/settings.json).
# Pulls the main branch of ai-skills and links each skill into ~/.claude/skills.
# Installed by workstation-setup\Install-Workstation.ps1 -- edit it there, not in ~/.claude.
param([string]$Repo = 'c:\code\ai-skills-main')
$ErrorActionPreference = 'Stop'

$skillsSrc = Join-Path $Repo 'skills'
$skillsDst = Join-Path $env:USERPROFILE '.claude\skills'

# Update main; a failure (offline, etc.) keeps the last pulled copy.
git -C $Repo pull --ff-only --quiet 2>$null
$pulled = ($LASTEXITCODE -eq 0)

if (-not (Test-Path $skillsSrc)) { exit 0 }   # main has no skills yet
New-Item -ItemType Directory -Force -Path $skillsDst | Out-Null

$added = @()
foreach ($skill in Get-ChildItem $skillsSrc -Directory) {
    $link = Join-Path $skillsDst $skill.Name
    if (-not (Test-Path $link)) {
        New-Item -ItemType Junction -Path $link -Target $skill.FullName | Out-Null
        $added += $skill.Name
    }
}

# Remove links to skills that were deleted from main (only junctions pointing into the repo).
foreach ($item in Get-ChildItem $skillsDst -Directory) {
    if ($item.LinkType -eq 'Junction' -and "$($item.Target)" -like "$skillsSrc*" -and -not (Test-Path "$($item.Target)")) {
        [System.IO.Directory]::Delete($item.FullName)   # removes the link only, not the target
    }
}

$msg = @()
if (-not $pulled) { $msg += 'ai-skills: could not pull main, using last copy' }
if ($added)       { $msg += "ai-skills: linked $($added -join ', ')" }
if ($msg) { @{ systemMessage = ($msg -join '; ') } | ConvertTo-Json -Compress }
