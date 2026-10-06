/// Microphone item: shows whether the default input device is muted. Only the keyboard's
/// microphone key changes that state; anything else that flips it (an app, the system, a new
/// default input device) is put back at once to the state the key last chose. capybar starting
/// and the Mac waking from sleep always mute it; unlocking the screen mutes it too, unless some
/// application is capturing from the device (a call that outlived the lock) and the key had
/// unmuted it. The key (consumer usage 0xCF, dictation) is remapped to F5 (`keymap.swift`), so
/// macOS no longer offers Dictation, and F5 is caught as a global hotkey.
///
/// Each device is muted through the one control `chooseMicrophoneControl` picks (a mute switch,
/// else the volume, on the main element or on every channel), read and written alike, and
/// watched through Core Audio property listeners. Muting through the volume remembers the
/// levels per device in UserDefaults and restores them on unmute.
import AppKit
import Carbon
import CoreAudio

private let MICROPHONE_KEY_CODE = UInt32(kVK_F5)
/// UserDefaults key of the levels saved when a device was muted through its volume: device UID → one level per element.
private let VOLUMES_BEFORE_MUTE_KEY = "microphoneVolumesBeforeMute"
/// The level an unmute gives an element whose own level before the mute is unknown.
private let FALLBACK_UNMUTED_VOLUME: Float32 = 0.75
private let MICROPHONE_AUTOSAVE_NAME = "capybarMicrophone"
private let MICROPHONE_ICON_SIZE = NSSize(width: 18, height: 18)
@MainActor private let MICROPHONE_SYMBOL = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
private let SCREEN_UNLOCKED_NOTIFICATION = NSNotification.Name("com.apple.screenIsUnlocked")

/// A property address on the system object or a device.
private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

/// Reads a fixed-size property value. @returns The value; nil when the read fails.
private func readProperty<Value: BitwiseCopyable>(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress, initial: Value) -> Value? {
    var propertyAddress = propertyAddress, value = initial
    var size = UInt32(MemoryLayout<Value>.size)
    return AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &value) == noErr ? value : nil
}

/// Writes a fixed-size property value. @returns The Core Audio status.
private func writeProperty<Value: BitwiseCopyable>(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress, _ value: Value) -> OSStatus {
    var propertyAddress = propertyAddress, value = value
    return AudioObjectSetPropertyData(object, &propertyAddress, 0, nil, UInt32(MemoryLayout<Value>.size), &value)
}

/// The current default input device. @returns Its id, or nil when there is none.
private func defaultInputDevice() -> AudioDeviceID? {
    let device = readProperty(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), initial: AudioDeviceID(0))
    return device == 0 ? nil : device
}

/// The device's persistent identifier. @returns The UID; nil when it cannot be read.
private func deviceUID(_ device: AudioDeviceID) -> String? {
    var propertyAddress = address(kAudioDevicePropertyDeviceUID)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &propertyAddress, 0, nil, &size, &uid) == noErr else { return nil }
    return uid?.takeRetainedValue() as String?
}

/// Counts the device's input channels from its input stream configuration. @returns The count, 0 when unknown.
private func inputChannelCount(_ device: AudioDeviceID) -> Int {
    var propertyAddress = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &propertyAddress, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(device, &propertyAddress, 0, nil, &size, storage) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}

/// Reads what one input element offers. @param device The device. @param element 0 for main, 1…N for channels.
private func inputElementControls(_ device: AudioDeviceID, element: UInt32) -> InputElementControls {
    func probe(_ selector: AudioObjectPropertySelector) -> (exists: Bool, settable: Bool) {
        var propertyAddress = address(selector, scope: kAudioDevicePropertyScopeInput, element: element)
        guard AudioObjectHasProperty(device, &propertyAddress) else { return (false, false) }
        var settable = DarwinBoolean(false)
        return (true, AudioObjectIsPropertySettable(device, &propertyAddress, &settable) == noErr && settable.boolValue)
    }
    let mute = probe(kAudioDevicePropertyMute), volume = probe(kAudioDevicePropertyVolumeScalar)
    return InputElementControls(element: element, hasMute: mute.exists, muteSettable: mute.settable, hasVolume: volume.exists, volumeSettable: volume.settable)
}

/// The property a control reads and writes on one element.
private func controlAddress(_ control: MicrophoneControl, element: UInt32) -> AudioObjectPropertyAddress {
    switch control {
    case .mute: return address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput, element: element)
    case .volume: return address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element)
    }
}

/// Reads a control on every element it covers: a mute switch as 0 or 1, a volume as 0...1.
/// @returns One reading per element that could be read.
private func readControl(_ control: MicrophoneControl, on device: AudioDeviceID) -> [Float32] {
    control.elements.compactMap { element in
        switch control {
        case .mute: return readProperty(device, controlAddress(control, element: element), initial: UInt32(0)).map { Float32($0) }
        case .volume: return readProperty(device, controlAddress(control, element: element), initial: Float32(0))
        }
    }
}

/// Writes a control on one element. @param value 0 or 1 for a mute switch, 0...1 for a volume. @returns The Core Audio status.
private func writeControl(_ control: MicrophoneControl, element: UInt32, value: Float32, on device: AudioDeviceID) -> OSStatus {
    switch control {
    case .mute: return writeProperty(device, controlAddress(control, element: element), UInt32(value))
    case .volume: return writeProperty(device, controlAddress(control, element: element), value)
    }
}

/// Whether any process is capturing from the device (a call, a recording). @returns False when unknown.
private func isInputInUse(_ device: AudioDeviceID) -> Bool {
    (readProperty(device, address(kAudioDevicePropertyDeviceIsRunningSomewhere), initial: UInt32(0)) ?? 0) != 0
}

/// What the item shows.
private enum MicrophoneIcon: Equatable {
    /// Muted, or no input device at all.
    case muted
    case live
    /// The device has no control capybar can set; the name is shown in the tooltip.
    case uncontrollable(deviceName: String)
}

/// Keeps the default input device on the state the key chose: finds the device's control,
/// listens for changes to it and to the default device, puts the state back and draws the item.
@MainActor private final class MicrophoneGuard {
    /// The state the microphone key last chose.
    var wantedMuted = true
    private let item: NSStatusItem
    private var device: AudioDeviceID?
    private var control: MicrophoneControl?
    private var watchedAddresses: [AudioObjectPropertyAddress] = []
    private var shownIcon: MicrophoneIcon?
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        // Registered on the main queue.
        MainActor.assumeIsolated { self?.enforce() }
    }

    init(item: NSStatusItem) {
        self.item = item
        var defaultAddress = address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followDefaultDevice() }
        }
        if status != noErr { logFailure("default input device listener not added: \(status)") }
        followDefaultDevice()
    }

    /// Moves the listeners to the current default input device and enforces the wanted state on it.
    func followDefaultDevice() {
        if let device {
            for var watched in watchedAddresses {
                let status = AudioObjectRemovePropertyListenerBlock(device, &watched, .main, listener)
                if status != noErr { logFailure("microphone listener not removed from \(deviceName(device)): \(status)") }
            }
        }
        watchedAddresses = []
        device = defaultInputDevice()
        control = device.flatMap { device in
            chooseMicrophoneControl(main: inputElementControls(device, element: kAudioObjectPropertyElementMain),
                                    channels: (0..<inputChannelCount(device)).map { inputElementControls(device, element: UInt32($0 + 1)) })
        }
        if let device, let control {
            for element in control.elements {
                var watched = controlAddress(control, element: element)
                let status = AudioObjectAddPropertyListenerBlock(device, &watched, .main, listener)
                if status == noErr { watchedAddresses.append(watched) } else { logFailure("microphone listener not added on \(deviceName(device)): \(status)") }
            }
        } else if let device {
            logFailureOnce(key: "uncontrollable \(deviceUID(device) ?? "\(device)")", "\(deviceName(device)) offers no mute or volume control capybar can set")
        }
        enforce()
    }

    /// Mutes now (start, wake from sleep).
    func mute() {
        wantedMuted = true
        enforce()
    }

    /// Mutes after an unlock, unless an application is capturing from the device and the key
    /// had unmuted it: that is a call in progress, and the key alone decides over it.
    func muteUnlessInUse() {
        if !wantedMuted, let device, isInputInUse(device) { return }
        mute()
    }

    /// Flips the wanted state from the microphone key and applies it.
    func toggle() {
        wantedMuted.toggle()
        enforce()
    }

    /// Puts the device back to the wanted state if anything changed it, then redraws the item.
    func enforce() {
        guard let device, let control else { return show(device.map { .uncontrollable(deviceName: deviceName($0)) } ?? .muted) }
        let readings = readControl(control, on: device)
        guard isMuted(control, readings: readings) != wantedMuted else { return show(wantedMuted ? .muted : .live) }
        apply(wantedMuted, through: control, on: device, current: readings)
        show(isMuted(control, readings: readControl(control, on: device)) ? .muted : .live)
    }

    /// Mutes or unmutes through the control; a failure is logged once per device and state.
    /// @param muted The wanted state. @param control The device's control. @param device The device. @param current The control's readings now.
    private func apply(_ muted: Bool, through control: MicrophoneControl, on device: AudioDeviceID, current: [Float32]) {
        let uid = deviceUID(device) ?? "\(device)"
        let values: [Float32]
        switch control {
        case .mute:
            values = [Float32](repeating: muted ? 1 : 0, count: control.elements.count)
        case .volume where muted:
            if current.contains(where: { $0 > 0 }) { rememberVolumes(current, for: uid) }
            values = [Float32](repeating: 0, count: control.elements.count)
        case .volume:
            values = volumesToRestore(remembered: rememberedVolumes(for: uid), elementCount: control.elements.count, fallback: FALLBACK_UNMUTED_VOLUME)
        }
        for (element, value) in zip(control.elements, values) {
            let status = writeControl(control, element: element, value: value, on: device)
            if status != noErr { logFailureOnce(key: "\(muted ? "mute" : "unmute") \(uid)", "microphone \(muted ? "mute" : "unmute") failed on \(deviceName(device)), element \(element): \(status)") }
        }
    }

    private func rememberedVolumes(for uid: String) -> [Float32]? {
        (UserDefaults.standard.dictionary(forKey: VOLUMES_BEFORE_MUTE_KEY)?[uid] as? [NSNumber])?.map(\.floatValue)
    }

    private func rememberVolumes(_ volumes: [Float32], for uid: String) {
        var stored = UserDefaults.standard.dictionary(forKey: VOLUMES_BEFORE_MUTE_KEY) ?? [:]
        stored[uid] = volumes
        UserDefaults.standard.set(stored, forKey: VOLUMES_BEFORE_MUTE_KEY)
    }

    /// Draws the item when what it shows changed.
    private func show(_ icon: MicrophoneIcon) {
        guard icon != shownIcon, let button = item.button else { return }
        shownIcon = icon
        button.image = makeMicrophoneImage(muted: icon == .muted)
        if case .uncontrollable(let name) = icon { button.toolTip = "\(name) offers no mute or volume control" } else { button.toolTip = nil }
    }
}

/// The device's name for messages. @returns The name, or its id when the name cannot be read.
private func deviceName(_ device: AudioDeviceID) -> String {
    var propertyAddress = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &propertyAddress, 0, nil, &size, &name) == noErr, let name else { return "device \(device)" }
    return name.takeRetainedValue() as String
}

/// Draws a microphone symbol centred on a fixed MICROPHONE_ICON_SIZE canvas, so the muted and
/// unmuted icons occupy the same box and the item never changes width.
/// @param muted Draws `mic.slash.fill` in red when true, `mic.fill` in the label colour otherwise.
/// @returns The image; a template image when unmuted so it follows the menu bar appearance.
@MainActor private func makeMicrophoneImage(muted: Bool) -> NSImage {
    let symbol = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill", accessibilityDescription: muted ? "Microphone muted" : "Microphone on")?
        .withSymbolConfiguration(muted ? MICROPHONE_SYMBOL.applying(.init(paletteColors: [.systemRed])) : MICROPHONE_SYMBOL)
    let image = NSImage(size: MICROPHONE_ICON_SIZE, flipped: false) { rect in
        guard let symbol else { return false }
        symbol.draw(in: NSRect(origin: NSPoint(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2), size: symbol.size))
        return true
    }
    image.isTemplate = !muted
    return image
}

@MainActor private var microphoneGuard: MicrophoneGuard?

/// Adds the microphone item, mutes the microphone (again on every wake from sleep, and on
/// unlock unless a call holds it), and registers F5 to toggle it.
@MainActor func startMicrophone() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.menu = makeQuitMenu()
    // A fixed autosave name gives the item its own remembered position, kept beside the system
    // Sound item at the left edge of the Control Center group.
    item.autosaveName = MICROPHONE_AUTOSAVE_NAME
    let guardian = MicrophoneGuard(item: item)
    microphoneGuard = guardian
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { guardian.mute() }
    }
    workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { guardian.muteUnlessInUse() }
    }
    DistributedNotificationCenter.default().addObserver(forName: SCREEN_UNLOCKED_NOTIFICATION, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { guardian.muteUnlessInUse() }
    }
    registerGlobalHotkey(.microphone, keyCode: MICROPHONE_KEY_CODE, modifiers: 0) { guardian.toggle() }
}
