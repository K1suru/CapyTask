import AppKit

@main
@MainActor
enum CapyTaskMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let launchedBeforeKey = "hasLaunchedBefore"
    private let state = AppState.shared
    private let engine = SystemMonitorEngine.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleURL.pathExtension != "app", let logo = CapyImages.image("capy_logo", maxPixel: 256) {
            NSApp.applicationIconImage = logo
        }
        NSApp.mainMenu = MainMenu.make()
        // Al cambiar de idioma se rehacen los menús y el título de Ajustes.
        observeChanges { [state] in _ = state.language } onChange: {
            NSApp.mainMenu = MainMenu.make()
            SettingsWindowController.shared.window?.title = L("Ajustes de CapyTask", "CapyTask Settings")
        }

        engine.start()
        MenuBarController.shared.start()
        CapyPetController.shared.start()

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            SnapshotRunner.run(outputDirectory: arguments[index + 1])
            return
        }
        if arguments.contains("--stress-language") {
            SnapshotRunner.stressLanguage()
            return
        }
        if arguments.contains("--benchmark") {
            SnapshotRunner.benchmark()
            return
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.launchedBeforeKey) || arguments.contains("--open-window") {
            defaults.set(true, forKey: Self.launchedBeforeKey)
            MainWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        CapyPetController.shared.savePosition()
    }

    // MARK: - Acciones del menú principal

    @objc func showMainWindow(_ sender: Any?) { MainWindowController.shared.show() }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }
    @objc func showSummaryTab(_ sender: Any?) { MainWindowController.shared.show(tab: .summary) }
    @objc func showProcessesTab(_ sender: Any?) { MainWindowController.shared.show(tab: .processes) }
    @objc func togglePet(_ sender: Any?) { state.petVisible.toggle() }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CapyTask",
            .credits: NSAttributedString(
                string: L("Monitor de sistema con un capibara que se relaja (o se estresa) contigo. 🍊", "A system monitor with a capybara that relaxes (or stresses out) with you. 🍊"),
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
        NSApp.activate()
    }
}

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "CapyTask")
        app.addItem(withTitle: L("Acerca de CapyTask", "About CapyTask"), action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Ajustes…", "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: L("Ocultar CapyTask", "Hide CapyTask"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: L("Ocultar otros", "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L("Mostrar todo", "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Salir de CapyTask", "Quit CapyTask"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "CapyTask")

        let edit = NSMenu(title: L("Edición", "Edit"))
        edit.addItem(withTitle: L("Deshacer", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Rehacer", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cortar", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copiar", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Pegar", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Seleccionar todo", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: L("Edición", "Edit"))

        let view = NSMenu(title: L("Ver", "View"))
        view.addItem(withTitle: L("Resumen Visual", "Visual Summary"), action: #selector(AppDelegate.showSummaryTab(_:)), keyEquivalent: "1")
        view.addItem(withTitle: L("Procesos", "Processes"), action: #selector(AppDelegate.showProcessesTab(_:)), keyEquivalent: "2")
        view.addItem(.separator())
        view.addItem(withTitle: L("Mostrar/Ocultar Mascota", "Show/Hide Pet"), action: #selector(AppDelegate.togglePet(_:)), keyEquivalent: "p")
        main.addItem(submenu: view, title: L("Ver", "View"))

        let window = NSMenu(title: L("Ventana", "Window"))
        window.addItem(withTitle: L("Minimizar", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: L("Cerrar", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: L("Monitor CapyTask", "CapyTask Monitor"), action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "0")
        main.addItem(submenu: window, title: L("Ventana", "Window"))
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
