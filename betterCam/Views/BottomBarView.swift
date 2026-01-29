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
                ParameterItem(title: camera.SS, index: 4)
                Spacer()
                ParameterItem(title: camera.Aperture, index: 5)
                Spacer()
                ParameterItem(title: camera.EV, index: 6)
                Spacer()
                ParameterItem(title: camera.ISO, index: 7)
                Spacer()
                ParameterItem(title: camera.style, index: 8)
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
