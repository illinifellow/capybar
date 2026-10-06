#!/bin/bash
# Builds capybar into ~/.local/bin and registers it as a launchd agent that starts at login
# and restarts if it crashes (Quit stays quit until the next login). Run again after every
# change to rebuild and restart. capybar's updater runs a release's own copy of this script.
#
# Usage: install.sh [version]
#   version  refuse to install unless the build reports exactly this version (the updater
#            always passes the release it downloaded)
#
# The build goes to a temporary file beside the binary and replaces it only once it is built,
# signed and checked, so a failure leaves the installed capybar as it was.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
expected_version="${1:-}"
label="com.illinifellow.capybar"
binary="$HOME/.local/bin/capybar"
plist="$HOME/Library/LaunchAgents/$label.plist"
signing_identity_name="capybar local signing"
mkdir -p "$(dirname "$binary")" "$(dirname "$plist")"
built="$(mktemp "$(dirname "$binary")/.capybar-build.XXXXXX")"
staged_plist="$(mktemp "$(dirname "$plist")/.$label.XXXXXX")"
trap 'rm -f "$built" "$staged_plist"' EXIT
swiftc -O "$root"/Sources/*.swift -o "$built"
# macOS keeps privacy permissions (Screen Recording, Automation) only while the signature
# stays the same; an ad-hoc signature changes on every build. A code-signing identity named
# "capybar local signing" in the keychain, if present, gives every build the same one.
identity="$(security find-identity -v -p codesigning | awk -v name="\"$signing_identity_name\"" 'index($0, name) {print $2; exit}')"
if [ -n "$identity" ]; then
  codesign --force --sign "$identity" --identifier "$label" "$built"
fi
version="$("$built" --version)"
if [ -n "$expected_version" ] && [ "$version" != "$expected_version" ]; then
  echo "the source of $expected_version builds capybar $version; not installed" >&2
  exit 1
fi
cat > "$staged_plist" <<PLIST
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
</dict>
</plist>
PLIST
chmod 644 "$staged_plist"
mv -f "$built" "$binary"
mv -f "$staged_plist" "$plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# bootout returns before the job is gone; bootstrapping too early fails with "5: Input/output error".
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "capybar $version installed: $binary, agent $label"
