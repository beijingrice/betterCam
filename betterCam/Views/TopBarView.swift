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
            /*
            Text("\(camera.imageQuality)")
            Spacer()
            Text("\(camera.aspectRatio)")
            Spacer()
            Text("\(camera.AFMode)")
            Spacer()
            Text("\(camera.WBMode)")
             */
            
            ParameterItem(title: camera.imageQuality, index: 0)
            Spacer()
            ParameterItem(
                            title: camera.availableDevices.isEmpty ? "1x" :
                                   (camera.currentDeviceIndex == 0 ? "1x" :
                                    camera.currentDeviceIndex == 1 ? "0.5x" : "3x"),
                            index: 1
                        )
            Spacer()
            ParameterItem(title: camera.AFMode, index: 2)
            Spacer()
            ParameterItem(title: camera.WBMode, index: 3)
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
