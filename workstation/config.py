"""Load config/workstation.json and resolve its values for this platform."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .platforms import expand_path, platform_key

DEFAULT_CONFIG = Path(__file__).resolve().parent.parent / "config" / "workstation.json"


@dataclass
class SkillRepo:
    """One skill repo: a working clone for branches, and a `main` worktree that Claude Code loads skills from."""

    name: str
    repo: str            # owner/name on GitHub
    clone: Path
    worktree: Path
    local_main_guard: bool  # enable the repo's pre-push hook that blocks pushes to main


def load(path: Path | None = None) -> dict:
    """Read the config file (default: config/workstation.json next to this package).

    If a git-ignored `<name>.local.json` sits next to it (e.g. workstation.local.json),
    its top-level keys replace the shared ones, for settings that differ on one machine,
    such as {"codeRoot": "c:/code"} on a PC that predates the ~/code default.
    """
    path = path or DEFAULT_CONFIG
    if not path.exists():
        raise SystemExit(f"Config file not found: {path}")
    cfg = json.loads(path.read_text(encoding="utf-8"))
    local = path.with_name(path.stem + ".local.json")
    if local.exists():
        cfg.update(json.loads(local.read_text(encoding="utf-8")))
    return cfg


def platform_value(value, platform: str | None = None):
    """Resolve a value that may differ by platform.

    A plain value is returned as is. An object keyed by 'windows' / 'macos' / 'linux'
    (with an optional 'default') returns the entry for this platform, or None.
    """
    if not isinstance(value, dict):
        return value
    platform = platform or platform_key()
    if platform in value:
        return value[platform]
    return value.get("default")


def code_root(cfg: dict) -> Path:
    """The folder repos are cloned into, for this platform."""
    return expand_path(platform_value(cfg["codeRoot"]))


def skill_repos(cfg: dict) -> list[SkillRepo]:
    """The skill repos from the config, with relative paths placed under the code root."""
    root = code_root(cfg)
    return [SkillRepo(name=r["name"], repo=r["repo"],
                      clone=expand_path(r["clonePath"], root),
                      worktree=expand_path(r["mainWorktreePath"], root),
                      local_main_guard=bool(r.get("localMainGuard")))
            for r in cfg.get("skillRepos") or []]


def global_instructions_source(cfg: dict) -> Path | None:
    """The repo file that ~/.claude/CLAUDE.md is kept in step with, or None if not configured.

    claude.globalInstructions names a skill repo and a path inside it; the file is read
    from that repo's main worktree, so only merged changes reach every session.
    """
    gi = (cfg.get("claude") or {}).get("globalInstructions") or {}
    if not gi.get("repo") or not gi.get("path"):
        return None
    for r in skill_repos(cfg):
        if r.name == gi["repo"]:
            return expand_path(gi["path"], r.worktree)
    raise SystemExit(f"claude.globalInstructions.repo '{gi['repo']}' is not in skillRepos")
