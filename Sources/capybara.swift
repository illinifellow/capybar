/// The animated capybara: walks, chews grass, lies looking around with an apple on its head,
/// sleeps letting out "z"s, stands in the rain, swims. Colours follow the menu bar's appearance;
/// the apple stays red, water stays blue. FRAMES_PER_SECOND frames a second.
///
/// She lives in a borderless panel laid over the menu bar's Control Center icon, which she covers
/// and follows. That icon is a window of Control Center (bundle CONTROL_CENTER_BUNDLE_IDENTIFIER)
/// named CONTROL_CENTER_ICON_WINDOW, and macOS reveals other programs' window names only with the
/// Screen Recording permission; without it she lives in an ordinary status item instead. A left
/// click brings Claude Code forward (`claudecode.swift`), a right click shows Quit.
import AppKit

private let ITEM_SIZE = NSSize(width: 30, height: 18)
private let CAPYBARA_WIDTH = 22.0
private let FRAMES_PER_SECOND = 8.0
private let WALK_STEP = 0.35

/// What the capybara is doing, with how many frames each activity lasts.
private enum Activity: CaseIterable {
    case walk, chew, lookAround, sleep, rain, swim
    var frames: Int {
        switch self {
        case .walk: return 64
        case .chew: return 32
        case .lookAround: return 48
        case .sleep: return 72
        case .rain: return 48
        case .swim: return 64
        }
    }
}

/// One animation frame: position, direction, activity and frame counter inside it.
private struct Pose {
    var originX = 0.0
    var facingRight = true
    var activity = Activity.walk
    var frame = 0
}

/// Draws one frame of `pose` in `foreground` colour.
/// @param pose What to draw.
/// @param foreground Colour of the capybara, grass and "z"s; the menu bar's label colour.
/// @returns A non-template NSImage of ITEM_SIZE (the apple and water keep their colours).
@MainActor private func makeImage(_ pose: Pose, foreground: NSColor) -> NSImage {
    NSImage(size: ITEM_SIZE, flipped: false) { _ in
        let frame = Double(pose.frame)
        let isLying = [.lookAround, .sleep].contains(pose.activity)
        let walking = pose.activity == .walk
        let swing = walking ? sin(frame * .pi / 2) * 1.2 : 0
        let bob = walking ? abs(sin(frame * .pi / 2)) * 0.6 : pose.activity == .swim ? sin(frame * .pi / 8) * 0.5 : 0
        let bodyY = isLying ? 1.0 : pose.activity == .swim ? 2.0 + bob : 4 + bob
        let bodyHeight = isLying ? 7.0 : 8.5
        let headY: Double = {
            switch pose.activity {
            case .chew: return 3.5
            case .lookAround: return 4
            case .sleep: return 1.2
            case .swim: return 4.5 + bob
            default: return 6 + bob
            }
        }()
        let chew = pose.activity == .chew && pose.frame % 2 == 0 ? 0.6 : 0
        let eyesClosed = pose.activity == .sleep || pose.frame % 24 == 0 || (pose.activity == .rain && pose.frame % 12 == 11)
        let look = pose.activity == .lookAround ? [0.0, 0.8, 0.8, 0.0, -0.8, -0.8][(pose.frame / 8) % 6] : 0

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: pose.facingRight ? pose.originX : pose.originX + CAPYBARA_WIDTH, yBy: 0)
        if !pose.facingRight { transform.scaleX(by: -1, yBy: 1) }
        transform.concat()

        foreground.setFill()
        if !isLying && pose.activity != .swim {
            for (legX, offset) in [(3.0, swing), (5.2, -swing), (10.5, -swing), (12.7, swing)] {
                NSBezierPath(roundedRect: NSRect(x: legX + offset, y: 1, width: 1.9, height: 4.5), xRadius: 0.9, yRadius: 0.9).fill()
            }
        }
        NSBezierPath(roundedRect: NSRect(x: 1.5, y: bodyY, width: 14, height: bodyHeight), xRadius: 4, yRadius: 4).fill()
        NSBezierPath(roundedRect: NSRect(x: 12, y: headY, width: 9, height: 7.5 - chew), xRadius: 3, yRadius: 3).fill()
        NSBezierPath(ovalIn: NSRect(x: 12.6, y: headY + 6.2, width: 2.6, height: 2.4)).fill()
        if pose.activity == .chew {
            for (grassX, height) in [(18.5, 3.0), (20.2, 4.0), (21.4, 2.6)] {
                NSBezierPath(rect: NSRect(x: grassX, y: 0.5, width: 0.7, height: height)).fill()
            }
        }

        NSGraphicsContext.current?.compositingOperation = .clear
        let eyeRect = eyesClosed
            ? NSRect(x: 16.4 + look, y: headY + 4.5, width: 2, height: 0.45)
            : NSRect(x: 16.6 + look, y: headY + 4, width: 1.6, height: 1.6)
        NSBezierPath(ovalIn: eyeRect).fill()
        NSBezierPath(ovalIn: NSRect(x: 19.4, y: headY + 2.2, width: 0.9, height: 0.9)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        if [.lookAround, .swim].contains(pose.activity) {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 15, y: headY + 7.3, width: 3.4, height: 3.2)).fill()
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16.8, y: headY + 10.2, width: 1.6, height: 0.9)).fill()
        }
        if pose.activity == .swim {
            NSColor.systemBlue.withAlphaComponent(0.55).setFill()
            let water = NSBezierPath()
            water.move(to: NSPoint(x: -4, y: 0))
            for step in 0...14 {
                let x = -4 + Double(step) * 2.2
                water.line(to: NSPoint(x: x, y: 6.2 + sin((x + frame) * 0.9) * 0.6))
            }
            water.line(to: NSPoint(x: 28, y: 0))
            water.close()
            water.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let headCenterX = pose.facingRight ? pose.originX + 17 : pose.originX + CAPYBARA_WIDTH - 17
        if pose.activity == .sleep {
            for index in 0..<3 {
                let phase = (frame / 3 + Double(index) * 4).truncatingRemainder(dividingBy: 12)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 3.5 + phase / 4),
                    .foregroundColor: foreground.withAlphaComponent(max(0, 1 - phase / 12)),
                ]
                let room = pose.facingRight ? ITEM_SIZE.width - headCenterX : headCenterX
                let direction: Double = room > 8 ? (pose.facingRight ? 1 : -1) : (pose.facingRight ? -1 : 1)
                let x = min(max(headCenterX - 1 + phase * 0.5 * direction, 0), ITEM_SIZE.width - 4)
                NSAttributedString(string: "z", attributes: attributes).draw(at: NSPoint(x: x, y: 8 + phase * 0.5))
            }
        }
        if pose.activity == .rain {
            NSColor.systemBlue.setFill()
            for index in 0..<3 {
                let fall = (frame * 1.5 + Double(index) * 6).truncatingRemainder(dividingBy: 18)
                let x = headCenterX - 5 + Double(index) * 4
                let y = ITEM_SIZE.height - fall
                if y > 11 { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1, height: 1.8)).fill() }
            }
        }
        return true
    }
}

/// Advances the animation by one frame; moves while walking or swimming, turns at the
/// edges, and switches to the next activity when the current one runs out.
/// @param pose The current pose, changed in place.
private func advance(_ pose: inout Pose) {
    pose.frame += 1
    if [.walk, .swim].contains(pose.activity) {
        pose.originX += (pose.facingRight ? 1 : -1) * (pose.activity == .walk ? WALK_STEP : WALK_STEP / 3)
        let limit = Double(ITEM_SIZE.width) - CAPYBARA_WIDTH
        if pose.originX >= limit || pose.originX <= 0 {
            pose.originX = min(max(pose.originX, 0), limit)
            pose.facingRight.toggle()
        }
    }
    if pose.frame >= pose.activity.frames {
        let all = Activity.allCases
        pose.activity = all[(all.firstIndex(of: pose.activity)! + 1) % all.count]
        pose.frame = 0
    }
}

/// The view the capybara lives in inside the panel: draws each frame and answers clicks.
private final class CapybaraView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    private let quitMenu = makeQuitMenu()

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        image.draw(in: NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                              width: image.size.width, height: image.size.height))
    }

    override func mouseUp(with event: NSEvent) { requestClaudeCodeFocus() }
    override func rightMouseUp(with event: NSEvent) { NSMenu.popUpContextMenu(quitMenu, with: event, for: self) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Receives clicks on the status item the capybara uses without Screen Recording.
@MainActor private final class CapybaraItemTarget: NSObject {
    private let quitMenu = makeQuitMenu()

    @objc func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { NSMenu.popUpContextMenu(quitMenu, with: event, for: sender) } else { requestClaudeCodeFocus() }
    }
}

private let CONTROL_CENTER_BUNDLE_IDENTIFIER = "com.apple.controlcenter"
private let CONTROL_CENTER_ICON_WINDOW = "BentoBox"
private let PLACEMENT_REFRESH_SECONDS = 1.0
private let CAPYBARA_AUTOSAVE_NAME = "capybarCapybara"
/// The panel's fill, which hides the Control Center icon under it. No public API exposes the
/// menu bar's tint; these are its colours measured on an opaque menu bar (dark: sRGB 4, 3, 4,
/// 2026-10-04), so on a translucent one the panel shows as a faint plate.
private let DARK_MENU_BAR_FILL = NSColor(srgbRed: 4 / 255, green: 3 / 255, blue: 4 / 255, alpha: 1)
private let LIGHT_MENU_BAR_FILL = NSColor.white

/// Finds the Control Center icon in the menu bar.
/// @returns Its frame in Cocoa screen coordinates, or nil when it is not on screen.
@MainActor private func controlCenterIconFrame() -> NSRect? {
    let owners = Set(NSRunningApplication.runningApplications(withBundleIdentifier: CONTROL_CENTER_BUNDLE_IDENTIFIER).map(\.processIdentifier))
    guard !owners.isEmpty, let primary = NSScreen.screens.first,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
          let icon = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t).map(owners.contains) == true && $0[kCGWindowName as String] as? String == CONTROL_CENTER_ICON_WINDOW }),
          let boundsDictionary = icon[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
    return NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
}

/// Shows the capybara over the Control Center icon, or in a status item of her own when the
/// icon cannot be found by name, and draws her frames.
@MainActor private final class CapybaraStage {
    private var pose = Pose()
    private let panel: NSPanel?
    private let panelView = CapybaraView()
    private let background = NSView()
    private var item: NSStatusItem?
    private let itemTarget = CapybaraItemTarget()

    /// @param overControlCenter True to live over the Control Center icon (needs Screen Recording), false for a status item.
    init(overControlCenter: Bool) {
        guard overControlCenter else {
            panel = nil
            let item = NSStatusBar.system.statusItem(withLength: ITEM_SIZE.width)
            item.autosaveName = CAPYBARA_AUTOSAVE_NAME
            item.button?.target = itemTarget
            item.button?.action = #selector(CapybaraItemTarget.clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            self.item = item
            return
        }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        background.wantsLayer = true
        panelView.autoresizingMask = [.width, .height]
        background.addSubview(panelView)
        panel.contentView = background
        self.panel = panel
        place()
        panelView.frame = background.bounds
        scheduleRepeatingTimer(every: PLACEMENT_REFRESH_SECONDS) { [weak self] in self?.place() }
    }

    /// Moves the panel over the Control Center icon, or hides it while the icon is absent.
    private func place() {
        guard let panel else { return }
        guard let frame = controlCenterIconFrame() else {
            logFailureOnce(key: "control center icon", "Control Center icon window \(CONTROL_CENTER_ICON_WINDOW) not found; the capybara stays hidden until it appears")
            return panel.orderOut(nil)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    /// Draws the next frame where the capybara lives; nothing is drawn while she cannot be seen
    /// (screen locked or asleep, menu bar hidden).
    func drawNextFrame() {
        if let panel {
            guard panel.occlusionState.contains(.visible) else { return }
            let isDark = panelView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let fill = (isDark ? DARK_MENU_BAR_FILL : LIGHT_MENU_BAR_FILL).cgColor
            if background.layer?.backgroundColor != fill { background.layer?.backgroundColor = fill }
            panelView.image = makeImage(pose, foreground: labelColor(for: panelView.effectiveAppearance))
        } else if let button = item?.button {
            guard button.window?.occlusionState.contains(.visible) ?? false else { return }
            button.image = makeImage(pose, foreground: labelColor(for: button.effectiveAppearance))
        }
        advance(&pose)
    }
}

@MainActor private var capybaraStage: CapybaraStage?

/// Puts the animated capybara in the menu bar: over the Control Center icon when capybar may
/// read window names (Screen Recording), in a status item of her own otherwise.
@MainActor func startCapybara() {
    let stage = CapybaraStage(overControlCenter: CGPreflightScreenCaptureAccess())
    capybaraStage = stage
    scheduleRepeatingTimer(every: 1 / FRAMES_PER_SECOND) { stage.drawNextFrame() }.fire()
}
