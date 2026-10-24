import Foundation

// MARK: - CPU

enum CoreKind: String, Sendable {
    case performance
    case efficiency
    case standard

    var shortLabel: String {
        switch self {
        case .performance: "P"
        case .efficiency: "E"
        case .standard: ""
        }
    }
}

struct CoreLoad: Sendable, Identifiable, Equatable {
    let id: Int
    let kind: CoreKind
    /// 0...1
    let usage: Double
}

struct CPUSnapshot: Sendable, Equatable {
    /// Carga global 0...1 (todos los núcleos).
    var usage: Double = 0
    var user: Double = 0
    var system: Double = 0
    var cores: [CoreLoad] = []
}

// MARK: - Memoria

enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: L("Normal", "Normal")
        case .warning: L("Elevada", "Elevated")
        case .critical: L("Crítica", "Critical")
        }
    }
}

/// Desglose equivalente al de Monitor de Actividad.
struct MemorySnapshot: Sendable, Equatable {
    var total: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var free: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal
    /// 0...1, derivado de `kern.memorystatus_level` (porcentaje libre según el kernel).
    var pressureFraction: Double = 0

    /// "Memoria usada" = App + Wired + Comprimida.
    var used: UInt64 { app + wired + compressed }
    var available: UInt64 { total > used ? total - used : 0 }
    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

// MARK: - Disco

struct DiskSnapshot: Sendable, Equatable {
    var total: Int64 = 0
    var available: Int64 = 0

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

// MARK: - Procesos

struct ProcessSample: Sendable, Identifiable, Equatable {
    let pid: Int32
    let name: String
    let path: String?
    /// Bundle `.app` más externo al que pertenece (para icono y agrupación).
    let bundlePath: String?
    let appName: String?
    let isUserApp: Bool
    let isOwnedByUser: Bool
    /// `nil` cuando aún no hay dos muestras o macOS no permite leerlo.
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let threadCount: Int?

    var id: Int32 { pid }
    var cpuSortValue: Double { cpuPercent ?? -1 }
    var memorySortValue: UInt64 { memoryBytes ?? 0 }
    var kindSortValue: Int { isUserApp ? 0 : 1 }
}

/// Procesos agrupados por aplicación (p. ej. Chrome + todos sus "Helper").
struct AppUsage: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    let executablePath: String?
    let cpuPercent: Double
    let memoryBytes: UInt64
    let processCount: Int
    let isUserApp: Bool
    /// Falso hasta tener dos muestras (o el dato de `ps` para procesos del sistema).
    let cpuMeasured: Bool

    static func group(_ processes: [ProcessSample]) -> [AppUsage] {
        var buckets: [String: [ProcessSample]] = [:]
        for process in processes {
            let key = process.bundlePath ?? "pid:\(process.pid)"
            buckets[key, default: []].append(process)
        }
        return buckets.map { key, members in
            let lead = members.min { $0.pid < $1.pid } ?? members[0]
            return AppUsage(
                id: key,
                name: lead.bundlePath != nil ? (lead.appName ?? lead.name) : lead.name,
                bundlePath: lead.bundlePath,
                executablePath: lead.path,
                cpuPercent: members.reduce(0) { $0 + ($1.cpuPercent ?? 0) },
                memoryBytes: members.reduce(0) { $0 + ($1.memoryBytes ?? 0) },
                processCount: members.count,
                isUserApp: members.contains { $0.isUserApp },
                cpuMeasured: members.contains { $0.cpuPercent != nil }
            )
        }
    }
}

/// Apps regulares (con Dock) según NSWorkspace; se capturan en el hilo principal.
struct RunningAppInfo: Sendable {
    let pid: Int32
    let name: String?
}

struct SelfUsage: Sendable, Equatable {
    var memoryBytes: UInt64 = 0
    var cpuPercent: Double = 0
}

struct SampleRequest: Sendable {
    var includeProcesses: Bool
    /// Mantener la base del delta de CPU aunque esta vez no se muestreen procesos.
    var keepProcessHistory: Bool
    var includeDisk: Bool
    var runningApps: [RunningAppInfo]
}

struct MetricsSnapshot: Sendable {
    var cpu: CPUSnapshot
    var memory: MemorySnapshot
    var disk: DiskSnapshot?
    var processes: [ProcessSample]?
    var selfUsage: SelfUsage
}
