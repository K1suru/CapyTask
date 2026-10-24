import AppKit
import SwiftUI

/// Con alguna ventana abierta CapyTask aparece en el Dock y en ⌘⇥;
/// sin ventanas vuelve a vivir solo en la barra de menú.
@MainActor
enum AppActivation {
    static func update() {
        let wantsDock = MainWindowController.shared.isOpen || SettingsWindowController.shared.isOpen
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private static let autosaveName = "CapyTaskMainWindow"

    private(set) var window: NSWindow?
    private let engine = SystemMonitorEngine.shared

    var isOpen: Bool { window != nil }

    func show(tab: MainTab? = nil) {
        if let tab { AppState.shared.selectedTab = tab }
        let window = self.window ?? makeWindow()
        self.window = window
        AppActivation.update()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateDemand()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "CapyTask"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.nsBackground
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)

        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        let hosting = NSHostingController(rootView: MainWindowView(titlebarHeight: titlebarHeight))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.minSize = NSSize(width: 680, height: 520)
        window.setContentSize(NSSize(width: 720, height: 560))
        window.delegate = self
        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        return window
    }

    private func updateDemand() {
        guard let window else {
            engine.mainWindowOpen = false
            engine.mainWindowVisible = false
            engine.mainWindowFocused = false
            return
        }
        engine.mainWindowOpen = true
        engine.mainWindowVisible = window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized
        engine.mainWindowFocused = window.isKeyWindow
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { updateDemand() }
    func windowDidResignKey(_ notification: Notification) { updateDemand() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateDemand() }
    func windowDidMiniaturize(_ notification: Notification) { updateDemand() }
    func windowDidDeminiaturize(_ notification: Notification) { updateDemand() }

    func windowWillClose(_ notification: Notification) {
        engine.mainWindowOpen = false
        engine.mainWindowVisible = false
        engine.mainWindowFocused = false
        // Soltamos la jerarquía SwiftUI y los iconos: con la ventana cerrada
        // CapyTask debe pesar lo mínimo.
        onMainQueue {
            self.window?.contentViewController = nil
            self.window = nil
            IconCache.shared.clear()
            AppActivation.update()
        }
        Task { @MainActor in
            // Devuelve al sistema las páginas que malloc retiene tras liberar la UI
            // (SwiftUI termina de soltar parte de su grafo unos segundos después).
            for delay in [1.0, 8.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard self.window == nil else { return }
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?
    var isOpen: Bool { window != nil }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        AppActivation.update()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Ajustes de CapyTask", "CapyTask Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onMainQueue {
            self.window?.contentViewController = nil
            self.window = nil
            AppActivation.update()
        }
    }
}
