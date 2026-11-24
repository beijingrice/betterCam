import AVFoundation

/// White balance choices on the top-bar dial: AWB, a few fixed presets, and a CUSTOM
/// colour temperature the user sets in 100 K steps.
enum WhiteBalance {
    static let auto = "AWB"
    static let custom = "CUSTOM"

    /// Ordered warm to cool, so turning the dial moves steadily through the presets.
    static let presets: [(label: String, kelvin: Int)] = [
        ("TUNG", 3200),
        ("FLUOR", 4000),
        ("DAY", 5500),
        ("CLOUD", 6500),
        ("SHADE", 7500),
    ]

    static let modeOptions: [String] = [auto] + presets.map(\.label) + [custom]

    static let kelvinRange: ClosedRange<Int> = 2500...10000
    static let kelvinStep = 100
    static let defaultCustomKelvin = 5500

    /// The colour temperature a mode locks to, or nil for AWB (and anything unknown).
    static func kelvin(for mode: String, customKelvin: Int) -> Int? {
        if mode == custom { return clampedKelvin(customKelvin) }
        return presets.first(where: { $0.label == mode })?.kelvin
    }

    /// One dial step from `kelvin`, stopping at the ends of the range instead of wrapping.
    static func steppedKelvin(_ kelvin: Int, direction: Int) -> Int {
        let snapped = (clampedKelvin(kelvin) + kelvinStep / 2) / kelvinStep * kelvinStep
        return clampedKelvin(snapped + direction.signum() * kelvinStep)
    }

    static func clampedKelvin(_ kelvin: Int) -> Int {
        min(max(kelvin, kelvinRange.lowerBound), kelvinRange.upperBound)
    }

    static func kelvinLabel(_ kelvin: Int) -> String {
        "\(clampedKelvin(kelvin))K"
    }

    /// Scales gains so the smallest is 1 (keeping their ratio, which is the colour), then
    /// limits each to what the device accepts. Locking with gains outside 1...maxGain
    /// raises an exception. Extreme temperatures can need more than maxGain; those clip,
    /// so the colour stops changing past that point.
    static func clampedGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains, maxGain: Float
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let values = [gains.redGain, gains.greenGain, gains.blueGain]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }), maxGain >= 1 else {
            return AVCaptureDevice.WhiteBalanceGains(redGain: 1, greenGain: 1, blueGain: 1)
        }
        let scale = 1 / values.min()!
        func limit(_ value: Float) -> Float { min(max(value * scale, 1), maxGain) }
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: limit(gains.redGain), greenGain: limit(gains.greenGain), blueGain: limit(gains.blueGain)
        )
    }
}
