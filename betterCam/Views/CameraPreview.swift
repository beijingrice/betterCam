//
//  CameraPreview.swift
//  betterCam
//
//  Created by Rice on 2026/1/23.
//

import SwiftUI
/*
struct CameraPreview: View {
    @EnvironmentObject var camera: Camera
    let aspectRatio: CGSize = CGSize(width: 4.0, height: 3.0)
    var body: some View {
        if let image = camera.currentPreviewImage {
            Image(image, scale: 1.0, orientation: .up, label: Text("Preview"))
                .resizable()
                .aspectRatio(aspectRatio, contentMode: .fit) // 强制 4:3 比例
        } else {
            Color.black // 启动时的黑屏占位
        }
    }
}
*/

struct CameraPreview: View {
    @EnvironmentObject var camera: Camera
    let aspectRatio: CGSize = CGSize(width: 4.0, height: 3.0)
    @State private var lastDragLocation: CGPoint?
    
    // 💡 用于 UI 临时显示的数值提示（可选）
    @State private var showHUD: Bool = false
    @State private var hudText: String = ""
    @State private var hudTimer: Timer?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 1. 底层预览图
                if let image = camera.currentPreviewImage {
                    Image(image, scale: 1.0, orientation: .up, label: Text("Preview"))
                        .resizable()
                        .aspectRatio(aspectRatio, contentMode: .fit)
                } else {
                    Color.black
                }
                
                // 2. 💡 透明的手势层 (覆盖在最上方)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0) // 设置为 0 可以更灵敏地捕捉初始点
                            .onChanged { value in
                                handleDrag(value, in: geometry.size)
                            }
                            .onEnded { _ in
                                // 💡 关键修复：松手时必须清空记录点
                                // 这样下次手指按下去时，handleDrag 里的 guard 才会触发，重新记录起点
                                lastDragLocation = nil
                                startHUDTimer()
                            }
                    )
                
                // 3. 💡 数值反馈提示 (HUD)
                if showHUD {
                    Text(hudText)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .transition(.opacity)
                }
            }
        }
    }

    // 💡 手势核心算法
    private func handleDrag(_ value: DragGesture.Value, in size: CGSize) {
        guard let lastLocation = lastDragLocation else {
            lastDragLocation = value.location
            return
        }
        
        // 计算当前帧与上一帧的微小偏移量
        let deltaX = Float(value.location.x - lastLocation.x)
        let deltaY = Float(value.location.y - lastLocation.y)
        
        // 立即更新记录点，确保下一帧计算是连续的
        lastDragLocation = value.location
        
        // 💡 这里的数值修改会基于 camera.lutIntensity 的当前值（即上一次结束时的值）
        // 左右滑动：手指每移动屏幕 1% 的距离，数值改变 0.01
        let sensitivityH = Float(size.width)
        let sensitivityV = Float(size.height)
        
        camera.lutIntensity = min(max(camera.lutIntensity + (deltaX / sensitivityH), 0.0), 1.0)
        camera.grainIntensity = min(max(camera.grainIntensity - (deltaY / sensitivityV), 0.0), 1.0)
        
        // 更新提示
        hudText = String(format: NSLocalizedString("LUT_HUD_FORMAT",tableName: "Localizable_variable" ,comment: ""), camera.lutIntensity * 100, camera.grainIntensity * 100)
        showHUD = true
    }

    private func startHUDTimer() {
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            withAnimation { showHUD = false }
        }
    }
}
