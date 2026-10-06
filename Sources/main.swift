/// capybar: one menu bar program with five items, left to right: CPU and RAM, network,
/// ping, capybara, microphone. The item created first sits rightmost. It also owns the screenshot hotkeys
/// Cmd+\ (toolbar, to clipboard) and Cmd+Shift+\ (toolbar, to Preview), and keeps Cmd and Ctrl
/// shortcuts Latin in iTerm2 on any keyboard layout, and offers its own update when a newer release
/// exists. Installed by install.sh as the launchd agent `com.illinifellow.capybar`.
/// `capybar --focus-claude-code` does what a click on the capybara does, then exits.
import AppKit

if CommandLine.arguments.dropFirst().first == "--focus-claude-code" {
    focusClaudeCode()
    exit(0)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
startMicrophone()
startCapybara()
startPing()
startNetwork()
startSystemLoad()
startScreenshotHotkeys()
remapSpecialKeys()
startFocusKey()
Updater.start()
application.run()
