import AppKit
import QuartzCore
import SwiftUI

@MainActor
@Observable
final class PetViewModel {
    var isHovering = false
    /// Alto del capibara en puntos; el ancho sale de la proporción de los fotogramas.
    var size: CGFloat = PetSize.medium.points

    var width: CGFloat { (size * SpriteLibrary.shared.aspectRatio).rounded() }
}

// MARK: - SwiftUI (burbuja)

struct PetBubbleView: View {
    let model: PetViewModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.isHovering {
                PetBubbleContent()
                    .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.isHovering)
    }
}

/// Solo existe mientras se muestra, así que fuera del hover no observa métricas.
private struct PetBubbleContent: View {
    private let engine = SystemMonitorEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                Text("CPU: \(Format.percent(engine.cpu.usage)) · RAM: \(Format.percent(engine.memory.usedFraction))")
                    .font(Theme.rounded(11.5, .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text("\(engine.mood.emoji) \(engine.mood.title)")
                    .font(Theme.rounded(9.5, .semibold))
                    .foregroundStyle(Theme.color(for: engine.mood))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
            BubbleTail()
                .fill(Theme.card)
                .frame(width: 12, height: 6)
                .offset(y: -1)
        }
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .fixedSize()
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - AppKit: interacción y animación

@MainActor
protocol PetInteractionDelegate: AnyObject {
    var isPetLocked: Bool { get }
    func petDidFinishDragging()
    func petWasPoked()
    func petWasDoubleClicked()
    func petContextMenu() -> NSMenu
    func petHoverChanged(_ hovering: Bool)
}

/// Vista raíz del panel. Recibe todos los eventos del ratón y mueve el panel a
/// mano para un arrastre suave. El capibara es un `SpritePlayerView`: quieto en
/// reposo y animado (por el WindowServer) mientras el cursor está encima.
final class PetRootView: NSView {
    static let bubbleHeight: CGFloat = 46
    static let bottomMargin: CGFloat = 6

    weak var delegate: PetInteractionDelegate?
    let sprite: SpritePlayerView
    private let model: PetViewModel
    private let bubbleHost: NSHostingView<PetBubbleView>
    private let bobView = NSView()
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: (mouse: NSPoint, window: NSPoint)?
    private var didDrag = false
    private var shookThisDrag = false

    init(model: PetViewModel) {
        self.model = model
        bubbleHost = NSHostingView(rootView: PetBubbleView(model: model))
        sprite = SpritePlayerView(pointHeight: model.size)
        super.init(frame: .zero)
        wantsLayer = true
        bobView.wantsLayer = true
        addSubview(bubbleHost)
        addSubview(bobView)
        bobView.addSubview(sprite)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("Capibara de CapyTask", "CapyTask capybara"))
        setAccessibilityHelp(L("Doble clic: abrir CapyTask. Clic derecho: opciones.", "Double-click: open CapyTask. Right-click: options."))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    var capyFrame: NSRect {
        let height = model.size
        let width = model.width
        return NSRect(x: (bounds.width - width) / 2, y: Self.bottomMargin, width: width, height: height)
    }

    override func layout() {
        super.layout()
        let capy = capyFrame
        bobView.frame = capy
        sprite.frame = bobView.bounds
        sprite.pointHeight = model.size
        bubbleHost.frame = NSRect(x: 0, y: capy.maxY - 4, width: bounds.width, height: Self.bubbleHeight)
    }

    // MARK: Eventos

    /// Solo responde dentro de la silueta (una elipse ajustada al sticker).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let capy = capyFrame.insetBy(dx: 4, dy: 2)
        let dx = (local.x - capy.midX) / (capy.width / 2)
        let dy = (local.y - capy.midY) / (capy.height / 2)
        return dx * dx + dy * dy <= 1 ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: capyFrame.insetBy(dx: 6, dy: 4), options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        delegate?.petHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        delegate?.petHoverChanged(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        dragOrigin = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        didDrag = false
        shookThisDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOrigin else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragOrigin.mouse.x
        let dy = mouse.y - dragOrigin.mouse.y
        if !didDrag && hypot(dx, dy) < 3 { return }
        if delegate?.isPetLocked == true {
            if !shookThisDrag {
                shookThisDrag = true
                playShake()
            }
            return
        }
        didDrag = true
        window.setFrameOrigin(NSPoint(x: dragOrigin.window.x + dx, y: dragOrigin.window.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        if didDrag {
            delegate?.petDidFinishDragging()
        } else if event.clickCount == 2 {
            delegate?.petWasDoubleClicked()
        } else if event.clickCount == 1 && !shookThisDrag {
            delegate?.petWasPoked()
            playHop()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        guard let menu = delegate?.petContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Reacciones (Core Animation)

    private func playHop() {
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, 14, 0, 5, 0]
        hop.keyTimes = [0, 0.3, 0.6, 0.8, 1]
        hop.duration = 0.55
        hop.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeOut), count: 4)
        hop.isAdditive = true
        bobView.layer?.add(hop, forKey: "hop")
    }

    private func playShake() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -6, 6, -4, 4, 0]
        shake.duration = 0.4
        shake.isAdditive = true
        bobView.layer?.add(shake, forKey: "shake")
    }
}
