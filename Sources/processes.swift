/// Per-process sampling for the drop-down menus of the CPU and RAM item and the network item
/// (`ps`, a streaming `nettop`), and force quitting a group of processes.
import Foundation

private let PS_PATH = "/bin/ps"
private let NETTOP_PATH = "/usr/bin/nettop"
private let NETTOP_INTERVAL_SECONDS = 1
private let NETTOP_READ_BUFFER_BYTES = 16_384
private let PROCESS_USAGE_COLUMNS = ["-Aceo", "pid=,uid=,pcpu=,rss=,comm="]
private let PROCESS_NAME_COLUMNS = ["-Aco", "pid=,comm="]

/// Reads CPU percent (ps's recent average, 100% = one core), resident memory and owner of
/// every process, summed per process name. Blocks while `ps` runs.
/// @returns One entry per name, unsorted; empty when `ps` fails.
func readProcessUsage() -> [ProcessUsage] {
    parseProcessUsage(runCommand(PS_PATH, PROCESS_USAGE_COLUMNS).output, userId: getuid(), ownProcessId: getpid())
}

/// Reads every process's name. Blocks while `ps` runs. @returns Name by process id.
private func readProcessNames() -> [pid_t: String] {
    parseProcessNames(runCommand(PS_PATH, PROCESS_NAME_COLUMNS).output)
}

/// Sends SIGKILL, the way Activity Monitor's Force Quit does, to each process that still
/// carries the name it had when the cross was pressed; an id that has exited or been reused by
/// another program is skipped. Runs off the main thread.
/// @param processIds Ids captured at the press. @param name Their name then.
/// @param completion Runs on the main thread once the signals are sent.
func forceQuit(_ processIds: [pid_t], named name: String, completion: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        for processId in processesStillNamed(name, among: processIds, currentNames: readProcessNames()) where kill(processId, SIGKILL) != 0 {
            logFailure("force quit of \(name) (\(processId)) refused: \(String(cString: strerror(errno)))")
        }
        performOnMain(completion)
    }
}

/// Streams per-process traffic from one long-running `nettop` in delta mode while a menu is
/// open. `nettop` prints a sample per second but buffers its output unless it writes to a
/// terminal, so it runs on a pseudo-terminal. The process, its reader and the parser live on one
/// serial queue; every start opens a new session, and a sample reaches the menu only while its
/// session is still the one the menu started.
final class NetworkSampler: @unchecked Sendable {
    private let onSample: @MainActor @Sendable ([ProcessUsage]) -> Void
    private let queue = DispatchQueue(label: "\(BUNDLE_IDENTIFIER).nettop")
    @MainActor private var sessionCount = 0
    @MainActor private var deliveringSession: Int?
    // Confined to `queue`.
    private var process: Process?
    private var reader: DispatchSourceRead?
    private var parser = NettopParser()
    private var runningSession = 0

    /// @param onSample Receives on the main thread the processes that moved traffic during the last second, unsorted.
    init(onSample: @escaping @MainActor @Sendable ([ProcessUsage]) -> Void) {
        self.onSample = onSample
    }

    /// Opens a session: starts `nettop` unless it already runs.
    @MainActor func start() {
        sessionCount += 1
        let session = sessionCount
        deliveringSession = session
        queue.async { self.startOnQueue(session) }
    }

    /// Closes the session and stops `nettop`; samples still in flight are dropped.
    @MainActor func stop() {
        deliveringSession = nil
        queue.async { self.stopOnQueue() }
    }

    private func startOnQueue(_ session: Int) {
        runningSession = session
        guard process == nil else { return }
        var primary: Int32 = 0, secondary: Int32 = 0
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { return logFailure("nettop pseudo-terminal failed: \(String(cString: strerror(errno)))") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: NETTOP_PATH)
        process.arguments = ["-P", "-L", "0", "-s", "\(NETTOP_INTERVAL_SECONDS)", "-d", "-x", "-J", "bytes_in,bytes_out"]
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        process.standardOutput = secondaryHandle
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            guard let self else { return }
            let endedProcess = ObjectIdentifier(ended)
            self.queue.async { if self.process.map(ObjectIdentifier.init) == endedProcess { self.stopOnQueue() } }
        }
        do { try process.run() } catch {
            close(primary)
            return logFailure("nettop did not start: \(error.localizedDescription)")
        }
        try? secondaryHandle.close()
        let reader = DispatchSource.makeReadSource(fileDescriptor: primary, queue: queue)
        reader.setEventHandler { [weak self] in self?.read(primary) }
        reader.setCancelHandler { close(primary) }
        reader.resume()
        parser = NettopParser()
        self.process = process
        self.reader = reader
    }

    private func stopOnQueue() {
        reader?.cancel()
        reader = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    /// Reads what `nettop` wrote and hands every finished sample to the menu.
    private func read(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: NETTOP_READ_BUFFER_BYTES)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return stopOnQueue() }
        let samples = parser.consume(String(decoding: buffer[..<count], as: UTF8.self))
        guard !samples.isEmpty else { return }
        let namesById = readProcessNames(), session = runningSession
        for sample in samples {
            let usage = groupTraffic(sample, namesById: namesById)
            performOnMain { [weak self, onSample] in
                if self?.deliveringSession == session { onSample(usage) }
            }
        }
    }
}
