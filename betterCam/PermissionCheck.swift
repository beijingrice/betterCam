//
//  PermissionCheck.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//

import Foundation
import AVFoundation
import Photos

extension Camera {
    func checkPhotoLibraryPermission() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
    }
    
    func checkAllPermissions() {
        // 1. 检查相机权限
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        handleCameraStatus(cameraStatus)
        
        // 2. 检查相册写入权限
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        handlePhotoStatus(photoStatus)
    }
    
    private func handleCameraStatus(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: cameraPermission = .authorized
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.cameraPermission = granted ? .authorized : .denied }
            }
        default: cameraPermission = .denied
        }
    }

    private func handlePhotoStatus(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited: photoPermission = .authorized
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async { self.photoPermission = (status == .authorized || status == .limited) ? .authorized : .denied }
            }
        default: photoPermission = .denied
        }
    }
}
