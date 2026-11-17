"""Install and configure what the checks look for. Safe to re-run: each step is skipped when done.

Steps: tools, git identity, GitHub CLI sign-in, VS Code extensions, code root, skill repos
(clone, main worktree, push guard), and Claude Code (sync script and hook, CLAUDE.md,
deny rules, private terms file). With dry_run, every change is printed instead of made.
"""
from __future__ import annotations

import filecmp
import shutil
import subprocess
from pathlib import Path

from . import checks, claude, config, tools
from .platforms import (CLAUDE_SETTINGS, OLD_SYNC_SCRIPT, SYNC_SCRIPT, editor_hint, expand_path, hook_python,
                        refresh_path, run, run_visible, which)

SYNC_SOURCE = Path(__file__).resolve().parent.parent / "files" / "sync_ai_skills.py"


class Installer:
    """Runs the install steps, printing each one, and only describing changes when dry_run is set."""

    def __init__(self, cfg: dict, dry_run: bool, git_name: str = "", git_email: str = "",
                 skip_optional_extensions: bool = False):
        """Keep the options; nothing runs until run()."""
        self.cfg, self.dry_run = cfg, dry_run
        self.git_name, self.git_email = git_name, git_email
        self.skip_optional = skip_optional_extensions

    # --- output and execution helpers ---

    @staticmethod
    def step(text: str) -> None:
        """Print a step heading."""
        print(f"==> {text}")

    @staticmethod
    def ok(text: str) -> None:
        """Print a line for something already done."""
        print(f"    ok: {text}")

    def change(self, what: str) -> bool:
        """Announce a change. Returns True when it should be made (False in a dry run)."""
        print(f"    {'would ' if self.dry_run else ''}{what}")
        return not self.dry_run

    def native(self, description: str, cmd: list[str]) -> None:
        """Run a command with the terminal attached; stop with a clear error if it fails."""
        rc = run_visible(cmd)
        if rc != 0:
            raise SystemExit(f"{description} failed (exit code {rc}): {' '.join(cmd)}")

    # --- steps ---

    def tools(self) -> None:
        """Install missing tools with this platform's package manager."""
        self.step("Tools")
        for tool in self.cfg.get("tools") or []:
            if which(tool["command"]):
                self.ok(tool["name"])
                continue
            cmd = tools.install_command(tool)
            if not cmd:
                msg = tools.install_hint(tool)
                if self.dry_run:
                    print(f"    warning: {msg}")
                    continue
                raise SystemExit(msg)
            if self.change(" ".join(cmd)):
                self.native(f"Installing {tool['name']}", cmd)
                refresh_path()

    def git_identity(self) -> None:
        """Set git user.name / user.email if missing, asking when not given on the command line."""
        self.step("Git identity")
        if not which("git"):
            return
        for key, value, prompt in (("user.name", self.git_name, "Your name for git commits: "),
                                   ("user.email", self.git_email, "Your email for git commits: ")):
            if checks.git_config(key):
                self.ok(key)
                continue
            if not value and not self.dry_run:
                value = input(prompt).strip()
            if value and self.change(f"git config --global {key} <value>"):
                self.native(f"Setting {key}", ["git", "config", "--global", key, value])

    def github(self) -> None:
        """Sign in to gh (opens a browser), add missing token scopes, and set gh as git's credential helper."""
        self.step("GitHub CLI")
        if not which("gh"):
            return
        scopes = self.cfg["github"]["requiredScopes"]
        if not checks.gh_login():
            if self.change("gh auth login --web (opens a browser)"):
                self.native("gh auth login", ["gh", "auth", "login", "--hostname", "github.com",
                                              "--git-protocol", "https", "--web", "--scopes", ",".join(scopes)])
        else:
            self.ok("signed in")
            have = checks.gh_scopes()
            missing = [s for s in scopes if have is not None and s not in have]
            if missing and self.change(f"gh auth refresh -s {','.join(missing)}"):
                self.native("gh auth refresh", ["gh", "auth", "refresh", "--hostname", "github.com",
                                                "--scopes", ",".join(missing)])
        rc, helper = run(["git", "config", "--get", "credential.helper"])
        if helper.strip():
            self.ok("git credential helper")
        elif self.change("gh auth setup-git"):
            self.native("gh auth setup-git", ["gh", "auth", "setup-git"])

    def vscode(self) -> None:
        """Install the VS Code extensions from the config."""
        self.step("VS Code extensions")
        if not which("code"):
            return
        installed = checks.vscode_extensions()
        for ext in self.cfg.get("vscodeExtensions") or []:
            if ext["id"].lower() in installed:
                self.ok(ext["name"])
            elif not ext.get("required", True) and self.skip_optional:
                self.ok(f"{ext['name']} (optional, skipped)")
            elif self.change(f"code --install-extension {ext['id']}"):
                self.native(f"Installing {ext['name']}", ["code", "--install-extension", ext["id"]])

    def folders(self) -> None:
        """Create the code root."""
        self.step("Folders")
        root = config.code_root(self.cfg)
        if root.is_dir():
            self.ok(str(root))
        elif self.change(f"create {root}"):
            root.mkdir(parents=True)

    def skill_repos(self) -> None:
        """Clone each skill repo, add its main worktree, and enable the push guard where configured."""
        for r in config.skill_repos(self.cfg):
            self.step(r.name)
            if (r.clone / ".git").exists():
                self.ok(f"clone at {r.clone}")
            elif self.change(f"gh repo clone {r.repo} {r.clone}"):
                self.native(f"Cloning {r.repo}", ["gh", "repo", "clone", r.repo, str(r.clone)])

            if r.worktree.exists():
                self.ok(f"main worktree at {r.worktree}")
            elif self.change(f"git worktree add {r.worktree} main"):
                c = str(r.clone)
                self.native("git fetch", ["git", "-C", c, "fetch", "--quiet", "origin"])
                # main can only be checked out in one place, so move the working clone off it first.
                _, branch = run(["git", "-C", c, "branch", "--show-current"])
                if branch.strip() == "main":
                    self.native("Detaching working clone", ["git", "-C", c, "switch", "--quiet", "--detach", "origin/main"])
                self.native("git worktree add", ["git", "-C", c, "worktree", "add", str(r.worktree), "main"])
                self.native("Setting upstream", ["git", "-C", str(r.worktree), "branch", "--quiet",
                                                 "--set-upstream-to=origin/main", "main"])

            if r.local_main_guard and (r.clone / ".git").exists():
                if checks.git_config("core.hooksPath", cwd=str(r.clone)) == "hooks":
                    self.ok("push guard on main")
                elif self.change("git config core.hooksPath hooks (blocks pushes to main)"):
                    self.native("Enabling push guard", ["git", "-C", str(r.clone), "config", "core.hooksPath", "hooks"])

    def claude_code(self) -> None:
        """Install the sync script and SessionStart hook, sync once, add deny rules, create the terms file."""
        self.step("Claude Code")
        repos = config.skill_repos(self.cfg)
        instructions = config.global_instructions_source(self.cfg)
        if repos:
            if SYNC_SCRIPT.exists() and filecmp.cmp(SYNC_SOURCE, SYNC_SCRIPT, shallow=False):
                self.ok("sync script up to date")
            elif self.change(f"install {SYNC_SCRIPT}"):
                SYNC_SCRIPT.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(SYNC_SOURCE, SYNC_SCRIPT)

            worktrees = [r.worktree for r in repos]
            needed = [str(w) for w in worktrees] + ([str(instructions)] if instructions else [])
            if claude.sync_hook_installed(CLAUDE_SETTINGS, needed):
                self.ok("SessionStart hook")
            elif self.change(f"set the SessionStart hook in {CLAUDE_SETTINGS} (backup: settings.json.bak)"):
                claude.register_sync_hook(CLAUDE_SETTINGS, hook_python(),
                                          claude.sync_hook_args(SYNC_SCRIPT, worktrees, instructions))

            # The hook now runs the Python script; the PowerShell one is no longer referenced.
            if OLD_SYNC_SCRIPT.exists() and self.change(f"remove the old {OLD_SYNC_SCRIPT.name}"):
                OLD_SYNC_SCRIPT.unlink()

            existing = [w for w in worktrees if w.exists()]
            if SYNC_SCRIPT.exists() and existing and self.change("link skills and CLAUDE.md from main"):
                args = claude.sync_hook_args(SYNC_SCRIPT, existing, instructions)
                r = subprocess.run([*hook_python(), *args], capture_output=True, text=True)
                if r.stdout.strip():
                    print(f"    {r.stdout.strip()}")

        cl = self.cfg.get("claude") or {}
        rules = cl.get("denyRules") or []
        if rules:
            missing = claude.missing_deny_rules(CLAUDE_SETTINGS, rules)
            if not missing:
                self.ok("deny rules")
            elif self.change(f"add {len(missing)} deny rule(s) to permissions.deny (backup: settings.json.bak)"):
                claude.add_deny_rules(CLAUDE_SETTINGS, missing)
        if cl.get("sensitiveTermsFile"):
            terms = expand_path(cl["sensitiveTermsFile"])
            if terms.exists():
                self.ok("private terms file")
            elif self.change(f"create {terms} (current user only)"):
                n = claude.init_terms_file(terms)
                print(f"    created with {n} seeded term(s). Add your hostnames, local domain and network names:")
                print(f"    {editor_hint(terms)}")

    def run(self) -> None:
        """Run every step in order."""
        self.tools()
        self.git_identity()
        self.github()
        self.vscode()
        self.folders()
        self.skill_repos()
        self.claude_code()
