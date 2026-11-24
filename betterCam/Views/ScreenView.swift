//
//  ScreenView.swift
//  betterCam
//
//  Created by Rice on 2026/1/24.
//
import SwiftUI

struct ScreenView: View {
    @EnvironmentObject var camera: Camera
    @EnvironmentObject private var lensManager: LensManager
    var body: some View {
        ZStack {
            CameraPreview()
                .background(Color.black)
            VStack(spacing: 0) {
                if lensManager.currentLens == nil || camera.permissionManager.isFullyAuthorized {
                    TopBarView()
                    Spacer()
                    BottomBarView()
                } else {
                    Spacer()
                    Color.clear
                        .frame(height: 40)
                }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }
}
