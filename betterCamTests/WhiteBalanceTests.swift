import AVFoundation
import Testing
@testable import betterCam

struct WhiteBalanceTests {
    @Test func dialOrderIsAutoPresetsThenCustom() {
        #expect(WhiteBalance.modeOptions == ["AWB", "TUNG", "FLUOR", "DAY", "CLOUD", "SHADE", "CUSTOM"])
        #expect(nextOption(in: WhiteBalance.modeOptions, current: "CUSTOM", direction: 1) == "AWB")
        #expect(nextOption(in: WhiteBalance.modeOptions, current: "AWB", direction: -1) == "CUSTOM")
    }

    @Test func modeKelvin() {
        #expect(WhiteBalance.kelvin(for: "AWB", customKelvin: 4300) == nil)
        #expect(WhiteBalance.kelvin(for: "DAY", customKelvin: 4300) == 5500)
        #expect(WhiteBalance.kelvin(for: "TUNG", customKelvin: 4300) == 3200)
        #expect(WhiteBalance.kelvin(for: "CUSTOM", customKelvin: 4300) == 4300)
        #expect(WhiteBalance.kelvin(for: "CUSTOM", customKelvin: 99_000) == 10_000)
        #expect(WhiteBalance.kelvin(for: "???", customKelvin: 4300) == nil)
    }

    @Test func kelvinStepsBy100AndStopsAtTheEnds() {
        #expect(WhiteBalance.steppedKelvin(5500, direction: 1) == 5600)
        #expect(WhiteBalance.steppedKelvin(5500, direction: -1) == 5400)
        #expect(WhiteBalance.steppedKelvin(10_000, direction: 1) == 10_000)
        #expect(WhiteBalance.steppedKelvin(2500, direction: -1) == 2500)
        // An off-grid value snaps back onto the 100 K grid.
        #expect(WhiteBalance.steppedKelvin(5530, direction: 1) == 5600)
    }

    @Test func kelvinLabel() {
        #expect(WhiteBalance.kelvinLabel(5500) == "5500K")
        #expect(WhiteBalance.kelvinLabel(12_000) == "10000K")
    }

    @Test func gainsAreNormalizedAndLimited() {
        let warm = WhiteBalance.clampedGains(
            AVCaptureDevice.WhiteBalanceGains(redGain: 0.5, greenGain: 1, blueGain: 3), maxGain: 4
        )
        #expect(warm.redGain == 1)
        #expect(warm.greenGain == 2)
        #expect(warm.blueGain == 4) // 6 clips at the device limit
        let invalid = WhiteBalance.clampedGains(
            AVCaptureDevice.WhiteBalanceGains(redGain: .nan, greenGain: 1, blueGain: 1), maxGain: 4
        )
        #expect(invalid.redGain == 1 && invalid.greenGain == 1 && invalid.blueGain == 1)
    }

    @Test func centreButtonFlowOnCustom() {
        let camera = Camera()
        camera.activeIndex = UIWidgets.WBMode.rawValue
        camera.parameterManager.WBMode = WhiteBalance.custom

        camera.toggleAdjustmentMode() // enter the list
        #expect(camera.isAdjustingValue && !camera.isEditingCustomKelvin)
        camera.toggleAdjustmentMode() // CUSTOM → edit the temperature
        #expect(camera.isEditingCustomKelvin)

        let start = camera.parameterManager.customKelvin
        adjustValue(for: camera, direction: 1)
        #expect(camera.parameterManager.customKelvin == WhiteBalance.steppedKelvin(start, direction: 1))
        #expect(camera.parameterManager.WBMode == WhiteBalance.custom)

        camera.toggleAdjustmentMode() // confirm, back to the list
        #expect(camera.isAdjustingValue && !camera.isEditingCustomKelvin)
        adjustValue(for: camera, direction: 1)
        #expect(camera.parameterManager.WBMode == WhiteBalance.auto)
        camera.toggleAdjustmentMode() // leave
        #expect(!camera.isAdjustingValue)
    }

    @Test func leavingTheControlEndsKelvinEditing() {
        let camera = Camera()
        camera.activeIndex = UIWidgets.WBMode.rawValue
        camera.parameterManager.WBMode = WhiteBalance.custom
        camera.toggleAdjustmentMode()
        camera.toggleAdjustmentMode()
        #expect(camera.isEditingCustomKelvin)
        camera.activeIndex = UIWidgets.SS.rawValue
        #expect(!camera.isEditingCustomKelvin)
    }
}
