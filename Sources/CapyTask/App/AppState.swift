import Foundation
import Observation

enum PetSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// Alto del capibara en puntos. Con pantalla Retina, «Grande» usa los
    /// fotogramas a resolución nativa (311 px de alto).
    var points: CGFloat {
        switch self {
        case .small: 110
        case .medium: 136
        case .large: 156
        }
    }

    var label: String {
        switch self {
        case .small: L("Pequeña", "Small")
        case .medium: L("Mediana", "Medium")
        case .large: L("Grande", "Large")
        }
    }
}

enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case summary
    case processes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: L("Resumen Visual", "Visual Summary")
        case .processes: L("Procesos", "Processes")
        }
    }

    var symbol: String {
        switch self {
        case .summary: "chart.pie.fill"
        case .processes: "list.bullet.rectangle.fill"
        }
    }
}

enum TopAppsMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory

    var id: String { rawValue }
    var label: String { self == .cpu ? "CPU" : "RAM" }
}

/// Preferencias del usuario, persistidas en UserDefaults.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    private enum Key {
        static let petVisible = "petVisible"
        static let petLocked = "petLocked"
        static let petSize = "petSize"
        static let showHoverBubble = "showHoverBubble"
        static let showCPUInMenuBar = "showCPUInMenuBar"
        static let topAppsMetric = "topAppsMetric"
        static let language = "language"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var petVisible: Bool { didSet { defaults.set(petVisible, forKey: Key.petVisible) } }
    var petLocked: Bool { didSet { defaults.set(petLocked, forKey: Key.petLocked) } }
    var petSize: PetSize { didSet { defaults.set(petSize.rawValue, forKey: Key.petSize) } }
    var showHoverBubble: Bool { didSet { defaults.set(showHoverBubble, forKey: Key.showHoverBubble) } }
    var showCPUInMenuBar: Bool { didSet { defaults.set(showCPUInMenuBar, forKey: Key.showCPUInMenuBar) } }
    var topAppsMetric: TopAppsMetric { didSet { defaults.set(topAppsMetric.rawValue, forKey: Key.topAppsMetric) } }
    var selectedTab: MainTab = .summary
    var language: AppLanguage {
        didSet {
            AppLanguage.current = language
            defaults.set(language.rawValue, forKey: Key.language)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.petVisible: true,
            Key.petLocked: false,
            Key.petSize: PetSize.medium.rawValue,
            Key.showHoverBubble: true,
            Key.showCPUInMenuBar: false,
            Key.topAppsMetric: TopAppsMetric.cpu.rawValue,
        ])
        petVisible = defaults.bool(forKey: Key.petVisible)
        petLocked = defaults.bool(forKey: Key.petLocked)
        petSize = PetSize(rawValue: defaults.string(forKey: Key.petSize) ?? "") ?? .medium
        showHoverBubble = defaults.bool(forKey: Key.showHoverBubble)
        showCPUInMenuBar = defaults.bool(forKey: Key.showCPUInMenuBar)
        topAppsMetric = TopAppsMetric(rawValue: defaults.string(forKey: Key.topAppsMetric) ?? "") ?? .cpu
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .systemDefault
        AppLanguage.current = language
    }
}

/// Ejecuta `work` en la cola principal de GCD, fuera de cualquier tarea de Swift.
///
/// AppKit puede abrir bucles de eventos anidados (al cambiar menús, cerrar
/// ventanas…). Si eso ocurre dentro de un `Task { @MainActor }`, otras tareas del
/// MainActor se ejecutan reentrando en él y su planificador se corrompe (la app
/// se cerraba al cambiar de idioma). Desde un bloque de GCD es seguro.
func onMainQueue(_ work: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { work() }
    }
}

/// Ejecuta `onChange` cada vez que cambie algo leído dentro de `track`.
@MainActor
func observeChanges(_ track: @escaping @MainActor @Sendable () -> Void, onChange: @escaping @MainActor @Sendable () -> Void) {
    withObservationTracking {
        track()
    } onChange: {
        onMainQueue {
            onChange()
            observeChanges(track, onChange: onChange)
        }
    }
}
