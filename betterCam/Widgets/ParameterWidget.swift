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
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .foregroundColor(camera.activeIndex == index ? .black : .white)
            .background(camera.activeIndex == index
                        ? Color.white.opacity(camera.isAdjustingValue ? 0.7 : 0.5) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                camera.activeIndex = index
                camera.isAdjustingValue = false
            }
    }
}
