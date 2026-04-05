//
//  ShutterSoundManager.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//
import Foundation
import AudioToolbox // 💡 必须导入这个来处理 SystemSoundID

// TODO: Implement calls to this class in camera.swift

// TODO: Save shutter sound prefered
// private var oldShutterSoundMode: ShutterSoundMode = .sony
// @AppStorage("shutterSoundMode") var shutterSoundMode: ShutterSoundMode = .sony

class ShutterSoundManager {
    private var shutterSoundID: SystemSoundID = 0
    
    // 💡 搬迁 setup 逻辑
    func setupSound(named fileName: String) {
        // 1. 销毁旧 ID 防止泄漏
        if shutterSoundID != 0 {
            AudioServicesDisposeSystemSoundID(shutterSoundID)
            shutterSoundID = 0
        }
        
        // 2. 加载音频文件
        guard let soundURL = Bundle.main.url(forResource: fileName, withExtension: "aac") else {
            print("❌ ShutterSoundManager: 找不到音频文件 \(fileName).aac")
            return
        }
        
        let status = AudioServicesCreateSystemSoundID(soundURL as CFURL, &shutterSoundID)
        if status == kAudioServicesNoError {
            print("✅ ShutterSoundManager: 已加载 \(fileName)")
        }
    }
    
    // 💡 搬迁播放逻辑
    func play() {
        if shutterSoundID != 0 {
            AudioServicesPlaySystemSound(shutterSoundID)
        }
    }
    
    // 💡 析构时确保释放内存
    deinit {
        if shutterSoundID != 0 {
            AudioServicesDisposeSystemSoundID(shutterSoundID)
        }
    }
}
