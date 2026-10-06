/// Ping item: two stacked lines refreshed once a second, the round-trip time to 8.8.8.8
/// above and the Wi-Fi signal quality in percent below. The ping is red when no reply arrived
/// or it exceeds SLOW_PING_MILLISECONDS; the signal is red below WEAK_SIGNAL_PERCENT or when
/// Wi-Fi is off. A tick is skipped while the previous ping waits for its reply. Clicking shows
/// the Wi-Fi link (CoreWLAN), the network configuration (SystemConfiguration, `getifaddrs`),
/// the public address and the ping statistics of the last PING_WINDOW_SAMPLES pings.
import AppKit
import CoreWLAN
import SystemConfiguration
import os

private let PING_HOST = "8.8.8.8"
private let PING_REFRESH_SECONDS = 1.0
private let PING_TIMEOUT_SECONDS = 1.0
private let PING_PAYLOAD_BYTES = 32
private let PING_RECEIVE_BUFFER_BYTES = 1500
private let PING_WINDOW_SAMPLES = 60
private let SLOW_PING_MILLISECONDS = 150.0
private let WEAK_SIGNAL_PERCENT = 50
/// RSSI mapped to 0% and 100% signal quality, the usual linear scale of network tools.
private let SIGNAL_FLOOR_DBM = -100, SIGNAL_CEILING_DBM = -50
private let PUBLIC_ADDRESS_URL = URL(string: "https://api.ipify.org")!
private let PUBLIC_ADDRESS_TIMEOUT_SECONDS = 3.0
private let PUBLIC_ADDRESS_CACHE_SECONDS = 300.0
private let PUBLIC_ADDRESS_RETRY_SECONDS = 30.0
private let PUBLIC_ADDRESS_UNAVAILABLE = "Unavailable"
private let TUNNEL_INTERFACE_PREFIXES = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
private let SYSTEM_PROFILER_PATH = "/usr/sbin/system_profiler"
private let PING_AUTOSAVE_NAME = "capybarPing"
private let PING_WIDEST_TEXTS = ["\(Int(PING_TIMEOUT_SECONDS * 1000)) ms", "— ms", "100%", "—%"]
private let ASKING = "Asking…"
private let NOT_AVAILABLE = "—"

private let pingTarget: [UInt8]? = {
    var address = in_addr()
    guard inet_pton(AF_INET, PING_HOST, &address) == 1 else { return nil }
    return withUnsafeBytes(of: address) { Array($0) }
}()
private let pingSequence = OSAllocatedUnfairLock(initialState: UInt16(0))

/// Pings PING_HOST once through an unprivileged ICMP datagram socket, so no `ping` process is
/// started every second; waits at most PING_TIMEOUT_SECONDS for this ping's own reply, skipping
/// replies meant for others. Blocks while it waits.
/// @returns Round-trip time in milliseconds; nil when no reply arrived in time or the socket failed.
private func measurePing() -> Double? {
    guard let target = pingTarget else { return nil }
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard descriptor >= 0 else {
        logFailureOnce(key: "ping socket", "ICMP socket failed: \(String(cString: strerror(errno)))")
        return nil
    }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: target) }
    let sequence = pingSequence.withLock { value in value &+= 1; return value }
    let identifier = UInt16(truncatingIfNeeded: getpid())
    let packet = makeEchoRequest(identifier: identifier, sequence: sequence, payloadLength: PING_PAYLOAD_BYTES)
    let start = DispatchTime.now().uptimeNanoseconds
    let sent = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard sent == packet.count else { return nil }
    var buffer = [UInt8](repeating: 0, count: PING_RECEIVE_BUFFER_BYTES)
    while true {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        guard elapsed < PING_TIMEOUT_SECONDS else { return nil }
        var timeout = socketTimeout(seconds: PING_TIMEOUT_SECONDS - elapsed)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            logFailureOnce(key: "ping timeout", "ICMP receive timeout not set: \(String(cString: strerror(errno)))")
            return nil
        }
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 0 else { return nil }
        if isEchoReply(buffer[..<received], from: target, identifier: identifier, sequence: sequence) {
            let roundTrip = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            return roundTrip <= PING_TIMEOUT_SECONDS * 1000 ? roundTrip : nil
        }
    }
}

/// Maps RSSI linearly from SIGNAL_FLOOR_DBM (0%) to SIGNAL_CEILING_DBM (100%).
/// @param rssi Signal in dBm. @returns Quality 0...100.
func signalPercent(rssi: Int) -> Int {
    min(max(100 * (rssi - SIGNAL_FLOOR_DBM) / (SIGNAL_CEILING_DBM - SIGNAL_FLOOR_DBM), 0), 100)
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
    #if compiler(>=6.2)
    // Wi-Fi 7 arrived in the macOS 26 SDK, which ships with Swift 6.2.
    case .mode11be: return "802.11be (Wi-Fi 7)"
    #endif
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
private func readWiFiNameFromSystemProfiler() -> ReportedWiFi {
    let data = Data(runCommand(SYSTEM_PROFILER_PATH, ["SPAirPortDataType", "-json"]).output.utf8)
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let interfaces = ((root?["SPAirPortDataType"] as? [[String: Any]])?.first?["spairport_airport_interfaces"] as? [[String: Any]]) ?? []
    let current = interfaces.lazy.compactMap { $0["spairport_current_network_information"] as? [String: Any] }.first
    return ReportedWiFi(name: current?["_name"] as? String, countryCode: current?["spairport_network_country_code"] as? String)
}

/// The network name and country code `system_profiler` reported.
private struct ReportedWiFi: Sendable {
    var name: String?
    var countryCode: String?
}

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
    let networkName = ssid ?? reported.map { $0.name ?? "Unknown" } ?? ASKING
    let countryCode = interface.countryCode() ?? reported.map { $0.countryCode ?? NOT_AVAILABLE } ?? (ssid == nil ? ASKING : NOT_AVAILABLE)
    let noise = interface.noiseMeasurement()
    let rows = [
        InfoRow(label: "Network", value: networkName, copyable: ssid != nil || reported?.name != nil),
        InfoRow(label: "BSSID", value: bssid ?? "Withheld by macOS", copyable: bssid != nil),
        InfoRow(label: "MAC", value: macAddress ?? NOT_AVAILABLE, copyable: macAddress != nil),
        InfoRow(label: "Interface", value: name),
        InfoRow(label: "Channel", value: interface.wlanChannel().map(describe) ?? NOT_AVAILABLE, copyable: true),
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
    return string(fromNullTerminated: host)
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

/// The session with the network configuration store, opened once.
@MainActor private let DYNAMIC_STORE = SCDynamicStoreCreate(nil, BUNDLE_IDENTIFIER as CFString, nil, nil)

/// Reads one dictionary from the dynamic store.
/// @param key Store key ("State:/Network/Global/IPv4"). @returns The dictionary, nil when absent.
@MainActor private func readDynamicStore(_ key: String) -> [String: Any]? {
    DYNAMIC_STORE.flatMap { SCDynamicStoreCopyValue($0, key as CFString) as? [String: Any] }
}

@MainActor private var interfaceDisplayNames: [String: String] = [:]

/// Finds the name System Settings gives a BSD interface ("Wi-Fi" for en0); the list of
/// interfaces is read again only for a name not seen before.
/// @param bsdName BSD name. @returns The display name, nil for interfaces System Settings does not list.
@MainActor private func displayName(ofInterface bsdName: String) -> String? {
    if let known = interfaceDisplayNames[bsdName] { return known }
    for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
        if let name = SCNetworkInterfaceGetBSDName(interface) as String?, let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
            interfaceDisplayNames[name] = display
        }
    }
    return interfaceDisplayNames[bsdName]
}

/// The network configuration: its rows, and what identifies the network (answers fetched for
/// one network are not shown on another).
private struct NetworkState {
    var rows: [InfoRow]
    /// Interface, router and addresses of the default route; empty without one.
    var identity: String
}

/// Reads the network configuration: the interface carrying the default route, its addresses,
/// the router, the DNS servers and whether a tunnel (VPN) holds an IPv4 address.
/// @returns The rows in display order and the network's identity.
@MainActor private func readNetworkState() -> NetworkState {
    let global = readDynamicStore("State:/Network/Global/IPv4") ?? [:]
    let addresses = readInterfaceAddresses()
    guard let primary = global["PrimaryInterface"] as? String else { return NetworkState(rows: [InfoRow(label: "Connection", value: "No default route")], identity: "") }
    /// One row per value, the label on the first only.
    func list(_ label: String, _ values: [String]) -> [InfoRow] {
        values.isEmpty ? [InfoRow(label: label, value: NOT_AVAILABLE)] : values.enumerated().map { InfoRow(label: $0.offset == 0 ? label : "", value: $0.element, copyable: true) }
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
    return NetworkState(rows: rows, identity: ([primary, router ?? ""] + own.ipv4).joined(separator: " "))
}

/// Summarises the recent pings: last, min/avg/max of the replies, and loss.
/// @param samples Round-trip times in milliseconds, nil for a lost ping, oldest first.
/// @returns The rows in display order.
private func pingRows(_ samples: [Double?]) -> [InfoRow] {
    let replies = samples.compactMap { $0 }
    let lost = samples.count - replies.count
    let last = samples.last.map { $0.map { String(format: "%.1f ms", $0) } ?? "Lost" } ?? NOT_AVAILABLE
    let spread = replies.isEmpty ? NOT_AVAILABLE : String(format: "%.1f / %.1f / %.1f ms", replies.min()!, replies.reduce(0, +) / Double(replies.count), replies.max()!)
    let loss = samples.isEmpty ? NOT_AVAILABLE : "\(lost * 100 / samples.count)% (\(lost) of \(samples.count))"
    return [InfoRow(label: "Target", value: PING_HOST, copyable: true), InfoRow(label: "Last", value: last, copyable: true),
            InfoRow(label: "Min / avg / max", value: spread, copyable: true), InfoRow(label: "Loss", value: loss, copyable: true)]
}

/// Answers that take a while, kept per network: the public address for
/// PUBLIC_ADDRESS_CACHE_SECONDS (a failure for PUBLIC_ADDRESS_RETRY_SECONDS), the `system_profiler` Wi-Fi report until the network changes.
/// One request of each kind runs at a time; an answer for a network that is no longer current
/// is dropped.
@MainActor private enum SlowAnswers {
    private static var publicAddress: (identity: String, value: String, expires: Date)?
    private static var publicAddressRequest: String?
    private static var reportedWiFi: (identity: String, value: ReportedWiFi)?
    private static var reportedWiFiRequest: String?

    /// The cached public address of this network; nil while unknown or stale.
    static func publicAddress(for identity: String) -> String? {
        guard let publicAddress, publicAddress.identity == identity, Date() < publicAddress.expires else { return nil }
        return publicAddress.value
    }

    /// The cached Wi-Fi report of this network; nil while unknown.
    static func reportedWiFi(for identity: String) -> ReportedWiFi? {
        reportedWiFi.flatMap { $0.identity == identity ? $0.value : nil }
    }

    /// Fetches the public address of this network unless it is cached or already being fetched.
    /// @param identity The current network. @param completion Runs on the main thread when an answer arrived.
    static func fetchPublicAddress(for identity: String, completion: @escaping @MainActor @Sendable () -> Void) {
        guard publicAddress(for: identity) == nil, publicAddressRequest != identity else { return }
        publicAddressRequest = identity
        var request = URLRequest(url: PUBLIC_ADDRESS_URL)
        request.timeoutInterval = PUBLIC_ADDRESS_TIMEOUT_SECONDS
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let text = data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let answer = (response as? HTTPURLResponse)?.statusCode == 200 && !text.isEmpty ? text : PUBLIC_ADDRESS_UNAVAILABLE
            performOnMain {
                publicAddressRequest = nil
                publicAddress = (identity, answer, Date().addingTimeInterval(answer == PUBLIC_ADDRESS_UNAVAILABLE ? PUBLIC_ADDRESS_RETRY_SECONDS : PUBLIC_ADDRESS_CACHE_SECONDS))
                completion()
            }
        }.resume()
    }

    /// Asks `system_profiler` for the Wi-Fi report of this network unless it is cached or already being asked.
    /// @param identity The current network. @param completion Runs on the main thread when the answer arrived.
    static func fetchReportedWiFi(for identity: String, completion: @escaping @MainActor @Sendable () -> Void) {
        guard reportedWiFi(for: identity) == nil, reportedWiFiRequest != identity else { return }
        reportedWiFiRequest = identity
        DispatchQueue.global(qos: .userInitiated).async {
            let reported = readWiFiNameFromSystemProfiler()
            performOnMain {
                reportedWiFiRequest = nil
                reportedWiFi = (identity, reported)
                completion()
            }
        }
    }
}

@MainActor private var pingSamples: [Double?] = []
@MainActor private var pingInFlight = false
@MainActor private var pingItem: NSStatusItem?

/// The drop-down: the Wi-Fi link, the network and the recent pings, built when it opens and
/// refreshed in place every second while open. The values that take a while (the network name
/// when CoreWLAN withholds it, the public address) read "Asking…" until they arrive.
@MainActor private final class PingMenuDelegate: NSObject, NSMenuDelegate {
    private var wifiSection: MenuSection?
    private var networkSection: MenuSection?
    private var pingSection: MenuSection?
    private let timer = OpenMenuTimer()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        wifiSection = MenuSection(in: menu, title: "Wi-Fi", folds: false)
        menu.addItem(.separator())
        networkSection = MenuSection(in: menu, title: "Network", folds: false)
        menu.addItem(.separator())
        pingSection = MenuSection(in: menu, title: "Ping, last \(PING_WINDOW_SAMPLES) s", folds: false)
        appendQuit(to: menu)
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { timer.start { [weak self] in self?.refresh() } }

    func menuDidClose(_ menu: NSMenu) { timer.stop() }

    /// Reads every value again and shows it, asking for the slow answers this network lacks.
    private func refresh() {
        let network = readNetworkState()
        let wifi = readWiFiRows(reported: SlowAnswers.reportedWiFi(for: network.identity))
        wifiSection?.update(wifi.rows)
        let address = SlowAnswers.publicAddress(for: network.identity)
        networkSection?.update(network.rows + [InfoRow(label: "Public IP", value: address ?? ASKING, copyable: address != nil && address != PUBLIC_ADDRESS_UNAVAILABLE)])
        pingSection?.update(pingRows(pingSamples))
        let refreshAgain: @MainActor @Sendable () -> Void = { [weak self] in self?.refresh() }
        if wifi.nameWithheld { SlowAnswers.fetchReportedWiFi(for: network.identity, completion: refreshAgain) }
        SlowAnswers.fetchPublicAddress(for: network.identity, completion: refreshAgain)
    }
}

@MainActor private let pingMenuDelegate = PingMenuDelegate()

/// Adds the ping and Wi-Fi signal item to the menu bar and starts measuring; its drop-down
/// describes the Wi-Fi link, the network and the recent pings.
@MainActor func startPing() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = PING_AUTOSAVE_NAME
    let menu = NSMenu()
    menu.delegate = pingMenuDelegate
    item.menu = menu
    pingItem = item
    scheduleRepeatingTimer(every: PING_REFRESH_SECONDS) {
        guard !pingInFlight else { return }
        pingInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let milliseconds = measurePing()
            performOnMain {
                pingSamples = Array((pingSamples + [milliseconds]).suffix(PING_WINDOW_SAMPLES))
                let signal = readSignalPercent()
                guard let pingItem else { return }
                showTwoLines(on: pingItem, top: milliseconds.map { "\(Int($0.rounded())) ms" } ?? "— ms",
                             topCritical: milliseconds.map { $0 > SLOW_PING_MILLISECONDS } ?? true,
                             bottom: signal.map { "\($0)%" } ?? "—%",
                             bottomCritical: signal.map { $0 < WEAK_SIGNAL_PERCENT } ?? true, widest: PING_WIDEST_TEXTS)
                pingInFlight = false
            }
        }
    }.fire()
}
