"""Command line: `python -m workstation check|install` (run from the repo root)."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import checks, config
from .install import Installer

COLORS = {"Pass": "\033[32m", "Warn": "\033[33m", "Fail": "\033[31m"}
RESET, GREY, CYAN = "\033[0m", "\033[90m", "\033[36m"


def color_ok() -> bool:
    """True when stdout is a terminal that shows ANSI colors (Windows 10+ terminals do, once enabled)."""
    if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
        return False
    if os.name == "nt":
        os.system("")  # turns on ANSI escape handling in the Windows console
    return True


def print_report(results: list[checks.Result]) -> int:
    """Print results grouped by area with fixes for anything not passing. Returns the exit code (1 if any failed)."""
    use = color_ok()

    def c(code: str, text: str) -> str:
        """Wrap text in a color code when colors are on."""
        return f"{code}{text}{RESET}" if use else text

    area = None
    for r in results:
        if r.area != area:
            area = r.area
            print(f"\n{c(CYAN, area)}")
        print(f"  {c(COLORS[r.status], '[' + r.status.upper() + ']')} {r.check:<22} {r.detail}")
        if r.status != "Pass" and r.fix:
            print(c(GREY, f"         fix: {r.fix}"))
    counts = {s: sum(1 for r in results if r.status == s) for s in ("Pass", "Warn", "Fail")}
    summary = f"{counts['Pass']} passed, {counts['Warn']} warning(s), {counts['Fail']} failed"
    worst = "Fail" if counts["Fail"] else "Warn" if counts["Warn"] else "Pass"
    print(f"\n{c(COLORS[worst], summary)}")
    if counts["Fail"]:
        print(c(GREY, f"{checks.install_hint()} to fix what it can."))
    return 1 if counts["Fail"] else 0


def main() -> None:
    """Parse the command line and run `check` or `install`."""
    ap = argparse.ArgumentParser(prog="python -m workstation",
                                 description="Check or set up this workstation (Windows, macOS, Linux).")
    ap.add_argument("--config", type=Path, help="config file (default: config/workstation.json)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="read-only report; exits 1 if anything fails")
    c.add_argument("--json", action="store_true", help="print results as JSON")
    i = sub.add_parser("install", help="install and configure, then run the checks")
    i.add_argument("--dry-run", action="store_true", help="show what would change without changing anything")
    i.add_argument("--git-name", default="", help="git user.name if not set (otherwise asks)")
    i.add_argument("--git-email", default="", help="git user.email if not set (otherwise asks)")
    i.add_argument("--skip-optional-extensions", action="store_true", help="don't install optional VS Code extensions")
    a = ap.parse_args()

    cfg = config.load(a.config)
    if a.cmd == "check":
        results = checks.status(cfg)
        if a.json:
            print(json.dumps([r.as_dict() for r in results], indent=2))
            sys.exit(1 if any(r.status == "Fail" for r in results) else 0)
        sys.exit(print_report(results))

    Installer(cfg, a.dry_run, a.git_name, a.git_email, a.skip_optional_extensions).run()
    if not a.dry_run:
        print("==> Verifying")
        sys.exit(print_report(checks.status(cfg)))


if __name__ == "__main__":
    main()
