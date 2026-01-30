//
//  TutorialOverlay.swift
//  betterCam
//
//  Created by Rice on 2026/1/30.
//

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

#Preview {
    TutorialOverlay(camera: Camera())
}
