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
    static var title: LocalizedStringResource = "Launch BetterCam"
    
    // 💡 关键：必须设置为 true 才能拉起主 App
    static var openAppWhenRun: Bool = true

    @MainActor
        func perform() async throws -> some IntentResult {
            // 💡 必须使用 App Group，否则主 App 读不到这个标记
            let prefs = UserDefaults(suiteName: "group.com.rice.betterCam")
            prefs?.set(true, forKey: "launchedByActionButton")
            
            // 记录启动时间戳，防止主 App 重复响应旧的启动请求
            prefs?.set(Date().timeIntervalSince1970, forKey: "lastActionButtonTriggerTime")
            
            return .result()
        }
}
