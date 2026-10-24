import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable private var state = AppState.shared
    private let engine = SystemMonitorEngine.shared
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var loginError: String?

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CapySpriteView(state: engine.mood.sprite, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CapyTask")
                            .font(Theme.rounded(18, .bold))
                        Text(L("Versión", "Version") + " \(version) · \(engine.mood.statusLine(effortPercent: Int((engine.stress * 100).rounded())))")
                            .font(Theme.rounded(11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section(L("General", "General")) {
                Picker(L("Idioma", "Language"), selection: $state.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("Abrir CapyTask al iniciar sesión", "Open CapyTask at login"), isOn: $launchAtLogin)
                    .disabled(!isBundled)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if !isBundled {
                    Text(L("Disponible al ejecutar CapyTask.app (scripts/build_app.sh).", "Available when running CapyTask.app (scripts/build_app.sh)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Theme.danger)
                }
                Toggle(L("Mostrar % de CPU en la barra de menú", "Show CPU % in the menu bar"), isOn: $state.showCPUInMenuBar)
            }

            Section(L("Mascota", "Pet")) {
                Toggle(L("Mostrar mascota en pantalla", "Show pet on screen"), isOn: $state.petVisible)
                Picker(L("Tamaño", "Size"), selection: $state.petSize) {
                    ForEach(PetSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("Fijar posición (evita arrastres accidentales)", "Lock position (prevents accidental drags)"), isOn: $state.petLocked)
                Toggle(L("Burbuja de consumo al pasar el cursor", "Usage bubble on hover"), isOn: $state.showHoverBubble)
                Button(L("Recolocar mascota en la esquina", "Move pet back to the corner")) {
                    CapyPetController.shared.resetPosition()
                }
            }

            Section(L("Rendimiento", "Performance")) {
                LabeledContent(L("Muestreo con la ventana enfocada", "Sampling with window focused"), value: Format.seconds(1))
                LabeledContent(L("Muestreo en segundo plano", "Background sampling"), value: Format.seconds(2.5))
                LabeledContent(L("Muestreo actual", "Current sampling"), value: Format.seconds(engine.interval))
                LabeledContent(L("Memoria usada por CapyTask", "Memory used by CapyTask"), value: Format.bytes(engine.selfUsage.memoryBytes))
                LabeledContent(L("CPU usada por CapyTask", "CPU used by CapyTask"), value: Format.cpu(engine.selfUsage.cpuPercent))
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            loginError = service.status == .requiresApproval
                ? L("Apruébalo en Ajustes del Sistema › General › Ítems de inicio.", "Approve it in System Settings › General › Login Items.")
                : nil
        } catch {
            loginError = L("No se pudo cambiar: ", "Couldn’t change it: ") + error.localizedDescription
        }
        launchAtLogin = service.status == .enabled
    }
}
