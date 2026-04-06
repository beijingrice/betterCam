//
//  ContentView.swift
//  betterCam
//
//  Created by Rice on 2026/1/22.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase
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
        .environmentObject(camera)
        .environmentObject(camera.parameterManager) // 💡 必须加上
        .environmentObject(camera.lensManager)
        .onChange(of: camera.isShowingTutorial) {
            isShowing in
            if !isShowing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    camera.callAllStartupFuncs()
                }
            }
        }
        .onChange(of: scenePhase) {
            // 💡 直接用外层的变量，不需要写 "newPhase in"
            if scenePhase == .background {
                camera.parameterManager.saveExposureParameters()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !camera.inCameraView }, // 如果不在相机视图，就显示管理页面
            set: { if $0 == false { camera.inCameraView = true } }
        )) {
            LUTManagerView(camera: camera)
        }
        .fullScreenCover(isPresented: Binding(
            get: {camera.isShowingMenu},
            set: { if $0 == true { camera.isShowingMenu = false }} )) {
                MenuView(camera: camera)
            }
    }
}


struct ContentViewPortrait: View {
    @StateObject var camera = Camera()
    var body: some View {
        GeometryReader { geo in
            
            let landscapeWidth = geo.size.height
            let landscapeHeight = geo.size.width
            
            ZStack {
                BodyFrameBackground()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ScreenView()
                            .wrapInCameraFrame(thickness: 20)
                            .recessedPanel()
                            .frame(height: landscapeHeight * 0.90)
                        
                    }
                    ControlDialView()
                        .padding(.leading, landscapeWidth * 0.1)
                }
                .frame(width: landscapeWidth, height: landscapeHeight)
                .rotationEffect(.degrees(90))
                .offset(x: (geo.size.width - landscapeWidth) / 2,
                            y: 0)
                .statusBar(hidden: true)
                .environmentObject(camera)
                // FOR DEBUG, camera.isShowingTutorial
                if camera.isShowingTutorial {
                    TutorialOverlay(camera: camera)
                        //.frame(width: landscapeWidth, height: landscapeHeight)
                        //.ignoresSafeArea()
                        //.rotationEffect(.degrees(90))
                        //.offset(x: (geo.size.width - landscapeWidth) / 2,y: 0)
                        .transition(.opacity)
                        .zIndex(99) // 确保在最上层
                }
            }   // START OF PROPERTIES
            .environmentObject(camera)
            .environmentObject(camera.parameterManager) // 💡 必须加上
            .environmentObject(camera.lensManager)
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
            .fullScreenCover(isPresented: Binding(
                get: {camera.isShowingMenu},
                set: { if $0 == true { camera.isShowingMenu = false }} )) {
                    MenuView(camera: camera)
                }
            // END OF PROPERTIES
        }
        
    }
}

#Preview {
    ContentView()
}
