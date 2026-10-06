/// Network item: upload above download throughput every 500 ms, arrows left of the
/// numbers, counting physical interfaces (`en*`) only so VPN tunnels are not counted twice.
/// Clicking shows the processes moving the most traffic.
import AppKit

private let NETWORK_REFRESH_SECONDS = 0.5

/// Sums received and sent bytes over every `en*` interface.
/// @returns Total (received, sent) byte counters; 32-bit counters per interface, wrap handled by the caller.
private func readCounters() -> (received: UInt64, sent: UInt64) {
    var received: UInt64 = 0, sent: UInt64 = 0
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
    defer { freeifaddrs(list) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let entry = pointer.pointee
        guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: entry.ifa_name).hasPrefix("en"),
              let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
        received += UInt64(data.ifi_ibytes)
        sent += UInt64(data.ifi_obytes)
    }
    return (received, sent)
}

/// Formats bytes per second as "12.3 KB/s" with one decimal below 100 and none above.
/// @param bytesPerSecond Throughput; negative values (counter wrap or reset) show as 0.
/// @returns The formatted rate.
func formatRate(_ bytesPerSecond: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = max(bytesPerSecond, 0), unitIndex = 0
    while value >= 1000 && unitIndex < units.count - 1 { value /= 1000; unitIndex += 1 }
    return value >= 100 || unitIndex == 0 ? "\(Int(value.rounded())) \(units[unitIndex])" : String(format: "%.1f %@", value, units[unitIndex])
}

private var networkItem: NSStatusItem?

/// The drop-down: the processes moving the most traffic, each with its download and upload rate
/// over the last second and the bytes it has received and sent in all. A streaming `nettop`
/// runs only while the menu is open and refreshes the rows in place every second; the menu
/// opens with the rows it last showed.
private final class NetworkMenuDelegate: NSObject, NSMenuDelegate {
    private var section: MenuSection?
    private var lastSample: [ProcessUsage] = []
    private lazy var sampler = NetworkSampler { [weak self] usage in
        self?.lastSample = usage
        self?.show(usage)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        section = MenuSection(in: menu, title: "Traffic by process", columns: ["↓ Now", "↑ Now", "↓ Total", "↑ Total"], folds: true)
        appendQuit(to: menu)
        show(lastSample)
    }

    func menuWillOpen(_ menu: NSMenu) { sampler.start() }

    func menuDidClose(_ menu: NSMenu) { sampler.stop() }

    private func show(_ usage: [ProcessUsage]) {
        section?.update(usage.sorted { $0.receivedBytesPerSecond + $0.sentBytesPerSecond > $1.receivedBytesPerSecond + $1.sentBytesPerSecond }.map {
            MenuRow(name: $0.name, values: [formatRate($0.receivedBytesPerSecond), formatRate($0.sentBytesPerSecond),
                                           formatBytes($0.receivedBytesTotal), formatBytes($0.sentBytesTotal)])
        })
    }
}

private let networkMenuDelegate = NetworkMenuDelegate()

/// Adds the network item to the menu bar and starts measuring; its drop-down lists the
/// processes moving the most traffic.
func startNetwork() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "capybarNetwork"
    let menu = NSMenu()
    menu.delegate = networkMenuDelegate
    item.menu = menu
    networkItem = item
    var previous = readCounters()
    var previousTime = Date()
    showTwoLines(on: item, top: "↑ 0 B/s", bottom: "↓ 0 B/s", widest: "↑ 999.9 MB/s")
    scheduleRepeatingTimer(every: NETWORK_REFRESH_SECONDS) { _ in
        let current = readCounters(), now = Date()
        let seconds = max(now.timeIntervalSince(previousTime), 0.001)
        let received = current.received >= previous.received ? Double(current.received - previous.received) : 0
        let sent = current.sent >= previous.sent ? Double(current.sent - previous.sent) : 0
        showTwoLines(on: item, top: "↑ " + formatRate(sent / seconds), bottom: "↓ " + formatRate(received / seconds), widest: "↑ 999.9 MB/s")
        previous = current
        previousTime = now
    }
}
