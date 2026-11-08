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
    @Published var currentLens: Lens?
    
    init(isFrontCameraEnabled: Bool = false) {
        let (lenses, defaultLens) = LensManager.performDiscovery(enableFront: isFrontCameraEnabled)
        self.physicalLenses = lenses
        self.currentLens = defaultLens
    }
    
    func discoverCameras(enableFrontCamera: Bool) {
        let (lenses, defaultLens) = LensManager.performDiscovery(enableFront: enableFrontCamera)
        self.physicalLenses = lenses
        self.currentLens = defaultLens
    }
    
    private static func performDiscovery(enableFront: Bool) -> ([Lens], Lens?) {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ], mediaType: .video, position: .back).devices
        
        let backLenses = devices
            .map { Lens(device: $0) }
            .sorted { $0.equivalentFocalLength < $1.equivalentFocalLength }
        
        var finalLenses = backLenses
        // On Duo this discovery returns the virtual camera that follows the active display.
        if enableFront, let frontCam = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video, position: .front
        ).devices.first {
            var frontLensObj = Lens(device: frontCam)
            frontLensObj.displayName = "FRONT"
            finalLenses.insert(frontLensObj, at: 0)
        }
        
        let defaultLens = finalLenses.first { $0.device.deviceType == .builtInWideAngleCamera } ?? finalLenses.first
        
        return (finalLenses, defaultLens)
    }
    func switchLens(direction: Int) {
        guard self.physicalLenses.count > 1 else { return }
        if let i = physicalLenses.firstIndex(where: { $0.device == currentLens?.device }) {
            let nextIndex = (i + direction + physicalLenses.count) % physicalLenses.count
            self.currentLens = physicalLenses[nextIndex]
        }
    }
}
