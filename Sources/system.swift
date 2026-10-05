/// System item: CPU load above RAM use every second; a value at or over its critical
/// threshold is drawn in red. Clicking shows the processes using the most CPU and memory.
import AppKit

private let SYSTEM_REFRESH_SECONDS = 1.0
private let CPU_CRITICAL_PERCENT = 85.0
private let RAM_CRITICAL_PERCENT = 90.0

/// Reads cumulative CPU ticks across all cores.
/// @returns (busy, total) tick counters since boot.
private func readCpuTicks() -> (busy: UInt64, total: UInt64) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
    return (user + system + nice, user + system + idle + nice)
}

/// Memory in use the way Activity Monitor's "Memory Used" counts it: app memory
/// (internal pages − purgeable), wired and compressed.
/// @returns Percent of physical memory in use, 0 when the kernel call fails.
private func readRamPercent() -> Double {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let pageSize = Double(vm_kernel_page_size)
    let used = (Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
    return used / Double(ProcessInfo.processInfo.physicalMemory) * 100
}

private var systemItem: NSStatusItem?

/// Rebuilds the drop-down each time it opens: the processes using the most CPU and the
/// most memory, the rest folded into "More".
private final class SystemMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let usage = readProcessUsage()
        appendTopSection(to: menu, title: "CPU (100% = one core)", rows: usage.filter { $0.cpuPercent >= 0.1 }.sorted { $0.cpuPercent > $1.cpuPercent }.map { ($0.name, String(format: "%.1f%%", $0.cpuPercent)) })
        menu.addItem(.separator())
        appendTopSection(to: menu, title: "Memory", rows: usage.sorted { $0.memoryBytes > $1.memoryBytes }.map { ($0.name, formatBytes($0.memoryBytes)) })
        menu.addItem(.separator())
        menu.addItem(withTitle: "Red at CPU ≥ \(Int(CPU_CRITICAL_PERCENT))%, RAM ≥ \(Int(RAM_CRITICAL_PERCENT))%", action: nil, keyEquivalent: "")
        appendQuit(to: menu)
    }
}

private let systemMenuDelegate = SystemMenuDelegate()

/// Adds the CPU and RAM item to the menu bar and starts measuring; its drop-down lists the
/// heaviest processes.
func startSystemLoad() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "capybarSystem"
    let menu = NSMenu()
    menu.delegate = systemMenuDelegate
    item.menu = menu
    systemItem = item
    var previousTicks = readCpuTicks()
    Timer.scheduledTimer(withTimeInterval: SYSTEM_REFRESH_SECONDS, repeats: true) { _ in
        let ticks = readCpuTicks()
        let total = Double(ticks.total &- previousTicks.total)
        let cpu = total > 0 ? Double(ticks.busy &- previousTicks.busy) / total * 100 : 0
        previousTicks = ticks
        let ram = readRamPercent()
        item.button?.image = makeTwoLineImage(
            top: "CPU \(Int(cpu.rounded()))%", topCritical: cpu >= CPU_CRITICAL_PERCENT,
            bottom: "RAM \(Int(ram.rounded()))%", bottomCritical: ram >= RAM_CRITICAL_PERCENT,
            widest: "CPU 100%", foreground: labelColor(of: item)
        )
    }.fire()
}
