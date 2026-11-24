import Testing
@testable import betterCam

struct CaptureModeTests {
    private func labels(_ modes: [CaptureMode]) -> [String] {
        modes.map { $0.quality + ($0.resolution == .high48MP ? "48" : "") }
    }

    @Test func fullDeviceOffersSixModes() {
        let modes = CaptureMode.available(proRAWSupported: true, highResolutionSupported: true, zeroProcessing: false)
        #expect(labels(modes) == ["JPEG", "JPEG48", "DNG+J", "DNG", "ProRAW", "ProRAW48"])
    }

    @Test func zeroProcessingDropsProRAWAnd48MP() {
        let modes = CaptureMode.available(proRAWSupported: true, highResolutionSupported: true, zeroProcessing: true)
        #expect(labels(modes) == ["JPEG", "DNG+J", "DNG"])
    }

    @Test func unsupportedFeaturesAreSkipped() {
        let modes = CaptureMode.available(proRAWSupported: false, highResolutionSupported: false, zeroProcessing: false)
        #expect(labels(modes) == ["JPEG", "DNG+J", "DNG"])
    }

    @Test func dialWrapsBothWays() {
        let modes = CaptureMode.available(proRAWSupported: true, highResolutionSupported: true, zeroProcessing: false)
        let last = modes[modes.count - 1]
        #expect(CaptureMode.next(after: last, in: modes, direction: 1) == modes[0])
        #expect(CaptureMode.next(after: modes[0], in: modes, direction: -1) == last)
        #expect(CaptureMode.next(after: modes[1], in: modes, direction: 1) == modes[2])
        // A state the dial does not offer starts over from the first mode.
        let stray = CaptureMode(quality: "DNG", resolution: .high48MP)
        #expect(CaptureMode.next(after: stray, in: modes, direction: 1) == modes[0])
    }

    @Test func badges() {
        #expect(CaptureMode.badge(quality: "JPEG", resolution: .standard, zeroProcessing: false) == nil)
        #expect(CaptureMode.badge(quality: "JPEG", resolution: .high48MP, zeroProcessing: false) == .highResolution)
        #expect(CaptureMode.badge(quality: "ProRAW", resolution: .high48MP, zeroProcessing: false) == .highResolution)
        #expect(CaptureMode.badge(quality: "JPEG", resolution: .standard, zeroProcessing: true) == .zeroProcessing)
        #expect(CaptureMode.badge(quality: "DNG+J", resolution: .standard, zeroProcessing: true) == .zeroProcessing)
        #expect(CaptureMode.badge(quality: "DNG", resolution: .standard, zeroProcessing: true) == nil)
    }
}
