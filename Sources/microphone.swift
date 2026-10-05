/// Microphone item: shows whether the default input device is muted. Only the keyboard's
/// microphone key changes that state; anything else that flips it (an app, the system, a new
/// default input device) is put back at once to the state the key last chose, kept in
/// UserDefaults under MICROPHONE_MUTED_KEY. capybar starting (login, restart), the Mac waking
/// and the session being unlocked always mute it; nothing but the key unmutes it. That key (HID consumer usage 0xCF, dictation) is
/// remapped to F5 with `hidutil` at start, so macOS no longer offers Dictation, and F5 is
/// caught as a global hotkey. Muting uses the device's own mute property; a device without
/// one is muted by setting its input volume to 0 and restoring the previous level.
import AppKit
import Carbon
import CoreAudio

private let MICROPHONE_HOTKEY_IDENTIFIER: UInt32 = 10

private var microphoneItem: NSStatusItem?
private var volumeBeforeMute: Float32 = 0.75
private let MICROPHONE_MUTED_KEY = "microphoneMuted"

/// The state the microphone key last chose.
private var wantedMuted: Bool {
    get { UserDefaults.standard.bool(forKey: MICROPHONE_MUTED_KEY) }
    set { UserDefaults.standard.set(newValue, forKey: MICROPHONE_MUTED_KEY) }
}

/// The current default input device. @returns Its id, or nil when there is none.
private func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != 0 ? device : nil
}

private func inputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
}

/// Whether the default input device is muted (mute property, or volume 0 without one).
/// @returns nil when there is no input device.
private func isMicrophoneMuted() -> Bool? {
    guard let device = defaultInputDevice() else { return nil }
    var muteAddress = inputAddress(kAudioDevicePropertyMute)
    if AudioObjectHasProperty(device, &muteAddress) {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr { return muted != 0 }
    }
    var volumeAddress = inputAddress(kAudioDevicePropertyVolumeScalar)
    var volume = Float32(1)
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr else { return false }
    return volume == 0
}

/// Mutes or unmutes the default input device; a failure is printed to stderr.
/// @param muted The wanted state.
private func setMicrophoneMuted(_ muted: Bool) {
    guard let device = defaultInputDevice() else { return }
    var muteAddress = inputAddress(kAudioDevicePropertyMute)
    var settable = DarwinBoolean(false)
    if AudioObjectHasProperty(device, &muteAddress), AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr, settable.boolValue {
        var value = UInt32(muted ? 1 : 0)
        let status = AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr { FileHandle.standardError.write("microphone mute failed: \(status)\n".data(using: .utf8)!) }
        return
    }
    var volumeAddress = inputAddress(kAudioDevicePropertyVolumeScalar)
    var size = UInt32(MemoryLayout<Float32>.size)
    if muted {
        var current = Float32(0)
        if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &current) == noErr, current > 0 { volumeBeforeMute = current }
    }
    var volume = muted ? Float32(0) : volumeBeforeMute
    let status = AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &volume)
    if status != noErr { FileHandle.standardError.write("microphone volume failed: \(status)\n".data(using: .utf8)!) }
}

private let MICROPHONE_ICON_SIZE = NSSize(width: 18, height: 18)
private let MICROPHONE_SYMBOL = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
private var lastDrawnMuted: Bool?

/// Draws a microphone symbol centred on a fixed MICROPHONE_ICON_SIZE canvas, so the muted and
/// unmuted icons occupy the same box and the item never changes width.
/// @param muted Draws `mic.slash.fill` in red when true, `mic.fill` in the label colour otherwise.
/// @returns The image; a template image when unmuted so it follows the menu bar appearance.
private func makeMicrophoneImage(muted: Bool) -> NSImage {
    let symbol = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill", accessibilityDescription: muted ? "Microphone muted" : "Microphone on")?
        .withSymbolConfiguration(muted ? MICROPHONE_SYMBOL.applying(.init(paletteColors: [.systemRed])) : MICROPHONE_SYMBOL)
    let image = NSImage(size: MICROPHONE_ICON_SIZE, flipped: false) { rect in
        guard let symbol else { return false }
        let origin = NSPoint(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2)
        symbol.draw(in: NSRect(origin: origin, size: symbol.size))
        return true
    }
    image.isTemplate = !muted
    return image
}

/// Redraws the item when the state changed: a microphone, crossed out and red when muted.
private func refreshMicrophoneItem() {
    let muted = isMicrophoneMuted() ?? true
    guard muted != lastDrawnMuted, let button = microphoneItem?.button else { return }
    lastDrawnMuted = muted
    button.image = makeMicrophoneImage(muted: muted)
}

/// Flips the wanted state from the microphone key, applies it and redraws the item.
private func toggleMicrophoneFromKey() {
    wantedMuted = !wantedMuted
    enforceWantedMicrophoneState()
}

/// Puts the device back to the wanted state if anything changed it, then redraws the item.
private func enforceWantedMicrophoneState() {
    if let muted = isMicrophoneMuted(), muted != wantedMuted { setMicrophoneMuted(wantedMuted) }
    refreshMicrophoneItem()
}

/// Adds the microphone item, mutes the microphone (also on every wake and unlock), remaps the
/// microphone key, registers F5 and keeps the device on the wanted state every second and on
/// device changes.
func startMicrophone() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.menu = makeQuitMenu(header: "Only the microphone key (F5) mutes and unmutes")
    // A fixed autosave name gives the item its own remembered position, kept beside the system
    // Sound item at the left edge of the Control Center group.
    item.autosaveName = "capybarMicrophone"
    microphoneItem = item
    wantedMuted = true
    enforceWantedMicrophoneState()
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
        workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
            wantedMuted = true
            enforceWantedMicrophoneState()
        }
    }
    DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
        wantedMuted = true
        enforceWantedMicrophoneState()
    }
    refreshMicrophoneItem()
    // Each press toggles the microphone. Key repeat sends further presses while the key is
    // held; only the first one counts until the key is released.
    var held = false
    registerGlobalHotkey(keyCode: UInt32(kVK_F5), modifiers: 0, identifier: MICROPHONE_HOTKEY_IDENTIFIER, onRelease: { held = false }) {
        guard !held else { return }
        held = true
        toggleMicrophoneFromKey()
    }
    var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main) { _, _ in enforceWantedMicrophoneState() }
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in enforceWantedMicrophoneState() }
}
