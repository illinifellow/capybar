#!/bin/bash
# Stops capybar and removes its launchd agent and binary.
set -euo pipefail
label="com.illinifellow.capybar"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/capybar"
echo "capybar removed"
