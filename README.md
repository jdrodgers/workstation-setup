# workstation-setup

Sets up and checks a Windows workstation for this workflow:

- **VS Code** with the **Claude Code** and **GitHub Pull Requests** extensions (GitHub Actions optional)
- **Git** with a name, email and credential helper
- **GitHub CLI** (`gh`) signed in with the `repo`, `workflow` and `read:org` scopes
- Repos under **`c:\code`**
- **[ai-skills](https://github.com/jdrodgers/ai-skills)** loaded into Claude Code from `main`: a worktree at `c:\code\ai-skills-main`, linked into `~/.claude/skills`, refreshed by a SessionStart hook

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
| ai-skills | Clones the repo, adds the `main` worktree, installs `~/.claude/scripts/sync-ai-skills.ps1`, adds the SessionStart hook to `~/.claude/settings.json` (backing it up to `settings.json.bak`, keeping all existing settings), and links the skills |

If PowerShell refuses to run the scripts, run them for this session only with:
```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Workstation.ps1
```

## Changing what's required

Edit [`config/workstation.json`](config/workstation.json): tools (with their winget IDs), VS Code extensions (`"required": false` makes a missing one a warning), GitHub token scopes, the code folder, and the ai-skills paths. Set `aiSkills.enabled` to `false` to skip that part.

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
