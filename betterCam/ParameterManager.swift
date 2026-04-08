//
//  ParameterManager.swift
//  betterCam
//
//  Created by Rice on 2026/4/4.
//

import Foundation
import SwiftUI
import Combine
import WidgetKit

class ParameterManager: ObservableObject {
    // 💡 1. 搬迁参数状态
    @Published var SS: String = "1/200"
    @Published var ISO: String = "100"
    @Published var EV: String = "0.0"
    @Published var style: String = "STD"
    @Published var imageQuality: String = "JPEG"
    @Published var AFMode: String = "AF-C"
    @Published var WBMode: String = "AWB"
    @Published var Aperture: String = "F1.8"
    @Published var aspectRatio: String = "4:3"
    @Published var currentFocalLength: Int = 26
    
    @Published var actualSSoptions: [String] = []
    @Published var actualISOoptions: [String] = []
    @Published var styleOptions: [String] = []
    let imageQualityOptions: [String] = ["DNG+J", "DNG", "JPEG"]
    let AFModeOptions: [String] = ["AF-C", "AF-S"]
    let EVOptions: [String] = ParameterAvailable.EVoptions
    // TODO: Pass lens SS & ISO info to lists above
        
    // Apply changes in next launch, okay with @AppStorage
    @AppStorage("enablePermanentParameterStorage") var enablePermanentStorage: Bool = false
    let enablePermanentParameterStorageKey: String = "enablePermanentParameterStorage"
    @AppStorage("perferAUTO") var perferAUTO: Bool = false
    let perferAUTOKey: String = "perferAUTO"
    
    // Apply changes immediately, requires UserDefaults & @Published
    @Published var enableFrontCamera: Bool = false
    let enableFrontCameraKey: String = "enableFrontCamera"
    @Published var shutterSoundSelection: ShutterSoundMode = .sony
    let shutterSoundSelectionKey: String = "shutterSoundSelection"
    @Published var isPureRawEngineEnabled: Bool = false
    let isPureRawEngineEnabledKey: String = "isPureRawEngineEnabled"
    
    // UserDefaults, but shared with home screen widget
    let prefs = UserDefaults(suiteName: "group.com.rice.betterCam")
        
    private var cancellables = Set<AnyCancellable>()
    
    // 💡 新增：记录上一次的手动值，以及防死循环的“互斥锁”
    private var lastSS: String = "1/200"
    private var lastISO: String = "ISO 100"
    private var isAutoUpdating: Bool = false
        
    init() {
        // 启动时自动加载
        syncAllLUTsToOptions()
        loadExposureParameters()
        loadPublishedParameters()
        setupAutoSync()
        setupAutoModeLogic() // 💡 注册联动监听
        setupSettingsSync()
        
    }
    
    func syncAllLUTsToOptions() {
        // 获取 FilmEngine 里所有的胶片名（包括内置和用户导入的）
        let allNames = FilmEngine.shared.availableSimulations.map { $0.name }
        styleOptions = []
        for name in allNames {
            if !styleOptions.contains(name) {
                // TODO: Change it back to ADD
                styleOptions.append(name)
            }
        }
        if !styleOptions.contains("MANAGE") {
            styleOptions.append("MANAGE")
        }
    }
        
    // 💡 3. 参数持久化逻辑
    func saveExposureParameters() {
        guard enablePermanentStorage else { return }
        UserDefaults.standard.set(SS, forKey: "SS")
        UserDefaults.standard.set(ISO, forKey: "ISO")
        prefs?.set(SS, forKey: "last_SS")
        prefs?.set(ISO, forKey: "last_ISO")
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    func savePublishedParameters() {
        UserDefaults.standard.set(enableFrontCamera, forKey: enableFrontCameraKey)
        UserDefaults.standard.setEnum(shutterSoundSelection, forKey: shutterSoundSelectionKey)
        UserDefaults.standard.set(isPureRawEngineEnabled, forKey: isPureRawEngineEnabledKey)
    }
    
    func loadPublishedParameters() {
        self.enableFrontCamera = UserDefaults.standard.bool(forKey: enableFrontCameraKey)
        self.isPureRawEngineEnabled = UserDefaults.standard.bool(forKey: isPureRawEngineEnabledKey)
        self.shutterSoundSelection = UserDefaults.standard.getEnum(type: ShutterSoundMode.self, forKey: shutterSoundSelectionKey) ?? .sony
    }
        
    func loadExposureParameters() {
        if perferAUTO {
            self.SS = "AUTO"
            self.ISO = "AUTO"
            prefs?.set(SS, forKey: "last_SS")
            prefs?.set(ISO, forKey: "last_ISO")
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        if enablePermanentStorage {
            self.SS = UserDefaults.standard.string(forKey: "SS") ?? "1/200"
            self.ISO = UserDefaults.standard.string(forKey: "ISO") ?? "ISO 100"
            
            // 💡 恢复参数时，顺便更新 last 记录，防止一拨轮子就乱跳
            if self.SS != "AUTO" { self.lastSS = self.SS }
            if self.ISO != "AUTO" { self.lastISO = self.ISO }
        }
    }
    
    private func setupSettingsSync() {
        // 监听这三个配置项的任何风吹草动
        Publishers.CombineLatest3($enableFrontCamera, $isPureRawEngineEnabled, $shutterSoundSelection)
            .dropFirst() // 忽略 init() 里面 loadPublishedParameters() 造成的初始赋值触发
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main) // 稍微加一点点防抖，防止 UI 狂点
            .sink { [weak self] _, _, _ in
                self?.savePublishedParameters()
                print("✅ [ParameterManager] 设置已自动存入 UserDefaults")
            }
            .store(in: &cancellables)
    }
    
    private func setupAutoSync() {
        // 监听所有可能需要存盘的参数
        Publishers.CombineLatest($SS, $ISO)
                    .debounce(for: .seconds(1), scheduler: RunLoop.main)
                    .sink { [weak self] _, _ in self?.saveExposureParameters() }
                    .store(in: &cancellables)
    }
    
    // MARK: - AUTO 联动逻辑 (替代以前的 autoAmode 和 didSet)
    
    private func setupAutoModeLogic() {
        // 监听 SS 变化
        $SS.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
                    .sink { [weak self] newSS in self?.handleSSChange(newSS) }
                    .store(in: &cancellables)
                // 监听 ISO 变化
        $ISO.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
                    .sink { [weak self] newISO in self?.handleISOChange(newISO) }
                    .store(in: &cancellables)
    }
    
    private func handleSSChange(_ newSS: String) {
        // 🔒 如果是内部联动引起的改变，直接拦截，防止死循环
        guard !isAutoUpdating else { return }
        isAutoUpdating = true
        defer {
            isAutoUpdating = false
        } // 💡 defer 保证在这个函数结束时，锁一定会解开

        if newSS == "AUTO" && ISO != "AUTO" {
            lastISO = ISO
            ISO = "AUTO"
            EV = "0.0"
        } else if newSS != "AUTO" && ISO == "AUTO" {
            ISO = lastISO
        }
    }
    
    private func handleISOChange(_ newISO: String) {
        // 🔒 防死循环拦截
        guard !isAutoUpdating else { return }
        isAutoUpdating = true
        defer { isAutoUpdating = false }

        if newISO == "AUTO" && SS != "AUTO" {
            lastSS = SS
            SS = "AUTO"
            EV = "0.0"
        } else if newISO != "AUTO" && SS == "AUTO" {
            SS = lastSS
        }
    }
}

extension UserDefaults { // enum packaging
    func setEnum<T: RawRepresentable>(_ value: T, forKey key: String) where T.RawValue == String {
        set(value.rawValue, forKey: key)
    }
    
    func getEnum<T: RawRepresentable>(type: T.Type, forKey key: String) -> T? where T.RawValue == String {
        guard let rawValue = string(forKey: key) else { return nil }
        return T(rawValue: rawValue)
    }
}

extension Publisher where Failure == Never, Output: Equatable {
    func syncChange(
        on object: AnyObject,
        action: @escaping (Output) -> Void
    ) -> AnyCancellable {
        return self
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak object] newValue in
                guard object != nil else { return }
                action(newValue)
            }
    }
}
