//
//  Constants.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//

import Foundation

enum ParameterAvailable {
    static let ISOoptions: [String] = ["AUTO", "50", "64", "100", "125", "160", "200", "250", "320", "400", "500", "640", "800", "1000", "1250", "1600", "2000", "2500", "3200", "4000", "5000", "6400"]
    static let SSoptions = [
        "AUTO", "1", "0.8", "0.6", "0.5", "0.4", "1/3", "1/4", "1/5", "1/6",
        "1/8", "1/10", "1/13", "1/15", "1/20", "1/25", "1/30", "1/40", "1/50",
        "1/60", "1/80", "1/100", "1/125", "1/160", "1/200", "1/250", "1/320",
        "1/400", "1/500", "1/640", "1/800", "1/1000", "1/1250", "1/1600",
        "1/2000", "1/2500", "1/3200", "1/4000", "1/5000", "1/6400", "1/8000",
        "1/10000", "1/12500", "1/16000", "1/20000", "1/25000", "1/32000",
        "1/40000", "1/50000", "1/64000"
    ]
    static let EVoptions = [
        "-5.0", "-4.7", "-4.3", "-4.0", "-3.7", "-3.3", "-3.0", "-2.7", "-2.3", "-2.0",
        "-1.7", "-1.3", "-1.0", "-0.7", "-0.3", "0.0",
        "+0.3", "+0.7", "+1.0", "+1.3", "+1.7", "+2.0", "+2.3", "+2.7", "+3.0", "+3.3",
        "+3.7", "+4.0", "+4.3", "+4.7", "+5.0"
    ]
}


enum CameraPermissionStatus {
    case undetermined  // 尚未询问
    case authorized    // 已授权
    case denied        // 已拒绝
}

enum UIWidgets: Int, CaseIterable {
    case imageQuality   = 0
    case lensSwitch     = 1
    case AFMode         = 2
    case WBMode         = 3
    case MENU           = 4
    case SS             = 5
    case aperture       = 6
    case EV             = 7
    case ISO            = 8
    case Style          = 9
}
    
enum ExposureMode { case waveform, histogram, off }
    
enum ShutterSoundMode: String, CaseIterable {
    case sony       = "shutter_eqed_gained"
    case panasonic  = "s1m2_shutter_gained"
}

