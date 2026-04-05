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

class SessionManager: NSObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let context = CIContext()
    @Published var currentPreviewImage: CGImage?
    
    weak var delegate: Camera?
    
    private let sessionQueue = DispatchQueue(label: "com.bettercam.sessionQueue")
    private var exposureOffsetObserver: NSKeyValueObservation?
    private var smoothedOffset: Float = 0.0
    private var lastUpdateTimestamp: TimeInterval = 0
    
    func initSession(with lens: Lens) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
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
            
            self.session.commitConfiguration()
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
            self.session.commitConfiguration()
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
        let device = camera.lensManager.currentLens.device
        
        sessionQueue.async { [weak self] in
            do {
                try device.lockForConfiguration()
                let isManual = (currentSS != "AUTO" && currentISO != "AUTO")
                
                if isManual {
                    let duration = self?.parseShutterSpeed(currentSS) ?? AVCaptureDevice.currentExposureDuration
                    let cleanISO = currentISO.replacingOccurrences(of: "ISO ", with: "")
                    let isoValue = Float(cleanISO) ?? 100.0
                    device.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil)
                } else {
                    if let evValue = Float(currentEV) {
                        device.setExposureTargetBias(evValue, completionHandler: nil)
                    }
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch { print("曝光控制失败: \(error)") }
        }
    }
    
    private func setupLightMeter(for device: AVCaptureDevice) {
        exposureOffsetObserver?.invalidate()
        exposureOffsetObserver = device.observe(\.exposureTargetOffset, options: [.new]) { [weak self] device, _ in
            guard let self = self, let camera = self.delegate else { return }
            if camera.parameterManager.SS != "AUTO" && camera.parameterManager.ISO != "AUTO" {
                let rawOffset = device.exposureTargetOffset
                self.smoothedOffset = (self.smoothedOffset * 0.8) + (rawOffset * 0.2)
                let now = Date().timeIntervalSince1970
                if now - self.lastUpdateTimestamp > 0.15 {
                    var displayValue = self.smoothedOffset
                    if abs(displayValue) < 0.15 { displayValue = 0.0 }
                    let formattedOffset = String(format: "%+.1f", displayValue)
                    DispatchQueue.main.async {
                        if camera.parameterManager.EV != formattedOffset {
                            camera.parameterManager.EV = formattedOffset
                            self.lastUpdateTimestamp = now
                        }
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
        ShutterManager.incrementShutter()
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
    
    func capturePhoto(orientation: AVCaptureVideoOrientation, userSettings: (String, Bool)) { // (imageQuality, isFront)
        guard let connection = photoOutput.connection(with: .video) else { return }
        connection.videoOrientation = orientation
        let (imageQuality, isFront) = userSettings
        let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first
        let photoSettings: AVCapturePhotoSettings
        if imageQuality == "DNG+J" && rawFormat != nil {
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat!, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else if imageQuality == "DNG" && rawFormat != nil {
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat!)
        } else {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        photoSettings.photoQualityPrioritization = .speed
        photoSettings.isShutterSoundSuppressionEnabled = true
        
        if isFront && connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
        
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }
    
    private func parseShutterSpeed(_ ss: String) -> CMTime {
        if let doubleVal = Double(ss) {
            return CMTime(value: 1000, timescale: Int32(1000 / doubleVal))
        }
        
        let components = ss.components(separatedBy: "/")
        if components.count == 2,
           let num = Double(components[0]),
           let den = Double(components[1]) {
            return CMTime(value: Int64(num * 1000), timescale: Int32(den * 1000))
        }
        return AVCaptureDevice.currentExposureDuration
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
        
        
        if let currentLens = self.delegate?.lensManager.currentLens,
           currentLens.device.position == .front {
            ciImage = ciImage.oriented(.upMirrored)
        }
        
        // MARK: Pipeline STEP 3
        // MARK: FILM SIM
        guard let camera = self.delegate else { return }
        let finalImage = (camera.parameterManager.imageQuality == "DNG") ? ciImage :
        FilmEngine.shared.process(ciImage,
                                  styleName: camera.parameterManager.style,
                                  lutIntensity: camera.lutIntensity,
                                  grainIntensity: camera.grainIntensity)
        
        
        if let cgImage = context.createCGImage(finalImage, from: finalImage.extent) {
            DispatchQueue.main.async {
                self.currentPreviewImage = cgImage
            }
        }
    }
}
    
extension SessionManager: AVCapturePhotoCaptureDelegate { // photo stream
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let camera = self.delegate else { return }
        if let error = error { return }
        defer { DispatchQueue.main.async { camera.isCapturing = false } }
        
        // --- 逻辑 A: 处理 RAW (DNG) 数据 ---
        if photo.isRawPhoto {
            if let rawData = photo.fileDataRepresentation() {
                saveImageDataToLibrary(rawData, isRaw: true)
            }
            if camera.parameterManager.imageQuality == "DNG" { return }
        }
        
        // --- 逻辑 B: 处理 JPEG (带滤镜) 数据 ---
        guard camera.parameterManager.imageQuality != "DNG" else { return }
        
        if !photo.isRawPhoto {
            guard let imageData = photo.fileDataRepresentation(),
                  var ciImage = CIImage(data: imageData) else { return }
            
            // 1. 应用滤镜处理
            let filteredImage = FilmEngine.shared.process(ciImage, styleName: camera.parameterManager.style, lutIntensity: camera.lutIntensity, grainIntensity: camera.grainIntensity)
            
            // 2. 渲染为中间 CGImage
            let context = CIContext()
            guard let cgImage = context.createCGImage(filteredImage, from: filteredImage.extent) else { return }
            
            // 3. 准备手动写入元数据的 Data 对象
            let outputData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            
            // 💡 关键点：获取并修正元数据
            var metadata = photo.metadata
            
            // 确保方向被显式写入，防止 Core Image 渲染后丢失旋转信息
            if let orientation = photo.metadata[kCGImagePropertyOrientation as String] {
                metadata[kCGImagePropertyOrientation as String] = orientation
            }
            
            // 4. 将 CGImage 和 元数据 合并写入
            CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
            
            if CGImageDestinationFinalize(destination) {
                saveImageDataToLibrary(outputData as Data, isRaw: false)
            }
        }
    }
}
