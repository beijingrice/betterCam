import SwiftUI

struct WaveformOverlay: View {
    var body: some View {
        // 只有开启且有数据时才显示
        if MetalWHProcessor.shared.exposureIndicatorMode == .waveform, let cgImage = MetalWHProcessor.shared.waveformImage {
            ZStack(alignment: .bottom) {
                // 背景：器材感的半透明黑
                Color.black.opacity(0.5)
                    .frame(width: CGFloat(MetalWHProcessor.shared.overlayWidth), height: CGFloat(MetalWHProcessor.shared.overlayHeight))
                    .cornerRadius(4)
                
                // 核心：渲染 Metal 生成的统计图
                Image(cgImage, scale: 1.0, orientation: .up, label: Text("Waveform"))
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: CGFloat(MetalWHProcessor.shared.overlayWidth), height: CGFloat(MetalWHProcessor.shared.overlayHeight))
                    .blendMode(.screen)      // 叠加模式
                
                // 辅助线：0%, 50%, 100% 亮度刻度
                VStack {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                    Spacer()
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                }
                .frame(width: CGFloat(MetalWHProcessor.shared.overlayWidth), height: CGFloat(MetalWHProcessor.shared.overlayHeight))
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}
