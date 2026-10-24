import Foundation
import Observation

/// Idiomas de la interfaz. Se elige en Ajustes y se aplica al instante.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case spanish = "es"
    case english = "en"

    var id: String { rawValue }

    /// Nombre en su propio idioma, para el selector.
    var label: String {
        switch self {
        case .spanish: "Español"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .spanish: Locale(identifier: "es_ES")
        case .english: Locale(identifier: "en_US")
        }
    }

    /// El del sistema si es español; inglés en cualquier otro caso.
    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("es") == true ? .spanish : .english
    }

    /// Idioma activo, legible desde cualquier contexto. Al ser observable,
    /// cada vista SwiftUI que llama a `L(...)` se vuelve a dibujar sola cuando
    /// cambia, sin tener que reconstruir (y destruir) la jerarquía entera.
    static var current: AppLanguage {
        get { LanguageStore.shared.language }
        set { LanguageStore.shared.language = newValue }
    }
}

/// Solo se escribe desde el hilo principal (`AppState`); el registro de
/// Observation es seguro entre hilos para las lecturas.
@Observable
final class LanguageStore: @unchecked Sendable {
    static let shared = LanguageStore()
    var language: AppLanguage = .systemDefault
}

/// Devuelve el texto en el idioma activo: `L("Procesos", "Processes")`.
func L(_ spanish: String, _ english: String) -> String {
    AppLanguage.current == .english ? english : spanish
}
