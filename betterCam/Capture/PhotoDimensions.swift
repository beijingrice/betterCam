import AVFoundation

extension CMVideoDimensions {
    var photoPixelCount: Int64 { Int64(width) * Int64(height) }
}

struct PhotoDimensions {
    let nativeRAW: CMVideoDimensions?
    let medium: CMVideoDimensions?
    let high: CMVideoDimensions?
    let largest: CMVideoDimensions?

    init(supported: [CMVideoDimensions] = []) {
        func closest(to target: Int64) -> CMVideoDimensions? {
            supported.min { abs($0.photoPixelCount - target) < abs($1.photoPixelCount - target) }
        }

        nativeRAW = closest(to: 12_000_000)
        medium = closest(to: 24_000_000).flatMap {
            (18_000_000..<40_000_000).contains($0.photoPixelCount) ? $0 : nil
        }
        high = closest(to: 48_000_000).flatMap { $0.photoPixelCount >= 40_000_000 ? $0 : nil }
        largest = supported.max { $0.photoPixelCount < $1.photoPixelCount }
    }
}
