/// Self-update: asks GitHub at start and every UPDATE_CHECK_INTERVAL_SECONDS for the latest
/// release; when it is newer than CAPYBAR_VERSION every menu offers "Update to X.Y.Z" above Quit.
/// The update downloads the release's source and runs that release's own `install.sh` in a
/// session of its own (so it survives launchd stopping capybar), asking it to install exactly
/// that version: one routine builds, signs, replaces the binary atomically, rewrites the launch
/// agent and restarts it. Any failure before the restart leaves the old binary in place and
/// says in an alert which step failed.
import AppKit

private let REPOSITORY = "illinifellow/capybar"
private let LATEST_RELEASE_URL = URL(string: "https://api.github.com/repos/\(REPOSITORY)/releases/latest")!
private let UPDATE_CHECK_INTERVAL_SECONDS = 6.0 * 60 * 60
private let UPDATE_REQUEST_TIMEOUT_SECONDS = 30.0
private let UPDATE_DOWNLOAD_TIMEOUT_SECONDS = 120.0
private let UPDATE_WORKSPACE_PREFIX = "capybar-update-"
private let TAR_PATH = "/usr/bin/tar"
private let BASH_PATH = "/bin/bash"
private let INSTALL_SCRIPT = "install.sh"
private let INSTALL_LOG = "install.log"
private let SOURCE_ARCHIVE = "source.tar.gz"
private let FAILURE_DETAIL_LINES = 12

/// Where an update unpacks and builds: the per-user temporary directory, which macOS clears.
private func updateWorkspace(_ version: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UPDATE_WORKSPACE_PREFIX + version)
}

/// An update failure with the step that failed and what it printed.
private struct UpdateError: Error {
    var step: String
    var detail: String
}

/// Watches GitHub for a newer release and performs the update.
@MainActor enum Updater {
    /// The newer release's version, nil while capybar is current or the check failed.
    private(set) static var availableVersion: String?
    /// True while an update downloads and builds.
    private(set) static var isUpdating = false
    private static let target = UpdateTarget()

    /// Removes what an earlier update left behind, then checks now and every UPDATE_CHECK_INTERVAL_SECONDS.
    static func start() {
        let temporary = FileManager.default.temporaryDirectory
        for leftover in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where leftover.hasPrefix(UPDATE_WORKSPACE_PREFIX) {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(leftover))
        }
        check()
        scheduleRepeatingTimer(every: UPDATE_CHECK_INTERVAL_SECONDS) { check() }
    }

    /// Reads the latest release's tag; a failed request keeps the previous answer, and a tag that
    /// is not a plain dotted version is ignored.
    private static func check() {
        var request = URLRequest(url: LATEST_RELEASE_URL)
        request.timeoutInterval = UPDATE_REQUEST_TIMEOUT_SECONDS
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = release["tag_name"] as? String, isReleaseVersion(tag) else { return }
            performOnMain { availableVersion = isNewer(tag, than: CAPYBAR_VERSION) ? tag : nil }
        }.resume()
    }

    /// The menu entry offering the update, nil when there is none.
    static func makeMenuItem() -> NSMenuItem? {
        guard let version = availableVersion else { return nil }
        let item = NSMenuItem(title: isUpdating ? "Updating to \(version)…" : "Update to \(version)", action: isUpdating ? nil : #selector(UpdateTarget.update), keyEquivalent: "")
        item.target = target
        return item
    }

    /// Downloads and installs `version` off the main thread. On success `install.sh` restarts the
    /// launch agent, which ends this process; on failure an alert says why.
    fileprivate static func perform(_ version: String) {
        isUpdating = true
        let source = URL(string: "https://github.com/\(REPOSITORY)/archive/refs/tags/\(version).tar.gz")!
        var request = URLRequest(url: source)
        request.timeoutInterval = UPDATE_DOWNLOAD_TIMEOUT_SECONDS
        URLSession.shared.downloadTask(with: request) { download, response, error in
            // The downloaded file is deleted when this handler returns, so it moves first.
            let workspace = updateWorkspace(version), tarball = workspace.appendingPathComponent(SOURCE_ARCHIVE)
            let moved = Result<Void, Error> {
                guard let download, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError(step: "Downloading \(version)", detail: (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? error?.localizedDescription ?? "no response")
                }
                try? FileManager.default.removeItem(at: workspace)
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: download, to: tarball)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try moved.get()
                    try install(version, in: workspace, from: tarball)
                } catch {
                    let failure = error as? UpdateError ?? UpdateError(step: "Preparing \(workspace.path)", detail: error.localizedDescription)
                    performOnMain { fail(version, failure) }
                }
            }
        }.resume()
    }

    /// Unpacks the source and runs its `install.sh` for exactly `version`. Runs off the main
    /// thread; returns only by throwing, since a successful script restarts capybar.
    /// @param version The release. @param workspace Directory to unpack into. @param tarball The source archive inside it.
    /// @throws UpdateError naming the step that failed, with the end of its output.
    nonisolated private static func install(_ version: String, in workspace: URL, from tarball: URL) throws {
        let unpacked = runCommand(TAR_PATH, ["-xzf", tarball.path, "-C", workspace.path, "--strip-components", "1"], includeErrors: true)
        guard unpacked.succeeded else { throw UpdateError(step: "Unpacking \(version)", detail: unpacked.output) }
        let script = workspace.appendingPathComponent(INSTALL_SCRIPT).path
        let installed = runCommandInOwnSession(BASH_PATH, [script, version], outputPath: workspace.appendingPathComponent(INSTALL_LOG).path)
        let detail = "exit \(installed.status)\n" + installed.output.split(separator: "\n").suffix(FAILURE_DETAIL_LINES).joined(separator: "\n")
        throw UpdateError(step: "Running \(version)'s \(INSTALL_SCRIPT)", detail: detail)
    }

    /// Reports a failed update in an alert.
    /// @param version Target version. @param error What failed.
    private static func fail(_ version: String, _ error: UpdateError) {
        isUpdating = false
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "capybar could not update to \(version)"
        alert.informativeText = "\(error.step) failed. The installed capybar is unchanged.\n\n\(error.detail)"
        NSApp.activate()
        alert.runModal()
    }
}

/// Receives the menu entry's action.
@MainActor private final class UpdateTarget: NSObject {
    @objc func update() {
        if let version = Updater.availableVersion, !Updater.isUpdating { Updater.perform(version) }
    }
}
