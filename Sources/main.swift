/// capybar: one menu bar program with four status items, left to right CPU and RAM, network,
/// ping, microphone (the item created first sits rightmost), and the capybara over the Control
/// Center icon. It also owns the screenshot hotkeys Cmd+\ and Cmd+Shift+\, the microphone key
/// and the moon key (remapped to F5 and F6 for the session), and offers its own update when a
/// newer release exists. Installed by install.sh as the launchd agent BUNDLE_IDENTIFIER.
///
/// Arguments: `--version` prints the version; `--focus-claude-code` does what a click on the
/// capybara does; `--remove-key-remaps` takes the key remaps out (uninstall.sh). Each exits.
import AppKit

private let ARGUMENT_ACTIONS: [String: () -> Void] = [
    "--version": { print(CAPYBAR_VERSION) },
    "--focus-claude-code": { focusClaudeCode(command: claudeCodeCommand()) },
    "--remove-key-remaps": { removeSpecialKeyRemaps() },
]

/// Delivers SIGTERM on the main queue once the default action is ignored.
private let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

if let argument = CommandLine.arguments.dropFirst().first {
    guard let action = ARGUMENT_ACTIONS[argument] else {
        FileHandle.standardError.write(Data("unknown argument \(argument); known: \(ARGUMENT_ACTIONS.keys.sorted().joined(separator: ", "))\n".utf8))
        exit(EXIT_FAILURE)
    }
    action()
    exit(EXIT_SUCCESS)
}

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    applySpecialKeyRemaps()
    // The remaps belong to the running capybar: Quit takes them out, and so does SIGTERM
    // (logout, `launchctl bootout`), which is routed through the same orderly termination.
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in removeSpecialKeyRemaps() }
    signal(SIGTERM, SIG_IGN)
    terminationSignal.setEventHandler { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
    terminationSignal.resume()
    startMicrophone()
    startCapybara()
    startPing()
    startNetwork()
    startSystemLoad()
    startScreenshotHotkeys()
    startFocusKey()
    Updater.start()
    application.run()
}
