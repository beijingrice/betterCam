//
//  ControlDialView.swift
//  betterCam
//
//  Created by Rice on 2026/1/24.
//
import SwiftUI
struct ControlDialView: View {
    let dialSize: CGFloat
    let verticalSpacing: CGFloat

    var body: some View {
        VStack(spacing: verticalSpacing) {
            KnurledDialView(dialSize: dialSize)
            ShutterButtonView()
        }
        .fixedSize()
    }
}
