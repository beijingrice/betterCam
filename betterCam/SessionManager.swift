//
//  SessionManager.swift
//  betterCam
//
//  Created by Rice on 2026/4/4.
//

import Foundation
import AVFoundation
import Combine
import CoreImage
import Photos
internal import UniformTypeIdentifiers

private struct CaptureContext {
    let request: PhotoCaptureRequest
    var pendingProcessingJobs: Int = 0
    var captureFinished: Bool = false
    // Held until the capture is complete so RAW+JPEG land in the library as one asset.
    var photoData: Data?
    var rawData: Data?
    /// Metered brightness of the viewfinder frame when the shutter fired, in stops.
    var previewStops: Float?
}

class SessionManager: NSObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.workingColorSpace: FilmEngine.workingColorSpace])
    let previewFrames = CameraPreviewFrames()
    
    weak var delegate: Camera?
    
    
    // Full-resolution Core Image rendering can materialize several large buffers.
    // Keep still-photo development serial to avoid multiple 48 MP renders competing for memory.
    private let processingQueue = DispatchQueue(label: "com.bettercam.processingQueue")
    private let sessionQueue = DispatchQueue(label: "com.bettercam.sessionQueue")
    private let captureContextLock = NSLock()
    private var captureContexts: [Int64: CaptureContext] = [:]
    private var photoDimensions = PhotoDimensions()
    // Manual-exposure meter state, shared between the main and video queues.
    nonisolated private let meterLock = NSLock()
    nonisolated(unsafe) private var meterIsActive = false
    nonisolated(unsafe) private var hasMeterReading = false
    nonisolated(unsafe) private var smoothedOffset: Float = 0.0
    nonisolated(unsafe) private var lastMeterSampleTimestamp: TimeInterval = 0
    nonisolated(unsafe) private var lastUpdateTimestamp: TimeInterval = 0
    nonisolated(unsafe) private var lastMeterDisplayValue: Float?
    /// Latest viewfinder reading, kept even when the meter is hidden: a ZERO PROCESSING
    /// capture develops its RAW to this brightness.
    nonisolated(unsafe) private var latestFrameStops: Float?
    nonisolated(unsafe) private var latestFrameTimestamp: TimeInterval = 0
    nonisolated private let meterSampleInterval: TimeInterval = 1.0 / 15
    nonisolated private let meterUpdateInterval: TimeInterval = 0.12
    nonisolated private let meterSmoothing: Float = 0.6
    nonisolated private let meterZeroDeadband: Float = 0.12
    nonisolated private let meterDisplayDeadband: Float = 0.1
    private var activeDeviceUniqueID: String?
    
    func initSession(with lens: Lens) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.session.inputs.forEach { self.session.removeInput($0) }
            
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
                self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                self.videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            
            do {
                let input = try AVCaptureDeviceInput(device: lens.device)
                if self.session.canAddInput(input) { self.session.addInput(input) }
            } catch { print("Init input failed!") }

            self.configurePhotoOutput(for: lens.device)
            
            self.session.commitConfiguration()
            self.activeDeviceUniqueID = lens.device.uniqueID
            self.delegate?.refreshLensCapabilities() 
            self.session.startRunning()
            self.applyPreparedPhotoSettings()
            self.warmUpStillProcessing()
            self.setupLightMeter(for: lens.device)
            
            
        }
    }
    
    func switchInput(to device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
            } catch {
                print("Switch input failed!")
            }
            self.configurePhotoOutput(for: device)
            self.session.commitConfiguration()
            self.applyPreparedPhotoSettings()
            self.activeDeviceUniqueID = device.uniqueID
            self.delegate?.refreshLensCapabilities()
            self.setupLightMeter(for: device)
        }
    }
    
    func isUsingDevice(_ device: AVCaptureDevice) -> Bool {
        return activeDeviceUniqueID == device.uniqueID
    }

    private func configurePhotoOutput(for device: AVCaptureDevice) {
        photoOutput.maxPhotoQualityPrioritization = .quality

        let supportsAppleProRAW = photoOutput.isAppleProRAWSupported
        if supportsAppleProRAW {
            photoOutput.isAppleProRAWEnabled = true
        } else if photoOutput.isAppleProRAWEnabled {
            photoOutput.isAppleProRAWEnabled = false
        }

        photoDimensions = PhotoDimensions(supported: device.activeFormat.supportedMaxPhotoDimensions)
        if let largest = photoDimensions.largest {
            photoOutput.maxPhotoDimensions = largest
        }

        let supports24MP = photoDimensions.medium != nil
        let supports48MP = photoDimensions.high != nil
        DispatchQueue.main.async { [weak self] in
            guard let camera = self?.delegate else { return }
            camera.is24MPSupported = supports24MP
            camera.is48MPSupported = supports48MP
            camera.isProRAWSupported = supportsAppleProRAW

            if !supportsAppleProRAW && camera.parameterManager.imageQuality == "ProRAW" {
                camera.parameterManager.imageQuality = "JPEG"
            }

            if !supports48MP && camera.parameterManager.photoResolutionMode == .high48MP {
                camera.parameterManager.photoResolutionMode = .standard
            }
        }
    }

    // The processed photo is only an intermediate: it is decoded, styled and re-encoded
    // as JPEG. Ask for near-lossless HEVC so the second encode is the only real loss.
    private static let intermediateFormat: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 1.0]
    ]
    private static let jpegQuality = 0.95

    private func makePhotoSettings(for request: PhotoCaptureRequest) -> AVCapturePhotoSettings? {
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let bayerRAW = rawTypes.first {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }
        let appleProRAW = rawTypes.first {
            AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
        }

        let settings: AVCapturePhotoSettings
        if request.imageQuality == "ProRAW" {
            guard let appleProRAW else { return nil }
            settings = AVCapturePhotoSettings(rawPixelFormatType: appleProRAW)
        } else if request.usePureRawEngine && request.imageQuality != "DNG" {
            guard let bayerRAW else { return nil }
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayerRAW)
        } else if request.imageQuality == "DNG+J" {
            guard let bayerRAW else { return nil }
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: bayerRAW,
                processedFormat: Self.intermediateFormat
            )
        } else if request.imageQuality == "DNG" {
            guard let bayerRAW else { return nil }
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayerRAW)
        } else {
            settings = AVCapturePhotoSettings(format: Self.intermediateFormat)
        }

        let canRequest48MP = request.resolutionMode == .high48MP &&
            !request.usePureRawEngine &&
            (request.imageQuality == "JPEG" || request.imageQuality == "ProRAW")

        if canRequest48MP, let dimensions = photoDimensions.high {
            settings.maxPhotoDimensions = dimensions
        } else if request.imageQuality == "ProRAW" ||
                    request.imageQuality == "DNG" ||
                    request.imageQuality == "DNG+J" ||
                    request.usePureRawEngine,
                  let dimensions = photoDimensions.nativeRAW {
            // Bayer RAW and standard ProRAW use the sensor's native binned RAW size.
            settings.maxPhotoDimensions = dimensions
        } else if let dimensions = photoDimensions.medium ?? photoDimensions.nativeRAW {
            settings.maxPhotoDimensions = dimensions
        }

        if request.usesManualExposure ||
            AVCapturePhotoOutput.isBayerRAWPixelFormat(settings.rawPhotoPixelFormatType) {
            // Apple requires .speed to honor custom exposure duration and ISO.
            settings.photoQualityPrioritization = .speed
        } else {
            // Auto exposure with an ISP-processed photo (JPEG at any resolution, ProRAW):
            // allow multi-frame fusion. Bursts are already bounded by the in-flight limit.
            settings.photoQualityPrioritization = .quality
        }

        return settings
    }

    // Allocating capture buffers for a new kind of request stalls the session, which
    // showed up as a hitch on the first shot (worst for Bayer RAW). Preparing the current
    // configuration ahead of time moves that cost off the shutter. Prepared settings are
    // dropped whenever the session is reconfigured, so they are re-applied after a lens
    // switch as well.
    private var preparedRequest: PhotoCaptureRequest?

    func preparePhotoPipeline(
        resolutionMode: PhotoResolutionMode,
        imageQuality: String,
        usePureRawEngine: Bool,
        usesManualExposure: Bool
    ) {
        let request = PhotoCaptureRequest(
            imageQuality: imageQuality,
            resolutionMode: resolutionMode,
            isFrontCamera: false,
            usePureRawEngine: usePureRawEngine,
            look: .standard,
            usesManualExposure: usesManualExposure,
            manualExposureDuration: nil,
            manualISO: nil
        )
        sessionQueue.async { [weak self] in
            self?.preparedRequest = request
            self?.applyPreparedPhotoSettings()
        }
    }

    // Session queue only.
    private func applyPreparedPhotoSettings() {
        guard let request = preparedRequest, photoOutput.connection(with: .video) != nil,
              let settings = makePhotoSettings(for: request) else {
            photoOutput.setPreparedPhotoSettingsArray([], completionHandler: nil)
            return
        }
        photoOutput.setPreparedPhotoSettingsArray([settings]) { prepared, error in
            if let error {
                print("❌ Photo pipeline preparation failed: \(error)")
            } else {
                print("✅ Photo pipeline prepared (\(request.imageQuality), pure RAW \(request.usePureRawEngine)): \(prepared)")
            }
        }
    }

    // Compile the still-photo Core Image graph (tone map, look, grain, P3 output) and the
    // JPEG encoder once, off the shutter path, so the first capture does not pay for it.
    private func warmUpStillProcessing() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let sample = CIImage(color: CIColor(red: 0.4, green: 0.35, blue: 0.3))
                    .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
                let looks = FilmEngine.shared.availableSimulations.filter { $0.look != nil }
                let cube = looks.first { if case .cube = $0.look { true } else { false } }
                let effect = looks.first { if case .photoEffect = $0.look { true } else { false } }
                for style in [cube, effect].compactMap({ $0 }) {
                    let look = FilmRenderSettings(style: style, colorAmount: 0.5, grainAmount: 1, appliesLook: true)
                    _ = self.renderFilteredJPEG(from: sample, with: [:], look: look, captureID: 0, pixelsAreUpright: false)
                }
            }
        }
    }
    
    func start() {
        sessionQueue.async {
            self.session.startRunning()
        }
    }
    
    func stop() {
        sessionQueue.async {
            self.session.stopRunning()
        }
    }
    
    func updateExposure() {
        guard let camera = delegate else { return }
        
        let currentSS = camera.parameterManager.SS
        let currentISO = camera.parameterManager.ISO
        let currentEV = camera.parameterManager.EV
        guard let lens = camera.lensManager.currentLens else { return }
        let device = lens.device
        let meterActive = currentSS != ExposureParameter.auto && currentISO != ExposureParameter.auto
        meterLock.lock()
        if meterActive != meterIsActive {
            meterIsActive = meterActive
            hasMeterReading = false
            lastMeterDisplayValue = nil
        }
        meterLock.unlock()
        
        sessionQueue.async { [weak self] in
            do {
                try device.lockForConfiguration()
                let isManual = (currentSS != ExposureParameter.auto && currentISO != ExposureParameter.auto)
                
                if isManual {
                    let duration = ExposureParameter.shutterDuration(currentSS) ?? device.exposureDuration
                    let iso = ExposureParameter.isoValue(currentISO) ?? device.iso
                    if device.isExposureModeSupported(.custom) {
                        self?.applyManualExposure(duration: duration, iso: iso, to: device)
                    }
                } else {
                    if let evValue = Float(currentEV), evValue.isFinite {
                        device.setExposureTargetBias(min(max(evValue, device.minExposureTargetBias), device.maxExposureTargetBias), completionHandler: nil)
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch { print("曝光控制失败: \(error)") }
        }
    }
    
    // Caller holds the configuration lock. The active format may have changed since the dial was set.
    private func applyManualExposure(duration: CMTime, iso: Float, to device: AVCaptureDevice,
                                     completion: ((CMTime) -> Void)? = nil) {
        let format = device.activeFormat
        let boundedDuration = CMTimeMinimum(CMTimeMaximum(duration, format.minExposureDuration), format.maxExposureDuration)
        let boundedISO = min(max(iso.isFinite ? iso : device.iso, format.minISO), format.maxISO)
        device.setExposureTargetBias(0, completionHandler: nil)
        device.setExposureModeCustom(duration: boundedDuration, iso: boundedISO, completionHandler: completion)
    }

    private func setupLightMeter(for device: AVCaptureDevice) {
        meterLock.lock()
        smoothedOffset = 0.0
        lastMeterDisplayValue = nil
        lastUpdateTimestamp = 0
        hasMeterReading = false
        meterLock.unlock()
    }

    // Runs on the video queue with every frame while manual exposure is on.
    nonisolated private func meter(_ pixelBuffer: CVPixelBuffer) {
        meterLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let due = now - lastMeterSampleTimestamp >= meterSampleInterval
        if due { lastMeterSampleTimestamp = now }
        meterLock.unlock()
        guard due, let rawOffset = ExposureMeter.offset(pixelBuffer: pixelBuffer) else { return }

        meterLock.lock()
        latestFrameStops = rawOffset
        latestFrameTimestamp = now
        guard meterIsActive else { meterLock.unlock(); return }
        // Start from the first reading instead of easing in from 0.
        smoothedOffset = hasMeterReading
            ? smoothedOffset * meterSmoothing + rawOffset * (1.0 - meterSmoothing)
            : rawOffset
        hasMeterReading = true
        var displayValue = smoothedOffset
        guard now - lastUpdateTimestamp > meterUpdateInterval else { meterLock.unlock(); return }
        if abs(displayValue) < meterZeroDeadband { displayValue = 0.0 }
        displayValue = (displayValue * 10).rounded() / 10
        if let lastValue = lastMeterDisplayValue, abs(displayValue - lastValue) < meterDisplayDeadband {
            meterLock.unlock()
            return
        }
        lastUpdateTimestamp = now
        lastMeterDisplayValue = displayValue
        meterLock.unlock()

        let formattedOffset = String(format: "%+.1f", displayValue)
        DispatchQueue.main.async { [weak self] in
            // Check the dials as they are now, not the meter flag: that only flips after the
            // exposure update's debounce, so a reading queued just before switching to
            // auto used to overwrite the 0.0 compensation and stick.
            guard let self, let camera = self.delegate, camera.isManualExposureActive,
                  camera.parameterManager.EV != formattedOffset else { return }
            camera.parameterManager.EV = formattedOffset
        }
    }

    
    func HDRswitch(_ mode: Bool, device: AVCaptureDevice) {
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.activeFormat.isVideoHDRSupported {
                    if device.automaticallyAdjustsVideoHDREnabled { device.automaticallyAdjustsVideoHDREnabled = false }
                    device.isVideoHDREnabled = mode
                }
                device.unlockForConfiguration()
            } catch { print("HDR setting failed") }
        }
    }
        
    // Session queue only. Bumped on every request so a custom-gains lock that completes
    // after a newer request can tell it is stale.
    private var whiteBalanceGeneration = 0
    private var requestedWhiteBalanceKelvin: Int?
    /// The latest request already reasserted by a stale lock, so a fast turn's many stale
    /// completions reapply it once instead of once each.
    private var reassertedWhiteBalanceGeneration = 0

    /// Locks white balance to `kelvin` (tint 0), or returns to AWB when nil. Devices that
    /// cannot lock custom gains (some front cameras) stay on AWB.
    func updateWhiteBalance(kelvin: Int?, device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.whiteBalanceGeneration += 1
            self.requestedWhiteBalanceKelvin = kelvin
            self.applyRequestedWhiteBalance(to: device)
        }
    }

    // Session queue only.
    private func applyRequestedWhiteBalance(to device: AVCaptureDevice) {
        let generation = whiteBalanceGeneration
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let kelvin = requestedWhiteBalanceKelvin, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let target = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(kelvin), tint: 0
                )
                let gains = WhiteBalance.clampedGains(
                    device.deviceWhiteBalanceGains(for: target), maxGain: device.maxWhiteBalanceGain
                )
                // The gains land a frame or more later. If the dial moved on meanwhile
                // (back to AWB, say), this late lock would override it, so reassert
                // whatever is current.
                device.setWhiteBalanceModeLocked(with: gains) { [weak self] _ in
                    self?.sessionQueue.async {
                        guard let self, self.whiteBalanceGeneration != generation,
                              self.reassertedWhiteBalanceGeneration != self.whiteBalanceGeneration else { return }
                        self.reassertedWhiteBalanceGeneration = self.whiteBalanceGeneration
                        self.applyRequestedWhiteBalance(to: device)
                    }
                }
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                // Setting a mode the device already reports does nothing, and after a
                // custom-gains lock it may still report AWB. Pass through .locked so AWB
                // always restarts.
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch { print("白平衡设置失败: \(error)") }
        #if DEBUG
        // Gains land a frame or more after the call, and AWB needs a moment to settle,
        // so read once they should have.
        sessionQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.whiteBalanceGeneration == generation else { return }
            self.logWhiteBalance(device, label: "after 1.5s", generation: generation)
        }
        #endif
    }

    #if DEBUG
    /// What the device is really doing, in the same terms as the dial.
    private func logWhiteBalance(_ device: AVCaptureDevice, label: String, generation: Int) {
        let mode: String
        switch device.whiteBalanceMode {
        case .locked: mode = "locked"
        case .autoWhiteBalance: mode = "auto(once)"
        case .continuousAutoWhiteBalance: mode = "AWB"
        @unknown default: mode = "unknown"
        }
        let gains = device.deviceWhiteBalanceGains
        let normalized = WhiteBalance.clampedGains(gains, maxGain: device.maxWhiteBalanceGain)
        let tt = device.temperatureAndTintValues(for: normalized)
        let requested = requestedWhiteBalanceKelvin.map { "\($0)K" } ?? "AWB"
        print(String(
            format: "[WB #%d %@] requested %@ | device %@ | gains R%.2f G%.2f B%.2f | ≈ %.0fK tint %+.0f",
            generation, label, requested, mode,
            gains.redGain, gains.greenGain, gains.blueGain, tt.temperature, tt.tint
        ))
    }
    #endif

    func focusModify(mode: AVCaptureDevice.FocusMode, device: AVCaptureDevice) {
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(mode) { device.focusMode = mode }
                device.unlockForConfiguration()
            } catch {}
        }
    }
        
    func focus(at point: CGPoint, afMode: String, device: AVCaptureDevice) {
        sessionQueue.async {
            guard afMode != "MF" else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                }
                if afMode == "AF-C" { device.focusMode = .continuousAutoFocus }
                device.unlockForConfiguration()
            } catch { print("对焦失败: \(error)") }
        }
    }
    
    private func saveToLibrary(photo: Data?, raw: Data?) {
        switch (photo, raw) {
        case let (photo?, raw?): savePair(photo: photo, raw: raw)
        case let (photo?, nil): saveSingle(photo, label: "JPEG")
        case let (nil, raw?): saveSingle(raw, label: "RAW")
        case (nil, nil): break
        }
    }

    private func saveSingle(_ data: Data, label: String) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }) { success, error in
            if success {
                print("✅ Saved \(label)")
            } else {
                print("❌ Saving \(label) failed: \(String(describing: error))")
            }
        }
    }

    // One asset with the JPEG as the photo and the DNG as its alternate, the way Apple's
    // RAW capture sample does it: the DNG goes in as a file with a .dng extension so
    // Photos can identify it. If Photos rejects the pair, both are saved separately so
    // nothing is lost.
    private func savePair(photo: Data, raw: Data) {
        let rawURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("dng")
        do {
            try raw.write(to: rawURL)
        } catch {
            print("❌ Writing DNG for RAW+JPEG failed: \(error)")
            saveSingle(photo, label: "JPEG")
            saveSingle(raw, label: "RAW")
            return
        }
        PHPhotoLibrary.shared().performChanges({
            let creationRequest = PHAssetCreationRequest.forAsset()
            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.uniformTypeIdentifier = UTType.jpeg.identifier
            creationRequest.addResource(with: .photo, data: photo, options: photoOptions)
            let rawOptions = PHAssetResourceCreationOptions()
            rawOptions.shouldMoveFile = true
            creationRequest.addResource(with: .alternatePhoto, fileURL: rawURL, options: rawOptions)
        }) { [weak self] success, error in
            try? FileManager.default.removeItem(at: rawURL)
            if success {
                print("✅ Saved RAW+JPEG")
            } else {
                print("❌ Saving RAW+JPEG as one asset failed, saving separately: \(String(describing: error))")
                self?.saveSingle(photo, label: "JPEG")
                self?.saveSingle(raw, label: "RAW")
            }
        }
    }
    
    func capturePhoto(
        orientation: AVCaptureVideoOrientation,
        request: PhotoCaptureRequest
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if request.usesManualExposure,
               let duration = request.manualExposureDuration,
               let iso = request.manualISO,
               let deviceInput = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first,
               deviceInput.device.isExposureModeSupported(.custom) {
                do {
                    let device = deviceInput.device
                    try device.lockForConfiguration()
                    self.applyManualExposure(duration: duration, iso: iso, to: device) { [weak self] _ in
                        self?.sessionQueue.async {
                            self?.performPhotoCapture(orientation: orientation, request: request)
                        }
                    }
                    device.unlockForConfiguration()
                } catch {
                    self.failPhotoCapture(error)
                }
                return
            }

            self.performPhotoCapture(orientation: orientation, request: request)
        }
    }

    private func performPhotoCapture(
        orientation: AVCaptureVideoOrientation,
        request: PhotoCaptureRequest
    ) {
        guard let connection = photoOutput.connection(with: .video),
              let photoSettings = makePhotoSettings(for: request) else {
            failPhotoCapture(nil)
            return
        }

        connection.videoOrientation = orientation
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = request.isFrontCamera
        }

        photoSettings.isShutterSoundSuppressionEnabled =
            photoOutput.isShutterSoundSuppressionSupported

        var context = CaptureContext(request: request)
        if request.usePureRawEngine {
            meterLock.lock()
            let fresh = ProcessInfo.processInfo.systemUptime - latestFrameTimestamp < 0.5
            context.previewStops = fresh ? latestFrameStops : nil
            meterLock.unlock()
        }
        captureContextLock.lock()
        captureContexts[photoSettings.uniqueID] = context
        captureContextLock.unlock()

        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }

    private func failPhotoCapture(_ error: Error?) {
        if let error {
            print("Photo capture configuration failed: \(error)")
        }
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.isSensorBusy = false
            if let camera = self?.delegate {
                camera.inFlightPhotos = max(0, camera.inFlightPhotos - 1)
            }
        }
    }
    
}


extension SessionManager: AVCaptureVideoDataOutputSampleBufferDelegate { // live stream
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        MetalWHProcessor.shared.process(pixelBuffer: pixelBuffer)
        meter(pixelBuffer)

        // The video feed is already demosaiced. For RAW-only modes the preview
        // shows this reference feed with the look bypassed.
        let mirrored = connection.inputPorts.first?.sourceDevicePosition == .front
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        // Tone map before orienting the CIImage so its original headroom is available.
        let image = FilmEngine.prepareSDR(input)
        previewFrames.update(image: mirrored ? image.oriented(.downMirrored) : image, mirrored: mirrored)
    }
}
    
extension SessionManager: AVCapturePhotoCaptureDelegate { // photo stream
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let captureContext = captureContext(for: photo.resolvedSettings.uniqueID) else { return }

        if photo.isRawPhoto {
            processRawPhoto(photo, captureContext: captureContext)
        } else {
            processProcessedPhoto(photo, captureContext: captureContext)
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let processedDimensions = resolvedSettings.photoDimensions
        let rawDimensions = resolvedSettings.rawPhotoDimensions
        let deliveredDimensions = processedDimensions.photoPixelCount >= rawDimensions.photoPixelCount
            ? processedDimensions
            : rawDimensions

        if error == nil {
            ShutterManager.incrementShutter()
        }

        DispatchQueue.main.async {
            self.delegate?.isSensorBusy = false
            if deliveredDimensions.width > 0 && deliveredDimensions.height > 0 {
                self.delegate?.lastCaptureResolution =
                    "\(deliveredDimensions.width)×\(deliveredDimensions.height)"
            }
        }

        markCaptureFinished(uniqueID: resolvedSettings.uniqueID)
    }

    private func captureContext(for uniqueID: Int64) -> CaptureContext? {
        captureContextLock.lock()
        defer { captureContextLock.unlock() }
        return captureContexts[uniqueID]
    }

    private func beginProcessing(uniqueID: Int64) {
        captureContextLock.lock()
        if var context = captureContexts[uniqueID] {
            context.pendingProcessingJobs += 1
            captureContexts[uniqueID] = context
        }
        captureContextLock.unlock()
    }

    private func finishProcessing(uniqueID: Int64) {
        captureContextLock.lock()
        var shouldReleaseBuffer = false
        var completed: CaptureContext?
        if var context = captureContexts[uniqueID] {
            context.pendingProcessingJobs = max(0, context.pendingProcessingJobs - 1)
            if context.captureFinished && context.pendingProcessingJobs == 0 {
                captureContexts.removeValue(forKey: uniqueID)
                shouldReleaseBuffer = true
            } else {
                captureContexts[uniqueID] = context
            }
            completed = shouldReleaseBuffer ? context : nil
        }
        captureContextLock.unlock()

        if let completed {
            saveToLibrary(photo: completed.photoData, raw: completed.rawData)
        }
        if shouldReleaseBuffer {
            releaseInFlightBuffer()
        }
    }

    private func markCaptureFinished(uniqueID: Int64) {
        captureContextLock.lock()
        var shouldReleaseBuffer = false
        var completed: CaptureContext?
        if var context = captureContexts[uniqueID] {
            context.captureFinished = true
            if context.pendingProcessingJobs == 0 {
                captureContexts.removeValue(forKey: uniqueID)
                shouldReleaseBuffer = true
                completed = context
            } else {
                captureContexts[uniqueID] = context
            }
        }
        captureContextLock.unlock()

        if let completed {
            saveToLibrary(photo: completed.photoData, raw: completed.rawData)
        }
        if shouldReleaseBuffer {
            releaseInFlightBuffer()
        }
    }

    private func store(photo: Data? = nil, raw: Data? = nil, uniqueID: Int64) {
        captureContextLock.lock()
        if var context = captureContexts[uniqueID] {
            if let photo { context.photoData = photo }
            if let raw { context.rawData = raw }
            captureContexts[uniqueID] = context
        }
        captureContextLock.unlock()
    }

    private func releaseInFlightBuffer() {
        DispatchQueue.main.async { [weak self] in
            guard let camera = self?.delegate else { return }
            camera.inFlightPhotos = max(0, camera.inFlightPhotos - 1)
        }
    }
    
    private func processRawPhoto(_ photo: AVCapturePhoto, captureContext: CaptureContext) {
        guard let rawData = photo.fileDataRepresentation() else { return }
        let request = captureContext.request
        let metadata = photo.metadata
        let uniqueID = photo.resolvedSettings.uniqueID

        beginProcessing(uniqueID: uniqueID)
        processingQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                defer { self.finishProcessing(uniqueID: uniqueID) }

                if request.imageQuality == "DNG" ||
                    request.imageQuality == "DNG+J" ||
                    request.imageQuality == "ProRAW" {
                    self.store(raw: rawData, uniqueID: uniqueID)
                }

                if request.usePureRawEngine, ParameterManager.savesJPEG(quality: request.imageQuality),
                   let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: nil) {
                    // Let the RAW developer roll highlights into SDR before the LUT.
                    rawFilter.extendedDynamicRangeAmount = 0
                    // A locked WB develops at that temperature; AWB keeps the as-shot neutral.
                    if let kelvin = request.whiteBalanceKelvin {
                        rawFilter.neutralTemperature = Float(kelvin)
                        rawFilter.neutralTint = 0
                    }
                    if let target = captureContext.previewStops {
                        rawFilter.exposure = self.matchedRAWExposure(
                            rawData, target: target, kelvin: request.whiteBalanceKelvin
                        )
                    }
                    // CIRAWFilter already rotates the pixels to the stored orientation.
                    if let baseCIImage = rawFilter.outputImage,
                       let jpeg = self.renderFilteredJPEG(
                            from: baseCIImage, with: metadata, look: request.look,
                            captureID: uniqueID, pixelsAreUpright: true
                       ) {
                        self.store(photo: jpeg, uniqueID: uniqueID)
                    }
                }
            }
        }
    }
    
    private func processProcessedPhoto(_ photo: AVCapturePhoto, captureContext: CaptureContext) {
        let request = captureContext.request
        guard ParameterManager.savesJPEG(quality: request.imageQuality), !request.usePureRawEngine else { return }

        guard let imageData = photo.fileDataRepresentation(),
              let ciImage = CIImage(data: imageData) else { return }
        let metadata = photo.metadata
        let uniqueID = photo.resolvedSettings.uniqueID

        beginProcessing(uniqueID: uniqueID)
        processingQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                defer { self.finishProcessing(uniqueID: uniqueID) }
                // CIImage(data:) keeps sensor orientation; the orientation tag rotates it.
                if let finalJPEGData = self.renderFilteredJPEG(
                    from: ciImage,
                    with: metadata,
                    look: request.look,
                    captureID: uniqueID,
                    pixelsAreUpright: false
                ) {
                    self.store(photo: finalJPEGData, uniqueID: uniqueID)
                }
            }
        }
    }
    
    // The viewfinder shows the ISP's rendering, which lifts the image well above a plain
    // RAW development. Find the global exposure that gives the developed RAW the same
    // metered brightness as the viewfinder frame at the shutter, using a small draft
    // development. Only brightness is matched; noise, sharpening and local tone mapping
    // stay out of the ZERO PROCESSING result.
    nonisolated static let rawExposureRange: ClosedRange<Float> = -2...3

    private func matchedRAWExposure(_ rawData: Data, target: Float, kelvin: Int?) -> Float {
        guard let draft = CIRAWFilter(imageData: rawData, identifierHint: nil) else { return 0 }
        if let kelvin {
            draft.neutralTemperature = Float(kelvin)
            draft.neutralTint = 0
        }
        let longEdge = max(draft.nativeSize.width, draft.nativeSize.height)
        if longEdge > 0 { draft.scaleFactor = Float(min(1, 384 / longEdge)) }
        draft.extendedDynamicRangeAmount = 0

        func measure(_ exposure: Float) -> Float? {
            draft.exposure = exposure
            guard let image = draft.outputImage else { return nil }
            let width = Int(image.extent.width), height = Int(image.extent.height)
            guard width > 0, height > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: image.extent,
                           format: .RGBA8, colorSpace: FilmEngine.deliveryColorSpace)
            return bytes.withUnsafeBufferPointer {
                ExposureMeter.offset(bytes: $0.baseAddress!, width: width, height: height,
                                     rowBytes: width * 4, order: .rgba)
            }
        }

        // The RAW tone curve is not linear in exposure, so correct twice.
        var exposure: Float = 0
        for _ in 0..<2 {
            guard let measured = measure(exposure) else { break }
            let error = target - measured
            if abs(error) < 0.05 { break }
            exposure = min(max(exposure + error, Self.rawExposureRange.lowerBound), Self.rawExposureRange.upperBound)
        }
        print("ZERO PROCESSING exposure matched to viewfinder: \(String(format: "%+.2f", exposure)) EV")
        return exposure
    }

    private func renderFilteredJPEG(
        from ciImage: CIImage,
        with originalMetadata: [String: Any],
        look: FilmRenderSettings,
        captureID: Int64,
        pixelsAreUpright: Bool
    ) -> Data? {
        let seed = UInt32(truncatingIfNeeded: captureID &* 0x9E3779B9)
        let filteredImage = FilmEngine.process(FilmEngine.prepareSDR(ciImage), settings: look, grainSeed: seed)
        guard let cgImage = context.createCGImage(
            filteredImage, from: filteredImage.extent, format: .RGBA8, colorSpace: FilmEngine.deliveryColorSpace
        ) else { return nil }
        
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        var metadata = originalMetadata
        // The ICC profile comes from the CGImage's color space.
        metadata.removeValue(forKey: kCGImagePropertyProfileName as String)
        let exifKey = kCGImagePropertyExifDictionary as String
        var exif = metadata[exifKey] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifColorSpace as String] = 0xFFFF // Uncalibrated: Display P3 via ICC
        metadata[exifKey] = exif
        if pixelsAreUpright {
            // Keeping the camera's tag would rotate already-upright pixels a second time.
            metadata[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
            let tiffKey = kCGImagePropertyTIFFDictionary as String
            var tiff = metadata[tiffKey] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation as String] = CGImagePropertyOrientation.up.rawValue
            metadata[tiffKey] = tiff
        }
        metadata[kCGImageDestinationLossyCompressionQuality as String] = Self.jpegQuality

        CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }
}
