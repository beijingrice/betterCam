//
//  BodyFrameBackground.swift
//  betterCam
//
//  Created by Rice on 2026/1/25.
//

import SwiftUI
struct BodyFrameBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.45, green: 0.45, blue: 0.46)
            
            LinearGradient(
                colors: [
                    .white.opacity(0.15),
                    .clear,
                    .black.opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            RadialGradient(
                colors: [.white.opacity(0.5), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 700
            )
            
            BodyGrainLayer()
        }
        .ignoresSafeArea()
        
    }
}
