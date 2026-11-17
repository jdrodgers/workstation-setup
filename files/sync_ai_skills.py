#!/usr/bin/env python3
"""Claude Code SessionStart hook: refresh skill repos from main and link them into ~/.claude.

For each skill repo's main worktree: `git pull --ff-only`, then link every folder in its
`skills/` into ~/.claude/skills (a directory junction on Windows, which needs no admin
rights; a symlink elsewhere), and remove links to skills deleted from the repo.
With --instructions, also keeps ~/.claude/CLAUDE.md a copy of that repo file (see
sync_instructions for how local edits are protected).

Installed by workstation-setup (python -m workstation install). Edit files/sync_ai_skills.py
in that repo, not the installed copy. Standard library only, Python 3.9+.

Usage:
  sync_ai_skills.py --repo <main worktree> [--repo ...] [--instructions <file>]

Prints {"systemMessage": "..."} (shown by Claude Code) when there is something to report.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
WINDOWS = os.name == "nt"


# --- links ------------------------------------------------------------------------

def _clean(target: str) -> str:
    r"""Normalize a link target for comparison (drops Windows' \\?\ prefix, folds case on Windows)."""
    if target.startswith("\\\\?\\"):
        target = target[4:]
    return os.path.normcase(os.path.normpath(target))


def link_target(path: Path) -> str | None:
    """Target of a symlink or Windows junction, or None if `path` is not a link.

    os.readlink reads junctions too on Python 3.8+ for Windows.
    """
    try:
        return os.readlink(path)
    except (OSError, ValueError):
        return None


def make_dir_link(link: Path, target: Path) -> None:
    """Create a directory link: a junction on Windows (no admin or Developer Mode needed), else a symlink."""
    if WINDOWS:
        r = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], capture_output=True, text=True)
        if r.returncode != 0:
            raise OSError(r.stderr.strip() or r.stdout.strip())
    else:
        os.symlink(target, link, target_is_directory=True)


def remove_link(link: Path) -> None:
    """Remove a link without touching what it points to (rmdir for junctions, unlink for symlinks)."""
    if WINDOWS and not link.is_symlink():
        os.rmdir(link)
    else:
        os.unlink(link)


def sync_repo(worktree: Path, skills_dst: Path, pull: bool = True) -> list[str]:
    """Pull one main worktree and link its skills into `skills_dst`. Returns messages to report."""
    name = worktree.name
    if not worktree.exists():
        return [f"{name}: not found"]
    msgs = []
    if pull and shutil.which("git"):
        r = subprocess.run(["git", "-C", str(worktree), "pull", "--ff-only", "--quiet"], capture_output=True)
        if r.returncode != 0:
            msgs.append(f"{name}: could not pull main, using last copy")  # offline, etc.

    src = worktree / "skills"
    if not src.is_dir():
        return msgs
    skills_dst.mkdir(parents=True, exist_ok=True)
    added = []
    for skill in sorted(p for p in src.iterdir() if p.is_dir()):
        link = skills_dst / skill.name
        if not os.path.lexists(link):
            make_dir_link(link, skill)
            added.append(skill.name)
            continue
        current = link_target(link)
        if current is not None and _clean(current) != _clean(str(skill)):
            msgs.append(f"{name}: skill '{skill.name}' already comes from {current}; rename one")
    if added:
        msgs.append(f"{name}: linked {', '.join(added)}")

    # Remove links into this repo whose skill no longer exists (only links, never real folders).
    prefix = _clean(str(src))
    for entry in skills_dst.iterdir():
        target = link_target(entry)
        # entry.exists() follows the link, so it is False when the skill folder is gone.
        if target and _clean(target).startswith(prefix) and not entry.exists():
            remove_link(entry)
    return msgs


# --- CLAUDE.md --------------------------------------------------------------------

def _sha(path: Path) -> str:
    """SHA-256 of a file's contents."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sync_instructions(source: Path, dest: Path, stamp: Path) -> list[str]:
    """Keep `dest` (~/.claude/CLAUDE.md) a copy of `source` without losing local edits.

    `stamp` records the hash of the last copy made. The file is replaced only when it is
    missing or still exactly what was last copied; if someone edited it locally, it is
    left alone and the message says to move the edits into the repo. A copy is used
    instead of a link because file symlinks need Developer Mode or admin on Windows.
    """
    if not source.exists():
        return [f"CLAUDE.md: {source} not found, keeping the current file"]
    want = _sha(source)
    have = _sha(dest) if dest.exists() else ""
    last = stamp.read_text(encoding="utf-8").strip() if stamp.exists() else ""
    stamp.parent.mkdir(parents=True, exist_ok=True)
    if have == want:
        if last != want:
            stamp.write_text(want, encoding="utf-8")
        return []
    if have and have != last:
        return [f"CLAUDE.md: {dest} has local edits; move them into {source} (via a PR) and delete the local file"]
    shutil.copyfile(source, dest)
    stamp.write_text(want, encoding="utf-8")
    return [f"CLAUDE.md: updated from {source}"]


def main() -> None:
    """Parse arguments, sync every repo and CLAUDE.md, and print a summary for Claude Code."""
    ap = argparse.ArgumentParser(description="Sync skill repos into ~/.claude (Claude Code SessionStart hook).")
    ap.add_argument("--repo", action="append", default=[], help="main worktree of a skill repo (repeatable)")
    ap.add_argument("--instructions", help="repo file to keep ~/.claude/CLAUDE.md in step with")
    a = ap.parse_args()
    msgs = []
    for repo in a.repo:
        try:
            msgs += sync_repo(Path(repo), CLAUDE_DIR / "skills")
        except OSError as e:  # never fail the session start; report instead
            msgs.append(f"{Path(repo).name}: {e}")
    if a.instructions:
        try:
            msgs += sync_instructions(Path(a.instructions), CLAUDE_DIR / "CLAUDE.md",
                                      CLAUDE_DIR / "scripts" / "CLAUDE.md.synced.sha256")
        except OSError as e:
            msgs.append(f"CLAUDE.md: {e}")
    if msgs:
        print(json.dumps({"systemMessage": "; ".join(msgs)}))


if __name__ == "__main__":
    main()
