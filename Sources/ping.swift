/// Ping item: two stacked lines refreshed once a second, the round-trip time to 8.8.8.8
/// above and the Wi-Fi signal quality in percent below. The ping is red when no reply arrived
/// or it exceeds SLOW_PING_MILLISECONDS; the signal is red below WEAK_SIGNAL_PERCENT or when
/// Wi-Fi is off. A tick is skipped while the previous ping waits for its reply. Clicking shows
/// the Wi-Fi link (CoreWLAN), the network configuration (SystemConfiguration, `getifaddrs`),
/// the public address and the ping statistics of the last PING_WINDOW_SAMPLES pings.
import AppKit
import CoreWLAN
import SystemConfiguration

private let PING_HOST = "8.8.8.8"
private let PING_REFRESH_SECONDS = 1.0
private let PING_TIMEOUT_SECONDS = 1.0
private let PING_WINDOW_SAMPLES = 60
private let SLOW_PING_MILLISECONDS = 150.0
private let WEAK_SIGNAL_PERCENT = 50
private let PUBLIC_ADDRESS_URL = URL(string: "https://api.ipify.org")!
private let PUBLIC_ADDRESS_TIMEOUT_SECONDS = 3.0
private let PUBLIC_ADDRESS_CACHE_SECONDS = 300.0
private let TUNNEL_INTERFACE_PREFIXES = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

/// Computes the internet checksum of an ICMP message.
/// @param bytes The message with its checksum field zeroed. @returns The checksum.
private func icmpChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for index in stride(from: 0, to: bytes.count, by: 2) {
        sum += UInt32(bytes[index]) << 8 | (index + 1 < bytes.count ? UInt32(bytes[index + 1]) : 0)
    }
    while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
    return ~UInt16(sum)
}

private var pingSequence: UInt16 = 0

/// Pings PING_HOST once with a PING_TIMEOUT_SECONDS timeout through an unprivileged ICMP
/// datagram socket, so no `ping` process is started every second. Blocks while it waits.
/// @returns Round-trip time in milliseconds, or nil when no reply arrived or the socket failed.
private func measurePing() -> Double? {
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: Int(PING_TIMEOUT_SECONDS), tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    guard inet_pton(AF_INET, PING_HOST, &address.sin_addr) == 1 else { return nil }
    pingSequence &+= 1
    let sequence = pingSequence, identifier = UInt16(truncatingIfNeeded: getpid())
    // Echo request: type 8, code 0, checksum, identifier, sequence, then a small payload.
    var packet: [UInt8] = [8, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xFF), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        + [UInt8](repeating: 0x63, count: 32)
    let checksum = icmpChecksum(packet)
    packet[2] = UInt8(checksum >> 8)
    packet[3] = UInt8(checksum & 0xFF)
    let start = DispatchTime.now().uptimeNanoseconds
    let sent = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard sent == packet.count else { return nil }
    var buffer = [UInt8](repeating: 0, count: 1500)
    while true {
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 0 else { return nil }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        // Replies arrive with their IP header; its length is in the low nibble of the first byte.
        let headerLength = Int(buffer[0] & 0x0F) * 4
        if received >= headerLength + 8, buffer[headerLength] == 0,
           UInt16(buffer[headerLength + 6]) << 8 | UInt16(buffer[headerLength + 7]) == sequence { return elapsed }
        if elapsed > PING_TIMEOUT_SECONDS * 1000 { return nil }
    }
}

/// Maps RSSI linearly from -100 dBm (0%) to -50 dBm (100%), the usual scale of network tools.
/// @param rssi Signal in dBm. @returns Quality 0...100.
private func signalPercent(rssi: Int) -> Int {
    min(max(2 * (rssi + 100), 0), 100)
}

/// Reads the Wi-Fi signal quality of the default interface as a percentage.
/// @returns Quality 0...100, or nil when Wi-Fi is off or not associated (RSSI 0).
private func readSignalPercent() -> Int? {
    guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
    let rssi = interface.rssiValue()
    return rssi == 0 ? nil : signalPercent(rssi: rssi)
}

/// Names a PHY mode as the 802.11 standard it stands for.
private func describe(_ mode: CWPHYMode) -> String {
    switch mode {
    case .mode11a: return "802.11a"
    case .mode11b: return "802.11b"
    case .mode11g: return "802.11g"
    case .mode11n: return "802.11n (Wi-Fi 4)"
    case .mode11ac: return "802.11ac (Wi-Fi 5)"
    case .mode11ax: return "802.11ax (Wi-Fi 6)"
    case .modeNone: return "None"
    @unknown default: return "802.11 (mode \(mode.rawValue))"
    }
}

/// Names a security type the way System Settings does.
private func describe(_ security: CWSecurity) -> String {
    switch security {
    case .none: return "None"
    case .WEP: return "WEP"
    case .wpaPersonal: return "WPA Personal"
    case .wpaPersonalMixed: return "WPA/WPA2 Personal"
    case .wpa2Personal: return "WPA2 Personal"
    case .personal: return "Personal"
    case .dynamicWEP: return "Dynamic WEP"
    case .wpaEnterprise: return "WPA Enterprise"
    case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
    case .wpa2Enterprise: return "WPA2 Enterprise"
    case .enterprise: return "Enterprise"
    case .wpa3Personal: return "WPA3 Personal"
    case .wpa3Enterprise: return "WPA3 Enterprise"
    case .wpa3Transition: return "WPA2/WPA3 Personal"
    case .OWE: return "Enhanced Open"
    case .oweTransition: return "Enhanced Open Transition"
    case .unknown: return "Unknown"
    @unknown default: return "Unknown (\(security.rawValue))"
    }
}

/// Describes a channel as "5 GHz, channel 36, 80 MHz".
private func describe(_ channel: CWChannel) -> String {
    let band: String
    switch channel.channelBand {
    case .band2GHz: band = "2.4 GHz"
    case .band5GHz: band = "5 GHz"
    case .band6GHz: band = "6 GHz"
    default: band = "Unknown band"
    }
    let width: String
    switch channel.channelWidth {
    case .width20MHz: width = "20 MHz"
    case .width40MHz: width = "40 MHz"
    case .width80MHz: width = "80 MHz"
    case .width160MHz: width = "160 MHz"
    default: width = "unknown width"
    }
    return "\(band), channel \(channel.channelNumber), \(width)"
}

/// The network name and country code as `system_profiler` reports them. CoreWLAN withholds both
/// from a process without Location, which macOS grants only to application bundles; the system
/// tool reads them on its own authority, in about four seconds, so it runs off the main thread.
/// @returns (name, country code), each nil when not reported.
private func readWiFiNameFromSystemProfiler() -> (name: String?, countryCode: String?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPAirPortDataType", "-json"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (nil, nil) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let interfaces = ((root?["SPAirPortDataType"] as? [[String: Any]])?.first?["spairport_airport_interfaces"] as? [[String: Any]]) ?? []
    let current = interfaces.lazy.compactMap { $0["spairport_current_network_information"] as? [String: Any] }.first
    return (current?["_name"] as? String, current?["spairport_network_country_code"] as? String)
}

/// The network name and country code `system_profiler` reported.
private typealias ReportedWiFi = (name: String?, countryCode: String?)

/// Reads the Wi-Fi link of the default interface through CoreWLAN.
/// @param reported What `system_profiler` reported for the name and country code CoreWLAN
/// withholds; nil while it has not answered yet ("Asking…").
/// @returns The rows in display order, and whether the network name was withheld (the caller
/// then asks `system_profiler`).
private func readWiFiRows(reported: ReportedWiFi?) -> (rows: [InfoRow], nameWithheld: Bool) {
    guard let interface = CWWiFiClient.shared().interface() else { return ([InfoRow(label: "Wi-Fi", value: "No Wi-Fi interface")], false) }
    let name = interface.interfaceName ?? "?"
    guard interface.powerOn() else { return ([InfoRow(label: "Wi-Fi", value: "Off (\(name))")], false) }
    let rssi = interface.rssiValue()
    guard rssi != 0 else { return ([InfoRow(label: "Wi-Fi", value: "Not connected (\(name))")], false) }
    let ssid = interface.ssid()
    let bssid = interface.bssid()
    let macAddress = interface.hardwareAddress()
    let networkName = ssid ?? reported.map { $0.name ?? "Unknown" } ?? "Asking…"
    let countryCode = interface.countryCode() ?? reported.map { $0.countryCode ?? "—" } ?? (ssid == nil ? "Asking…" : "—")
    let noise = interface.noiseMeasurement()
    let rows = [
        InfoRow(label: "Network", value: networkName, copyable: ssid != nil || reported?.name != nil),
        InfoRow(label: "BSSID", value: bssid ?? "Withheld by macOS", copyable: bssid != nil),
        InfoRow(label: "MAC", value: macAddress ?? "—", copyable: macAddress != nil),
        InfoRow(label: "Interface", value: name),
        InfoRow(label: "Channel", value: interface.wlanChannel().map(describe) ?? "—", copyable: true),
        InfoRow(label: "PHY mode", value: describe(interface.activePHYMode())),
        InfoRow(label: "Signal", value: "\(rssi) dBm (\(signalPercent(rssi: rssi))%)"),
        InfoRow(label: "Noise", value: "\(noise) dBm"),
        InfoRow(label: "SNR", value: "\(rssi - noise) dB"),
        InfoRow(label: "Transmit rate", value: "\(Int(interface.transmitRate())) Mbps"),
        InfoRow(label: "Security", value: describe(interface.security())),
        InfoRow(label: "Country code", value: countryCode),
    ]
    return (rows, ssid == nil)
}

/// Addresses of one interface from `getifaddrs`.
private struct InterfaceAddresses {
    var ipv4: [String] = []
    var ipv6: [String] = []
}

/// Formats a socket address numerically.
/// @param address The address. @returns "192.168.1.2" or "fe80::1%en0"; nil when it cannot be formatted.
private func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let length = socklen_t(address.pointee.sa_len)
    guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
    return String(cString: host)
}

/// Counts the leading one bits of a netmask.
/// @param netmask An IPv4 or IPv6 netmask. @returns The prefix length.
private func prefixLength(_ netmask: UnsafeMutablePointer<sockaddr>) -> Int {
    if netmask.pointee.sa_family == UInt8(AF_INET) {
        return netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr).nonzeroBitCount }
    }
    return netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
        withUnsafeBytes(of: pointer.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
    }
}

/// Reads the IPv4 and IPv6 addresses of every interface, each with its prefix length.
/// @returns Addresses keyed by BSD interface name ("en0").
private func readInterfaceAddresses() -> [String: InterfaceAddresses] {
    var byInterface: [String: InterfaceAddresses] = [:]
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [:] }
    defer { freeifaddrs(list) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let entry = pointer.pointee
        guard let address = entry.ifa_addr, let host = numericHost(address) else { continue }
        let name = String(cString: entry.ifa_name)
        let prefix = entry.ifa_netmask.map { "/\(prefixLength($0))" } ?? ""
        switch Int32(address.pointee.sa_family) {
        case AF_INET: byInterface[name, default: InterfaceAddresses()].ipv4.append(host + prefix)
        case AF_INET6: byInterface[name, default: InterfaceAddresses()].ipv6.append(host + prefix)
        default: continue
        }
    }
    return byInterface
}

/// Reads one dictionary from the dynamic store.
/// @param key Store key ("State:/Network/Global/IPv4"). @returns The dictionary, nil when absent.
private func readDynamicStore(_ key: String) -> [String: Any]? {
    guard let store = SCDynamicStoreCreate(nil, "capybar" as CFString, nil, nil) else { return nil }
    return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
}

/// Finds the name System Settings gives a BSD interface ("Wi-Fi" for en0).
/// @param bsdName BSD name. @returns The display name, nil for interfaces System Settings does not list.
private func displayName(ofInterface bsdName: String) -> String? {
    let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
    return interfaces.first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
        .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
}

/// Reads the network configuration: the interface carrying the default route, its addresses,
/// the router, the DNS servers and whether a tunnel (VPN) holds an IPv4 address.
/// @returns The rows in display order.
private func readNetworkRows() -> [InfoRow] {
    let global = readDynamicStore("State:/Network/Global/IPv4") ?? [:]
    let addresses = readInterfaceAddresses()
    guard let primary = global["PrimaryInterface"] as? String else { return [InfoRow(label: "Connection", value: "No default route")] }
    /// One row per value, the label on the first only.
    func list(_ label: String, _ values: [String]) -> [InfoRow] {
        values.isEmpty ? [InfoRow(label: label, value: "—")] : values.enumerated().map { InfoRow(label: $0.offset == 0 ? label : "", value: $0.element, copyable: true) }
    }
    let own = addresses[primary] ?? InterfaceAddresses()
    let router = global["Router"] as? String
    let servers = readDynamicStore("State:/Network/Global/DNS")?["ServerAddresses"] as? [String] ?? []
    var rows = [InfoRow(label: "Interface", value: displayName(ofInterface: primary).map { "\($0) (\(primary))" } ?? primary)]
    rows += list("IPv4", own.ipv4)
    rows += list("IPv6", own.ipv6.sorted { !$0.hasPrefix("fe80") && $1.hasPrefix("fe80") })
    rows += list("Router", router.map { [$0] } ?? [])
    rows += list("DNS", servers)
    let tunnels = addresses.filter { name, entry in TUNNEL_INTERFACE_PREFIXES.contains { name.hasPrefix($0) } && !entry.ipv4.isEmpty }.keys.sorted()
    let viaTunnel = TUNNEL_INTERFACE_PREFIXES.contains { primary.hasPrefix($0) }
    rows.append(InfoRow(label: "VPN", value: tunnels.isEmpty ? "Off" : "On (\(tunnels.joined(separator: ", "))\(viaTunnel ? ", default route" : ""))"))
    return rows
}

/// Summarises the recent pings: last, min/avg/max of the replies, and loss.
/// @param samples Round-trip times in milliseconds, nil for a lost ping, oldest first.
/// @returns The rows in display order.
private func pingRows(_ samples: [Double?]) -> [InfoRow] {
    let replies = samples.compactMap { $0 }
    let lost = samples.count - replies.count
    let last = samples.last.map { $0.map { String(format: "%.1f ms", $0) } ?? "Lost" } ?? "—"
    let spread = replies.isEmpty ? "—" : String(format: "%.1f / %.1f / %.1f ms", replies.min()!, replies.reduce(0, +) / Double(replies.count), replies.max()!)
    let loss = samples.isEmpty ? "—" : "\(lost * 100 / samples.count)% (\(lost) of \(samples.count))"
    return [InfoRow(label: "Target", value: PING_HOST, copyable: true), InfoRow(label: "Last", value: last, copyable: true),
            InfoRow(label: "Min / avg / max", value: spread, copyable: true), InfoRow(label: "Loss", value: loss, copyable: true)]
}

/// The public address as an outside server sees it, fetched at most every
/// PUBLIC_ADDRESS_CACHE_SECONDS.
private enum PublicAddress {
    static let UNAVAILABLE = "Unavailable"
    static var value: String?
    static var fetchedAt = Date.distantPast

    /// Calls `completion` on the main thread with the address, fetching it when the cached one
    /// is stale; UNAVAILABLE when the request fails.
    static func read(_ completion: @escaping (String) -> Void) {
        if let value, Date().timeIntervalSince(fetchedAt) < PUBLIC_ADDRESS_CACHE_SECONDS { return completion(value) }
        var request = URLRequest(url: PUBLIC_ADDRESS_URL)
        request.timeoutInterval = PUBLIC_ADDRESS_TIMEOUT_SECONDS
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let text = data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200 && !(text ?? "").isEmpty
            RunLoop.main.perform(inModes: [.common]) {
                if ok { value = text; fetchedAt = Date() }
                completion(ok ? text! : UNAVAILABLE)
            }
        }.resume()
    }
}

private var pingItem: NSStatusItem?
private var pingSamples: [Double?] = []

/// The drop-down: the Wi-Fi link, the network and the recent pings, built when it opens and
/// refreshed in place every second while open. The values that take a while (the network name
/// when CoreWLAN withholds it, the public address) read "Asking…" until they arrive.
private final class PingMenuDelegate: NSObject, NSMenuDelegate {
    private var wifiSection: MenuSection?
    private var networkSection: MenuSection?
    private var pingSection: MenuSection?
    private var reportedWiFi: ReportedWiFi?
    private var publicAddress: String?
    private let timer = OpenMenuTimer()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        wifiSection = MenuSection(in: menu, title: "Wi-Fi", folds: false)
        menu.addItem(.separator())
        networkSection = MenuSection(in: menu, title: "Network", folds: false)
        menu.addItem(.separator())
        pingSection = MenuSection(in: menu, title: "Ping, last \(PING_WINDOW_SAMPLES) s", folds: false)
        appendQuit(to: menu)
        reportedWiFi = nil
        publicAddress = nil
        if refresh() {
            DispatchQueue.global(qos: .userInitiated).async {
                let reported = readWiFiNameFromSystemProfiler()
                RunLoop.main.perform(inModes: [.common]) { [weak self] in
                    self?.reportedWiFi = reported
                    self?.refresh()
                }
            }
        }
        PublicAddress.read { [weak self] address in
            self?.publicAddress = address
            self?.refresh()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { timer.start { [weak self] in self?.refresh() } }

    func menuDidClose(_ menu: NSMenu) { timer.stop() }

    /// Reads every value again and shows it.
    /// @returns Whether CoreWLAN withheld the network name.
    @discardableResult
    private func refresh() -> Bool {
        let wifi = readWiFiRows(reported: reportedWiFi)
        wifiSection?.update(wifi.rows)
        let address = publicAddress ?? "Asking…"
        networkSection?.update(readNetworkRows() + [InfoRow(label: "Public IP", value: address, copyable: publicAddress != nil && address != PublicAddress.UNAVAILABLE)])
        pingSection?.update(pingRows(pingSamples))
        return wifi.nameWithheld
    }
}

private let pingMenuDelegate = PingMenuDelegate()

/// Adds the ping and Wi-Fi signal item to the menu bar and starts measuring; its drop-down
/// describes the Wi-Fi link, the network and the recent pings.
func startPing() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "capybarPing"
    let menu = NSMenu()
    menu.delegate = pingMenuDelegate
    item.menu = menu
    pingItem = item
    var pingInFlight = false
    scheduleRepeatingTimer(every: PING_REFRESH_SECONDS) { _ in
        guard !pingInFlight else { return }
        pingInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let milliseconds = measurePing()
            RunLoop.main.perform(inModes: [.common]) {
                pingSamples = Array((pingSamples + [milliseconds]).suffix(PING_WINDOW_SAMPLES))
                let signal = readSignalPercent()
                showTwoLines(on: item, top: milliseconds.map { "\(Int($0.rounded())) ms" } ?? "— ms",
                             topCritical: milliseconds.map { $0 > SLOW_PING_MILLISECONDS } ?? true,
                             bottom: signal.map { "\($0)%" } ?? "—%",
                             bottomCritical: signal.map { $0 < WEAK_SIGNAL_PERCENT } ?? true, widest: "150 ms")
                pingInFlight = false
            }
        }
    }.fire()
}
