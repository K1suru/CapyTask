import Darwin
import Foundation

/// Memoria física vía `host_statistics64(HOST_VM_INFO64)`, con el mismo
/// desglose que Monitor de Actividad.
struct MemoryReader: Sendable {
    let totalBytes: UInt64
    let pageSize: UInt64

    init() {
        totalBytes = Sysctl.read("hw.memsize", as: UInt64.self) ?? ProcessInfo.processInfo.physicalMemory
        var size: vm_size_t = 0
        if host_page_size(HostPort.shared, &size) == KERN_SUCCESS, size > 0 {
            pageSize = UInt64(size)
        } else {
            pageSize = UInt64(getpagesize())
        }
    }

    func sample() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(HostPort.shared, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemorySnapshot(total: totalBytes) }

        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let level = Sysctl.read("kern.memorystatus_level", as: Int32.self).map(Double.init) ?? 100
        let pressureLevel = Sysctl.read("kern.memorystatus_vm_pressure_level", as: Int32.self) ?? 1

        return MemorySnapshot(
            total: totalBytes,
            active: UInt64(stats.active_count) * pageSize,
            inactive: UInt64(stats.inactive_count) * pageSize,
            // Igual que `vm_stat`: las páginas especulativas se cuentan aparte.
            free: UInt64(stats.free_count > stats.speculative_count ? stats.free_count - stats.speculative_count : 0) * pageSize,
            app: (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize,
            wired: UInt64(stats.wire_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize,
            cached: (UInt64(stats.external_page_count) + purgeable) * pageSize,
            swapUsed: Sysctl.swapUsage()?.xsu_used ?? 0,
            pressure: MemoryPressure(rawValue: Int(pressureLevel)) ?? .normal,
            pressureFraction: max(0, min(1, 1 - level / 100))
        )
    }
}

enum DiskReader {
    /// Mismo cálculo que Finder: el espacio disponible incluye lo purgable.
    static func sample() -> DiskSnapshot? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        return DiskSnapshot(
            total: Int64(total),
            available: values.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}
