/// The capybara's errand: a click brings forward the iTerm2 session in which Claude Code runs,
/// recognised by a process whose executable is named CLAUDE_CODE_PROCESS_NAME on the session's
/// terminal; with none, it opens a new iTerm2 window and types the command kept in the defaults
/// key CLAUDE_CODE_COMMAND_KEY (`defaults write capybar claudeCodeCommand "…"`), `claude` when
/// unset. Without iTerm2 installed a click does nothing. iTerm2 is driven through `osascript`
/// off the main thread, one errand at a time; the first one makes macOS ask whether capybar may
/// control iTerm2.
import AppKit

private let ITERM_BUNDLE_IDENTIFIER = "com.googlecode.iterm2"
private let CLAUDE_CODE_PROCESS_NAME = "claude"
private let CLAUDE_CODE_COMMAND_KEY = "claudeCodeCommand"
private let DEFAULT_CLAUDE_CODE_COMMAND = "claude"
private let OSASCRIPT_PATH = "/usr/bin/osascript"
private let PS_PATH = "/bin/ps"
private let DEVICE_DIRECTORY = "/dev/"
/// How `osascript` separates the items of a list it prints.
private let OSASCRIPT_LIST_SEPARATOR = ", "
private let focusQueue = DispatchQueue(label: "\(BUNDLE_IDENTIFIER).claudecode")
@MainActor private var focusInFlight = false

/// Writes text as an AppleScript string literal.
/// @param text Any text. @returns The text in double quotes, backslashes and quotes escaped.
func appleScriptStringLiteral(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Finds the first terminal, in iTerm2's order, on which Claude Code runs.
/// @param terminals Session terminals as iTerm2 reports them ("/dev/ttys004").
/// @param processes Output of `ps -A -o tty=,comm=`. @param processName Executable name of Claude Code.
/// @returns The terminal as iTerm2 reported it; nil when none runs it.
func claudeCodeTerminal(among terminals: [String], processes: String, processName: String) -> String? {
    var running: Set<String> = []
    for line in processes.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard fields.count == 2 else { continue }
        let executable = fields[1].trimmingCharacters(in: .whitespaces).split(separator: "/").last.map(String.init)
        if executable == processName { running.insert(String(fields[0])) }
    }
    return terminals.first { running.contains($0.replacingOccurrences(of: DEVICE_DIRECTORY, with: "")) }
}

/// Runs AppleScript through `osascript`. Blocks while it runs; a failure is logged.
/// @param source The script. @returns What the script returned, as `osascript` prints it; nil on failure.
private func runAppleScript(_ source: String) -> String? {
    let result = runCommand(OSASCRIPT_PATH, ["-e", source], includeErrors: true)
    guard result.succeeded else {
        logFailure("AppleScript for iTerm2 failed: exit \(result.status), \(result.output)")
        return nil
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Brings Claude Code forward in iTerm2, or starts it in a new window. Blocks while iTerm2
/// answers, so it runs off the main thread except for `capybar --focus-claude-code`.
/// @param command What to type into a new window when no session runs Claude Code.
func focusClaudeCode(command: String) {
    let iTerm = appleScriptStringLiteral(ITERM_BUNDLE_IDENTIFIER)
    let listing = runAppleScript("""
        if application id \(iTerm) is not running then return ""
        tell application id \(iTerm) to return tty of sessions of tabs of windows
        """) ?? ""
    let terminals = listing.components(separatedBy: OSASCRIPT_LIST_SEPARATOR).filter { !$0.isEmpty }
    let processes = runCommand(PS_PATH, ["-A", "-o", "tty=,comm="]).output
    if let terminal = claudeCodeTerminal(among: terminals, processes: processes, processName: CLAUDE_CODE_PROCESS_NAME) {
        _ = runAppleScript("""
            tell application id \(iTerm)
                activate
                repeat with candidateWindow in windows
                    repeat with candidateTab in tabs of candidateWindow
                        repeat with candidateSession in sessions of candidateTab
                            if tty of candidateSession is \(appleScriptStringLiteral(terminal)) then
                                select candidateWindow
                                tell candidateTab to select
                                tell candidateSession to select
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
    } else {
        _ = runAppleScript("""
            tell application id \(iTerm)
                activate
                set claudeWindow to (create window with default profile)
                tell current session of claudeWindow to write text \(appleScriptStringLiteral(command))
            end tell
            """)
    }
}

/// The command typed into a new window: the defaults value, or DEFAULT_CLAUDE_CODE_COMMAND.
func claudeCodeCommand() -> String {
    UserDefaults.standard.string(forKey: CLAUDE_CODE_COMMAND_KEY).flatMap { $0.isEmpty ? nil : $0 } ?? DEFAULT_CLAUDE_CODE_COMMAND
}

/// Whether iTerm2 is installed; logged once when it is not.
@MainActor func isITermInstalled() -> Bool {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: ITERM_BUNDLE_IDENTIFIER) != nil else {
        logFailureOnce(key: "iterm missing", "iTerm2 (\(ITERM_BUNDLE_IDENTIFIER)) is not installed; the capybara's click does nothing")
        return false
    }
    return true
}

/// Answers a click on the capybara: focuses Claude Code on a background queue unless iTerm2 is
/// missing or the previous click is still being answered.
@MainActor func requestClaudeCodeFocus() {
    guard !focusInFlight, isITermInstalled() else { return }
    focusInFlight = true
    let command = claudeCodeCommand()
    focusQueue.async {
        focusClaudeCode(command: command)
        performOnMain { focusInFlight = false }
    }
}
