#!/bin/bash
# Stops capybar and removes everything it keeps: the launchd agent, the binary, the key
# remaps, its preferences (status item positions, remembered microphone levels) and the files
# older versions left (the log and the screenshot cache).
set -euo pipefail
label="com.illinifellow.capybar"
binary="$HOME/.local/bin/capybar"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
if [ -x "$binary" ]; then
  "$binary" --remove-key-remaps
fi
defaults delete capybar 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$binary" "$HOME/Library/Logs/capybar.log"
rm -rf "$HOME/Library/Caches/capybar"
echo "capybar removed"
