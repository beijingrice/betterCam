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

enum ExposureParameter {
    static let auto = "AUTO"
    private static let preferredTimescale: CMTimeScale = 1_000_000_000
    
    static func isoValue(_ string: String) -> Float? {
        return Float(normalizedISO(string))
    }
    
    static func normalizedISO(_ string: String) -> String {
        if string.hasPrefix("ISO ") {
            return String(string.dropFirst(4))
        }
        return string
    }
    
    static func clampedISO(_ iso: Float, for lens: Lens) -> Float {
        return min(max(iso, lens.minISO), lens.maxISO)
    }
    
    static func shutterSeconds(_ string: String) -> Double? {
        if let doubleValue = Double(string), doubleValue > 0 {
            return doubleValue
        }
        
        let components = string.components(separatedBy: "/")
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           numerator > 0,
           denominator > 0 {
            return numerator / denominator
        }
        
        return nil
    }
    
    static func shutterDuration(_ string: String) -> CMTime? {
        guard let seconds = shutterSeconds(string) else { return nil }
        return CMTime(seconds: seconds, preferredTimescale: preferredTimescale)
    }
    
    static func clampedDuration(_ duration: CMTime, for lens: Lens) -> CMTime {
        if CMTimeCompare(duration, lens.minExposureDuration) < 0 {
            return lens.minExposureDuration
        }
        if CMTimeCompare(duration, lens.maxExposureDuration) > 0 {
            return lens.maxExposureDuration
        }
        return duration
    }
    
    static func validatedSS(_ ss: String, options: [String]) -> String {
        return nearestOption(in: options, current: ss, value: shutterSeconds)
    }
    
    static func validatedISO(_ iso: String, options: [String]) -> String {
        let normalized = normalizedISO(iso)
        return nearestOption(in: options, current: normalized) {
            guard let value = isoValue($0) else { return nil }
            return Double(value)
        }
    }
    
    private static func nearestOption(in options: [String], current: String, value: (String) -> Double?) -> String {
        guard !options.isEmpty else { return current }
        if options.contains(current) { return current }
        if current == auto { return options.contains(auto) ? auto : (options.first ?? current) }
        
        let manualOptions = options.filter { $0 != auto }
        guard let currentValue = value(current) else { return manualOptions.first ?? options.first ?? current }
        
        return manualOptions.min {
            guard let left = value($0), let right = value($1) else { return false }
            return abs(left - currentValue) < abs(right - currentValue)
        } ?? manualOptions.first ?? options.first ?? current
    }
}

extension Array where Element == String {
    func supportedISO(for device: AVCaptureDevice) -> [String] {
        let maxISO = device.activeFormat.maxISO
        let minISO = device.activeFormat.minISO
        
        return self.filter {
            if $0 == ExposureParameter.auto { return true }
            guard let val = ExposureParameter.isoValue($0) else { return false }
            return val >= minISO && val <= maxISO
        }
    }
    
    func supportedSS(for device: AVCaptureDevice) -> [String] {
        return self.filter {
            if $0 == ExposureParameter.auto { return true }
            guard let duration = ExposureParameter.shutterDuration($0) else { return false }
            let minDuration = device.activeFormat.minExposureDuration
            let maxDuration = device.activeFormat.maxExposureDuration
            return CMTimeCompare(duration, minDuration) >= 0 && CMTimeCompare(duration, maxDuration) <= 0
        }
    }
    
    func formattedISOoptions() -> [String] {
        return self.map {
            isoItem in Int(isoItem) != nil ? "ISO \(isoItem)" : isoItem
        }
    }
}
