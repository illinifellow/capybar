/// Camera item and the call video toggle. The item shows whether any camera is capturing for any
/// application (CoreMediaIO's running-somewhere flag of every video device, watched through
/// property listeners): `video.fill` while one is, a red `video.slash.fill` otherwise.
///
/// macOS offers no way to switch a camera off for other applications (its camera daemons are
/// SIP-protected and launchd restarts them at once), so holding the microphone key turns video on
/// or off in the call itself: capybar finds the call application capturing from a microphone
/// (CoreAudio process objects), brings it forward, presses its own video shortcut
/// (CALL_APPLICATIONS) and returns to the application that was in front. A call in Chrome is
/// Google Meet, whose tab is selected first through AppleScript. Pressing keys in another
/// application needs the Accessibility permission, asked for at start.
import AppKit
import Carbon
import CoreAudio
import CoreMediaIO

private let CAMERA_AUTOSAVE_NAME = "capybarCamera"
private let CAMERA_ICON_SIZE = NSSize(width: 22, height: 18)
@MainActor private let CAMERA_SYMBOL = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
/// Seconds between bringing the call forward and pressing its shortcut, and between the press and returning.
private let ACTIVATION_DELAY: TimeInterval = 0.15
private let OSASCRIPT_PATH = "/usr/bin/osascript"

/// A call application and the shortcut that turns its video on or off.
struct CallApplication: Equatable, Sendable {
    var bundleIdentifier: String
    var keyCode: CGKeyCode
    var modifiers: CGEventFlags
    /// For a browser: the address the call's tab starts with, selected before the press.
    var tabAddressPrefix: String? = nil
}

/// The call applications capybar knows, in the order one is chosen when several capture at once.
let CALL_APPLICATIONS = [
    CallApplication(bundleIdentifier: "us.zoom.xos", keyCode: CGKeyCode(kVK_ANSI_V), modifiers: [.maskCommand, .maskShift]),
    CallApplication(bundleIdentifier: "com.microsoft.teams2", keyCode: CGKeyCode(kVK_ANSI_O), modifiers: [.maskCommand, .maskShift]),
    CallApplication(bundleIdentifier: "com.tinyspeck.slackmacgap", keyCode: CGKeyCode(kVK_ANSI_V), modifiers: [.maskCommand, .maskShift]),
    CallApplication(bundleIdentifier: "com.google.Chrome", keyCode: CGKeyCode(kVK_ANSI_E), modifiers: [.maskCommand],
                    tabAddressPrefix: "https://meet.google.com/"),
]

/// Picks the call application among the processes capturing from a microphone; a helper process
/// ("com.google.Chrome.helper") counts as its application.
/// @param capturing Bundle identifiers of the processes capturing audio input.
/// @param known The call applications, in order of preference.
/// @returns The first known application capturing; nil when none is.
func callApplication(capturing: [String], among known: [CallApplication]) -> CallApplication? {
    known.first { call in capturing.contains { $0 == call.bundleIdentifier || $0.hasPrefix(call.bundleIdentifier + ".") } }
}

/// A property address on the CoreAudio system object or a process object.
private func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

/// Bundle identifiers of the processes capturing audio input now.
/// @returns The identifiers; empty when CoreAudio cannot list its processes.
private func bundleIdentifiersCapturingAudio() -> [String] {
    var listAddress = audioAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr else { return [] }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes) == noErr else { return [] }
    return processes.compactMap { process in
        var runningAddress = audioAddress(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0, runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { return nil }
        var identifierAddress = audioAddress(kAudioProcessPropertyBundleID)
        var identifier: Unmanaged<CFString>?
        var identifierSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &identifierAddress, 0, nil, &identifierSize, &identifier) == noErr else { return nil }
        return identifier?.takeRetainedValue() as String?
    }
}

/// Selects the call's tab in the browser and raises its window, through `osascript`.
/// @param call A browser call application with `tabAddressPrefix`. @returns Whether a tab was found and selected.
private func selectCallTab(_ call: CallApplication) -> Bool {
    guard let prefix = call.tabAddressPrefix else { return true }
    let result = runCommand(OSASCRIPT_PATH, ["-e", """
        tell application id \(appleScriptStringLiteral(call.bundleIdentifier))
            repeat with candidateWindow in windows
                set tabIndex to 0
                repeat with candidateTab in tabs of candidateWindow
                    set tabIndex to tabIndex + 1
                    if URL of candidateTab starts with \(appleScriptStringLiteral(prefix)) then
                        set active tab index of candidateWindow to tabIndex
                        set index of candidateWindow to 1
                        return "selected"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """], includeErrors: true)
    guard result.succeeded else {
        logFailure("call tab not selected in \(call.bundleIdentifier): exit \(result.status), \(result.output)")
        return false
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "selected"
}

/// Presses a shortcut in the frontmost application through the HID event tap.
/// @param keyCode Virtual key code. @param modifiers Modifier flags held for the press.
private func pressShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    for keyDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return logFailure("key event \(keyCode) not created")
        }
        event.flags = modifiers
        event.post(tap: .cghidEventTap)
    }
}

@MainActor private var callVideoToggleInFlight = false

/// Turns video on or off in the call capturing from a microphone; with no known call, or without
/// the Accessibility permission, logs why and does nothing.
@MainActor func toggleCallVideo() {
    guard !callVideoToggleInFlight else { return }
    guard AXIsProcessTrusted() else { return logFailure("call video not toggled: capybar lacks the Accessibility permission") }
    let capturing = bundleIdentifiersCapturingAudio()
    guard let call = callApplication(capturing: capturing, among: CALL_APPLICATIONS),
          let application = NSRunningApplication.runningApplications(withBundleIdentifier: call.bundleIdentifier).first else {
        return logFailure("call video not toggled: no known call application captures audio (capturing: \(capturing.joined(separator: ", ")))")
    }
    callVideoToggleInFlight = true
    let previous = NSWorkspace.shared.frontmostApplication
    DispatchQueue.global(qos: .userInitiated).async {
        let tabSelected = selectCallTab(call)
        performOnMain {
            guard tabSelected else {
                callVideoToggleInFlight = false
                return logFailure("call video not toggled: no tab at \(call.tabAddressPrefix ?? "") in \(call.bundleIdentifier)")
            }
            application.activate()
            runAfter(ACTIVATION_DELAY) {
                pressShortcut(keyCode: call.keyCode, modifiers: call.modifiers)
                runAfter(ACTIVATION_DELAY) {
                    if let previous, previous != application { previous.activate() }
                    callVideoToggleInFlight = false
                }
            }
        }
    }
}

/// A property address on the CoreMediaIO system object or a device.
private func cameraAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

/// Every video device CoreMediaIO knows. @returns Their ids; empty when the list cannot be read.
private func cameraDevices() -> [CMIOObjectID] {
    var listAddress = cameraAddress(kCMIOHardwarePropertyDevices)
    var size: UInt32 = 0, used: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &listAddress, 0, nil, &size) == noErr else { return [] }
    var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &listAddress, 0, nil, size, &used, &devices) == noErr else { return [] }
    return devices
}

/// Whether some application captures from the device. @returns False when unknown.
private func isCameraRunning(_ device: CMIOObjectID) -> Bool {
    var runningAddress = cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
    var running: UInt32 = 0, used: UInt32 = 0
    return CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr && running != 0
}

/// Watches every camera's running state and the device list, and draws the item.
@MainActor private final class CameraWatcher {
    private let item: NSStatusItem
    private var watchedDevices: [CMIOObjectID] = []
    private var shownRunning: Bool?
    private lazy var listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        // Registered on the main queue.
        MainActor.assumeIsolated { self?.show() }
    }

    init(item: NSStatusItem) {
        self.item = item
        var listAddress = cameraAddress(kCMIOHardwarePropertyDevices)
        let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &listAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followDevices() }
        }
        if status != noErr { logFailure("camera list listener not added: \(status)") }
        followDevices()
    }

    /// Moves the listeners to the current device list and redraws the item.
    func followDevices() {
        for device in watchedDevices {
            var runningAddress = cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            let status = CMIOObjectRemovePropertyListenerBlock(device, &runningAddress, .main, listener)
            if status != noErr { logFailure("camera listener not removed from device \(device): \(status)") }
        }
        watchedDevices = []
        for device in cameraDevices() {
            var runningAddress = cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            let status = CMIOObjectAddPropertyListenerBlock(device, &runningAddress, .main, listener)
            if status == noErr { watchedDevices.append(device) } else { logFailure("camera listener not added on device \(device): \(status)") }
        }
        show()
    }

    /// Draws the item when whether a camera runs changed.
    func show() {
        let running = watchedDevices.contains(where: isCameraRunning)
        guard running != shownRunning, let button = item.button else { return }
        shownRunning = running
        button.image = makeCameraImage(running: running)
    }
}

/// Draws a camera symbol centred on a fixed CAMERA_ICON_SIZE canvas, so both icons occupy the
/// same box and the item never changes width.
/// @param running Draws `video.fill` in the label colour when true, `video.slash.fill` in red otherwise.
/// @returns The image; a template image when running so it follows the menu bar appearance.
@MainActor private func makeCameraImage(running: Bool) -> NSImage {
    let symbol = NSImage(systemSymbolName: running ? "video.fill" : "video.slash.fill", accessibilityDescription: running ? "Camera on" : "Camera off")?
        .withSymbolConfiguration(running ? CAMERA_SYMBOL : CAMERA_SYMBOL.applying(.init(paletteColors: [.systemRed])))
    let image = NSImage(size: CAMERA_ICON_SIZE, flipped: false) { rect in
        guard let symbol else { return false }
        symbol.draw(in: NSRect(origin: NSPoint(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2), size: symbol.size))
        return true
    }
    image.isTemplate = running
    return image
}

@MainActor private var cameraWatcher: CameraWatcher?

/// Adds the camera item and asks for the Accessibility permission the call video toggle needs
/// (macOS adds capybar to the list and shows its own request the first time).
@MainActor func startCamera() {
    let item = NSStatusBar.system.statusItem(withLength: CAMERA_ICON_SIZE.width)
    item.menu = makeQuitMenu()
    item.autosaveName = CAMERA_AUTOSAVE_NAME
    cameraWatcher = CameraWatcher(item: item)
    if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }
}
