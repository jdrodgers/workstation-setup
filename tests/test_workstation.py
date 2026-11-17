"""Unit tests for the workstation package and the SessionStart sync script.

They touch only temporary folders (never the real ~/.claude) and run on Windows, macOS and Linux.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path

import pytest

from workstation import claude, config, tools
from workstation.platforms import expand_path

REPO = Path(__file__).resolve().parent.parent


def load_sync_module():
    """Import files/sync_ai_skills.py (a standalone script, not part of the package)."""
    spec = importlib.util.spec_from_file_location("sync_ai_skills", REPO / "files" / "sync_ai_skills.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sync = load_sync_module()


# --- config ---------------------------------------------------------------------

def test_platform_value_picks_platform_then_default():
    """Per-platform objects resolve to the platform's entry, then 'default'; plain values pass through."""
    v = {"windows": "c:/code", "default": "~/code"}
    assert config.platform_value(v, "windows") == "c:/code"
    assert config.platform_value(v, "linux") == "~/code"
    assert config.platform_value("~/x", "macos") == "~/x"
    assert config.platform_value({"windows": 1}, "linux") is None


def test_expand_path_home_and_relative():
    """A leading ~ is the home folder; relative paths join the base."""
    assert expand_path("~/code") == Path.home() / "code"
    assert expand_path("ai-skills", Path("/base")) == Path("/base") / "ai-skills"
    absolute = Path.home() / "elsewhere"
    assert expand_path(str(absolute), Path("/base")) == absolute


def test_shipped_config_resolves():
    """The real config loads, puts repos under the code root, and finds the CLAUDE.md source."""
    cfg = config.load(REPO / "config" / "workstation.json")
    root = config.code_root(cfg)
    repos = config.skill_repos(cfg)
    assert repos and all(r.clone.parent == root for r in repos)
    src = config.global_instructions_source(cfg)
    assert src == repos[0].worktree / "claude" / "CLAUDE.md"


def test_local_override_replaces_top_level_keys(tmp_path):
    """workstation.local.json next to the config overrides top-level keys."""
    (tmp_path / "w.json").write_text(json.dumps({"codeRoot": "~/code", "skillRepos": []}))
    (tmp_path / "w.local.json").write_text(json.dumps({"codeRoot": str(tmp_path / "src")}))
    cfg = config.load(tmp_path / "w.json")
    assert config.code_root(cfg) == tmp_path / "src"


# --- tools ----------------------------------------------------------------------

GH = {"name": "GitHub CLI", "command": "gh", "install": {"winget": "GitHub.cli", "brew": "gh", "apt": "gh", "dnf": "gh"}}
CODE = {"name": "VS Code", "command": "code",
        "install": {"winget": "Microsoft.VisualStudioCode", "brewCask": "visual-studio-code", "snap": "code --classic"}}


def test_install_command_per_platform():
    """Each platform uses its first available manager, with extra arguments kept."""
    every = lambda exe: True  # noqa: E731 - every manager present
    assert tools.install_command(GH, "windows", every)[:4] == ["winget", "install", "--id", "GitHub.cli"]
    assert tools.install_command(CODE, "macos", every) == ["brew", "install", "--cask", "visual-studio-code"]
    assert tools.install_command(GH, "linux", every) == ["sudo", "apt-get", "install", "-y", "gh"]
    assert tools.install_command(CODE, "linux", every) == ["sudo", "snap", "install", "code", "--classic"]


def test_install_command_skips_missing_managers():
    """Managers not on the machine are skipped; None when nothing fits."""
    only_dnf = lambda exe: exe == "dnf"  # noqa: E731
    assert tools.install_command(GH, "linux", only_dnf) == ["sudo", "dnf", "install", "-y", "gh"]
    assert tools.install_command(CODE, "linux", only_dnf) is None


# --- settings.json ----------------------------------------------------------------

def test_register_hook_replaces_old_entry_and_keeps_others(tmp_path):
    """The PowerShell-era hook is replaced; other hooks and settings survive; a .bak is written."""
    s = tmp_path / "settings.json"
    other = {"matcher": "startup", "hooks": [{"type": "command", "command": "echo hi"}]}
    old = {"matcher": "startup", "hooks": [{"type": "command", "command": "powershell.exe",
                                            "args": ["-File", "x/sync-ai-skills.ps1", "-Repo", "a"]}]}
    s.write_text(json.dumps({"model": "x", "hooks": {"SessionStart": [other, old]}}))
    args = claude.sync_hook_args(Path("/h/sync_ai_skills.py"), [Path("/c/a-main"), Path("/c/b-main")],
                                 Path("/c/a-main/claude/CLAUDE.md"))
    claude.register_sync_hook(s, ["python3"], args)

    data = json.loads(s.read_text())
    assert data["model"] == "x"
    entries = data["hooks"]["SessionStart"]
    assert entries[0] == other and len(entries) == 2
    assert entries[1]["hooks"][0]["command"] == "python3"
    assert (tmp_path / "settings.json.bak").exists()
    assert claude.sync_hook_installed(s, [str(Path("/c/a-main")), str(Path("/c/b-main"))])
    assert not claude.sync_hook_installed(s, [str(Path("/c/other-main"))])


def test_old_powershell_hook_does_not_count_as_installed(tmp_path):
    """A hook that still runs the .ps1 script is reported as needing replacement."""
    s = tmp_path / "settings.json"
    s.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"command": "powershell.exe",
                                                                    "args": ["sync-ai-skills.ps1", "c:/code/a-main"]}]}]}}))
    assert not claude.sync_hook_installed(s, ["c:/code/a-main"])


def test_deny_rules_merge(tmp_path):
    """Only missing deny rules are added, after the existing ones; allow rules are untouched."""
    s = tmp_path / "settings.json"
    s.write_text(json.dumps({"permissions": {"allow": ["Bash(ls)"], "deny": ["Read(a)"]}}))
    assert claude.missing_deny_rules(s, ["Read(a)", "Read(b)"]) == ["Read(b)"]
    claude.add_deny_rules(s, ["Read(b)"])
    perms = json.loads(s.read_text())["permissions"]
    assert perms == {"allow": ["Bash(ls)"], "deny": ["Read(a)", "Read(b)"]}


def test_invalid_settings_are_not_overwritten(tmp_path):
    """Invalid JSON stops the write so the user can fix the file."""
    s = tmp_path / "settings.json"
    s.write_text("{not json")
    with pytest.raises(SystemExit):
        claude.add_deny_rules(s, ["Read(x)"])
    assert s.read_text() == "{not json"


def test_terms_file_created_once(tmp_path):
    """The terms file is created with a header and never overwritten."""
    p = tmp_path / "cfg" / "terms.txt"
    assert claude.init_terms_file(p) >= 1
    assert claude.terms_count(p) >= 1
    p.write_text("custom\n")
    assert claude.init_terms_file(p) == 0
    assert p.read_text() == "custom\n"


# --- sync script: links ------------------------------------------------------------

def test_sync_links_new_and_removes_deleted_skills(tmp_path):
    """New skills are linked, links to deleted skills are removed, real folders are left alone."""
    worktree = tmp_path / "repo-main"
    (worktree / "skills" / "one").mkdir(parents=True)
    (worktree / "skills" / "two").mkdir()
    dst = tmp_path / "claude" / "skills"
    (dst / "mine").mkdir(parents=True)  # a real folder, not a link

    msgs = sync.sync_repo(worktree, dst, pull=False)
    assert "linked one, two" in " ".join(msgs)
    assert (dst / "one").exists() and sync.link_target(dst / "one") is not None

    (worktree / "skills" / "two").rmdir()
    sync.sync_repo(worktree, dst, pull=False)
    assert not os.path.lexists(dst / "two")
    assert (dst / "one").exists() and (dst / "mine").is_dir()


def test_sync_reports_name_clash(tmp_path):
    """A skill name already linked from another repo is reported, not replaced."""
    a, b = tmp_path / "a-main", tmp_path / "b-main"
    (a / "skills" / "same").mkdir(parents=True)
    (b / "skills" / "same").mkdir(parents=True)
    dst = tmp_path / "skills"
    sync.sync_repo(a, dst, pull=False)
    msgs = sync.sync_repo(b, dst, pull=False)
    assert any("already comes from" in m for m in msgs)


# --- sync script: CLAUDE.md --------------------------------------------------------

def test_instructions_copy_update_and_local_edit(tmp_path):
    """Missing -> copied; repo change -> updated; local edit -> kept and reported."""
    src, dst, stamp = tmp_path / "src.md", tmp_path / "CLAUDE.md", tmp_path / "s" / "stamp"
    src.write_text("v1")
    assert "updated" in sync.sync_instructions(src, dst, stamp)[0]
    assert dst.read_text() == "v1"

    assert sync.sync_instructions(src, dst, stamp) == []  # in step: nothing to say

    src.write_text("v2")
    sync.sync_instructions(src, dst, stamp)
    assert dst.read_text() == "v2"

    dst.write_text("my local change")
    msgs = sync.sync_instructions(src, dst, stamp)
    assert "local edits" in msgs[0] and dst.read_text() == "my local change"


def test_instructions_adopts_identical_existing_file(tmp_path):
    """An existing CLAUDE.md that already matches the repo is adopted (stamp written, file untouched)."""
    src, dst, stamp = tmp_path / "src.md", tmp_path / "CLAUDE.md", tmp_path / "stamp"
    src.write_text("same")
    dst.write_text("same")
    assert sync.sync_instructions(src, dst, stamp) == []
    assert stamp.exists()


def test_instructions_missing_source_keeps_file(tmp_path):
    """No source (e.g. not merged yet) leaves CLAUDE.md alone."""
    dst = tmp_path / "CLAUDE.md"
    dst.write_text("keep")
    msgs = sync.sync_instructions(tmp_path / "nope.md", dst, tmp_path / "stamp")
    assert "not found" in msgs[0] and dst.read_text() == "keep"
