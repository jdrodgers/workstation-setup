<#
.SYNOPSIS
    Installs and configures what Test-Workstation.ps1 checks for.

.DESCRIPTION
    Safe to re-run: each step is skipped when it is already done.
      1. Installs missing tools with winget (Git, GitHub CLI, VS Code)
      2. Sets git user.name / user.email if missing
      3. Signs in to GitHub CLI (opens a browser) and adds missing token scopes
      4. Installs the VS Code extensions from config\workstation.json
      5. Creates the code root folder
      6. Clones each skill repo (public ai-skills, private ai-skills-private), adds
         its main worktree, and enables the local push guard where configured
      7. Claude Code: installs the sync script and SessionStart hook, adds deny
         rules for secret files, and creates the private terms file used by the
         public-repo-hygiene scanner (~/.claude/settings.json is backed up first)
    Then runs Test-Workstation.ps1.

    Use -WhatIf to see what it would do without changing anything.

.EXAMPLE
    .\Install-Workstation.ps1 -WhatIf
    .\Install-Workstation.ps1 -GitName "Jane Doe" -GitEmail "jane@example.com"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath,
    [string]$GitName,
    [string]$GitEmail,
    [switch]$SkipOptionalExtensions
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot isn't available in param defaults under Windows PowerShell 5.1 -File.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\workstation.json' }
Import-Module (Join-Path $root 'lib\Workstation.psm1') -Force
$config = Import-WorkstationConfig -Path $ConfigPath
$claude = Get-ClaudePath

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Skip([string]$Text) { Write-Host "    ok: $Text" -ForegroundColor DarkGray }

# Uses .NET directly because Get-FileHash returns nothing under -WhatIf, which made
# every file look identical in a dry run.
function Get-FileSha([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) }
    finally { $sha.Dispose() }
}

# Runs a native command and throws if it fails (native exit codes don't trigger -ErrorAction).
function Invoke-Native {
    param([string]$Description, [scriptblock]$Command)
    # Progress text on stderr (git, winget) must not count as failure; the exit code decides.
    $ErrorActionPreference = 'Continue'
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit code $LASTEXITCODE)" }
}

# --- 1. Tools ---
Write-Step 'Tools'
foreach ($tool in $config.tools) {
    if (Test-CommandExist $tool.command) { Write-Skip $tool.name; continue }
    if (-not (Test-CommandExist 'winget')) {
        $msg = "$($tool.name) is missing and winget is not available. Install ""App Installer"" from the Microsoft Store, then re-run."
        if ($WhatIfPreference) { Write-Warning $msg; continue }
        throw $msg
    }
    if ($PSCmdlet.ShouldProcess($tool.name, "winget install $($tool.wingetId)")) {
        Invoke-Native "Installing $($tool.name)" {
            winget install --id $tool.wingetId --exact --silent --accept-source-agreements --accept-package-agreements
        }
        Sync-SessionPath
    }
}

# --- 2. Git identity ---
Write-Step 'Git identity'
if (Test-CommandExist 'git') {
    foreach ($pair in @(@('user.name', $GitName, 'Your name for git commits'), @('user.email', $GitEmail, 'Your email for git commits'))) {
        $key, $value, $prompt = $pair
        if (git config --global --get $key) { Write-Skip $key; continue }
        if (-not $value) { $value = Read-Host $prompt }
        if ($value -and $PSCmdlet.ShouldProcess("git config --global $key", 'Set')) {
            git config --global $key $value
        }
    }
}

# --- 3. GitHub CLI ---
Write-Step 'GitHub CLI'
if (Test-CommandExist 'gh') {
    $scopes = $config.github.requiredScopes
    if (-not (Test-GhSignedIn)) {
        if ($PSCmdlet.ShouldProcess('github.com', 'gh auth login (opens a browser)')) {
            Invoke-Native 'gh auth login' { gh auth login --hostname github.com --git-protocol https --web --scopes ($scopes -join ',') }
        }
    } else {
        Write-Skip 'signed in'
        $have = Get-GhTokenScope
        if ($null -ne $have) {
            $missing = @($scopes | Where-Object { $have -notcontains $_ })
            if ($missing.Count -and $PSCmdlet.ShouldProcess('github.com', "gh auth refresh -s $($missing -join ',')")) {
                Invoke-Native 'gh auth refresh' { gh auth refresh --hostname github.com --scopes ($missing -join ',') }
            }
        }
    }
    if (-not (git config --get credential.helper)) {
        if ($PSCmdlet.ShouldProcess('git', 'gh auth setup-git')) { Invoke-Native 'gh auth setup-git' { gh auth setup-git } }
    } else { Write-Skip 'git credential helper' }
}

# --- 4. VS Code extensions ---
Write-Step 'VS Code extensions'
if (Test-CommandExist 'code') {
    $installed = Get-VSCodeExtension
    foreach ($ext in $config.vscodeExtensions) {
        if ($installed -contains $ext.id.ToLowerInvariant()) { Write-Skip $ext.name; continue }
        if ($ext.required -eq $false -and $SkipOptionalExtensions) { Write-Skip "$($ext.name) (optional, skipped)"; continue }
        if ($PSCmdlet.ShouldProcess($ext.id, 'code --install-extension')) {
            Invoke-Native "Installing $($ext.name)" { code --install-extension $ext.id }
        }
    }
}

# --- 5. Code root ---
Write-Step 'Folders'
$codeRoot = [Environment]::ExpandEnvironmentVariables($config.codeRoot)
if (Test-Path $codeRoot) { Write-Skip $codeRoot }
elseif ($PSCmdlet.ShouldProcess($codeRoot, 'Create folder')) { New-Item -ItemType Directory -Path $codeRoot | Out-Null }

# --- 6. Skill repos ---
$repos = @(Get-SkillRepo -Config $config)
foreach ($r in $repos) {
    Write-Step $r.Name

    if (Test-Path (Join-Path $r.Clone '.git')) { Write-Skip "clone at $($r.Clone)" }
    elseif ($PSCmdlet.ShouldProcess($r.Clone, "gh repo clone $($r.Repo)")) {
        Invoke-Native "Cloning $($r.Repo)" { gh repo clone $r.Repo $r.Clone }
    }

    if (Test-Path $r.Worktree) { Write-Skip "main worktree at $($r.Worktree)" }
    elseif ($PSCmdlet.ShouldProcess($r.Worktree, 'git worktree add (main)')) {
        Invoke-Native 'git fetch' { git -C $r.Clone fetch --quiet origin }
        # main can only be checked out in one place, so move the working clone off it first.
        if ((git -C $r.Clone branch --show-current) -eq 'main') {
            Invoke-Native 'Detaching working clone' { git -C $r.Clone switch --quiet --detach origin/main }
        }
        Invoke-Native 'git worktree add' { git -C $r.Clone worktree add $r.Worktree main }
        Invoke-Native 'Setting upstream' { git -C $r.Worktree branch --quiet --set-upstream-to=origin/main main }
    }

    # Repos without server-side branch protection (free private repos) get a local pre-push guard.
    if ($r.LocalMainGuard -and (Test-Path (Join-Path $r.Clone '.git'))) {
        if ((git -C $r.Clone config --get core.hooksPath) -eq 'hooks') { Write-Skip 'push guard on main' }
        elseif ($PSCmdlet.ShouldProcess($r.Clone, 'git config core.hooksPath hooks (blocks pushes to main)')) {
            Invoke-Native 'Enabling push guard' { git -C $r.Clone config core.hooksPath hooks }
        }
    }
}

# --- 7. Claude Code: sync hook, deny rules, private terms file ---
Write-Step 'Claude Code'
if ($repos.Count) {
    $syncSource = Join-Path $root 'files\sync-ai-skills.ps1'
    $needsCopy = -not (Test-Path $claude.SyncScript) -or
        ((Get-FileSha $syncSource) -ne (Get-FileSha $claude.SyncScript))
    if (-not $needsCopy) { Write-Skip 'sync script up to date' }
    elseif ($PSCmdlet.ShouldProcess($claude.SyncScript, 'Install sync script')) {
        New-Item -ItemType Directory -Force -Path (Split-Path $claude.SyncScript) | Out-Null
        Copy-Item $syncSource $claude.SyncScript -Force
    }

    $worktrees = @($repos | ForEach-Object { $_.Worktree })
    if (Test-SyncHookInstalled -SettingsPath $claude.Settings -RepoPaths $worktrees) { Write-Skip 'SessionStart hook' }
    elseif ($PSCmdlet.ShouldProcess($claude.Settings, "Set SessionStart hook for $($repos.Count) repo(s) (backup: settings.json.bak)")) {
        Register-SyncHook -SettingsPath $claude.Settings -SyncScript $claude.SyncScript -Repo $worktrees
    }

    $existing = @($worktrees | Where-Object { Test-Path $_ })
    if ((Test-Path $claude.SyncScript) -and $existing.Count -and $PSCmdlet.ShouldProcess($claude.Skills, 'Link skills from main')) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $claude.SyncScript -Repo ($existing -join ';') | Out-Null
    }
}

$claudeCfg = $config.claude
if ($claudeCfg) {
    $rules = @($claudeCfg.denyRules)
    if ($rules.Count) {
        $missingRules = @(Get-MissingDenyRule -SettingsPath $claude.Settings -Rules $rules)
        if ($missingRules.Count -eq 0) { Write-Skip 'deny rules' }
        elseif ($PSCmdlet.ShouldProcess($claude.Settings, "Add $($missingRules.Count) deny rule(s) to permissions.deny (backup: settings.json.bak)")) {
            Register-DenyRule -SettingsPath $claude.Settings -Rules $missingRules
        }
    }
    if ($claudeCfg.sensitiveTermsFile) {
        $termsPath = Expand-ConfigPath $claudeCfg.sensitiveTermsFile
        if (Test-Path $termsPath) { Write-Skip 'private terms file' }
        elseif ($PSCmdlet.ShouldProcess($termsPath, 'Create private terms file (current user only)')) {
            $n = New-SensitiveTermsFile -Path $termsPath
            Write-Host "    created with $n seeded term(s). Add your hostnames, local domain and network names:" -ForegroundColor Yellow
            Write-Host "    notepad `"$termsPath`"" -ForegroundColor Yellow
        }
    }
}

# --- Verify ---
if (-not $WhatIfPreference) {
    Write-Step 'Verifying'
    & (Join-Path $root 'Test-Workstation.ps1') -ConfigPath $ConfigPath
}
