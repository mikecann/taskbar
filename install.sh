#!/usr/bin/env bash
# Install the launcher only. setup_mac.sh builds; restart.sh stages the app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$HOME/.local/bin}"

case "${1:-}" in
  -h|--help)
    echo "Usage: install.sh [target_bin_dir]"
    echo "Default: ~/.local/bin. Run setup_mac.sh to build, then taskbar restart."
    exit 0
    ;;
  -*)
    echo "Unknown option: $1 (try --help)" >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "Usage: install.sh [target_bin_dir]" >&2
  exit 2
fi

mkdir -p "$TARGET_DIR"
DEST="$TARGET_DIR/taskbar"
if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
  echo "Refusing to replace existing file or directory: $DEST" >&2
  exit 1
fi
chmod +x "$SCRIPT_DIR/taskbar"
ln -sfn "$SCRIPT_DIR/taskbar" "$DEST"
echo "Installed $DEST -> $SCRIPT_DIR/taskbar"
echo "Add $TARGET_DIR to PATH if needed, then run bash $SCRIPT_DIR/setup_mac.sh."
echo "Start the app with taskbar restart. Re-run install.sh after moving the clone."
