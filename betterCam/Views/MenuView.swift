//
//  MenuView.swift
//  betterCam
//
//  Created by Rice on 2026/2/4.
//
import SwiftUI
import StoreKit

struct MenuView: View {
    @ObservedObject var camera: Camera
    
    @EnvironmentObject var storeManager: StoreManager
    
    @EnvironmentObject var pm: ParameterManager // 💡 新增
    @EnvironmentObject var lm: LensManager      // 💡 新增
    
    @State private var showThanksAlert: Bool = false
    @State private var showRestoredMsg: Bool = false
    
    // 💡 本地化变量
    private let LOW: String = String(NSLocalizedString("LOW", tableName: "Localizable_variable", comment: ""))
    private let HIGH: String = String(NSLocalizedString("HIGH", tableName: "Localizable_variable", comment: ""))
    private let WAVEFORM: String = String(NSLocalizedString("WAVEFORM", tableName: "Localizable_variable", comment: ""))
    private let HISTOGRAM: String = String(NSLocalizedString("HISTOGRAM", tableName: "Localizable_variable", comment: ""))
    private let OFF: String = String(NSLocalizedString("OFF", tableName: "Localizable_variable", comment: ""))
    private let ENABLE: String = String(NSLocalizedString("ENABLE", tableName: "Localizable_variable", comment: ""))
    private let DISABLE: String = String(NSLocalizedString("DISABLE", tableName: "Localizable_variable", comment: ""))
    
    private let innerSpacing: CGFloat = 12
    private let roundedCornerRadius: CGFloat = 8
    
    private var headerSection: some View {
        Text("Settings")
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundColor(.white)
        
    }
    
    private var waveFormHistogramSection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Exposure Indicator")
                .font(.caption.bold())
                .foregroundColor(.gray)
            
            HStack(spacing: 0) {
                SegmentedButton(title: WAVEFORM, isSelected: camera.exposureIndicatorMode == .waveform) {
                    // 💡 物理反馈第一
                    haptic(.medium)
                    // 💡 异步开启，防止 GPU 突发负载引起主线程瞬间丢帧
                    DispatchQueue.main.async {
                        camera.exposureIndicatorMode = .waveform
                    }
                }
                SegmentedButton(title: HISTOGRAM, isSelected: camera.exposureIndicatorMode == .histogram) {
                    // 💡 物理反馈第一
                    haptic(.medium)
                    // 💡 异步开启，防止 GPU 突发负载引起主线程瞬间丢帧
                    DispatchQueue.main.async {
                        camera.exposureIndicatorMode = .histogram
                    }
                }
                SegmentedButton(title: OFF, isSelected: camera.exposureIndicatorMode == .off) {
                    haptic(.medium)
                    DispatchQueue.main.async {
                        camera.exposureIndicatorMode = .off
                    }
                }
            }
            .background(Color.white.opacity(0.1))
            .cornerRadius(roundedCornerRadius)
        }
    }
    
    // TODO: Check if there's any issue after added/removed front cam
    private var enableFrontCameraOrNotSection: some View {
        VStack (alignment: .leading, spacing: innerSpacing) { // Enable front camera
            Text("Front Camera")
                .font(.caption.bold())
                .foregroundColor(.gray)
            HStack(spacing: 0) {
                SegmentedButton(title: ENABLE, isSelected: pm.enableFrontCamera) {
                    haptic(.medium)
                    DispatchQueue.main.async {
                        pm.enableFrontCamera = true
                        lm.discoverCameras(enableFrontCamera: true)
                    }
                }
                SegmentedButton(title: DISABLE, isSelected: !pm.enableFrontCamera) {
                    haptic(.medium)
                    DispatchQueue.main.async {
                        pm.enableFrontCamera = false
                        camera.lensManager.discoverCameras(enableFrontCamera: false)
                    }
                }
            }
            .background(Color.white.opacity(0.1))
            .cornerRadius(roundedCornerRadius)
        }
    }
    
    private var shutterSoundSection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Shutter Sound")
                .font(.caption.bold()).foregroundColor(.gray)
            HStack(spacing: 0) {
                SegmentedButton(title: "1", isSelected: pm.shutterSoundSelection == .sony) {
                    haptic(.medium)
                    pm.shutterSoundSelection = .sony
                }
                SegmentedButton(title: "2", isSelected: pm.shutterSoundSelection == .panasonic) {
                    haptic(.medium)
                    pm.shutterSoundSelection = .panasonic
                }
            }
            .background(Color.white.opacity(0.1)).cornerRadius(roundedCornerRadius)
        }
    }
    
    private var saveSSandISOsection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Save shutter speed and ISO from last session")
                .font(.caption.bold()).foregroundColor(.gray)
            HStack(spacing: 0) {
                SegmentedButton(title: ENABLE, isSelected: pm.enablePermanentStorage, isDisabled: pm.perferAUTO) {
                    haptic(.medium)
                    pm.enablePermanentStorage = true
                    pm.saveExposureParameters()
                }
                SegmentedButton(title: DISABLE, isSelected: !pm.enablePermanentStorage, isDisabled: pm.perferAUTO) {
                    haptic(.medium)
                    pm.enablePermanentStorage = false
                }
            }
            .background(Color.white.opacity(0.1)).cornerRadius(roundedCornerRadius)
        }
    }
    
    private var preferAUTOsection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Prefer AUTO mode when launched")
                .font(.caption.bold()).foregroundColor(.gray)
            HStack(spacing: 0) {
                SegmentedButton(title: ENABLE, isSelected: pm.perferAUTO) {
                    pm.perferAUTO = true
                    pm.enablePermanentStorage = false
                }
                SegmentedButton(title: DISABLE, isSelected: !pm.perferAUTO) {
                    pm.perferAUTO = false
                }
            }
            .background(Color.white.opacity(0.1)).cornerRadius(roundedCornerRadius)
        }
    }
    
    private var zeroProcessingSection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Enable ZERO PROCESSING")
                .font(.caption.bold()).foregroundColor(.gray)
            HStack(spacing: 0) {
                SegmentedButton(title: ENABLE, isSelected: pm.isPureRawEngineEnabled) {
                    pm.isPureRawEngineEnabled = true
                    pm.photoResolutionMode = .standard
                }
                SegmentedButton(title: DISABLE, isSelected: !pm.isPureRawEngineEnabled) {
                    pm.isPureRawEngineEnabled = false
                }
            }
            .background(Color.white.opacity(0.1)).cornerRadius(roundedCornerRadius)
        }
    }

    private var photoResolutionSection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Photo Resolution")
                .font(.caption.bold()).foregroundColor(.gray)

            HStack(spacing: 0) {
                SegmentedButton(
                    title: camera.is24MPSupported ? PhotoResolutionMode.standard.rawValue : "24MP N/A",
                    isSelected: pm.photoResolutionMode == .standard,
                    isDisabled: !camera.is24MPSupported
                ) {
                    haptic(.medium)
                    pm.photoResolutionMode = .standard
                }

                SegmentedButton(
                    title: camera.is48MPSupported ? PhotoResolutionMode.high48MP.rawValue : "48MP N/A",
                    isSelected: pm.photoResolutionMode == .high48MP,
                    isDisabled: !camera.is48MPSupported
                ) {
                    haptic(.medium)
                    pm.photoResolutionMode = .high48MP
                }
            }
            .background(Color.white.opacity(0.1))
            .cornerRadius(roundedCornerRadius)

            Text("24MP and 48MP apply to processed photos. RAW formats use a sensor-supported RAW resolution. Apple ProRAW is automatically disabled on unsupported devices.")
                .font(.caption2)
                .foregroundColor(.gray)

        }
    }

    private var imageQualitySection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Image Quality")
                .font(.caption.bold())
                .foregroundColor(.gray)

            HStack(spacing: 0) {
                ForEach(pm.imageQualityOptions, id: \.self) { option in
                    SegmentedButton(
                        title: option,
                        isSelected: pm.imageQuality == option,
                        isDisabled: option == "ProRAW" && !camera.isProRAWSupported
                    ) {
                        haptic(.medium)
                        pm.imageQuality = option
                    }
                }
            }
            .background(Color.white.opacity(0.1))
            .cornerRadius(roundedCornerRadius)
        }
    }
    
    private var supportButton: some View {
        Button {
            haptic(.light)
            Task {
                guard await storeManager.purchase() else { return }
                haptic(.heavy)
                showThanksAlert = true
                camera.doneTheTip = true
            }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if storeManager.isPurchasing {
                        ProgressView().tint(.yellow)
                    } else {
                        Image(systemName: "cup.and.saucer.fill")
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 24)
                .foregroundStyle(.yellow)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Support betterCam")
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.yellow)
                    Text("Buy me a cup of coffee")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if let product = storeManager.products.first {
                    Text(product.displayPrice)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(12)
            .frame(minHeight: 44)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: roundedCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: roundedCornerRadius)
                    .strokeBorder(Color.yellow.opacity(0.3))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(storeManager.isPurchasing)
    }
    
    private var cancelButton: some View {
        Button(action: {
            dismissMenu()
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 24))
                .foregroundColor(Color.white)
        }
    }
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            ZStack {
                // 半透明背景，点击此处也可以增加关闭逻辑
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        
                        // 1. 顶部标题
                        ZStack {
                            HStack {
                                cancelButton
                                    .padding(10)
                                Spacer()
                            }
                            headerSection
                        }

                        if !camera.doneTheTip {
                            supportButton
                        }
                        
                        // 3. 波形图开关
                        // MenuView.swift 中的波形图部分
                        waveFormHistogramSection
                        
                        enableFrontCameraOrNotSection
                        
                        shutterSoundSection
                        
                        saveSSandISOsection
                        
                        preferAUTOsection

                        imageQualitySection

                        photoResolutionSection
                        
                        zeroProcessingSection
                        
                        Spacer()
                        
                        // 4. 关键修正：关闭按钮
                        // 采用最高的优先级，物理反馈优先于状态变更
                        
                    }
                    .padding(30)
                }
            }
            .statusBar(hidden: true)
            .alert("Oh, yeah! You have already donated me! Thank you!", isPresented: $showRestoredMsg) {
                Button("OK", role: .cancel) {}
            }
            .alert("Thank you!", isPresented: $showThanksAlert) {
                Button("OK", role: .cancel) {}
            }
        }
    }
    
    private func dismissMenu() {
        haptic(.medium)
        camera.isShowingMenu = false
    }
    
    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}

// MARK: - 核心组件：SegmentedButton
struct SegmentedButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    let isDisabled: Bool
    
    init(title: String, isSelected: Bool, action: @escaping () -> Void, isDisabled: Bool = false) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
        self.isDisabled = isDisabled
    }
    
    func actualAction() {
        if !isDisabled {
            action()
        }
    }
    
    var body: some View {
        Button(action: actualAction) {
            if !isDisabled {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(isSelected ? Color.white : Color.clear)
                    .foregroundColor(isSelected ? Color.black : Color.white)
            } else {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.black.opacity(0.4))
                    .foregroundColor(Color.white.opacity(0.6))
            }
        }
        // 💡 禁用按钮自带的简单动画，避免与 camera 里的逻辑冲突
        .animation(.none, value: isSelected)
        .disabled(isDisabled)
    }
}

#Preview {
    MenuView(camera: Camera())
        .environmentObject(StoreManager())
}
