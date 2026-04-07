import Foundation
import AVFoundation
import SwiftUI
import Combine
import UIKit

class Camera: NSObject, ObservableObject {
    // MARK: - 核心模块注入 (所有打工仔)
    @Published var lensManager = LensManager()
    @Published var parameterManager = ParameterManager()
    var sessionManager = SessionManager()
    var shutterSoundManager = ShutterSoundManager()
    var permissionManager = PermissionManager()
    var motionManager = MotionManager() // 💡 新加入的陀螺仪管家
    
    @Published var currentPreviewImage: CGImage?
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - UI 交互状态
    @Published var activeIndex: Int = 0
    @Published var isAdjustingValue: Bool = false
    @Published var exposureIndicatorMode: ExposureMode = .off {
        didSet {
            MetalWHProcessor.shared.exposureIndicatorMode = self.exposureIndicatorMode
            DispatchQueue.main.async {
                if self.exposureIndicatorMode == .waveform {
                    MetalWHProcessor.shared.histogramImage = nil
                } else if self.exposureIndicatorMode == .histogram {
                    MetalWHProcessor.shared.waveformImage = nil
                } else {
                    MetalWHProcessor.shared.waveformImage = nil
                    MetalWHProcessor.shared.histogramImage = nil
                }
            }
        }
    }
    @Published var isCapturing: Bool = false
    @Published var isShowingMenu = false { didSet { manageSession() } }
    @Published var showingMENU: Bool = false
    @Published var inCameraView: Bool = true { didSet { manageSession() } }
    
    @AppStorage("doneTheTip") var doneTheTip: Bool = false
    @AppStorage("hasCompletedTutorial") var hasCompletedTutorial: Bool = false
    @Published var isShowingTutorial: Bool = false
    
    // 特效参数
    @Published var lutIntensity: Float = 1.0
    @Published var grainIntensity: Float = 1.0
    
    var maxWidgetIndex: Int { UIWidgets.allCases.map { $0.rawValue }.max() ?? 0 }
    var nullWidgetIndex: Int { maxWidgetIndex + 1 }
    
    override init() {
        super.init()
        sessionManager.delegate = self
        
        if hasCompletedTutorial {
            callAllStartupFuncs()
        } else {
            isShowingTutorial = true
        }
    }
    
    func callAllStartupFuncs() {
        permissionManager.checkAllPermissions()
        motionManager.start()
        shutterSoundManager.setupSound(named: parameterManager.shutterSoundSelection.rawValue)
        
        // 1. 启动硬件
        sessionManager.initSession(with: lensManager.currentLens)
        
        // 2. 初始化第一颗镜头的物理参数到 UI
        updateUIWithLens(lensManager.currentLens)
        
        // 3. 建立绑定机制
        setupBindings()
    }
    
    private func setupBindings() {
        // 💡 监听镜头切换 -> 换硬件输入 + 自动刷新光圈/焦距
        lensManager.$currentLens
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLens in
                self?.sessionManager.switchInput(to: newLens.device)
                self?.updateUIWithLens(newLens)
            }
            .store(in: &cancellables)
            
        // 💡 监听参数拨盘 (SS / ISO / EV) 触发更新曝光
        Publishers.CombineLatest3(parameterManager.$SS, parameterManager.$ISO, parameterManager.$EV)
            .sink { [weak self] _, _, _ in self?.sessionManager.updateExposure() }
            .store(in: &cancellables)
            
        // 💡 监听其他设置
        parameterManager.$imageQuality
            .sink { [weak self] q in
                guard let dev = self?.lensManager.currentLens.device else { return }
                self?.sessionManager.HDRswitch(q != "DNG", device: dev)
            }
            .store(in: &cancellables)
            
        parameterManager.$AFMode
            .sink { [weak self] mode in
                guard let dev = self?.lensManager.currentLens.device else { return }
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
    
    // 💡 一个辅助函数，把镜头的物理属性传递给参数管家
    private func updateUIWithLens(_ lens: Lens) {
        parameterManager.actualSSoptions = lens.availableSSoptions
        parameterManager.actualISOoptions = lens.availableISOoptions
        parameterManager.Aperture = lens.aperture
        parameterManager.currentFocalLength = lens.equivalentFocalLength
    }
    
    // MARK: - 交互操作
    func takePhoto() {
        guard !isCapturing && !isShowingTutorial else { return }
        isCapturing = true
        sessionManager.capturePhoto(orientation: motionManager.deviceOrientation, userSettings: (
            parameterManager.imageQuality,
            lensManager.currentLens.device.position == .front
        ))
        shutterSoundManager.play()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
    
    func focus(at point: CGPoint) {
        sessionManager.focus(at: point, afMode: parameterManager.AFMode, device: lensManager.currentLens.device)
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
        if !inCameraView || isShowingMenu { sessionManager.stop() }
        else { sessionManager.start() }
    }
}
