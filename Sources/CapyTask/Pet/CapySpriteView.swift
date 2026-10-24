import AppKit
import ImageIO
import IOSurface
import QuartzCore
import SwiftUI

/// Los tres bucles animados del capibara (ver `assets_processed/metadata.json`).
enum SpriteState: String, CaseIterable, Sendable {
    case normal
    case worried
    case stressed
}

struct SpriteMetadata: Decodable, Sendable {
    struct State: Decodable, Sendable {
        let frameCount: Int
        let avgDurationMs: Double
        let framesPath: String
        let firstFrame: String
    }

    let width: Int
    let height: Int
    let states: [String: State]

    var aspectRatio: CGFloat { height > 0 ? CGFloat(width) / CGFloat(height) : 1 }
}

/// Fotogramas de un estado ya decodificados en `IOSurface`s: Core Animation
/// las comparte con el WindowServer sin copiarlas, así cada fotograma existe
/// una sola vez en memoria. No se modifican tras crearlas, por eso es seguro
/// pasarlas entre hilos.
struct SpriteFrames: @unchecked Sendable {
    let surfaces: [IOSurface]
    let frameDuration: Double

    var byteCount: Int { surfaces.reduce(0) { $0 + $1.allocationSize } }
}

/// Carga y comparte los fotogramas. En reposo cada vista solo necesita su
/// póster (el primer fotograma); los 64 de la animación (~15 MB) se cargan al
/// pasar el cursor y se sueltan poco después de que se vaya.
@MainActor
final class SpriteLibrary {
    static let shared = SpriteLibrary()

    let metadata: SpriteMetadata?
    private let baseURL: URL?

    private struct Key: Hashable {
        let state: SpriteState
        let pixelHeight: Int
    }

    private struct Entry {
        var users = 0
        var frames: SpriteFrames?
        var loading: Task<SpriteFrames?, Never>?
    }

    private var entries: [Key: Entry] = [:]
    private var posters: [Key: IOSurface] = [:]
    private var posterOrder: [Key] = []
    private static let maxPosters = 8

    init(baseURL: URL? = SpriteLibrary.locateAssets()) {
        self.baseURL = baseURL
        metadata = baseURL.flatMap { url in
            guard let data = try? Data(contentsOf: url.appending(path: "metadata.json")) else { return nil }
            return try? JSONDecoder().decode(SpriteMetadata.self, from: data)
        }
    }

    var aspectRatio: CGFloat { metadata?.aspectRatio ?? 232.0 / 311.0 }

    /// Resolución a la que hay que decodificar: la del píxel real en pantalla
    /// redondeada a escalones de 16 px (redimensionar la ventana no obliga a
    /// decodificar de nuevo en cada píxel), sin superar la de los PNG originales.
    func pixelHeight(forPointHeight pointHeight: CGFloat, scale: CGFloat) -> Int {
        let step = 16
        let wanted = (Int((pointHeight * scale).rounded(.up)) + step - 1) / step * step
        return max(step, min(metadata?.height ?? wanted, wanted))
    }

    /// Devuelve los fotogramas y los retiene hasta que se llame a `release`.
    func acquire(_ state: SpriteState, pixelHeight: Int) async -> SpriteFrames? {
        let key = Key(state: state, pixelHeight: pixelHeight)
        entries[key, default: Entry()].users += 1
        if let frames = entries[key]?.frames { return frames }
        if let loading = entries[key]?.loading { return await loading.value }

        guard let baseURL, let info = metadata?.states[state.rawValue] else { return nil }
        let task = Task.detached(priority: .userInitiated) {
            Self.decode(baseURL: baseURL, info: info, pixelHeight: pixelHeight)
        }
        entries[key]?.loading = task
        let frames = await task.value
        entries[key]?.loading = nil
        if (entries[key]?.users ?? 0) > 0 {
            entries[key]?.frames = frames
        } else {
            entries[key] = nil
        }
        return frames
    }

    func release(_ state: SpriteState, pixelHeight: Int) {
        let key = Key(state: state, pixelHeight: pixelHeight)
        guard var entry = entries[key] else { return }
        entry.users -= 1
        entries[key] = entry.users > 0 || entry.loading != nil ? entry : nil
    }

    /// Primer fotograma del estado: lo que se ve mientras no hay animación.
    func poster(_ state: SpriteState, pixelHeight: Int) async -> IOSurface? {
        let key = Key(state: state, pixelHeight: pixelHeight)
        if let poster = posters[key] { return poster }
        guard let baseURL, let info = metadata?.states[state.rawValue] else { return nil }
        let frames = await Task.detached(priority: .userInitiated) {
            Self.decode(baseURL: baseURL, info: info, pixelHeight: pixelHeight, frames: 0..<1)
        }.value
        guard let poster = frames?.surfaces.first else { return nil }
        if posters[key] == nil {
            posterOrder.append(key)
            if posterOrder.count > Self.maxPosters {
                posters[posterOrder.removeFirst()] = nil
            }
        }
        posters[key] = poster
        return poster
    }

    nonisolated static func decode(
        baseURL: URL,
        info: SpriteMetadata.State,
        pixelHeight: Int,
        frames range: Range<Int>? = nil
    ) -> SpriteFrames? {
        let directory = baseURL.appending(path: info.framesPath, directoryHint: .isDirectory)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let colorSpaceInfo = colorSpace.copyPropertyList()
        let indices = range ?? 0..<info.frameCount
        var surfaces: [IOSurface] = []
        surfaces.reserveCapacity(indices.count)
        for index in indices {
            let url = directory.appending(path: String(format: "frame_%03d.png", index))
            // Sin caché: ImageIO decodifica al dibujar y suelta el búfer enseguida.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { continue }
            let height = min(pixelHeight, image.height)
            let width = max(1, Int((Double(image.width) * Double(height) / Double(image.height)).rounded()))
            guard let surface = IOSurface(properties: [
                .width: width,
                .height: height,
                .bytesPerElement: 4,
                .pixelFormat: kCVPixelFormatType_32BGRA,
            ]) else { continue }
            if let colorSpaceInfo {
                IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpaceInfo)
            }
            surface.lock(options: [], seed: nil)
            defer { surface.unlock(options: [], seed: nil) }
            guard let context = CGContext(
                data: surface.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { continue }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            surfaces.append(surface)
        }
        guard !surfaces.isEmpty else { return nil }
        return SpriteFrames(surfaces: surfaces, frameDuration: max(0.016, info.avgDurationMs / 1000))
    }

    /// En el `.app` los fotogramas viven en `Contents/Resources/Sprites`; al
    /// ejecutar con `swift run` o `swift test` se usan los de `assets_processed/`.
    nonisolated static func locateAssets() -> URL? {
        let fileManager = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appending(path: "Sprites"),
           fileManager.fileExists(atPath: bundled.appending(path: "metadata.json").path) {
            return bundled
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appending(path: "assets_processed")
            if fileManager.fileExists(atPath: candidate.appending(path: "metadata.json").path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}

/// Muestra el póster del estado y, mientras se esté reproduciendo (cursor
/// encima), la secuencia completa con una animación discreta de `contents`:
/// la ejecuta el WindowServer, así que la app no despierta en cada fotograma.
final class SpritePlayerView: NSView {
    /// Tiempo que se conservan los fotogramas tras dejar de animar, para que
    /// volver a pasar el cursor sea instantáneo.
    private static let framesGracePeriod: Duration = .seconds(10)

    private let spriteLayer = CALayer()
    private let playsOnHover: Bool
    private var trackingArea: NSTrackingArea?
    private var posterTask: Task<Void, Never>?
    private var framesTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var held: (state: SpriteState, pixelHeight: Int)?
    private var animating: SpriteState?
    private var isSuspended = false
    private(set) var state: SpriteState?
    private(set) var isPlaying = false
    /// La secuencia de fotogramas está en marcha (no solo pedida).
    var isAnimating: Bool { spriteLayer.animation(forKey: "frames") != nil }

    var pointHeight: CGFloat {
        didSet {
            guard pointHeight != oldValue else { return }
            reload()
        }
    }

    /// - Parameter playsOnHover: si es `true`, la propia vista anima al pasar el
    ///   cursor; si no, quien la contiene llama a `setPlaying(_:)`.
    init(pointHeight: CGFloat, playsOnHover: Bool = false) {
        self.pointHeight = pointHeight
        self.playsOnHover = playsOnHover
        super.init(frame: .zero)
        wantsLayer = true
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.minificationFilter = .trilinear
        layer?.addSublayer(spriteLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    private var isActive: Bool { window != nil && !isSuspended }

    private var pixelHeight: Int {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return SpriteLibrary.shared.pixelHeight(forPointHeight: pointHeight, scale: scale)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.frame = bounds
        spriteLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? releaseEverything() : reload()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reload()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard playsOnHover else { return }
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if playsOnHover { setPlaying(true) }
    }

    override func mouseExited(with event: NSEvent) {
        if playsOnHover { setPlaying(false) }
    }

    // MARK: API

    func show(_ state: SpriteState) {
        guard state != self.state else { return }
        let animated = self.state != nil
        self.state = state
        guard isActive else { return }
        loadPoster(animated: animated && animating == nil)
        if isPlaying { startFrames() }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        guard isActive else { return }
        playing ? startFrames() : stopFrames()
    }

    /// Suelta todo mientras la vista no se ve (p. ej. mascota oculta).
    func suspend() {
        isSuspended = true
        isPlaying = false
        releaseEverything()
    }

    func resume() {
        isSuspended = false
        reload()
    }

    // MARK: Carga

    private func reload() {
        guard isActive, state != nil else { return }
        loadPoster(animated: false)
        if isPlaying {
            animating = nil
            startFrames()
        }
    }

    private func loadPoster(animated: Bool) {
        guard let state else { return }
        let pixelHeight = pixelHeight
        posterTask?.cancel()
        posterTask = Task { [weak self] in
            guard let poster = await SpriteLibrary.shared.poster(state, pixelHeight: pixelHeight),
                  let self, !Task.isCancelled, self.state == state, self.isActive else { return }
            if animated { self.crossfade() }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.spriteLayer.contents = poster
            CATransaction.commit()
        }
    }

    private func startFrames() {
        guard let state, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        releaseTask?.cancel()
        let pixelHeight = pixelHeight
        if animating == state, let held, held.state == state, held.pixelHeight == pixelHeight { return }
        let library = SpriteLibrary.shared
        framesTask?.cancel()
        framesTask = Task { [weak self] in
            guard let frames = await library.acquire(state, pixelHeight: pixelHeight) else { return }
            guard let self, !Task.isCancelled, self.isPlaying, self.state == state, self.isActive else {
                library.release(state, pixelHeight: pixelHeight)
                return
            }
            let previous = self.held
            self.held = (state, pixelHeight)
            self.animate(frames, crossfade: self.animating != nil)
            self.animating = state
            if let previous {
                // Se suelta tras el fundido para no quedarse con dos estados en memoria.
                try? await Task.sleep(for: .seconds(0.6))
                library.release(previous.state, pixelHeight: previous.pixelHeight)
            }
        }
    }

    private func stopFrames() {
        framesTask?.cancel()
        if animating != nil {
            crossfade(duration: 0.25)
            spriteLayer.removeAnimation(forKey: "frames")
            animating = nil
        }
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.framesGracePeriod)
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            self.releaseHeldFrames()
        }
    }

    private func animate(_ frames: SpriteFrames, crossfade: Bool) {
        let count = frames.surfaces.count
        guard count > 1 else { return }
        if crossfade { self.crossfade() }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.surfaces
        // En modo discreto hacen falta N+1 instantes para que cada fotograma dure lo mismo.
        animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        animation.calculationMode = .discrete
        animation.duration = Double(count) * frames.frameDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        spriteLayer.add(animation, forKey: "frames")
    }

    private func crossfade(duration: CFTimeInterval = 0.35) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        spriteLayer.add(fade, forKey: "crossfade")
    }

    private func releaseHeldFrames() {
        if let held {
            SpriteLibrary.shared.release(held.state, pixelHeight: held.pixelHeight)
            self.held = nil
        }
    }

    private func releaseEverything() {
        posterTask?.cancel()
        framesTask?.cancel()
        releaseTask?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.removeAllAnimations()
        spriteLayer.contents = nil
        CATransaction.commit()
        animating = nil
        releaseHeldFrames()
    }
}

/// Envoltorio SwiftUI del reproductor.
/// El capibara está quieto y se anima mientras el cursor está encima.
struct CapySpriteView: NSViewRepresentable {
    let state: SpriteState
    var height: CGFloat

    func makeNSView(context: Context) -> SpritePlayerView {
        SpritePlayerView(pointHeight: height, playsOnHover: true)
    }

    func updateNSView(_ view: SpritePlayerView, context: Context) {
        view.pointHeight = height
        view.show(state)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpritePlayerView, context: Context) -> CGSize? {
        CGSize(width: height * SpriteLibrary.shared.aspectRatio, height: height)
    }
}
