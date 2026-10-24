import CoreGraphics
import CoreImage
import Metal

/// Bokeh's lens blur on the GPU: every pixel gathers the light around it within the aperture's shape — round, a
/// hexagon of blades, an anamorphic oval, or a cat's eye clipped toward the frame's edges — more of it at the rim when
/// Ring asks. It works in half floats, so lights brighter than white keep their brightness through the blur. A big
/// blur runs on a smaller copy, which it hides, so its cost stays the same however wide the discs.
nonisolated final class MetalBokeh: @unchecked Sendable {
    static let shared: MetalBokeh? = try? MetalBokeh()
    /// The widest disc radius gathered at full size, in pixels.
    static let largestRadius: CGFloat = 20
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    struct Parameters {
        var radius: Float
        var shape: UInt32
        var ring: Float
        var width: Float
        var height: Float
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let function = try device.makeLibrary(source: Self.source, options: nil).makeFunction(name: "bokeh")
        else { throw ExportError.render }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// `image` blurred into discs of `radius` pixels within `extent`, the result covering `extent`.
    func blur(_ image: CIImage, extent: CGRect, radius: CGFloat, shape: BokehShape, ring: Double) throws -> CIImage {
        let shrink = min(1, Self.largestRadius / max(radius, 0.5))
        let small = radius * shrink
        // Room for the discs reaching in from past the edge, which carries its edge pixels on.
        let margin = (small * 1.7).rounded(.up) + 2
        let region = CGRect(x: extent.minX * shrink, y: extent.minY * shrink, width: extent.width * shrink, height: extent.height * shrink)
            .insetBy(dx: -margin, dy: -margin).integral
        let width = Int(region.width), height = Int(region.height), rowBytes = width * 8
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let source = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
        PixelAdjust.ciContext.render(source, toBitmap: &pixels, rowBytes: rowBytes, bounds: region, format: .RGBAh, colorSpace: nil)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let input = device.makeTexture(descriptor: descriptor), let output = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        let all = MTLRegionMake2D(0, 0, width, height)
        input.replace(region: all, mipmapLevel: 0, withBytes: pixels, bytesPerRow: rowBytes)
        var parameters = Parameters(radius: Float(small), shape: shape.index, ring: Float(ring),
                                    width: Float(width), height: Float(height))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? ExportError.render }
        output.getBytes(&pixels, bytesPerRow: rowBytes, from: all, mipmapLevel: 0)

        let blurred = CIImage(bitmapData: Data(bytes: pixels, count: pixels.count * 2), bytesPerRow: rowBytes,
                              size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: nil)
        return blurred.transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / shrink, y: 1 / shrink))).cropped(to: extent)
    }

    // Compiled at launch by the system's Metal compiler, as the brush's is.
    private static let source = """
#include <metal_stdlib>
using namespace metal;

struct Parameters {
    float radius;
    uint shape;     // 0 round, 1 hexagon, 2 oval, 3 cat's eye
    float ring;
    float width;
    float height;
};

// How far `o` (in disc radii) is toward the aperture's edge, 1 on it.
float aperture(float2 o, uint shape, float2 outward) {
    if (shape == 1) {
        float2 q = abs(o);
        return max(q.x * 0.866025 + q.y * 0.5, q.y) / 0.866025 * 0.93;
    }
    if (shape == 2) return length(o * float2(1.0, 0.62));
    if (shape == 3) {
        // The disc clipped by a second one shifted toward the frame's middle, more so farther out.
        return max(length(o), length(o + outward * 1.25));
    }
    return length(o);
}

kernel void bokeh(texture2d<float, access::sample> image [[texture(0)]],
                  texture2d<float, access::write> result [[texture(1)]],
                  constant Parameters &p [[buffer(0)]],
                  uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= result.get_width() || pixel.y >= result.get_height()) return;
    constexpr sampler linear(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 at = float2(pixel) + 0.5;
    float2 fromMiddle = (at - float2(p.width, p.height) * 0.5) / (max(p.width, p.height) * 0.5);
    float2 outward = fromMiddle * min(1.0, length(fromMiddle));
    float radius = max(p.radius, 0.5);
    int reachX = int(ceil(radius)), reachY = int(ceil(radius * (p.shape == 2 ? 1.62 : 1.0)));
    float soft = 1.0 / radius;
    float4 sum = 0;
    float total = 0;
    for (int dy = -reachY; dy <= reachY; dy++) {
        for (int dx = -reachX; dx <= reachX; dx++) {
            float2 o = float2(dx, dy) / radius;
            float d = aperture(o, p.shape, outward);
            float inside = 1.0 - smoothstep(1.0 - soft, 1.0, d);
            if (inside <= 0.0) continue;
            // A lens that draws its discs with a bright rim, as many fast ones do.
            float weight = inside * (1.0 + p.ring * 2.5 * smoothstep(0.6, 0.97, d));
            sum += image.sample(linear, at + float2(dx, dy)) * weight;
            total += weight;
        }
    }
    result.write(sum / max(total, 1e-5), pixel);
}
"""
}
