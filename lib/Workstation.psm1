# Shared helpers for Test-Workstation.ps1 and Install-Workstation.ps1.
# Targets Windows PowerShell 5.1 (no ternary / null-coalescing operators).

$script:ClaudeDir      = Join-Path $env:USERPROFILE '.claude'
$script:ClaudeSettings = Join-Path $script:ClaudeDir 'settings.json'
$script:ClaudeSkills   = Join-Path $script:ClaudeDir 'skills'
$script:SyncScriptPath = Join-Path $script:ClaudeDir 'scripts\sync-ai-skills.ps1'

function Get-ClaudePath {
    [pscustomobject]@{
        Settings   = $script:ClaudeSettings
        Skills     = $script:ClaudeSkills
        SyncScript = $script:SyncScriptPath
    }
}

function Import-WorkstationConfig {
    param([string]$Path = (Join-Path $PSScriptRoot '..\config\workstation.json'))
    if (-not (Test-Path $Path)) { throw "Config file not found: $Path" }
    Get-Content -Raw -Path $Path | ConvertFrom-Json
}

# winget installs update the registry PATH, not this session's PATH.
function Sync-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Test-CommandExist {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CheckResult {
    param(
        [string]$Area,
        [string]$Check,
        [ValidateSet('Pass', 'Warn', 'Fail')][string]$Status,
        [string]$Detail = '',
        [string]$Fix = ''
    )
    [pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix }
}

# Probes below call native commands that write to stderr when something is missing
# (e.g. gh signed out). Under $ErrorActionPreference = 'Stop', Windows PowerShell 5.1
# turns that stderr into a terminating error even with 2>$null, so each probe sets
# 'Continue' for its own scope and reports failure through $LASTEXITCODE instead.

function Test-GhSignedIn {
    $ErrorActionPreference = 'Continue'
    $login = gh api user --jq .login 2>$null
    if ($LASTEXITCODE -eq 0 -and $login) { return "$login".Trim() }
    $null
}

function Get-VSCodeExtension {
    $ErrorActionPreference = 'Continue'
    @(code --list-extensions 2>$null | ForEach-Object { $_.ToLowerInvariant() })
}

# Returns the scopes on the token gh is using, or $null if they can't be read
# (e.g. fine-grained tokens don't report scopes). Never returns the token itself.
function Get-GhTokenScope {
    $ErrorActionPreference = 'Continue'
    $lines = gh api -i user 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $scopeLine = $lines | Where-Object { $_ -match '^X-Oauth-Scopes:' } | Select-Object -First 1
    if (-not $scopeLine) { return $null }
    @(($scopeLine -replace '^X-Oauth-Scopes:\s*', '').Split(',') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-SyncHookInstalled {
    param([string]$SettingsPath = $script:ClaudeSettings)
    if (-not (Test-Path $SettingsPath)) { return $false }
    try { $settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json } catch { return $false }
    if (-not $settings -or -not ($settings.PSObject.Properties.Name -contains 'hooks')) { return $false }
    if (-not ($settings.hooks.PSObject.Properties.Name -contains 'SessionStart')) { return $false }
    foreach ($entry in @($settings.hooks.SessionStart)) {
        foreach ($hook in @($entry.hooks)) {
            $text = "$($hook.command) $(@($hook.args) -join ' ')"
            if ($text -like '*sync-ai-skills.ps1*') { return $true }
        }
    }
    $false
}

# Adds the ai-skills SessionStart hook to a Claude Code settings.json, keeping every
# existing setting and hook. Writes a .bak copy first. Throws (and writes nothing)
# if the existing file isn't valid JSON.
function Register-SyncHook {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$SyncScript,
        [Parameter(Mandatory = $true)][string]$Repo
    )
    $settings = New-Object psobject
    if (Test-Path $SettingsPath) {
        $raw = Get-Content -Raw $SettingsPath
        if ($raw -and $raw.Trim()) {
            try { $settings = $raw | ConvertFrom-Json }
            catch { throw "$SettingsPath is not valid JSON; fix it by hand, then re-run. ($($_.Exception.Message))" }
        }
        Copy-Item $SettingsPath "$SettingsPath.bak" -Force
    }
    if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object psobject)
    }
    if (-not ($settings.hooks.PSObject.Properties.Name -contains 'SessionStart')) {
        $settings.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue @()
    }
    $entry = [pscustomobject]@{
        matcher = 'startup'
        hooks   = @([pscustomobject]@{
            type          = 'command'
            command       = 'powershell.exe'
            args          = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SyncScript, '-Repo', $Repo)
            timeout       = 30
            statusMessage = 'Syncing ai-skills from main'
        })
    }
    $settings.hooks.SessionStart = @($settings.hooks.SessionStart) + $entry
    $json = $settings | ConvertTo-Json -Depth 32
    New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath) | Out-Null
    [IO.File]::WriteAllText($SettingsPath, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-WorkstationStatus {
    param([Parameter(Mandatory = $true)]$Config)

    $ErrorActionPreference = 'Continue'   # see the note above Test-GhSignedIn
    $results = New-Object System.Collections.Generic.List[object]
    $installHint = 'Run .\Install-Workstation.ps1'

    # --- Tools ---
    foreach ($tool in $Config.tools) {
        $cmd = Get-Command $tool.command -ErrorAction SilentlyContinue
        if ($cmd) {
            $results.Add((Get-CheckResult 'Tools' $tool.name 'Pass' $cmd.Source))
        } else {
            $results.Add((Get-CheckResult 'Tools' $tool.name 'Fail' "'$($tool.command)' not found on PATH" "winget install --id $($tool.wingetId) -e"))
        }
    }
    $hasGit  = Test-CommandExist 'git'
    $hasGh   = Test-CommandExist 'gh'
    $hasCode = Test-CommandExist 'code'

    # --- Git ---
    if ($hasGit) {
        $name = git config --global --get user.name
        if ($name) { $results.Add((Get-CheckResult 'Git' 'user.name' 'Pass' $name)) }
        else { $results.Add((Get-CheckResult 'Git' 'user.name' 'Fail' 'Not set' 'git config --global user.name "<name>"')) }

        $email = git config --global --get user.email
        if ($email) { $results.Add((Get-CheckResult 'Git' 'user.email' 'Pass' 'Set')) }
        else { $results.Add((Get-CheckResult 'Git' 'user.email' 'Fail' 'Not set' 'git config --global user.email "<email>"')) }

        $helper = git config --get credential.helper
        if ($helper) { $results.Add((Get-CheckResult 'Git' 'Credential helper' 'Pass' $helper)) }
        else { $results.Add((Get-CheckResult 'Git' 'Credential helper' 'Warn' 'None configured; git may prompt for passwords' 'gh auth setup-git')) }
    }

    # --- GitHub CLI ---
    if ($hasGh) {
        $login = Test-GhSignedIn
        if ($login) {
            $results.Add((Get-CheckResult 'GitHub' 'Signed in' 'Pass' "as $login"))
            $scopes = Get-GhTokenScope
            if ($null -eq $scopes) {
                $results.Add((Get-CheckResult 'GitHub' 'Token scopes' 'Warn' 'Could not read token scopes'))
            } else {
                $missing = @($Config.github.requiredScopes | Where-Object { $scopes -notcontains $_ })
                if ($missing.Count -eq 0) { $results.Add((Get-CheckResult 'GitHub' 'Token scopes' 'Pass' ($scopes -join ', '))) }
                else { $results.Add((Get-CheckResult 'GitHub' 'Token scopes' 'Fail' "Missing: $($missing -join ', ')" "gh auth refresh -h github.com -s $($missing -join ',')")) }
            }
        } else {
            $results.Add((Get-CheckResult 'GitHub' 'Signed in' 'Fail' 'gh is not authenticated' 'gh auth login --web'))
        }
    }

    # --- VS Code extensions ---
    if ($hasCode) {
        $installed = Get-VSCodeExtension
        foreach ($ext in $Config.vscodeExtensions) {
            if ($installed -contains $ext.id.ToLowerInvariant()) {
                $results.Add((Get-CheckResult 'VS Code' $ext.name 'Pass' $ext.id))
            } else {
                $status = 'Fail'
                if ($ext.required -eq $false) { $status = 'Warn' }
                $results.Add((Get-CheckResult 'VS Code' $ext.name $status "$($ext.id) not installed" "code --install-extension $($ext.id)"))
            }
        }
    }

    # --- Folders ---
    $codeRoot = [Environment]::ExpandEnvironmentVariables($Config.codeRoot)
    if (Test-Path $codeRoot -PathType Container) { $results.Add((Get-CheckResult 'Folders' 'Code root' 'Pass' $codeRoot)) }
    else { $results.Add((Get-CheckResult 'Folders' 'Code root' 'Fail' "$codeRoot does not exist" "New-Item -ItemType Directory $codeRoot")) }

    # --- ai-skills ---
    $ai = $Config.aiSkills
    if ($ai -and $ai.enabled) {
        $clone    = [Environment]::ExpandEnvironmentVariables($ai.clonePath)
        $worktree = [Environment]::ExpandEnvironmentVariables($ai.mainWorktreePath)

        if (Test-Path (Join-Path $clone '.git')) { $results.Add((Get-CheckResult 'ai-skills' 'Working clone' 'Pass' $clone)) }
        else { $results.Add((Get-CheckResult 'ai-skills' 'Working clone' 'Fail' "$clone not found" $installHint)) }

        $branch = $null
        if ($hasGit -and (Test-Path $worktree)) { $branch = git -C $worktree branch --show-current 2>$null }
        if ($branch -eq 'main') { $results.Add((Get-CheckResult 'ai-skills' 'main worktree' 'Pass' $worktree)) }
        elseif ($branch) { $results.Add((Get-CheckResult 'ai-skills' 'main worktree' 'Fail' "$worktree is on '$branch', expected main" "git -C $worktree switch main")) }
        else { $results.Add((Get-CheckResult 'ai-skills' 'main worktree' 'Fail' "$worktree not found" $installHint)) }

        if (Test-Path $script:SyncScriptPath) { $results.Add((Get-CheckResult 'ai-skills' 'Sync script' 'Pass' $script:SyncScriptPath)) }
        else { $results.Add((Get-CheckResult 'ai-skills' 'Sync script' 'Fail' 'Not installed' $installHint)) }

        if (Test-SyncHookInstalled) { $results.Add((Get-CheckResult 'ai-skills' 'SessionStart hook' 'Pass' $script:ClaudeSettings)) }
        else { $results.Add((Get-CheckResult 'ai-skills' 'SessionStart hook' 'Fail' 'Not in ~/.claude/settings.json' $installHint)) }

        $skillsSrc = Join-Path $worktree 'skills'
        if (Test-Path $skillsSrc) {
            $skills  = @(Get-ChildItem $skillsSrc -Directory)
            $missing = @($skills | Where-Object { -not (Test-Path (Join-Path $script:ClaudeSkills $_.Name)) })
            if ($missing.Count -eq 0) { $results.Add((Get-CheckResult 'ai-skills' 'Skills linked' 'Pass' "$($skills.Count) skill(s)")) }
            else { $results.Add((Get-CheckResult 'ai-skills' 'Skills linked' 'Warn' "Not linked yet: $(($missing | ForEach-Object Name) -join ', ')" "& '$script:SyncScriptPath'")) }
        }
    }

    $results
}

Export-ModuleMember -Function Get-ClaudePath, Import-WorkstationConfig, Sync-SessionPath, Test-CommandExist, Get-GhTokenScope, Test-SyncHookInstalled, Register-SyncHook, Test-GhSignedIn, Get-VSCodeExtension, Get-WorkstationStatus
