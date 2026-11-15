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

# --- Config helpers -----------------------------------------------------------

function Expand-ConfigPath([string]$Path) { [Environment]::ExpandEnvironmentVariables($Path) }

# The skill repos from config, with paths expanded.
function Get-SkillRepo {
    param([Parameter(Mandatory = $true)]$Config)
    foreach ($r in @($Config.skillRepos)) {
        if (-not $r) { continue }
        [pscustomobject]@{
            Name           = $r.name
            Repo           = $r.repo
            Clone          = Expand-ConfigPath $r.clonePath
            Worktree       = Expand-ConfigPath $r.mainWorktreePath
            LocalMainGuard = ($r.localMainGuard -eq $true)
        }
    }
}

# --- Claude Code settings.json --------------------------------------------------

function Read-ClaudeSetting([string]$SettingsPath) {
    if (-not (Test-Path $SettingsPath)) { return $null }
    $raw = Get-Content -Raw $SettingsPath
    if (-not $raw -or -not $raw.Trim()) { return (New-Object psobject) }
    try { $raw | ConvertFrom-Json }
    catch { throw "$SettingsPath is not valid JSON; fix it by hand, then re-run. ($($_.Exception.Message))" }
}

function Save-ClaudeSetting([string]$SettingsPath, $Settings) {
    if (Test-Path $SettingsPath) { Copy-Item $SettingsPath "$SettingsPath.bak" -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath) | Out-Null
    $json = $Settings | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($SettingsPath, $json, (New-Object Text.UTF8Encoding $false))
}

function Add-MissingProperty($Object, [string]$Name, $Value) {
    if (-not ($Object.PSObject.Properties.Name -contains $Name)) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Test-IsSyncHookEntry($Entry) {
    foreach ($hook in @($Entry.hooks)) {
        if ("$($hook.command) $(@($hook.args) -join ' ')" -like '*sync-ai-skills.ps1*') { return $true }
    }
    $false
}

# True when a SessionStart hook runs the sync script for every given repo path.
function Test-SyncHookInstalled {
    param([string]$SettingsPath = $script:ClaudeSettings, [string[]]$RepoPaths = @())
    try { $settings = Read-ClaudeSetting $SettingsPath } catch { return $false }
    if (-not $settings -or -not ($settings.PSObject.Properties.Name -contains 'hooks')) { return $false }
    if (-not ($settings.hooks.PSObject.Properties.Name -contains 'SessionStart')) { return $false }
    foreach ($entry in @($settings.hooks.SessionStart)) {
        if (-not (Test-IsSyncHookEntry $entry)) { continue }
        $text = (@($entry.hooks) | ForEach-Object { @($_.args) -join ' ' }) -join ' '
        $missing = @($RepoPaths | Where-Object { $text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 })
        if ($missing.Count -eq 0) { return $true }
    }
    $false
}

# Sets the ai-skills SessionStart hook in a Claude Code settings.json: removes any
# older sync hook entry, adds one for the given repos, and keeps every other setting
# and hook. Writes a .bak copy first; throws (writing nothing) on invalid JSON.
function Register-SyncHook {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$SyncScript,
        [Parameter(Mandatory = $true)][string[]]$Repo
    )
    $settings = Read-ClaudeSetting $SettingsPath
    if ($null -eq $settings) { $settings = New-Object psobject }
    Add-MissingProperty $settings 'hooks' (New-Object psobject)
    Add-MissingProperty $settings.hooks 'SessionStart' @()
    $entry = [pscustomobject]@{
        matcher = 'startup'
        hooks   = @([pscustomobject]@{
            type          = 'command'
            command       = 'powershell.exe'
            args          = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SyncScript, '-Repo', ($Repo -join ';'))
            timeout       = 30
            statusMessage = 'Syncing skills from main'
        })
    }
    $kept = @(@($settings.hooks.SessionStart) | Where-Object { $_ -and -not (Test-IsSyncHookEntry $_) })
    $settings.hooks.SessionStart = $kept + $entry
    Save-ClaudeSetting $SettingsPath $settings
}

# Deny rules from config that are not yet in settings.json permissions.deny.
function Get-MissingDenyRule {
    param([string]$SettingsPath = $script:ClaudeSettings, [string[]]$Rules = @())
    $have = @()
    try { $settings = Read-ClaudeSetting $SettingsPath } catch { return $Rules }
    if ($settings -and ($settings.PSObject.Properties.Name -contains 'permissions') -and
        ($settings.permissions.PSObject.Properties.Name -contains 'deny')) {
        $have = @($settings.permissions.deny)
    }
    @($Rules | Where-Object { $have -notcontains $_ })
}

# Adds deny rules to permissions.deny, keeping existing allow/deny/ask rules.
function Register-DenyRule {
    param([Parameter(Mandatory = $true)][string]$SettingsPath, [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Rules)
    if (-not $Rules -or $Rules.Count -eq 0) { return }
    $settings = Read-ClaudeSetting $SettingsPath
    if ($null -eq $settings) { $settings = New-Object psobject }
    Add-MissingProperty $settings 'permissions' (New-Object psobject)
    Add-MissingProperty $settings.permissions 'deny' @()
    $current = @($settings.permissions.deny)
    $settings.permissions.deny = $current + @($Rules | Where-Object { $current -notcontains $_ })
    Save-ClaudeSetting $SettingsPath $settings
}

# --- Private sensitive-terms file (read by the public-repo-hygiene scanner) ---

function Get-SensitiveTermCount([string]$Path) {
    if (-not (Test-Path $Path)) { return -1 }
    @(Get-Content $Path | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count
}

# Creates the terms file seeded with this machine's identifying values, readable
# only by the current user. Never overwrites an existing file. Returns the number
# of seeded terms (values are not returned or printed).
function Initialize-SensitiveTermsFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path $Path) { return 0 }
    $ErrorActionPreference = 'Continue'
    $seed = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($env:USERNAME, $env:COMPUTERNAME)) { if ($v -and $v.Length -ge 3) { $seed.Add($v) } }
    if (Test-CommandExist 'git') {
        $email = git config --global --get user.email 2>$null
        if ($email) { $seed.Add("$email".Trim()) }
    }
    $header = @(
        '# Private terms for the public-repo-hygiene scanner. One per line; prefix re: for a regex.',
        '# Add your hostnames, local domain, network names, device names, and anything else',
        '# that identifies your environment. This file must never be committed or shared,',
        '# and AI agents are denied from reading it.',
        '')
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllLines($Path, [string[]]($header + $seed), (New-Object Text.UTF8Encoding $false))
    & icacls $Path /inheritance:r /grant:r "${env:USERNAME}:(F)" | Out-Null
    $seed.Count
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

    # --- Skill repos ---
    $repos = @(Get-SkillRepo -Config $Config)
    foreach ($r in $repos) {
        $area = $r.Name
        if (Test-Path (Join-Path $r.Clone '.git')) { $results.Add((Get-CheckResult $area 'Working clone' 'Pass' $r.Clone)) }
        else { $results.Add((Get-CheckResult $area 'Working clone' 'Fail' "$($r.Clone) not found" $installHint)) }

        $branch = $null
        if ($hasGit -and (Test-Path $r.Worktree)) { $branch = git -C $r.Worktree branch --show-current 2>$null }
        if ($branch -eq 'main') { $results.Add((Get-CheckResult $area 'main worktree' 'Pass' $r.Worktree)) }
        elseif ($branch) { $results.Add((Get-CheckResult $area 'main worktree' 'Fail' "$($r.Worktree) is on '$branch', expected main" "git -C $($r.Worktree) switch main")) }
        else { $results.Add((Get-CheckResult $area 'main worktree' 'Fail' "$($r.Worktree) not found" $installHint)) }

        if ($r.LocalMainGuard -and $hasGit -and (Test-Path (Join-Path $r.Clone '.git'))) {
            $hooksPath = git -C $r.Clone config --get core.hooksPath 2>$null
            $guardFile = Join-Path $r.Clone 'hooks\pre-push'
            if ($hooksPath -ne 'hooks') { $results.Add((Get-CheckResult $area 'Push guard on main' 'Fail' 'core.hooksPath not set; pushes to main are not blocked' "git -C $($r.Clone) config core.hooksPath hooks")) }
            elseif (-not (Test-Path $guardFile)) { $results.Add((Get-CheckResult $area 'Push guard on main' 'Warn' 'Enabled, but hooks/pre-push is not in this checkout')) }
            else { $results.Add((Get-CheckResult $area 'Push guard on main' 'Pass' 'pre-push blocks main')) }
        }

        $skillsSrc = Join-Path $r.Worktree 'skills'
        if (Test-Path $skillsSrc) {
            $skills  = @(Get-ChildItem $skillsSrc -Directory)
            $missing = @($skills | Where-Object { -not (Test-Path (Join-Path $script:ClaudeSkills $_.Name)) })
            if ($missing.Count -eq 0) { $results.Add((Get-CheckResult $area 'Skills linked' 'Pass' "$($skills.Count) skill(s)")) }
            else { $results.Add((Get-CheckResult $area 'Skills linked' 'Warn' "Not linked yet: $(($missing | ForEach-Object { $_.Name }) -join ', ')" "& '$script:SyncScriptPath' -Repo '$($r.Worktree)'")) }
        }
    }

    # --- Claude Code ---
    if ($repos.Count) {
        if (Test-Path $script:SyncScriptPath) { $results.Add((Get-CheckResult 'Claude Code' 'Sync script' 'Pass' $script:SyncScriptPath)) }
        else { $results.Add((Get-CheckResult 'Claude Code' 'Sync script' 'Fail' 'Not installed' $installHint)) }

        if (Test-SyncHookInstalled -RepoPaths @($repos | ForEach-Object { $_.Worktree })) { $results.Add((Get-CheckResult 'Claude Code' 'SessionStart hook' 'Pass' "syncs $($repos.Count) repo(s)")) }
        else { $results.Add((Get-CheckResult 'Claude Code' 'SessionStart hook' 'Fail' 'Missing, or not syncing every skill repo' $installHint)) }
    }

    $claude = $Config.claude
    if ($claude) {
        $rules = @($claude.denyRules)
        if ($rules.Count) {
            $missingRules = @(Get-MissingDenyRule -Rules $rules)
            if ($missingRules.Count -eq 0) { $results.Add((Get-CheckResult 'Claude Code' 'Deny rules' 'Pass' "$($rules.Count) rule(s) in permissions.deny")) }
            else { $results.Add((Get-CheckResult 'Claude Code' 'Deny rules' 'Fail' "$($missingRules.Count) of $($rules.Count) missing from permissions.deny" $installHint)) }
        }
        if ($claude.sensitiveTermsFile) {
            $termsPath = Expand-ConfigPath $claude.sensitiveTermsFile
            $count = Get-SensitiveTermCount $termsPath
            if ($count -lt 0) { $results.Add((Get-CheckResult 'Claude Code' 'Private terms file' 'Fail' 'Not created' $installHint)) }
            elseif ($count -le 3) { $results.Add((Get-CheckResult 'Claude Code' 'Private terms file' 'Warn' "$count term(s): add your hostnames, local domain and network names" "notepad `"$termsPath`"")) }
            else { $results.Add((Get-CheckResult 'Claude Code' 'Private terms file' 'Pass' "$count term(s)")) }
        }
    }

    $results
}

Export-ModuleMember -Function Get-ClaudePath, Import-WorkstationConfig, Sync-SessionPath, Test-CommandExist, Get-GhTokenScope, Test-GhSignedIn, Get-VSCodeExtension, Expand-ConfigPath, Get-SkillRepo, Test-SyncHookInstalled, Register-SyncHook, Get-MissingDenyRule, Register-DenyRule, Get-SensitiveTermCount, Initialize-SensitiveTermsFile, Get-WorkstationStatus
