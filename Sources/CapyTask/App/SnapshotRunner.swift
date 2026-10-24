import AppKit

/// Modos de diagnóstico:
/// - `CapyTask --snapshot <carpeta>`: abre cada vista, la guarda como PNG,
///   informa métricas y comprueba el hit-testing de la cabecera.
/// - `CapyTask --benchmark`: mide la CPU y memoria de CapyTask en cada escenario.
@MainActor
enum SnapshotRunner {
    static func benchmark(seconds: Double = 30) {
        let engine = SystemMonitorEngine.shared
        let state = AppState.shared
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        func usage() -> (cpu: Double, footprint: UInt64) {
            var info = rusage_info_v2()
            _ = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
                }
            }
            let ticks = Double(info.ri_user_time + info.ri_system_time)
            return (ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9, info.ri_phys_footprint)
        }

        func measure(_ label: String) async {
            try? await Task.sleep(for: .seconds(4)) // dejar que se asiente
            let start = usage()
            let clock = ContinuousClock()
            let began = clock.now
            try? await Task.sleep(for: .seconds(seconds))
            let elapsed = clock.now - began
            let end = usage()
            let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let percent = (end.cpu - start.cpu) / wall * 100
            let window = MainWindowController.shared.window
            let visibility = window.map { $0.occlusionState.contains(.visible) ? "visible" : "tapada" } ?? "cerrada"
            print("benchmark: \(label): CPU \(String(format: "%.2f", percent))% · memoria \(Format.bytes(end.footprint)) · muestreo \(engine.interval) s · ventana \(visibility) · \(engine.processes.count) procesos")
        }

        Task { @MainActor in
            state.petVisible = true
            await measure("solo mascota (ventana cerrada)")

            state.selectedTab = .summary
            MainWindowController.shared.show()
            MainWindowController.shared.window?.level = .floating
            engine.mainWindowFocused = true // simula foco aunque se lance desde una terminal
            await measure("ventana · Resumen Visual")

            state.selectedTab = .processes
            engine.mainWindowFocused = true
            await measure("ventana · Procesos")

            MainWindowController.shared.window?.close()
            try? await Task.sleep(for: .seconds(2))
            await measure("ventana cerrada de nuevo")
            NSApp.terminate(nil)
        }
    }

    static func run(outputDirectory: String) {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SystemMonitorEngine.shared
        let state = AppState.shared

        Task { @MainActor in
            state.selectedTab = .summary
            MainWindowController.shared.show()
            guard let window = MainWindowController.shared.window else {
                print("snapshot: no hay ventana principal")
                NSApp.terminate(nil)
                return
            }
            // Que ninguna otra ventana la tape mientras se captura.
            window.level = .floating
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(6))
            capture(window, to: directory.appending(path: "main-summary.png"))
            reportHeaderHitTesting(in: window)

            window.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .seconds(1))
            capture(window, to: directory.appending(path: "main-summary-dark.png"))
            window.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .seconds(1))
            capture(window, to: directory.appending(path: "main-summary-light.png"))
            state.selectedTab = .processes
            try? await Task.sleep(for: .seconds(2))
            capture(window, to: directory.appending(path: "main-processes-light.png"))
            let previousLanguage = state.language
            state.language = .english
            state.selectedTab = .summary
            try? await Task.sleep(for: .seconds(1.5))
            capture(window, to: directory.appending(path: "main-summary-en.png"))
            state.selectedTab = .processes
            try? await Task.sleep(for: .seconds(1.5))
            capture(window, to: directory.appending(path: "main-processes-en.png"))
            SettingsWindowController.shared.show()
            try? await Task.sleep(for: .seconds(1))
            if let settings = SettingsWindowController.shared.window {
                capture(settings, to: directory.appending(path: "settings-en.png"))
            }
            state.language = previousLanguage
            state.selectedTab = .summary
            window.appearance = nil

            state.selectedTab = .processes
            try? await Task.sleep(for: .seconds(4))
            print("snapshot: pestaña=\(state.selectedTab) oclusión=\(window.occlusionState.contains(.visible)) key=\(window.isKeyWindow)")
            capture(window, to: directory.appending(path: "main-processes.png"))

            SettingsWindowController.shared.show()
            try? await Task.sleep(for: .seconds(1.5))
            if let settings = SettingsWindowController.shared.window {
                capture(settings, to: directory.appending(path: "settings.png"))
            }

            if let pet = NSApp.windows.first(where: { $0 is CapyPetWindow }) {
                let pets = CapyPetController.shared
                print("snapshot: mascota en reposo anima=\(pets.isSpriteAnimating)")
                pets.petHoverChanged(true)
                try? await Task.sleep(for: .seconds(1))
                print("snapshot: cursor encima anima=\(pets.isSpriteAnimating)")
                capture(pet, to: directory.appending(path: "pet.png"))
                pets.petHoverChanged(false)
                try? await Task.sleep(for: .seconds(0.5))
                print("snapshot: cursor fuera anima=\(pets.isSpriteAnimating)")
                print("snapshot: mascota en \(NSStringFromRect(pet.frame)), visible=\(pet.isVisible)")
            }

            print("snapshot: CPU \(Format.percent(engine.cpu.usage)) · RAM \(Format.bytes(engine.memory.used)) de \(Format.bytes(engine.memory.total)) · disco \(Format.percent(engine.disk.usedFraction))")
            print("snapshot: ánimo \(engine.mood.title), estrés \(Format.percent(engine.stress)), intervalo \(engine.interval) s")
            let readable = engine.processes.filter { $0.cpuPercent != nil }.count
            print("snapshot: \(engine.processes.count) procesos, \(readable) con CPU medida, \(engine.processes.filter(\.isUserApp).count) apps de usuario")
            for app in engine.apps.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(6) {
                print("snapshot:   \(app.name): \(Format.cpu(app.cpuPercent)) · \(Format.bytes(app.memoryBytes)) · \(app.processCount) proc.")
            }
            print("snapshot: CapyTask usa \(Format.bytes(engine.selfUsage.memoryBytes)) y \(Format.cpu(engine.selfUsage.cpuPercent)) CPU")
            NSApp.terminate(nil)
        }
    }

    /// `CapyTask --stress-language`: cambia de idioma repetidamente mientras
    /// envía movimientos de ratón a la ventana (reproduce el cierre de 1.0.0).
    static func stressLanguage(rounds: Int = 30) {
        let state = AppState.shared
        Task { @MainActor in
            state.selectedTab = .summary
            MainWindowController.shared.show()
            guard let window = MainWindowController.shared.window else { return }
            window.level = .floating
            try? await Task.sleep(for: .seconds(3))
            let size = window.frame.size
            for round in 0..<rounds {
                state.language = state.language == .spanish ? .english : .spanish
                if round % 10 == 9 { state.selectedTab = state.selectedTab == .summary ? .processes : .summary }
                for step in 0..<12 {
                    let point = NSPoint(x: size.width * (0.15 + 0.06 * Double(step)), y: size.height * (0.35 + 0.03 * Double(step % 5)))
                    if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                        window.sendEvent(event)
                        window.contentView?.hitTest(point)?.mouseMoved(with: event)
                    }
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
            print("stress: \(rounds) cambios de idioma sin fallos")
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: guardado \(url.lastPathComponent)")
    }

    /// Verifica que los clics en la franja de la barra de título lleguen a SwiftUI.
    private static func reportHeaderHitTesting(in window: NSWindow) {
        guard let frameView = window.contentView?.superview, let content = window.contentView else { return }
        let titlebar = window.frame.height - window.contentLayoutRect.height
        let y = frameView.bounds.height - max(titlebar, 38) / 2
        let probes: [(String, CGFloat)] = [
            ("selector de pestañas", frameView.bounds.midX),
            ("interruptor de mascota", frameView.bounds.maxX - 30),
            ("fondo de cabecera", 240),
        ]
        for (label, x) in probes {
            let hit = frameView.hitTest(NSPoint(x: x, y: y))
            let insideContent = hit.map { $0.isDescendant(of: content) } ?? false
            print("snapshot: clic en \(label) → \(hit.map { String(describing: type(of: $0)) } ?? "nada") (contenido: \(insideContent))")
        }
    }
}
