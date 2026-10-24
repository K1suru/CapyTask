import Foundation
import Testing
@testable import CapyTask

@MainActor
@Suite("Preferencias")
struct AppStateTests {
    @Test func selectedTabIsWritable() {
        let defaults = UserDefaults(suiteName: "capytask.tests.\(UUID().uuidString)")!
        let state = AppState(defaults: defaults)
        state.selectedTab = .processes
        #expect(state.selectedTab == .processes)
    }

    @Test func sharedSelectedTabIsWritable() {
        AppState.shared.selectedTab = .processes
        #expect(AppState.shared.selectedTab == .processes)
        AppState.shared.selectedTab = .summary
    }

    @Test func persistsPreferences() {
        let suite = "capytask.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let state = AppState(defaults: defaults)
        #expect(state.petVisible)
        #expect(state.petSize == .medium)
        state.petSize = .large
        state.petLocked = true
        let reloaded = AppState(defaults: UserDefaults(suiteName: suite)!)
        #expect(reloaded.petSize == .large)
        #expect(reloaded.petLocked)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
@Suite("Idioma")
struct LanguageTests {
    @Test func switchesTextsAndPersists() {
        let suite = "capytask.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let state = AppState(defaults: defaults)
        state.language = .english
        #expect(L("Procesos", "Processes") == "Processes")
        #expect(CapyMood.stressed.title == "Stressed")
        #expect(MainTab.processes.title == "Processes")
        state.language = .spanish
        #expect(CapyMood.stressed.title == "Estresado")
        #expect(AppLanguage.current.locale.identifier == "es_ES")

        state.language = .english
        let reloaded = AppState(defaults: UserDefaults(suiteName: suite)!)
        #expect(reloaded.language == .english)
        defaults.removePersistentDomain(forName: suite)
        AppLanguage.current = AppState.shared.language
    }
}
