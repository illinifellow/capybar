/// Helpers shared by the menu bar items: the Quit menu, the menu bar's label colour, the
/// two stacked lines image and global hotkeys.
import AppKit
import Carbon

private let TWO_LINE_FONT = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

/// Builds an item menu: an optional disabled header line, then Quit (quits all items).
/// @param header Text of the first line; nil leaves only Quit.
/// @returns The menu.
func makeQuitMenu(header: String? = nil) -> NSMenu {
    let menu = NSMenu()
    if let header { menu.addItem(withTitle: header, action: nil, keyEquivalent: "") }
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    return menu
}

/// Resolves the label colour for the item's current appearance (light or dark menu bar).
/// @param item The status item whose appearance decides.
/// @returns An RGB colour, black when the item has no button.
func labelColor(of item: NSStatusItem) -> NSColor {
    var color = NSColor.black
    item.button?.effectiveAppearance.performAsCurrentDrawingAppearance {
        color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
    }
    return color
}

/// Renders two stacked lines, 22 pt high, as wide as `widest` so the item never changes width.
/// @param top Upper line. @param topCritical Draws the upper line red.
/// @param bottom Lower line. @param bottomCritical Draws the lower line red.
/// @param widest Longest text either line can hold. @param foreground Normal text colour.
/// @returns A non-template NSImage.
func makeTwoLineImage(top: String, topCritical: Bool = false, bottom: String, bottomCritical: Bool = false, widest: String, foreground: NSColor) -> NSImage {
    func line(_ text: String, critical: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: TWO_LINE_FONT, .foregroundColor: critical ? NSColor.systemRed : foreground])
    }
    let width = ceil(line(widest, critical: false).size().width)
    return NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
        line(top, critical: topCritical).draw(at: NSPoint(x: 0, y: 10.5))
        line(bottom, critical: bottomCritical).draw(at: NSPoint(x: 0, y: 0.5))
        return true
    }
}

private var hotkeyHandlers: [UInt32: () -> Void] = [:]
private var hotkeyReleaseHandlers: [UInt32: () -> Void] = [:]
private var hotkeyEventHandlerInstalled = false

/// Registers a system-wide hotkey through Carbon `RegisterEventHotKey`; one application event
/// handler dispatches presses and releases of every registered hotkey by identifier. A
/// combination already taken by the system is reported on stderr.
/// @param keyCode Virtual key code. @param modifiers Carbon modifier mask (`cmdKey`, `shiftKey`, 0 for none).
/// @param identifier Unique id of this hotkey within capybar. @param onRelease Runs on the main thread when released (optional).
/// @param handler Runs on the main thread when pressed.
func registerGlobalHotkey(keyCode: UInt32, modifiers: UInt32, identifier: UInt32, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) {
    if !hotkeyEventHandlerInstalled {
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotkeyIdentifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotkeyIdentifier)
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { hotkeyReleaseHandlers[hotkeyIdentifier.id]?() }
            else { hotkeyHandlers[hotkeyIdentifier.id]?() }
            return noErr
        }, 2, &eventTypes, nil, nil)
        hotkeyEventHandlerInstalled = true
    }
    hotkeyHandlers[identifier] = handler
    hotkeyReleaseHandlers[identifier] = onRelease
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x43415059), id: identifier), GetApplicationEventTarget(), 0, &reference)
    if status != noErr { FileHandle.standardError.write("hotkey \(identifier) not registered: \(status)\n".data(using: .utf8)!) }
}

private let SPECIAL_KEY_REMAPS: [(source: UInt64, destination: UInt64)] = [
    (0xC_0000_00CF, 0x7_0000_003E), // microphone (dictation) key -> F5
    (0x1_0000_009B, 0x7_0000_003F), // moon (do not disturb) key -> F6
]

/// Remaps the keyboard's microphone and moon keys to F5 and F6 for this login session through
/// `hidutil`, so macOS keeps its own handling off them and capybar's hotkeys receive them.
func remapSpecialKeys() {
    let entries = SPECIAL_KEY_REMAPS.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}" }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    process.arguments = ["property", "--set", "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"]
    process.standardOutput = FileHandle.nullDevice
    do { try process.run(); process.waitUntilExit() } catch {
        FileHandle.standardError.write("hidutil remap failed: \(error)\n".data(using: .utf8)!)
    }
}
