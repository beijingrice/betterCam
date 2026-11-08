//
//  CameraPreview.swift
//  betterCam
//
//  Created by Rice on 2026/1/23.
//

import SwiftUI
import AVFoundation
import AVKit

struct CameraPreview: View {
    @Environment(\.cameraPreviewOrientation) private var previewOrientation
    @EnvironmentObject var camera: Camera
    @EnvironmentObject private var lensManager: LensManager
    @State private var lastDragLocation: CGPoint?
    
    @State private var focusPoint: CGPoint?
    @State private var focusTimer: Timer?
    
    // 💡 用于 UI 临时显示的数值提示（可选）
    @State private var showHUD: Bool = false
    @State private var hudText: String = ""
    @State private var hudTimer: Timer?

    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if lensManager.currentLens == nil {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Camera unavailable")
                } else if camera.permissionManager.isFullyAuthorized {
                    CaptureInteractionView(camera: camera)
                    actualPreviewLayer(in: geometry.size)
                } else if camera.permissionManager.cameraPermission == .denied || camera.permissionManager.photoPermission == .denied {
                    // 💡 只要有一个拒绝，就显示图文提示
                    permissionDeniedView
                } else {
                    Color.black // 等待授权中
                }
            }
        }
    }
        
        // 原有的预览逻辑封装
        @ViewBuilder
    private func actualPreviewLayer(in size: CGSize) -> some View {
        ZStack {
            // 1. 底层预览图
            if let image = camera.currentPreviewImage {
                Image(image, scale: 1.0, orientation: previewOrientation, label: Text("Preview"))
                    .resizable()
                    .scaledToFit()
                    .blur(radius: camera.isSwitchingLens ? 30 : 0)
                    .clipped()
            } else {
                Color.black
            }
            
            ZStack {
                WaveformOverlay()
                HistogramOverlay()
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            // 2. 整合后的交互层 (手势 + 对焦)
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            handleDrag(value, in: size)
                        }
                        .onEnded { _ in
                            lastDragLocation = nil
                            startHUDTimer()
                        }
                )
                .onTapGesture { location in
                    handleTapToFocus(at: location, in: size)
                }
            
            // 3. 数值反馈提示 (HUD)
            if showHUD {
                Text(hudText)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .transition(.opacity)
                    .zIndex(10) // 确保在对焦框下方或上方
            }
            
            // 4. 对焦框 UI
            if let fp = focusPoint {
                FocusBoxView()
                    .position(fp)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
    
    private func permissionRow(label: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
            Text(label).foregroundColor(.white)
        }
    }
    
    private var permissionDeniedView: some View {
        VStack(alignment: .center, spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Permission Needed")
                .font(.title3.bold())
                .foregroundColor(.white)

            // 💡 动态显示缺失哪个权限
            VStack(alignment: .leading, spacing: 8) {
                permissionRow(label: NSLocalizedString("CAMERA_ACCESS", tableName: "Localizable_variable" ,comment: ""), granted: camera.permissionManager.cameraPermission == .authorized)
                permissionRow(label: NSLocalizedString("PHOTO_LIB_ACCESS", tableName: "Localizable_variable" ,comment: ""), granted: camera.permissionManager.photoPermission == .authorized)
            }
            .padding()

            Button(NSLocalizedString("OPEN_SETTINGS", tableName: "Localizable_variable" ,comment: "")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
        .background(Color.black)
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
    

    private func handleTapToFocus(at location: CGPoint, in size: CGSize) {
        guard let image = camera.currentPreviewImage else { return }
        let portrait = previewOrientation == .right || previewOrientation == .left
        let imageSize = CGSize(width: CGFloat(portrait ? image.height : image.width),
                               height: CGFloat(portrait ? image.width : image.height))
        let rect = AVMakeRect(aspectRatio: imageSize, insideRect: CGRect(origin: .zero, size: size))
        guard rect.contains(location), rect.width > 0, rect.height > 0 else { return }
        let x = (location.x - rect.minX) / rect.width
        let y = (location.y - rect.minY) / rect.height
        var cameraPoint: CGPoint
        switch previewOrientation {
        case .right: cameraPoint = CGPoint(x: y, y: 1 - x)
        case .left: cameraPoint = CGPoint(x: 1 - y, y: x)
        case .down: cameraPoint = CGPoint(x: 1 - x, y: 1 - y)
        default: cameraPoint = CGPoint(x: x, y: y)
        }
        if lensManager.currentLens?.device.position == .front {
            cameraPoint.y = 1 - cameraPoint.y // Undo the front preview's downMirrored transform.
        }
        focusPoint = location
        camera.focus(at: cameraPoint)
        
        // 4. 自动隐藏对焦框
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            withAnimation { focusPoint = nil }
        }
    }
}

struct CaptureInteractionView: UIViewRepresentable {
    @ObservedObject var camera: Camera

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        
        // 仅在 iOS 17.2+ 支持捕获事件，iOS 18 会自动重定向音量键
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                // 确保在拍照开始瞬间触发，且不在教学状态下
                if event.phase == .began && !camera.isShowingTutorial {
                    camera.takePhoto()
                    
                    // 提供物理反馈感
                    let impact = UIImpactFeedbackGenerator(style: .heavy)
                    impact.impactOccurred()
                }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
