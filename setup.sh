#!/usr/bin/env sh
# macOS / Linux bootstrap: makes sure Git and Python 3.9+ are installed, then runs the
# Python setup (`python3 -m workstation <command>`) from this folder.
#
#   ./setup.sh                    # install (default)
#   ./setup.sh check              # read-only report
#   ./setup.sh install --dry-run  # show what would change; the bootstrap installs nothing either
#
# macOS: uses Homebrew if present, otherwise the Xcode Command Line Tools (which include
# git and python3). Linux: apt-get or dnf, with sudo. Nothing is downloaded and piped
# into a shell.
set -eu
cd "$(dirname "$0")"

[ "$#" -eq 0 ] && set -- install
dry_run=0
for a in "$@"; do [ "$a" = "--dry-run" ] && dry_run=1; done
[ "$1" = "check" ] && dry_run=1

# True when python3 exists and is 3.9 or newer. On macOS without the Command Line Tools,
# /usr/bin/python3 is a stub that fails here (and may offer to install them).
have_python() {
  command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1
}

need=""
command -v git >/dev/null 2>&1 || need="$need git"
have_python || need="$need python3"

if [ -n "$need" ]; then
  if [ "$dry_run" -eq 1 ]; then
    echo "    would install:$need"
    have_python || { echo "    (the Python setup runs once Python is installed)"; exit 0; }
  else
    case "$(uname -s)" in
      Darwin)
        if command -v brew >/dev/null 2>&1; then
          pkgs=$(echo "$need" | sed 's/python3/python/')  # Homebrew calls it "python"
          # shellcheck disable=SC2086  # word splitting of the package list is intended
          brew install $pkgs
        else
          echo "==> Installing the Xcode Command Line Tools (git, python3). Finish the dialog, then re-run ./setup.sh"
          xcode-select --install || true
          exit 1
        fi
        ;;
      Linux)
        if command -v apt-get >/dev/null 2>&1; then
          sudo apt-get update
          # shellcheck disable=SC2086
          sudo apt-get install -y $need
        elif command -v dnf >/dev/null 2>&1; then
          # shellcheck disable=SC2086
          sudo dnf install -y $need
        else
          echo "Install$need with your package manager, then re-run ./setup.sh" >&2
          exit 1
        fi
        ;;
      *)
        echo "Unsupported system $(uname -s); on Windows run .\\setup.ps1" >&2
        exit 1
        ;;
    esac
  fi
fi

exec python3 -m workstation "$@"
