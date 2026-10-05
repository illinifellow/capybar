#!/bin/bash
# Builds capybar into ~/.local/bin and registers it as a launchd agent that starts at login
# and restarts if it crashes (Quit stays quit until the next login). Run again after every
# change to rebuild and restart.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
binary="$HOME/.local/bin/capybar"
label="com.illinifellow.capybar"
plist="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
swiftc -O "$root"/Sources/*.swift -o "$binary"
# macOS keeps privacy permissions (Screen Recording, Input Monitoring) only while the signature
# stays the same; an ad-hoc signature changes on every build. A code-signing identity named
# "capybar local signing" in the keychain, if present, gives every build the same one.
identity="$(security find-identity -v -p codesigning | awk '/"capybar local signing"/ {print $2; exit}')"
if [ -n "$identity" ]; then
  codesign --force --sign "$identity" --identifier com.illinifellow.capybar "$binary"
fi
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$binary</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/capybar.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# bootout returns before the job is gone; bootstrapping too early fails with "5: Input/output error".
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "capybar installed: $binary, agent $label"
