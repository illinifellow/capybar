/// Per-process usage for the drop-down menus of the CPU and RAM item and the network item:
/// sampling (`ps`, `nettop`), grouping by process name, and the "top rows, rest folded"
/// menu section.
import AppKit

private let VISIBLE_ROWS = 5
private let FOLDED_ROWS_LIMIT = 40
private let ROW_TAB_STOP: CGFloat = 300

/// Usage of every process sharing one name, summed.
struct ProcessUsage {
    var name: String
    var cpuPercent = 0.0
    var memoryBytes = 0.0
    var receivedBytes = 0.0
    var sentBytes = 0.0
}

/// Runs a command and returns its standard output.
/// @param path Executable. @param arguments Its arguments.
/// @returns Output as text, empty when the command cannot start.
private func runCommand(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Reads CPU percent (ps's recent average, 100% = one core) and resident memory of every
/// process, summed per process name.
/// @returns One entry per name, unsorted.
func readProcessUsage() -> [ProcessUsage] {
    var byName: [String: ProcessUsage] = [:]
    for line in runCommand("/bin/ps", ["-Aceo", "pcpu=,rss=,comm="]).split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let cpu = Double(fields[0]), let rssKilobytes = Double(fields[1]) else { continue }
        let name = String(fields[2])
        byName[name, default: ProcessUsage(name: name)].cpuPercent += cpu
        byName[name, default: ProcessUsage(name: name)].memoryBytes += rssKilobytes * 1024
    }
    return Array(byName.values)
}

/// Measures bytes received and sent per process over `seconds` with `nettop` delta mode,
/// summed per process name (names resolved through `ps` by process id).
/// @param seconds Sampling window. @returns Entries with traffic, unsorted.
func sampleNetworkUsage(seconds: Int = 1) -> [ProcessUsage] {
    var namesById: [String: String] = [:]
    for line in runCommand("/bin/ps", ["-Aco", "pid=,comm="]).split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if fields.count == 2 { namesById[String(fields[0])] = String(fields[1]) }
    }
    let output = runCommand("/usr/bin/nettop", ["-P", "-L", "2", "-s", String(seconds), "-d", "-x", "-J", "bytes_in,bytes_out"])
    guard let lastHeader = output.range(of: ",bytes_in,bytes_out,", options: .backwards) else { return [] }
    var byName: [String: ProcessUsage] = [:]
    for line in output[lastHeader.upperBound...].split(separator: "\n") {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3, let received = Double(fields[1]), let sent = Double(fields[2]), received + sent > 0 else { continue }
        let label = String(fields[0])
        let processId = label.split(separator: ".").last.map(String.init) ?? ""
        let name = namesById[processId] ?? label
        byName[name, default: ProcessUsage(name: name)].receivedBytes += received / Double(seconds)
        byName[name, default: ProcessUsage(name: name)].sentBytes += sent / Double(seconds)
    }
    return Array(byName.values)
}

/// Formats a byte count as "1.2 GB".
/// @param bytes Size. @returns The formatted size.
func formatBytes(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

/// Builds a disabled row: name on the left, value right-aligned.
/// @param name Process name. @param value Formatted value. @returns The menu item.
private func makeRow(_ name: String, _ value: String) -> NSMenuItem {
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ROW_TAB_STOP)]
    let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    row.attributedTitle = NSAttributedString(string: "\(name)\t\(value)", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .paragraphStyle: paragraph,
    ])
    return row
}

/// Appends a section: a bold title, the VISIBLE_ROWS largest rows, and a "More (N)"
/// submenu holding the next rows up to FOLDED_ROWS_LIMIT.
/// @param menu Target menu. @param title Section title.
/// @param rows (name, value) pairs, largest first.
func appendTopSection(to menu: NSMenu, title: String, rows: [(String, String)]) {
    let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    header.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
    menu.addItem(header)
    rows.prefix(VISIBLE_ROWS).forEach { menu.addItem(makeRow($0.0, $0.1)) }
    let folded = rows.dropFirst(VISIBLE_ROWS).prefix(FOLDED_ROWS_LIMIT)
    guard !folded.isEmpty else { return }
    let more = NSMenuItem(title: "More (\(rows.count - VISIBLE_ROWS))", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    folded.forEach { submenu.addItem(makeRow($0.0, $0.1)) }
    more.submenu = submenu
    menu.addItem(more)
}

/// Appends a separator and Quit.
/// @param menu Target menu.
func appendQuit(to menu: NSMenu) {
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
}
