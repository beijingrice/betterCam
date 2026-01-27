//
//  ShutterButtonView.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI

struct ShutterButtonView: View {
    // 注入全局 Camera 对象以调用拍照音效和逻辑
    @EnvironmentObject var camera: Camera
    
    // 使用 @State 模拟按钮按下的物理反馈
    @State private var isPressed: Bool = false
    
    var body: some View {
        Button(action: {
            // 触发 Camera 类中封装好的拍照序列（包含音效、震动）
            camera.takePhoto()
        }) {
            ZStack {
                // 1. 底座凹陷阴影（按钮下方的坑）
                Circle()
                    .fill(Color.black.opacity(0.4))
                    .blur(radius: 2)
                    .offset(x: 1, y: 1)
                
                // 2. 按钮主体
                ZStack {
                    // A. 金属基座
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.6), Color(white: 0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    // B. 纹理层：模拟拉丝金属与微小噪点
                    Canvas { context, size in
                        // 绘制极细的同心圆拉丝纹
                        for radius in stride(from: size.width/2, to: 0, by: -1) {
                            let path = Path(ellipseIn: CGRect(
                                x: size.width/2 - radius,
                                y: size.height/2 - radius,
                                width: radius * 2,
                                height: radius * 2)
                            )
                            context.stroke(path, with: .color(Color.white.opacity(0.05)), lineWidth: 0.5)
                        }
                        
                        // 随机喷砂噪点
                        for _ in 0...1500 {
                            let x = Double.random(in: 0...size.width)
                            let y = Double.random(in: 0...size.height)
                            context.fill(
                                Path(ellipseIn: CGRect(x: x, y: y, width: 0.5, height: 0.5)),
                                with: .color(Color.black.opacity(0.1))
                            )
                        }
                    }
                    .blendMode(.overlay)
                    
                    // C. 边缘倒角亮边 (Bevel)
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.5), .clear, .black.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                }
                // 物理动态：按下时缩小并下沉
                .scaleEffect(isPressed ? 0.96 : 1.0)
                .offset(y: isPressed ? 1 : 0)
                .animation(.spring(response: 0.2, dampingFraction: 0.5), value: isPressed)
            }
        }
        .buttonStyle(ShutterButtonStyle(isPressed: $isPressed))
        .frame(width: 70, height: 70)
    }
}

// MARK: - 自定义 ButtonStyle
// 用于在不破坏材质外观的前提下，将按钮的点击状态同步给视图
struct ShutterButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { newValue in
                isPressed = newValue
            }
    }
}

// MARK: - 预览
#Preview {
    ZStack {
        Color.gray.ignoresSafeArea()
        ShutterButtonView()
            .environmentObject(Camera())
    }
}
