#!/bin/bash
# Install Matt's Mac utilities on another Mac (shared mode).
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/mattdanielmurphy/mac-utilities/main/install.sh)
#
# Installs Hammerspoon if missing, clones mac-utilities into ~/.hammerspoon
# (an existing one is moved to ~/.hammerspoon.bak-<date>), turns on shared mode,
# then opens the Accessibility settings, the one step macOS makes you click.
set -euo pipefail

REPO="${SUITE_REPO:-https://github.com/mattdanielmurphy/mac-utilities.git}"
DEST="$HOME/.hammerspoon"

if [ ! -d /Applications/Hammerspoon.app ]; then
  if command -v brew >/dev/null; then
    echo "Installing Hammerspoon with Homebrew…"
    brew install --cask hammerspoon
  else
    echo "Installing Hammerspoon from GitHub…"
    tmp=$(mktemp -d)
    url=$(curl -fsSL https://api.github.com/repos/Hammerspoon/hammerspoon/releases/latest \
      | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)
    curl -fsSL "$url" -o "$tmp/hs.zip"
    ditto -x -k "$tmp/hs.zip" /Applications/
  fi
fi

if [ -d "$DEST/.git" ] && git -C "$DEST" remote get-url origin 2>/dev/null | grep -q mac-utilities; then
  echo "Already installed; updating…"
  git -C "$DEST" pull --ff-only --quiet origin main
else
  if [ -e "$DEST" ]; then
    backup="$DEST.bak-$(date +%Y%m%d-%H%M%S)"
    echo "Moving your existing ~/.hammerspoon to $backup"
    mv "$DEST" "$backup"
  fi
  git clone --quiet --branch main "$REPO" "$DEST"
fi

echo shared > "$DEST/profile"
echo "✓ Installed. Every utility starts off: turn them on from the ⚙︎ menu bar icon."

if [ -z "${SUITE_NO_OPEN:-}" ]; then
  open -a Hammerspoon
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  echo "→ In the window that opened, switch on Hammerspoon (Accessibility)."
fi
