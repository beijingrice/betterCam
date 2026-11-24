import AVFoundation
import Foundation

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

}
