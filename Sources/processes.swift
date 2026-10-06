/// Per-process usage for the drop-down menus of the CPU and RAM item and the network item:
/// sampling (`ps`, a streaming `nettop`), grouping by process name, and force quitting a group.
import Foundation

/// Usage of every process sharing one name, summed.
struct ProcessUsage {
    var name: String
    var cpuPercent = 0.0
    var memoryBytes = 0.0
    var receivedBytesPerSecond = 0.0
    var sentBytesPerSecond = 0.0
    var receivedBytesTotal = 0.0
    var sentBytesTotal = 0.0
    /// Processes of this name the user may kill: owned by the current user, capybar excluded.
    var killableProcessIds: [pid_t] = []
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

/// Reads CPU percent (ps's recent average, 100% = one core), resident memory and owner of
/// every process, summed per process name; processes owned by the current user, capybar
/// itself excepted, are recorded as killable.
/// @returns One entry per name, unsorted.
func readProcessUsage() -> [ProcessUsage] {
    var byName: [String: ProcessUsage] = [:]
    let userId = getuid(), ownProcessId = getpid()
    for line in runCommand("/bin/ps", ["-Aceo", "pid=,uid=,pcpu=,rss=,comm="]).split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard fields.count == 5, let processId = pid_t(fields[0]), let ownerId = uid_t(fields[1]),
              let cpu = Double(fields[2]), let rssKilobytes = Double(fields[3]) else { continue }
        let name = String(fields[4])
        var usage = byName[name] ?? ProcessUsage(name: name)
        usage.cpuPercent += cpu
        usage.memoryBytes += rssKilobytes * 1024
        if ownerId == userId && processId != ownProcessId { usage.killableProcessIds.append(processId) }
        byName[name] = usage
    }
    return Array(byName.values)
}

/// Reads process names by process id through `ps`.
/// @returns Name keyed by the decimal process id.
private func readProcessNames() -> [String: String] {
    var namesById: [String: String] = [:]
    for line in runCommand("/bin/ps", ["-Aco", "pid=,comm="]).split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if fields.count == 2 { namesById[String(fields[0])] = String(fields[1]) }
    }
    return namesById
}

/// Sends SIGKILL to each process, the way Activity Monitor's Force Quit does. A process that
/// is gone already or that macOS refuses to signal is skipped without complaint.
/// @param processIds Processes to kill.
func forceQuit(_ processIds: [pid_t]) {
    processIds.forEach { kill($0, SIGKILL) }
}

/// Formats a byte count as "1.2 GB".
/// @param bytes Size. @returns The formatted size.
func formatBytes(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}


/// Streams per-process traffic from one long-running `nettop` in delta mode while a menu is
/// open. `nettop` prints a sample per second but buffers its output unless it writes to a
/// terminal, so it runs on a pseudo-terminal. Its first sample holds each process's cumulative
/// bytes; every later one the bytes moved during the last second, which are added to those totals.
/// Names are resolved through `ps` by process id, since `nettop` truncates them.
final class NetworkSampler {
    private let onSample: ([ProcessUsage]) -> Void
    private var process: Process?
    private var terminal: FileHandle?
    private var pending = ""
    private var block: [String: (received: Double, sent: Double)] = [:]
    private var blocksSeen = 0
    private var totals: [String: (received: Double, sent: Double)] = [:]

    /// @param onSample Receives, on the main thread in every run loop mode, the processes that moved traffic during the last second, unsorted.
    init(onSample: @escaping ([ProcessUsage]) -> Void) {
        self.onSample = onSample
    }

    /// Starts `nettop`; does nothing when it already runs or the pseudo-terminal cannot be opened.
    func start() {
        guard process == nil else { return }
        var primary: Int32 = 0, secondary: Int32 = 0
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
            FileHandle.standardError.write("nettop pseudo-terminal failed: \(String(cString: strerror(errno)))\n".data(using: .utf8)!)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "0", "-s", "1", "-d", "-x", "-J", "bytes_in,bytes_out"]
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        process.standardOutput = secondaryHandle
        process.standardError = FileHandle.nullDevice
        let terminal = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        pending = ""; block = [:]; blocksSeen = 0; totals = [:]
        terminal.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(String(decoding: data, as: UTF8.self))
        }
        do { try process.run() } catch {
            FileHandle.standardError.write("nettop did not start: \(error)\n".data(using: .utf8)!)
            terminal.readabilityHandler = nil
            return
        }
        try? secondaryHandle.close()
        self.process = process
        self.terminal = terminal
    }

    /// Stops `nettop`.
    func stop() {
        terminal?.readabilityHandler = nil
        process?.terminate()
        process = nil
        terminal = nil
    }

    /// Splits streamed text into lines; a header line closes the block before it.
    private func consume(_ text: String) {
        pending += text
        let lines = pending.components(separatedBy: "\n")
        pending = lines.last ?? ""
        for raw in lines.dropLast() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\u{4}\u{8}"))
            if line.hasPrefix(",bytes_in,bytes_out") { finishBlock(); continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let received = Double(fields[1]), let sent = Double(fields[2]) else { continue }
            block[String(fields[0])] = (received, sent)
        }
    }

    /// Turns a finished block into totals (the first) or a sample (every later one).
    private func finishBlock() {
        defer { block = [:]; blocksSeen += 1 }
        guard !block.isEmpty else { return }
        if blocksSeen <= 1 {
            totals = block
            return
        }
        let namesById = readProcessNames()
        var byName: [String: ProcessUsage] = [:]
        for (label, delta) in block {
            let total = totals[label] ?? (0, 0)
            totals[label] = (total.received + delta.received, total.sent + delta.sent)
            let name = namesById[label.split(separator: ".").last.map(String.init) ?? ""] ?? label
            var usage = byName[name] ?? ProcessUsage(name: name)
            usage.receivedBytesPerSecond += delta.received
            usage.sentBytesPerSecond += delta.sent
            usage.receivedBytesTotal += total.received + delta.received
            usage.sentBytesTotal += total.sent + delta.sent
            byName[name] = usage
        }
        let sample = byName.values.filter { $0.receivedBytesPerSecond + $0.sentBytesPerSecond > 0 }
        RunLoop.main.perform(inModes: [.common]) { [onSample] in onSample(Array(sample)) }
    }
}
