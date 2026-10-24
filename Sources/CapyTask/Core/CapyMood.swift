import Foundation

/// Estado emocional del capibara según la carga del sistema.
enum CapyMood: String, Sendable, CaseIterable {
    case normal
    case worried
    case stressed

    /// Límites inferiores de Preocupado y Estresado.
    static let thresholds: [Double] = [0.40, 0.75]

    var sprite: SpriteState {
        switch self {
        case .normal: .normal
        case .worried: .worried
        case .stressed: .stressed
        }
    }

    var title: String {
        switch self {
        case .normal: L("Relajado", "Relaxed")
        case .worried: L("Preocupado", "Worried")
        case .stressed: L("Estresado", "Stressed")
        }
    }

    var emoji: String {
        switch self {
        case .normal: "😌"
        case .worried: "😟"
        case .stressed: "😵‍💫"
        }
    }

    func statusLine(effortPercent: Int) -> String {
        switch self {
        case .normal: L("Todo tranquilo, \(effortPercent)% de esfuerzo", "All calm, \(effortPercent)% effort")
        case .worried: L("Algo inquieto… \(effortPercent)% de esfuerzo", "A bit uneasy… \(effortPercent)% effort")
        case .stressed: L("¡Sobrecarga! \(effortPercent)% de esfuerzo", "Overload! \(effortPercent)% effort")
        }
    }

    private var band: Int {
        switch self {
        case .normal: 0
        case .worried: 1
        case .stressed: 2
        }
    }

    /// Normal < 40% · Preocupado 40–75% · Estresado > 75%.
    static func band(for stress: Double) -> CapyMood {
        switch stress {
        case ..<thresholds[0]: .normal
        case ...thresholds[1]: .worried
        default: .stressed
        }
    }

    /// Sube de estado al instante, pero para bajar exige quedar `hysteresis`
    /// por debajo del umbral, evitando que la animación parpadee en el límite.
    static func resolve(stress: Double, current: CapyMood, hysteresis: Double = 0.03) -> CapyMood {
        let target = band(for: stress)
        guard target.band < current.band else { return target }
        return stress > thresholds[current.band - 1] - hysteresis ? current : target
    }
}

/// Cómo se traduce el estado del sistema a "estrés" 0...1.
enum StressModel {
    /// macOS mantiene la RAM llena a propósito (cachés, compresión), así que el
    /// porcentaje "usado" de un Mac de 8 GB ronda el 75% aunque esté tranquilo.
    /// Para el ánimo usamos la presión de memoria del kernel: solo con presión
    /// elevada (preocupado) o crítica (estresado) la memoria pesa en el ánimo.
    static func memoryStress(_ memory: MemorySnapshot) -> Double {
        let fraction = min(1, max(0, memory.pressureFraction))
        switch memory.pressure {
        case .normal: return fraction * 0.6
        case .warning: return 0.6 + fraction * 0.15
        case .critical: return 0.8 + fraction * 0.2
        }
    }

    static func stress(cpu: Double, memory: MemorySnapshot) -> Double {
        min(1, max(cpu, memoryStress(memory)))
    }
}
