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
    
    private var enableFrontCameraOrNotSection: some View {
        VStack (alignment: .leading, spacing: innerSpacing) { // Enable front camera
            Text("Front Camera")
                .font(.caption.bold())
                .foregroundColor(.gray)
            HStack(spacing: 0) {
                SegmentedButton(title: ENABLE, isSelected: $camera.) {
                    haptic(.medium)
                    DispatchQueue.main.async {
                        camera.enableFrontCamera = true
                        camera.discoverCameras()
                    }
                }
                SegmentedButton(title: DISABLE, isSelected: !camera.enableFrontCamera) {
                    haptic(.medium)
                    DispatchQueue.main.async {
                        camera.enableFrontCamera = false
                        camera.discoverCameras()
                        camera.currentDeviceIndex = 0
                        camera.switchCamera(direction: 0)
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
                SegmentedButton(title: "1", isSelected: camera.shutterSoundMode == .sony) {
                    haptic(.medium)
                    camera.shutterSoundMode = .sony
                    camera.changeShutterSound()
                }
                SegmentedButton(title: "2", isSelected: camera.shutterSoundMode == .panasonic) {
                    haptic(.medium)
                    camera.shutterSoundMode = .panasonic
                    camera.changeShutterSound()
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
                SegmentedButton(title: ENABLE, isSelected: camera.enablePermanentParameterStorage, isDisabled: camera.perferAUTO) {
                    haptic(.medium)
                    camera.enablePermanentParameterStorage = true
                    camera.updateParameterToStorage()
                }
                SegmentedButton(title: DISABLE, isSelected: !camera.enablePermanentParameterStorage, isDisabled: camera.perferAUTO) {
                    haptic(.medium)
                    camera.enablePermanentParameterStorage = false
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
                SegmentedButton(title: ENABLE, isSelected: camera.perferAUTO) {
                    camera.perferAUTO = true
                    camera.enablePermanentParameterStorage = false
                }
                SegmentedButton(title: DISABLE, isSelected: !camera.perferAUTO) {
                    camera.perferAUTO = false
                }
            }
            .background(Color.white.opacity(0.1)).cornerRadius(roundedCornerRadius)
        }
    }
    
    private var enableColorProfileInRAWsection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Enable color profile in RAW mode")
                .font(.caption.bold()).foregroundColor(.gray)
            HStack(spacing: 0) {
                SegmentedButton(title: ENABLE, isSelected: camera.enableColorProfileInRAW) {
                    camera.enableColorProfileInRAW = true
                }
                SegmentedButton(title: DISABLE, isSelected: !camera.enableColorProfileInRAW) {
                    camera.enableColorProfileInRAW = false
                }
            }
            .background(Color.white.opacity(0.1)).cornerRadius(roundedCornerRadius)
        }
    }
    
    private var moneyONEGAIsection: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            Text("Buy me a cup of coffee")
                .font(.caption.bold()).foregroundColor(.gray)
            Button(action: {
                haptic(.light)
                print("Tapped purchase button!")
                Task {
                    let success = await storeManager.purchase()
                    print("Created the task!")
                    if success {
                        haptic(.heavy)
                        showThanksAlert = true
                        camera.doneTheTip = true
                        print("Purchase done!")
                    }
                }
            }) {
                HStack {
                    if storeManager.isPurchasing {
                        ProgressView().tint(.yellow)
                    } else {
                        Image(systemName: "cup.and.saucer.fill")
                    }
                    Text("Buy me a cup of coffee!")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                    Spacer()
                }
                .padding()
                .background(Color.yellow.opacity(0.15))
                .foregroundColor(.yellow)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                )
            }
        }
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
        GeometryReader { geometry in
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
                        
                        // 3. 波形图开关
                        // MenuView.swift 中的波形图部分
                        waveFormHistogramSection
                        
                        enableFrontCameraOrNotSection
                        
                        shutterSoundSection
                        
                        saveSSandISOsection
                        
                        preferAUTOsection
                        
                        enableColorProfileInRAWsection
                        
                        if !camera.doneTheTip {
                            moneyONEGAIsection // かわいいからお金お願いします〜
                        }
                        
                        Spacer()
                        
                        // 4. 关键修正：关闭按钮
                        // 采用最高的优先级，物理反馈优先于状态变更
                        
                    }
                    .padding(30)
                }
            }
            .statusBar(hidden: true)
            .rotationEffect(.degrees(90))
            // 2. 关键：旋转后，由于是在 Portrait 容器里，
            // 我们需要手动把宽度设为屏幕的高度，高度设为屏幕的宽度
            .frame(width: geometry.size.height, height: geometry.size.width)
            // 3. 将视图居中对齐
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .alert("Oh, yeah! You have already donated me! Thank you!", isPresented: $showRestoredMsg) {
                Button("OK", role: .cancel) {}
            }
            .alert("Thank you!", isPresented: $showThanksAlert) {
                Button("OK", role: .cancel) {}
            }
        }
    }
    
    // 💡 修正 3：强制关闭菜单
    private func dismissMenu() {
        // 第一优先级：物理震动（即使主线程接下来被硬件锁死，震动也该已经发出）
        haptic(.medium)
        
        // 第二优先级：UI 消失动画
        // 通过 withAnimation 立即标记 camera.isShowingMenu = false
        // 这会让 SwiftUI 准备卸载 MenuView 视图
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            camera.isShowingMenu = false
        }
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
