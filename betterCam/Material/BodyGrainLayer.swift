//
//  BodyGrainLayer.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI

struct BodyGrainLayer: View {
    var body: some View {
        Image("camera_body_noise")
            .resizable(resizingMode: .tile)
            .opacity(1.0)
            .blendMode(.overlay)
            .ignoresSafeArea()
    }
}

