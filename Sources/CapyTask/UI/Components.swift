import AppKit
import ImageIO
import SwiftUI

// MARK: - Imágenes

@MainActor
enum CapyImages {
    private static var cache: [String: NSImage] = [:]

    /// Decodifica el PNG ya reducido a `maxPixel` para no gastar memoria de más.
    static func image(_ name: String, maxPixel: Int = 512) -> NSImage? {
        let key = "\(name)@\(maxPixel)"
        if let cached = cache[key] { return cached }
        guard let url = url(for: name), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        cache[key] = image
        return image
    }

    static func url(for name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Images")
    }

    static func purge() {
        cache.removeAll()
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var icons: [String: NSImage] = [:]

    func icon(forFile path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        icons[path] = icon
        return icon
    }

    func clear() {
        icons.removeAll()
    }
}

// MARK: - Capibara

struct LogoBadge: View {
    var size: CGFloat = 24

    var body: some View {
        if let image = CapyImages.image("capy_logo", maxPixel: Int(size * 2)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

// MARK: - Gráficos

struct RingSpec: Identifiable {
    let id: String
    let value: Double
    let color: Color
}

/// Anillos concéntricos; el primero de `rings` es el exterior.
struct ConcentricRings<Center: View>: View {
    let rings: [RingSpec]
    var lineWidth: CGFloat = 11
    var gap: CGFloat = 4
    @ViewBuilder var center: () -> Center

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let innerSide = side - 2 * CGFloat(rings.count) * (lineWidth + gap)
            ZStack {
                RingsLayer(values: rings.map(\.value), colors: rings.map { NSColor($0.color) }, lineWidth: lineWidth, gap: gap)
                    .frame(width: side, height: side)
                center()
                    .frame(width: max(0, innerSide), height: max(0, innerSide))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Los anillos son `CAShapeLayer`: la transición de `strokeEnd` la anima el
/// WindowServer en lugar de recalcular la vista SwiftUI en cada fotograma.
private struct RingsLayer: NSViewRepresentable {
    let values: [Double]
    let colors: [NSColor]
    let lineWidth: CGFloat
    let gap: CGFloat

    func makeNSView(context: Context) -> RingsView { RingsView() }

    func updateNSView(_ view: RingsView, context: Context) {
        view.update(values: values, colors: colors, lineWidth: lineWidth, gap: gap)
    }
}

final class RingsView: NSView {
    private var tracks: [CAShapeLayer] = []
    private var bars: [CAShapeLayer] = []
    private var colors: [NSColor] = []
    private var lineWidth: CGFloat = 11
    private var gap: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    func update(values: [Double], colors: [NSColor], lineWidth: CGFloat, gap: CGFloat) {
        self.colors = colors
        self.lineWidth = lineWidth
        self.gap = gap
        while bars.count < values.count {
            let track = CAShapeLayer()
            let bar = CAShapeLayer()
            for shape in [track, bar] {
                shape.fillColor = nil
                shape.lineCap = .round
                layer?.addSublayer(shape)
            }
            bar.strokeEnd = 0
            tracks.append(track)
            bars.append(bar)
        }
        applyColors()
        for (bar, value) in zip(bars, values) {
            let target = CGFloat(min(1, max(0, value)))
            let current = bar.presentation()?.strokeEnd ?? bar.strokeEnd
            guard abs(target - bar.strokeEnd) > 0.0005 else { continue }
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = current
            animation.toValue = target
            animation.duration = 0.6
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.strokeEnd = target
            CATransaction.commit()
            bar.add(animation, forKey: "strokeEnd")
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in bars.indices {
            let radius = side / 2 - CGFloat(index) * (lineWidth + gap) - lineWidth / 2
            guard radius > 0 else { continue }
            let path = CGMutablePath()
            // Empieza arriba y avanza en sentido horario.
            path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            for shape in [tracks[index], bars[index]] {
                shape.frame = bounds
                shape.path = path
                shape.lineWidth = lineWidth
            }
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, color) in colors.enumerated() where index < bars.count {
                bars[index].strokeColor = color.cgColor
                tracks[index].strokeColor = color.withAlphaComponent(0.16).cgColor
            }
        }
        CATransaction.commit()
    }
}

struct UsageBar: View {
    let value: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(value > 0.001 ? height : 0, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

struct StackedBarSegment: Identifiable {
    let id: String
    let value: Double
    let color: Color
}

struct StackedBar: View {
    let segments: [StackedBarSegment]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geometry.size.width * min(1, segment.value) - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(Theme.track)
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var capacity = SystemMonitorEngine.historyLength

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let step = width / CGFloat(max(capacity - 1, 1))
            let offset = CGFloat(max(0, capacity - values.count)) * step
            let points = values.enumerated().map { index, value in
                CGPoint(x: offset + CGFloat(index) * step, y: height - CGFloat(min(1, max(0, value))) * (height - 2) - 1)
            }
            if let first = points.first, let last = points.last, points.count > 1 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: height))
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: last.x, y: height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct CoreBars: View {
    let cores: [CoreLoad]

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(cores) { core in
                VStack(spacing: 3) {
                    GeometryReader { geometry in
                        let fill = max(3, geometry.size.height * min(1, core.usage))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.track)
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(color(for: core).gradient)
                                    .frame(height: fill)
                            }
                    }
                    .frame(width: 11)
                    Text(core.kind.shortLabel)
                        .font(Theme.rounded(8.5, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                }
                .frame(maxWidth: .infinity)
                .help(L("Núcleo", "Core") + " \(core.id + 1) (\(core.kind == .performance ? L("rendimiento", "performance") : core.kind == .efficiency ? L("eficiencia", "efficiency") : L("estándar", "standard"))): \(Format.percent(core.usage))")
            }
        }
    }

    private func color(for core: CoreLoad) -> Color {
        core.kind == .efficiency ? Theme.peach : Theme.mandarina
    }
}

// MARK: - Piezas pequeñas

struct CardTitle: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(tint.gradient))
            Text(title)
                .font(Theme.rounded(13, .bold))
                .foregroundStyle(Theme.ink)
        }
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(Theme.rounded(10, .medium)).foregroundStyle(Theme.inkSoft)
            }
            Text(value)
                .font(Theme.rounded(12.5, .bold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

struct ProcessIcon: View {
    let bundlePath: String?
    var size: CGFloat = 20

    var body: some View {
        if let bundlePath {
            Image(nsImage: IconCache.shared.icon(forFile: bundlePath))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.chip)
                .overlay(
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: size * 0.52))
                        .foregroundStyle(Theme.inkSoft)
                )
                .frame(width: size, height: size)
        }
    }
}

struct KindTag: View {
    let isUserApp: Bool

    var body: some View {
        Text(isUserApp ? "App" : L("Sistema", "System"))
            .font(Theme.rounded(10.5, .semibold))
            .foregroundStyle(isUserApp ? Theme.bambooInk : Theme.inkSoft)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(isUserApp ? Theme.bamboo.opacity(0.2) : Theme.chip))
    }
}

/// Tres barritas tipo "señal" según el peso relativo en la RAM total.
struct WeightIndicator: View {
    let bytes: UInt64
    let totalMemory: UInt64

    private var level: Int {
        guard totalMemory > 0, bytes > 0 else { return 0 }
        let fraction = Double(bytes) / Double(totalMemory)
        return fraction < 0.02 ? 1 : fraction < 0.07 ? 2 : 3
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...3, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1)
                    .fill(step <= level ? color : Theme.track)
                    .frame(width: 3, height: CGFloat(3 + step * 3))
            }
        }
        .help(level == 3 ? L("Proceso pesado", "Heavy process") : level == 2 ? L("Peso medio", "Medium weight") : L("Proceso ligero", "Light process"))
    }

    private var color: Color {
        switch level {
        case 3: Theme.danger
        case 2: Theme.mandarina
        default: Theme.bamboo
        }
    }
}

struct CapsuleChoice: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(11.5, .semibold))
                .foregroundStyle(isSelected ? Theme.accentInk : Theme.inkSoft)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? Theme.mandarina.opacity(0.18) : Theme.chip))
                .overlay(Capsule().strokeBorder(isSelected ? Theme.mandarina.opacity(0.45) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(12.5, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.danger.gradient))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Permite arrastrar la ventana desde el fondo de la cabecera.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
