//
//  betterCamApp.swift
//  betterCam
//
//  Created by Rice on 2026/1/22.
//

import SwiftUI
import AppIntents

@main
struct betterCamApp: App {
    
    @StateObject private var storeManager = StoreManager()
    
    init() {
        ShutterManager.cleanupOldData()
        ShutterManager.resetSession()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentViewPortrait()
                .environmentObject(storeManager)
        }
    }
}
