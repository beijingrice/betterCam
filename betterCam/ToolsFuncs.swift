//
//  ToolsFuncs.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//

import Foundation
extension Camera {
    func changeParameter(direction: Int) {
        /*
         activeIndex: 0...maxWidgetIndex + 1
         0...maxWidgetIndex: parameters
         maxWidgetIndex + 1: nothing selected
         maxWidgetIndex + 2: will be never reached, just for condition check
         */
        
        if isAdjustingValue {
            adjustValue(direction: direction)
        } else {
            var pendingIndex: Int = 0
            let newIndex = activeIndex + direction
            if newIndex >= maxWidgetIndex + 2 { // direction = positive
                pendingIndex = 0
            } else if newIndex < 0 { // direction = negative
                pendingIndex = maxWidgetIndex + 1 // go to nothing selected index
            } else {
                pendingIndex = newIndex
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                activeIndex = pendingIndex
            }
        }
    }
    
    private func adjustValue(direction: Int) {
        switch activeIndex {
        case UIWidgets.AFMode.rawValue:
            AFMode = nextOption(in: AFModeOptions, current: AFMode, direction: direction)
        case UIWidgets.Style.rawValue: // STYLE
            style = nextOption(in: styleOptions, current: style, direction: direction)
        case UIWidgets.SS.rawValue: // SS
            SS = nextOption(in: actualSSoptions, current: SS, direction: direction)
        case UIWidgets.EV.rawValue: // EV
            let isManualMode = (SS != "AUTO" && ISO != "AUTO")
            if !isManualMode {
                EV = nextOption(in: EVoptions, current: EV, direction: direction)
            }
        case UIWidgets.ISO.rawValue: // ISO
            ISO = nextOption(in: actualISOoptions, current: ISO, direction: direction)
        case UIWidgets.lensSwitch.rawValue: switchCamera(direction: direction)
        case UIWidgets.imageQuality.rawValue: // Image Quality
            imageQuality = nextOption(in: imageQualityOptions, current: imageQuality, direction: direction)
        default:
            break
        }
    }
    
    private func nextOption(in options: [String], current: String, direction: Int, isEV: Bool = false) -> String {
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
}
