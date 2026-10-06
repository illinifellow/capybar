/// Which control of an input device capybar mutes through, and how the state reads from it. A
/// device may offer a mute switch, a volume, either on its main element or on each channel, and
/// any of them read-only; the one control chosen is used for reading and writing alike, so the
/// icon always reports what capybar can change.

/// What one element of an input device offers: the main element (0) or a channel (1…N).
struct InputElementControls: Equatable, Sendable {
    var element: UInt32
    var hasMute = false
    var muteSettable = false
    var hasVolume = false
    var volumeSettable = false
}

/// The control capybar mutes an input device through, with the elements it covers.
enum MicrophoneControl: Equatable, Sendable {
    /// The mute switch of every listed element.
    case mute(elements: [UInt32])
    /// The volume of every listed element, 0 meaning muted.
    case volume(elements: [UInt32])

    /// The elements the control covers.
    var elements: [UInt32] {
        switch self {
        case .mute(let elements), .volume(let elements): return elements
        }
    }
}

/// Chooses the control to mute through: a settable mute switch on the main element, else on
/// every channel, else a settable volume on the main element, else on every channel. A control
/// that exists but cannot be set is never chosen, not even for reading.
/// @param main The main element. @param channels The channel elements, possibly none.
/// @returns The control; nil when the device offers nothing capybar can set.
func chooseMicrophoneControl(main: InputElementControls, channels: [InputElementControls]) -> MicrophoneControl? {
    if main.hasMute && main.muteSettable { return .mute(elements: [main.element]) }
    if !channels.isEmpty && channels.allSatisfy({ $0.hasMute && $0.muteSettable }) { return .mute(elements: channels.map(\.element)) }
    if main.hasVolume && main.volumeSettable { return .volume(elements: [main.element]) }
    if !channels.isEmpty && channels.allSatisfy({ $0.hasVolume && $0.volumeSettable }) { return .volume(elements: channels.map(\.element)) }
    return nil
}

/// Whether readings of a control mean muted: every switch on, or every volume at 0.
/// @param control The control read. @param readings One value per element, in the control's order (a switch reads 0 or 1).
/// @returns True when muted; false when any element still lets sound through or nothing was read.
func isMuted(_ control: MicrophoneControl, readings: [Float32]) -> Bool {
    guard !readings.isEmpty else { return false }
    switch control {
    case .mute: return readings.allSatisfy { $0 != 0 }
    case .volume: return readings.allSatisfy { $0 == 0 }
    }
}

/// The volumes an unmute restores: the levels remembered when capybar muted the device, or the
/// fallback for every element when nothing usable was remembered.
/// @param remembered Levels saved at the last mute, one per element; nil when none.
/// @param elementCount Elements of the control now. @param fallback Level for an unknown element, above 0.
/// @returns One level per element.
func volumesToRestore(remembered: [Float32]?, elementCount: Int, fallback: Float32) -> [Float32] {
    guard let remembered, remembered.count == elementCount, remembered.contains(where: { $0 > 0 }) else {
        return [Float32](repeating: fallback, count: elementCount)
    }
    return remembered
}
