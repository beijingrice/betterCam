//
//  TopBarView.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI

struct TopBarView: View {
    @EnvironmentObject var camera: Camera
    var body: some View {
        HStack {
            ParameterItem(title: camera.imageQuality, index: UIWidgets.imageQuality.rawValue)
            Spacer()
            ParameterItem(
                title: String(camera.currentFocalLength) + "mm",
                index: UIWidgets.lensSwitch.rawValue
            )
            Spacer()
            ParameterItem(title: camera.AFMode, index: UIWidgets.AFMode.rawValue)
            Spacer()
            ParameterItem(title: camera.WBMode, index: UIWidgets.WBMode.rawValue)
            Spacer()
            ParameterItem(title: "MENU", index: UIWidgets.MENU.rawValue)
        }
        .padding()
        .frame(height: 40)
        .background(Color.black.opacity(0.5))
        .foregroundColor(.white)
        .font(.system(size: 14, weight: .bold, design: .monospaced))
    }
}

#Preview {
    TopBarView()
        .environmentObject(Camera())
}
