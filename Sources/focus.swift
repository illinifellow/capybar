/// Do Not Disturb on the keyboard's moon key: the key (HID generic desktop usage 0x9B) is
/// remapped to F6 by `remapSpecialKeys`, caught as a global hotkey and answered by running the
/// Shortcuts shortcut FOCUS_SHORTCUT_NAME, whose single action toggles Do Not Disturb (Focus
/// has no public API to switch it).
import AppKit
import Carbon

private let FOCUS_SHORTCUT_NAME = "Toggle Do Not Disturb"
private let FOCUS_HOTKEY_IDENTIFIER: UInt32 = 11

/// Runs the toggle shortcut without waiting for it; a failure to start is printed to stderr.
private func toggleDoNotDisturb() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = ["run", FOCUS_SHORTCUT_NAME]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        FileHandle.standardError.write("do not disturb toggle failed to start: \(error)\n".data(using: .utf8)!)
    }
}

/// Registers F6 (the remapped moon key) to toggle Do Not Disturb.
func startFocusKey() {
    registerGlobalHotkey(keyCode: UInt32(kVK_F6), modifiers: 0, identifier: FOCUS_HOTKEY_IDENTIFIER) { toggleDoNotDisturb() }
}
