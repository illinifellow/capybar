/// capybar: one menu bar program with five items, left to right: CPU and RAM, network,
/// ping, capybara, microphone. The item created first sits rightmost. It also owns the screenshot hotkeys
/// Cmd+\ (toolbar, to clipboard) and Cmd+Shift+\ (toolbar, to Preview), and keeps Cmd and Ctrl
/// shortcuts Latin in iTerm2 on any keyboard layout. Installed by install.sh as the launchd agent `com.illinifellow.capybar`.
/// `capybar --focus-claude-code` does what a click on the capybara does, then exits;
/// `capybar --hold-camera-key <seconds>` does to OBS what holding the microphone key that long
/// does (the microphone is left alone), then exits; `capybar --clear-camera-loop` does what a
/// double press during a loop does, then exits.
import AppKit

if CommandLine.arguments.dropFirst().first == "--focus-claude-code" {
    focusClaudeCode()
    exit(0)
}
if CommandLine.arguments.dropFirst().first == "--hold-camera-key", CommandLine.arguments.count == 3, let seconds = Double(CommandLine.arguments[2]) {
    MainActor.assumeIsolated { CameraLoopKey.shared.pressed() }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        MainActor.assumeIsolated { CameraLoopKey.shared.released(long: seconds >= LONG_PRESS_SECONDS) { exit(0) } }
    }
    dispatchMain()
}
if CommandLine.arguments.dropFirst().first == "--clear-camera-loop" {
    MainActor.assumeIsolated { CameraLoopKey.shared.clearLoop { exit(0) } }
    dispatchMain()
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
startObsOnDemand()
application.run()
