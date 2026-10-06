/// System item: CPU load above RAM use every second; a value at or over its critical
/// threshold is drawn in red. Clicking shows the processes using the most CPU and memory, each
/// of which can be force quit from there.
import AppKit

private let SYSTEM_REFRESH_SECONDS = 1.0
private let CPU_CRITICAL_PERCENT = 85.0
private let RAM_CRITICAL_PERCENT = 90.0
/// CPU below this share is not worth a row.
private let CPU_ROW_MINIMUM_PERCENT = 0.1
private let SYSTEM_AUTOSAVE_NAME = "capybarSystem"
private let SYSTEM_WIDEST_TEXTS = ["CPU 100%", "RAM 100%"]

/// Reads cumulative CPU ticks across all cores. @returns The ticks; nil when the kernel call fails.
private func readCpuTicks() -> CpuTicks? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return nil }
    return CpuTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
}

/// Memory in use the way Activity Monitor's "Memory Used" counts it: app memory
/// (internal pages − purgeable), wired and compressed.
/// @returns Percent of physical memory in use; nil when the kernel call fails.
private func readRamPercent() -> Double? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    var pageSize = vm_size_t(0)
    guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
    let used = (Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * Double(pageSize)
    return used / Double(ProcessInfo.processInfo.physicalMemory) * 100
}

/// The drop-down: the processes using the most CPU and the most memory, the rest folded into
/// "More", each with a cross that force quits it. It opens with the last sample and refreshes
/// in place, off the main thread, every second while open and right after a force quit.
@MainActor private final class SystemMenuDelegate: NSObject, NSMenuDelegate {
    private var cpuSection: MenuSection?
    private var memorySection: MenuSection?
    private var lastUsage: [ProcessUsage] = []
    private let timer = OpenMenuTimer()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let refresh: @MainActor () -> Void = { [weak self] in self?.refreshInBackground() }
        cpuSection = MenuSection(in: menu, title: "CPU (100% = one core)", folds: true, onKill: refresh)
        menu.addItem(.separator())
        memorySection = MenuSection(in: menu, title: "Memory (resident)", folds: true, onKill: refresh)
        appendQuit(to: menu)
        show(lastUsage)
        refreshInBackground()
    }

    func menuWillOpen(_ menu: NSMenu) { timer.start { [weak self] in self?.refreshInBackground() } }

    func menuDidClose(_ menu: NSMenu) { timer.stop() }

    /// Samples `ps` off the main thread and shows the result.
    private func refreshInBackground() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = readProcessUsage()
            performOnMain { [weak self] in
                self?.lastUsage = usage
                self?.show(usage)
            }
        }
    }

    private func show(_ usage: [ProcessUsage]) {
        cpuSection?.update(usage.filter { $0.cpuPercent >= CPU_ROW_MINIMUM_PERCENT }.sorted { $0.cpuPercent > $1.cpuPercent }
            .map { MenuRow(name: $0.name, values: [String(format: "%.1f%%", $0.cpuPercent)], kill: .button($0.killableProcessIds)) })
        memorySection?.update(usage.sorted { $0.memoryBytes > $1.memoryBytes }
            .map { MenuRow(name: $0.name, values: [formatBytes($0.memoryBytes)], kill: .button($0.killableProcessIds)) })
    }
}

@MainActor private let systemMenuDelegate = SystemMenuDelegate()

/// Adds the CPU and RAM item to the menu bar and starts measuring; its drop-down lists the
/// heaviest processes.
@MainActor func startSystemLoad() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = SYSTEM_AUTOSAVE_NAME
    let menu = NSMenu()
    menu.delegate = systemMenuDelegate
    item.menu = menu
    var previousTicks = readCpuTicks()
    var cpu = 0.0
    scheduleRepeatingTimer(every: SYSTEM_REFRESH_SECONDS) {
        if let ticks = readCpuTicks() {
            if let previousTicks, let percent = busyPercent(from: previousTicks, to: ticks) { cpu = percent }
            previousTicks = ticks
        }
        guard let ram = readRamPercent() else { return }
        showTwoLines(on: item, top: "CPU \(Int(cpu.rounded()))%", topCritical: cpu >= CPU_CRITICAL_PERCENT,
                     bottom: "RAM \(Int(ram.rounded()))%", bottomCritical: ram >= RAM_CRITICAL_PERCENT, widest: SYSTEM_WIDEST_TEXTS)
    }.fire()
}
