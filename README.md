# workstation-setup

Sets up and checks a Windows workstation for this workflow:

- **VS Code** with the **Claude Code** and **GitHub Pull Requests** extensions (GitHub Actions optional)
- **Git** with a name, email and credential helper
- **GitHub CLI** (`gh`) signed in with the `repo`, `workflow` and `read:org` scopes
- Repos under **`c:\code`**
- **Skills loaded into Claude Code from `main`** of the public [ai-skills](https://github.com/jdrodgers/ai-skills) repo and a private companion repo: each gets a `main` worktree, linked into `~/.claude/skills`, refreshed by one SessionStart hook
- **Claude Code guardrails**: deny rules so Claude's file tools can't read secret files (SSH keys, cloud credentials, `.env`, `config.local.json`, `secrets.yaml`, certificates), and a private terms file for the `public-repo-hygiene` scanner

Targets Windows PowerShell 5.1, which ships with Windows. No PowerShell 7 needed.

## Check a machine

```powershell
.\Test-Workstation.ps1
```

Read-only. Prints Pass / Warn / Fail for each check with the command that fixes it, and exits 1 if anything failed. `-PassThru` returns the results as objects instead.

## Set up a machine

```powershell
.\Install-Workstation.ps1 -WhatIf   # show what it would change
.\Install-Workstation.ps1           # do it, then run the checks
```

Safe to re-run: every step is skipped when it's already done.

| Step | What it does |
|---|---|
| Tools | `winget install` for Git, GitHub CLI and VS Code if missing |
| Git identity | Sets `user.name` / `user.email` if missing (`-GitName`, `-GitEmail`, or it asks) |
| GitHub CLI | `gh auth login --web` if signed out, `gh auth refresh` for missing scopes, `gh auth setup-git` if there's no credential helper |
| VS Code | Installs the extensions in the config (`-SkipOptionalExtensions` to skip optional ones) |
| Folders | Creates `c:\code` |
| Skill repos | For each repo in `skillRepos`: clones it and adds its `main` worktree. Repos marked `localMainGuard` (free private repos have no server-side branch protection) get `core.hooksPath hooks`, so the repo's `pre-push` hook blocks pushes to `main` |
| Claude Code | Installs `~/.claude/scripts/sync-ai-skills.ps1` and one SessionStart hook that syncs every skill repo, adds the deny rules to `permissions.deny`, and links the skills. `~/.claude/settings.json` is backed up to `settings.json.bak` and every existing setting is kept |
| Private terms file | Creates `%USERPROFILE%\.config\ai-skills\sensitive-terms.txt`, readable only by you, seeded with your username, computer name and git email. **Add your hostnames, local domain and network names to it.** It's never committed, and the deny rules keep Claude from reading it |

If PowerShell refuses to run the scripts, run them for this session only with:
```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Workstation.ps1
```

## Changing what's required

Edit [`config/workstation.json`](config/workstation.json):

- `tools`: with their winget IDs
- `vscodeExtensions`: `"required": false` makes a missing one a warning
- `github.requiredScopes`
- `codeRoot`
- `skillRepos`: each skill repo's clone and `main` worktree paths, and `localMainGuard`. An empty list skips the skill setup.
- `claude.denyRules`: the Claude Code `permissions.deny` entries. They limit Claude's Read tool, not shell commands, so the `agent-guardrails` skill still applies.
- `claude.sensitiveTermsFile`: where the private terms file lives

Skill names must be unique across the skill repos. If two repos have a skill with the same name, the first repo listed wins and the sync hook reports the clash.

The sync script that the hook runs lives in [`files/sync-ai-skills.ps1`](files/sync-ai-skills.ps1). Change it there. The installer copies it again whenever the installed copy differs.

## Layout

```
Test-Workstation.ps1        checks (read-only)
Install-Workstation.ps1     fixes
config/workstation.json     what's required
lib/Workstation.psm1        shared check and settings code
files/sync-ai-skills.ps1    installed to ~/.claude/scripts/
```

## Contributing

`main` is protected: branch from `origin/main` and open a pull request. CI runs PSScriptAnalyzer, runs both scripts on a clean Windows runner (`Test-Workstation`, and `Install-Workstation -WhatIf`), and does a gitleaks secret scan.
