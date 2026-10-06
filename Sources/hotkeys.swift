/// Global screenshot hotkeys: Cmd+\ and Cmd+Shift+\ open the macOS screenshot toolbar
/// (`screencapture -iU`) starting on area selection; the first sends the capture to the
/// clipboard, the second saves it to the per-user temporary directory (which macOS clears) and
/// opens it in Preview. The system's own screenshot shortcuts must not claim the same keys.
/// screencapture runs as capybar's child, so capybar needs the Screen Recording permission;
/// without it macOS returns captures that hold only the wallpaper.
import AppKit
import Carbon

private let SCREENSHOT_KEY_CODE = UInt32(kVK_ANSI_Backslash)
private let SCREENCAPTURE_PATH = "/usr/sbin/screencapture"
private let SCREENCAPTURE_INTERACTIVE_ARGUMENTS = ["-iU", "-Jselection"]

/// Runs screencapture with the arguments of one hotkey, without waiting for it.
/// @param hotkey `.screenshotToClipboard` or `.screenshotToPreview`.
private func runScreenshot(_ hotkey: Hotkey) {
    let destination: [String]
    if hotkey == .screenshotToPreview {
        let name = "capybar screenshot \(ISO8601DateFormatter().string(from: Date())).png"
        destination = ["-P", FileManager.default.temporaryDirectory.appendingPathComponent(name).path]
    } else {
        destination = ["-c"]
    }
    launchCommand(SCREENCAPTURE_PATH, SCREENCAPTURE_INTERACTIVE_ARGUMENTS + destination)
}

/// Registers both screenshot hotkeys and asks for Screen Recording if capybar lacks it (macOS
/// adds capybar to the list and shows its own request the first time).
@MainActor func startScreenshotHotkeys() {
    if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    registerGlobalHotkey(.screenshotToClipboard, keyCode: SCREENSHOT_KEY_CODE, modifiers: UInt32(cmdKey)) { runScreenshot(.screenshotToClipboard) }
    registerGlobalHotkey(.screenshotToPreview, keyCode: SCREENSHOT_KEY_CODE, modifiers: UInt32(cmdKey | shiftKey)) { runScreenshot(.screenshotToPreview) }
}
