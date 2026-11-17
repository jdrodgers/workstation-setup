"""Pick the package-manager command that installs a tool on this machine."""
from __future__ import annotations

from .platforms import platform_key, which

# Managers to try, in order, per platform. A tool's "install" object in the config gives
# its package name for each manager it supports; the first one present on the machine wins.
MANAGER_ORDER = {
    "windows": ["winget"],
    "macos": ["brewCask", "brew"],
    "linux": ["apt", "dnf", "snap"],
}
MANAGER_EXE = {"winget": "winget", "brew": "brew", "brewCask": "brew", "apt": "apt-get", "dnf": "dnf", "snap": "snap"}


def build_command(manager: str, package: str) -> list[str]:
    """The full install command for one package with one manager.

    `package` may carry extra arguments after the name (e.g. snap's "code --classic").
    Linux managers run under sudo, which prompts for a password in the terminal.
    """
    pkg = package.split()
    if manager == "winget":
        return ["winget", "install", "--id", pkg[0], "--exact", "--silent",
                "--accept-source-agreements", "--accept-package-agreements"]
    if manager == "brew":
        return ["brew", "install", *pkg]
    if manager == "brewCask":
        return ["brew", "install", "--cask", *pkg]
    if manager == "apt":
        return ["sudo", "apt-get", "install", "-y", *pkg]
    if manager == "dnf":
        return ["sudo", "dnf", "install", "-y", *pkg]
    if manager == "snap":
        return ["sudo", "snap", "install", *pkg]
    raise ValueError(f"unknown package manager {manager}")


def install_command(tool: dict, platform: str | None = None, has=which) -> list[str] | None:
    """The command that installs `tool` here, or None if no listed manager is available.

    `has` checks whether a command exists (injectable for tests).
    """
    install = tool.get("install") or {}
    for manager in MANAGER_ORDER[platform or platform_key()]:
        if install.get(manager) and has(MANAGER_EXE[manager]):
            return build_command(manager, install[manager])
    return None


def install_hint(tool: dict) -> str:
    """Fix text for a missing tool: the install command, or what to do when there is none."""
    cmd = install_command(tool)
    if cmd:
        return " ".join(cmd)
    tried = ", ".join(dict.fromkeys(MANAGER_EXE[m] for m in MANAGER_ORDER[platform_key()]))
    return f"Install {tool['name']} yourself (no configured package manager found; looked for {tried})"
