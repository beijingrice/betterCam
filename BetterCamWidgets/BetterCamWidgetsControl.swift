//
//  BetterCamWidgetsControl.swift
//  BetterCamWidgets
//
//  Created by Rice on 2026/2/7.
//

import WidgetKit
import AppIntents
import SwiftUI

struct BetterCamWidgetsControl: ControlWidget {
    // 💡 这个 ID 必须唯一
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.rice.betterCam.cameraLauncher") {
            // 💡 使用 ControlWidgetButton 并关联你的 Intent
            ControlWidgetButton(action: StartBetterCamIntent()) {
                // 这里定义图标和文字
                Label("BetterCam", systemImage: "camera.fill")
            }
        }
        .displayName("BetterCam") // 控件库里显示的名字
        .description("Launch BetterCam")
    }
}
