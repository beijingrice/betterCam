//
//  ParameterWidget.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI

struct ParameterItem: View {
    let title: String
    let index: Int
    @EnvironmentObject var camera: Camera
    var body: some View {
        if camera.activeIndex == index {
            Text(title)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .foregroundColor(.black)
                .background(camera.isAdjustingValue ? Color.white.opacity(0.7) : Color.white.opacity(0.5))
        } else {
            Text(title)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
        }
    }
}
