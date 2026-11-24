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

    var body: some View {
        ParameterLabel(title: title, badge: badge, isActive: camera.activeIndex == index)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(camera.activeIndex == index
                        ? Color.white.opacity(camera.isAdjustingValue ? 0.7 : 0.5) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                camera.activeIndex = index
                camera.isAdjustingValue = false
            }
    }
}

/// A top-bar label with an optional half-width badge after its top-right corner.
struct ParameterLabel: View {
    let title: String
    var badge: CaptureMode.Badge? = nil
    var isActive = false

    var body: some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            // A zero-width frame pinned to the word's trailing edge holds the badge, which
            // spills to the right of it. The word keeps its width and position, and the
            // badge never sits on top of the last letter.
            .overlay(alignment: .topTrailing) {
                if let badge {
                    badgeText(badge)
                        .fixedSize()
                        .padding(.leading, 1)
                        .frame(width: 0, alignment: .leading)
                }
            }
            .foregroundColor(isActive ? .black : .white)
            .accessibilityElement(children: .combine)
            .accessibilityValue(badge.map(accessibilityName) ?? "")
    }

    private func badgeText(_ badge: CaptureMode.Badge) -> some View {
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
