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
    
    private var hasConfiguredSession = false
    /// The capture session is built only after camera access is granted.
    private var hasStartedSession = false
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - UI 交互状态
    @Published var activeIndex: Int = 0 {
        didSet { if activeIndex != oldValue { isEditingCustomKelvin = false } }
    }
    @Published var isAdjustingValue: Bool = false {
        didSet { if !isAdjustingValue { isEditingCustomKelvin = false } }
    }
    /// The WB dial is on CUSTOM and turning it changes the colour temperature.
    /// Leaving the WB control any other way keeps the temperature reached so far.
    @Published var isEditingCustomKelvin: Bool = false
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
    var availableCaptureModes: [CaptureMode] {
        CaptureMode.available(
            proRAWSupported: isProRAWSupported,
            highResolutionSupported: is48MPSupported,
            zeroProcessing: parameterManager.isPureRawEngineEnabled
        )
    }
    var currentCaptureMode: CaptureMode {
        CaptureMode(quality: parameterManager.imageQuality, resolution: parameterManager.photoResolutionMode)
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        // The quality and resolution observers correct each other's invalid pairs.
        // Leave 48MP before switching to a RAW format, and pick the format before 48MP.
        if mode.resolution == .high48MP {
            parameterManager.imageQuality = mode.quality
            parameterManager.photoResolutionMode = mode.resolution
        } else {
            parameterManager.photoResolutionMode = mode.resolution
            parameterManager.imageQuality = mode.quality
        }
    }
    var isManualExposureActive: Bool {
        parameterManager.SS != ExposureParameter.auto &&
        parameterManager.ISO != ExposureParameter.auto
    }
    var maxBufferCount: Int {
        parameterManager.photoResolutionMode == .high48MP ? 1 : 3
    }
    @Published var isShowingMenu = false { didSet { manageSession() } }
    @Published var inCameraView: Bool = true { didSet { manageSession() } }
    var isCameraScreenVisible: Bool { inCameraView && !isShowingMenu }
    private var pendingSessionStop: DispatchWorkItem?
    private let selectFeedback = UIImpactFeedbackGenerator(style: .heavy)
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

        // Views read access state through the camera, so republish its changes.
        permissionManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Access granted in Settings while the app was in the background.
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let self, self.hasConfiguredSession else { return }
                self.permissionManager.refresh()
                self.startSessionIfAuthorized()
            }
            .store(in: &cancellables)
        
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
        bindWhiteBalance()
        bindCaptureSettings()
        bindFilmLook()
        bindFocusAndSound()
    }
    
    private func configureInitialLens(_ lens: Lens) {
        hasConfiguredSession = true
        updateUIWithLens(lens)
        // Building the session before access is granted left it without an input on a
        // fresh install, and nothing rebuilt it after the prompt.
        Task { @MainActor [weak self] in
            await self?.permissionManager.requestAll()
            self?.startSessionIfAuthorized()
        }
    }

    private func startSessionIfAuthorized() {
        guard !hasStartedSession, permissionManager.cameraPermission == .authorized,
              let lens = lensManager.currentLens else { return }
        hasStartedSession = true
        sessionManager.initSession(with: lens)
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
                self.updatePreviewHDR()
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

    private func bindWhiteBalance() {
        Publishers.CombineLatest(parameterManager.$WBMode, parameterManager.$customKelvin)
            .removeDuplicates { $0 == $1 }
            // @Published fires before the property changes, so use the delivered values;
            // reading parameterManager here would apply the previous dial position.
            .sink { [weak self] mode, kelvin in
                self?.applyWhiteBalance(WhiteBalance.kelvin(for: mode, customKelvin: kelvin))
            }
            .store(in: &cancellables)
    }

    var whiteBalanceKelvin: Int? {
        WhiteBalance.kelvin(for: parameterManager.WBMode, customKelvin: parameterManager.customKelvin)
    }

    /// White balance gains are per device, so this also runs after every lens change.
    private func applyWhiteBalance(_ kelvin: Int?) {
        guard let device = lensManager.currentLens?.device else { return }
        sessionManager.updateWhiteBalance(kelvin: kelvin, device: device)
    }

    private func bindCaptureSettings() {
        // Keep the photo output prepared for whatever the next shot will be. Debounced so a
        // chain of corrections (e.g. 48MP forcing JPEG) prepares only the final state.
        Publishers.CombineLatest4(
            parameterManager.$imageQuality,
            parameterManager.$photoResolutionMode,
            parameterManager.$isPureRawEngineEnabled,
            Publishers.CombineLatest(parameterManager.$SS, parameterManager.$ISO)
        )
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] quality, resolution, pureRaw, exposure in
            guard let self else { return }
            // A saved state from an older version can pair ZERO PROCESSING with ProRAW or
            // 48MP, which the dial no longer offers. The corrected value re-triggers this.
            if pureRaw && quality == "ProRAW" {
                self.parameterManager.imageQuality = "DNG+J"
                return
            }
            if pureRaw && resolution == .high48MP {
                self.parameterManager.photoResolutionMode = .standard
                return
            }
            self.sessionManager.preparePhotoPipeline(
                resolutionMode: resolution,
                imageQuality: quality,
                usePureRawEngine: pureRaw,
                usesManualExposure: exposure.0 != ExposureParameter.auto && exposure.1 != ExposureParameter.auto
            )
        }
        .store(in: &cancellables)

        parameterManager.$imageQuality
            .sink { [weak self] q in
                guard let self = self else { return }

                if q == "ProRAW" && !self.isProRAWSupported {
                    self.parameterManager.imageQuality = "JPEG"
                    return
                }

                self.updatePreviewHDR(quality: q)

                if self.parameterManager.photoResolutionMode == .high48MP,
                   q != "JPEG" && q != "ProRAW" {
                    self.parameterManager.photoResolutionMode = .standard
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

                self.updatePreviewHDR(usesRAWDeveloper: enabled)
            }
            .store(in: &cancellables)
            
    }

    private func updatePreviewHDR(quality: String? = nil, usesRAWDeveloper: Bool? = nil) {
        guard let device = lensManager.currentLens?.device else { return }
        let enablesHDR = !isManualExposureActive &&
            !(usesRAWDeveloper ?? parameterManager.isPureRawEngineEnabled) &&
            ParameterManager.savesJPEG(quality: quality ?? parameterManager.imageQuality)
        sessionManager.HDRswitch(enablesHDR, device: device)
    }

    private func bindFilmLook() {
        let engine = FilmEngine.shared
        let controls = Publishers.CombineLatest4(
            parameterManager.$style, parameterManager.$imageQuality, $lutIntensity, $grainIntensity
        )
        Publishers.CombineLatest(controls, engine.$availableSimulations)
            .sink { [weak self] update in
                let ((style, quality, color, grain), simulations) = update
                self?.sessionManager.previewFrames.update(look: FilmRenderSettings(
                    style: simulations.first(where: { $0.name == style }),
                    colorAmount: color, grainAmount: grain,
                    appliesLook: ParameterManager.savesJPEG(quality: quality)
                ))
            }
            .store(in: &cancellables)
    }

    var canAdjustFilmLook: Bool {
        ParameterManager.savesJPEG(quality: parameterManager.imageQuality) &&
        parameterManager.style != FilmEngine.standardName &&
        parameterManager.style != FilmEngine.manageName
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
        applyWhiteBalance(whiteBalanceKelvin)
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
        // The camera screen stays mounted under the menu, so its shutter controls still
        // exist there; the session is stopped behind it.
        guard let lens = lensManager.currentLens, !isSensorBusy && inFlightPhotos < maxBufferCount && !isShowingTutorial,
              isCameraScreenVisible else { return }
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
            look: FilmEngine.shared.settings(
                styleName: parameterManager.style, colorAmount: lutIntensity, grainAmount: grainIntensity,
                appliesLook: ParameterManager.savesJPEG(quality: parameterManager.imageQuality)
            ),
            usesManualExposure: isManualExposureActive,
            manualExposureDuration: manualDuration,
            manualISO: manualISO,
            whiteBalanceKelvin: whiteBalanceKelvin
        )
        sessionManager.capturePhoto(
            orientation: motionManager.deviceOrientation,
            request: request
        )
        shutterSoundManager.play()
        selectFeedback.impactOccurred()
    }
    
    func focus(at point: CGPoint) {
        guard let device = lensManager.currentLens?.device else { return }
        sessionManager.focus(at: point, afMode: parameterManager.AFMode, device: device)
    }
    
    func toggleAdjustmentMode() {
        switch activeIndex {
        case nullWidgetIndex:
            break
        case UIWidgets.Style.rawValue:
            isAdjustingValue.toggle()
            if parameterManager.style == "MANAGE" && !isAdjustingValue { inCameraView = false }
        case UIWidgets.MENU.rawValue:
            if !isAdjustingValue { isAdjustingValue = true }
            else { isShowingMenu = true; isAdjustingValue = false }
        case UIWidgets.WBMode.rawValue:
            toggleWhiteBalanceAdjustment()
        default:
            isAdjustingValue.toggle()
        }
        selectFeedback.impactOccurred()
    }

    /// Centre button on WB: enter the list → on CUSTOM, edit the temperature → confirm
    /// back to the list (showing CUSTOM) → leave.
    private func toggleWhiteBalanceAdjustment() {
        if !isAdjustingValue {
            isAdjustingValue = true
        } else if isEditingCustomKelvin {
            isEditingCustomKelvin = false
        } else if parameterManager.WBMode == WhiteBalance.custom {
            isEditingCustomKelvin = true
        } else {
            isAdjustingValue = false
        }
    }
    
    func manageSession() {
        guard lensManager.currentLens != nil else { return }
        pendingSessionStop?.cancel()
        pendingSessionStop = nil
        if isCameraScreenVisible {
            sessionManager.start()
        } else {
            // Powering the camera down mid-transition competes with the animation. Wait
            // until it has finished; reopening the camera before then cancels the stop.
            let stop = DispatchWorkItem { [weak self] in self?.sessionManager.stop() }
            pendingSessionStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: stop)
        }
    }
}
