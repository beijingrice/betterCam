import Foundation
import AVFoundation
import SwiftUI
import Combine
import UIKit

class Camera: NSObject, ObservableObject {
    // MARK: - 核心模块注入 (所有打工仔)
    @Published var parameterManager = ParameterManager()
    @Published var lensManager = LensManager()
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
    // Camera App Status
    
    // @Published var isCapturing: Bool = false
    // CHANGE TO ->
    @Published var isSensorBusy: Bool = false
    @Published var inFlightPhotos: Int = 0
    let maxBufferCount: Int = 3
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
            callAllStartupFuncs()
        } else {
            isShowingTutorial = true
        }
    }
    
    func callAllStartupFuncs() {
        permissionManager.checkAllPermissions()
        motionManager.start()
        lensManager.discoverCameras(enableFrontCamera: parameterManager.enableFrontCamera)
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
            .dropFirst() // 忽略 App 启动时的第一次通知，因为 callAllStartupFuncs 已处理
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main) // 💡 核心防抖：用户停下轮子 0.3 秒后才放行！
            .sink { [weak self] newLens in
                guard let self = self else { return }
                
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
            
        // 💡 监听参数拨盘 (SS / ISO / EV) 触发更新曝光
        Publishers.CombineLatest3(parameterManager.$SS, parameterManager.$ISO, parameterManager.$EV)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.sessionManager.updateExposure() }
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
        
        parameterManager.$isPureRawEngineEnabled
            .syncChange(on: self) { [weak self] isPureRawEngineEnabled in
                guard let self = self else { return }
                self.sessionManager.HDRswitch(isPureRawEngineEnabled, device: self.lensManager.currentLens.device)
            }
    }
    
    func refreshLensCapabilities() {
        // 1. 让当前镜头自我刷新（去读 6400 的极限）
        lensManager.currentLens.refreshCapabilities()
        
        // 2. 🚨 极其重要：把刷新后的新镜头塞回 LensManager 的数组里替换掉旧的！
        // 否则你切一次镜头再切回来，它又会变成 4000
        if let index = lensManager.physicalLenses.firstIndex(where: { $0.device.uniqueID == lensManager.currentLens.device.uniqueID }) {
            lensManager.physicalLenses[index] = lensManager.currentLens
        }
        
        // 3. 把最新鲜的数据推给 UI
        updateUIWithLens(lensManager.currentLens)
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
        guard !isSensorBusy && inFlightPhotos < maxBufferCount && !isShowingTutorial else { return }
        isSensorBusy = true
        inFlightPhotos += 1
        
        sessionManager.capturePhoto(orientation: motionManager.deviceOrientation, userSettings: (
            parameterManager.imageQuality,
            lensManager.currentLens.device.position == .front // check if using front cam
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
