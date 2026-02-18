//
//  BodyGrainLayer.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI
/*
struct BodyGrainLayer: View {
    // 💡 缓存生成的贴图，类似 Python 里的单例模式或对象池
    @State private var cachedGrainImage: Image? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let grain = cachedGrainImage {
                    // 💡 如果已经渲染过，直接显示图片（GPU 负责，0 CPU 占用）
                    grain
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // 💡 第一次加载时显示占位，并触发异步渲染
                    Color.clear
                        .onAppear {
                            renderGrainAsync(size: geometry.size)
                        }
                }
            }
        }
        .blendMode(.overlay)
        .ignoresSafeArea()
    }

    // 💡 核心优化：离线渲染函数
    private func renderGrainAsync(size: CGSize) {
        // 防止尺寸为 0 时崩溃
        guard size.width > 0 && size.height > 0 else { return }

        // 使用 ImageRenderer 在后台线程或立即渲染出一张位图
        let renderer = ImageRenderer(content:
            ZStack {
                // 原有的黑点 Canvas
                Canvas { context, size in
                    for _ in 0...400000 { // Draw black dots for 400000 times
                        let x = Double.random(in: 0...size.width)
                        let y = Double.random(in: 0...size.height)
                        let dotSize = Double.random(in: 0.3...0.5)
                        let opacity = Double.random(in: 0.1...0.15)
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: dotSize, height: dotSize)),
                            with: .color(.black.opacity(opacity))
                        )
                    }
                }
                // 原有的白点 Canvas
                Canvas { context, size in
                    for _ in 0...100000 { // Draw white dots for 100000 times
                        let x = Double.random(in: 0...size.width)
                        let y = Double.random(in: 0...size.height)
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 0.4, height: 0.4)),
                            with: .color(.white.opacity(0.15))
                        )
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        )

        // 💡 提高采样率，确保噪点细腻不模糊
        renderer.scale = UIScreen.main.scale

        if let uiImage = renderer.uiImage {
            // 回到主线程更新 UI
            DispatchQueue.main.async {
                self.cachedGrainImage = Image(uiImage: uiImage)
            }
        }
    }
}
*/


struct BodyGrainLayer: View {
    var body: some View {
        Image("camera_body_noise")
            .resizable(resizingMode: .tile)
            .opacity(1.0)
            .blendMode(.overlay)
            .ignoresSafeArea()
    }
}

