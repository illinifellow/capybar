/// Per-process usage as the drop-down menus show it: parsing `ps` and `nettop` output, grouping
/// processes by name, deciding which may be force quit, and folding long lists under "More".
import Foundation

/// Processes whose loss ends the login session or the system itself; their rows never offer
/// an active cross, whoever owns them.
let PROTECTED_PROCESS_NAMES: Set<String> = ["loginwindow", "launchd", "WindowServer"]

/// Usage of every process sharing one name, summed.
struct ProcessUsage: Sendable {
    var name: String
    var cpuPercent = 0.0
    var memoryBytes = 0.0
    var receivedBytesPerSecond = 0.0
    var sentBytesPerSecond = 0.0
    var receivedBytesTotal = 0.0
    var sentBytesTotal = 0.0
    /// Processes of this name the user may kill: owned by the current user, capybar itself and
    /// PROTECTED_PROCESS_NAMES excluded.
    var killableProcessIds: [pid_t] = []
}

/// Groups the output of `ps -Aceo pid=,uid=,pcpu=,rss=,comm=` by process name.
/// @param output The `ps` output, one process per line. @param userId The current user.
/// @param ownProcessId capybar's own process id, never killable.
/// @returns One entry per name, CPU percent and resident memory summed, unsorted; malformed lines are skipped.
func parseProcessUsage(_ output: String, userId: uid_t, ownProcessId: pid_t) -> [ProcessUsage] {
    var byName: [String: ProcessUsage] = [:]
    for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard fields.count == 5, let processId = pid_t(fields[0]), let ownerId = uid_t(fields[1]),
              let cpu = Double(fields[2]), let residentKilobytes = Double(fields[3]) else { continue }
        let name = String(fields[4])
        var usage = byName[name] ?? ProcessUsage(name: name)
        usage.cpuPercent += cpu
        usage.memoryBytes += residentKilobytes * 1024
        if ownerId == userId && processId != ownProcessId && !PROTECTED_PROCESS_NAMES.contains(name) { usage.killableProcessIds.append(processId) }
        byName[name] = usage
    }
    return Array(byName.values)
}

/// Reads process names from the output of `ps -Aco pid=,comm=`.
/// @param output The `ps` output. @returns Name by process id; malformed lines are skipped.
func parseProcessNames(_ output: String) -> [pid_t: String] {
    var namesById: [pid_t: String] = [:]
    for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if fields.count == 2, let processId = pid_t(fields[0]) { namesById[processId] = String(fields[1]) }
    }
    return namesById
}

/// The processes of a force quit that still carry the name they had when the cross was pressed;
/// an id that exited or now belongs to another program is dropped.
/// @param processIds Ids captured at the press. @param name Their name then.
/// @param currentNames Name by id now (`parseProcessNames`). @returns The ids safe to signal.
func processesStillNamed(_ name: String, among processIds: [pid_t], currentNames: [pid_t: String]) -> [pid_t] {
    processIds.filter { currentNames[$0] == name && !PROTECTED_PROCESS_NAMES.contains(name) }
}

/// A list split into the rows shown directly and the rows folded under "More".
struct FoldedRows<Row> {
    var visible: [Row]
    var folded: [Row]
}

/// Splits rows, largest first, into the first `visibleCount` and up to `foldedLimit` after them;
/// rows beyond both are not shown.
/// @param rows All rows, largest first. @param visibleCount Rows shown directly. @param foldedLimit Most rows under "More".
/// @returns The two parts; `folded.count` is the number "More (N)" announces.
func foldRows<Row>(_ rows: [Row], visibleCount: Int, foldedLimit: Int) -> FoldedRows<Row> {
    FoldedRows(visible: Array(rows.prefix(visibleCount)), folded: Array(rows.dropFirst(visibleCount).prefix(foldedLimit)))
}

/// Bytes a process received and sent.
struct Traffic: Equatable, Sendable {
    var received: Double
    var sent: Double
}

/// One process's traffic in a `nettop` sample: what it moved during the last second and in all.
struct NettopEntry: Equatable, Sendable {
    /// `nettop`'s label, "name.pid" with the name truncated.
    var label: String
    var delta: Traffic
    var total: Traffic
}

/// Parses the streamed CSV of `nettop -P -L 0 -d -x -J bytes_in,bytes_out`. A header line closes
/// the block before it; the first non-empty block holds each process's cumulative bytes, every
/// later one the bytes moved since the previous block, which are added to those totals.
struct NettopParser {
    private static let HEADER_PREFIX = ",bytes_in,bytes_out"
    private var pending = ""
    private var block: [String: Traffic] = [:]
    private var totals: [String: Traffic]?

    /// Feeds streamed text, which may end mid-line.
    /// @param text The next chunk. @returns One sample per delta block the chunk completed, oldest first.
    mutating func consume(_ text: String) -> [[NettopEntry]] {
        pending += text
        let lines = pending.components(separatedBy: "\n")
        pending = lines.last ?? ""
        var samples: [[NettopEntry]] = []
        for raw in lines.dropLast() {
            let line = raw.trimmingCharacters(in: ["\r", "\u{4}", "\u{8}"])
            if line.hasPrefix(Self.HEADER_PREFIX) {
                if let sample = finishBlock() { samples.append(sample) }
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let received = Double(fields[1]), let sent = Double(fields[2]) else { continue }
            block[String(fields[0])] = Traffic(received: received, sent: sent)
        }
        return samples
    }

    /// Turns the finished block into totals (the first) or a sample (every later one).
    private mutating func finishBlock() -> [NettopEntry]? {
        defer { block = [:] }
        guard !block.isEmpty else { return nil }
        guard var totals else {
            totals = block
            return nil
        }
        let sample = block.map { label, delta in
            let before = totals[label] ?? Traffic(received: 0, sent: 0)
            let total = Traffic(received: before.received + delta.received, sent: before.sent + delta.sent)
            totals[label] = total
            return NettopEntry(label: label, delta: delta, total: total)
        }
        self.totals = totals
        return sample
    }
}

/// Sums a `nettop` sample by process name; the name comes from `ps` by the id in the label,
/// since `nettop` truncates names, and falls back to the label.
/// @param sample One sample. @param namesById Names by process id (`parseProcessNames`).
/// @returns The processes that moved traffic during the sample's second, unsorted.
func groupTraffic(_ sample: [NettopEntry], namesById: [pid_t: String]) -> [ProcessUsage] {
    var byName: [String: ProcessUsage] = [:]
    for entry in sample {
        let name = entry.label.split(separator: ".").last.flatMap { pid_t($0) }.flatMap { namesById[$0] } ?? entry.label
        var usage = byName[name] ?? ProcessUsage(name: name)
        usage.receivedBytesPerSecond += entry.delta.received
        usage.sentBytesPerSecond += entry.delta.sent
        usage.receivedBytesTotal += entry.total.received
        usage.sentBytesTotal += entry.total.sent
        byName[name] = usage
    }
    return byName.values.filter { $0.receivedBytesPerSecond + $0.sentBytesPerSecond > 0 }
}
