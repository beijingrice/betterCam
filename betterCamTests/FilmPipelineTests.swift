import CoreImage
import Foundation
import Testing
@testable import betterCam

struct FilmPipelineTests {
    private let context = CIContext(options: [
        .workingColorSpace: FilmEngine.workingColorSpace, .workingFormat: CIFormat.RGBAf
    ])

    @Test func encodedLUTUsesEncodedSamples() throws {
        let lut = try makeLUT(multiplier: 0.5)
        let source = patch(0.5, colorSpace: FilmEngine.sRGBColorSpace)
        let encoded = pixels(lut.apply(to: source, encoding: .sRGB), colorSpace: FilmEngine.sRGBColorSpace)[0]
        let linear = pixels(lut.apply(to: source, encoding: .linearSRGB), colorSpace: FilmEngine.sRGBColorSpace)[0]
        #expect(abs(encoded - 0.25) < 0.01)
        #expect(abs(linear - 0.361) < 0.01)
    }

    @Test func importUsesDomainAndRejectsBadRows() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.cube")
        let header = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 0.5 0.5 0.5\n"
        let rows = (0..<8).map { "\($0 & 1) \(($0 >> 1) & 1) \($0 >> 2)" }.joined(separator: "\n")
        try (header + rows).write(to: url, atomically: true, encoding: .utf8)
        let lut = try FilmLUT(contentsOf: url)
        #expect(lut.domainMax == SIMD3(repeating: 0.5))
        let result = pixels(lut.apply(to: patch(0.25), encoding: .linearSRGB))[0]
        #expect(abs(result - 0.5) < 0.01)
        try (header + rows + "\n0 0 0").write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: LUTError.invalidCube) { try FilmLUT(contentsOf: url) }
    }

    @available(iOS 26.0, *)
    @Test func knownHDRHeadroomIsMappedBeforeTheLook() throws {
        let hdr = bitmap([2, 4]).settingContentHeadroom(4)
        let pixelsBefore = pixels(hdr.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2]))
        try #require(pixelsBefore.count == 8)
        #expect(abs(pixelsBefore[0] - 0.5) < 0.01)
        #expect(abs(pixelsBefore[4] - 1) < 0.01)
        let mapped = pixels(FilmEngine.prepareSDR(hdr))
        try #require(mapped.count == 8)
        #expect(mapped[0] > 0)
        #expect(mapped[0] < mapped[4])
        #expect(mapped[4] <= 1.01)
    }

    @Test func builtInHighlightRampsRemainDistinct() throws {
        let builtIns = try builtInCubes()
        for name in ["FUJICOLOR_400", "KODAK_GOLD_200"] {
            let (lut, encoding) = try #require(builtIns[name])
            // The top eighth of the sRGB range, sampled every 1/64 of a code value.
            let strip = bitmap((56...64).map { Self.linear(Float($0) / 64) })
            let rendered = pixels(lut.apply(to: strip, encoding: encoding))
            try #require(rendered.count == 9 * 4)
            for channel in 0..<3 {
                let ramp = (0..<9).map { rendered[$0 * 4 + channel] }
                #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 < $1 }, "\(name), channel \(channel): \(ramp)")
            }
        }
    }

    @Test func builtInLooksKeepShadowDetail() throws {
        let builtIns = try builtInCubes()
        #expect(builtIns.count == 4)
        for (name, (lut, encoding)) in builtIns {
            #expect(encoding == .sRGB, "\(name)")
            // sRGB 0.2 and 0.3: the old linear reading turned these near-black.
            let rendered = pixels(lut.apply(to: bitmap([Self.linear(0.2), Self.linear(0.3)]), encoding: encoding),
                                  colorSpace: FilmEngine.sRGBColorSpace)
            for channel in 0..<3 {
                #expect(rendered[channel] > 0.08, "\(name) at 0.2, channel \(channel): \(rendered[channel])")
                #expect(rendered[4 + channel] > rendered[channel] + 0.05, "\(name) 0.2→0.3, channel \(channel)")
            }
        }
    }

    @Test func grainRespondsToStrengthAndCaptureSeed() {
        let source = patch(0.25, side: 64)
        let clean = pixels(source)
        let low = grain(on: source, amount: 0.1, seed: 42)
        let high = grain(on: source, amount: 1, seed: 42)

        #expect(grain(on: source, amount: 0, seed: 42) == clean)
        #expect(high == grain(on: source, amount: 1, seed: 42))
        #expect(high != grain(on: source, amount: 1, seed: 73))
        let lowError = meanSquareDifference(low, clean)
        let highError = meanSquareDifference(high, clean)
        #expect(lowError > 0)
        #expect(highError > lowError * 16)
        let highlight = patch(0.99, side: 64)
        #expect(meanSquareDifference(grain(on: highlight, amount: 1, seed: 42), pixels(highlight)) < highError)
    }

    @Test func grainKeepsHueOnSaturatedColors() throws {
        // A saturated orange in sRGB code values. Per-channel clipping used to push most
        // of the grain into the blue channel, which has the least headroom below 0.
        let side = 128
        let code: [CGFloat] = [0.9, 0.45, 0.1]
        let source = CIImage(color: CIColor(red: code[0], green: code[1], blue: code[2], alpha: 1,
                                            colorSpace: FilmEngine.sRGBColorSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let style = FilmSimulation(
            name: "Test", look: .photoEffect("CIPhotoEffectMono"),
            grain: FilmGrain(size: 4 / Float(side), amplitude: 0.12)
        )
        let settings = FilmRenderSettings(style: style, colorAmount: 0, grainAmount: 1, appliesLook: true)
        let grainy = pixels(FilmEngine.process(source, settings: settings, grainSeed: 7),
                            colorSpace: FilmEngine.sRGBColorSpace)

        var deviation: [Float] = [0, 0, 0]
        for index in stride(from: 0, to: grainy.count, by: 4) {
            for channel in 0..<3 { deviation[channel] += abs(grainy[index + channel] - Float(code[channel])) }
        }
        #expect(deviation[0] > 0, "grain should still show on saturated colors")
        // Without a chroma term each channel moves in proportion to its own value.
        for channel in 1..<3 {
            let expected = Float(code[channel] / code[0])
            let actual = deviation[channel] / deviation[0]
            #expect(abs(actual - expected) < 0.05 * expected + 0.01, "channel \(channel): \(actual) vs \(expected)")
        }
        // No channel is pushed out of range.
        #expect(grainy.allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 })
    }

    @Test func grainKernelLoads() {
        #expect(FilmEngine.grainKernel != nil)
    }

    @Test func grainHasNoCellGrid() throws {
        // 8 px cells on a flat mid-tone patch, read back as sRGB code values.
        let side = 512, cell = 8
        let source = patch(0.4, side: side, colorSpace: FilmEngine.sRGBColorSpace)
        let style = FilmSimulation(
            name: "Test", look: .photoEffect("CIPhotoEffectMono"),
            grain: FilmGrain(size: Float(cell) / Float(side), amplitude: 0.1)
        )
        let settings = FilmRenderSettings(style: style, colorAmount: 0, grainAmount: 1, appliesLook: true)
        let clean = pixels(source, colorSpace: FilmEngine.sRGBColorSpace)
        let grainy = pixels(FilmEngine.process(source, settings: settings, grainSeed: 0),
                            colorSpace: FilmEngine.sRGBColorSpace)

        // Seed 0 puts cell edges between pixels 7|8, so phases {7, 0} sit next to
        // lattice points and {3, 4} sit at cell centres.
        func variance(phases: Set<Int>) -> Float {
            var sum: Float = 0, count: Float = 0
            for y in 0..<side where phases.contains(y % cell) {
                for x in 0..<side where phases.contains(x % cell) {
                    let index = (y * side + x) * 4
                    let difference = grainy[index] - clean[index]
                    sum += difference * difference
                    count += 1
                }
            }
            return sum / count
        }
        let corners = variance(phases: [7, 0])
        let centres = variance(phases: [3, 4])
        // Interpolated value noise gives centres/corners ≈ 0.28 here.
        #expect(centres / corners > 0.8 && centres / corners < 1.25, "centres \(centres), corners \(corners)")

        // Overall strength keeps the calibration of the previous noise: RMS ≈ 0.303 × amplitude.
        let rms = sqrt(meanSquareDifference(
            stride(from: 0, to: grainy.count, by: 4).map { grainy[$0] },
            stride(from: 0, to: clean.count, by: 4).map { clean[$0] }
        ))
        #expect(abs(rms - 0.0303) < 0.003, "rms \(rms)")
    }

    @Test func customLUTCanBeRenamedReloadedAndDeleted() throws {
        let dir = try makeDirectory()
        let suite = UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let cube = try makeLUT(multiplier: 1)
        let engine = FilmEngine(documents: dir, preferences: preferences)
        try engine.saveCustomLUT(cube, name: "Portrait", encoding: .sRGB)
        #expect(throws: LUTError.duplicateName) {
            try engine.saveCustomLUT(cube, name: " portrait ", encoding: .linearSRGB)
        }
        let fileName = try #require(engine.availableSimulations.last?.fileName)
        try engine.renameCustomLUT(fileName: fileName, name: "Daylight")
        let reloaded = FilmEngine(documents: dir, preferences: preferences)
        #expect(reloaded.availableSimulations.last?.name == "Daylight")
        #expect(reloaded.availableSimulations.last?.customEncoding == .sRGB)
        try reloaded.deleteCustomLUT(fileName: fileName)
        #expect(reloaded.availableSimulations.allSatisfy { $0.fileName != fileName })
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path))
    }

    @Test func legacyDuplicateIndexLoadsTheCurrentFileOnlyOnce() throws {
        let dir = try makeDirectory()
        let suite = UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let cube = try makeLUT(multiplier: 1)
        let fileName = "Portrait.lutdata"
        try cube.data.write(to: dir.appendingPathComponent(fileName))
        preferences.set([
            ["name": "Portrait", "fileName": fileName, "dimension": 3],
            ["name": "Portrait", "fileName": fileName, "dimension": 2]
        ], forKey: "UserSavedLUTs")
        let styles = FilmEngine(documents: dir, preferences: preferences).availableSimulations
        let matching = styles.filter { $0.name == "Portrait" }
        #expect(matching.count == 1)
        #expect(matching.first?.customEncoding == .linearSRGB)
    }

    private func makeLUT(multiplier: Float) throws -> FilmLUT {
        var entries: [Float] = []
        for i in 0..<8 {
            entries += [Float(i & 1) * multiplier, Float((i >> 1) & 1) * multiplier, Float(i >> 2) * multiplier, 1]
        }
        return try FilmLUT(data: entries.withUnsafeBytes { Data($0) }, dimension: 2)
    }

    private static func linear(_ code: Float) -> Float {
        code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4)
    }

    /// The bundled film LUTs exactly as the engine loads them.
    private func builtInCubes() throws -> [String: (FilmLUT, LUTEncoding)] {
        let dir = try makeDirectory()
        let suite = UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        var cubes: [String: (FilmLUT, LUTEncoding)] = [:]
        for style in FilmEngine(documents: dir, preferences: preferences).availableSimulations {
            if case let .cube(lut, encoding) = style.look { cubes[style.name] = (lut, encoding) }
        }
        return cubes
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func patch(
        _ value: CGFloat, side: Int = 1, colorSpace: CGColorSpace = FilmEngine.workingColorSpace
    ) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: colorSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    private func bitmap(_ gray: [Float]) -> CIImage {
        let rgba: [Float] = gray.flatMap { [$0, $0, $0, 1] }
        return CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: rgba.count * MemoryLayout<Float>.size,
                       size: CGSize(width: gray.count, height: 1), format: .RGBAf, colorSpace: FilmEngine.workingColorSpace)
    }

    private func pixels(_ image: CIImage, colorSpace: CGColorSpace = FilmEngine.workingColorSpace) -> [Float] {
        let stride = Int(image.extent.width) * 4
        var data = [Float](repeating: .nan, count: Int(image.extent.height) * stride)
        data.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: stride * MemoryLayout<Float>.size,
                           bounds: image.extent, format: .RGBAf, colorSpace: colorSpace)
        }
        return data
    }

    private func grain(on image: CIImage, amount: Float, seed: UInt32) -> [Float] {
        let style = FilmSimulation(name: "Test", look: .photoEffect("CIPhotoEffectMono"), grain: .monochrome)
        let settings = FilmRenderSettings(style: style, colorAmount: 0, grainAmount: amount, appliesLook: true)
        return pixels(FilmEngine.process(image, settings: settings, grainSeed: seed))
    }

    private func meanSquareDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { sum, pair in
            let difference = pair.0 - pair.1
            return sum + difference * difference
        } / Float(lhs.count)
    }
}
