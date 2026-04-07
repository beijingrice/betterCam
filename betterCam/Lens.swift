//
//  Lens.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//

import Foundation
import AVFoundation
struct Lens {
    let device: AVCaptureDevice
    let equivalentFocalLength: Int
    let aperture: String
    var availableSSoptions: [String]
    var availableISOoptions: [String]
    var maxISO: Float
    var minISO: Float
    var displayName: String?
    
    init(device: AVCaptureDevice) {
        self.device = device
        self.aperture = Lens.getAperture(device: device)
        self.equivalentFocalLength = Lens.getFocalLength(device: device)
        self.availableSSoptions = ParameterAvailable.SSoptions.supportedSS(for: device)
        self.availableISOoptions = ParameterAvailable.ISOoptions.supportedISO(for: device)
        let numericISOs = self.availableISOoptions.compactMap { Float($0) }
        self.minISO = numericISOs.min() ?? device.activeFormat.minISO
        self.maxISO = numericISOs.max() ?? device.activeFormat.maxISO
        print("minISO\(self.minISO) maxISO\(self.maxISO)")
        self.displayName = nil
    }
    
    mutating func refreshCapabilities() {
        self.availableSSoptions = ParameterAvailable.SSoptions.supportedSS(for: device)
        self.availableISOoptions = ParameterAvailable.ISOoptions.supportedISO(for: device)
        
        let numericISOs = self.availableISOoptions.compactMap { Float($0) }
        self.minISO = numericISOs.min() ?? device.activeFormat.minISO
        self.maxISO = numericISOs.max() ?? device.activeFormat.maxISO
        print("✅ Lens 已刷新极限: \(self.minISO) ~ \(self.maxISO)")
    }
    
    static func getAperture(device: AVCaptureDevice) -> String {
        do {
            try device.lockForConfiguration()
            let aperture = device.lensAperture
            let finalAperture = aperture > 0 ? aperture : (device.lensAperture > 0 ? device.lensAperture: 1.8)
            return String(format: "F%.1f", finalAperture)
        } catch {
            print("Error when fetching aperture!")
        }
        return "F1.8"
    }
    
    static func getFocalLength(device: AVCaptureDevice) -> Int {
        print("Now calculating focal length for device:", device)
        let baseFormat = device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // 寻找比例接近 1.33 (4:3) 且分辨率够高的格式
            return Double(dims.width) / Double(dims.height) < 1.5
        } ?? device.activeFormat
        let hFOV = baseFormat.videoFieldOfView
        //let hFOV = device.activeFormat.videoFieldOfView
        print("hFOV is:", hFOV)
        let radians = hFOV * Float.pi / 180.0
        var calculatedEquivalent = 36.0 / (2.0 * tan(radians / 2.0))
        print("\(calculatedEquivalent)mm")
        
        if device.deviceType == .builtInUltraWideCamera {
            if calculatedEquivalent >= 13 && calculatedEquivalent <= 15 {
                calculatedEquivalent = 13
            }
        }
        
        // 2. 针对主摄进行硬校准
        // iPhone 主摄在预览流下算出来常为 26.8-27.2，但在全像素下是 24 或 26
        if device.deviceType == .builtInWideAngleCamera {
            // 根据不同机型微调，通常主摄强制归位到 24 或 26 看起来最自然
            if calculatedEquivalent > 23 && calculatedEquivalent < 28 {
                // 这里可以根据你的 iPhone 15/16 Pro 经验，如果是 27 左右就显示 26
                if calculatedEquivalent > 26.5 {
                    print(calculatedEquivalent)
                    calculatedEquivalent = 26
                } else {
                    print(calculatedEquivalent)
                    calculatedEquivalent = 24
                }
            }
        }
        
        // 3. 针对长焦 (Telephoto)
        // 长焦常算出来是 78，系统显示 77；或算出来 122，系统显示 120
        if device.deviceType == .builtInTelephotoCamera {
            if calculatedEquivalent > 70 && calculatedEquivalent < 80 { calculatedEquivalent = 72 }
            if calculatedEquivalent > 110 && calculatedEquivalent < 125 { calculatedEquivalent = 120 }
            if calculatedEquivalent > 95 && calculatedEquivalent < 105 { calculatedEquivalent = 100 }
        }
        
        return Int(round(calculatedEquivalent))
    }
    
}
