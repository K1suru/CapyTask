import AppKit

/// Icono del capibara en la barra de menú con un menú rápido.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private let state = AppState.shared
    private let engine = SystemMonitorEngine.shared
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "Midiendo…", action: nil, keyEquivalent: "")
    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private let buttonFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private var menuIsOpen = false
    private let petItem = NSMenuItem(title: "Mostrar Mascota en Pantalla", action: nil, keyEquivalent: "")

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let icon = CapyImages.image("capy_logo", maxPixel: 36)
            icon?.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.imagePosition = .imageLeading
            button.toolTip = "CapyTask"
        }
        item.menu = makeMenu()
        statusItem = item

        observeChanges { [engine] in
            _ = engine.cpu
            _ = engine.memory
            _ = engine.mood
        } onChange: { [weak self] in
            self?.refresh()
        }
        observeChanges { [state] in _ = state.language } onChange: { [weak self] in
            guard let self else { return }
            self.statusItem?.menu = self.makeMenu()
            self.refresh()
        }
        observeChanges { [state] in
            _ = state.showCPUInMenuBar
            _ = state.petVisible
        } onChange: { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    private func makeMenu() -> NSMenu {
        // Estos dos elementos se reutilizan: un NSMenuItem no puede estar en dos
        // menús a la vez (AppKit lanza una excepción), así que se sacan del anterior.
        for item in [statusLine, petItem] {
            item.menu?.removeItem(item)
        }
        let menu = NSMenu()
        menu.delegate = self
        statusLine.title = L("Midiendo…", "Measuring…")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        petItem.title = L("Mostrar Mascota en Pantalla", "Show Pet on Screen")
        petItem.action = #selector(togglePet)
        petItem.target = self
        menu.addItem(petItem)

        let open = NSMenuItem(title: L("Abrir CapyTask…", "Open CapyTask…"), action: #selector(openMain), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let preferences = NSMenuItem(title: L("Preferencias…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Salir de CapyTask", "Quit CapyTask"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// Solo se toca lo que el usuario puede ver: el menú abierto o el % en la barra.
    private func refresh() {
        if menuIsOpen {
            let line = "\(engine.mood.emoji)  CPU: \(Format.percent(engine.cpu.usage)) · RAM: \(Format.bytes(engine.memory.used))"
            statusLine.attributedTitle = NSAttributedString(string: line, attributes: [
                .font: statusFont,
                .foregroundColor: NSColor.labelColor,
            ])
        }
        petItem.state = state.petVisible ? .on : .off

        engine.menuBarShowsValue = state.showCPUInMenuBar
        if let button = statusItem?.button {
            if state.showCPUInMenuBar {
                button.attributedTitle = NSAttributedString(string: " " + Format.percent(engine.cpu.usage), attributes: [
                    .font: buttonFont,
                ])
            } else if !button.title.isEmpty {
                button.title = ""
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        engine.menuOpen = true
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        engine.menuOpen = false
    }

    // MARK: - Acciones

    @objc private func togglePet() { state.petVisible.toggle() }
    @objc private func openMain() { MainWindowController.shared.show() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
