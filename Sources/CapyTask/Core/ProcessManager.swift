import Darwin
import Foundation

/// Enumera procesos con libproc y calcula su consumo entre dos muestras.
///
/// macOS solo deja leer CPU/memoria (`PROC_PIDTASKALLINFO`) de los procesos
/// del propio usuario. Para los del sistema (root, _windowserver…) se recurre a
/// `/bin/ps`, que es setuid root y viene con macOS; solo se usa mientras la
/// ventana principal está visible.
struct ProcessManager {
    private struct CPUMark {
        let startTime: UInt64
        let cpuNanos: Double
    }

    private var identities: [Int32: ProcessIdentity] = [:]
    private var bundleNames: [String: String] = [:]
    private var lastCPU: [Int32: CPUMark] = [:]
    private var lastWall: UInt64 = 0
    private var lastPrivileged: [Int32: PrivilegedReading] = [:]
    private var lastPrivilegedWall: UInt64 = 0
    private var privilegedCPU: [Int32: Double] = [:]
    private let nanosPerTick: Double
    private let userID = getuid()
    private let home = NSHomeDirectory()

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosPerTick = timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }

    /// Olvida el historial y las cachés (al cerrar la ventana).
    mutating func reset() {
        identities = [:]
        bundleNames = [:]
        lastCPU = [:]
        lastWall = 0
        lastPrivileged = [:]
        lastPrivilegedWall = 0
        privilegedCPU = [:]
    }

    mutating func sample(runningApps: [RunningAppInfo], privileged: [Int32: PrivilegedReading]?) -> [ProcessSample] {
        let now = DispatchTime.now().uptimeNanoseconds
        let wallDelta = lastWall > 0 ? Double(now - lastWall) : 0
        if let privileged { absorbPrivileged(privileged, now: now) }

        let regular = Dictionary(runningApps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let pids = Self.listPIDs()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(pids.count)
        var nextCPU: [Int32: CPUMark] = [:]
        nextCPU.reserveCapacity(pids.count)

        for pid in pids {
            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size {
                var comm = Self.string(fromCTuple: info.pbsd.pbi_name)
                if comm.isEmpty { comm = Self.string(fromCTuple: info.pbsd.pbi_comm) }
                let identity = identity(for: pid, comm: comm, regular: regular[pid])
                let cpuNanos = Double(info.ptinfo.pti_total_user + info.ptinfo.pti_total_system) * nanosPerTick
                let start = UInt64(info.pbsd.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbsd.pbi_start_tvusec)
                var cpu: Double?
                if let previous = lastCPU[pid], previous.startTime == start, wallDelta > 0, cpuNanos >= previous.cpuNanos {
                    cpu = (cpuNanos - previous.cpuNanos) / wallDelta * 100
                }
                nextCPU[pid] = CPUMark(startTime: start, cpuNanos: cpuNanos)
                samples.append(ProcessSample(
                    pid: pid,
                    name: identity.name,
                    path: identity.path,
                    bundlePath: identity.bundlePath,
                    appName: identity.appName,
                    isUserApp: identity.isUserApp || regular[pid] != nil,
                    // Como kill(2): basta con que coincida el uid real o el efectivo
                    // (un `top` setuid lanzado por ti sigue siendo tuyo).
                    isOwnedByUser: info.pbsd.pbi_uid == userID || info.pbsd.pbi_ruid == userID,
                    cpuPercent: cpu,
                    memoryBytes: Self.footprint(pid) ?? info.ptinfo.pti_resident_size,
                    threadCount: Int(info.ptinfo.pti_threadnum)
                ))
            } else {
                var short = proc_bsdshortinfo()
                let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
                let comm: String
                let ownedByUser: Bool
                if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize {
                    comm = Self.string(fromCTuple: short.pbsi_comm)
                    ownedByUser = short.pbsi_uid == userID || short.pbsi_ruid == userID
                } else if pid == 0 {
                    comm = "kernel_task"
                    ownedByUser = false
                } else {
                    continue // terminó entre el listado y la lectura
                }
                let identity = identity(for: pid, comm: comm, regular: regular[pid])
                samples.append(ProcessSample(
                    pid: pid,
                    name: identity.name,
                    path: identity.path,
                    bundlePath: identity.bundlePath,
                    appName: identity.appName,
                    isUserApp: identity.isUserApp || regular[pid] != nil,
                    isOwnedByUser: ownedByUser,
                    cpuPercent: privilegedCPU[pid],
                    memoryBytes: lastPrivileged[pid]?.rssBytes,
                    threadCount: nil
                ))
            }
        }

        lastCPU = nextCPU
        lastWall = now
        if identities.count > samples.count * 2 {
            let alive = Set(pids)
            identities = identities.filter { alive.contains($0.key) }
        }
        return samples
    }

    private mutating func absorbPrivileged(_ readings: [Int32: PrivilegedReading], now: UInt64) {
        if lastPrivilegedWall > 0 {
            let wallCentis = Double(now - lastPrivilegedWall) / 10_000_000
            var cpu: [Int32: Double] = [:]
            if wallCentis > 0 {
                for (pid, reading) in readings {
                    guard let previous = lastPrivileged[pid], reading.cpuCentiseconds >= previous.cpuCentiseconds else { continue }
                    cpu[pid] = Double(reading.cpuCentiseconds - previous.cpuCentiseconds) / wallCentis * 100
                }
            }
            privilegedCPU = cpu
        }
        lastPrivileged = readings
        lastPrivilegedWall = now
    }

    private mutating func identity(for pid: Int32, comm: String, regular: RunningAppInfo?) -> ProcessIdentity {
        if let cached = identities[pid], cached.comm == comm {
            return cached
        }
        let path = Self.path(for: pid)
        let bundle = path.flatMap(ProcessNaming.outermostBundle)
        var appName: String?
        if let bundle {
            if let known = bundleNames[bundle] {
                appName = known
            } else {
                let resolved = ProcessNaming.displayName(forBundle: bundle)
                bundleNames[bundle] = resolved
                appName = resolved
            }
        }
        let name: String
        if let regularName = regular?.name, !regularName.isEmpty {
            name = regularName
        } else if let bundle, let path, let appName, ProcessNaming.isMainExecutable(path: path, bundle: bundle) {
            name = appName
        } else if let path {
            name = ProcessNaming.friendlyName(forExecutable: (path as NSString).lastPathComponent)
        } else {
            name = comm
        }
        let identity = ProcessIdentity(
            comm: comm,
            name: name,
            path: path,
            bundlePath: bundle,
            appName: appName,
            isUserApp: bundle.map { ProcessNaming.isInUserAppLocation($0, home: home) } ?? false
        )
        identities[pid] = identity
        return identity
    }

    // MARK: - libproc

    static func listPIDs() -> [Int32] {
        // Con búfer nulo devuelve los bytes necesarios; se deja margen por si
        // nacen procesos entre las dos llamadas.
        let neededBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard neededBytes > 0 else { return [] }
        let stride = MemoryLayout<Int32>.stride
        var pids = [Int32](repeating: 0, count: Int(neededBytes) / stride + 64)
        let filledBytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard filledBytes > 0 else { return [] }
        // pid 0 (kernel_task) es válido, pero solo una vez.
        var seenKernel = false
        return pids.prefix(Int(filledBytes) / stride).filter { pid in
            guard pid == 0 else { return true }
            defer { seenKernel = true }
            return !seenKernel
        }
    }

    static func path(for pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// `phys_footprint`: la cifra de la columna "Memoria" de Monitor de Actividad.
    static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    static func string<T>(fromCTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

struct ProcessIdentity: Sendable {
    let comm: String
    let name: String
    let path: String?
    let bundlePath: String?
    let appName: String?
    let isUserApp: Bool
}

enum ProcessNaming {
    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Helper` → `/Applications/Google Chrome.app`
    static func outermostBundle(in path: String) -> String? {
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path.hasSuffix(".app") ? path : nil
    }

    static func isMainExecutable(path: String, bundle: String) -> Bool {
        let executable = (path as NSString).lastPathComponent
        return path == bundle + "/Contents/MacOS/" + executable
    }

    static func isInUserAppLocation(_ bundle: String, home: String) -> Bool {
        let prefixes = [
            "/Applications/",
            home + "/Applications/",
            "/System/Applications/",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/",
            "/System/Cryptexes/App/System/Applications/",
        ]
        return prefixes.contains { bundle.hasPrefix($0) }
    }

    private static let knownServices = [
        "com.apple.WebKit.WebContent": "Contenido web (WebKit)",
        "com.apple.WebKit.GPU": "GPU web (WebKit)",
        "com.apple.WebKit.Networking": "Red web (WebKit)",
    ]

    static func friendlyName(forExecutable executable: String) -> String {
        knownServices[executable] ?? executable
    }

    static func displayName(forBundle bundle: String) -> String {
        let name = FileManager.default.displayName(atPath: bundle)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

// MARK: - Procesos del sistema vía /bin/ps

struct PrivilegedReading: Sendable, Equatable {
    let cpuCentiseconds: UInt64
    let rssBytes: UInt64
}

enum PrivilegedStatsReader {
    static func read() async -> [Int32: PrivilegedReading]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readBlocking())
            }
        }
    }

    private static func readBlocking() -> [Int32: PrivilegedReading]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,time=,rss="]
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> [Int32: PrivilegedReading] {
        var result: [Int32: PrivilegedReading] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  let cpu = parseCPUTime(fields[1]),
                  let rssKB = UInt64(fields[2]) else { continue }
            result[pid] = PrivilegedReading(cpuCentiseconds: cpu, rssBytes: rssKB * 1024)
        }
        return result
    }

    /// Acepta `MM:SS.cc`, `HH:MM:SS.cc` y `D-HH:MM:SS.cc`; devuelve centésimas.
    static func parseCPUTime<S: StringProtocol>(_ text: S) -> UInt64? {
        var days: UInt64 = 0
        var clock = Substring(text)
        if let dash = clock.firstIndex(of: "-") {
            guard let parsedDays = UInt64(clock[..<dash]) else { return nil }
            days = parsedDays
            clock = clock[clock.index(after: dash)...]
        }
        let parts = clock.split(separator: ":")
        guard (1...3).contains(parts.count), let secondsPart = parts.last else { return nil }
        let secondsFields = secondsPart.split(separator: ".", omittingEmptySubsequences: false)
        guard let seconds = UInt64(secondsFields[0]) else { return nil }
        var centis: UInt64 = 0
        if secondsFields.count > 1 {
            let fraction = String(secondsFields[1].prefix(2)).padding(toLength: 2, withPad: "0", startingAt: 0)
            guard let value = UInt64(fraction) else { return nil }
            centis = value
        }
        var minutes: UInt64 = 0
        var hours: UInt64 = 0
        if parts.count >= 2 {
            guard let value = UInt64(parts[parts.count - 2]) else { return nil }
            minutes = value
        }
        if parts.count == 3 {
            guard let value = UInt64(parts[0]) else { return nil }
            hours = value
        }
        let totalSeconds = ((days * 24 + hours) * 60 + minutes) * 60 + seconds
        return totalSeconds * 100 + centis
    }
}

// MARK: - Finalizar procesos

enum KillOutcome: Sendable, Equatable {
    case terminated
    case forceKilled
    case alreadyGone
    case notPermitted
    case protected
    case failed(Int32)
}

enum ProcessKiller {
    /// SIGTERM y, si a los 3 segundos sigue vivo el mismo proceso, SIGKILL.
    static func terminate(pid: Int32, grace: Duration = .seconds(3)) async -> KillOutcome {
        guard pid > 1, pid != getpid() else { return .protected }
        let originalStart = startTime(of: pid)
        if kill(pid, SIGTERM) != 0 {
            switch errno {
            case ESRCH: return .alreadyGone
            case EPERM: return .notPermitted
            default: return .failed(errno)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: grace)
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if !isAlive(pid, start: originalStart) { return .terminated }
        }
        guard isAlive(pid, start: originalStart) else { return .terminated }
        if kill(pid, SIGKILL) != 0 {
            return errno == ESRCH ? .terminated : .failed(errno)
        }
        return .forceKilled
    }

    private static func isAlive(_ pid: Int32, start: UInt64?) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        // Si el PID se reutilizó, el instante de arranque ya no coincide.
        guard let start else { return true }
        return startTime(of: pid) == start
    }

    private static func startTime(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }
}
