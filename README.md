# workstation-setup

Sets up and checks a workstation on **Windows, macOS or Linux** for this workflow:

- **VS Code** with the **Claude Code** and **GitHub Pull Requests** extensions (GitHub Actions optional)
- **Git** with a name, email and credential helper
- **GitHub CLI** (`gh`) signed in with the `repo`, `workflow` and `read:org` scopes
- Repos under **`~/code`**
- **Skills loaded into Claude Code from `main`** of the public [ai-skills](https://github.com/jdrodgers/ai-skills) repo and a private companion repo: each gets a `main` worktree, linked into `~/.claude/skills`, refreshed by one SessionStart hook
- **Global Claude Code instructions**: `~/.claude/CLAUDE.md` kept in step with [`claude/CLAUDE.md`](https://github.com/jdrodgers/ai-skills/blob/main/claude/CLAUDE.md) in ai-skills, so changes to it go through a PR
- **Claude Code guardrails**: deny rules so Claude's file tools can't read secret files (SSH keys, cloud credentials, `.env`, `config.local.json`, `secrets.yaml`, certificates), and a private terms file for the `public-repo-hygiene` scanner

## How it's built

A small bootstrap per platform gets the machine to where it can run Python; everything after that is one Python package that runs the same way everywhere.

| Platform | Bootstrap | Installs if missing |
|---|---|---|
| Windows | `setup.ps1` (Windows PowerShell 5.1, ships with Windows) | Git and Python 3 with winget |
| macOS | `setup.sh` | Git and Python with Homebrew, or the Xcode Command Line Tools if there's no Homebrew |
| Linux | `setup.sh` | `git` and `python3` with apt-get or dnf (sudo) |

The Python code (`workstation/`) needs Python 3.9+ and only the standard library.

## Check a machine

```sh
./setup.sh check          # macOS / Linux
.\setup.ps1 check         # Windows
```

Read-only. Prints Pass / Warn / Fail for each check with the command that fixes it, and exits 1 if anything failed. `python -m workstation check --json` gives the results as JSON.

## Set up a machine

```sh
./setup.sh install --dry-run      # show what it would change (also: .\setup.ps1 install --dry-run)
./setup.sh                        # do it, then run the checks
```

Safe to re-run: every step is skipped when it's already done. Options: `--git-name`, `--git-email`, `--skip-optional-extensions`.

| Step | What it does |
|---|---|
| Tools | Installs Git, GitHub CLI and VS Code with the platform's package manager (winget; Homebrew; apt-get, dnf or snap) |
| Git identity | Sets `user.name` / `user.email` if missing (`--git-name`, `--git-email`, or it asks) |
| GitHub CLI | `gh auth login --web` if signed out, `gh auth refresh` for missing scopes, `gh auth setup-git` if there's no credential helper |
| VS Code | Installs the extensions in the config |
| Folders | Creates the code root (`~/code`) |
| Skill repos | For each repo in `skillRepos`: clones it and adds its `main` worktree. Repos marked `localMainGuard` (free private repos have no server-side branch protection) get `core.hooksPath hooks`, so the repo's `pre-push` hook blocks pushes to `main` |
| Claude Code | Installs `~/.claude/scripts/sync_ai_skills.py` and one SessionStart hook that pulls every skill repo, links the skills (junctions on Windows, symlinks elsewhere) and refreshes `~/.claude/CLAUDE.md`; adds the deny rules to `permissions.deny`. `~/.claude/settings.json` is backed up to `settings.json.bak` and every existing setting is kept |
| Private terms file | Creates `~/.config/ai-skills/sensitive-terms.txt`, readable only by you, seeded with your username, computer name and git email. **Add your hostnames, local domain and network names to it.** It's never committed, and the deny rules keep Claude from reading it |

### Global `CLAUDE.md`

`~/.claude/CLAUDE.md` is a **copy** of the repo file (file links need admin or Developer Mode on Windows). Each session start replaces it only if it is missing or unchanged since the last copy. If you edit it locally, it is left alone and Claude Code shows a message: move the edit into ai-skills through a PR, then delete the local file.

## Changing what's required

Edit [`config/workstation.json`](config/workstation.json):

- `codeRoot`: where repos go. A value can be one path, or an object per platform: `{"windows": "d:/src", "default": "~/code"}`
- `tools`: the command to look for and the package name per manager (`winget`, `brew`, `brewCask`, `apt`, `dnf`, `snap`; a value can carry extra arguments, e.g. `"code --classic"`)
- `vscodeExtensions`: `"required": false` makes a missing one a warning
- `github.requiredScopes`
- `skillRepos`: each skill repo's clone and `main` worktree paths (relative to `codeRoot`), and `localMainGuard`. An empty list skips the skill setup.
- `claude.globalInstructions`: the skill repo and path that `~/.claude/CLAUDE.md` follows
- `claude.denyRules`: the Claude Code `permissions.deny` entries. They limit Claude's Read tool, not shell commands, so the `agent-guardrails` skill still applies.
- `claude.sensitiveTermsFile`: where the private terms file lives

**One machine only:** put overrides in `config/workstation.local.json` (git-ignored). Its top-level keys replace the shared ones, e.g. `{"codeRoot": "c:/code"}` on a PC set up before `~/code` was the default.

Skill names must be unique across the skill repos. If two repos have a skill with the same name, the first repo listed wins and the sync hook reports the clash.

## Layout

```
setup.ps1                  Windows bootstrap (Git + Python via winget), then python -m workstation
setup.sh                   macOS / Linux bootstrap, then python3 -m workstation
workstation/               the setup itself: checks.py (read-only), install.py, claude.py (settings.json),
                           config.py, tools.py (package managers), platforms.py (OS differences)
files/sync_ai_skills.py    the SessionStart hook script, installed to ~/.claude/scripts/
config/workstation.json    what's required
tests/                     pytest unit tests (temporary folders only)
```

## Contributing

`main` is protected: branch from `origin/main` and open a pull request. CI runs ruff and pytest on Windows, macOS and Linux (Python 3.9 and 3.13), smoke-tests `check` and `install --dry-run`, lints both bootstrap scripts (shellcheck, PSScriptAnalyzer), and does a gitleaks secret scan. Dependabot proposes updates to the pinned Actions and dev tools.

Local checks:

```sh
python -m venv .venv && .venv/bin/pip install -r requirements-dev.txt   # Windows: .venv\Scripts\pip
python -m ruff check . && python -m pytest -q
```
