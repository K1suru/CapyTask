import Darwin
import Foundation
import IOKit

/// Carga de CPU por diferencia de ticks entre dos lecturas de `host_processor_info`.
struct CPUReader: Sendable {
    let coreKinds: [CoreKind]
    private var previousTicks: [UInt32] = []

    init() {
        coreKinds = CPUTopology.coreKinds()
    }

    mutating func sample() -> CPUSnapshot {
        guard let ticks = Self.readTicks() else { return CPUSnapshot() }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return CPUSnapshot() }
        return Self.snapshot(previous: previousTicks, current: ticks, kinds: coreKinds)
    }

    /// `ticks` contiene, por núcleo, [user, system, idle, nice]. Los contadores
    /// son de 32 bits y pueden dar la vuelta, por eso se resta con `&-`.
    static func snapshot(previous: [UInt32], current: [UInt32], kinds: [CoreKind]) -> CPUSnapshot {
        let stride = Int(CPU_STATE_MAX)
        let coreCount = current.count / stride
        var cores: [CoreLoad] = []
        cores.reserveCapacity(coreCount)
        var sumUser: UInt64 = 0, sumSystem: UInt64 = 0, sumIdle: UInt64 = 0, sumNice: UInt64 = 0

        for core in 0..<coreCount {
            let base = core * stride
            func delta(_ state: Int32) -> UInt64 {
                UInt64(current[base + Int(state)] &- previous[base + Int(state)])
            }
            let user = delta(CPU_STATE_USER)
            let system = delta(CPU_STATE_SYSTEM)
            let idle = delta(CPU_STATE_IDLE)
            let nice = delta(CPU_STATE_NICE)
            let total = user + system + idle + nice
            sumUser += user
            sumSystem += system
            sumIdle += idle
            sumNice += nice
            cores.append(CoreLoad(
                id: core,
                kind: core < kinds.count ? kinds[core] : .standard,
                usage: total > 0 ? Double(user + system + nice) / Double(total) : 0
            ))
        }

        let total = Double(sumUser + sumSystem + sumIdle + sumNice)
        guard total > 0 else { return CPUSnapshot(cores: cores) }
        return CPUSnapshot(
            usage: Double(sumUser + sumSystem + sumNice) / total,
            user: Double(sumUser + sumNice) / total,
            system: Double(sumSystem) / total,
            cores: cores
        )
    }

    static func readTicks() -> [UInt32]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(HostPort.shared, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        return (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
    }
}

enum CPUTopology {
    static var modelName: String {
        Sysctl.string("machdep.cpu.brand_string") ?? "Procesador"
    }

    /// Tipo de cada núcleo lógico, en el orden de `host_processor_info`.
    static func coreKinds() -> [CoreKind] {
        let count = Int(Sysctl.read("hw.logicalcpu", as: Int32.self) ?? Int32(ProcessInfo.processInfo.processorCount))
        if let fromDeviceTree = deviceTreeKinds(), fromDeviceTree.count == count {
            return fromDeviceTree
        }
        // Apple Silicon numera primero los núcleos de eficiencia.
        if let performance = Sysctl.read("hw.perflevel0.logicalcpu", as: Int32.self),
           let efficiency = Sysctl.read("hw.perflevel1.logicalcpu", as: Int32.self),
           Int(performance + efficiency) == count {
            return Array(repeating: .efficiency, count: Int(efficiency))
                + Array(repeating: .performance, count: Int(performance))
        }
        return Array(repeating: .standard, count: count)
    }

    /// Lee `cluster-type` (E/P) de cada CPU en `IODeviceTree:/cpus`.
    private static func deviceTreeKinds() -> [CoreKind]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var kinds: [Int: CoreKind] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let id = integerProperty(entry, "logical-cpu-id"),
                  let cluster = dataProperty(entry, "cluster-type")?.first else { continue }
            switch cluster {
            case UInt8(ascii: "E"): kinds[id] = .efficiency
            case UInt8(ascii: "P"): kinds[id] = .performance
            default: kinds[id] = .standard
            }
        }
        guard !kinds.isEmpty else { return nil }
        return (0..<kinds.count).map { kinds[$0] ?? .standard }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func dataProperty(_ entry: io_registry_entry_t, _ key: String) -> Data? {
        property(entry, key) as? Data
    }

    private static func integerProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        switch property(entry, key) {
        case let number as NSNumber:
            return number.intValue
        case let data as Data where data.count >= 4:
            return Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        default:
            return nil
        }
    }
}
