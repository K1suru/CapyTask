import AppKit
import Observation

/// Hace todas las lecturas fuera del hilo principal.
actor MetricsSampler {
    private var cpuReader = CPUReader()
    private let memoryReader = MemoryReader()
    private var processManager = ProcessManager()
    private var lastPrivilegedRead: ContinuousClock.Instant?
    private var samplingProcesses = false
    private var selfMark: (cpuNanos: Double, wall: UInt64)?
    private let nanosPerTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosPerTick = timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }

    func sample(_ request: SampleRequest) async -> MetricsSnapshot {
        let cpu = cpuReader.sample()
        let memory = memoryReader.sample()
        let disk = request.includeDisk ? DiskReader.sample() : nil

        var processes: [ProcessSample]?
        if request.includeProcesses {
            let clock = ContinuousClock()
            var privileged: [Int32: PrivilegedReading]?
            if lastPrivilegedRead.map({ clock.now - $0 >= .seconds(2) }) ?? true {
                privileged = await PrivilegedStatsReader.read()
                lastPrivilegedRead = clock.now
            }
            processes = processManager.sample(runningApps: request.runningApps, privileged: privileged)
            samplingProcesses = true
        } else if samplingProcesses && !request.keepProcessHistory {
            processManager.reset()
            lastPrivilegedRead = nil
            samplingProcesses = false
        }

        return MetricsSnapshot(cpu: cpu, memory: memory, disk: disk, processes: processes, selfUsage: selfUsage())
    }

    private func selfUsage() -> SelfUsage {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return SelfUsage() }
        let now = DispatchTime.now().uptimeNanoseconds
        let cpuNanos = Double(info.ri_user_time + info.ri_system_time) * nanosPerTick
        var cpuPercent = 0.0
        if let mark = selfMark, now > mark.wall {
            cpuPercent = max(0, cpuNanos - mark.cpuNanos) / Double(now - mark.wall) * 100
        }
        selfMark = (cpuNanos, now)
        return SelfUsage(memoryBytes: info.ri_phys_footprint, cpuPercent: cpuPercent)
    }
}

/// Motor central de métricas, compartido por toda la app.
@MainActor
@Observable
final class SystemMonitorEngine {
    static let shared = SystemMonitorEngine()
    static let historyLength = 60

    private(set) var cpu = CPUSnapshot()
    private(set) var memory = MemorySnapshot()
    private(set) var disk = DiskSnapshot()
    private(set) var processes: [ProcessSample] = []
    private(set) var apps: [AppUsage] = []
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    /// 0...1: max(CPU suavizada, estrés de memoria). Ver `StressModel`.
    private(set) var stress: Double = 0
    private(set) var mood: CapyMood = .normal
    private(set) var selfUsage = SelfUsage()
    private(set) var interval: Double = 2.5
    private(set) var hasProcessData = false

    let cpuModel = CPUTopology.modelName
    let coreKinds = CPUTopology.coreKinds()
    let totalMemory = MemoryReader().totalBytes

    // Demanda: la fijan los controladores de ventana, mascota y menú.
    /// La ventana existe (aunque esté tapada o minimizada): se conserva la última lista.
    var mainWindowOpen = false
    /// La ventana se ve en pantalla: solo entonces se muestrean procesos.
    var mainWindowVisible = false { didSet { if mainWindowVisible != oldValue { demandChanged() } } }
    var mainWindowFocused = false { didSet { if mainWindowFocused != oldValue { demandChanged() } } }
    var petVisible = false { didSet { if petVisible != oldValue { demandChanged() } } }
    var menuOpen = false { didSet { if menuOpen != oldValue { demandChanged() } } }
    var menuBarShowsValue = false { didSet { if menuBarShowsValue != oldValue { demandChanged() } } }

    @ObservationIgnored private let sampler = MetricsSampler()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var smoothedCPU: Double?
    @ObservationIgnored private var lastDiskRead: Date?
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var performanceCoreCount: Int { coreKinds.filter { $0 == .performance }.count }
    var efficiencyCoreCount: Int { coreKinds.filter { $0 == .efficiency }.count }

    private init() {}

    func start() {
        guard loop == nil else { return }
        observeSleep()
        loop = Task { [weak self] in
            await self?.prime()
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await self.tick()
                await self.sleep(pause)
            }
        }
    }

    /// Corta la espera actual para muestrear ya (p. ej. al abrir la ventana).
    func refreshNow() {
        sleeper?.cancel()
    }

    // MARK: - Bucle

    private var desiredInterval: Double {
        if screensAsleep { return 10 }
        if mainWindowVisible && mainWindowFocused { return 1.0 }
        if mainWindowVisible || petVisible || menuOpen || menuBarShowsValue { return 2.5 }
        return 5.0
    }

    private func demandChanged() {
        let wanted = desiredInterval
        let shouldHurry = wanted < interval || (mainWindowVisible && !hasProcessData) || menuOpen
        interval = wanted
        if shouldHurry { refreshNow() }
    }

    private func prime() async {
        _ = await sampler.sample(SampleRequest(includeProcesses: false, keepProcessHistory: false, includeDisk: false, runningApps: []))
        await sleep(0.5)
    }

    private func sleep(_ seconds: Double) async {
        let task = Task {
            _ = try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(seconds * 0.1))
        }
        sleeper = task
        await task.value
        sleeper = nil
    }

    /// Devuelve cuánto esperar hasta la siguiente muestra.
    private func tick() async -> Double {
        let needsProcesses = mainWindowVisible
        let now = Date()
        let diskMaxAge: TimeInterval = needsProcesses ? 10 : 120
        let includeDisk = lastDiskRead.map { now.timeIntervalSince($0) >= diskMaxAge } ?? true
        let runningApps: [RunningAppInfo] = needsProcesses
            ? NSWorkspace.shared.runningApplications.compactMap {
                $0.activationPolicy == .regular ? RunningAppInfo(pid: $0.processIdentifier, name: $0.localizedName) : nil
            }
            : []

        let wasMissingProcesses = !hasProcessData
        let snapshot = await sampler.sample(SampleRequest(
            includeProcesses: needsProcesses,
            keepProcessHistory: mainWindowOpen,
            includeDisk: includeDisk,
            runningApps: runningApps
        ))
        apply(snapshot, at: now)
        interval = desiredInterval
        // La primera muestra de procesos solo fija la base del delta de CPU.
        if needsProcesses && wasMissingProcesses { return 0.6 }
        return interval
    }

    private func apply(_ snapshot: MetricsSnapshot, at date: Date) {
        cpu = snapshot.cpu
        memory = snapshot.memory
        selfUsage = snapshot.selfUsage
        if let disk = snapshot.disk {
            self.disk = disk
            lastDiskRead = date
        }
        if let processes = snapshot.processes {
            self.processes = processes
            apps = AppUsage.group(processes)
            hasProcessData = true
        } else if hasProcessData && !mainWindowOpen {
            // Ventana cerrada: soltamos la lista para mantener la app ligera.
            processes = []
            apps = []
            hasProcessData = false
        }
        // La primera lectura de CPU no tiene delta todavía: no la registramos.
        if !snapshot.cpu.cores.isEmpty {
            cpuHistory = Self.appending(snapshot.cpu.usage, to: cpuHistory)
            memoryHistory = Self.appending(snapshot.memory.usedFraction, to: memoryHistory)
        }
        updateMood()
    }

    private static func appending(_ value: Double, to history: [Double]) -> [Double] {
        var history = history
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
        return history
    }

    private func updateMood() {
        let smoothed = smoothedCPU.map { $0 * 0.6 + cpu.usage * 0.4 } ?? cpu.usage
        smoothedCPU = smoothed
        let newStress = StressModel.stress(cpu: smoothed, memory: memory)
        if abs(newStress - stress) > 0.001 { stress = newStress }

        let next = CapyMood.resolve(stress: newStress, current: mood)
        if next != mood { mood = next }
    }

    /// Estos avisos pueden llegar en el hilo principal pero fuera de la cola
    /// principal (p. ej. al despertar la pantalla), así que se re-encolan.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let asleep: [Notification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification]
        let awake: [Notification.Name] = [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification]
        for name in asleep {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                onMainQueue { self?.setScreensAsleep(true) }
            })
        }
        for name in awake {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                onMainQueue { self?.setScreensAsleep(false) }
            })
        }
    }

    private func setScreensAsleep(_ asleep: Bool) {
        guard screensAsleep != asleep else { return }
        screensAsleep = asleep
        if !asleep { refreshNow() }
        demandChanged()
    }
}
