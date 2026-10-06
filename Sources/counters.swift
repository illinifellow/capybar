/// Arithmetic on the kernel's cumulative counters: CPU ticks, which are 32 bits per state and
/// wrap, and interface byte counts, read as 64 bits and reset when an interface restarts.

/// Cumulative CPU ticks per state across all cores, as `host_statistics` reports them.
struct CpuTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// The busy share of the ticks that passed between two readings. Each state's delta is taken
/// in its own 32-bit width with wrapping subtraction, so a counter that wrapped still yields
/// its true increment.
/// @param previous The earlier reading. @param current The later reading.
/// @returns Percent busy, 0...100; nil when no tick passed.
func busyPercent(from previous: CpuTicks, to current: CpuTicks) -> Double? {
    let user = UInt64(current.user &- previous.user), system = UInt64(current.system &- previous.system)
    let idle = UInt64(current.idle &- previous.idle), nice = UInt64(current.nice &- previous.nice)
    let busy = user + system + nice, total = busy + idle
    return total > 0 ? Double(busy) / Double(total) * 100 : nil
}

/// Received and sent bytes of one interface since it came up.
struct InterfaceCounters: Equatable, Sendable {
    var received: UInt64
    var sent: UInt64
}

/// The bytes moved between two readings, summed over the interfaces present in both. An
/// interface whose counter went down was restarted and counts as 0 for this interval.
/// @param previous The earlier reading, keyed by interface name. @param current The later reading.
/// @returns Bytes received and sent during the interval.
func bytesMoved(from previous: [String: InterfaceCounters], to current: [String: InterfaceCounters]) -> InterfaceCounters {
    var moved = InterfaceCounters(received: 0, sent: 0)
    for (name, now) in current {
        guard let before = previous[name] else { continue }
        moved.received += now.received >= before.received ? now.received - before.received : 0
        moved.sent += now.sent >= before.sent ? now.sent - before.sent : 0
    }
    return moved
}
