import AppKit
import CoreImage
import Testing
@testable import Compositor

/// Progressive Blur, Bloom / Glow and RGB Split as adjustment layers.
@MainActor
struct FilterLayerTests {
    /// A white square in the middle of a clear 61 × 61 image, rows top-down.
    private func square() throws -> CGImage {
        let context = try BrushRaster.context(width: 61, height: 61, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 28, y: 28, width: 5, height: 5))
        return try #require(context.makeImage())
    }

    private func reader(_ image: CGImage) throws -> (Int, Int) -> [Int] {
        let width = image.width, height = image.height
        let read = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        read.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return { x, y in (0..<4).map { Int(bytes[(y * width + x) * 4 + $0]) } } // rows top-down
    }

    /// The canvas's GPU drawing runs the dispersion in Core Image's coordinates, whose y points up: a split pointing
    /// up there puts red above the square and blue below, as on the CPU.
    @Test func dispersionInCoreImageFollowsItsCoordinates() throws {
        guard MetalDispersion.shared != nil else { return }
        let image = CIImage(cgImage: try square())
        let parameters = MetalDispersion.Parameters(center: .zero, direction: SIMD2(0, 1), distance: 8, blur: 0, reach: 1,
                                                    radial: 0, sides: 0, spectral: 8, smear: 1)
        let result = try #require(MetalDispersion.apply(to: image, parameters, margin: 18))
        let rendered = try #require(CIContext().createCGImage(result, from: CGRect(x: 0, y: 0, width: 61, height: 61)))
        let pixel = try reader(rendered)
        let above = (19...26).reduce([0, 0]) { [$0[0] + pixel(30, $1)[0], $0[1] + pixel(30, $1)[2]] }
        let below = (34...41).reduce([0, 0]) { [$0[0] + pixel(30, $1)[0], $0[1] + pixel(30, $1)[2]] }
        #expect(above[0] > above[1] * 2, "red above: \(above)")
        #expect(below[1] > below[0] * 2, "blue below: \(below)")
    }

    /// Each new kind adds as a layer that changes what's under it when exported, opens in its filter's panel, and
    /// survives saving, which needs version 16.
    @Test func filterLayersRenderEditAndSave() async throws {
        let session = EditorSession()
        session.createDocument(width: 61, height: 61)
        let image = try square()
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Square"))
        let before = try reader(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        for kind in [AdjustmentKind.progressiveBlur, .bloomGlow, .rgbSplit] {
            session.addAdjustment(kind)
            #expect(session.adjustmentEditingID != nil)
            await session.beginAdjustmentEditing(try #require(session.adjustmentEditingID))
            #expect(session.filterEdit?.kind == kind.filterKind, "\(kind) opens its filter's panel")
            if kind == .bloomGlow {
                var settings = try #require(session.filterEdit?.settings)
                settings.bloomRadius = 10
                session.updateFilter(settings, preview: true)
            }
            session.finishAdjustmentEditing(commit: true)
        }
        let layers = try #require(session.document?.layers)
        #expect(layers.compactMap(\.adjustment?.kind) == [.progressiveBlur, .bloomGlow, .rgbSplit])
        #expect(layers[2].adjustment?.filterLayer.bloomRadius == 10)
        #expect(layers[1].adjustment?.filterLayer.progressiveStart != nil && layers[3].adjustment?.filterLayer.rgbSplitCenter != nil)

        let snapshot = try #require(session.projectSnapshot())
        let after = try reader(try await ImageExporter.shared.render(snapshot).image)
        #expect((0..<61).contains { x in after(x, 20) != before(x, 20) } || after(30, 30) != before(30, 30), "the layers change the image")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FilterLayers-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.compactMap(\.adjustment?.kind) == [.progressiveBlur, .bloomGlow, .rgbSplit])
        var older = snapshot.manifest
        older.version = 15
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }

    /// The canvas can draw each of them on the GPU, rather than falling back to the slower drawing.
    @Test func theCanvasDrawsThemOnTheGPU() {
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        for kind in [AdjustmentKind.progressiveBlur, .bloomGlow] + (MetalDispersion.shared == nil ? [] : [.rgbSplit]) {
            #expect(GPUAdjustment.apply(LayerAdjustment(kind: kind), to: image, scale: 1, mapping: .identity) != nil, "\(kind)")
        }
    }
}
