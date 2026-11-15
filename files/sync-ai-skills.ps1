# Runs at Claude Code session start (SessionStart hook in ~/.claude/settings.json).
# For each skill repo's main worktree: pulls main and links each skill into ~/.claude/skills.
# Installed by workstation-setup\Install-Workstation.ps1 -- edit it there, not in ~/.claude.
#   -Repo  one or more main-worktree paths, separated by ';'
param([string]$Repo = 'c:\code\ai-skills-main')
$ErrorActionPreference = 'Continue'   # git writes progress to stderr; exit codes decide

$skillsDst = Join-Path $env:USERPROFILE '.claude\skills'
New-Item -ItemType Directory -Force -Path $skillsDst | Out-Null

$msg = @()
foreach ($r in ($Repo -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $name = Split-Path $r -Leaf
    if (-not (Test-Path $r)) { $msg += "${name}: not found"; continue }

    # Update main; a failure (offline, etc.) keeps the last pulled copy.
    git -C $r pull --ff-only --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { $msg += "${name}: could not pull main, using last copy" }

    $skillsSrc = Join-Path $r 'skills'
    if (-not (Test-Path $skillsSrc)) { continue }

    $added = @()
    foreach ($skill in Get-ChildItem $skillsSrc -Directory) {
        $link = Join-Path $skillsDst $skill.Name
        if (-not (Test-Path $link)) {
            New-Item -ItemType Junction -Path $link -Target $skill.FullName | Out-Null
            $added += $skill.Name
            continue
        }
        $existing = Get-Item $link
        if ($existing.LinkType -eq 'Junction' -and "$($existing.Target)" -ne $skill.FullName) {
            $msg += "${name}: skill '$($skill.Name)' already comes from $($existing.Target); rename one"
        }
    }
    if ($added) { $msg += "${name}: linked $($added -join ', ')" }

    # Remove links to skills deleted from this repo (only junctions pointing into it).
    foreach ($item in Get-ChildItem $skillsDst -Directory) {
        if ($item.LinkType -eq 'Junction' -and "$($item.Target)" -like "$skillsSrc*" -and -not (Test-Path "$($item.Target)")) {
            [System.IO.Directory]::Delete($item.FullName)   # removes the link only, not the target
        }
    }
}

if ($msg) { @{ systemMessage = ($msg -join '; ') } | ConvertTo-Json -Compress }
