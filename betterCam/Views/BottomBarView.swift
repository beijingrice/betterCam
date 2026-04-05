//
//  BottomBarView.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI

struct BottomBarView: View {
    @EnvironmentObject var camera: Camera
    @EnvironmentObject var pm: ParameterManager
    @EnvironmentObject var lm: LensManager
    var body: some View {
        HStack(spacing: 0) {
            Group {
                ParameterItem(title: pm.SS, index: UIWidgets.SS.rawValue)
                Spacer()
                ParameterItem(title: pm.Aperture, index: UIWidgets.aperture.rawValue)
                Spacer()
                ParameterItem(title: pm.EV, index: UIWidgets.EV.rawValue)
                Spacer()
                ParameterItem(title: pm.ISO, index: UIWidgets.ISO.rawValue)
                Spacer()
                ParameterItem(title: pm.style, index: UIWidgets.Style.rawValue)
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
