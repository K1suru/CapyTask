import Foundation
import IOSurface
import Testing
@testable import CapyTask

@MainActor
@Suite("Animación del capibara")
struct SpriteTests {
    @Test func readsMetadataForTheThreeStates() throws {
        let metadata = try #require(SpriteLibrary.shared.metadata, "No se encontró assets_processed/metadata.json")
        #expect(metadata.width == 232)
        #expect(metadata.height == 311)
        for state in SpriteState.allCases {
            let info = try #require(metadata.states[state.rawValue])
            #expect(info.frameCount == 64)
            #expect(abs(info.avgDurationMs - 62.5) < 0.01) // ~16 fps
        }
    }

    @Test func moodsMapToSprites() {
        #expect(CapyMood.normal.sprite == .normal)
        #expect(CapyMood.worried.sprite == .worried)
        #expect(CapyMood.stressed.sprite == .stressed)
    }

    @Test func decodesAllFramesAtScreenSizeQuickly() async throws {
        let baseURL = try #require(SpriteLibrary.locateAssets())
        let info = try #require(SpriteLibrary.shared.metadata?.states["worried"])
        let clock = ContinuousClock()
        let started = clock.now
        let frames = try #require(SpriteLibrary.decode(baseURL: baseURL, info: info, pixelHeight: 272))
        let elapsed = clock.now - started
        #expect(frames.surfaces.count == 64)
        #expect(frames.surfaces[0].height == 272)
        #expect(frames.surfaces[0].width == 203)
        #expect(abs(frames.frameDuration - 0.0625) < 0.0001)
        #expect(elapsed < .seconds(1), "decodificar 64 fotogramas tardó \(elapsed)")
        print("sprite: 64 fotogramas a 272 px en \(elapsed), \(frames.byteCount / 1_048_576) MB")
    }

    @Test func pixelSizeIsQuantizedAndNeverUpscaled() {
        let library = SpriteLibrary.shared
        #expect(library.pixelHeight(forPointHeight: 400, scale: 2) == 311)
        #expect(library.pixelHeight(forPointHeight: 110, scale: 2) == 224)
        #expect(library.pixelHeight(forPointHeight: 136, scale: 2) == 272)
        // Tamaños casi iguales comparten fotogramas.
        #expect(library.pixelHeight(forPointHeight: 101, scale: 2) == library.pixelHeight(forPointHeight: 104, scale: 2))
    }

    @Test func sharesFramesAndReleasesThem() async throws {
        let library = SpriteLibrary.shared
        let first = try #require(await library.acquire(.normal, pixelHeight: 100))
        let second = try #require(await library.acquire(.normal, pixelHeight: 100))
        #expect(first.surfaces[0] === second.surfaces[0], "Dos vistas deben compartir los mismos fotogramas")
        library.release(.normal, pixelHeight: 100)
        library.release(.normal, pixelHeight: 100)
        let third = try #require(await library.acquire(.normal, pixelHeight: 100))
        #expect(third.surfaces[0] !== first.surfaces[0], "Sin usuarios, los fotogramas se liberan")
        library.release(.normal, pixelHeight: 100)
    }
}
