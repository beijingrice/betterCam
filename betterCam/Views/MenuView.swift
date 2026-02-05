//
//  MenuView.swift
//  betterCam
//
//  Created by Rice on 2026/2/4.
//
import SwiftUI

struct MenuView: View {
    @ObservedObject var camera: Camera
    
    // 💡 本地化变量
    private let LOW: String = String(NSLocalizedString("LOW", tableName: "Localizable_variable", comment: ""))
    private let HIGH: String = String(NSLocalizedString("HIGH", tableName: "Localizable_variable", comment: ""))
    private let WAVEFORM: String = String(NSLocalizedString("WAVEFORM", tableName: "Localizable_variable", comment: ""))
    private let HISTOGRAM: String = String(NSLocalizedString("HISTOGRAM", tableName: "Localizable_variable", comment: ""))
    private let OFF: String = String(NSLocalizedString("OFF", tableName: "Localizable_variable", comment: ""))
    
    private let innerSpacing: CGFloat = 12
    private let roundedCornerRadius: CGFloat = 8
    
    var body: some View {
        ZStack {
            // 半透明背景，点击此处也可以增加关闭逻辑
            Color.black.opacity(0.9)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // 1. 顶部标题
                Text("Settings")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white)
                
                // 2. 预览分辨率选择
                VStack(alignment: .leading, spacing: innerSpacing) {
                    Text("Preview Resolution")
                        .font(.caption.bold())
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 0) {
                        SegmentedButton(title: LOW, isSelected: camera.previewResolution == "LOW") {
                            updateResolution("LOW")
                        }
                        SegmentedButton(title: HIGH, isSelected: camera.previewResolution == "HIGH") {
                            updateResolution("HIGH")
                        }
                    }
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(roundedCornerRadius)
                }
                
                // 3. 波形图开关
                // MenuView.swift 中的波形图部分
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
                                camera.histogramImage = nil
                            }
                        }
                        SegmentedButton(title: HISTOGRAM, isSelected: camera.exposureIndicatorMode == .histogram) {
                            // 💡 物理反馈第一
                            haptic(.medium)
                            // 💡 异步开启，防止 GPU 突发负载引起主线程瞬间丢帧
                            DispatchQueue.main.async {
                                camera.exposureIndicatorMode = .histogram
                                camera.waveformImage = nil
                            }
                        }
                        SegmentedButton(title: OFF, isSelected: camera.exposureIndicatorMode == .off) {
                            haptic(.medium)
                            DispatchQueue.main.async {
                                camera.exposureIndicatorMode = .off
                                camera.waveformImage = nil // 立即清空显存
                                camera.histogramImage = nil
                            }
                        }
                    }
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(roundedCornerRadius)
                }
                
                Spacer()
                
                // 4. 关键修正：关闭按钮
                // 采用最高的优先级，物理反馈优先于状态变更
                Button(action: {
                    dismissMenu()
                }) {
                    Text("Close")
                        .font(.system(size: 14, weight: .bold))
                        .frame(height: 44) // 增加点击热区
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.bottom, 20)
            }
            .padding(30)
        }
    }
    
    // --- 逻辑控制 ---

    // 💡 修正 1：切换分辨率时，先触发震动，再异步提交重度逻辑
    private func updateResolution(_ res: String) {
        haptic(.light)
        
        // 使用 async 确保当前按钮的“松开”动画和震动能被主线程优先渲染
        DispatchQueue.main.async {
            camera.previewResolution = res
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
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(isSelected ? Color.white : Color.clear)
                .foregroundColor(isSelected ? Color.black : Color.white)
        }
        // 💡 禁用按钮自带的简单动画，避免与 camera 里的逻辑冲突
        .animation(.none, value: isSelected)
    }
}
