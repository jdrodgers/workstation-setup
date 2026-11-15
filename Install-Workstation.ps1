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
      6. Clones ai-skills, adds the main worktree, installs the sync script and
         the Claude Code SessionStart hook (~/.claude/settings.json is backed up first)
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
    gh api user --jq .login 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
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
    $installed = @(code --list-extensions 2>$null | ForEach-Object { $_.ToLowerInvariant() })
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

# --- 6. ai-skills ---
$ai = $config.aiSkills
if ($ai -and $ai.enabled) {
    Write-Step 'ai-skills'
    $clone    = [Environment]::ExpandEnvironmentVariables($ai.clonePath)
    $worktree = [Environment]::ExpandEnvironmentVariables($ai.mainWorktreePath)

    if (Test-Path (Join-Path $clone '.git')) { Write-Skip "clone at $clone" }
    elseif ($PSCmdlet.ShouldProcess($clone, "gh repo clone $($ai.repo)")) {
        Invoke-Native 'Cloning ai-skills' { gh repo clone $ai.repo $clone }
    }

    if (Test-Path $worktree) { Write-Skip "main worktree at $worktree" }
    elseif ($PSCmdlet.ShouldProcess($worktree, 'git worktree add (main)')) {
        Invoke-Native 'git fetch' { git -C $clone fetch --quiet origin }
        # main can only be checked out in one place, so move the working clone off it first.
        if ((git -C $clone branch --show-current) -eq 'main') {
            Invoke-Native 'Detaching working clone' { git -C $clone switch --quiet --detach origin/main }
        }
        Invoke-Native 'git worktree add' { git -C $clone worktree add $worktree main }
        Invoke-Native 'Setting upstream' { git -C $worktree branch --quiet --set-upstream-to=origin/main main }
    }

    $syncSource = Join-Path $root 'files\sync-ai-skills.ps1'
    $needsCopy = -not (Test-Path $claude.SyncScript) -or
        ((Get-FileSha $syncSource) -ne (Get-FileSha $claude.SyncScript))
    if (-not $needsCopy) { Write-Skip 'sync script up to date' }
    elseif ($PSCmdlet.ShouldProcess($claude.SyncScript, 'Install sync script')) {
        New-Item -ItemType Directory -Force -Path (Split-Path $claude.SyncScript) | Out-Null
        Copy-Item $syncSource $claude.SyncScript -Force
    }

    if (Test-SyncHookInstalled) { Write-Skip 'SessionStart hook' }
    elseif ($PSCmdlet.ShouldProcess($claude.Settings, 'Add SessionStart hook (backup: settings.json.bak)')) {
        Register-SyncHook -SettingsPath $claude.Settings -SyncScript $claude.SyncScript -Repo $worktree
    }

    if ((Test-Path $claude.SyncScript) -and (Test-Path $worktree) -and $PSCmdlet.ShouldProcess($claude.Skills, 'Link skills from main')) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $claude.SyncScript -Repo $worktree | Out-Null
    }
}

# --- Verify ---
if (-not $WhatIfPreference) {
    Write-Step 'Verifying'
    & (Join-Path $root 'Test-Workstation.ps1') -ConfigPath $ConfigPath
}
