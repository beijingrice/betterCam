//
//  CameraIntent.swift
//  betterCam
//
//  Created by Rice on 2026/2/7.
//

import AppIntents
import WidgetKit
import Foundation
import SwiftUI

// 💡 显式指定版本并使用最基础的协议组合
@available(iOS 18.0, *)
struct StartBetterCamIntent: AppIntent, ControlConfigurationIntent {
    // 💡 日本语本地化
    static var title: LocalizedStringResource = "Launch BetterCam"
    
    // 💡 关键：必须设置为 true 才能拉起主 App
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // 记录启动来源，用于主 App 识别
        UserDefaults.standard.set(true, forKey: "launchedByActionButton")
        return .result()
    }
}
