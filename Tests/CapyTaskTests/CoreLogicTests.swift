import Darwin
import Foundation
import Testing
@testable import CapyTask

@Suite("Ánimo del capibara")
struct MoodTests {
    @Test("Umbrales: normal < 40%, preocupado 40–75%, estresado > 75%", arguments: [
        (0.0, CapyMood.normal), (0.39, .normal), (0.40, .worried), (0.60, .worried),
        (0.75, .worried), (0.76, .stressed), (1.0, .stressed),
    ])
    func bands(stress: Double, expected: CapyMood) {
        #expect(CapyMood.band(for: stress) == expected)
    }

    @Test func climbsImmediately() {
        #expect(CapyMood.resolve(stress: 0.80, current: .normal) == .stressed)
    }

    @Test func hysteresisWhenCalmingDown() {
        // Justo por debajo del umbral: no baja todavía.
        #expect(CapyMood.resolve(stress: 0.73, current: .stressed) == .stressed)
        #expect(CapyMood.resolve(stress: 0.71, current: .stressed) == .worried)
        #expect(CapyMood.resolve(stress: 0.38, current: .worried) == .worried)
        #expect(CapyMood.resolve(stress: 0.36, current: .worried) == .normal)
        #expect(CapyMood.resolve(stress: 0.20, current: .stressed) == .normal)
    }

    @Test func memoryPressureDrivesStress() {
        var memory = MemorySnapshot(total: 8, pressure: .normal, pressureFraction: 0.55)
        #expect(StressModel.memoryStress(memory) < CapyMood.thresholds[0])
        memory.pressure = .warning
        #expect(CapyMood.band(for: StressModel.memoryStress(memory)) == .worried)
        memory.pressure = .critical
        #expect(CapyMood.band(for: StressModel.memoryStress(memory)) == .stressed)
        #expect(StressModel.stress(cpu: 0.9, memory: MemorySnapshot()) == 0.9)
    }
}

@Suite("Lecturas de CPU")
struct CPUTests {
    @Test func deltaMathHandlesWraparound() {
        // Un núcleo: user, system, idle, nice
        let previous: [UInt32] = [UInt32.max - 9, 0, 100, 0]
        let current: [UInt32] = [10, 20, 160, 0]   // user +20 (con vuelta), system +20, idle +60
        let snapshot = CPUReader.snapshot(previous: previous, current: current, kinds: [.performance])
        #expect(abs(snapshot.usage - 0.4) < 0.0001)
        #expect(abs(snapshot.user - 0.2) < 0.0001)
        #expect(snapshot.cores.count == 1)
        #expect(snapshot.cores[0].kind == .performance)
    }

    @Test func liveCoresMatchSysctl() {
        let ticks = CPUReader.readTicks()
        let logical = Int(Sysctl.read("hw.logicalcpu", as: Int32.self) ?? 0)
        #expect(ticks?.count == logical * Int(CPU_STATE_MAX))
        #expect(CPUTopology.coreKinds().count == logical)
    }
}

@Suite("Memoria y disco")
struct MemoryTests {
    @Test func liveMemoryIsCoherent() {
        let memory = MemoryReader().sample()
        #expect(memory.total == Sysctl.read("hw.memsize", as: UInt64.self))
        #expect(memory.used > 0)
        #expect(memory.used <= memory.total)
        #expect((0...1).contains(memory.pressureFraction))
        #expect(memory.active > 0 && memory.inactive > 0)
        let pages = memory.active + memory.inactive + memory.wired + memory.compressed + memory.free
        #expect(pages <= memory.total, "activa+inactiva+wired+comprimida+libre no puede superar la RAM física")
        #expect(pages > memory.total / 2)
    }

    @Test func diskIsReadable() throws {
        let disk = try #require(DiskReader.sample())
        #expect(disk.total > 0)
        #expect(disk.available > 0 && disk.available <= disk.total)
    }
}

@Suite("Procesos")
struct ProcessTests {
    @Test("Tiempo de CPU de ps", arguments: [
        ("0:00.00", UInt64(0)), ("2:49.21", 16921), ("119:17.54", 715754),
        ("1:02:03.04", 372304), ("1-00:00:01.5", 8640150),
    ])
    func parsesPSTime(text: String, centis: UInt64) {
        #expect(PrivilegedStatsReader.parseCPUTime(text) == centis)
    }

    @Test func parsesPSOutput() {
        let output = "    1 119:17.54  14832\n  343   2:49.21   7200\nbasura\n"
        let parsed = PrivilegedStatsReader.parse(output)
        #expect(parsed.count == 2)
        #expect(parsed[343] == PrivilegedReading(cpuCentiseconds: 16921, rssBytes: 7200 * 1024))
    }

    @Test func bundleNaming() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(ProcessNaming.outermostBundle(in: helper) == "/Applications/Google Chrome.app")
        #expect(!ProcessNaming.isMainExecutable(path: helper, bundle: "/Applications/Google Chrome.app"))
        #expect(ProcessNaming.isMainExecutable(path: "/Applications/Safari.app/Contents/MacOS/Safari", bundle: "/Applications/Safari.app"))
        #expect(ProcessNaming.outermostBundle(in: "/usr/libexec/trustd") == nil)
        #expect(ProcessNaming.isInUserAppLocation("/System/Applications/Notes.app", home: "/Users/x"))
        #expect(ProcessNaming.isInUserAppLocation("/Users/x/Applications/Foo.app", home: "/Users/x"))
        #expect(!ProcessNaming.isInUserAppLocation("/System/Library/CoreServices/Dock.app", home: "/Users/x"))
    }

    @Test func groupsHelpersUnderTheirApp() {
        func sample(_ pid: Int32, _ bundle: String?, cpu: Double, mem: UInt64) -> ProcessSample {
            ProcessSample(pid: pid, name: "p\(pid)", path: nil, bundlePath: bundle, appName: bundle == nil ? nil : "Chrome",
                          isUserApp: bundle != nil, isOwnedByUser: true, cpuPercent: cpu, memoryBytes: mem, threadCount: 1)
        }
        let groups = AppUsage.group([
            sample(10, "/Applications/Chrome.app", cpu: 5, mem: 100),
            sample(11, "/Applications/Chrome.app", cpu: 7, mem: 50),
            sample(12, nil, cpu: 1, mem: 10),
        ])
        let chrome = try? #require(groups.first { $0.id == "/Applications/Chrome.app" })
        #expect(groups.count == 2)
        #expect(chrome?.cpuPercent == 12)
        #expect(chrome?.memoryBytes == 150)
        #expect(chrome?.processCount == 2)
        #expect(chrome?.name == "Chrome")
        #expect(chrome?.cpuMeasured == true)
        let unmeasured = AppUsage.group([
            ProcessSample(pid: 1, name: "x", path: nil, bundlePath: nil, appName: nil, isUserApp: false,
                          isOwnedByUser: false, cpuPercent: nil, memoryBytes: nil, threadCount: nil)
        ])
        #expect(unmeasured.first?.cpuMeasured == false)
    }

    @Test func liveSampleFindsOwnProcessWithRealNumbers() async throws {
        var manager = ProcessManager()
        _ = manager.sample(runningApps: [], privileged: nil)
        // Quemamos un poco de CPU para que el delta no sea cero.
        let clock = ContinuousClock()
        let end = clock.now + .milliseconds(300)
        var x = 0.0
        while clock.now < end { x += sin(x) + 1 }
        #expect(x > 0)
        let samples = manager.sample(runningApps: [], privileged: nil)
        let me = try #require(samples.first { $0.pid == getpid() })
        #expect(me.isOwnedByUser)
        #expect((me.memoryBytes ?? 0) > 1_000_000)
        let cpu = try #require(me.cpuPercent)
        #expect(cpu > 30, "CPU propio medido: \(cpu)%")
        // Otros tests corren en paralelo en este proceso: el tope solo descarta
        // errores de unidades (sin convertir ticks de Mach saldría ~40 veces más).
        #expect(cpu < 100 * Double(ProcessInfo.processInfo.activeProcessorCount) + 10)
        #expect(samples.count > 50)
    }

    @Test func privilegedReaderSeesSystemProcesses() async throws {
        let readings = try #require(await PrivilegedStatsReader.read())
        #expect(readings[1] != nil, "launchd (root) debería aparecer vía ps")
        #expect(readings.count > 100)
    }
}

@Suite("Formato")
struct FormatTests {
    @Test func bytes() {
        let es = Locale(identifier: "es_ES")
        #expect(Format.bytes(UInt64(512 * 1024 * 1024), locale: es) == "512 MB")
        #expect(Format.bytes(UInt64(1536 * 1024 * 1024), locale: es) == "1,5 GB")
        #expect(Format.bytes(UInt64(800 * 1024), locale: es) == "800 KB")
        #expect(Format.bytes(UInt64(12_345 * 1024 * 1024), locale: es) == "12,1 GB")
    }

    @Test func percents() {
        let es = Locale(identifier: "es_ES")
        #expect(Format.percent(0.237) == "24%")
        #expect(Format.cpu(3.456, locale: es) == "3,5%")
        #expect(Format.cpu(123.4, locale: es) == "123%")
    }
}

@Suite("Coincidencia con top")
struct TopComparisonTests {
    /// `top` informa wired y compressor con el mismo origen (host_statistics64).
    @Test func wiredAndCompressedMatchTop() throws {
        let memory = MemoryReader().sample()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "1", "-n", "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("PhysMem:") })
        func megabytes(before label: String) -> Double? {
            guard let range = line.range(of: label) else { return nil }
            let prefix = line[..<range.lowerBound]
            let token = prefix.split(whereSeparator: { $0 == " " || $0 == "(" }).last ?? ""
            guard let unit = token.last, let value = Double(token.dropLast()) else { return nil }
            return unit == "G" ? value * 1024 : unit == "K" ? value / 1024 : value
        }
        let topWired = try #require(megabytes(before: " wired"))
        let topCompressed = try #require(megabytes(before: " compressor"))
        let ourWired = Double(memory.wired) / 1_048_576
        let ourCompressed = Double(memory.compressed) / 1_048_576
        #expect(abs(ourWired - topWired) / topWired < 0.1, "wired: nuestro \(ourWired) MB vs top \(topWired) MB")
        #expect(abs(ourCompressed - topCompressed) / max(topCompressed, 1) < 0.1, "compressor: nuestro \(ourCompressed) MB vs top \(topCompressed) MB")
    }
}

@Suite("Finalizar Tarea")
struct KillTests {
    private func spawn(_ path: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        return process
    }

    @Test func politeTerminationWithSigterm() async throws {
        let child = try spawn("/bin/sleep", ["30"])
        try await Task.sleep(for: .milliseconds(200))
        let outcome = await ProcessKiller.terminate(pid: child.processIdentifier, grace: .seconds(2))
        #expect(outcome == .terminated)
        #expect(!child.isRunning)
    }

    @Test func escalatesToSigkillWhenIgnored() async throws {
        let child = try spawn("/usr/bin/perl", ["-e", "$SIG{TERM}='IGNORE'; sleep 30"])
        try await Task.sleep(for: .milliseconds(300))
        let outcome = await ProcessKiller.terminate(pid: child.processIdentifier, grace: .milliseconds(800))
        #expect(outcome == .forceKilled)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!child.isRunning)
    }

    @Test func refusesProtectedProcesses() async {
        #expect(await ProcessKiller.terminate(pid: 1) == .protected)
        #expect(await ProcessKiller.terminate(pid: getpid()) == .protected)
    }

    @Test func reportsMissingPermission() async throws {
        // Un daemon de root de verdad (uid real, efectivo y guardado = 0): kill()
        // devuelve EPERM sin entregar la señal. Se excluyen los setuid lanzados
        // por el usuario (p. ej. el `top` de otro test), que sí son señalizables.
        let rootProcess = try #require(ProcessManager.listPIDs().first { pid in
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            return pid > 1 && proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size
                && info.pbsi_uid == 0 && info.pbsi_ruid == 0 && info.pbsi_svuid == 0
        })
        #expect(await ProcessKiller.terminate(pid: rootProcess) == .notPermitted)
    }
}
