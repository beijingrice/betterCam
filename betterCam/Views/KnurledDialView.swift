import SwiftUI

struct KnurledDialView: View {
    
    @EnvironmentObject var camera: Camera
    
    @State private var rotationAngle: Double = 0
    @State private var lastGestureAngle: Double = 0
    @State private var hapticAccumulator: Double = 0
    
    private let dialSize: CGFloat = 140
    private let stepDegrees: Double = 45
    private let midButtonSize: CGFloat = 55
    
    var body: some View {
        ZStack {
            // 1. 物理阴影
            Circle()
                .fill(Color.black.opacity(0.4))
                .blur(radius: 2)
                .offset(x: 1, y: 1)
            
            // 2. 拨轮主体
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let fullRadius = size.width / 2
                let rect = CGRect(origin: .zero, size: size)
                
                // A. 基础底色
                context.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.45, green: 0.45, blue: 0.46)))
                
                // B. 渐变层 (显式写出类型，解决报错)
                context.fill(
                    Path(ellipseIn: rect),
                    with: GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [Color.white.opacity(0.18), Color.clear, Color.black.opacity(0.25)]),
                        startPoint: CGPoint.zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )

                // C. 金字塔纹理 (物理路径变换法)
                let outerRingRadius = fullRadius * 0.85
                let innerRingRadius = fullRadius * 0.45
                let constantDotSize: CGFloat = 4.2
                
                for ring in 0..<6 {
                    let currentRadius = innerRingRadius + CGFloat(ring) * (outerRingRadius - innerRingRadius) / 4
                    let teethCount = Int(2 * .pi * currentRadius / (constantDotSize * 1.6))
                    
                    for i in 0..<teethCount {
                        let angle = Double(i) * (360.0 / Double(teethCount))
                        let radian = angle * .pi / 180
                        let x = center.x + cos(radian) * currentRadius
                        let y = center.y + sin(radian) * currentRadius
                        
                        // 核心逻辑：直接对 Path 应用变换矩阵，不触碰 context 状态
                        var transform = CGAffineTransform(translationX: x, y: y)
                        transform = transform.rotated(by: CGFloat(radian + .pi / 4))
                        
                        // 绘制每一个齿
                        let dotRect = CGRect(x: -constantDotSize/2, y: -constantDotSize/2, width: constantDotSize, height: constantDotSize)
                        let dotPath = Path(dotRect).applying(transform)
                        
                        let isBright = (i + ring) % 2 == 0
                        context.fill(
                            dotPath,
                            with: GraphicsContext.Shading.color(isBright ? Color.white.opacity(0.3) : Color.black.opacity(0.35))
                        )
                    }
                }
                
                // D. 噪点颗粒
                for _ in 0...5000 {
                    let dotX = Double.random(in: 0...size.width)
                    let dotY = Double.random(in: 0...size.height)
                    context.fill(
                        Path(ellipseIn: CGRect(x: dotX, y: dotY, width: 0.5, height: 0.5)),
                        with: .color(Color.black.opacity(0.12))
                    )
                }
                
            }
            .clipShape(Circle())
            .rotationEffect(Angle(degrees: rotationAngle))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in handleRotationUpdate(location: value.location) }
                    .onEnded { _ in lastGestureAngle = 0}
            )
            // 3. 【核心修复】反向物理遮罩
            // 强制将 55 像素以内的所有像素点抹除，不管是 Canvas 还是 Shadow 产生的
            .mask(
                ZStack {
                    Rectangle() // 填满背景
                    Circle()    // 挖掉中心
                        .frame(width: midButtonSize, height: midButtonSize)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            
            // 4. 中心盖板 (物理零件)
            ZStack {
                Circle().fill(Color(red: 0.45, green: 0.45, blue: 0.46))

            }
            .frame(width: midButtonSize, height: midButtonSize)
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.8))
            .onTapGesture {
                camera.toggleAdjustmentMode()
            }
        }
        .frame(width: dialSize, height: dialSize)
        .compositingGroup()
    }
    
    private func handleRotationUpdate(location: CGPoint) {
        let center = CGPoint(x: dialSize/2, y: dialSize/2)
        let currentAngle = Double(atan2(location.y - center.y, location.x - center.x))
                
                // 2. 如果是手势刚开始，初始化 lastGestureAngle
                if lastGestureAngle == 0 {
                    lastGestureAngle = currentAngle
                    return
                }
                
                // 3. 计算角度增量 (Delta)
                var delta = currentAngle - lastGestureAngle
                
                // 4. 核心：处理极坐标跳变 (-π 到 π 的边界)
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                
                // 将弧度增量转换为角度增量
                let deltaInDegrees = delta * 180 / .pi
                
                // 5. 更新状态
                // 使用线性动画平滑视觉，response 越小越灵敏
                withAnimation(.interactiveSpring(response: 0.1, dampingFraction: 0.8)) {
                    rotationAngle += deltaInDegrees
                }
                
                // 6. 步进逻辑：每 30 度触发反馈并切换参数
                hapticAccumulator += deltaInDegrees
                if abs(hapticAccumulator) >= stepDegrees {
                    triggerFeedback()
                    if hapticAccumulator > 0 {
                        camera.changeParameter(direction: 1)
                    } else {
                        camera.changeParameter(direction: -1)
                    }
                    // 这种写法支持快速旋转时连续触发
                    hapticAccumulator = hapticAccumulator.truncatingRemainder(dividingBy: stepDegrees)
                }
                
                lastGestureAngle = currentAngle
            }
    
    private func triggerFeedback() {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
}

#Preview {
    KnurledDialView()
        .environmentObject(Camera())
}
