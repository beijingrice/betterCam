//
//  BottomBarView.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI

struct BottomBarView: View {
    @EnvironmentObject var camera: Camera
    var body: some View {
        HStack(spacing: 0) {
            Group {
                ParameterItem(title: camera.SS, index: UIWidgets.SS.rawValue)
                Spacer()
                ParameterItem(title: camera.Aperture, index: UIWidgets.aperture.rawValue)
                Spacer()
                ParameterItem(title: camera.EV, index: UIWidgets.EV.rawValue)
                Spacer()
                ParameterItem(title: camera.ISO, index: UIWidgets.ISO.rawValue)
                Spacer()
                ParameterItem(title: camera.style, index: UIWidgets.Style.rawValue)
            } 
        }
        .frame(height: 40)
        .background(Color.black.opacity(0.5))
        .foregroundColor(.white)
        .font(.system(size: 16, weight: .medium, design: .monospaced))
        .clipped()
    }
}

#Preview {
    BottomBarView()
        .environmentObject(Camera())
}
