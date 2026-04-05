//
//  TopBarView.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI

struct TopBarView: View {
    @EnvironmentObject var camera: Camera
    @EnvironmentObject var pm: ParameterManager
    @EnvironmentObject var lm: LensManager
    var body: some View {
        HStack (spacing: 0){
            Group {
                ParameterItem(title: pm.imageQuality, index: UIWidgets.imageQuality.rawValue)
                Spacer()
                ParameterItem(
                    title: String(lm.currentLens.equivalentFocalLength) + "mm",
                    index: UIWidgets.lensSwitch.rawValue
                )
                Spacer()
                ParameterItem(title: pm.AFMode, index: UIWidgets.AFMode.rawValue)
                Spacer()
                ParameterItem(title: pm.WBMode, index: UIWidgets.WBMode.rawValue)
                Spacer()
                ParameterItem(title: "MENU", index: UIWidgets.MENU.rawValue)
            }
        }
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
