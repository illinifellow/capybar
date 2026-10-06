/// Tests of capybar's pure logic, built as a plain executable together with every source file
/// except `Sources/main.swift` and run by CI:
///
///     swiftc $(ls Sources/*.swift | grep -v main.swift) Tests/main.swift -o .build/tests && .build/tests
///
/// Each check pins a behaviour whose failure the user would see: a microphone that lies or
/// cannot be unmuted, a CPU or network reading that jumps after a counter wraps, a ping
/// answered by someone else's reply, a menu that announces rows it does not hold, an update
/// offered forever, or the user's own key remaps lost. Prints every failure and exits non-zero
/// when there is one.
import Foundation

/// The checks made so far and the ones that failed.
struct Results {
    private(set) var checks = 0
    private(set) var failures = 0

    /// Records one expectation. @param condition What must hold. @param description What it means, printed on failure.
    mutating func expect(_ condition: Bool, _ description: String, line: Int = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("FAILED (line \(line)): \(description)")
        }
    }
}

var results = Results()

// MARK: Microphone control
// A device whose mute switch exists but is read-only must be read and written through its
// volume (0.1.0 read the switch and wrote the volume: the icon lied and the key could not unmute).

let readOnlyMute = InputElementControls(element: 0, hasMute: true, muteSettable: false, hasVolume: true, volumeSettable: true)
results.expect(chooseMicrophoneControl(main: readOnlyMute, channels: []) == .volume(elements: [0]),
               "a read-only mute switch is skipped for a settable volume")
let settableMute = InputElementControls(element: 0, hasMute: true, muteSettable: true, hasVolume: true, volumeSettable: true)
results.expect(chooseMicrophoneControl(main: settableMute, channels: []) == .mute(elements: [0]), "a settable mute switch on the main element wins")
let bareMain = InputElementControls(element: 0)
let channelMutes = [InputElementControls(element: 1, hasMute: true, muteSettable: true), InputElementControls(element: 2, hasMute: true, muteSettable: true)]
results.expect(chooseMicrophoneControl(main: bareMain, channels: channelMutes) == .mute(elements: [1, 2]), "per-channel mute switches are used when the main element has none")
let channelVolumes = [InputElementControls(element: 1, hasVolume: true, volumeSettable: true), InputElementControls(element: 2, hasVolume: true, volumeSettable: true)]
results.expect(chooseMicrophoneControl(main: bareMain, channels: channelVolumes) == .volume(elements: [1, 2]), "per-channel volumes are the last resort")
let mixedChannels = [InputElementControls(element: 1, hasMute: true, muteSettable: true), InputElementControls(element: 2, hasMute: true, muteSettable: false)]
results.expect(chooseMicrophoneControl(main: bareMain, channels: mixedChannels) == nil, "channels are used only when every one of them is settable")
results.expect(chooseMicrophoneControl(main: InputElementControls(element: 0, hasMute: true, hasVolume: true), channels: []) == nil,
               "a device with nothing settable has no control")
results.expect(isMuted(.volume(elements: [0]), readings: [0]), "volume 0 reads as muted")
results.expect(!isMuted(.volume(elements: [1, 2]), readings: [0, 0.4]), "one live channel means not muted")
results.expect(isMuted(.mute(elements: [1, 2]), readings: [1, 1]), "every switch on reads as muted")
results.expect(!isMuted(.mute(elements: [0]), readings: []), "an unreadable control does not claim muted")
results.expect(volumesToRestore(remembered: [0.3, 0.6], elementCount: 2, fallback: 0.75) == [0.3, 0.6], "unmute restores the remembered levels")
results.expect(volumesToRestore(remembered: nil, elementCount: 2, fallback: 0.75) == [0.75, 0.75], "unknown levels fall back")
results.expect(volumesToRestore(remembered: [0, 0], elementCount: 2, fallback: 0.75) == [0.75, 0.75], "remembered silence is not restored as silence")
results.expect(volumesToRestore(remembered: [0.5], elementCount: 2, fallback: 0.75) == [0.75, 0.75], "levels of another channel layout are not reused")

// MARK: Counters
// CPU ticks are 32-bit per state; a wrap must yield the true increment (0.1.0 showed 0% or 100%).

let beforeWrap = CpuTicks(user: UInt32.max - 4, system: 100, idle: UInt32.max - 9, nice: 0)
let afterWrap = CpuTicks(user: 5, system: 110, idle: 10, nice: 0)
results.expect(busyPercent(from: beforeWrap, to: afterWrap) == 50, "wrapped counters give 20 busy of 40 ticks: 50%")
results.expect(busyPercent(from: afterWrap, to: afterWrap) == nil, "no tick passed gives no reading")
let interfacesBefore = ["en0": InterfaceCounters(received: 1_000, sent: 500), "en1": InterfaceCounters(received: 70, sent: 7)]
let interfacesAfter = ["en0": InterfaceCounters(received: 1_600, sent: 900), "en1": InterfaceCounters(received: 10, sent: 7), "en5": InterfaceCounters(received: 9_999, sent: 9_999)]
results.expect(bytesMoved(from: interfacesBefore, to: interfacesAfter) == InterfaceCounters(received: 600, sent: 400),
               "a restarted interface counts 0 and a new one is skipped, the rest summed")

// MARK: Ping
// Only this ping's reply counts; the socket also receives other programs' replies.

let target: [UInt8] = [8, 8, 8, 8]
let request = makeEchoRequest(identifier: 0x1234, sequence: 7, payloadLength: 32)
results.expect(icmpChecksum(request) == 0, "a request carrying its checksum sums to 0")
results.expect(request.count == 40 && request[0] == 8, "an echo request is type 8 with its payload")
/// An IPv4 header of 20 bytes from `source`, then an ICMP message.
func datagram(source: [UInt8], type: UInt8, identifier: UInt16, sequence: UInt16) -> [UInt8] {
    let header: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 11) + source + [UInt8](repeating: 0, count: 4)
    let icmp: [UInt8] = [type, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xFF), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
    return header + icmp
}
results.expect(isEchoReply(datagram(source: target, type: 0, identifier: 0x1234, sequence: 7)[...], from: target, identifier: 0x1234, sequence: 7), "the matching reply counts")
results.expect(!isEchoReply(datagram(source: target, type: 0, identifier: 0x9999, sequence: 7)[...], from: target, identifier: 0x1234, sequence: 7),
               "another program's reply with the same sequence does not count")
results.expect(!isEchoReply(datagram(source: [1, 1, 1, 1], type: 0, identifier: 0x1234, sequence: 7)[...], from: target, identifier: 0x1234, sequence: 7),
               "a reply from another host does not count")
results.expect(!isEchoReply(datagram(source: target, type: 8, identifier: 0x1234, sequence: 7)[...], from: target, identifier: 0x1234, sequence: 7),
               "an echo request is not a reply")
results.expect(!isEchoReply([0x45, 0, 0][...], from: target, identifier: 0x1234, sequence: 7), "a truncated datagram does not count")
let halfSecond = socketTimeout(seconds: 0.5)
results.expect(halfSecond.tv_sec == 0 && halfSecond.tv_usec == 500_000, "0.5 s is a real timeout, not 0 (no timeout)")
let almostTwo = socketTimeout(seconds: 1.9999999)
results.expect(almostTwo.tv_sec == 2 && almostTwo.tv_usec == 0, "microseconds never reach a full second")
results.expect(signalPercent(rssi: -100) == 0 && signalPercent(rssi: -75) == 50 && signalPercent(rssi: -40) == 100, "RSSI maps linearly from -100 to -50 dBm")

// MARK: Processes and menus
// Rows group by name; only the user's own processes may be killed, never capybar or the session.

let psOutput = """
      1     0   0.0   12000 launchd
    100   501  12.5  204800 Safari
    101   501   7.5  102400 Safari
    102     0   3.0    1024 Safari
    200   501   0.0   40960 loginwindow
    300   501   1.0    2048 capybar
    garbage line
    """
let usage = Dictionary(uniqueKeysWithValues: parseProcessUsage(psOutput, userId: 501, ownProcessId: 300).map { ($0.name, $0) })
results.expect(usage["Safari"]?.cpuPercent == 23 && usage["Safari"]?.memoryBytes == 308_224 * 1024, "same-named processes are summed")
results.expect(usage["Safari"]?.killableProcessIds == [100, 101], "only the user's own processes are killable")
results.expect(usage["loginwindow"]?.killableProcessIds == [], "loginwindow is never killable")
results.expect(usage["capybar"]?.killableProcessIds == [], "capybar never offers to kill itself")
results.expect(usage.count == 4, "malformed lines are skipped")
let namesNow = parseProcessNames("  100 Safari\n  101 Mail\n")
results.expect(processesStillNamed("Safari", among: [100, 101, 102], currentNames: namesNow) == [100],
               "a force quit spares ids that exited or now belong to another program")
let folded = foldRows(Array(1...120), visibleCount: 5, foldedLimit: 40)
results.expect(folded.visible == [1, 2, 3, 4, 5] && folded.folded.count == 40 && folded.folded.first == 6, "More holds the 40 rows after the first 5")
results.expect(foldRows([1, 2, 3], visibleCount: 5, foldedLimit: 40).folded.isEmpty, "no More without rows to fold")

// MARK: nettop
// The first block is cumulative, later ones are deltas added to it.

var parser = NettopParser()
var samples = parser.consume(",bytes_in,bytes_out,\nSafari.100,1000,200,\nMail.200,50,5,\n,bytes_in,bytes_out,\nSafari.100,10,2,\nMa")
results.expect(samples.isEmpty, "the cumulative block produces no sample")
samples = parser.consume("il.200,0,0,\n,bytes_in,bytes_out,\n")
let safari = samples.first?.first { $0.label == "Safari.100" }
results.expect(samples.count == 1 && safari?.delta == Traffic(received: 10, sent: 2) && safari?.total == Traffic(received: 1010, sent: 202),
               "a delta block adds to the totals, across chunks split mid-line")
let traffic = groupTraffic(samples[0], namesById: [100: "Safari Networking", 200: "Mail"])
results.expect(traffic.count == 1 && traffic.first?.name == "Safari Networking", "names come from ps by id, and silent processes are dropped")

// MARK: Versions and formats

results.expect(isNewer("0.10.0", than: "0.9.1") && !isNewer("0.2.0", than: "0.2.0") && isNewer("1.0", than: "0.9.9") && !isNewer("0.2", than: "0.2.0"),
               "versions compare numerically, part by part")
results.expect(isReleaseVersion("0.2.0") && isReleaseVersion("10") && !isReleaseVersion("v0.2.0") && !isReleaseVersion("0.2.0-beta")
               && !isReleaseVersion("") && !isReleaseVersion("1..2") && !isReleaseVersion("../x"), "only dotted numbers are release versions")
results.expect(formatRate(999.6) == "1.0 KB/s" && formatRate(99_960) == "100 KB/s" && formatRate(12_345) == "12.3 KB/s" && formatRate(-5) == "0 B/s",
               "rates never exceed three digits and never go negative")
results.expect(WIDEST_RATE_TEXTS.contains("99.9 MB/s") && WIDEST_RATE_TEXTS.contains("999 GB/s"), "the widest rate texts cover every unit")
results.expect(string(fromNullTerminated: [101, 110, 48, 0, 120]) == "en0", "a C buffer ends at its first null")

// MARK: Key remaps
// The user's own mappings survive capybar's remaps, and only capybar's entries are removed.

let hidutilOutput = """
    (
            {
            HIDKeyboardModifierMappingDst = 30064771113;
            HIDKeyboardModifierMappingSrc = 30064771129;
        },
            {
            HIDKeyboardModifierMappingDst = 30064771134;
            HIDKeyboardModifierMappingSrc = 51539607759;
        }
    )
    """
let capsLockToEscape = KeyMapping(source: 30_064_771_129, destination: 30_064_771_113)
let parsed = parseKeyMappings(hidutilOutput)
results.expect(parsed == [capsLockToEscape, SPECIAL_KEY_REMAPS[0]], "hidutil's listing is read")
results.expect(parseKeyMappings("(null)\n") == [], "an unset mapping is empty")
results.expect(parseKeyMappings("(\n)\n") == [], "an emptied mapping is empty")
results.expect(parseKeyMappings("something unexpected") == nil, "an unreadable listing is refused, so nothing is overwritten")
results.expect(mergingRemaps(SPECIAL_KEY_REMAPS, into: parsed ?? []) == [capsLockToEscape] + SPECIAL_KEY_REMAPS, "merging keeps the user's entries once and adds capybar's")
results.expect(removingRemaps(SPECIAL_KEY_REMAPS, from: [capsLockToEscape] + SPECIAL_KEY_REMAPS) == [capsLockToEscape], "removing leaves the user's entries")
results.expect(keyMappingArgument([capsLockToEscape]) == "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771113}]}",
               "the mapping is written in the JSON hidutil takes")

// MARK: Claude Code

let processes = "ttys001  -zsh\nttys004  /Users/someone/.local/bin/claude\nttys005  notclaude\n??       claude\n"
results.expect(claudeCodeTerminal(among: ["/dev/ttys005", "/dev/ttys001", "/dev/ttys004"], processes: processes, processName: "claude") == "/dev/ttys004",
               "the session running an executable named claude is found, not one merely ending in it")
results.expect(claudeCodeTerminal(among: ["/dev/ttys001"], processes: processes, processName: "claude") == nil, "no session runs it")
results.expect(appleScriptStringLiteral("say \"hi\" \\ bye") == "\"say \\\"hi\\\" \\\\ bye\"", "commands are escaped for AppleScript")

print("\(results.checks - results.failures) of \(results.checks) checks passed")
exit(results.failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
