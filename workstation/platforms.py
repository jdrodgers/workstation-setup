"""What differs between Windows, macOS and Linux: platform names, paths, and running commands."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
CLAUDE_SETTINGS = CLAUDE_DIR / "settings.json"
CLAUDE_SKILLS = CLAUDE_DIR / "skills"
CLAUDE_MD = CLAUDE_DIR / "CLAUDE.md"
CLAUDE_SCRIPTS = CLAUDE_DIR / "scripts"
SYNC_SCRIPT = CLAUDE_SCRIPTS / "sync_ai_skills.py"
# Installed by the PowerShell version of this repo; replaced by SYNC_SCRIPT.
OLD_SYNC_SCRIPT = CLAUDE_SCRIPTS / "sync-ai-skills.ps1"


def platform_key() -> str:
    """Return 'windows', 'macos' or 'linux': the keys used for per-platform values in the config."""
    if os.name == "nt":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return "linux"


def expand_path(value: str, base: Path | None = None) -> Path:
    """Expand environment variables and a leading ~ in a config path.

    A relative result is taken as relative to `base` when one is given (e.g. repo paths
    relative to the code root). Config files can use '/' on every platform.
    """
    path = Path(os.path.expanduser(os.path.expandvars(value)))
    if base is not None and not path.is_absolute():
        path = base / path
    return path


def which(name: str) -> str | None:
    """Full path of a command on PATH, or None. Resolves Windows .cmd/.exe wrappers (code, gh)."""
    return shutil.which(name)


def run(cmd: list[str]) -> tuple[int, str]:
    """Run a command quietly and return (exit code, stdout). Used by read-only probes.

    Missing commands return (127, "") instead of raising, so a probe never stops a check.
    """
    exe = which(cmd[0])
    if exe is None:
        return 127, ""
    try:
        r = subprocess.run([exe, *cmd[1:]], capture_output=True, text=True, encoding="utf-8", errors="replace")
    except OSError:
        return 127, ""
    return r.returncode, r.stdout


def run_visible(cmd: list[str]) -> int:
    """Run a command with the terminal attached (for installers, browser logins, sudo prompts).

    Returns the exit code; 127 when the command doesn't exist.
    """
    exe = which(cmd[0])
    if exe is None:
        return 127
    return subprocess.run([exe, *cmd[1:]]).returncode


def refresh_path() -> None:
    """Windows only: reload PATH from the registry after winget installs something.

    winget updates the registry, not this process's environment. Other platforms'
    package managers install onto the existing PATH, so this does nothing there.
    """
    if platform_key() != "windows":
        return
    import winreg  # Windows-only module

    parts = []
    for root, key in ((winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
                      (winreg.HKEY_CURRENT_USER, "Environment")):
        try:
            with winreg.OpenKey(root, key) as k:
                parts.append(os.path.expandvars(winreg.QueryValueEx(k, "Path")[0]))
        except OSError:
            pass
    if parts:
        os.environ["PATH"] = ";".join(parts)


def hook_python() -> list[str]:
    """The command that runs a Python script from the Claude Code SessionStart hook.

    On Windows the `py` launcher is preferred: it stays at a fixed path when Python is
    upgraded, while python.exe's folder changes with each minor version. Elsewhere the
    python3 on PATH (or this interpreter) is used.
    """
    if platform_key() == "windows":
        py = which("py")
        if py:
            return [py, "-3"]
        return [sys.executable]
    return [which("python3") or sys.executable]


def restrict_to_owner(path: Path) -> None:
    """Make a file readable only by the current user (ACL on Windows, mode 600 elsewhere)."""
    if platform_key() == "windows":
        user = os.environ.get("USERNAME", "")
        subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"{user}:(F)"],
                       capture_output=True)
    else:
        os.chmod(path.parent, 0o700)
        os.chmod(path, 0o600)


def editor_hint(path: Path) -> str:
    """A command that opens a file for editing; VS Code is a required tool on every platform."""
    return f'code "{path}"'
