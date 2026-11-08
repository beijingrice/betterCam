import Foundation
import AVFoundation
import SwiftUI
import Combine
import UIKit

class Camera: NSObject, ObservableObject {
    // MARK: - 相机模块
    @Published var lensManager = LensManager()
    @Published var parameterManager = ParameterManager()
    var sessionManager = SessionManager()
    var shutterSoundManager = ShutterSoundManager()
    var permissionManager = PermissionManager()
    var motionManager = MotionManager() // 💡 新加入的陀螺仪管家
    
    @Published var currentPreviewImage: CGImage?
    
    private var hasConfiguredSession = false
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - UI 交互状态
    @Published var activeIndex: Int = 0
    @Published var isAdjustingValue: Bool = false
    @Published var exposureIndicatorMode: ExposureMode = .off {
        didSet {
            MetalWHProcessor.shared.setMode(exposureIndicatorMode)
        }
    }
    // Camera App Status
    
    @Published var isSensorBusy: Bool = false
    @Published var inFlightPhotos: Int = 0
    @Published var is24MPSupported: Bool = false
    @Published var is48MPSupported: Bool = false
    @Published var isProRAWSupported: Bool = false
    @Published var lastCaptureResolution: String?
    var availableImageQualityOptions: [String] {
        parameterManager.imageQualityOptions.filter {
            $0 != "ProRAW" || isProRAWSupported
        }
    }
    var isManualExposureActive: Bool {
        parameterManager.SS != ExposureParameter.auto &&
        parameterManager.ISO != ExposureParameter.auto
    }
    var shouldEnableVideoHDRForPreview: Bool {
        !isManualExposureActive &&
        !parameterManager.isPureRawEngineEnabled &&
        parameterManager.imageQuality != "DNG"
    }
    var maxBufferCount: Int {
        parameterManager.photoResolutionMode == .high48MP ? 1 : 3
    }
    @Published var isShowingMenu = false { didSet { manageSession() } }
    @Published var inCameraView: Bool = true { didSet { manageSession() } }
    @AppStorage("doneTheTip") var doneTheTip: Bool = false
    @AppStorage("hasCompletedTutorial") var hasCompletedTutorial: Bool = false
    @Published var isShowingTutorial: Bool = false
    
    @Published var isSwitchingLens: Bool = false // Blur the lens when switching
    
    // 特效参数
    @Published var lutIntensity: Float = 1.0
    @Published var grainIntensity: Float = 1.0
    
    var maxWidgetIndex: Int { UIWidgets.allCases.map { $0.rawValue }.max() ?? 0 }
    var nullWidgetIndex: Int { maxWidgetIndex + 1 }
    
    override init() {
        super.init()
        sessionManager.delegate = self // pass camera instance to sessionManager
        
        if hasCompletedTutorial {
            startCamera()
        } else {
            isShowingTutorial = true
        }
    }
    
    func startCamera() {
        motionManager.start()
        shutterSoundManager.setupSound(named: parameterManager.shutterSoundSelection.rawValue)
        
        if let lens = lensManager.currentLens {
            configureInitialLens(lens)
        }

        bindLensSelection()
        bindExposureControls()
        bindCaptureSettings()
        bindFocusAndSound()
    }
    
    private func configureInitialLens(_ lens: Lens) {
        permissionManager.checkAllPermissions()
        hasConfiguredSession = true
        sessionManager.initSession(with: lens)
        updateUIWithLens(lens)
    }

    private func bindLensSelection() {
        // 💡 监听镜头切换 -> 换硬件输入 + 自动刷新光圈/焦距
        lensManager.$currentLens
            .dropFirst() // 忽略 App 启动时的第一次通知，因为 startCamera 已处理
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main) // 💡 核心防抖：用户停下轮子 0.3 秒后才放行！
            .sink { [weak self] newLens in
                guard let self, let newLens else { return }

                if !self.hasConfiguredSession {
                    self.configureInitialLens(newLens)
                    return
                }
                if self.sessionManager.isUsingDevice(newLens.device) {
                    self.updateUIWithLens(newLens)
                    return
                }
                
                // 1. 瞬间开启模糊过场
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.isSwitchingLens = true
                }
                
                // 2. 真正执行重负荷的底层硬件切换
                self.sessionManager.switchInput(to: newLens.device)
                self.updateUIWithLens(newLens)
                
                // 3. 硬件准备好后，撤销模糊
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.isSwitchingLens = false
                    }
                }
            }
            .store(in: &cancellables)
            
    }

    private func bindExposureControls() {
        // 监听参数拨盘 (SS / ISO) 触发更新曝光
        Publishers.CombineLatest(parameterManager.$SS, parameterManager.$ISO)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self, self.lensManager.currentLens != nil else { return }
                self.sessionManager.updateExposure()
                self.updatePreviewHDR()
                self.sessionManager.preparePhotoPipeline(
                    resolutionMode: self.parameterManager.photoResolutionMode,
                    imageQuality: self.parameterManager.imageQuality,
                    usesManualExposure: self.isManualExposureActive
                )
            }
            .store(in: &cancellables)
        
        // 💡 手动模式下 EV 是测光显示，不反向触发硬件曝光更新
        parameterManager.$EV
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.parameterManager.SS == ExposureParameter.auto || self.parameterManager.ISO == ExposureParameter.auto {
                    self.sessionManager.updateExposure()
                }
            }
            .store(in: &cancellables)
            
    }

    private func bindCaptureSettings() {
        parameterManager.$imageQuality
            .sink { [weak self] q in
                guard let self = self else { return }

                if q == "ProRAW" && !self.isProRAWSupported {
                    self.parameterManager.imageQuality = "JPEG"
                    return
                }

                self.updatePreviewHDR()

                if self.parameterManager.photoResolutionMode == .high48MP,
                   q != "JPEG" && q != "ProRAW" {
                    self.parameterManager.photoResolutionMode = .standard
                } else if self.parameterManager.photoResolutionMode == .high48MP {
                    self.sessionManager.preparePhotoPipeline(
                        resolutionMode: .high48MP,
                        imageQuality: q,
                        usesManualExposure: self.isManualExposureActive
                    )
                }
            }
            .store(in: &cancellables)

        parameterManager.$photoResolutionMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in
                guard let self = self else { return }

                if mode == .high48MP {
                    guard self.is48MPSupported else {
                        self.parameterManager.photoResolutionMode = .standard
                        return
                    }

                    self.parameterManager.isPureRawEngineEnabled = false
                    if self.parameterManager.imageQuality != "JPEG" &&
                        self.parameterManager.imageQuality != "ProRAW" {
                        self.parameterManager.imageQuality = "JPEG"
                    }
                }

                self.sessionManager.preparePhotoPipeline(
                    resolutionMode: self.parameterManager.photoResolutionMode,
                    imageQuality: self.parameterManager.imageQuality,
                    usesManualExposure: self.isManualExposureActive
                )
            }
            .store(in: &cancellables)

        parameterManager.$isPureRawEngineEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self = self else { return }

                if enabled && self.parameterManager.photoResolutionMode == .high48MP {
                    self.parameterManager.photoResolutionMode = .standard
                }

                // Apple ProRAW includes Apple's computational pipeline, so it cannot
                // represent the app's Bayer RAW zero-processing path.
                if enabled && self.parameterManager.imageQuality == "ProRAW" {
                    self.parameterManager.imageQuality = "DNG+J"
                }

                self.updatePreviewHDR()
            }
            .store(in: &cancellables)
            
    }

    private func updatePreviewHDR() {
        guard let device = lensManager.currentLens?.device else { return }
        sessionManager.HDRswitch(shouldEnableVideoHDRForPreview, device: device)
    }

    private func bindFocusAndSound() {
        parameterManager.$AFMode
            .sink { [weak self] mode in
                guard let dev = self?.lensManager.currentLens?.device else { return }
                self?.sessionManager.focusModify(mode: mode == "AF-S" ? .locked : .continuousAutoFocus, device: dev)
            }
            .store(in: &cancellables)
        
        parameterManager.$shutterSoundSelection
            .syncChange(on: self) { [weak self] newSound in
                self?.shutterSoundManager.setupSound(named: newSound.rawValue)
                self?.parameterManager.saveExposureParameters()
            }
            .store(in: &cancellables)
    }
    
    func refreshLensCapabilities() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.refreshLensCapabilities()
            }
            return
        }
        
        guard var lens = lensManager.currentLens else { return }
        lens.refreshCapabilities()
        lensManager.currentLens = lens
        if let index = lensManager.physicalLenses.firstIndex(where: { $0.device.uniqueID == lens.device.uniqueID }) {
            lensManager.physicalLenses[index] = lens
        }
        updateUIWithLens(lens)
    }
    
    // 💡 一个辅助函数，把镜头的物理属性传递给参数管家
    private func updateUIWithLens(_ lens: Lens) {
        parameterManager.actualSSoptions = lens.availableSSoptions
        parameterManager.actualISOoptions = lens.availableISOoptions
        parameterManager.Aperture = lens.aperture
        parameterManager.currentFocalLength = lens.equivalentFocalLength
        parameterManager.validateExposureOptions()
    }
    
    // MARK: - 交互操作
    func takePhoto() {
        guard let lens = lensManager.currentLens, !isSensorBusy && inFlightPhotos < maxBufferCount && !isShowingTutorial else { return }
        isSensorBusy = true
        inFlightPhotos += 1

        let manualDuration = isManualExposureActive
            ? ExposureParameter.clampedDuration(
                ExposureParameter.shutterDuration(parameterManager.SS) ?? lens.device.exposureDuration,
                for: lens
            )
            : nil
        let manualISO = isManualExposureActive
            ? ExposureParameter.clampedISO(
                ExposureParameter.isoValue(parameterManager.ISO) ?? lens.minISO,
                for: lens
            )
            : nil
        
        let request = PhotoCaptureRequest(
            imageQuality: parameterManager.imageQuality,
            resolutionMode: parameterManager.photoResolutionMode,
            isFrontCamera: lens.device.position == .front,
            usePureRawEngine: parameterManager.isPureRawEngineEnabled,
            styleName: parameterManager.style,
            lutIntensity: lutIntensity,
            grainIntensity: grainIntensity,
            usesManualExposure: isManualExposureActive,
            manualExposureDuration: manualDuration,
            manualISO: manualISO
        )
        sessionManager.capturePhoto(
            orientation: motionManager.deviceOrientation,
            request: request
        )
        shutterSoundManager.play()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
    
    func focus(at point: CGPoint) {
        guard let device = lensManager.currentLens?.device else { return }
        sessionManager.focus(at: point, afMode: parameterManager.AFMode, device: device)
    }
    
    func toggleAdjustmentMode() {
        if activeIndex != nullWidgetIndex && activeIndex != UIWidgets.Style.rawValue { isAdjustingValue.toggle() }
        if activeIndex == UIWidgets.Style.rawValue {
            isAdjustingValue = !isAdjustingValue
            if parameterManager.style == "MANAGE" && !isAdjustingValue { inCameraView = false }
        }
        if activeIndex == UIWidgets.MENU.rawValue {
            if !isAdjustingValue { isAdjustingValue = true }
            else { isShowingMenu = true; isAdjustingValue = false }
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
    
    func manageSession() {
        guard lensManager.currentLens != nil else { return }
        if !inCameraView || isShowingMenu { sessionManager.stop() }
        else { sessionManager.start() }
    }
}
