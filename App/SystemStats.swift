// VoltBar.app — CPU load, memory and swap usage, read directly from the kernel (no privileges needed).

import Foundation
import Darwin
import IOKit

struct MemoryUsage: Equatable {
    var usedGB: Double
    var totalGB: Double
    var percent: Double { totalGB > 0 ? usedGB / totalGB * 100 : 0 }
}

struct SwapUsage: Equatable {
    var usedGB: Double
    var totalGB: Double
}

final class SystemStats {
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? = nil
    private let pageSize = Double(vm_kernel_page_size)
    private let totalMemory: Double = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return Double(size)
    }()

    /// Total CPU load in percent since the previous call (nil on the first call).
    func cpuLoad() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = (user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                 idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
        defer { lastTicks = t }
        guard let p = lastTicks else { return nil }
        let busy = Double((t.user &- p.user) + (t.system &- p.system) + (t.nice &- p.nice))
        let all = busy + Double(t.idle &- p.idle)
        return all > 0 ? busy / all * 100 : nil
    }

    private var lastCoreTicks: [(busy: UInt64, total: UInt64)] = []

    /// Load of every logical CPU (thread) in percent since the previous call (nil on the first call).
    func perThreadLoad() -> [Double]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info = info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var now: [(busy: UInt64, total: UInt64)] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            now.append((user + sys + nice, user + sys + nice + idle))
        }
        defer { lastCoreTicks = now }
        guard lastCoreTicks.count == now.count else { return nil }
        return zip(now, lastCoreTicks).map { n, p in
            let total = Double(n.total &- p.total)
            return total > 0 ? Double(n.busy &- p.busy) / total * 100 : 0
        }
    }

    /// "Used" memory the way Activity Monitor counts it: app (active + inactive - purgeable... approximated
    /// by internal pages) + wired + compressed.
    func memory() -> MemoryUsage? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, totalMemory > 0 else { return nil }
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        let used = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * pageSize
        return MemoryUsage(usedGB: used / 1_073_741_824, totalGB: totalMemory / 1_073_741_824)
    }

    /// GPU utilisation from the graphics drivers' PerformanceStatistics (no privileges needed).
    /// Intel = integrated; NVIDIA / AMD = discrete. nil when that GPU isn't there or doesn't report.
    func gpuUtilization() -> (integrated: Double?, discrete: Double?) {
        var integrated: Double? = nil, discrete: Double? = nil
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOObjectRelease(it) }
        var s = IOIteratorNext(it)
        while s != 0 {
            var cls = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(s, &cls)
            let name = String(cString: cls)
            if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let util = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber {
                if name.hasPrefix("Intel") { integrated = util.doubleValue } else { discrete = util.doubleValue }
            }
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
        return (integrated, discrete)
    }

    /// Whether a discrete (non-Intel) GPU driver is present at all.
    static let hasDiscreteGPU: Bool = {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        var found = false
        var s = IOIteratorNext(it)
        while s != 0 {
            var cls = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(s, &cls)
            if !String(cString: cls).hasPrefix("Intel") { found = true }
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
        return found
    }()

    func swap() -> SwapUsage? {
        var usage = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &len, nil, 0) == 0 else { return nil }
        return SwapUsage(usedGB: Double(usage.xsu_used) / 1_073_741_824, totalGB: Double(usage.xsu_total) / 1_073_741_824)
    }
}
