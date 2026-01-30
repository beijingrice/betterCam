//
//  FocusBoxView.swift
//  betterCam
//
//  Created by Rice on 2026/1/30.
//

import SwiftUI
struct FocusBoxView: View {
    @State private var animate = false
    
    // 💡 定义颜色和线条宽度，方便统一修改
    private let boxColor = Color.green
    private let lineWidth: CGFloat = 1.2
    private let boxSize: CGFloat = 70.0
    private let crosshairSize: CGFloat = 70.0 // 十字丝的大小
    
    var body: some View {
        ZStack {
            // 1. 外部方框
            Rectangle()
                .stroke(boxColor, lineWidth: lineWidth)
                .frame(width: boxSize, height: boxSize)
            
            // 2. 💡 中心十字 - 水平线
            Rectangle()
                .fill(boxColor)
                .frame(width: crosshairSize, height: lineWidth)
            
            // 3. 💡 中心十字 - 垂直线
            Rectangle()
                .fill(boxColor)
                .frame(width: lineWidth, height: crosshairSize)
        }
        // 4. 动画效果：点击时从大变小并淡入
        .scaleEffect(animate ? 1.0 : 1.4)
        .opacity(animate ? 1.0 : 0.0)
        .onAppear {
            // 使用弹性动画模拟相机合焦的动作感
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                animate = true
            }
        }
    }
}
