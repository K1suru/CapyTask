import AppKit

/// Muestra, oculta, coloca y recuerda la posición del capibara flotante.
@MainActor
final class CapyPetController: NSObject, PetInteractionDelegate {
    static let shared = CapyPetController()

    private static let anchorKey = "petAnchor"

    private let state = AppState.shared
    private let engine = SystemMonitorEngine.shared
    private let model = PetViewModel()
    private var panel: CapyPetWindow?
    private var root: PetRootView?
    private var started = false

    var isPetLocked: Bool { state.petLocked }
    var isSpriteAnimating: Bool { root?.sprite.isAnimating ?? false }

    func start() {
        guard !started else { return }
        started = true
        observeChanges { [state] in _ = state.petVisible } onChange: { [weak self] in self?.applyVisibility() }
        observeChanges { [state] in _ = state.petSize } onChange: { [weak self] in self?.applySize() }
        observeChanges { [engine] in _ = engine.mood } onChange: { [weak self] in self?.applyMood() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            onMainQueue { self?.keepOnScreen(animated: true) }
        }
        applyVisibility()
    }

    /// Vuelve a la esquina inferior derecha de la pantalla principal.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.anchorKey)
        guard let panel else { return }
        panel.setFrameOrigin(origin(forAnchor: defaultAnchor(), size: panel.frame.size))
        saveAnchor()
    }

    func savePosition() {
        if panel != nil { saveAnchor() }
    }

    // MARK: - Visibilidad y tamaño

    private func applyVisibility() {
        engine.petVisible = state.petVisible
        if state.petVisible {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        root?.sprite.resume()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        applyMood()
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        saveAnchor()
        model.isHovering = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            onMainQueue {
                guard !self.state.petVisible else { return }
                panel.orderOut(nil)
                // Oculta, la mascota no necesita sus fotogramas en memoria.
                self.root?.sprite.suspend()
            }
        }
    }

    private func makePanel() -> CapyPetWindow {
        model.size = state.petSize.points
        let size = Self.panelSize(for: model.size)
        let panel = CapyPetWindow(size: size)
        let root = PetRootView(model: model)
        root.delegate = self
        root.frame = NSRect(origin: .zero, size: size)
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        panel.setFrameOrigin(origin(forAnchor: savedAnchor() ?? defaultAnchor(), size: size))
        self.root = root
        keepOnScreen(animated: false)
        return panel
    }

    private func applySize() {
        guard let panel else {
            model.size = state.petSize.points
            return
        }
        let anchor = currentAnchor()
        model.size = state.petSize.points
        let size = Self.panelSize(for: model.size)
        panel.setFrame(NSRect(origin: origin(forAnchor: anchor, size: size), size: size), display: true)
        root?.needsLayout = true
        root?.layoutSubtreeIfNeeded()
        root?.updateTrackingAreas()
        keepOnScreen(animated: false)
        saveAnchor()
    }

    private func applyMood() {
        root?.sprite.show(engine.mood.sprite)
        root?.setAccessibilityValue("\(engine.mood.title): \(engine.mood.statusLine(effortPercent: Int((engine.stress * 100).rounded())))")
    }

    /// El panel deja sitio a la burbuja por encima; lo transparente no captura clics.
    static func panelSize(for petHeight: CGFloat) -> NSSize {
        let petWidth = (petHeight * SpriteLibrary.shared.aspectRatio).rounded()
        return NSSize(width: max(petWidth + 28, 196), height: petHeight + PetRootView.bubbleHeight + PetRootView.bottomMargin)
    }

    // MARK: - Posición (se guarda el punto inferior central del capibara)

    private func origin(forAnchor anchor: NSPoint, size: NSSize) -> NSPoint {
        NSPoint(x: anchor.x - size.width / 2, y: anchor.y - PetRootView.bottomMargin)
    }

    private func currentAnchor() -> NSPoint {
        guard let panel else { return savedAnchor() ?? defaultAnchor() }
        return NSPoint(x: panel.frame.midX, y: panel.frame.minY + PetRootView.bottomMargin)
    }

    private func saveAnchor() {
        let anchor = currentAnchor()
        UserDefaults.standard.set([anchor.x, anchor.y], forKey: Self.anchorKey)
    }

    private func savedAnchor() -> NSPoint? {
        guard let values = UserDefaults.standard.array(forKey: Self.anchorKey) as? [Double], values.count == 2 else { return nil }
        let anchor = NSPoint(x: values[0], y: values[1])
        // Si el monitor donde estaba ya no existe, se ignora.
        return NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(anchor) } ? anchor : nil
    }

    private func defaultAnchor() -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.maxX - 40 - model.width / 2, y: frame.minY + 16)
    }

    /// Asegura que el capibara quede visible dentro de alguna pantalla.
    private func keepOnScreen(animated: Bool) {
        guard let panel else { return }
        let capyWidth = model.width
        let capyHeight = model.size
        let anchor = currentAnchor()
        let capyRect = NSRect(x: anchor.x - capyWidth / 2, y: anchor.y, width: capyWidth, height: capyHeight)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let best = screens.max { $0.visibleFrame.intersection(capyRect).area < $1.visibleFrame.intersection(capyRect).area }
            ?? screens[0]
        let visible = best.visibleFrame
        guard visible.intersection(capyRect).area < capyRect.area * 0.7 else { return }
        let clamped = NSPoint(
            x: min(max(anchor.x, visible.minX + capyWidth / 2), visible.maxX - capyWidth / 2),
            y: min(max(anchor.y, visible.minY), visible.maxY - capyHeight)
        )
        let target = NSRect(origin: origin(forAnchor: clamped, size: panel.frame.size), size: panel.frame.size)
        panel.setFrame(target, display: true, animate: animated)
        saveAnchor()
    }

    // MARK: - PetInteractionDelegate

    func petDidFinishDragging() {
        keepOnScreen(animated: true)
        saveAnchor()
    }

    /// Un toque hace saltar al capibara (la animación la lanza la vista).
    func petWasPoked() {}

    func petWasDoubleClicked() {
        MainWindowController.shared.show()
    }

    /// Con el cursor encima el capibara se anima y aparece la burbuja; en
    /// reposo se queda quieto mostrando el primer fotograma de su estado.
    func petHoverChanged(_ hovering: Bool) {
        root?.sprite.setPlaying(hovering)
        let shouldShow = hovering && state.showHoverBubble
        guard model.isHovering != shouldShow else { return }
        model.isHovering = shouldShow
    }

    func petContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(L("Ocultar Mascota", "Hide Pet"), symbol: "eye.slash", action: #selector(hidePet)))
        let lock = menuItem(L("Fijar en esta posición", "Lock in This Position"), symbol: "lock", action: #selector(toggleLock))
        lock.state = state.petLocked ? .on : .off
        menu.addItem(lock)

        let sizeItem = NSMenuItem(title: L("Tamaño", "Size"), action: nil, keyEquivalent: "")
        sizeItem.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        let sizes = NSMenu()
        for size in PetSize.allCases {
            let item = NSMenuItem(title: size.label, action: #selector(changeSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = state.petSize == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(L("Abrir Monitor Completo", "Open Full Monitor"), symbol: "chart.bar.xaxis", action: #selector(openMonitor)))
        menu.addItem(menuItem(L("Ajustes de CapyTask…", "CapyTask Settings…"), symbol: "gearshape", action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("Cerrar CapyTask", "Quit CapyTask"), symbol: "xmark.circle", action: #selector(quit)))
        return menu
    }

    private func menuItem(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func hidePet() { state.petVisible = false }
    @objc private func toggleLock() { state.petLocked.toggle() }
    @objc private func openMonitor() { MainWindowController.shared.show() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func changeSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = PetSize(rawValue: raw) {
            state.petSize = size
        }
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
