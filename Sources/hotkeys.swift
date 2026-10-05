/// Global screenshot hotkeys: Cmd+\ and Cmd+Shift+\ open the macOS screenshot toolbar
/// (`screencapture -iU`) starting on area selection; the first sends the capture to the
/// clipboard, the second opens it in Preview. Registered through Carbon `RegisterEventHotKey`,
/// so the system's own screenshot shortcuts must not claim the same keys. screencapture runs
/// as capybar's child, so capybar needs the Screen Recording permission; without it macOS returns
/// captures that hold only the wallpaper.
import AppKit
import Carbon

private let BACKSLASH_KEY_CODE = UInt32(kVK_ANSI_Backslash)
private let CAPTURE_DIRECTORY = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/capybar")

/// One registered hotkey and the screencapture arguments it runs.
private struct ScreenshotHotkey {
    let identifier: UInt32
    let modifiers: UInt32
    let arguments: () -> [String]
}

private let SCREENSHOT_HOTKEYS: [ScreenshotHotkey] = [
    ScreenshotHotkey(identifier: 1, modifiers: UInt32(cmdKey), arguments: { ["-iU", "-Jselection", "-c"] }),
    ScreenshotHotkey(identifier: 2, modifiers: UInt32(cmdKey | shiftKey), arguments: {
        try? FileManager.default.createDirectory(at: CAPTURE_DIRECTORY, withIntermediateDirectories: true)
        let name = "Screenshot \(ISO8601DateFormatter().string(from: Date())).png"
        return ["-iU", "-Jselection", "-P", CAPTURE_DIRECTORY.appendingPathComponent(name).path]
    }),
]

/// Runs /usr/sbin/screencapture with the hotkey's arguments, without waiting for it; a failure
/// to start is printed to stderr.
/// @param identifier The pressed hotkey's identifier from SCREENSHOT_HOTKEYS.
private func runScreenshot(_ identifier: UInt32) {
    guard let hotkey = SCREENSHOT_HOTKEYS.first(where: { $0.identifier == identifier }) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = hotkey.arguments()
    do { try process.run() } catch {
        FileHandle.standardError.write("screencapture failed to start: \(error)\n".data(using: .utf8)!)
    }
}

/// Registers every screenshot hotkey and asks for Screen Recording if capybar lacks it (macOS
/// adds capybar to the list and shows its own request).
func startScreenshotHotkeys() {
    if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    for hotkey in SCREENSHOT_HOTKEYS {
        registerGlobalHotkey(keyCode: BACKSLASH_KEY_CODE, modifiers: hotkey.modifiers, identifier: hotkey.identifier) { runScreenshot(hotkey.identifier) }
    }
}
