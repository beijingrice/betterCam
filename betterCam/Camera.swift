//
//  Camera.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import Foundation
import AVFoundation
import SwiftUI
import Combine
import CoreImage
import Photos
import CoreMotion

enum CameraPermissionStatus {
    case undetermined  // 尚未询问
    case authorized    // 已授权
    case denied        // 已拒绝
}

class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    private var exposureOffsetObserver: NSKeyValueObservation?
    private var smoothedOffset: Float = 0.0 // 💡 用于平滑存储
    private var lastUpdateTimestamp: TimeInterval = 0
    private let sessionQueue = DispatchQueue(label: "com.betterCam.sessionQueue")
    
    @Published var cameraPermission: CameraPermissionStatus = .undetermined
    @Published var photoPermission: CameraPermissionStatus = .undetermined
    
    var isFullyAuthorized: Bool {
        cameraPermission == .authorized && photoPermission == .authorized
    }
    
    // Camera.swift 中添加
    @AppStorage("hasCompletedTutorial") var hasCompletedTutorial: Bool = false
    @Published var isShowingTutorial: Bool = false
    
    // 在 Camera 类中添加
    @Published var lutIntensity: Float = 1.0  // 0.0 到 1.0
    @Published var grainIntensity: Float = 0.0 // 0.0 到 1.0

    // 定义一个临时的起始值，用于手势计算
    private var startLutIntensity: Float = 0.0
    private var startGrainIntensity: Float = 0.0
    
    @Published var inCameraView: Bool = true {
        didSet {
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                if !inCameraView {
                    if self.session.isRunning {
                        self.session.stopRunning()
                    }
                } else {
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                }
            }
        }
    }
    
    @Published var isCapturing: Bool = false
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var currentDeviceIndex: Int = 0 {
        didSet {
            setupLightMeter()
        }
    }
    
    deinit {
        exposureOffsetObserver?.invalidate()
    }
    
    func setupLightMeter() {
        exposureOffsetObserver?.invalidate()
        guard availableDevices.indices.contains(currentDeviceIndex) else { return }
        let device = availableDevices[currentDeviceIndex]
        exposureOffsetObserver = device.observe(\.exposureTargetOffset, options: [.new]) {[weak self] device, _ in
            // 只有当快门和 ISO 都是手动时，才激活“测光表”模式
            guard let self = self else { return }
            if self.SS != "AUTO" && self.ISO != "AUTO" {
                let rawOffset = device.exposureTargetOffset
                
                // 1. 💡 低通滤波算法：新值 = 旧值 * 0.8 + 采样值 * 0.2
                // 这能让数字变化带有“阻尼感”，过滤掉高频抖动
                self.smoothedOffset = (self.smoothedOffset * 0.8) + (rawOffset * 0.2)
                
                let now = Date().timeIntervalSince1970
                // 2. 限制 UI 刷新频率（每 150ms），进一步减少视觉疲劳
                if now - self.lastUpdateTimestamp > 0.15 {
                    // 3. 💡 增加“死区”判断：如果绝对值很小，直接显示 0.0，防止在 0 附近乱跳
                    var displayValue = self.smoothedOffset
                    if abs(displayValue) < 0.15 { displayValue = 0.0 }
                    
                    let formattedOffset = String(format: "%+.1f", displayValue)
                    
                    DispatchQueue.main.async {
                        if self.EV != formattedOffset {
                            self.EV = formattedOffset
                            self.lastUpdateTimestamp = now
                        }
                    }
                }
            }
        }
        
    }
    
    private var lastSS: String = ""
    private var lastISO: String = ""
    private func autoAmode(nowBeingControlled: String) {
        if nowBeingControlled == "SS" {
            if SS == "AUTO" && ISO != "AUTO" {
                // Enter AUTO mode
                lastISO = ISO
                ISO = "AUTO"
                EV = "0.0"
                smoothedOffset = 0.0
            } else if SS != "AUTO" && ISO == "AUTO" {
                ISO = lastISO
            }
        } else if nowBeingControlled == "ISO" {
            if ISO == "AUTO" && SS != "AUTO" {
                // Enter AUTO mode
                lastSS = SS
                SS = "AUTO"
                EV = "0.0"
                smoothedOffset = 0.0
            } else if ISO != "AUTO" && SS == "AUTO" {
                SS = lastSS
            }
        }
    }
    @Published var SS: String = "1/200" {
        didSet {
            autoAmode(nowBeingControlled: "SS")
            updateExposure()
    }
    }
    @Published var Aperture: String = "F1.8"
    @Published var EV: String = "0.0" { didSet { updateExposure() } }
    @Published var ISO: String = "ISO 100" {
        didSet {
            autoAmode(nowBeingControlled: "ISO")
            updateExposure()
        }
    }
    // var styleOptions: [String] = ["STD", "RICH", "NOSTALGIC", "BW", "MANAGE"]
    // TODO: Change it back after ADD function is ready
    var styleOptions: [String] = []
    var AFModeOptions: [String] = ["AF-C", "AF-S"]
    @Published var style: String = "STD"
    @Published var imageQuality: String = "DNG+J"
    @Published var aspectRatio: String = "4:3"
    @Published var AFMode: String = "AF-C" {
        didSet {
            if AFMode == "AF-S" {
                focusModify(mode: .locked)
            } else if AFMode == "AF-C" {
                focusModify(mode: .continuousAutoFocus)
            }
        }
    }
    @Published var WBMode: String = "AWB"
    let ISOoptions = ["AUTO", "50", "64", "100", "125", "160", "200", "250", "320", "400", "500", "640", "800", "1000", "1250", "1600", "2000", "2500", "3200", "4000", "5000", "6400"]
    let SSoptions = [
      "AUTO", "1", "0.8", "0.6", "0.5", "0.4", "1/3", "1/4", "1/5", "1/6", 
      "1/8", "1/10", "1/13", "1/15", "1/20", "1/25", "1/30", "1/40", "1/50",
      "1/60", "1/80", "1/100", "1/125", "1/160", "1/200", "1/250", "1/320",
      "1/400", "1/500", "1/640", "1/800", "1/1000", "1/1250", "1/1600",
      "1/2000", "1/2500", "1/3200", "1/4000", "1/5000", "1/6400", "1/8000",
      "1/10000", "1/12500", "1/16000", "1/20000", "1/25000", "1/32000",
      "1/40000", "1/50000", "1/64000"
    ]
    let EVoptions = [
        "-5.0", "-4.7", "-4.3", "-4.0", "-3.7", "-3.3", "-3.0", "-2.7", "-2.3", "-2.0",
        "-1.7", "-1.3", "-1.0", "-0.7", "-0.3", "0.0",
        "+0.3", "+0.7", "+1.0", "+1.3", "+1.7", "+2.0", "+2.3", "+2.7", "+3.0", "+3.3",
        "+3.7", "+4.0", "+4.3", "+4.7", "+5.0"
    ]
    let imageQualityOptions: [String] = ["DNG+J", "DNG", "JPEG"]
    
    
    @Published var actualISOoptions: [String] = []
    @Published var actualSSoptions: [String] = []
    
    
    @Published var activeIndex: Int = 0
    @Published var currentPreviewImage: CGImage?
    @Published var isAdjustingValue: Bool = false
    
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let context = CIContext()
    private var shutterSoundID: SystemSoundID = 0
    
    private let motionManager = CMMotionManager()
    private var deviceOrientation: AVCaptureVideoOrientation = .portrait

        // 在 init 中启动监测
    func startDeviceMotion() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.2
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                guard let motion = motion else { return }
                
                // 💡 根据引力向量计算当前的物理方向
                let x = motion.gravity.x
                let y = motion.gravity.y
                
                if abs(y) >= abs(x) {
                    self?.deviceOrientation = y >= 0 ? .portraitUpsideDown : .portrait
                } else {
                    self?.deviceOrientation = x >= 0 ? .landscapeLeft : .landscapeRight
                }
            }
        }
    }
    
    func syncAllLUTsToOptions() {
        // 获取 FilmEngine 里所有的胶片名（包括内置和用户导入的）
        let allNames = FilmEngine.shared.availableSimulations.map { $0.name }
        styleOptions = []
        for name in allNames {
            if !styleOptions.contains(name) {
                // TODO: Change it back to ADD
                styleOptions.append(name)
            }
        }
        if !styleOptions.contains("MANAGE") {
            styleOptions.append("MANAGE")
        }
    }
    
    override init() {
        super.init()
        checkAllPermissions()
        discoverCameras()
        setupShutterSound()
        setupSession()
        setupLightMeter()
        startDeviceMotion()
        syncAllLUTsToOptions()
        if !hasCompletedTutorial {
            isShowingTutorial = true
        }
    }
    
    func checkAllPermissions() {
        // 1. 检查相机权限
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        handleCameraStatus(cameraStatus)
        
        // 2. 检查相册写入权限
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        handlePhotoStatus(photoStatus)
    }
    private func handleCameraStatus(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: cameraPermission = .authorized
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.cameraPermission = granted ? .authorized : .denied }
            }
        default: cameraPermission = .denied
        }
    }

    private func handlePhotoStatus(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited: photoPermission = .authorized
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async { self.photoPermission = (status == .authorized || status == .limited) ? .authorized : .denied }
            }
        default: photoPermission = .denied
        }
    }
    
    
    func discoverCameras() {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back)
        self.availableDevices = discoverySession.devices
    }
    
    func switchCamera(direction: Int) {
        guard availableDevices.count > 1 else { return }
        if currentDeviceIndex + direction >= 0 {
            currentDeviceIndex = (currentDeviceIndex + 1) % availableDevices.count
        } else {
            currentDeviceIndex = (availableDevices.count - 1)
        }
        let newDevice = availableDevices[currentDeviceIndex]
        
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                // 💡 关键：切换后立即更新光圈显示和 SS/ISO 可用范围
                self.Aperture = String(format: "F%.1f", newDevice.lensAperture)
                self.actualSSoptions = self.SSoptions.supportedSS(for: newDevice)
                self.actualISOoptions = self.ISOoptions.supportedISO(for: newDevice).formattedISOoptions()
                updateExposure()
            }
        } catch {
            print("切换失败: \(error)")
        }
        session.commitConfiguration()
    }
    
    func toggleAdjustmentMode() {
        // 1. 切换模式
        if activeIndex != 9 && activeIndex != 8 {
            isAdjustingValue.toggle()
        }
        
        if activeIndex == 8 {
            if !isAdjustingValue {
                isAdjustingValue = true
            }
            else { // is adjusting value
                if style == "MANAGE" {
                    inCameraView = false
                    isAdjustingValue = false
                } else {
                    isAdjustingValue = false
                }
            }
        }
        
        // 2. 物理反馈：按下时震动一下
        // 这里使用 medium 震动，区别于拨轮旋转时的 light 震动
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
        
        // 3. 可以在这里做一些自动化的逻辑
        // 比如：如果从调节模式退出，可以自动触发一次硬件锁定
    }
    
    // --- 1. 权限处理逻辑 ---
    func checkPhotoLibraryPermission() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
    }
    
    private func setupSession() {
        guard !availableDevices.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer {
            self.session.commitConfiguration()
        }
        
        guard let videoDevice = availableDevices[currentDeviceIndex] ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoDeviceInput) else { return }
        session.addInput(videoDeviceInput)
        
        self.Aperture = String(format: "F%.1f", videoDevice.lensAperture)
        
        self.actualSSoptions = self.SSoptions.supportedSS(for: videoDevice)
        self.actualISOoptions = self.ISOoptions.supportedISO(for: videoDevice).formattedISOoptions()
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        }
        
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        
        session.commitConfiguration()
        print("AF Mode:", videoDevice.focusMode)
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // 💡 传入实时强度参数
        let finalImage = (imageQuality == "DNG") ? ciImage :
        FilmEngine.shared.process(ciImage,
                                  styleName: style,
                                  lutIntensity: lutIntensity,
                                  grainIntensity: grainIntensity)
        
        if let cgImage = context.createCGImage(finalImage, from: finalImage.extent) {
            DispatchQueue.main.async {
                self.currentPreviewImage = cgImage
            }
        }
    }
    
    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard AFMode != "MF" else { return }
            
            // 1. 获取当前正在使用的物理设备
            guard let device = self.availableDevices.indices.contains(self.currentDeviceIndex) ?
                    self.availableDevices[self.currentDeviceIndex] :
                        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            
            do {
                try device.lockForConfiguration()
                
                // 2. 设置对焦模式（如果设备支持）
                // point 是已经转换后的 (0,0) 到 (1,1) 的坐标
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus // 这里使用 .autoFocus 触发一次对焦
                }
                
                // 3. 设置曝光测光模式（通常对焦和测光点是一致的）
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                }
                
                // 4. 对焦完成后建议恢复到连续自动对焦 (AF-C)
                // 你也可以根据你的 AFMode 逻辑来决定是否切回 .continuousAutoFocus
                if AFMode == "AF-C" {
                    device.focusMode = .continuousAutoFocus
                }
                
                
                device.unlockForConfiguration()
            } catch {
                print("❌ 对焦配置失败: \(error)")
            }
        }
    }
    
    func focusModify(mode: AVCaptureDevice.FocusMode) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let device = self.availableDevices.indices.contains(self.currentDeviceIndex) ?
                    self.availableDevices[self.currentDeviceIndex] :
                        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            do {
                try device.lockForConfiguration()
                device.focusMode = mode
                device.unlockForConfiguration()
            } catch {
                // Do nothing
            }
        }
    }
    
    private func setupShutterSound() {
        guard let soundURL = Bundle.main.url(forResource: "shutter_eqed_gained", withExtension: "aac") else { return }
        AudioServicesCreateSystemSoundID(soundURL as CFURL, &shutterSoundID)
    }
    
    func playShutterSound() {
        if shutterSoundID != 0 {
            AudioServicesPlaySystemSound(shutterSoundID)
        }
    }
    
    private func adjustValue(direction: Int) {
        switch activeIndex {
        case 2:
            AFMode = nextOption(in: AFModeOptions, current: AFMode, direction: direction)
        case 8: // STYLE
            style = nextOption(in: styleOptions, current: style, direction: direction)
        case 4: // SS
            SS = nextOption(in: actualSSoptions, current: SS, direction: direction)
        case 6: // EV
            let isManualMode = (SS != "AUTO" && ISO != "AUTO")
            if !isManualMode {
                EV = nextOption(in: EVoptions, current: EV, direction: direction)
            }
        case 7: // ISO
            ISO = nextOption(in: actualISOoptions, current: ISO, direction: direction)
        case 1: switchCamera(direction: direction)
        case 0: // Image Quality
            imageQuality = nextOption(in: imageQualityOptions, current: imageQuality, direction: direction)
        // 💡 你可以在这里补充 Aperture (index 5) 或 Style (index 8) 的逻辑
        default:
            break
        }
    }

    // 辅助函数：在数组中寻找下一个值（Python 风格的循环索引）
    private func nextOption(in options: [String], current: String, direction: Int, isEV: Bool = false) -> String {
        guard !options.isEmpty else { return current }
        let currentIndex = options.firstIndex(of: current) ?? 0
        var nextIndex: Int = 0
        if !isEV {
            nextIndex = (currentIndex + direction) % options.count
        } else {
            // is EV mode
            if (currentIndex + direction) >= options.count {
                nextIndex = currentIndex
            } else
            if (currentIndex + direction) < 0 {
                nextIndex = currentIndex
            } else {
                nextIndex = currentIndex + direction
            }
        }
        if nextIndex < 0 {
            nextIndex = options.count - 1
        }
        return options[nextIndex]
    }
    
    func changeParameter(direction: Int) {
        if isAdjustingValue {
            adjustValue(direction: direction)
        } else {
            let newIndex = activeIndex + direction
            if newIndex >= 10 {
                activeIndex = 0
            } else if newIndex < 0 {
                activeIndex = 10 - 1
            } else {
                activeIndex = newIndex
            }
        }
    }
    
    /*
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { return }
        defer { DispatchQueue.main.async { self.isCapturing = false } }
        
        // --- 逻辑 A: 处理 RAW (DNG) 数据 ---
        if photo.isRawPhoto {
            if let rawData = photo.fileDataRepresentation() {
                saveImageDataToLibrary(rawData, isRaw: true)
            }
            // 如果是 DNG 模式，处理完 RAW 就可以返回了
            if imageQuality == "DNG" { return }
        }
        
        // --- 逻辑 B: 处理 JPEG/HEVC (带滤镜) 数据 ---
        // 只有当模式包含 JPEG 时才执行以下逻辑
        guard imageQuality != "DNG" else { return }
        
        // 如果当前收到的不是 RAW，说明它是那个需要套滤镜的“预览图”或“压缩图”
        if !photo.isRawPhoto {
            guard let imageData = photo.fileDataRepresentation(),
                  let ciImage = CIImage(data: imageData) else { return }
            
            // 应用滤镜
            let filteredImage = FilmEngine.shared.process(ciImage, styleName: style, lutIntensity: lutIntensity, grainIntensity: grainIntensity)
            let context = CIContext()
            guard let colorSpace = ciImage.colorSpace,
                  let processedData = context.jpegRepresentation(of: filteredImage, colorSpace: colorSpace, options: []) else { return }
            
            saveImageDataToLibrary(processedData, isRaw: false)
        }
        
    }
     */
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { return }
        defer { DispatchQueue.main.async { self.isCapturing = false } }
        
        // --- 逻辑 A: 处理 RAW (DNG) 数据 ---
        if photo.isRawPhoto {
            if let rawData = photo.fileDataRepresentation() {
                saveImageDataToLibrary(rawData, isRaw: true)
            }
            if imageQuality == "DNG" { return }
        }
        
        // --- 逻辑 B: 处理 JPEG (带滤镜) 数据 ---
        guard imageQuality != "DNG" else { return }
        
        if !photo.isRawPhoto {
            guard let imageData = photo.fileDataRepresentation(),
                  let ciImage = CIImage(data: imageData) else { return }
            
            // 1. 应用滤镜处理
            let filteredImage = FilmEngine.shared.process(ciImage, styleName: style, lutIntensity: lutIntensity, grainIntensity: grainIntensity)
            
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
    
    func takePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        
        guard !isShowingTutorial else { return }
        
        if let photoConnection = photoOutput.connection(with: .video) {
            photoConnection.videoOrientation = self.deviceOrientation
        }
        
        // 💡 核心修复：获取当前镜头实例以同步参数
        guard let currentDevice = availableDevices.indices.contains(currentDeviceIndex) ? availableDevices[currentDeviceIndex] : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        
        let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first
        let photoSettings: AVCapturePhotoSettings
        
        if imageQuality == "DNG+J" && rawFormat != nil {
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat!, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else if imageQuality == "DNG" && rawFormat != nil {
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat!)
        } else {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        
        // 💡 核心修复：EXIF信息校正。强制快门优先，防止算法重置快门时长
        photoSettings.photoQualityPrioritization = .speed
        photoSettings.isShutterSoundSuppressionEnabled = true
        
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
        playShutterSound()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
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
        
        // 默认保底值
        return AVCaptureDevice.currentExposureDuration
    }

    func updateExposure() {
        guard let device = availableDevices.indices.contains(currentDeviceIndex) ? availableDevices[currentDeviceIndex] : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        
        do {
            try device.lockForConfiguration()
            
            // 1. 处理曝光补偿 (EV)
            if let evValue = Float(EV) {
                device.setExposureTargetBias(evValue, completionHandler: nil)
            }
            
            let isSSAuto = (SS == "AUTO")
            let isISOAuto = (ISO == "AUTO")
            
            // 2. 核心组合逻辑
            if isSSAuto && isISOAuto {
                // 全自动模式
                device.exposureMode = .continuousAutoExposure
                
            } else if !isSSAuto && !isISOAuto {
                // 全手动模式 (M档)
                let duration = parseShutterSpeed(SS)
                
                // 💡 修复点：先去掉 "ISO " 前缀再转为 Float
                let cleanISO = ISO.replacingOccurrences(of: "ISO ", with: "")
                let isoValue = Float(cleanISO) ?? 100.0
                
                device.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil)
                
            }
            
            device.unlockForConfiguration()
        } catch {
            print("硬件控制失败: \(error)")
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
}

extension Array where Element == String {
    func supportedISO(for device: AVCaptureDevice) -> [String] {
        let maxISO = device.activeFormat.maxISO
        let minISO = device.activeFormat.minISO
        
        return self.filter {
            if $0 == "AUTO" { return true }
            guard let val = Float($0) else { return false }
            return val >= minISO && val <= maxISO
        }
    }
    
    func supportedSS(for device: AVCaptureDevice) -> [String] {
        let minSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxSeconds = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        
        return self.filter {
            if $0 == "AUTO" { return true }
            
            // 💡 修复点：调用一个自定义转换函数，支持处理 "/" 符号
            guard let val = parseShutterSpeedToDouble($0) else { return false }
            
            // 浮点数比较建议加一个极小的余量（epsilon），防止精度误差
            return val >= (minSeconds - 0.00001) && val <= (maxSeconds + 0.00001)
        }
    }
    
    func formattedISOoptions() -> [String] {
        return self.map {
            isoItem in Int(isoItem) != nil ? "ISO \(isoItem)" : isoItem
        }
    }

    // 辅助函数：把 "1/100" 转为 0.01
    private func parseShutterSpeedToDouble(_ string: String) -> Double? {
        if let doubleValue = Double(string) {
            return doubleValue // 处理 "1", "0.8" 等直接数值
        }
        
        // 处理 "1/100" 这种分数格式
        let components = string.components(separatedBy: "/")
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            return numerator / denominator
        }
        
        return nil
    }
}
