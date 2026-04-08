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
    
    weak var delegate: Camera?
    
    
    private let processingQueue = DispatchQueue(label: "com.bettercam.processingQueue", attributes: .concurrent)
    private let sessionQueue = DispatchQueue(label: "com.bettercam.sessionQueue")
    private var exposureOffsetObserver: NSKeyValueObservation?
    private var smoothedOffset: Float = 0.0
    private var lastUpdateTimestamp: TimeInterval = 0
    private var physicalStreamingPosition: AVCaptureDevice.Position = .back
    
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
            
            self.session.commitConfiguration()
            self.physicalStreamingPosition = lens.device.position
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
            self.session.commitConfiguration()
            self.physicalStreamingPosition = device.position
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
                    var isoValue = Float(currentISO) ?? 100.0
                    if isoValue > camera.lensManager.currentLens.maxISO {
                        isoValue = camera.lensManager.currentLens.maxISO
                    } else if isoValue < camera.lensManager.currentLens.minISO {
                        isoValue = camera.lensManager.currentLens.minISO
                    }
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
        var photoSettings: AVCapturePhotoSettings
        
        let pureEngine = delegate?.parameterManager.isPureRawEngineEnabled ?? false
        
        // 💡 1. Zero Process 终极霸王条款：
        // 只要开了 pureEngine，且不是纯 DNG 模式，一律只向硬件要 RAW！彻底切断苹果的熟肉流水线！
        if pureEngine && imageQuality != "DNG" && rawFormat != nil {
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat!)
        }
        // 2. 以下是普通的下单逻辑
        else if imageQuality == "DNG+J" && rawFormat != nil {
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
        
        
        if self.physicalStreamingPosition == .front {
            ciImage = ciImage.oriented(.downMirrored)
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
                camera.currentPreviewImage = cgImage
            }
        }
    }
}
    
extension SessionManager: AVCapturePhotoCaptureDelegate { // photo stream
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let camera = self.delegate, error == nil else { return }
        
        // 路由分发：根据照片类型，送入不同的“冲洗车间”
        if photo.isRawPhoto {
            processRawPhoto(photo, camera: camera)
        } else {
            processProcessedPhoto(photo, camera: camera)
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        // 无论这次拍摄是成功、失败、单拍、双拍，只要到了这里，说明流水线彻底空了！
        DispatchQueue.main.async {
            self.delegate?.isSensorBusy = false
        }
    }
    
    private func processRawPhoto(_ photo: AVCapturePhoto, camera: Camera) {
        // 这两步提取数据很快，在当前线程做
        guard let rawData = photo.fileDataRepresentation() else { return }
        let quality = camera.parameterManager.imageQuality
        let pureEngine = camera.parameterManager.isPureRawEngineEnabled
        let metadata = photo.metadata // 提前把元数据拿出来
        
        // 🚀 核心：把耗时的操作踢到并发后台队列！
        processingQueue.async { [weak self] in
            // 存底片
            if quality == "DNG" || quality == "DNG+J" {
                self?.saveImageDataToLibrary(rawData, isRaw: true)
            }
            
            // 自己洗照片 (Zero Process)
            if pureEngine && quality != "DNG" {
                guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: nil),
                      let baseCIImage = rawFilter.outputImage else { return }
                
                // 这里的 render 极其耗时，但现在在后台，UI 丝毫不卡！
                if let finalJPEGData = self?.renderFilteredJPEG(from: baseCIImage, with: metadata, camera: camera) {
                    self?.saveImageDataToLibrary(finalJPEGData, isRaw: false)
                }
            }
            
            // 💡 洗完收工，通知 Camera 释放一个内存缓冲位！
            DispatchQueue.main.async {
                camera.inFlightPhotos -= 1
            }
        }
    }
    
    private func processProcessedPhoto(_ photo: AVCapturePhoto, camera: Camera) {
        let quality = camera.parameterManager.imageQuality
        let pureEngine = camera.parameterManager.isPureRawEngineEnabled
        
        if quality == "DNG" || pureEngine { return }
        
        // 提前拿数据
        guard let imageData = photo.fileDataRepresentation(),
              let ciImage = CIImage(data: imageData) else { return }
        let metadata = photo.metadata
        
        // 🚀 踢到后台并发处理！
        processingQueue.async { [weak self] in
            if let finalJPEGData = self?.renderFilteredJPEG(from: ciImage, with: metadata, camera: camera) {
                self?.saveImageDataToLibrary(finalJPEGData, isRaw: false)
            }
            
            // 💡 释放内存位
            DispatchQueue.main.async {
                camera.inFlightPhotos -= 1
            }
        }
    }
    
    private func renderFilteredJPEG(from ciImage: CIImage, with originalMetadata: [String: Any], camera: Camera) -> Data? {
        let filteredImage = FilmEngine.shared.process(
            ciImage,
            styleName: camera.parameterManager.style,
            lutIntensity: camera.lutIntensity,
            grainIntensity: camera.grainIntensity
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
