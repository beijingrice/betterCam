import CoreVideo
import Foundation

/// Manual-exposure meter, modelled on the multi-segment (evaluative) metering of
/// mirrorless cameras. It reads the frames the viewfinder shows, the same rendering the
/// JPEG gets, instead of `exposureTargetOffset`: that value measures against Apple's own
/// auto-exposure target, which lifts dim and contrasty scenes far above middle gray.
///
/// 1. The frame is split into 12×9 zones; each zone's brightness is its mean linear
///    luminance, expressed in stops from middle gray.
/// 2. Zones get a mild centre bias, not a centre-weighted hot spot.
/// 3. The scene's typical level is the weighted median zone.
/// 4. Zones far from it (lamps, sky, a black foreground) count less and are clamped to
///    ±2 stops of the median, so one extreme region cannot drag the reading.
/// 5. The reading is the weighted mean of the zones in stops, i.e. a log average, which
///    is how brightness is perceived.
nonisolated enum ExposureMeter {
    /// Middle gray in linear light; sRGB code value ≈ 0.46 (118/255).
    static let middleGray: Float = 0.18
    static let range: ClosedRange<Float> = -6...6
    static let zoneColumns = 12, zoneRows = 9
    /// Samples per zone along each axis.
    static let zoneSamples = 8
    /// How far a zone may sit from the median before it is clamped, in stops.
    static let outlierLimit: Float = 2
    /// Zones more than this far from the median count at `outlierWeight`.
    static let outlierThreshold: Float = 1.5
    static let outlierWeight: Float = 0.5

    /// Base weight of a zone centred at a normalised position (0...1 on both axes):
    /// 1.0 at the centre, falling to about 0.6 in the corners.
    static func weight(x: Float, y: Float) -> Float {
        let dx = (x - 0.5) * 2, dy = (y - 0.5) * 2
        return 0.6 + 0.4 * exp(-(dx * dx + dy * dy) / 0.5)
    }

    /// Stops between the metered scene and middle gray. `luminance` returns linear
    /// luminance (0...1) at a normalised position.
    static func offset(luminance: (Float, Float) -> Float) -> Float {
        var zones: [(stops: Float, weight: Float)] = []
        zones.reserveCapacity(zoneColumns * zoneRows)
        let columns = zoneColumns * zoneSamples, rows = zoneRows * zoneSamples
        let floor = middleGray * exp2(range.lowerBound)
        for zoneRow in 0..<zoneRows {
            for zoneColumn in 0..<zoneColumns {
                var sum: Float = 0
                for sy in 0..<zoneSamples {
                    let y = (Float(zoneRow * zoneSamples + sy) + 0.5) / Float(rows)
                    for sx in 0..<zoneSamples {
                        let x = (Float(zoneColumn * zoneSamples + sx) + 0.5) / Float(columns)
                        sum += luminance(x, y)
                    }
                }
                let mean = sum / Float(zoneSamples * zoneSamples)
                let centre = (x: (Float(zoneColumn) + 0.5) / Float(zoneColumns),
                              y: (Float(zoneRow) + 0.5) / Float(zoneRows))
                zones.append((log2(max(mean, floor) / middleGray), weight(x: centre.x, y: centre.y)))
            }
        }

        let median = weightedMedian(zones)
        var sum: Float = 0, total: Float = 0
        for zone in zones {
            let distance = zone.stops - median
            let weight = abs(distance) > outlierThreshold ? zone.weight * outlierWeight : zone.weight
            let stops = median + min(max(distance, -outlierLimit), outlierLimit)
            sum += stops * weight
            total += weight
        }
        return min(max(sum / total, range.lowerBound), range.upperBound)
    }

    static func weightedMedian(_ zones: [(stops: Float, weight: Float)]) -> Float {
        let sorted = zones.sorted { $0.stops < $1.stops }
        let half = sorted.reduce(0) { $0 + $1.weight } / 2
        var running: Float = 0
        for zone in sorted {
            running += zone.weight
            if running >= half { return zone.stops }
        }
        return sorted.last?.stops ?? 0
    }

    /// Meter a 32BGRA video frame.
    static func offset(pixelBuffer: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        return offset(
            bytes: base.assumingMemoryBound(to: UInt8.self),
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer), order: .bgra
        )
    }

    enum ChannelOrder { case bgra, rgba }

    /// Meter an 8-bit, 4-channel bitmap of sRGB-style encoded values.
    static func offset(
        bytes: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int, order: ChannelOrder
    ) -> Float? {
        guard width > 0, height > 0 else { return nil }
        let (red, blue) = order == .bgra ? (2, 0) : (0, 2)
        return offset { x, y in
            let px = min(width - 1, Int(x * Float(width)))
            let py = min(height - 1, Int(y * Float(height)))
            let pixel = bytes + py * rowBytes + px * 4
            return 0.2126 * linearTable[Int(pixel[red])]
                + 0.7152 * linearTable[Int(pixel[1])]
                + 0.0722 * linearTable[Int(pixel[blue])]
        }
    }

    static func decodeSRGB(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static let linearTable: [Float] = (0..<256).map { decodeSRGB(Float($0) / 255) }
}
