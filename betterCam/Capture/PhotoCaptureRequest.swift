import AVFoundation

struct PhotoCaptureRequest {
    let imageQuality: String
    let resolutionMode: PhotoResolutionMode
    let isFrontCamera: Bool
    let usePureRawEngine: Bool
    let look: FilmRenderSettings
    let usesManualExposure: Bool
    let manualExposureDuration: CMTime?
    let manualISO: Float?
}
