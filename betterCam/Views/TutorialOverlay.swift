//
//  TutorialOverlay.swift
//  betterCam
//
//  Created by Rice on 2026/1/30.
//

import SwiftUI

struct TutorialOverlay: View {
    @ObservedObject var camera: Camera
    @State private var currentStep: Int = 1
    
    // 动画状态
    @State private var offsetH: CGFloat = -15
    @State private var offsetV: CGFloat = 15
    
    var body: some View {
        GeometryReader { geo in
            // 获取物理屏幕的宽高
            let screenW = geo.size.width
            let screenH = geo.size.height
            
            ZStack {
                Color.black.opacity(0.8)
                    .ignoresSafeArea()
                
                // 关键点：创建一个固定尺寸的容器，其尺寸是反向的
                // 旋转后，这个容器会正好填满竖屏
                Group {
                    if currentStep == 1 {
                        mainInfoView
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading)))
                    } else {
                        dialAndShutterView
                            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
                    }
                }
                .frame(width: screenH, height: screenW) // 交换宽高
                .rotationEffect(.degrees(90))           // 顺时针旋转90度
                .offset(x: -(screenW / 4))
            }
            .frame(width: screenW, height: screenH)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 第一阶段视图
    private var mainInfoView: some View {
        HStack(spacing: 40) {
            VStack(spacing: 25) {
                Text("In camera screen:")
                    .font(.title3.bold())
                gestureSection(icon: "hand.draw.fill", text: "Swipe horizontally for Profile Intensity", offset: offsetH, isHorizontal: true)
                gestureSection(icon: "hand.draw.fill", text: "Swipe vertically for Grain", offset: offsetV, isHorizontal: false)
                
                nextButton(label: "Got it") {
                    withAnimation(.spring()) { currentStep = 2 }
                }
            }
            .frame(maxWidth: .infinity)
            
            lutInfoSection
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 60)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                offsetH = 15
                offsetV = -15
            }
        }
    }

    // MARK: - 第二阶段视图
    private var dialAndShutterView: some View {
        HStack(spacing: 60) {
            // 左侧：拨盘
            VStack(spacing: 20) {
                Text("Physical Control:")
                    .font(.title3.bold())
                
                KnurledDialView() // 假设你已有此组件
                    .allowsHitTesting(false)
                    .frame(height: 120)
                    .padding(.vertical, 40)
                
                VStack(alignment: .center, spacing: 4) {
                    Text("Rotate the dial to switch items")
                    Text("Press center to select")
                }
                .font(.subheadline)
            }
            .frame(maxWidth: .infinity)

            // 右侧：快门
            VStack(spacing: 20) {
                Text("Capture:")
                    .font(.title3.bold())
                
                ShutterButtonView() // 假设你已有此组件
                    .allowsHitTesting(false)
                    .frame(height: 120)

                Text("Press the shutter button to shoot.")
                    .font(.subheadline)
                
                Spacer().frame(height: 20)

                nextButton(label: "Start Shooting") {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        camera.hasCompletedTutorial = true
                        camera.isShowingTutorial = false
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 60)
    }
    
    // MARK: - 辅助组件
    private func nextButton(label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .frame(width: 160, height: 44)
                .background(Color.white)
                .foregroundColor(.black)
                .cornerRadius(22)
        }
    }
    
    private func gestureSection(icon: String, text: LocalizedStringKey, offset: CGFloat, isHorizontal: Bool) -> some View {
        VStack(spacing: 12) {
            HStack {
                if isHorizontal {
                    Image(systemName: "arrow.left")
                    Image(systemName: icon).offset(x: offset)
                    Image(systemName: "arrow.right")
                } else {
                    VStack {
                        Image(systemName: "arrow.up")
                        Image(systemName: icon).offset(y: offset)
                        Image(systemName: "arrow.down")
                    }
                }
            }
            .font(.system(size: 32))
            Text(text).font(.caption).multilineTextAlignment(.center)
        }
    }
    
    private var lutInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In bottom bar of camera screen:")
                .font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("Look for STYLE parameter,")
                Text("Usually it's STD when launched.")
                Text("Change it to MANAGE then click the")
                Text("middle button of the dial to manage LUTs.")
            }
            Divider().background(Color.white.opacity(0.3)).padding(.vertical, 5)
            VStack(alignment: .leading, spacing: 6) {
                Text("In LUT management view,")
                Text("Swipe left to rename or delete.")
            }
        }
        .font(.subheadline)
    }
}

#Preview {
    TutorialOverlay(camera: Camera())
}
