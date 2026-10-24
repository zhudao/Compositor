import CoreGraphics
import CoreImage

/// Filter › Lens Effects: what light does inside a camera's lens and the filters in front of it. Each effect is made from
/// the picture's own light, in linear light as optics work, so only real light sources flare and nothing is pasted on.
nonisolated enum LensEffect: String, CaseIterable, Sendable {
    case anamorphicFlare = "Anamorphic Flare"
    case starburst = "Starburst"
    case mist = "Mist"
    case prism = "Prism"
    case bokeh = "Bokeh"
}

/// The shape a lens draws its out-of-focus lights in.
nonisolated enum BokehShape: String, CaseIterable, Sendable {
    /// Wide open.
    case round = "Round"
    /// Stopped down, its aperture's blades showing as straight sides.
    case hexagon = "Hexagon"
    /// An anamorphic lens's tall ovals.
    case oval = "Oval"
    /// Clipped into a lemon shape toward the frame's edges, as fast and vintage lenses draw them.
    case catsEye = "Cat's Eye"

    var index: UInt32 { UInt32(Self.allCases.firstIndex(of: self) ?? 0) }
}

nonisolated struct LensEffectSettings: Equatable, Sendable {
    static let starPointChoices = [4, 6, 8, 12, 14]
    static let bokehSizes: ClosedRange<Double> = 0.5...6

    var effect: LensEffect = .anamorphicFlare
    /// Anamorphic Flare and Starburst: how bright a light has to be to flare, 50–99% of white.
    var threshold: Double = 90
    /// Anamorphic Flare: strength 0–100, and the streak's reach as a percentage of the layer's longer side.
    var flareAmount: Double = 50
    var flareLength: Double = 60
    /// How much the lens's coatings turn the streak blue along its length, 0–100: none keeps every streak the color of
    /// its light all the way.
    var flareBlue: Double = 80
    /// Starburst: strength, the spikes' reach (percent of the longer side), how many, and their angle in degrees.
    var starAmount: Double = 50
    var starLength: Double = 12
    var starPoints = 6
    var starAngle: Double = 15
    /// Mist: how much light scatters, and how far, 0–100.
    var mistStrength: Double = 50
    var mistSize: Double = 30
    /// Prism: how strong the ghosted copies are, how many, how far apart (percent of the longer side), which way in
    /// degrees (counterclockwise from right), and how far into the frame they reach from that edge (percent).
    var prismAmount: Double = 70
    var prismCopies: Double = 3
    var prismOffset: Double = 11
    var prismAngle: Double = 180
    var prismSpread: Double = 70
    /// Bokeh, always a full lens blur: the discs' size (percent of the longer side), how brightly lights open into
    /// them, how much of a disc's light gathers at its rim, as many lenses draw it, and the aperture's shape.
    var bokehRadius: Double = 2
    var bokehBrightness: Double = 50
    var bokehRing: Double = 100
    var bokehShape: BokehShape = .round

    /// Nothing to do: OK closes as Cancel does.
    var isIdentity: Bool {
        switch effect {
        case .anamorphicFlare: flareAmount == 0
        case .starburst: starAmount == 0
        case .mist: mistStrength == 0
        case .prism: prismAmount == 0 || prismOffset == 0
        case .bokeh: false
        }
    }

    var normalized: Self {
        var result = self
        result.threshold = ImageAdjustmentPixels.clamp(threshold, 50...99, 90)
        result.flareAmount = ImageAdjustmentPixels.clamp(flareAmount, 0...100, 50)
        result.flareLength = ImageAdjustmentPixels.clamp(flareLength, 1...100, 60)
        result.flareBlue = ImageAdjustmentPixels.clamp(flareBlue, 0...100, 80)
        result.starAmount = ImageAdjustmentPixels.clamp(starAmount, 0...100, 50)
        result.starLength = ImageAdjustmentPixels.clamp(starLength, 2...40, 12)
        result.starPoints = Self.starPointChoices.contains(starPoints) ? starPoints : 6
        result.starAngle = ImageAdjustmentPixels.clamp(starAngle, -180...180, 15)
        result.mistStrength = ImageAdjustmentPixels.clamp(mistStrength, 0...100, 50)
        result.mistSize = ImageAdjustmentPixels.clamp(mistSize, 0...100, 30)
        result.prismAmount = ImageAdjustmentPixels.clamp(prismAmount, 0...100, 70)
        result.prismCopies = ImageAdjustmentPixels.clamp(prismCopies, 1...8, 3).rounded()
        result.prismOffset = ImageAdjustmentPixels.clamp(prismOffset, 0...50, 11)
        result.prismAngle = ImageAdjustmentPixels.clamp(prismAngle, -180...180, 180)
        result.prismSpread = ImageAdjustmentPixels.clamp(prismSpread, 10...100, 70)
        result.bokehRadius = ImageAdjustmentPixels.clamp(bokehRadius, Self.bokehSizes.lowerBound...Self.bokehSizes.upperBound, 2)
        result.bokehBrightness = ImageAdjustmentPixels.clamp(bokehBrightness, 0...100, 50)
        result.bokehRing = ImageAdjustmentPixels.clamp(bokehRing, 0...100, 100)
        return result
    }

    /// The effect on `pixels`, an 8- or 16-bit layer's sRGB pixels. Sizes are proportions of the image, so a preview at
    /// a smaller size looks as the result will.
    func apply(to pixels: CGImage) throws -> CIImage {
        let settings = normalized
        let original = CIImage(cgImage: pixels), extent = original.extent
        // The light arithmetic runs on opaque colors, and the layer's own transparency goes back on at the end: Core
        // Image's blends weigh light by its alpha, which a thin streak hardly has.
        let image = original.unpremultiplyingAlpha().settingAlphaOne(in: extent)
        let result: CIImage
        switch settings.effect {
        case .anamorphicFlare: result = LensOptics.anamorphic(image, settings)
        case .starburst: result = LensOptics.starburst(image, settings)
        case .mist: result = LensOptics.mist(image, settings)
        case .prism: result = LensOptics.prism(image, settings)
        case .bokeh: result = try LensOptics.bokeh(image, settings)
        }
        return result.cropped(to: extent).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: original])
    }
}

/// The light arithmetic behind the lens effects, in Core Image.
private nonisolated enum LensOptics {
    static func linear(_ image: CIImage) -> CIImage { image.applyingFilter("CISRGBToneCurveToLinear") }
    static func gamma(_ image: CIImage) -> CIImage { image.applyingFilter("CILinearToSRGBToneCurve") }

    /// Red, green and blue scaled, alpha left as it is.
    static func scaled(_ image: CIImage, _ red: Double, _ green: Double, _ blue: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    static func scaled(_ image: CIImage, _ amount: Double) -> CIImage { scaled(image, amount, amount, amount) }

    /// Light added to light, both laid over black first: the blend weighs light by its alpha, which a thin streak
    /// hardly has. Not `CIAdditionCompositing`, which adds the alphas too, past one.
    static func add(_ light: CIImage, to image: CIImage) -> CIImage {
        let black = CIImage(color: .black)
        return light.composited(over: black).applyingFilter("CILinearDodgeBlendMode", parameters: [
            kCIInputBackgroundImageKey: image.composited(over: black)])
    }

    /// The light brighter than `threshold` (0–1, on the picture's own tones), in linear light, fading in above it.
    static func highlights(_ image: CIImage, threshold: Double) -> CIImage {
        let t = min(0.95, max(0, threshold)), k = 1 - t
        let luminance = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let gray = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luminance, "inputGVector": luminance, "inputBVector": luminance,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        let mask = gray.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: t, y: 0),
            "inputPoint2": CIVector(x: t + k * 0.4, y: 0.25), "inputPoint3": CIVector(x: t + k * 0.75, y: 0.7),
            "inputPoint4": CIVector(x: 1, y: 1)])
        // Over black, not clear: a tone curve or blend reads a dim light divided by its alpha.
        return linear(image).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .black), kCIInputMaskImageKey: mask]).cropped(to: image.extent)
    }

    /// Only the lights shorter than `height` pixels: the light less its vertical opening, so a wide bright area drops
    /// out and a lamp or a glint stays.
    static func compact(_ light: CIImage, height: CGFloat) -> CIImage {
        let size = max(3, Int(height) | 1)
        let opened = light.applyingFilter("CIMorphologyRectangleMinimum", parameters: ["inputWidth": 1, "inputHeight": size])
            .applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": 1, "inputHeight": size])
        return light.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: light, kCIInputImageKey: opened])
    }

    /// `image` blurred along `angle` (radians) with a standard deviation of `along` pixels and `across` pixels across
    /// it: squeezed along the line, blurred evenly and stretched back, so a long streak costs no more than a short one.
    /// `spread` first draws each light out along the line, which lifts a small light far more than a wide bright area.
    static func streak(_ image: CIImage, angle: CGFloat, along: CGFloat, across: CGFloat, spread: CGFloat = 0) -> CIImage {
        let across = max(0.5, across)
        let squeeze = max(1, along / across)
        var turned = angle == 0 ? image : image.transformed(by: CGAffineTransform(rotationAngle: -angle))
        if spread >= 3 {
            turned = turned.applyingFilter("CIMorphologyRectangleMaximum", parameters: [
                "inputWidth": min(301, Int(spread) | 1), "inputHeight": 1])
        }
        let origin = turned.extent.origin
        let small = turned.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1, kCIInputAspectRatioKey: 1 / squeeze])
        let back = small.applyingGaussianBlur(sigma: across)
            .transformed(by: CGAffineTransform(scaleX: squeeze, y: 1))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        return angle == 0 ? back : back.transformed(by: CGAffineTransform(rotationAngle: angle))
    }

    /// Horizontal streaks as an anamorphic lens's cylindrical glass draws them, made from the picture's own light.
    /// Lights brighter than Threshold flare, the more the brighter they are, and concentrated ones — a lamp, the sun,
    /// daylight through an opening — count for far more than the same light scattered in glints. Each throws a thin line across the frame inside a softer band, a white core and a veil.
    /// Near the light a streak keeps the light's own color; along it the coatings turn it blue, reaching farthest in
    /// blue and least in red, as much as Blue asks. Each color is eased off before it's tinted, so a strong streak stays
    /// saturated rather than whitening.
    static func anamorphic(_ image: CIImage, _ settings: LensEffectSettings) -> CIImage {
        let extent = image.extent, side = max(extent.width, extent.height)
        let reach = side * settings.flareLength / 100, thin = max(0.5, side * 0.0008)
        let amount = settings.flareAmount / 50, blue = settings.flareBlue / 100
        let spread = highlights(image, threshold: settings.threshold / 100).clampedToExtent()
            .applyingGaussianBlur(sigma: side * 0.004).cropped(to: extent)
        let lifted = add(spread, to: CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: extent))
        let sources = scaled(spread.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: lifted]), 1.6)
            .cropped(to: extent)
        // The thin line comes from compact lights only: drawn from a big one it would be as tall as the light.
        let lineSources = compact(sources, height: side * 0.012)
        let lengths = [1 - 0.7 * blue, 1 - 0.4 * blue, 1.0], coat = [1 - blue * 0.9, 1 - blue * 0.62, 1.0]
        func only(_ light: CIImage, _ channel: Int, _ gain: Double) -> CIImage {
            scaled(light, channel == 0 ? gain : 0, channel == 1 ? gain : 0, channel == 2 ? gain : 0)
        }
        var flare = CIImage.empty()
        for channel in 0..<3 {
            let line = streak(lineSources, angle: 0, along: reach * lengths[channel], across: thin)
            flare = add(only(softClip(scaled(line, 4 * amount), limit: 0.6), channel, coat[channel]), to: flare)
            // The band: brightest near the light, fading toward the frame's edges.
            var band = CIImage.empty()
            for (fraction, weight) in [(0.08, 0.8), (0.3, 0.35), (0.9, 0.15)] {
                let along = reach * fraction * lengths[channel]
                let gain = weight * pow(along / (side * 0.08), 0.5) * amount
                band = add(scaled(streak(sources, angle: 0, along: along, across: side * 0.006), gain), to: band)
            }
            flare = add(only(softClip(band, limit: 0.7), channel, coat[channel]), to: flare)
        }
        let core = streak(sources, angle: 0, along: side * 0.015, across: thin * 3)
        let veil = sources.clampedToExtent().applyingGaussianBlur(sigma: side * 0.04).cropped(to: extent)
        flare = add(scaled(core, 1.2 * amount), to: flare)
        flare = add(scaled(veil, 0.5 * amount * coat[0], 0.5 * amount * coat[1], 0.5 * amount), to: flare)
        return gamma(add(flare, to: linear(image)))
    }

    /// Thin spikes from each light, as an aperture's blades diffract it: fading quickly from the light, and a little
    /// longer in red than in blue, as diffraction spreads longer waves farther.
    static func starburst(_ image: CIImage, _ settings: LensEffectSettings) -> CIImage {
        let side = max(image.extent.width, image.extent.height)
        let light = highlights(image, threshold: settings.threshold / 100)
        let reach = side * settings.starLength / 100, thin = max(0.5, side * 0.0006)
        let spokes = max(1, settings.starPoints / 2)
        var rays = CIImage.empty()
        for spoke in 0..<spokes {
            let theta = settings.starAngle * .pi / 180 + Double(spoke) * .pi / Double(spokes)
            for (fraction, weight) in [(0.04, 1.8), (0.12, 0.9), (0.35, 0.35), (1.0, 0.1)] {
                for (channel, stretch) in [(0, 1.0), (1, 0.9), (2, 0.8)] {
                    let along = max(thin * 2, reach * fraction * stretch)
                    let gain = weight * settings.starAmount / 50
                    let blurred = streak(light, angle: theta, along: along, across: thin, spread: along * 0.8)
                    rays = add(scaled(blurred, channel == 0 ? gain : 0, channel == 1 ? gain : 0, channel == 2 ? gain : 0), to: rays)
                }
            }
        }
        return gamma(add(rays, to: linear(image)))
    }

    /// A diffusion filter, as a black mist one: a share of every pixel's light scatters into a near halo and a wide
    /// veil rather than being added, so bright areas soften and spill and the shadows lift a little, without the whole
    /// picture brightening. The brightest lights scatter a little extra.
    static func mist(_ image: CIImage, _ settings: LensEffectSettings) -> CIImage {
        let extent = image.extent, side = max(extent.width, extent.height)
        let light = linear(image)
        let scale = side * (0.2 + settings.mistSize / 100 * 1.8) / 100
        let near = light.clampedToExtent().applyingGaussianBlur(sigma: scale * 0.6).cropped(to: extent)
        let far = light.clampedToExtent().applyingGaussianBlur(sigma: scale * 4).cropped(to: extent)
        let glow = highlights(image, threshold: 0.75).clampedToExtent().applyingGaussianBlur(sigma: scale * 1.5).cropped(to: extent)
        let strength = settings.mistStrength / 100, scatter = strength * 0.4
        let scattered = add(scaled(glow, strength * 0.35), to: add(scaled(far, scatter * 0.4), to: scaled(near, scatter * 0.6)))
        return gamma(add(scattered, to: scaled(light, 1 - scatter)))
    }

    /// The blur of a lens focused elsewhere: every point spreads into a disc of the aperture's shape, not the soft
    /// smear of a Gaussian blur (see `MetalBokeh`). In a real photo a light is far brighter than white, so its disc
    /// stays bright: the lights are boosted, blurred on their own and eased back, so a wide bright area doesn't blow out.
    static func bokeh(_ image: CIImage, _ settings: LensEffectSettings) throws -> CIImage {
        let extent = image.extent, side = max(extent.width, extent.height)
        let radius = side * settings.bokehRadius / 100
        guard let gpu = MetalBokeh.shared else { throw ExportError.render }
        func disc(_ light: CIImage) throws -> CIImage {
            try gpu.blur(light, extent: extent, radius: radius, shape: settings.bokehShape, ring: settings.bokehRing / 100)
        }
        // Even at its least, lights open into clear discs: Brightness says how much they glow, not whether.
        let lights = scaled(highlights(image, threshold: 0.8), 12 + settings.bokehBrightness * 0.7)
        return gamma(add(softClip(try disc(lights), limit: 0.8), to: try disc(linear(image))))
    }

    /// Light compressed smoothly toward `limit`: nearly unchanged when dim, never past it.
    static func softClip(_ light: CIImage, limit: Double) -> CIImage {
        let curved = scaled(light.composited(over: CIImage(color: .black)), 1 / (4 * limit)).applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.0625, y: 0.224), "inputPoint2": CIVector(x: 0.125, y: 0.398),
            "inputPoint3": CIVector(x: 0.25, y: 0.638), "inputPoint4": CIVector(x: 1, y: 1)])
        return scaled(curved, limit)
    }

    /// A prism held at the lens's edge: copies of the picture stepped sideways, each a little fainter and softer and its
    /// colors fanned a little wider, as light bent more times through the glass. They show where they're brighter than
    /// the picture, so they echo into its darker parts, strongest at the edge they're pushed toward.
    static func prism(_ image: CIImage, _ settings: LensEffectSettings) -> CIImage {
        let extent = image.extent, side = max(extent.width, extent.height)
        let light = linear(image)
        let theta = settings.prismAngle * .pi / 180
        let direction = CGVector(dx: cos(theta), dy: sin(theta))
        let shift = side * settings.prismOffset / 100
        var echoes = CIImage.empty()
        for copy in 1...Int(settings.prismCopies) {
            let step = CGFloat(copy)
            var ghost = CIImage.empty()
            for (channel, stretch) in [(0, 1 + 0.012 * step), (1, 1.0), (2, 1 - 0.012 * step)] {
                let moved = light.transformed(by: CGAffineTransform(translationX: direction.dx * shift * step * stretch,
                                                                    y: direction.dy * shift * step * stretch))
                ghost = add(scaled(moved, channel == 0 ? 1 : 0, channel == 1 ? 1 : 0, channel == 2 ? 1 : 0), to: ghost)
            }
            let fade = pow(0.72, Double(copy - 1)) * settings.prismAmount / 100
            ghost = scaled(ghost.clampedToExtent().applyingGaussianBlur(sigma: side * 0.004 * step).cropped(to: extent), fade)
            echoes = copy == 1 ? ghost : lighten(ghost, echoes)
        }
        let reach = abs(direction.dx) * extent.width / 2 + abs(direction.dy) * extent.height / 2
        let edge = CGPoint(x: extent.midX + direction.dx * reach, y: extent.midY + direction.dy * reach)
        let depth = side * settings.prismSpread / 100
        let inner = CGPoint(x: edge.x - direction.dx * depth, y: edge.y - direction.dy * depth)
        let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: edge), "inputPoint1": CIVector(cgPoint: inner),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])?.outputImage?.cropped(to: extent) ?? CIImage.empty()
        let band = echoes.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: light, kCIInputMaskImageKey: mask])
        return gamma(lighten(band, light))
    }

    static func lighten(_ image: CIImage, _ background: CIImage) -> CIImage {
        image.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: background])
    }

}
