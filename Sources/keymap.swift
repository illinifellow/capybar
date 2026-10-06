/// The keyboard's microphone and moon keys remapped to F5 and F6 through `hidutil`'s user key
/// mapping (Apple TN2450), so macOS keeps Dictation and Focus off them and capybar's hotkeys
/// receive them. The two entries are merged into whatever mapping the user already keeps and
/// taken out again on Quit, logout and uninstall; a mapping capybar cannot read is left alone.
import Foundation

private let HIDUTIL_PATH = "/usr/bin/hidutil"
private let USER_KEY_MAPPING = "UserKeyMapping"
private let SOURCE_FIELD = "HIDKeyboardModifierMappingSrc"
private let DESTINATION_FIELD = "HIDKeyboardModifierMappingDst"
/// What `hidutil property --get` prints for a property that is not set.
private let UNSET_PROPERTY_OUTPUT = "(null)"

/// One entry of the user key mapping: a HID usage (page << 32 | usage) and what it becomes.
struct KeyMapping: Equatable, Sendable {
    var source: UInt64
    var destination: UInt64
}

/// capybar's entries: the microphone key (consumer page 0x0C, usage 0xCF, dictation) to F5
/// (keyboard page 0x07, usage 0x3E) and the moon key (generic desktop page 0x01, usage 0x9B,
/// do not disturb) to F6 (usage 0x3F).
let SPECIAL_KEY_REMAPS = [
    KeyMapping(source: 0xC_0000_00CF, destination: 0x7_0000_003E),
    KeyMapping(source: 0x1_0000_009B, destination: 0x7_0000_003F),
]

/// Reads the user key mapping as `hidutil property --get UserKeyMapping` prints it (an OpenStep
/// property list, or "(null)" when unset).
/// @param output The command's output. @returns The entries; nil when the output cannot be read.
func parseKeyMappings(_ output: String) -> [KeyMapping]? {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if text == UNSET_PROPERTY_OUTPUT { return [] }
    guard let data = text.data(using: .utf8),
          let entries = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] else { return nil }
    var mappings: [KeyMapping] = []
    for entry in entries {
        guard let source = entry[SOURCE_FIELD].flatMap({ UInt64("\($0)") }),
              let destination = entry[DESTINATION_FIELD].flatMap({ UInt64("\($0)") }) else { return nil }
        mappings.append(KeyMapping(source: source, destination: destination))
    }
    return mappings
}

/// Adds remaps to a mapping; an entry of the user's for one of the same keys gives way, since
/// capybar must receive those keys.
/// @param remaps Entries to add. @param existing The current mapping. @returns The merged mapping, the user's entries first.
func mergingRemaps(_ remaps: [KeyMapping], into existing: [KeyMapping]) -> [KeyMapping] {
    existing.filter { entry in !remaps.contains { $0.source == entry.source } } + remaps
}

/// Takes remaps out of a mapping, leaving every other entry as it was.
/// @param remaps Entries to remove, matched exactly. @param existing The current mapping. @returns The rest.
func removingRemaps(_ remaps: [KeyMapping], from existing: [KeyMapping]) -> [KeyMapping] {
    existing.filter { !remaps.contains($0) }
}

/// Writes a mapping in the JSON form `hidutil property --set` takes.
/// @param mappings The entries. @returns `{"UserKeyMapping":[{…},…]}`.
func keyMappingArgument(_ mappings: [KeyMapping]) -> String {
    let entries = mappings.map { "{\"\(SOURCE_FIELD)\":\($0.source),\"\(DESTINATION_FIELD)\":\($0.destination)}" }
    return "{\"\(USER_KEY_MAPPING)\":[\(entries.joined(separator: ","))]}"
}

/// Reads the mapping, transforms it and writes it back when it changed; any failure is logged
/// and leaves the mapping untouched.
/// @param transform Turns the current mapping into the wanted one.
private func updateUserKeyMapping(_ transform: ([KeyMapping]) -> [KeyMapping]) {
    let current = runCommand(HIDUTIL_PATH, ["property", "--get", USER_KEY_MAPPING])
    guard current.succeeded, let existing = parseKeyMappings(current.output) else {
        return logFailure("hidutil key mapping unreadable, left unchanged: exit \(current.status), \(current.output)")
    }
    let wanted = transform(existing)
    guard wanted != existing else { return }
    let result = runCommand(HIDUTIL_PATH, ["property", "--set", keyMappingArgument(wanted)])
    if !result.succeeded { logFailure("hidutil key mapping not set: exit \(result.status), \(result.output)") }
}

/// Merges SPECIAL_KEY_REMAPS into the user key mapping for this login session.
func applySpecialKeyRemaps() {
    updateUserKeyMapping { mergingRemaps(SPECIAL_KEY_REMAPS, into: $0) }
}

/// Takes SPECIAL_KEY_REMAPS out of the user key mapping, so the keys work as macOS intends again.
func removeSpecialKeyRemaps() {
    updateUserKeyMapping { removingRemaps(SPECIAL_KEY_REMAPS, from: $0) }
}
