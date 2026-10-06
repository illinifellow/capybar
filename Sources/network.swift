/// Network item: upload above download throughput every 500 ms, arrows left of the numbers,
/// counting physical interfaces (`en*`) only so VPN tunnels are not counted twice. The byte
/// counters are the kernel's 64-bit ones (`NET_RT_IFLIST2`), which do not wrap. Clicking shows
/// the processes moving the most traffic.
import AppKit

private let NETWORK_REFRESH_SECONDS = 0.5
private let PHYSICAL_INTERFACE_PREFIX = "en"
private let NETWORK_AUTOSAVE_NAME = "capybarNetwork"
private let UPLOAD_ARROW = "↑", DOWNLOAD_ARROW = "↓"
private let NETWORK_WIDEST_TEXTS = [UPLOAD_ARROW, DOWNLOAD_ARROW].flatMap { arrow in WIDEST_RATE_TEXTS.map { "\(arrow) \($0)" } }
private let NO_RATE = "—"

/// Reads the byte counters of every `en*` interface from the kernel's interface list.
/// @returns Counters keyed by interface name; empty when the list cannot be read.
private func readCounters() -> [String: InterfaceCounters] {
    var request: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var length = 0
    guard sysctl(&request, UInt32(request.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&request, UInt32(request.count), &buffer, &length, nil, 0) == 0 else { return [:] }
    var counters: [String: InterfaceCounters] = [:]
    buffer.withUnsafeBytes { bytes in
        var offset = 0
        // Messages of several types follow each other; each starts with its length and type.
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let messageLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            let type = bytes.loadUnaligned(fromByteOffset: offset + MemoryLayout<UInt16>.size + 1, as: UInt8.self)
            guard messageLength > 0 else { break }
            if Int32(type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                    let interface = string(fromNullTerminated: name)
                    if interface.hasPrefix(PHYSICAL_INTERFACE_PREFIX) {
                        counters[interface] = InterfaceCounters(received: message.ifm_data.ifi_ibytes, sent: message.ifm_data.ifi_obytes)
                    }
                }
            }
            offset += messageLength
        }
    }
    return counters
}

/// The drop-down: the processes moving the most traffic, each with its download and upload rate
/// over the last second and the bytes it has received and sent in all. A streaming `nettop`
/// runs only while the menu is open and refreshes the rows in place every second; until its
/// first sample the menu shows the rows it last showed, their rates as "—".
@MainActor private final class NetworkMenuDelegate: NSObject, NSMenuDelegate {
    private var section: MenuSection?
    private var lastSample: [ProcessUsage] = []
    private lazy var sampler = NetworkSampler { [weak self] usage in
        self?.lastSample = usage
        self?.show(usage, ratesCurrent: true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        section = MenuSection(in: menu, title: "Traffic by process", columns: ["↓ Now", "↑ Now", "↓ Total", "↑ Total"], folds: true)
        appendQuit(to: menu)
        show(lastSample, ratesCurrent: false)
    }

    func menuWillOpen(_ menu: NSMenu) { sampler.start() }

    func menuDidClose(_ menu: NSMenu) { sampler.stop() }

    /// Shows the processes, the busiest first.
    /// @param usage The processes. @param ratesCurrent False shows the rates as "—", for a sample from an earlier opening.
    private func show(_ usage: [ProcessUsage], ratesCurrent: Bool) {
        section?.update(usage.sorted { $0.receivedBytesPerSecond + $0.sentBytesPerSecond > $1.receivedBytesPerSecond + $1.sentBytesPerSecond }.map {
            MenuRow(name: $0.name, values: [ratesCurrent ? formatRate($0.receivedBytesPerSecond) : NO_RATE, ratesCurrent ? formatRate($0.sentBytesPerSecond) : NO_RATE,
                                           formatBytes($0.receivedBytesTotal), formatBytes($0.sentBytesTotal)])
        })
    }
}

@MainActor private let networkMenuDelegate = NetworkMenuDelegate()

/// Adds the network item to the menu bar and starts measuring; its drop-down lists the
/// processes moving the most traffic.
@MainActor func startNetwork() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = NETWORK_AUTOSAVE_NAME
    let menu = NSMenu()
    menu.delegate = networkMenuDelegate
    item.menu = menu
    var previous = readCounters()
    var previousTime = Date()
    showTwoLines(on: item, top: "\(UPLOAD_ARROW) \(formatRate(0))", bottom: "\(DOWNLOAD_ARROW) \(formatRate(0))", widest: NETWORK_WIDEST_TEXTS)
    scheduleRepeatingTimer(every: NETWORK_REFRESH_SECONDS) {
        let current = readCounters(), now = Date()
        let seconds = now.timeIntervalSince(previousTime)
        guard seconds > 0 else { return }
        let moved = bytesMoved(from: previous, to: current)
        showTwoLines(on: item, top: "\(UPLOAD_ARROW) \(formatRate(Double(moved.sent) / seconds))", bottom: "\(DOWNLOAD_ARROW) \(formatRate(Double(moved.received) / seconds))", widest: NETWORK_WIDEST_TEXTS)
        previous = current
        previousTime = now
    }
}
