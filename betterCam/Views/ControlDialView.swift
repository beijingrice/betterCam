//
//  ControlDialView.swift
//  betterCam
//
//  Created by Rice on 2026/1/24.
//
import SwiftUI
struct ControlDialView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            KnurledDialView()
                .padding(.bottom, 60)
            ShutterButtonView()
            Spacer()
        }
    }
}
