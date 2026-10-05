/// Ping item: two stacked lines refreshed once a second, the round-trip time to 8.8.8.8
/// above and the Wi-Fi signal quality in percent below. The ping is red when no reply arrived
/// or it exceeds SLOW_PING_MILLISECONDS; the signal is red below WEAK_SIGNAL_PERCENT or when
/// Wi-Fi is off. A tick is skipped while the previous ping waits for its reply.
import AppKit
import CoreWLAN

private let PING_HOST = "8.8.8.8"
private let PING_REFRESH_SECONDS = 1.0
private let SLOW_PING_MILLISECONDS = 150.0
private let WEAK_SIGNAL_PERCENT = 50

/// Pings PING_HOST once with a one-second timeout.
/// @returns Round-trip time in milliseconds, or nil when no reply arrived.
private func measurePing() -> Double? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/sbin/ping")
    process.arguments = ["-c", "1", "-t", "1", PING_HOST]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard let range = output.range(of: #"time=([0-9.]+)"#, options: .regularExpression) else { return nil }
    return Double(output[range].dropFirst(5))
}

/// Reads the Wi-Fi signal quality of the default interface as a percentage, mapping RSSI
/// linearly from -100 dBm (0%) to -50 dBm (100%), the usual scale of network tools.
/// @returns Quality 0...100, or nil when Wi-Fi is off or not associated (RSSI 0).
private func readSignalPercent() -> Int? {
    guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
    let rssi = interface.rssiValue()
    return rssi == 0 ? nil : min(max(2 * (rssi + 100), 0), 100)
}

private var pingItem: NSStatusItem?

/// Adds the ping and Wi-Fi signal item to the menu bar and starts measuring.
func startPing() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "capybarPing"
    item.menu = makeQuitMenu(header: "Ping \(PING_HOST): red when lost or over \(Int(SLOW_PING_MILLISECONDS)) ms; Wi-Fi: red below \(WEAK_SIGNAL_PERCENT)%")
    pingItem = item
    var pingInFlight = false
    Timer.scheduledTimer(withTimeInterval: PING_REFRESH_SECONDS, repeats: true) { _ in
        guard !pingInFlight else { return }
        pingInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let milliseconds = measurePing()
            DispatchQueue.main.async {
                let signal = readSignalPercent()
                item.button?.image = makeTwoLineImage(
                    top: milliseconds.map { "\(Int($0.rounded())) ms" } ?? "— ms",
                    topCritical: milliseconds.map { $0 > SLOW_PING_MILLISECONDS } ?? true,
                    bottom: signal.map { "\($0)%" } ?? "—%",
                    bottomCritical: signal.map { $0 < WEAK_SIGNAL_PERCENT } ?? true,
                    widest: "150 ms",
                    foreground: labelColor(of: item)
                )
                pingInFlight = false
            }
        }
    }.fire()
}
