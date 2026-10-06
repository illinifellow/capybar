/// Do Not Disturb on the keyboard's moon key: the key is remapped to F6 (`keymap.swift`), caught
/// as a global hotkey and answered by running the Shortcuts shortcut FOCUS_SHORTCUT_NAME, whose
/// single action toggles Do Not Disturb (Focus has no public API to switch it).
import AppKit
import Carbon

private let FOCUS_SHORTCUT_NAME = "Toggle Do Not Disturb"
private let FOCUS_KEY_CODE = UInt32(kVK_F6)
private let SHORTCUTS_PATH = "/usr/bin/shortcuts"

/// Runs the toggle shortcut without waiting for it; a non-zero exit (the shortcut missing, for
/// one) is logged.
private func toggleDoNotDisturb() {
    launchCommand(SHORTCUTS_PATH, ["run", FOCUS_SHORTCUT_NAME]) { status in
        if status != 0 { logFailure("shortcut \"\(FOCUS_SHORTCUT_NAME)\" failed: exit \(status)") }
    }
}

/// Registers F6 (the remapped moon key) to toggle Do Not Disturb.
@MainActor func startFocusKey() {
    registerGlobalHotkey(.doNotDisturb, keyCode: FOCUS_KEY_CODE, modifiers: 0) { toggleDoNotDisturb() }
}
