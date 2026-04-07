//
//  ToolFuncs.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//

import Foundation
import AVFoundation
import SwiftUI
func changeParameter(for camera: Camera, direction: Int) {
    
    if camera.isAdjustingValue {
        adjustValue(for: camera, direction: direction)
    } else {
        var pendingIndex: Int = 0
        let newIndex = camera.activeIndex + direction
        if newIndex >= camera.maxWidgetIndex + 2 { // direction = positive
            pendingIndex = 0
        } else if newIndex < 0 { // direction = negative
            pendingIndex = camera.maxWidgetIndex + 1 // go to nothing selected index
        } else {
            pendingIndex = newIndex
        }
        DispatchQueue.main.async {
            camera.activeIndex = pendingIndex
        }
    }
}

func adjustValue(for camera: Camera, direction: Int) {
    // 提前把 pm 和 lm 拿出来，让代码更干净
    let pm = camera.parameterManager
    let lm = camera.lensManager
    
    switch camera.activeIndex {
    case UIWidgets.AFMode.rawValue:
        pm.AFMode = nextOption(in: pm.AFModeOptions, current: pm.AFMode, direction: direction)
        
    case UIWidgets.Style.rawValue:
        pm.style = nextOption(in: pm.styleOptions, current: pm.style, direction: direction)
        
    case UIWidgets.SS.rawValue:
        pm.SS = nextOption(in: pm.actualSSoptions, current: pm.SS, direction: direction)
        
    case UIWidgets.EV.rawValue:
        let isManualMode = (pm.SS != "AUTO" && pm.ISO != "AUTO")
        if !isManualMode {
            pm.EV = nextOption(in: pm.EVOptions, current: pm.EV, direction: direction, isEV: true)
        }
        
    case UIWidgets.ISO.rawValue:
        pm.ISO = nextOption(in: pm.actualISOoptions, current: pm.ISO, direction: direction)
        
    case UIWidgets.lensSwitch.rawValue:
        lm.switchLens(direction: direction)
        
    case UIWidgets.imageQuality.rawValue:
        pm.imageQuality = nextOption(in: pm.imageQualityOptions, current: pm.imageQuality, direction: direction)
        
    default:
        break
    }
}

func nextOption(in options: [String], current: String, direction: Int, isEV: Bool = false) -> String {
    guard !options.isEmpty else { return current }
    let currentIndex = options.firstIndex(of: current) ?? 0
    var nextIndex: Int = 0
    if !isEV {
        nextIndex = (currentIndex + direction) % options.count
    } else {
        // is EV mode
        if (currentIndex + direction) >= options.count {
            nextIndex = currentIndex
        } else
        if (currentIndex + direction) < 0 {
            nextIndex = currentIndex
        } else {
            nextIndex = currentIndex + direction
        }
    }
    if nextIndex < 0 {
        nextIndex = options.count - 1
    }
    return options[nextIndex]
}

extension Array where Element == String {
    func supportedISO(for device: AVCaptureDevice) -> [String] {
        let maxISO = device.activeFormat.maxISO
        let minISO = device.activeFormat.minISO
        
        return self.filter {
            if $0 == "AUTO" { return true }
            guard let val = Float($0) else { return false }
            return val >= minISO && val <= maxISO
        }
    }
    
    func supportedSS(for device: AVCaptureDevice) -> [String] {
        let minSeconds = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxSeconds = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        
        return self.filter {
            if $0 == "AUTO" { return true }
            
            // 💡 修复点：调用一个自定义转换函数，支持处理 "/" 符号
            guard let val = parseShutterSpeedToDouble($0) else { return false }
            
            // 浮点数比较建议加一个极小的余量（epsilon），防止精度误差
            return val >= (minSeconds - 0.00001) && val <= (maxSeconds + 0.00001)
        }
    }
    
    func formattedISOoptions() -> [String] {
        return self.map {
            isoItem in Int(isoItem) != nil ? "ISO \(isoItem)" : isoItem
        }
    }

    // 辅助函数：把 "1/100" 转为 0.01
    private func parseShutterSpeedToDouble(_ string: String) -> Double? {
        if let doubleValue = Double(string) {
            return doubleValue // 处理 "1", "0.8" 等直接数值
        }
        
        // 处理 "1/100" 这种分数格式
        let components = string.components(separatedBy: "/")
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            return numerator / denominator
        }
        
        return nil
    }
}
