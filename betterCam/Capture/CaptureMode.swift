import Foundation

/// One position on the format dial: a file format together with its resolution.
/// The dial only offers combinations the capture pipeline supports, so 48MP RAW,
/// 48MP with ZERO PROCESSING or ProRAW with ZERO PROCESSING cannot be selected.
nonisolated struct CaptureMode: Equatable {
    let quality: String
    let resolution: PhotoResolutionMode

    /// Small mark drawn at the top right of the format in the top bar.
    enum Badge: Equatable {
        case highResolution   // "48"
        case zeroProcessing   // yellow "Z"
    }

    static func available(
        proRAWSupported: Bool, highResolutionSupported: Bool, zeroProcessing: Bool
    ) -> [CaptureMode] {
        let highResolution = highResolutionSupported && !zeroProcessing
        var modes = [CaptureMode(quality: "JPEG", resolution: .standard)]
        if highResolution { modes.append(CaptureMode(quality: "JPEG", resolution: .high48MP)) }
        modes.append(CaptureMode(quality: "DNG+J", resolution: .standard))
        modes.append(CaptureMode(quality: "DNG", resolution: .standard))
        if proRAWSupported && !zeroProcessing {
            modes.append(CaptureMode(quality: "ProRAW", resolution: .standard))
            if highResolution { modes.append(CaptureMode(quality: "ProRAW", resolution: .high48MP)) }
        }
        return modes
    }

    /// The neighbouring mode, wrapping around. A current state that is not on the dial
    /// (e.g. restored from an older version) steps from the first mode.
    static func next(after current: CaptureMode, in modes: [CaptureMode], direction: Int) -> CaptureMode {
        guard !modes.isEmpty else { return current }
        guard let index = modes.firstIndex(of: current) else { return modes[0] }
        let count = modes.count
        return modes[((index + direction) % count + count) % count]
    }

    /// 48MP is marked as "48". ZERO PROCESSING is marked only where it changes the
    /// result: plain DNG has no JPEG, so it looks the same either way.
    static func badge(
        quality: String, resolution: PhotoResolutionMode, zeroProcessing: Bool
    ) -> Badge? {
        if resolution == .high48MP { return .highResolution }
        if zeroProcessing && quality != "DNG" { return .zeroProcessing }
        return nil
    }
}
