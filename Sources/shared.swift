/// Helpers shared by the menu bar items: the Quit menu, timers that keep firing while a menu
/// is open, the menu bar's label colour, the two stacked lines image and global hotkeys.
import AppKit
import Carbon

@MainActor private let TWO_LINE_FONT = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
private let TWO_LINE_HEIGHT: CGFloat = 22
private let TOP_LINE_BASELINE: CGFloat = 10.5
private let BOTTOM_LINE_BASELINE: CGFloat = 0.5
/// The four-character signature of capybar's hotkeys ("CAPY").
private let HOTKEY_SIGNATURE = OSType(0x43415059)

/// Rebuilds a Quit menu each time it opens, so the update entry appears when one is due.
@MainActor private final class QuitMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        appendQuit(to: menu)
    }
}

@MainActor private let quitMenuDelegate = QuitMenuDelegate()

/// Builds an item menu holding Quit (quits all items) and, while a newer release exists, the update entry.
/// @returns The menu.
@MainActor func makeQuitMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = quitMenuDelegate
    appendQuit(to: menu)
    return menu
}

/// Schedules a repeating timer on the main run loop in the common modes, so it keeps firing
/// while a menu is open (menus track events in a mode a default timer never fires in).
/// @param interval Seconds between runs. @param block The work, run on the main thread.
/// @returns The timer.
@MainActor @discardableResult
func scheduleRepeatingTimer(every interval: TimeInterval, _ block: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated(block) }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

/// Runs work once on the main thread after a delay, in the common run loop modes.
/// @param delay Seconds to wait. @param block The work.
@MainActor func runAfter(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
    RunLoop.main.add(Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated(block) }, forMode: .common)
}

/// Hands work to the main thread from any thread, in the common run loop modes so it is not
/// held back while a menu is open.
/// @param block The work.
func performOnMain(_ block: @escaping @MainActor @Sendable () -> Void) {
    RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(block) }
}

/// Resolves the label colour for an appearance (light or dark menu bar).
/// @param appearance The appearance that decides.
/// @returns An RGB colour.
@MainActor func labelColor(for appearance: NSAppearance) -> NSColor {
    var color = NSColor.labelColor
    appearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor }
    return color
}

@MainActor private var shownTwoLines: [ObjectIdentifier: String] = [:]

/// Shows two stacked lines on a status item, redrawing only when the item can be seen and the
/// text, the red state or the menu bar's label colour changed since it was last drawn.
/// @param item Target item. @param top Upper line. @param topCritical Draws the upper line red.
/// @param bottom Lower line. @param bottomCritical Draws the lower line red.
/// @param widest Every longest text either line can hold; the image is as wide as the widest of them.
@MainActor func showTwoLines(on item: NSStatusItem, top: String, topCritical: Bool = false, bottom: String, bottomCritical: Bool = false, widest: [String]) {
    guard let button = item.button, button.window?.occlusionState.contains(.visible) ?? false else { return }
    let foreground = labelColor(for: button.effectiveAppearance)
    let key = "\(top)|\(topCritical)|\(bottom)|\(bottomCritical)|\(foreground)"
    guard shownTwoLines[ObjectIdentifier(item)] != key else { return }
    shownTwoLines[ObjectIdentifier(item)] = key
    button.image = makeTwoLineImage(top: top, topCritical: topCritical, bottom: bottom, bottomCritical: bottomCritical, widest: widest, foreground: foreground)
}

/// Renders two stacked lines, TWO_LINE_HEIGHT high, as wide as the widest candidate so the item
/// never changes width.
/// @param top Upper line. @param topCritical Draws the upper line red.
/// @param bottom Lower line. @param bottomCritical Draws the lower line red.
/// @param widest Every longest text either line can hold. @param foreground Normal text colour.
/// @returns A non-template NSImage.
@MainActor private func makeTwoLineImage(top: String, topCritical: Bool, bottom: String, bottomCritical: Bool, widest: [String], foreground: NSColor) -> NSImage {
    func line(_ text: String, critical: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: TWO_LINE_FONT, .foregroundColor: critical ? NSColor.systemRed : foreground])
    }
    let width = ceil(widest.map { line($0, critical: false).size().width }.max() ?? 0)
    let topLine = line(top, critical: topCritical), bottomLine = line(bottom, critical: bottomCritical)
    return NSImage(size: NSSize(width: width, height: TWO_LINE_HEIGHT), flipped: false) { _ in
        topLine.draw(at: NSPoint(x: 0, y: TOP_LINE_BASELINE))
        bottomLine.draw(at: NSPoint(x: 0, y: BOTTOM_LINE_BASELINE))
        return true
    }
}

/// Every system-wide hotkey capybar registers, by its identifier.
enum Hotkey: UInt32 {
    case screenshotToClipboard = 1
    case screenshotToPreview = 2
    case microphone = 10
    case doNotDisturb = 11
}

@MainActor private var hotkeyHandlers: [UInt32: () -> Void] = [:]
@MainActor private var heldHotkeys: Set<UInt32> = []
@MainActor private var hotkeyEventHandlerInstalled = false

/// Dispatches a Carbon hotkey event: a press runs the hotkey's handler unless the key is
/// already held (key repeat sends further presses), a release ends the hold.
/// @param event The hotkey event. @returns noErr.
@MainActor private func handleHotkeyEvent(_ event: EventRef?) -> OSStatus {
    var identifier = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
        heldHotkeys.remove(identifier.id)
    } else if heldHotkeys.insert(identifier.id).inserted {
        hotkeyHandlers[identifier.id]?()
    }
    return noErr
}

/// Registers a system-wide hotkey through Carbon `RegisterEventHotKey`; one application event
/// handler dispatches every registered hotkey. Holding the key runs the handler once. A
/// combination another program already holds is logged.
/// @param hotkey Which hotkey. @param keyCode Virtual key code. @param modifiers Carbon modifier mask (`cmdKey`, `shiftKey`, 0 for none).
/// @param handler Runs on the main thread when pressed.
@MainActor func registerGlobalHotkey(_ hotkey: Hotkey, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
    if !hotkeyEventHandlerInstalled {
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        // Carbon delivers application events on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in MainActor.assumeIsolated { handleHotkeyEvent(event) } }, eventTypes.count, &eventTypes, nil, nil)
        hotkeyEventHandlerInstalled = true
    }
    hotkeyHandlers[hotkey.rawValue] = handler
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: HOTKEY_SIGNATURE, id: hotkey.rawValue), GetApplicationEventTarget(), 0, &reference)
    if status != noErr { logFailure("hotkey \(hotkey) not registered: \(status)") }
}
