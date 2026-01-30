//
//  ScreenView.swift
//  betterCam
//
//  Created by Rice on 2026/1/24.
//
import SwiftUI
internal import UniformTypeIdentifiers

struct ScreenView: View {
    @EnvironmentObject var camera: Camera
    @State private var tempLUTData: Data? = nil
    @State private var showRenameAlert = false
    @State private var newLUTName = ""
    @State private var tempDimension: Int = 0
    var body: some View {
        ZStack {
            CameraPreview()
                .background(Color.black)
            VStack(spacing: 0) {
                TopBarView()
                Spacer()
                BottomBarView()
            }
        }
        .aspectRatio(4/3, contentMode: .fit)
    }
}
