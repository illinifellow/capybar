/// The menu rows every drop-down shares, all drawn by one custom row view: a section of the
/// largest rows with the rest folded under "More", and a section of labelled values. Sections
/// keep their menu items and update them in place, so an open menu can refresh every second
/// without losing the highlighted row or the open submenu. Also the timer that drives that
/// refresh, and the Quit entry.
import AppKit

private let VISIBLE_ROWS = 5
private let FOLDED_ROWS_LIMIT = 40
private let ROW_HEIGHT: CGFloat = 22
private let ROW_LEADING_INSET: CGFloat = 12
private let ROW_TRAILING_INSET: CGFloat = 12
private let NAME_COLUMN_WIDTH: CGFloat = 220
private let VALUE_COLUMN_WIDTH: CGFloat = 76
private let INFO_NAME_COLUMN_WIDTH: CGFloat = 130
private let INFO_VALUE_COLUMN_WIDTH: CGFloat = 250
private let KILL_BUTTON_SIZE: CGFloat = 16
private let KILL_BUTTON_GAP: CGFloat = 10
private let REFRESH_AFTER_KILL_SECONDS = 0.25
private let COPIED_NOTICE_SECONDS = 0.9
private let OPEN_MENU_REFRESH_SECONDS = 1.0
private let HIGHLIGHT_INSET: CGFloat = 5
private let HIGHLIGHT_RADIUS: CGFloat = 4
private let ROW_FONT = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
private let COLUMN_HEADER_FONT = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

/// What a row shows after its value columns.
enum KillControl {
    /// Nothing.
    case none
    /// An empty space as wide as the cross, so headings line up with rows that carry one.
    case placeholder
    /// A cross that force quits these processes; disabled when the list is empty.
    case button([pid_t])

    /// Whether the row keeps room for the cross after its values.
    var reservesColumn: Bool {
        if case .none = self { return false }
        return true
    }
}

/// One row of a menu section: a name, its formatted values (one per column) and what follows
/// them, with the widths of the name column and of each value column.
struct MenuRow {
    var name: String
    var values: [String]
    var kill: KillControl = .none
    var nameWidth: CGFloat = NAME_COLUMN_WIDTH
    var valueWidth: CGFloat = VALUE_COLUMN_WIDTH
    /// Text a click copies to the clipboard; nil leaves the row inert.
    var copyValue: String? = nil
}

/// One labelled value of an information section.
struct InfoRow {
    var label: String
    var value: String
    /// Whether a click copies the value.
    var copyable = false

    var menuRow: MenuRow {
        MenuRow(name: label, values: [value], nameWidth: INFO_NAME_COLUMN_WIDTH, valueWidth: INFO_VALUE_COLUMN_WIDTH, copyValue: copyable ? value : nil)
    }
}

/// Puts text on the general pasteboard, replacing what was there.
/// @param text The text.
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// A borderless cross, grey at rest, red under the pointer, dimmed by AppKit when disabled. The
/// symbol carries its colour in its own configuration: a template image tinted through
/// `contentTintColor` is not drawn inside a menu row view while the button is enabled.
private final class KillButton: NSButton {
    private static func crossImage(_ color: NSColor) -> NSImage {
        let symbol = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Force Quit")!
        return symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: color))!
    }

    private static let restImage = crossImage(.secondaryLabelColor)
    private static let hoverImage = crossImage(.systemRed)

    /// @param action Sent to the target when pressed.
    init(action: Selector) {
        super.init(frame: .zero)
        isBordered = false
        imageScaling = .scaleProportionallyDown
        self.action = action
        image = KillButton.restImage
    }

    required init?(coder: NSCoder) { fatalError("KillButton is built in code only") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { image = KillButton.hoverImage } }

    override func mouseExited(with event: NSEvent) { image = KillButton.restImage }
}

/// The view of one menu row: the name on the left, value columns right-aligned at the right
/// edge, an optional cross button after them. It stretches to the menu's width. A row with a
/// copy value highlights under the pointer like an ordinary menu item and, clicked, copies the
/// value and shows "Copied ✓" in place of its name for a moment, the menu staying open.
private final class MenuRowView: NSView {
    private let nameLabel: NSTextField
    private let valueLabels: [NSTextField]
    private let killButton: KillButton?
    private let reservesKillColumn: Bool
    private let valueWidth: CGFloat
    private var row: MenuRow
    private var processIds: [pid_t] = []
    private var copiedUntil = Date.distantPast
    private let onKill: () -> Void

    /// @param row The row to show. @param font Text font. @param onKill Runs after the cross killed the row's processes.
    init(row: MenuRow, font: NSFont, onKill: @escaping () -> Void) {
        self.row = row
        nameLabel = MenuRowView.makeLabel(font: font, alignment: .left)
        valueLabels = row.values.map { _ in MenuRowView.makeLabel(font: font, alignment: .right) }
        reservesKillColumn = row.kill.reservesColumn
        valueWidth = row.valueWidth
        self.onKill = onKill
        if case .button = row.kill { killButton = KillButton(action: #selector(killPressed)) } else { killButton = nil }
        let killWidth = reservesKillColumn ? KILL_BUTTON_GAP + KILL_BUTTON_SIZE : 0
        let width = ROW_LEADING_INSET + row.nameWidth + CGFloat(row.values.count) * row.valueWidth + killWidth + ROW_TRAILING_INSET
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: ROW_HEIGHT))
        autoresizingMask = [.width]
        ([nameLabel] + valueLabels).forEach(addSubview)
        if let killButton {
            killButton.target = self
            addSubview(killButton)
        }
        show(row)
    }

    required init?(coder: NSCoder) { fatalError("MenuRowView is built in code only") }

    /// Whether `row` can be shown by this view without rebuilding it.
    func fits(_ row: MenuRow) -> Bool {
        row.values.count == valueLabels.count && row.kill.reservesColumn == reservesKillColumn && row.valueWidth == valueWidth
            && (killButton != nil) == { if case .button = row.kill { return true } else { return false } }()
    }

    /// Shows new content in place.
    /// @param row Content of the same shape (see `fits`).
    func show(_ row: MenuRow) {
        self.row = row
        if Date() >= copiedUntil, nameLabel.stringValue != row.name { nameLabel.stringValue = row.name }
        for (label, value) in zip(valueLabels, row.values) where label.stringValue != value {
            label.stringValue = value
            label.toolTip = value
        }
        if case .button(let killable) = row.kill {
            processIds = killable
            killButton?.isEnabled = !killable.isEmpty
            killButton?.toolTip = killable.isEmpty ? "Belongs to another user or to capybar itself; macOS does not permit it" : "Force Quit every \(row.name) process"
        }
        needsDisplay = true
    }

    /// Builds a one-line, non-editable label in the colour of the menu's disabled rows; a value
    /// too long for its column is shortened in the middle and shown whole as its tooltip.
    private static func makeLabel(font: NSFont, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        label.lineBreakMode = alignment == .right ? .byTruncatingMiddle : .byTruncatingTail
        return label
    }

    override func layout() {
        super.layout()
        let lineHeight = ceil(nameLabel.intrinsicContentSize.height)
        let textY = floor((bounds.height - lineHeight) / 2)
        var right = bounds.width - ROW_TRAILING_INSET
        if reservesKillColumn {
            killButton?.frame = NSRect(x: right - KILL_BUTTON_SIZE, y: floor((bounds.height - KILL_BUTTON_SIZE) / 2), width: KILL_BUTTON_SIZE, height: KILL_BUTTON_SIZE)
            right -= KILL_BUTTON_SIZE + KILL_BUTTON_GAP
        }
        for label in valueLabels.reversed() {
            label.frame = NSRect(x: right - valueWidth, y: textY, width: valueWidth, height: lineHeight)
            right -= valueWidth
        }
        nameLabel.frame = NSRect(x: ROW_LEADING_INSET, y: textY, width: max(right - ROW_LEADING_INSET, 0), height: lineHeight)
    }

    private var isHighlighted: Bool { row.copyValue != nil && enclosingMenuItem?.isHighlighted == true }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isHighlighted
        let textColor: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        ([nameLabel] + valueLabels).filter { $0.textColor != textColor }.forEach { $0.textColor = textColor }
        guard highlighted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: HIGHLIGHT_INSET, dy: 0), xRadius: HIGHLIGHT_RADIUS, yRadius: HIGHLIGHT_RADIUS).fill()
    }

    override func mouseUp(with event: NSEvent) {
        guard let copyValue = row.copyValue else { return super.mouseUp(with: event) }
        copyToPasteboard(copyValue)
        copiedUntil = Date().addingTimeInterval(COPIED_NOTICE_SECONDS)
        nameLabel.stringValue = "Copied ✓"
        let timer = Timer(timeInterval: COPIED_NOTICE_SECONDS, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.nameLabel.stringValue = self.row.name
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func killPressed() {
        forceQuit(processIds)
        killButton?.isEnabled = false
        let timer = Timer(timeInterval: REFRESH_AFTER_KILL_SECONDS, repeats: false) { [onKill] _ in onKill() }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Shows a row in a menu item, reusing its view when the shape allows; the item's title (unseen,
/// read by VoiceOver) is the row's name.
/// @param row Content. @param item Target item. @param font Text font. @param onKill Runs after a force quit.
private func show(_ row: MenuRow, in item: NSMenuItem, font: NSFont = ROW_FONT, onKill: @escaping () -> Void) {
    if item.title != row.name { item.title = row.name }
    if let view = item.view as? MenuRowView, view.fits(row) { view.show(row) } else { item.view = MenuRowView(row: row, font: font, onKill: onKill) }
}

/// Makes a section title item.
private func makeHeader(_ title: String) -> NSMenuItem {
    let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    header.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
    return header
}

/// Brings the row items of a menu to `rows`, updating items in place and inserting or removing
/// only the difference, right after `anchor` (or at the top when nil).
/// @returns The row items in order.
private func reconcile(_ items: [NSMenuItem], with rows: [MenuRow], in menu: NSMenu, after anchor: NSMenuItem?, onKill: @escaping () -> Void) -> [NSMenuItem] {
    var items = items
    while items.count > rows.count { menu.removeItem(items.removeLast()) }
    for (index, row) in rows.enumerated() {
        if index < items.count {
            show(row, in: items[index], onKill: onKill)
        } else {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            show(row, in: item, onKill: onKill)
            let previous = items.last ?? anchor
            menu.insertItem(item, at: previous.map { menu.index(of: $0) + 1 } ?? 0)
            items.append(item)
        }
    }
    return items
}

/// A section of a menu: a bold title, optional column headings, then rows. A folding section
/// shows the VISIBLE_ROWS largest rows and folds the next ones, up to FOLDED_ROWS_LIMIT, under
/// "More (N)". `update` changes the rows in place.
final class MenuSection {
    private let menu: NSMenu
    private let folds: Bool
    private let onKill: () -> Void
    private let lastFixedItem: NSMenuItem
    private var rowItems: [NSMenuItem] = []
    private var moreItem: NSMenuItem?
    private var foldedItems: [NSMenuItem] = []

    /// Appends the section's title (and headings) to the end of the menu.
    /// @param menu Target menu. @param title Section title. @param columns Headings over the value columns; empty shows none.
    /// @param folds Whether rows beyond VISIBLE_ROWS fold under "More". @param onKill Runs after a row's cross killed its processes.
    init(in menu: NSMenu, title: String, columns: [String] = [], folds: Bool, onKill: @escaping () -> Void = {}) {
        self.menu = menu
        self.folds = folds
        self.onKill = onKill
        let header = makeHeader(title)
        menu.addItem(header)
        if columns.isEmpty {
            lastFixedItem = header
        } else {
            let headings = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            show(MenuRow(name: "", values: columns), in: headings, font: COLUMN_HEADER_FONT, onKill: {})
            menu.addItem(headings)
            lastFixedItem = headings
        }
    }

    /// Shows `rows`, largest first.
    func update(_ rows: [MenuRow]) {
        let visible = folds ? Array(rows.prefix(VISIBLE_ROWS)) : rows
        rowItems = reconcile(rowItems, with: visible, in: menu, after: lastFixedItem, onKill: onKill)
        guard folds else { return }
        let folded = Array(rows.dropFirst(VISIBLE_ROWS).prefix(FOLDED_ROWS_LIMIT))
        if folded.isEmpty {
            if let moreItem { menu.removeItem(moreItem) }
            moreItem = nil
            foldedItems = []
            return
        }
        let more: NSMenuItem
        if let moreItem { more = moreItem } else {
            more = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            more.submenu = NSMenu()
            menu.insertItem(more, at: menu.index(of: rowItems.last ?? lastFixedItem) + 1)
            moreItem = more
        }
        let title = "More (\(rows.count - VISIBLE_ROWS))"
        if more.title != title { more.title = title }
        foldedItems = reconcile(foldedItems, with: folded, in: more.submenu!, after: nil, onKill: onKill)
    }

    /// Shows labelled values.
    func update(_ rows: [InfoRow]) { update(rows.map(\.menuRow)) }
}

/// Repeats an action every second while a menu is open.
final class OpenMenuTimer {
    private var timer: Timer?

    /// Starts repeating `action`; a running timer is replaced.
    func start(_ action: @escaping () -> Void) {
        timer?.invalidate()
        timer = scheduleRepeatingTimer(every: OPEN_MENU_REFRESH_SECONDS) { _ in action() }
    }

    /// Stops repeating.
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Appends Quit, after a separator when the menu holds anything else, and above it the update
/// entry while a newer release exists.
/// @param menu Target menu.
func appendQuit(to menu: NSMenu) {
    if menu.numberOfItems > 0 { menu.addItem(.separator()) }
    if let update = Updater.makeMenuItem() { menu.addItem(update) }
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
}
