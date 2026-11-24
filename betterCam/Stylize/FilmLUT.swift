import CoreImage
import CoreImage.CIFilterBuiltins

enum LUTEncoding: String, CaseIterable {
    case sRGB
    case linearSRGB

    var title: String {
        switch self {
        case .sRGB: "sRGB"
        case .linearSRGB: String(localized: "Linear sRGB")
        }
    }
}

enum LUTError: LocalizedError, Equatable {
    case invalidCube
    case unsupportedCube
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .invalidCube: String(localized: "The file is not a valid 3D LUT.")
        case .unsupportedCube: String(localized: "Only standalone 3D .cube LUTs are supported.")
        case .duplicateName: String(localized: "A style with that name already exists.")
        }
    }
}

struct FilmLUT {
    let data: Data
    let dimension: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>

    init(data: Data, dimension: Int, domainMin: SIMD3<Float> = .zero, domainMax: SIMD3<Float> = SIMD3(repeating: 1)) throws {
        guard (2...128).contains(dimension),
              data.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size,
              (0..<3).allSatisfy({
                  let range = domainMax[$0] - domainMin[$0]
                  return range > 0 && range.isFinite && (1 / range).isFinite && (domainMin[$0] / range).isFinite
              }) else { throw LUTError.invalidCube }
        self.data = data
        self.dimension = dimension
        self.domainMin = domainMin
        self.domainMax = domainMax
    }

    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var dimension: Int?
        var values: [Float] = []
        var minimum: SIMD3<Float> = .zero
        var maximum = SIMD3<Float>(repeating: 1)
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = line.prefix(while: { $0 != "#" })
                .split(whereSeparator: { $0.isWhitespace || $0 == "\u{FEFF}" })
            guard let key = tokens.first else { continue }
            switch key {
            case "TITLE":
                continue
            case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                throw LUTError.unsupportedCube
            case "LUT_3D_SIZE":
                guard dimension == nil, tokens.count == 2, let size = Int(tokens[1]), (2...128).contains(size) else {
                    throw LUTError.invalidCube
                }
                dimension = size
                values.reserveCapacity(size * size * size * 4)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard let triple = Self.parseTriple(tokens.dropFirst()) else { throw LUTError.invalidCube }
                if key == "DOMAIN_MIN" { minimum = triple } else { maximum = triple }
            case "LUT_3D_INPUT_RANGE":
                guard tokens.count == 3, let min = Float(tokens[1]), let max = Float(tokens[2]) else {
                    throw LUTError.invalidCube
                }
                minimum = SIMD3(repeating: min)
                maximum = SIMD3(repeating: max)
            default:
                guard let dimension, values.count < dimension * dimension * dimension * 4,
                      let triple = Self.parseTriple(tokens[...]) else { throw LUTError.invalidCube }
                values.append(triple.x)
                values.append(triple.y)
                values.append(triple.z)
                values.append(1)
            }
        }
        guard let dimension else { throw LUTError.invalidCube }
        try self.init(
            data: values.withUnsafeBytes { Data($0) },
            dimension: dimension,
            domainMin: minimum,
            domainMax: maximum
        )
    }

    private static func parseTriple(_ tokens: ArraySlice<Substring>) -> SIMD3<Float>? {
        let values = tokens.compactMap { Float($0) }
        guard tokens.count == 3, values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    func apply(to image: CIImage, encoding: LUTEncoding) -> CIImage {
        // CIColorCube sees numeric samples in the linear working space. Encode before
        // lookup and decode afterward if the table was made with sRGB code values.
        var input = encoding == .sRGB ? image.applyingFilter("CILinearToSRGBToneCurve") : image
        if domainMin != .zero || domainMax != SIMD3(repeating: 1) {
            let scale = 1 / (domainMax - domainMin)
            let bias = -domainMin * scale
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = input
            matrix.rVector = CIVector(x: CGFloat(scale.x), y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: CGFloat(scale.y), z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(scale.z), w: 0)
            matrix.biasVector = CIVector(x: CGFloat(bias.x), y: CGFloat(bias.y), z: CGFloat(bias.z), w: 0)
            input = matrix.outputImage ?? input
        }

        let cube = CIFilter.colorCube()
        cube.inputImage = input
        cube.cubeDimension = Float(dimension)
        cube.cubeData = data
        guard let mapped = cube.outputImage else { return image }
        return encoding == .sRGB ? mapped.applyingFilter("CISRGBToneCurveToLinear") : mapped
    }
}
