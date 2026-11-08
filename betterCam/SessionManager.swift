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
}

class SessionManager: NSObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let context = CIContext()
    
    weak var delegate: Camera?
    
    
    // Full-resolution Core Image rendering can materialize several large buffers.
    // Keep still-photo development serial to avoid multiple 48 MP renders competing for memory.
    private let processingQueue = DispatchQueue(label: "com.bettercam.processingQueue")
    private let sessionQueue = DispatchQueue(label: "com.bettercam.sessionQueue")
    private let captureContextLock = NSLock()
    private var captureContexts: [Int64: CaptureContext] = [:]
    private var photoDimensions = PhotoDimensions()
    private var exposureOffsetObserver: NSKeyValueObservation?
    private var smoothedOffset: Float = 0.0
    private var lastUpdateTimestamp: TimeInterval = 0
    private var lastMeterDisplayValue: Float?
    private let meterUpdateInterval: TimeInterval = 0.12
    private let meterSmoothing: Float = 0.75
    private let meterZeroDeadband: Float = 0.12
    private let meterDisplayDeadband: Float = 0.1
    private var physicalStreamingPosition: AVCaptureDevice.Position = .back
    private var activeDeviceUniqueID: String?
    
    func initSession(with lens: Lens) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.session.inputs.forEach { self.session.removeInput($0) }
            
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
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
            self.physicalStreamingPosition = lens.device.position
            self.activeDeviceUniqueID = lens.device.uniqueID
            self.delegate?.refreshLensCapabilities() 
            self.session.startRunning()
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
            self.physicalStreamingPosition = device.position
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
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc]
            )
        } else if request.imageQuality == "DNG" {
            guard let bayerRAW else { return nil }
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayerRAW)
        } else {
            settings = AVCapturePhotoSettings(
                format: [AVVideoCodecKey: AVVideoCodecType.hevc]
            )
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
        } else if canRequest48MP || request.imageQuality == "ProRAW" {
            settings.photoQualityPrioritization = .quality
        } else {
            settings.photoQualityPrioritization = .speed
        }

        return settings
    }

    func preparePhotoPipeline(
        resolutionMode: PhotoResolutionMode,
        imageQuality: String,
        usesManualExposure: Bool
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard resolutionMode == .high48MP,
                  imageQuality == "JPEG" || imageQuality == "ProRAW" else {
                self.photoOutput.setPreparedPhotoSettingsArray([], completionHandler: nil)
                return
            }

            let request = PhotoCaptureRequest(
                imageQuality: imageQuality,
                resolutionMode: resolutionMode,
                isFrontCamera: false,
                usePureRawEngine: false,
                styleName: "STD",
                lutIntensity: 1,
                grainIntensity: 0,
                usesManualExposure: usesManualExposure,
                manualExposureDuration: nil,
                manualISO: nil
            )
            guard let settings = self.makePhotoSettings(for: request) else { return }

            self.photoOutput.setPreparedPhotoSettingsArray([settings]) { prepared, error in
                if let error {
                    print("❌ High-resolution pipeline preparation failed: \(error)")
                } else {
                    print("✅ High-resolution pipeline prepared: \(prepared)")
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
        exposureOffsetObserver?.invalidate()
        smoothedOffset = 0.0
        lastMeterDisplayValue = nil
        lastUpdateTimestamp = 0
        
        exposureOffsetObserver = device.observe(\.exposureTargetOffset, options: [.new]) { [weak self] device, _ in
            guard let self = self, let camera = self.delegate else { return }
            if camera.parameterManager.SS != ExposureParameter.auto && camera.parameterManager.ISO != ExposureParameter.auto {
                let rawOffset = device.exposureTargetOffset
                self.smoothedOffset = (self.smoothedOffset * self.meterSmoothing) + (rawOffset * (1.0 - self.meterSmoothing))
                
                let now = Date().timeIntervalSince1970
                guard now - self.lastUpdateTimestamp > self.meterUpdateInterval else { return }
                
                var displayValue = self.smoothedOffset
                if abs(displayValue) < self.meterZeroDeadband { displayValue = 0.0 }
                displayValue = (displayValue * 10).rounded() / 10
                
                if let lastValue = self.lastMeterDisplayValue,
                   abs(displayValue - lastValue) < self.meterDisplayDeadband {
                    return
                }
                
                self.lastUpdateTimestamp = now
                self.lastMeterDisplayValue = displayValue
                let formattedOffset = String(format: "%+.1f", displayValue)
                
                DispatchQueue.main.async {
                    if camera.parameterManager.EV != formattedOffset {
                        camera.parameterManager.EV = formattedOffset
                    }
                }
            }
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
    
    private func saveImageDataToLibrary(_ data: Data, isRaw: Bool) {
        PHPhotoLibrary.shared().performChanges({
            let creationRequest = PHAssetCreationRequest.forAsset()
            
            if isRaw {
                // 💡 修复点：使用 PHAssetResourceCreationOptions 的正确方式
                let options = PHAssetResourceCreationOptions()
                // 确保 DNG 格式被正确识别，有些 iOS 版本需要通过 options 显式指定
                creationRequest.addResource(with: .photo, data: data, options: options)
            } else {
                creationRequest.addResource(with: .photo, data: data, options: nil)
            }
        }) { success, error in
            if success {
                print("✅ \(isRaw ? "RAW" : "JPEG") 保存成功")
            } else if let error = error {
                print("❌ 保存失败: \(error.localizedDescription)")
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

        captureContextLock.lock()
        captureContexts[photoSettings.uniqueID] = CaptureContext(request: request)
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
        
        // MARK: Pipeline STEP 1
        // MARK: Offload METAL stuff to MetalWH Processor
        if let camera = self.delegate {
            MetalWHProcessor.shared.process(pixelBuffer: pixelBuffer)
        }
        
        // MARK: Pipeline STEP 2
        // MARK: MIRROR
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        
        if self.physicalStreamingPosition == .front {
            ciImage = ciImage.oriented(.downMirrored)
        }
        
        // MARK: Pipeline STEP 3
        // MARK: PREVIEW DEVELOPMENT
        // AVCaptureVideoDataOutput is always a demosaiced video stream. In ZERO
        // PROCESSING mode this is an SDR RAW-reference preview, not a Bayer RAW
        // stream; the same film simulation is still applied to match our RAW
        // development output as closely as the public capture API permits.
        guard let camera = self.delegate else { return }
        let finalImage: CIImage
        if camera.parameterManager.imageQuality == "DNG" {
            finalImage = ciImage
        } else {
            finalImage = FilmEngine.shared.process(
                ciImage,
                styleName: camera.parameterManager.style,
                lutIntensity: camera.lutIntensity,
                grainIntensity: camera.grainIntensity
            )
        }
        
        
        if let cgImage = context.createCGImage(finalImage, from: finalImage.extent) {
            DispatchQueue.main.async {
                camera.currentPreviewImage = cgImage
            }
        }
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
        if var context = captureContexts[uniqueID] {
            context.pendingProcessingJobs = max(0, context.pendingProcessingJobs - 1)
            if context.captureFinished && context.pendingProcessingJobs == 0 {
                captureContexts.removeValue(forKey: uniqueID)
                shouldReleaseBuffer = true
            } else {
                captureContexts[uniqueID] = context
            }
        }
        captureContextLock.unlock()

        if shouldReleaseBuffer {
            releaseInFlightBuffer()
        }
    }

    private func markCaptureFinished(uniqueID: Int64) {
        captureContextLock.lock()
        var shouldReleaseBuffer = false
        if var context = captureContexts[uniqueID] {
            context.captureFinished = true
            if context.pendingProcessingJobs == 0 {
                captureContexts.removeValue(forKey: uniqueID)
                shouldReleaseBuffer = true
            } else {
                captureContexts[uniqueID] = context
            }
        }
        captureContextLock.unlock()

        if shouldReleaseBuffer {
            releaseInFlightBuffer()
        }
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
                    self.saveImageDataToLibrary(rawData, isRaw: true)
                }

                if request.usePureRawEngine &&
                    request.imageQuality != "DNG" &&
                    request.imageQuality != "ProRAW",
                   let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: nil),
                   let baseCIImage = rawFilter.outputImage,
                   let finalJPEGData = self.renderFilteredJPEG(
                        from: baseCIImage,
                        with: metadata,
                        request: request
                   ) {
                    self.saveImageDataToLibrary(finalJPEGData, isRaw: false)
                }
            }
        }
    }
    
    private func processProcessedPhoto(_ photo: AVCapturePhoto, captureContext: CaptureContext) {
        let request = captureContext.request
        if request.imageQuality == "DNG" ||
            request.imageQuality == "ProRAW" ||
            request.usePureRawEngine { return }

        guard let imageData = photo.fileDataRepresentation(),
              let ciImage = CIImage(data: imageData) else { return }
        let metadata = photo.metadata
        let uniqueID = photo.resolvedSettings.uniqueID

        beginProcessing(uniqueID: uniqueID)
        processingQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                defer { self.finishProcessing(uniqueID: uniqueID) }
                if let finalJPEGData = self.renderFilteredJPEG(
                    from: ciImage,
                    with: metadata,
                    request: request
                ) {
                    self.saveImageDataToLibrary(finalJPEGData, isRaw: false)
                }
            }
        }
    }
    
    private func renderFilteredJPEG(
        from ciImage: CIImage,
        with originalMetadata: [String: Any],
        request: PhotoCaptureRequest
    ) -> Data? {
        let filteredImage = FilmEngine.shared.process(
            ciImage,
            styleName: request.styleName,
            lutIntensity: request.lutIntensity,
            grainIntensity: request.grainIntensity
        )
        
        guard let cgImage = self.context.createCGImage(filteredImage, from: filteredImage.extent) else { return nil }
        
        // C. 准备容器
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                
        // D. 缝合元数据
        var finalMetadata = originalMetadata
        if let orientation = originalMetadata[kCGImagePropertyOrientation as String] {
            finalMetadata[kCGImagePropertyOrientation as String] = orientation
        }
                
        // E. 封口打包
        CGImageDestinationAddImage(destination, cgImage, finalMetadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
                
        return outputData as Data
    }
}
