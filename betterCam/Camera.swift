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
import WidgetKit

class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    
    private var isRestoring: Bool = false
    
    @AppStorage("doneTheTip") var doneTheTip: Bool = false
    
    private var oldShutterSoundMode: ShutterSoundMode = .sony
    @AppStorage("shutterSoundMode") var shutterSoundMode: ShutterSoundMode = .sony
    
    @Published var currentFocalLength: Int = 26
    
    @Published var enableFrontCamera: Bool = false
    
    let overlayWidth: Int = 128
    let overlayHeight: Int = 64
    
    var device: MTLDevice? = MTLCreateSystemDefaultDevice()
    var commandQueue: MTLCommandQueue?
    var pipelineState: MTLComputePipelineState?
    var textureCache: CVMetalTextureCache?
    
    var histogramComputePipeline: MTLComputePipelineState?
    let histogramRenderPipeline: MTLRenderPipelineState? = nil// 用于将数据画成条形图
    var histogramBuffer: MTLBuffer?
    @Published var histogramImage: CGImage?
        
    @Published var waveformImage: CGImage? // 用于 UI 显示
    
    var maxWidgetIndex: Int {
        return UIWidgets.allCases.map { $0.rawValue }.max() ?? 0
    }
    var nullWidgetIndex: Int {
        return maxWidgetIndex + 1
    }
    private var exposureOffsetObserver: NSKeyValueObservation?
    private var smoothedOffset: Float = 0.0 // 💡 用于平滑存储
    private var lastUpdateTimestamp: TimeInterval = 0
    let sessionQueue = DispatchQueue(label: "com.betterCam.sessionQueue")
    
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
    @Published var grainIntensity: Float = 1.0 // 0.0 到 1.0
    
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
            manageSession()
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
            UserDefaults.standard.set(shutterSoundMode.rawValue, forKey: "shutterSoundMode")
        }
    }
    
    func loadShutterSoundFromStorage() {
        if let savedShutterSoundMode = UserDefaults.standard.string(forKey: "shutterSoundMode") {
            shutterSoundMode = ShutterSoundMode(rawValue: savedShutterSoundMode) ?? .sony
        }
    }
    
    var firstTimeCallingDiscoverCameras: Bool = true
    
    func callAllStartupFuncs() {
        setupMetal()
        setupTextureCache()
        setDefaultResolution()
        checkAllPermissions()
        discoverCameras()
        setupShutterSound()
        setupSession()
        loadShutterSoundFromStorage()
        loadParameterFromStorage()
        setupLightMeter()
        applyResolutionSettings()
        startDeviceMotion()
        syncAllLUTsToOptions()
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
            manageSession()
        }
    }
    
    @Published var isCapturing: Bool = false
    
    // MARK: lens management here!
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var currentDeviceIndex: Int = 0
    
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
    
    private var lastSS: String = "1/200"
    private var lastISO: String = "ISO 100"
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
    
    @AppStorage("enablePermanentParameterStorage") var enablePermanentParameterStorage: Bool = false
    @AppStorage("perferAUTO") var perferAUTO: Bool = false
    @AppStorage("enableColorProfileInRAW") var enableColorProfileInRAW: Bool = false
    
    let prefs = UserDefaults(suiteName: "group.com.rice.betterCam")
    
    func updateParameterToStorage() {
        print("PermanentParameterStorageEnabled?", enablePermanentParameterStorage)
        if enablePermanentParameterStorage {
            print("Wrote parameter to disk!")
            UserDefaults.standard.set(SS, forKey: "SS")
            UserDefaults.standard.set(ISO, forKey: "ISO")
            if let savedISO = UserDefaults.standard.string(forKey: "ISO") {
                print("Saved ISO:", savedISO) // FOR DEBUG
            }
        }
        prefs?.set(SS, forKey: "last_SS")
        prefs?.set(ISO, forKey: "last_ISO")
        let ss = prefs?.string(forKey: "last_SS") ?? "NONE"
        let iso = prefs?.string(forKey: "last_ISO") ?? "NONE"
        print("Saved for Widgets: \(ss) \(iso)")
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    func loadParameterFromStorage() {
        isRestoring = true
        if UserDefaults.standard.bool(forKey: "perferAUTO") {
            self.SS = "AUTO"
            self.ISO = "AUTO"
            prefs?.set(SS, forKey: "last_SS")
            prefs?.set(ISO, forKey: "last_ISO")
            WidgetCenter.shared.reloadAllTimelines()
            isRestoring = false
            return
        }
        if UserDefaults.standard.bool(forKey: "enablePermanentParameterStorage") {
            if let savedSS = UserDefaults.standard.string(forKey: "SS") {
                self.SS = savedSS
            }
            if let savedISO = UserDefaults.standard.string(forKey: "ISO") {
                self.ISO = savedISO
            }
            print("✅ 参数已从磁盘恢复: SS=\(SS), ISO=\(ISO)")
        }
        isRestoring = false
    }
    
    @Published var SS: String = "1/200" {
        didSet {
            guard !isRestoring else { return }
            autoAmode(nowBeingControlled: "SS")
            updateExposure()
            // updateParameterToStorage()
    }
    }
    @Published var Aperture: String = "F1.8"
    @Published var EV: String = "0.0" { didSet { updateExposure() } }
    @Published var ISO: String = "ISO 100" {
        didSet {
            print("ISO changed!")
            guard !isRestoring else { return }
            autoAmode(nowBeingControlled: "ISO")
            updateExposure()
        }
    }
    var styleOptions: [String] = []
    var AFModeOptions: [String] = ["AF-C", "AF-S"]
    @Published var style: String = "STD"
    @Published var imageQuality: String = "JPEG" {
        didSet {
            if imageQuality == "DNG" {
                HDRswitch(false)
            } else {
                HDRswitch(true)
            }
        }
    }
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
    
    let imageQualityOptions: [String] = ["DNG+J", "DNG", "JPEG"]
    
    var ISOoptions: [String] = ParameterAvailable.ISOoptions
    var SSoptions: [String] = ParameterAvailable.SSoptions
    var EVoptions: [String] = ParameterAvailable.EVoptions
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
        
        var tempList: [AVCaptureDevice] = []
        // 如果你只想在特定条件下显示前置，可以在这里过滤
        if enableFrontCamera {
            tempList = discoverySession.devices
        } else {
            // 仅保留后置镜头
            tempList = discoverySession.devices.filter { $0.position == .back }
        }
        
        tempList = discoverySession.devices.filter { $0.position == .back }
        let decorated = tempList.enumerated().map { (offset, device) in
            let focalLength = getFocalLengthByIndex(idx: offset, camList: tempList)
            return (device, focalLength)
        }
        // 2. 排序：基于元组中的焦距进行从小到大排序
        let sortedDecorated = decorated.sorted { $0.1 < $1.1 }
        // 3. 还原：将排序后的设备重新赋值回 tempList
        tempList = sortedDecorated.map { $0.0 }
        if enableFrontCamera {
            print(tempList.indices.contains(currentDeviceIndex + 1))
            
            tempList.insert(contentsOf: discoverySession.devices.filter{ $0.position == .front }, at: 0)
            if tempList.indices.contains(currentDeviceIndex + 1) {
                print("+1")
                currentDeviceIndex += 1
            }
        }
        
        self.availableDevices = tempList
        if firstTimeCallingDiscoverCameras {
            firstTimeCallingDiscoverCameras = false
            for cam in self.availableDevices {
                if cam.deviceType == .builtInWideAngleCamera {
                    currentDeviceIndex = self.availableDevices.firstIndex(of: cam) ?? 0
                }
            }
        }
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
                if !actualISOoptions.contains(ISO) {
                    ISO = actualISOoptions[actualISOoptions.count - 1]
                }
                if !actualSSoptions.contains(SS) {
                    SS = actualSSoptions[actualSSoptions.count - 1]
                }
                updateExposure()
            }
        } catch {
            print("切换失败: \(error)")
        }
        session.commitConfiguration()
        self.setupLightMeter()
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
        // for bar view items
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
    
    
    var videoDevice: AVCaptureDevice?
    private var apertureObserver: NSKeyValueObservation?
    
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
            
            self.session.startRunning()
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
    
    func HDRswitch(_ mode: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard let device = self.availableDevices.indices.contains(self.currentDeviceIndex) ?
                    self.availableDevices[self.currentDeviceIndex] :
                        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            
            do {
                try device.lockForConfiguration()
                if device.activeFormat.isVideoHDRSupported {
                    if device.automaticallyAdjustsVideoHDREnabled {
                        device.automaticallyAdjustsVideoHDREnabled = false
                    }
                    device.isVideoHDREnabled = mode
                }
                device.unlockForConfiguration()
            } catch {
                print("HDR setting failed!")
            }
            print("Now HDR Preview is:", device.isVideoHDREnabled)
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
                //device.focusMode = mode
                
                if device.isFocusModeSupported(mode) {
                    device.focusMode = mode
                } else {
                    print("Unsupported focus mode!")
                }
                
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
                if photoConnection.isVideoMirroringSupported {
                    photoConnection.isVideoMirrored = true // 开启硬件级镜像
                }
            } else {
                if photoConnection.isVideoMirroringSupported {
                    photoConnection.isVideoMirrored = false
                }
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
                
                device.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil) // TODO: Check ISO value
                
            }
            
            device.unlockForConfiguration()
        } catch {
            print("硬件控制失败: \(error)")
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
}
