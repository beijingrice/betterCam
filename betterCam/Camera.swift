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
import UIKit
import Metal
import MetalKit

enum CameraPermissionStatus {
    case undetermined  // 尚未询问
    case authorized    // 已授权
    case denied        // 已拒绝
}

enum UIWidgets: Int, CaseIterable {
    case imageQuality   = 0
    case lensSwitch     = 1
    case AFMode         = 2
    case WBMode         = 3
    case MENU           = 4
    case SS             = 5
    case aperture       = 6
    case EV             = 7
    case ISO            = 8
    case Style          = 9
}

class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    
    enum ExposureMode { case waveform, histogram, off }
    
    enum ShutterSoundMode: String, CaseIterable {
        case sony       = "shutter_eqed_gained"
        case panasonic  = "s1m2_shutter_gained"
    }
    
    private var oldShutterSoundMode: ShutterSoundMode = .sony
    @Published var shutterSoundMode: ShutterSoundMode = .sony
    
    @Published var currentFocalLength: Int = 26
    
    @Published var enableFrontCamera: Bool = false {
        didSet {
            discoverCameras()
        }
    }
    
    let overlayWidth: Int = 128
    let overlayHeight: Int = 64
    
    private var device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    
    private var histogramComputePipeline: MTLComputePipelineState?
    private let histogramRenderPipeline: MTLRenderPipelineState? = nil// 用于将数据画成条形图
    private var histogramBuffer: MTLBuffer?
    @Published var histogramImage: CGImage?
        
    @Published var waveformImage: CGImage? // 用于 UI 显示
    
    private var maxWidgetIndex: Int {
        return UIWidgets.allCases.map { $0.rawValue }.max() ?? 0
    }
    private var nullWidgetIndex: Int {
        return maxWidgetIndex + 1
    }
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
    
    @Published var showingMENU: Bool = false
    
    // 在 Camera 类中添加
    @Published var lutIntensity: Float = 1.0  // 0.0 到 1.0
    @Published var grainIntensity: Float = 0.5 // 0.0 到 1.0
    
    private var previewResolutionOld: String = "HIGH"
    @Published var previewResolution: String = "HIGH" { // Let system decide as a default
        didSet { // check if there's better options
            if previewResolution != previewResolutionOld {
                applyResolutionSettings()
                previewResolutionOld = previewResolution
            }
        }
    }
    
    private var isConfiguring: Bool = false
    
    @Published var exposureIndicatorMode: ExposureMode = .off
    @Published var isShowingMenu = false {
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

    // 定义一个临时的起始值，用于手势计算
    private var startLutIntensity: Float = 0.0
    private var startGrainIntensity: Float = 0.0
    
    private func setupTextureCache() {
        guard let device = device else { return }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }
    
    func changeShutterSound() {
        if oldShutterSoundMode != shutterSoundMode {
            setupShutterSound()
            oldShutterSoundMode = shutterSoundMode
        }
    }
    
    func callAllStartupFuncs() {
        setupMetal()
        setupTextureCache()
        setDefaultResolution()
        checkAllPermissions()
        discoverCameras()
        setupShutterSound()
        setupSession()
        setupLightMeter()
        applyResolutionSettings()
        startDeviceMotion()
        syncAllLUTsToOptions()
        getEquivalentFocalLength()
    }
    
    override init() {
        super.init()
        if hasCompletedTutorial {
            callAllStartupFuncs()
        } else {
            isShowingTutorial = true
        }
    }
    
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
            getEquivalentFocalLength()
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
    
    func getEquivalentFocalLength() {
        guard availableDevices.indices.contains(currentDeviceIndex) else { return }
        let device = availableDevices[currentDeviceIndex]
        
        // 1. 获取原始计算值
        let hFOV = device.activeFormat.videoFieldOfView
        let radians = hFOV * Float.pi / 180.0
        var calculatedEquivalent = 36.0 / (2.0 * tan(radians / 2.0))
        
        if device.deviceType == .builtInUltraWideCamera {
            if Int(round(calculatedEquivalent)) == 14 {
                calculatedEquivalent = 13
            }
        }
        
        // 2. 针对主摄进行硬校准
        // iPhone 主摄在预览流下算出来常为 26.8-27.2，但在全像素下是 24 或 26
        if device.deviceType == .builtInWideAngleCamera {
            // 根据不同机型微调，通常主摄强制归位到 24 或 26 看起来最自然
            if calculatedEquivalent > 23 && calculatedEquivalent < 28 {
                // 这里可以根据你的 iPhone 15/16 Pro 经验，如果是 27 左右就显示 26
                if calculatedEquivalent > 26.5 {
                    calculatedEquivalent = 26
                } else {
                    calculatedEquivalent = 24
                }
            }
        }
        
        // 3. 针对长焦 (Telephoto)
        // 长焦常算出来是 78，系统显示 77；或算出来 122，系统显示 120
        if device.deviceType == .builtInTelephotoCamera {
            if calculatedEquivalent > 70 && calculatedEquivalent < 80 { calculatedEquivalent = 72 }
            if calculatedEquivalent > 110 && calculatedEquivalent < 125 { calculatedEquivalent = 120 }
        }
        
        self.currentFocalLength = Int(round(calculatedEquivalent))
    }

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
        // 将 position 设置为 .unspecified 可以搜索到所有方向的镜头
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
            ],
            mediaType: .video,
            position: .unspecified // 💡 修改点：允许前置和后置
        )
        
        // 如果你只想在特定条件下显示前置，可以在这里过滤
        if enableFrontCamera {
            self.availableDevices = discoverySession.devices
        } else {
            // 仅保留后置镜头
            self.availableDevices = discoverySession.devices.filter { $0.position == .back }
        }
        print("Available camera counts:", self.availableDevices.count)
    }
    
    func switchCamera(direction: Int) {
        guard availableDevices.count > 1 else { return }
        if currentDeviceIndex + direction >= 0 {
            print("In branch 1")
            print(currentDeviceIndex, "->", (currentDeviceIndex + direction) % availableDevices.count)
            currentDeviceIndex = (currentDeviceIndex + direction) % availableDevices.count
        } else {
            print("In branch 2")
            print(currentDeviceIndex, "->", availableDevices.count - 1)
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
                self.actualSSoptions = self.SSoptions.supportedSS(for: newDevice)
                self.actualISOoptions = self.ISOoptions.supportedISO(for: newDevice).formattedISOoptions()
                updateExposure()
            }
        } catch {
            print("切换失败: \(error)")
        }
        session.commitConfiguration()
        self.updateApertureInfo()
    }
    
    func applyResolutionSettings() {
        guard !isConfiguring else { return }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.isConfiguring = true
            
            let preset: AVCaptureSession.Preset = (self.previewResolution == "LOW") ? .vga640x480 : .photo
            
            if self.session.sessionPreset != preset {
                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(preset) {
                    self.session.sessionPreset = preset
                }
                self.session.commitConfiguration()
                
                // 💡 给硬件一点点“呼吸”时间再解锁
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            self.isConfiguring = false
        }
    }
    
    func toggleAdjustmentMode() {
        // 1. 切换模式
        if activeIndex != nullWidgetIndex && activeIndex != UIWidgets.Style.rawValue {
            isAdjustingValue.toggle()
        }
        
        if activeIndex == UIWidgets.Style.rawValue {
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
        
        if activeIndex == UIWidgets.MENU.rawValue {
            if !isAdjustingValue {
                isAdjustingValue = true
            } else {
                isShowingMenu = true
                isAdjustingValue = false
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
    
    func setupSession() {
        guard !availableDevices.isEmpty else { return }
        session.beginConfiguration()
        
        // 💡 确保分辨率设置已经进入队列
        self.applyResolutionSettings()
        
        // 移除 defer 中的 commit，改为在末尾手动 commit 更好控制顺序
        
        guard let videoDevice = availableDevices[currentDeviceIndex] ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoDeviceInput) else {
            session.commitConfiguration()
            return
        }
        
        session.addInput(videoDeviceInput)
        
        // 💡 移除这里直接对 self.Aperture 的赋值，统一由 updateApertureInfo 处理
        
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
        
        // 💡 重点修改：整合启动与光圈更新
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 1. 开启 Session
            self.session.startRunning()
            
            // 2. 检查 Session 是否成功运行
            if self.session.isRunning {
                // 💡 3. 延迟 0.1-0.2 秒读取。这是针对 iPhone 16/17 Pro 处理延迟的“玄学补丁”
                // 此时硬件已经开始输出预览流，寄存器里的光圈值已经更新
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.updateApertureInfo()
                }
            }
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        switch exposureIndicatorMode {
            case .waveform:
                self.processWaveform(from: pixelBuffer)
                if histogramImage != nil { DispatchQueue.main.async { self.histogramImage = nil } }
            case .histogram:
                self.processHistogram(from: pixelBuffer)
                if waveformImage != nil { DispatchQueue.main.async { self.waveformImage = nil } }
            case .off:
                // 模式关闭时，确保清空图片引用，释放内存
                if waveformImage != nil || histogramImage != nil {
                    DispatchQueue.main.async {
                        self.waveformImage = nil
                        self.histogramImage = nil
                    }
                }
            }
        
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        

        if let videoDevice = availableDevices.indices.contains(currentDeviceIndex) ? availableDevices[currentDeviceIndex] : nil,
           videoDevice.position == .front {
            
            // 1. 先将图像移回 (0,0) 原点，防止 extent 偏移干扰翻转
            let originTransform = CGAffineTransform(translationX: -ciImage.extent.origin.x, y: -ciImage.extent.origin.y)
            var correctedImage = ciImage.transformed(by: originTransform)
            
            // 2. 💡 执行镜像：翻转 X 轴并平移回显示区域
            let mirrorTransform = CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: -correctedImage.extent.width, y: 0)
            
            ciImage = correctedImage.transformed(by: mirrorTransform)
        }
        
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
        // 1. 彻底销毁旧 ID，防止资源占用
        if shutterSoundID != 0 {
            AudioServicesDisposeSystemSoundID(shutterSoundID)
            shutterSoundID = 0
        }
        
        // 2. 这里的 shutterSoundMode.rawValue 应该对应你工程里的文件名
        let fileName = shutterSoundMode.rawValue
        print(fileName)
        
        // 💡 调试打印：如果你在切换到 2 时静音，控制台会显示路径是否为空
        guard let soundURL = Bundle.main.url(forResource: fileName, withExtension: "aac") else {
            print("❌ 错误：找不到音频文件: \(fileName).aac")
            return
        }
        
        // 3. 重新创建 SoundID
        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(soundURL as CFURL, &soundID)
        
        if status == kAudioServicesNoError {
            self.shutterSoundID = soundID
            print("✅ 成功加载快门音: \(fileName)")
        } else {
            print("❌ 无法创建 SystemSoundID，状态码: \(status)")
        }
    }
    
    func playShutterSound() {
        if shutterSoundID != 0 {
            AudioServicesPlaySystemSound(shutterSoundID)
        }
    }
     
    private func adjustValue(direction: Int) {
        switch activeIndex {
        case UIWidgets.AFMode.rawValue:
            AFMode = nextOption(in: AFModeOptions, current: AFMode, direction: direction)
        case UIWidgets.Style.rawValue: // STYLE
            style = nextOption(in: styleOptions, current: style, direction: direction)
        case UIWidgets.SS.rawValue: // SS
            SS = nextOption(in: actualSSoptions, current: SS, direction: direction)
        case UIWidgets.EV.rawValue: // EV
            let isManualMode = (SS != "AUTO" && ISO != "AUTO")
            if !isManualMode {
                EV = nextOption(in: EVoptions, current: EV, direction: direction)
            }
        case UIWidgets.ISO.rawValue: // ISO
            ISO = nextOption(in: actualISOoptions, current: ISO, direction: direction)
        case UIWidgets.lensSwitch.rawValue: switchCamera(direction: direction)
        case UIWidgets.imageQuality.rawValue: // Image Quality
            imageQuality = nextOption(in: imageQualityOptions, current: imageQuality, direction: direction)
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
        /*
         activeIndex: 0...maxWidgetIndex + 1
         0...maxWidgetIndex: parameters
         maxWidgetIndex + 1: nothing selected
         maxWidgetIndex + 2: will be never reached, just for condition check
         */
        
        if isAdjustingValue {
            adjustValue(direction: direction)
        } else {
            let newIndex = activeIndex + direction
            if newIndex >= maxWidgetIndex + 2 { // direction = positive
                activeIndex = 0
            } else if newIndex < 0 { // direction = negative
                activeIndex = maxWidgetIndex + 1 // go to nothing selected index
            } else {
                activeIndex = newIndex
            }
        }
    }
    
    /// 💡 读取当前镜头的光圈值并更新 UI 绑定变量
    func updateApertureInfo() {
        // 必须在 sessionQueue 中执行，避免与 session 配置产生死锁
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 获取当前正在使用的物理设备
            guard self.availableDevices.indices.contains(self.currentDeviceIndex) else { return }
            let device = self.availableDevices[self.currentDeviceIndex]
            
            do {
                // 💡 关键：iOS 26 的 Pro 机型通常需要 lock 状态才能读取某些实时硬件参数
                try device.lockForConfiguration()
                
                // 尝试读取实时值
                let aperture = device.lensAperture
                
                // 💡 保底逻辑：如果实时值为 0，则读取该镜头支持的最大光圈元数据
                let finalAperture = aperture > 0 ? aperture : (device.lensAperture > 0 ? device.lensAperture : 1.8)
                
                // 回到主线程更新 @Published 变量以刷新 UI
                DispatchQueue.main.async {
                    self.Aperture = String(format: "F%.1f", finalAperture)
                }
                
                device.unlockForConfiguration()
            } catch {
                print("❌ 无法锁定设备以读取光圈: \(error)")
            }
        }
    }
    
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
                  var ciImage = CIImage(data: imageData) else { return }
            
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
        
        if let photoConnection = photoOutput.connection(with: .video) {
            if let videoDevice = availableDevices.indices.contains(currentDeviceIndex) ? availableDevices[currentDeviceIndex] : nil,
               videoDevice.position == .front {
                photoConnection.isVideoMirrored = true // 开启硬件级镜像
            } else {
                photoConnection.isVideoMirrored = false
            }
        }
        
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

extension UIDevice {
    // 💡 获取硬件标识符（如 "iPhone15,3"）
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}

enum DevicePerformanceTier {
    case pro      // iPhone 15 Pro 及以上：支持 4K/ProRes 实时预览
    case high     // iPhone 13 - 14 系列：稳定 4K
    case standard // 旧款设备：建议默认 1080P 以维持帧率
}

extension Camera {
    // MARK: - Metal Setup
    func setupMetal() {
        guard let device = device else { return }
        commandQueue = device.makeCommandQueue()
        let library = device.makeDefaultLibrary()
        
        // 初始化 Waveform 管线
        if let kernel = library?.makeFunction(name: "waveformKernel") {
            pipelineState = try? device.makeComputePipelineState(function: kernel)
        }
        
        // 初始化 Histogram 计算管线
        if let histKernel = library?.makeFunction(name: "histogram_compute") {
            histogramComputePipeline = try! device.makeComputePipelineState(function: histKernel)
        }
        
        // 初始化直方图 Buffer (256个等级)
        histogramBuffer = device.makeBuffer(length: 256 * MemoryLayout<UInt32>.stride, options: .storageModeShared)
    }

    // MARK: - Waveform Process
    func processWaveform(from pixelBuffer: CVPixelBuffer) {
        guard exposureIndicatorMode == .waveform,
              let pipeline = pipelineState,
              let queue = commandQueue,
              let cache = textureCache else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let inputTexture = CVMetalTextureGetTexture(cvTexture!) else { return }
        
        // 输出纹理强制设为 128x64
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: overlayWidth, height: overlayHeight, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        guard let outputTexture = device?.makeTexture(descriptor: desc) else { return }
        
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(width: (outputTexture.width + 15) / 16,
                                   height: (outputTexture.height + 15) / 16,
                                   depth: 1)
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            let cgImage = self.makeCGImage(from: outputTexture)
            DispatchQueue.main.async {
                self.waveformImage = cgImage
            }
        }
        commandBuffer.commit()
    }

    // MARK: - Histogram Process
    func processHistogram(from pixelBuffer: CVPixelBuffer) {
        guard exposureIndicatorMode == .histogram,
              let pipeline = histogramComputePipeline,
              let queue = commandQueue,
              let cache = textureCache,
              let hBuffer = histogramBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let inputTexture = CVMetalTextureGetTexture(cvTexture!) else { return }

        // 重置统计数据
        memset(hBuffer.contents(), 0, hBuffer.length)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setBuffer(hBuffer, offset: 0, index: 0)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let gridSize = MTLSize(width: (inputTexture.width + w - 1) / w,
                               height: (inputTexture.height + h - 1) / h,
                               depth: 1)

        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.renderHistogramUI()
        }
        commandBuffer.commit()
    }

    private func renderHistogramUI() {
        guard let buffer = histogramBuffer else { return }
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: 256)
        
        var maxCount: Float = 1.0
        for i in 0..<256 { maxCount = max(maxCount, Float(ptr[i])) }

        // 适配 128x64 规格
        let size = CGSize(width: CGFloat(overlayWidth), height: CGFloat(overlayHeight))
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            
            // 💡 优化：256 bins 对应 128 像素，每像素合并 2 bins
            let binsPerPixel = 2
            
            for x in 0..<overlayWidth {
                let binIndex = x * binsPerPixel
                // 取两个相邻 bin 的平均值保证曲线平滑
                let count = Float(ptr[binIndex] + ptr[binIndex + 1]) / 2.0
                let barHeight = CGFloat(count / maxCount) * size.height
                
                ctx.fill(CGRect(x: CGFloat(x), y: size.height - barHeight, width: 1.0, height: barHeight))
            }
        }

        DispatchQueue.main.async {
            self.histogramImage = image.cgImage
        }
    }

    // MARK: - Helpers
    func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let rowBytes = width * 4
        var data = [UInt8](repeating: 0, count: rowBytes * height)
        
        texture.getBytes(&data, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    
    // MARK: - Performance & Resolution
    var performanceTier: DevicePerformanceTier {
        let id = UIDevice.current.modelIdentifier
        let scanner = Scanner(string: id)
        _ = scanner.scanUpToCharacters(from: .decimalDigits)
        let modelMajorVersion = scanner.scanInt() ?? 0
        
        if modelMajorVersion >= 17 { return .pro }
        else if modelMajorVersion >= 15 { return .high }
        else { return .standard }
    }
        
    func setDefaultResolution() {
        switch performanceTier {
        case .pro, .high: self.previewResolution = "HIGH"
        case .standard: self.previewResolution = "LOW"
        }
    }
}
