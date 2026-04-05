//
//  MotionManager.swift
//  betterCam
//
//  Created by Rice on 2026/4/5.
//

import Foundation
import CoreMotion
import AVFoundation
import Combine

class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    @Published var deviceOrientation: AVCaptureVideoOrientation = .portrait
    
    func start() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.2
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let motion = motion else { return }
                let x = motion.gravity.x
                let y = motion.gravity.y
                if abs(y) >= abs(x) {
                    self?.deviceOrientation = y >= 0 ? .portraitUpsideDown : .portrait
                } else {
                    self?.deviceOrientation = x >= 0 ? .landscapeLeft : .landscapeRight
                }
            }
        }
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
