/// Self-update: asks GitHub at start and every UPDATE_CHECK_INTERVAL_SECONDS for the latest
/// release; when it is newer than CAPYBAR_VERSION every menu offers "Update to X.Y.Z" above Quit.
/// The update downloads the tag's source, builds it with `swiftc` beside the installed binary,
/// signs it as install.sh does, swaps it in and restarts the launchd agent. Any failure leaves
/// the old binary in place and says what went wrong in an alert.
import AppKit

let CAPYBAR_VERSION = "0.1.0"
private let REPOSITORY = "illinifellow/capybar"
private let LATEST_RELEASE_URL = URL(string: "https://api.github.com/repos/\(REPOSITORY)/releases/latest")!
private let UPDATE_CHECK_INTERVAL_SECONDS = 6.0 * 60 * 60
private let UPDATE_REQUEST_TIMEOUT_SECONDS = 30.0
private let AGENT_LABEL = "com.illinifellow.capybar"
private let SIGNING_IDENTITY_NAME = "capybar local signing"

/// Compares dotted versions numerically ("0.10.0" > "0.9.1").
/// @param candidate Version to test. @param current Version in use.
/// @returns True when `candidate` is newer.
private func isNewer(_ candidate: String, than current: String) -> Bool {
    let left = candidate.split(separator: ".").map { Int($0) ?? 0 }, right = current.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
        let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0
        if a != b { return a > b }
    }
    return false
}

/// An update failure with the step that failed and what it printed.
private struct UpdateError: Error {
    var step: String
    var detail: String
}

/// Runs a command to completion.
/// @param path Executable. @param arguments Its arguments. @param step Name of the step for the error.
/// @returns Standard output. @throws UpdateError with the tail of the combined output when the command fails.
@discardableResult
private func run(_ path: String, _ arguments: [String], step: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { throw UpdateError(step: step, detail: "\(path) did not start: \(error.localizedDescription)") }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UpdateError(step: step, detail: "exit \(process.terminationStatus)\n" + output.split(separator: "\n").suffix(12).joined(separator: "\n"))
    }
    return output
}

/// Watches GitHub for a newer release and performs the update.
enum Updater {
    /// The newer release's version, nil while capybar is current or the check failed.
    private(set) static var availableVersion: String?
    /// True while an update downloads and builds.
    private(set) static var isUpdating = false
    private static let target = UpdateTarget()

    /// Checks now and every UPDATE_CHECK_INTERVAL_SECONDS.
    static func start() {
        check()
        Timer.scheduledTimer(withTimeInterval: UPDATE_CHECK_INTERVAL_SECONDS, repeats: true) { _ in check() }
    }

    /// Reads the latest release's tag; a failed request keeps the previous answer.
    private static func check() {
        var request = URLRequest(url: LATEST_RELEASE_URL)
        request.timeoutInterval = UPDATE_REQUEST_TIMEOUT_SECONDS
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = release["tag_name"] as? String else { return }
            RunLoop.main.perform(inModes: [.common]) { availableVersion = isNewer(tag, than: CAPYBAR_VERSION) ? tag : nil }
        }.resume()
    }

    /// The menu entry offering the update, nil when there is none.
    static func makeMenuItem() -> NSMenuItem? {
        guard let version = availableVersion else { return nil }
        let item = NSMenuItem(title: isUpdating ? "Updating to \(version)…" : "Update to \(version)", action: isUpdating ? nil : #selector(UpdateTarget.update), keyEquivalent: "")
        item.target = target
        return item
    }

    /// Downloads, builds and installs `version`, then restarts the agent; on failure shows an alert.
    fileprivate static func perform(_ version: String) {
        isUpdating = true
        DispatchQueue.global(qos: .userInitiated).async {
            func report(_ error: Error, installed: Bool) {
                let failure = error as? UpdateError ?? UpdateError(step: "Updating", detail: error.localizedDescription)
                RunLoop.main.perform(inModes: [.common]) { fail(version, failure, installed: installed) }
            }
            do { try install(version) } catch { return report(error, installed: false) }
            do { try run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(AGENT_LABEL)"], step: "Restarting the launch agent") } catch { report(error, installed: true) }
        }
    }

    /// Builds `version` from its source tarball into a temporary binary and moves it over the
    /// running one only after the build and signing succeeded.
    private static func install(_ version: String) throws {
        let binary = Bundle.main.executableURL!.resolvingSymlinksInPath()
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("capybar-update-\(version)")
        try? FileManager.default.removeItem(at: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tarball = workspace.appendingPathComponent("source.tar.gz")
        try run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--location", "--max-time", "120", "-o", tarball.path,
                                  "https://github.com/\(REPOSITORY)/archive/refs/tags/\(version).tar.gz"], step: "Downloading \(version)")
        try run("/usr/bin/tar", ["-xzf", tarball.path, "-C", workspace.path, "--strip-components", "1"], step: "Unpacking \(version)")
        let sources = try FileManager.default.contentsOfDirectory(atPath: workspace.appendingPathComponent("Sources").path)
            .filter { $0.hasSuffix(".swift") }.map { workspace.appendingPathComponent("Sources").appendingPathComponent($0).path }
        let built = binary.deletingLastPathComponent().appendingPathComponent(".capybar-\(version)")
        try run("/usr/bin/swiftc", ["-O"] + sources + ["-o", built.path], step: "Building \(version)")
        let identities = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], step: "Looking up the signing identity")
        if let line = identities.split(separator: "\n").first(where: { $0.contains("\"\(SIGNING_IDENTITY_NAME)\"") }),
           let identity = line.split(separator: " ").dropFirst().first {
            try run("/usr/bin/codesign", ["--force", "--sign", String(identity), "--identifier", AGENT_LABEL, built.path], step: "Signing \(version)")
        }
        guard rename(built.path, binary.path) == 0 else {
            try? FileManager.default.removeItem(at: built)
            throw UpdateError(step: "Replacing \(binary.path)", detail: String(cString: strerror(errno)))
        }
    }

    /// Reports a failed update in an alert.
    /// @param version Target version. @param error What failed. @param installed True when the new binary is in place and only the restart failed.
    private static func fail(_ version: String, _ error: UpdateError, installed: Bool = false) {
        isUpdating = false
        if installed { availableVersion = nil }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = installed ? "capybar \(version) is installed but did not restart" : "capybar could not update to \(version)"
        alert.informativeText = installed
            ? "\(error.step) failed; quit capybar and run it again to start \(version).\n\n\(error.detail)"
            : "\(error.step) failed. The installed capybar is unchanged.\n\n\(error.detail)"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Receives the menu entry's action.
private final class UpdateTarget: NSObject {
    @objc func update() {
        if let version = Updater.availableVersion, !Updater.isUpdating { Updater.perform(version) }
    }
}
