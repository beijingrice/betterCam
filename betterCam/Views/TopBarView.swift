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
                ParameterItem(
                    title: pm.imageQuality, index: UIWidgets.imageQuality.rawValue,
                    badge: CaptureMode.badge(
                        quality: pm.imageQuality, resolution: pm.photoResolutionMode,
                        zeroProcessing: pm.isPureRawEngineEnabled
                    )
                )
                Spacer()
                ParameterItem(title: lm.currentLens.map { $0.displayName ?? "\($0.equivalentFocalLength)mm" } ?? "-", index: UIWidgets.lensSwitch.rawValue)
                Spacer()
                ParameterItem(title: pm.AFMode, index: UIWidgets.AFMode.rawValue)
                Spacer()
                ParameterItem(
                    title: camera.isEditingCustomKelvin ? WhiteBalance.kelvinLabel(pm.customKelvin) : pm.WBMode,
                    index: UIWidgets.WBMode.rawValue
                )
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
