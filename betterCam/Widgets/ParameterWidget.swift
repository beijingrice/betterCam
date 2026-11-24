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
    var badge: CaptureMode.Badge? = nil
    @EnvironmentObject var camera: Camera

    private var isActive: Bool { camera.activeIndex == index }

    var body: some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            // The badge hangs off the top-right corner without taking layout width, so the
            // word itself never moves or rescales when the badge comes and goes.
            .overlay(alignment: .topTrailing) {
                if let badge { badgeLabel(badge).alignmentGuide(.trailing) { $0[.leading] } }
            }
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
            .accessibilityElement(children: .combine)
            .accessibilityValue(badge.map(accessibilityName) ?? "")
    }

    private func badgeLabel(_ badge: CaptureMode.Badge) -> some View {
        let text: String
        let color: Color
        switch badge {
        case .highResolution:
            text = "48"
            color = isActive ? .black : .white
        case .zeroProcessing:
            text = "Z"
            // Dark amber keeps the mark readable on the white highlight.
            color = isActive ? Color(red: 0.55, green: 0.4, blue: 0) : .yellow
        }
        return Text(verbatim: text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .offset(y: -2)
            .accessibilityHidden(true)
    }

    private func accessibilityName(_ badge: CaptureMode.Badge) -> String {
        switch badge {
        case .highResolution: "48MP"
        case .zeroProcessing: "ZERO PROCESSING"
        }
    }
}
