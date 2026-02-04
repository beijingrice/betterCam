//
//  TutorialOverlay.swift
//  betterCam
//
//  Created by Rice on 2026/1/30.
//

/*
import SwiftUI
struct TutorialOverlay: View {
    @ObservedObject var camera: Camera
    @State private var pulse: Bool = false
    @State private var offsetH: CGFloat = -10
    @State private var offsetV: CGFloat = 10
    
    var body: some View {
        ZStack {
            // 半透明背景
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            
            HStack {
                VStack(spacing: 0) { // Gesture
                    Text("In camera screen:")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .padding(.top, 10)
                    Spacer()
                    
                    // 💡 左右滑动教学动画
                    VStack {
                        HStack {
                            Image(systemName: "arrow.left")
                            Image(systemName: "hand.draw.fill")
                                .offset(x: offsetH)
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 40))
                        Text("Swipe horizontally for Profile Intensity")
                    }
                    .foregroundColor(Color.white.opacity(0.8))
                    Spacer()
                    
                    // 💡 上下滑动教学动画
                    VStack {
                        VStack {
                            Image(systemName: "arrow.up")
                            Image(systemName: "hand.draw.fill")
                                .offset(y: offsetV)
                            Image(systemName: "arrow.down")
                        }
                        .font(.system(size: 40))
                        Text("Swipe vertically for Grain")
                    }
                    .foregroundColor(Color.white.opacity(0.8))
                    
                    Button("Got it") {
                        withAnimation {
                            camera.hasCompletedTutorial = true
                            camera.isShowingTutorial = false
                        }
                    }
                    .padding(.top, 10)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.white.opacity(0.8))
                    .foregroundColor(.black)
                }
                
                VStack(alignment: .leading, spacing: 10) { // LUT management
                    Text("In bottom bar of camera screen:")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .padding(.top, 10)
                    Group {
                        Text("Look for STYLE parameter,")
                        Text("Usually it's STD when launched.")
                        Text("Change it to MANAGE then click the")
                        Text("middle button of the dial to manage LUTs.")
                        Text("In LUT management view,")
                        Text("Swipe left to rename or delete.")
                    }
                    .padding(.top, 5)
                }
                .padding(.horizontal) // 给左边留一点呼吸空间
            }
            
        }
        .onAppear {
            // 循环动画模拟手势
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                offsetH = 10
                offsetV = -10
            }
        }
    }
}
*/

import SwiftUI

struct TutorialOverlay: View {
    @ObservedObject var camera: Camera
    
    // 教学步骤控制
    @State private var currentStep: Int = 1 // 1: 手势与LUT说明, 2: 拨盘与快门说明
    
    // 动画状态
    @State private var offsetH: CGFloat = -15
    @State private var offsetV: CGFloat = 15
    @State private var dialRotation: Double = 0
    @State private var shutterPulse: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()
            
            if currentStep == 1 {
                // --- 第一阶段：原有的手势与LUT说明 ---
                mainInfoView
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading)))
            } else {
                // --- 第二阶段：拨盘、中键与快门动画教学 ---
                dialAndShutterView
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - 第一阶段视图 (手势与LUT)
    private var mainInfoView: some View {
        HStack(spacing: 30) {
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
        .padding(40)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                offsetH = 15
                offsetV = -15
            }
        }
    }
    
    // MARK: - 第二阶段视图 (拨盘与快门)
    private var dialAndShutterView: some View {
        HStack(spacing: 50) {
            // 左侧：拨盘说明
            VStack(spacing: 30) {
                Text("Physical Control:")
                    .font(.title3.bold())
                
                // 模拟拨盘旋转动画
                ZStack {
                    KnurledDialView()
                        .allowsHitTesting(false)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rotate the dial to switch items")
                    Text("Press center to select")
                }
                .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            
            // 右侧：快门说明
            VStack(spacing: 30) {
                Text("Capture:")
                    .font(.title3.bold())
                
                // 快门按钮动画
                ShutterButtonView()
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Press the shutter button to shoot.")
                }
                .font(.subheadline)
                
                Spacer()
                
                nextButton(label: "Start Shooting") {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        camera.hasCompletedTutorial = true
                        camera.isShowingTutorial = false
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(40)
        .onAppear {
            // 拨盘旋转动画
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                dialRotation = 360
            }
            // 快门/中键点击动画
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                shutterPulse = 0.8
            }
        }
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
