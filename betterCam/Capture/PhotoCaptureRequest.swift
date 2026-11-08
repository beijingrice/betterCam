import AVFoundation

struct PhotoCaptureRequest {
    let imageQuality: String
    let resolutionMode: PhotoResolutionMode
    let isFrontCamera: Bool
    let usePureRawEngine: Bool
    let styleName: String
    let lutIntensity: Float
    let grainIntensity: Float
    let usesManualExposure: Bool
    let manualExposureDuration: CMTime?
    let manualISO: Float?
}
