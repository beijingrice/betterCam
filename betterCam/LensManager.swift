//
//  LensManager.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//

import Foundation
import AVFoundation
import Combine

class LensManager: ObservableObject {
    @Published var physicalLenses: [Lens] = []
    @Published var currentLens: Lens
    @Published var enableFrontCamera: Bool = false
    
    init() {
        let (lenses, defaultLens) = LensManager.performDiscovery(enableFront: self.enableFrontCamera)
        self.physicalLenses = lenses
        self.currentLens = defaultLens
    }
    
    func discoverCameras() {
        let (lenses, defaultLens) = LensManager.performDiscovery(enableFront: self.enableFrontCamera)
        self.physicalLenses = lenses
        self.currentLens = defaultLens
    }
    
    private static func performDiscovery(enableFront: Bool) -> ([Lens], Lens) {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ], mediaType: .video, position: .unspecified).devices
        
        let backLenses = devices.filter { $0.position == .back }
            .map { Lens(device: $0) }
            .sorted { $0.equivalentFocalLength < $1.equivalentFocalLength }
        
        var finalLenses = backLenses
        if enableFront, let frontCam = devices.first(where: { $0.position == .front }) {
            finalLenses.insert(Lens(device: frontCam), at: 0)
        }
        
        let defaultLens = finalLenses.first { $0.device.deviceType == .builtInWideAngleCamera } ?? finalLenses.first!
        
        return (finalLenses, defaultLens)
    }
    func switchLens(direction: Int) {
        guard self.physicalLenses.count > 1 else { return }
        if let i = physicalLenses.firstIndex(where: { $0.device == currentLens.device }) {
            let nextIndex = (i + direction + physicalLenses.count) % physicalLenses.count
            self.currentLens = physicalLenses[nextIndex]
        }
    }
}
