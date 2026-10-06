/// Child processes and failure reports: one runner that waits for a command, one launcher that
/// does not, and the unified log every failure goes to (subsystem BUNDLE_IDENTIFIER; read it
/// with `log show --predicate 'subsystem == "com.illinifellow.capybar"'`).
import Foundation
import os

/// capybar's identifier: the launch agent's label, the code signature's identifier and the
/// log subsystem.
let BUNDLE_IDENTIFIER = "com.illinifellow.capybar"

private let LOG = Logger(subsystem: BUNDLE_IDENTIFIER, category: "capybar")
private let reportedFailures = OSAllocatedUnfairLock(initialState: Set<String>())

/// Records a failure in the unified log at error level, which macOS keeps on disk.
/// @param message What failed, with the values that explain it.
func logFailure(_ message: String) {
    LOG.error("\(message, privacy: .public)")
}

/// Records a failure once per key for the life of the process, for failures that would
/// otherwise repeat every second.
/// @param key Identifies the failure (what failed and on which device). @param message What failed.
func logFailureOnce(key: String, _ message: String) {
    if reportedFailures.withLock({ $0.insert(key).inserted }) { logFailure(message) }
}

/// What a finished command returned.
struct CommandResult: Sendable {
    /// Exit status; -1 when the command could not start.
    var status: Int32
    /// Standard output (with standard error when asked), or why the command could not start.
    var output: String

    var succeeded: Bool { status == 0 }
}

/// Runs a command to completion. Output is read to its end before waiting, so a command that
/// fills the pipe cannot stall. Blocks the calling thread.
/// @param path Absolute path of the executable. @param arguments Its arguments.
/// @param includeErrors Appends standard error to the output when true; discards it otherwise.
/// @returns Exit status and output.
@discardableResult
func runCommand(_ path: String, _ arguments: [String], includeErrors: Bool = false) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = includeErrors ? pipe : FileHandle.nullDevice
    do { try process.run() } catch { return CommandResult(status: -1, output: "\(path) did not start: \(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

/// Starts a command without waiting for it; a failure to start is logged.
/// @param path Absolute path of the executable. @param arguments Its arguments.
/// @param onExit Receives the exit status on a background thread; nil ignores it.
func launchCommand(_ path: String, _ arguments: [String], onExit: (@Sendable (Int32) -> Void)? = nil) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    if let onExit { process.terminationHandler = { onExit($0.terminationStatus) } }
    do { try process.run() } catch { logFailure("\(path) did not start: \(error.localizedDescription)") }
}

/// Starts a command in a session of its own and waits for it, so it outlives capybar when
/// launchd stops capybar's job (launchd ends the job's whole process group, not other sessions).
/// Standard output and error go to a file. Blocks the calling thread.
/// @param path Absolute path of the executable. @param arguments Its arguments. @param outputPath File that receives the output.
/// @returns The exit status (-1 when it could not start or was ended by a signal) and the output file's text.
func runCommandInOwnSession(_ path: String, _ arguments: [String], outputPath: String) -> CommandResult {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var processId: pid_t = 0
    let spawned = posix_spawn(&processId, path, &actions, &attributes, argv, environ)
    guard spawned == 0 else { return CommandResult(status: -1, output: "\(path) did not start: \(String(cString: strerror(spawned)))") }
    var status: Int32 = 0
    while waitpid(processId, &status, 0) == -1 && errno == EINTR {}
    let output = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
    // The wait status packs the signal that ended the process in its low 7 bits and the exit
    // status in the next byte (WIFEXITED and WEXITSTATUS, which Swift does not import).
    let exitedNormally = status & 0x7F == 0
    return CommandResult(status: exitedNormally ? (status >> 8) & 0xFF : -1, output: output)
}
