//
//  Styles.swift
//  betterCam
//
//  Created by Rice on 2026/1/24.
//

import SwiftUI

// 定义纹理类型

// 扩展 View，让所有 View 都能访问
extension View {
    
    var baseColor: Color {
        return Color(white: 0.6)
    }
    
    func sunkenPanelEffect(radius: CGFloat = 4, opacity: Double = 0.5) -> some View {
            self.overlay(
                ZStack {
                    // 1. 顶部和左侧的深色阴影（模拟由于面板下陷产生的遮挡）
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.black.opacity(opacity), .clear]),
                                startPoint: .trailing, // 从右侧开始
                                endPoint: .leading     // 向左侧淡出
                            )
                        )
                        .frame(width: radius * 1.5)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    
                }
                .opacity(opacity)
            )
        }
    
    func embeddedInMetalFrame(thickness: CGFloat = 2) -> some View {
            self
                .padding(thickness) // 这里的 thickness 是金属框的“内沿”
                .background(Color.black) // 模拟屏幕与金属框之间的缝隙
                .overlay(
                    // 模拟金属切割面的亮边（Bevel）
                    Rectangle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
                //.shadow(color: .black.opacity(0.6), radius: 10, x: 5, y: 5) // 整个屏幕模块对底座的投影
        }
    
    func recessedPanel(cornerRadius: CGFloat = 8, depth: CGFloat = 2) -> some View {
            self.overlay(
                ZStack {
                    // 1. 左侧和上侧：深色阴影（下陷感）
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(LinearGradient(
                            colors: [.black.opacity(0.6), .clear],
                            startPoint: .topLeading,
                            endPoint: .center
                        ), lineWidth: depth)
                        .blur(radius: 1)
                    
                    // 2. 右侧和下侧：微弱亮边（模拟切削面反光）
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(LinearGradient(
                            colors: [.clear, .white.opacity(0.5)],
                            startPoint: .center,
                            endPoint: .bottomTrailing
                        ), lineWidth: 1)
                }
            )
            // 3. 内部裁剪，确保阴影不会溢出到金属机身外面
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    
    func wrapInCameraFrame(thickness: CGFloat = 25) -> some View {
        self
            .padding(thickness)
            .background(
                Image("camera_body_noise_darker")
                    .resizable(resizingMode: .tile)
                    .opacity(1.0)
                    .blendMode(.overlay)
                    .ignoresSafeArea()
            )
    }
    
}
