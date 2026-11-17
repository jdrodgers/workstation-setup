"""Read-only checks: what is set up on this machine and what still needs fixing."""
from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass

from . import claude, config, tools
from .platforms import (CLAUDE_MD, CLAUDE_SETTINGS, CLAUDE_SKILLS, SYNC_SCRIPT, editor_hint, expand_path,
                        platform_key, run, which)


@dataclass
class Result:
    """One check: its area and name, Pass / Warn / Fail, details, and a suggested fix."""

    area: str
    check: str
    status: str
    detail: str = ""
    fix: str = ""

    def as_dict(self) -> dict:
        """The result as a plain dict (for --json output)."""
        return asdict(self)


def install_hint() -> str:
    """How to run the installer on this platform."""
    return r"Run .\setup.ps1" if platform_key() == "windows" else "Run ./setup.sh"


def gh_login() -> str | None:
    """The GitHub login gh is signed in as, or None."""
    rc, out = run(["gh", "api", "user", "--jq", ".login"])
    return out.strip() if rc == 0 and out.strip() else None


def gh_scopes() -> list[str] | None:
    """Scopes on gh's token, or None if they can't be read (fine-grained tokens don't report them).

    Reads only the X-Oauth-Scopes response header; the token itself is never read.
    """
    rc, out = run(["gh", "api", "-i", "user"])
    if rc != 0:
        return None
    for line in out.splitlines():
        if line.lower().startswith("x-oauth-scopes:"):
            return [s.strip() for s in line.split(":", 1)[1].split(",") if s.strip()]
    return None


def vscode_extensions() -> set[str]:
    """Installed VS Code extension IDs, lower-cased."""
    rc, out = run(["code", "--list-extensions"])
    return {ln.strip().lower() for ln in out.splitlines() if ln.strip()} if rc == 0 else set()


def git_config(key: str, cwd: str | None = None, scope: str = "--global") -> str:
    """A git config value ('' if unset). `cwd` reads a repo's config instead of the global one."""
    cmd = ["git", "-C", cwd, "config", "--get", key] if cwd else ["git", "config", scope, "--get", key]
    rc, out = run(cmd)
    return out.strip() if rc == 0 else ""


def sha(path) -> str:
    """SHA-256 of a file's contents."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def status(cfg: dict) -> list[Result]:
    """Run every check for the given config and return the results in display order."""
    out: list[Result] = []
    add = out.append
    hint = install_hint()

    # --- Tools ---
    for tool in cfg.get("tools") or []:
        path = which(tool["command"])
        if path:
            add(Result("Tools", tool["name"], "Pass", path))
        else:
            add(Result("Tools", tool["name"], "Fail", f"'{tool['command']}' not found on PATH", tools.install_hint(tool)))
    has_git, has_gh, has_code = which("git"), which("gh"), which("code")

    # --- Git ---
    if has_git:
        name = git_config("user.name")
        add(Result("Git", "user.name", "Pass", name) if name else
            Result("Git", "user.name", "Fail", "Not set", 'git config --global user.name "<name>"'))
        add(Result("Git", "user.email", "Pass", "Set") if git_config("user.email") else
            Result("Git", "user.email", "Fail", "Not set", 'git config --global user.email "<email>"'))
        rc, helper = run(["git", "config", "--get", "credential.helper"])
        add(Result("Git", "Credential helper", "Pass", helper.strip()) if helper.strip() else
            Result("Git", "Credential helper", "Warn", "None configured; git may prompt for passwords", "gh auth setup-git"))

    # --- GitHub CLI ---
    if has_gh:
        login = gh_login()
        if not login:
            add(Result("GitHub", "Signed in", "Fail", "gh is not authenticated", "gh auth login --web"))
        else:
            add(Result("GitHub", "Signed in", "Pass", f"as {login}"))
            scopes = gh_scopes()
            if scopes is None:
                add(Result("GitHub", "Token scopes", "Warn", "Could not read token scopes"))
            else:
                missing = [s for s in cfg["github"]["requiredScopes"] if s not in scopes]
                add(Result("GitHub", "Token scopes", "Pass", ", ".join(scopes)) if not missing else
                    Result("GitHub", "Token scopes", "Fail", f"Missing: {', '.join(missing)}",
                           f"gh auth refresh -h github.com -s {','.join(missing)}"))

    # --- VS Code extensions ---
    if has_code:
        installed = vscode_extensions()
        for ext in cfg.get("vscodeExtensions") or []:
            if ext["id"].lower() in installed:
                add(Result("VS Code", ext["name"], "Pass", ext["id"]))
            else:
                add(Result("VS Code", ext["name"], "Fail" if ext.get("required", True) else "Warn",
                           f"{ext['id']} not installed", f"code --install-extension {ext['id']}"))

    # --- Folders ---
    root = config.code_root(cfg)
    add(Result("Folders", "Code root", "Pass", str(root)) if root.is_dir() else
        Result("Folders", "Code root", "Fail", f"{root} does not exist", hint))

    # --- Skill repos ---
    repos = config.skill_repos(cfg)
    for r in repos:
        if (r.clone / ".git").exists():
            add(Result(r.name, "Working clone", "Pass", str(r.clone)))
        else:
            add(Result(r.name, "Working clone", "Fail", f"{r.clone} not found", hint))

        branch = ""
        if has_git and r.worktree.exists():
            _, branch = run(["git", "-C", str(r.worktree), "branch", "--show-current"])
            branch = branch.strip()
        if branch == "main":
            add(Result(r.name, "main worktree", "Pass", str(r.worktree)))
        elif branch:
            add(Result(r.name, "main worktree", "Fail", f"{r.worktree} is on '{branch}', expected main",
                       f'git -C "{r.worktree}" switch main'))
        else:
            add(Result(r.name, "main worktree", "Fail", f"{r.worktree} not found", hint))

        # Repos without server-side branch protection rely on the repo's pre-push hook.
        if r.local_main_guard and has_git and (r.clone / ".git").exists():
            if git_config("core.hooksPath", cwd=str(r.clone)) != "hooks":
                add(Result(r.name, "Push guard on main", "Fail", "core.hooksPath not set; pushes to main are not blocked",
                           f'git -C "{r.clone}" config core.hooksPath hooks'))
            elif not (r.clone / "hooks" / "pre-push").exists():
                add(Result(r.name, "Push guard on main", "Warn", "Enabled, but hooks/pre-push is not in this checkout"))
            else:
                add(Result(r.name, "Push guard on main", "Pass", "pre-push blocks main"))

        src = r.worktree / "skills"
        if src.is_dir():
            skills = sorted(p.name for p in src.iterdir() if p.is_dir())
            missing = [s for s in skills if not (CLAUDE_SKILLS / s).exists()]
            add(Result(r.name, "Skills linked", "Pass", f"{len(skills)} skill(s)") if not missing else
                Result(r.name, "Skills linked", "Warn", f"Not linked yet: {', '.join(missing)}",
                       "Start a new Claude Code session (the SessionStart hook links them)"))

    # --- Claude Code ---
    instructions = config.global_instructions_source(cfg)
    if repos:
        add(Result("Claude Code", "Sync script", "Pass", str(SYNC_SCRIPT)) if SYNC_SCRIPT.exists() else
            Result("Claude Code", "Sync script", "Fail", "Not installed", hint))
        needed = [str(r.worktree) for r in repos] + ([str(instructions)] if instructions else [])
        add(Result("Claude Code", "SessionStart hook", "Pass", f"syncs {len(repos)} repo(s)")
            if claude.sync_hook_installed(CLAUDE_SETTINGS, needed) else
            Result("Claude Code", "SessionStart hook", "Fail", "Missing, old, or not syncing every repo and CLAUDE.md", hint))

    # ~/.claude/CLAUDE.md is a copy of the repo file, refreshed by the sync hook.
    if instructions:
        if not instructions.exists():
            add(Result("Claude Code", "Global CLAUDE.md", "Warn", f"Source {instructions} not found (not merged to main yet?)"))
        elif not CLAUDE_MD.exists():
            add(Result("Claude Code", "Global CLAUDE.md", "Fail", f"{CLAUDE_MD} missing", hint))
        elif sha(instructions) == sha(CLAUDE_MD):
            add(Result("Claude Code", "Global CLAUDE.md", "Pass", f"matches {instructions}"))
        else:
            add(Result("Claude Code", "Global CLAUDE.md", "Warn", "Differs from the repo copy (local edits, or not synced yet)",
                       f"Move local edits into {instructions} through a PR; the next session start refreshes it"))

    cl = cfg.get("claude") or {}
    rules = cl.get("denyRules") or []
    if rules:
        missing_rules = claude.missing_deny_rules(CLAUDE_SETTINGS, rules)
        if not missing_rules:
            add(Result("Claude Code", "Deny rules", "Pass", f"{len(rules)} rule(s) in permissions.deny"))
        else:
            add(Result("Claude Code", "Deny rules", "Fail",
                       f"{len(missing_rules)} of {len(rules)} missing from permissions.deny", hint))
    if cl.get("sensitiveTermsFile"):
        terms = expand_path(cl["sensitiveTermsFile"])
        n = claude.terms_count(terms)
        if n < 0:
            add(Result("Claude Code", "Private terms file", "Fail", "Not created", hint))
        elif n <= 3:
            add(Result("Claude Code", "Private terms file", "Warn",
                       f"{n} term(s): add your hostnames, local domain and network names", editor_hint(terms)))
        else:
            add(Result("Claude Code", "Private terms file", "Pass", f"{n} term(s)"))
    return out
