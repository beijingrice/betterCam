//
//  HistogramOverlay.swift
//  betterCam
//
//  Created by Rice on 2026/2/5.
//

import SwiftUI
struct HistogramOverlay: View {
    @ObservedObject var processor = MetalWHProcessor.shared
    var body: some View {
        // 只有在模式为直方图且有数据时显示
        if processor.exposureIndicatorMode == .histogram, let cgImage = processor.histogramImage {
            ZStack(alignment: .bottom) {
                // 背景
                Color.black.opacity(0.5)
                    .frame(width: CGFloat(processor.overlayWidth), height: CGFloat(processor.overlayHeight))
                    .cornerRadius(4)
                
                // 直方图渲染结果
                Image(cgImage, scale: 1.0, orientation: .up, label: Text("Histogram"))
                    .resizable()
                    .renderingMode(.template) // 允许通过 .foregroundColor 改变颜色
                    .foregroundColor(.white)
                    .frame(width: CGFloat(processor.overlayWidth), height: CGFloat(processor.overlayHeight))
                    .blendMode(.screen)
                
                // 辅助刻度线 (垂直分位线)
                HStack {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1) // 暗部
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1) // 中间调
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1) // 高光
                }
                .frame(width: CGFloat(processor.overlayWidth), height: CGFloat(processor.overlayHeight))
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}
