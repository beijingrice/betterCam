import CoreVideo
import Testing
@testable import betterCam

struct ExposureMeterTests {
    private func encode(_ linear: Float) -> Float {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    @Test func uniformFieldReadsItsOwnLevel() {
        #expect(abs(ExposureMeter.offset { _, _ in 0.18 }) < 0.01)
        #expect(abs(ExposureMeter.offset { _, _ in 0.09 } + 1) < 0.01)
        #expect(abs(ExposureMeter.offset { _, _ in 0.72 } - 2) < 0.01)
        #expect(ExposureMeter.offset { _, _ in 0 } == ExposureMeter.range.lowerBound)
    }

    @Test func smallLightSourceBarelyMovesTheReading() {
        // A clipped lamp covering about 4% of a mid-gray frame.
        let reading = ExposureMeter.offset { x, y in hypot(x - 0.7, y - 0.3) < 0.11 ? 1 : 0.18 }
        #expect(reading > -0.05 && reading < 0.3, "\(reading)")
    }

    @Test func blackForegroundDoesNotDemandOverexposure() {
        // Bottom 40% almost black. A light-averaging meter would ask for about +1.4 EV;
        // the clamped multi-zone reading stays well under that.
        let reading = ExposureMeter.offset { _, y in y > 0.6 ? 0.0015 : 0.18 }
        #expect(reading > -0.8 && reading < 0, "\(reading)")
    }

    @Test func brightSkyIsHeldBack() {
        // Top third four stops over a mid-gray landscape.
        let reading = ExposureMeter.offset { _, y in y < 0.33 ? min(1, 0.18 * 16) : 0.18 }
        #expect(reading > 0 && reading < 0.6, "\(reading)")
    }

    @Test func readsBGRAFrames() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 96, 72, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let code = UInt8((encode(0.18) * 255).rounded())
        for row in 0..<72 {
            let line = base + row * CVPixelBufferGetBytesPerRow(frame)
            for column in 0..<96 {
                line[column * 4] = code; line[column * 4 + 1] = code; line[column * 4 + 2] = code; line[column * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let reading = try #require(ExposureMeter.offset(pixelBuffer: frame))
        #expect(abs(reading) < 0.03)
    }

    @Test func previewGrainShowsOnlyAroundAdjustment() {
        typealias Frames = CameraPreviewFrames
        #expect(Frames.grainVisibility(adjusting: false, releasedAt: nil, now: 10) == 0)
        #expect(Frames.grainVisibility(adjusting: true, releasedAt: nil, now: 10) == 1)
        #expect(Frames.grainVisibility(adjusting: false, releasedAt: 10, now: 10 + Frames.grainHold) == 1)
        let midFade = Frames.grainVisibility(adjusting: false, releasedAt: 10,
                                             now: 10 + Frames.grainHold + Frames.grainFade / 2)
        #expect(abs(midFade - 0.5) < 0.01)
        #expect(Frames.grainVisibility(adjusting: false, releasedAt: 10, now: 20) == 0)
    }

    @Test func channelOrderIsRespected() {
        // A saturated red: reading the same bytes as BGRA treats the red byte as blue.
        let width = 24, height = 18
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgba[index] = 255; rgba[index + 1] = 40; rgba[index + 2] = 0; rgba[index + 3] = 255
        }
        let asRGBA = rgba.withUnsafeBufferPointer {
            ExposureMeter.offset(bytes: $0.baseAddress!, width: width, height: height, rowBytes: width * 4, order: .rgba)
        }!
        let asBGRA = rgba.withUnsafeBufferPointer {
            ExposureMeter.offset(bytes: $0.baseAddress!, width: width, height: height, rowBytes: width * 4, order: .bgra)
        }!
        // Red carries 0.2126 of luminance, blue 0.0722: reading red as blue drops about 1.4 stops.
        #expect(asRGBA - asBGRA > 1.2, "\(asRGBA) vs \(asBGRA)")
    }
}
