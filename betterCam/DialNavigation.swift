import Foundation

func changeParameter(for camera: Camera, direction: Int) {
    
    if camera.isAdjustingValue {
        adjustValue(for: camera, direction: direction)
    } else {
        let count = camera.nullWidgetIndex + 1
        let pendingIndex = (camera.activeIndex + direction + count) % count
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
        pm.imageQuality = nextOption(
            in: camera.availableImageQualityOptions,
            current: pm.imageQuality,
            direction: direction
        )
        
    default:
        break
    }
}

func nextOption(in options: [String], current: String, direction: Int, isEV: Bool = false) -> String {
    guard !options.isEmpty else { return current }
    let currentIndex = options.firstIndex(of: current) ?? 0
    let proposed = currentIndex + direction
    if isEV {
        return options.indices.contains(proposed) ? options[proposed] : current
    }
    let wrapped = (proposed % options.count + options.count) % options.count
    return options[wrapped]
}
