"""Claude Code user settings: the skill-sync SessionStart hook, deny rules, and the private terms file.

Every write keeps all existing settings and hooks, and copies settings.json to
settings.json.bak first. Invalid JSON is never overwritten.
"""
from __future__ import annotations

import getpass
import json
import os
import platform as _platform
import shutil
from pathlib import Path

from .platforms import platform_key, restrict_to_owner, run

# Both the old PowerShell script and the Python one count as "the sync hook", so
# re-registering replaces an entry left by the PowerShell version of this repo.
SYNC_SCRIPT_NAMES = ("sync-ai-skills.ps1", "sync_ai_skills.py")


def read_settings(path: Path) -> dict | None:
    """Return settings.json as a dict, {} if it is empty, or None if it doesn't exist.

    Raises SystemExit on invalid JSON so nothing overwrites a file the user must fix by hand.
    """
    if not path.exists():
        return None
    raw = path.read_text(encoding="utf-8-sig")
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise SystemExit(f"{path} is not valid JSON; fix it by hand, then re-run. ({e})") from None


def save_settings(path: Path, settings: dict) -> None:
    """Write settings.json (UTF-8, no BOM), backing up the current file to settings.json.bak."""
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + ".bak"))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")


def _hook_text(entry: dict) -> str:
    """All command and argument text of a SessionStart entry, for matching."""
    parts = []
    for hook in entry.get("hooks") or []:
        parts.append(str(hook.get("command", "")))
        parts.extend(str(a) for a in hook.get("args") or [])
    return " ".join(parts)


def is_sync_hook_entry(entry: dict) -> bool:
    """True if a SessionStart entry runs one of the skill-sync scripts."""
    text = _hook_text(entry)
    return any(name in text for name in SYNC_SCRIPT_NAMES)


def sync_hook_args(sync_script: Path, repos: list[Path], instructions: Path | None) -> list[str]:
    """Arguments for the sync script: one --repo per main worktree, and the CLAUDE.md source."""
    args = [str(sync_script)]
    for r in repos:
        args += ["--repo", str(r)]
    if instructions:
        args += ["--instructions", str(instructions)]
    return args


def sync_hook_installed(settings_path: Path, required: list[str]) -> bool:
    """True when a SessionStart hook runs the Python sync script with every `required` value in its arguments.

    Comparison ignores case on Windows, where paths are case-insensitive.
    """
    try:
        settings = read_settings(settings_path)
    except SystemExit:
        return False
    fold = (lambda s: s.lower()) if platform_key() == "windows" else (lambda s: s)
    for entry in ((settings or {}).get("hooks") or {}).get("SessionStart") or []:
        text = fold(_hook_text(entry))
        if "sync_ai_skills.py" in text and all(fold(str(v)) in text for v in required):
            return True
    return False


def register_sync_hook(settings_path: Path, command: list[str], args: list[str]) -> None:
    """Set the skill-sync SessionStart hook: drop older sync entries, add one, keep everything else.

    `command` is the Python launcher (e.g. ["py", "-3"]); its first element becomes the
    hook's command and the rest are prepended to `args`.
    """
    settings = read_settings(settings_path) or {}
    hooks = settings.setdefault("hooks", {})
    kept = [e for e in hooks.get("SessionStart") or [] if e and not is_sync_hook_entry(e)]
    kept.append({
        "matcher": "startup",
        "hooks": [{
            "type": "command",
            "command": command[0],
            "args": [*command[1:], *args],
            "timeout": 30,
            "statusMessage": "Syncing skills from main",
        }],
    })
    hooks["SessionStart"] = kept
    save_settings(settings_path, settings)


def missing_deny_rules(settings_path: Path, rules: list[str]) -> list[str]:
    """Deny rules from the config that aren't in settings.json permissions.deny yet."""
    try:
        settings = read_settings(settings_path) or {}
    except SystemExit:
        return list(rules)
    have = set((settings.get("permissions") or {}).get("deny") or [])
    return [r for r in rules if r not in have]


def add_deny_rules(settings_path: Path, rules: list[str]) -> None:
    """Append deny rules to permissions.deny, keeping existing allow/deny/ask rules and their order."""
    if not rules:
        return
    settings = read_settings(settings_path) or {}
    deny = settings.setdefault("permissions", {}).setdefault("deny", [])
    deny.extend(r for r in rules if r not in deny)
    save_settings(settings_path, settings)


# --- Private terms file (read by the public-repo-hygiene scanner) -------------------

TERMS_HEADER = [
    "# Private terms for the public-repo-hygiene scanner. One per line; prefix re: for a regex.",
    "# Add your hostnames, local domain, network names, device names, and anything else",
    "# that identifies your environment. This file must never be committed or shared,",
    "# and AI agents are denied from reading it.",
    "",
]


def terms_count(path: Path) -> int:
    """Number of terms in the file (non-blank, non-comment lines), or -1 if it doesn't exist."""
    if not path.exists():
        return -1
    return sum(1 for ln in path.read_text(encoding="utf-8").splitlines()
               if ln.strip() and not ln.strip().startswith("#"))


def init_terms_file(path: Path) -> int:
    """Create the terms file seeded with this machine's identifying values; owner-only access.

    Never overwrites an existing file. Returns how many terms were seeded; the values
    themselves are never printed.
    """
    if path.exists():
        return 0
    node = _platform.node()
    seed = []
    # macOS/Linux may report a fully qualified name; seed the short name too.
    for v in (getpass.getuser(), node, node.split(".")[0]):
        if v and len(v) >= 3 and v not in seed:
            seed.append(v)
    rc, email = run(["git", "config", "--global", "--get", "user.email"])
    if rc == 0 and email.strip():
        seed.append(email.strip())
    path.parent.mkdir(parents=True, exist_ok=True)
    # Create with owner-only permissions from the start on POSIX (no window where it's readable).
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(TERMS_HEADER + seed) + "\n")
    restrict_to_owner(path)
    return len(seed)
