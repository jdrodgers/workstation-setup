"""Check and set up a workstation (Windows, macOS or Linux) for the VS Code + GitHub + Claude Code workflow.

Run from the repo root:
    python -m workstation check            # read-only report
    python -m workstation install --dry-run
    python -m workstation install

Standard library only, Python 3.9+, so it runs on the Python that ships with macOS
Command Line Tools as well as a fresh python.org / winget install.
"""
