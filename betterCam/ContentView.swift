//
//  ContentView.swift
//  betterCam
//
//  Created by Rice on 2026/1/22.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject var camera = Camera()
    var body: some View {
        ZStack {
            // for debug
            BodyFrameBackground()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScreenView()
                        .wrapInCameraFrame(thickness: 20)
                        .recessedPanel()
                        .padding(.top)
                        .frame(height: UIScreen.main.bounds.height * 0.95)
                        
                }
                ControlDialView()
                    .padding(.leading, UIScreen.main.bounds.width * 0.1)
            }
            .statusBar(hidden: true)
            .environmentObject(camera)
            if camera.isShowingTutorial {
                TutorialOverlay(camera: camera)
                    .transition(.opacity)
                    .zIndex(99) // 确保在最上层
            }
        }
        .onChange(of: camera.isShowingTutorial) {
            isShowing in
            if !isShowing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    camera.callAllStartupFuncs()
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !camera.inCameraView }, // 如果不在相机视图，就显示管理页面
            set: { if $0 == false { camera.inCameraView = true } }
        )) {
            LUTManagerView(camera: camera)
        }
    }
}




#Preview {
    ContentView()
}
