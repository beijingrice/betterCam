import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import os

struct FilmGrain {
    let size: Float
    let amplitude: Float
    var chroma: Float = 0

    // `size` is the grain cell as a fraction of the short edge; a grain spans about two
    // cells. Around 0.0008 puts roughly 600 grains across the short edge, close to 35 mm
    // film, and stays fine on a 48 MP capture.
    static let color = FilmGrain(size: 0.0008, amplitude: 0.10)
    static let monochrome = FilmGrain(size: 0.00095, amplitude: 0.13)
    static let imported = FilmGrain(size: 0.00078, amplitude: 0.10)
}

struct FilmSimulation {
    enum Look {
        case photoEffect(String)
        case cube(FilmLUT, LUTEncoding)
    }

    var name: String
    var look: Look?
    var grain: FilmGrain?
    var fileName: String?

    var customEncoding: LUTEncoding? {
        guard fileName != nil, case let .cube(_, encoding) = look else { return nil }
        return encoding
    }
}

struct FilmRenderSettings {
    var simulation: FilmSimulation? = nil
    var colorAmount: Float = 0
    var grainAmount: Float = 0

    static let standard = FilmRenderSettings(style: nil, colorAmount: 0, grainAmount: 0, appliesLook: false)

    init(style: FilmSimulation?, colorAmount: Float, grainAmount: Float, appliesLook: Bool) {
        guard appliesLook, let style, style.look != nil else { return }
        simulation = style
        self.colorAmount = min(max(colorAmount, 0), 1)
        self.grainAmount = min(max(grainAmount, 0), 1)
    }
}

final class FilmEngine: ObservableObject {
    static let shared = FilmEngine()
    static let standardName = "STD"
    static let manageName = "MANAGE"
    static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // Viewfinder and JPEG. Looks are authored in sRGB, but unstyled or partly styled
    // pixels keep the camera's wider gamut instead of being clipped to sRGB.
    static let deliveryColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    @Published var availableSimulations: [FilmSimulation]
    let documents: URL
    let preferences: UserDefaults

    init(
        documents: URL = URL.documentsDirectory,
        preferences: UserDefaults = .standard,
        bundle: Bundle = .main
    ) {
        self.documents = documents
        self.preferences = preferences
        self.availableSimulations = [
            FilmSimulation(name: Self.standardName),
            FilmSimulation(name: "CHROME", look: .photoEffect("CIPhotoEffectChrome"), grain: .color),
            FilmSimulation(name: "INSTANT", look: .photoEffect("CIPhotoEffectInstant"), grain: .color),
            FilmSimulation(name: "FADE", look: .photoEffect("CIPhotoEffectFade"), grain: .color),
            FilmSimulation(name: "PROCESS", look: .photoEffect("CIPhotoEffectProcess"), grain: .color),
            FilmSimulation(name: "TRANSFER", look: .photoEffect("CIPhotoEffectTransfer"), grain: .color),
            FilmSimulation(name: "MONO", look: .photoEffect("CIPhotoEffectMono"), grain: .monochrome),
            FilmSimulation(name: "NOIR", look: .photoEffect("CIPhotoEffectNoir"), grain: .monochrome),
            FilmSimulation(name: "TONAL", look: .photoEffect("CIPhotoEffectTonal"), grain: .monochrome)
        ]
        loadBundleLUTs(from: bundle)
        loadSavedCustomLUTs()
    }

    private func loadBundleLUTs(from bundle: Bundle) {
        let presets: [(file: String, grain: FilmGrain)] = [
            ("Fujicolor_400", FilmGrain(size: 0.00105, amplitude: 0.13, chroma: 0.035)),
            ("Fujicolor_C200", FilmGrain(size: 0.00078, amplitude: 0.10, chroma: 0.03)),
            ("Kodak_Gold_200", FilmGrain(size: 0.00075, amplitude: 0.10, chroma: 0.025)),
            ("Kodak_Vision3_250D_5207", FilmGrain(size: 0.00065, amplitude: 0.085, chroma: 0.02))
        ]
        for preset in presets {
            guard let url = bundle.url(forResource: preset.file, withExtension: "cube"),
                  let cube = try? FilmLUT(contentsOf: url) else { continue }
            // The files carry no color-space metadata, but their gray axes are ordinary
            // film curves on sRGB code values (mid gray stays near 0.45–0.5). Read as
            // linear input they crushed everything below ~0.25 sRGB to black.
            availableSimulations.append(FilmSimulation(
                name: preset.file.uppercased(), look: .cube(cube, .sRGB), grain: preset.grain
            ))
        }
    }

    func settings(styleName: String, colorAmount: Float, grainAmount: Float, appliesLook: Bool) -> FilmRenderSettings {
        FilmRenderSettings(
            style: availableSimulations.first(where: { $0.name == styleName }),
            colorAmount: colorAmount, grainAmount: grainAmount, appliesLook: appliesLook
        )
    }

    // Both destinations are SDR. Only compress a source that advertises HDR headroom.
    static func prepareSDR(_ input: CIImage) -> CIImage {
        let headroom = input.contentHeadroom
        guard headroom > 1 else { return input }
        let toneMap = CIFilter.toneMapHeadroom()
        toneMap.inputImage = input
        toneMap.sourceHeadroom = headroom
        toneMap.targetHeadroom = 1
        return toneMap.outputImage ?? input
    }

    static func process(_ input: CIImage, settings: FilmRenderSettings, grainSeed: UInt32) -> CIImage {
        guard let simulation = settings.simulation, let look = simulation.look else { return input }
        var image = input
        if settings.colorAmount > 0 {
            let styled: CIImage
            switch look {
            case .photoEffect(let filter): styled = input.applyingFilter(filter)
            case .cube(let lut, let encoding): styled = lut.apply(to: input, encoding: encoding)
            }
            if settings.colorAmount == 1 {
                image = styled
            } else {
                let blend = CIFilter.blendWithAlphaMask()
                blend.inputImage = styled
                blend.backgroundImage = input
                blend.maskImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(settings.colorAmount)))
                    .cropped(to: input.extent)
                image = blend.outputImage ?? input
            }
        }

        guard settings.grainAmount > 0, let grain = simulation.grain else { return image }
        let shortEdge = min(image.extent.width, image.extent.height)
        let size = max(1, Float(shortEdge) * grain.size)
        let offset = CIVector(x: CGFloat(grainSeed & 0xffff), y: CGFloat(grainSeed >> 16))
        return grainKernel?.apply(extent: image.extent, arguments: [
            image, size, grain.amplitude * settings.grainAmount, grain.chroma, offset
        ]) ?? image
    }

    static let grainKernel: CIColorKernel? = {
        let log = Logger(subsystem: "com.bettercam", category: "FilmEngine")
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            log.fault("default.metallib is missing; grain is disabled")
            assertionFailure("default.metallib is missing")
            return nil
        }
        do {
            let library = try Data(contentsOf: url)
            return try CIColorKernel(functionName: "betterCamGrain", fromMetalLibraryData: library)
        } catch {
            log.fault("Grain kernel failed to load: \(error, privacy: .public)")
            assertionFailure("Grain kernel failed to load: \(error)")
            return nil
        }
    }()
}
