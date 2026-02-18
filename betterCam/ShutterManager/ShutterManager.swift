//
//  ShutterManager.swift
//  betterCam
//
//  Created by Rice on 2026/2/18.
//

import Foundation
import WidgetKit

struct ShutterManager {
    static let suiteName = "group.com.rice.betterCam"
    static let TOTAL_SHUTTER_KEY: String = "total_shutter"
    
    static var sessionCount: Int = 0
    
    static func incrementShutter() {
        guard let prefs = UserDefaults(suiteName: suiteName) else { return }
        let total = prefs.integer(forKey: TOTAL_SHUTTER_KEY)
        prefs.set(total + 1, forKey: TOTAL_SHUTTER_KEY)
        
        let todayKey = getTodayKey()
        let todayCount = prefs.integer(forKey: todayKey)
        prefs.set(todayCount + 1, forKey: todayKey)
        
        sessionCount += 1
        prefs.set(sessionCount, forKey: "session_count")
        
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    static func cleanupOldData() {
        guard let prefs = UserDefaults(suiteName: suiteName) else { return }
        let allKeys = prefs.dictionaryRepresentation().keys
        let todayKey = getTodayKey()
        
        // 找出所有以 "shutter_" 开头但不是今天 Key 的键
        let keysToRemove = allKeys.filter { $0.hasPrefix("shutter_") && $0 != todayKey }
        
        for key in keysToRemove {
            prefs.removeObject(forKey: key)
        }
        
        print("清理了 \(keysToRemove.count) 条旧快门数据")
    }
    
    static func resetSession() {
        sessionCount = 0
        UserDefaults(suiteName: suiteName)?.set(0, forKey: "session_count")
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    static func getTodayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return "shutter_\(formatter.string(from: Date()))"
    }
}
