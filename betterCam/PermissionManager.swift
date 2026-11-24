//
//  PermissionCheck.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//

import Foundation
import AVFoundation
import Combine
import Photos

/// Camera and photo-library access. Published so the camera screen redraws the moment the
/// user answers a prompt; it used to be a plain class, so a grant on first launch only
/// showed up after the app was relaunched.
final class PermissionManager: ObservableObject {
    @Published private(set) var cameraPermission = PermissionManager.cameraStatus()
    @Published private(set) var photoPermission = PermissionManager.photoStatus()

    var isFullyAuthorized: Bool {
        cameraPermission == .authorized && photoPermission == .authorized
    }

    /// Asks for whatever is still undetermined, one prompt after the other, and returns
    /// once both have answers.
    func requestAll() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        cameraPermission = Self.cameraStatus()
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        photoPermission = Self.photoStatus()
    }

    /// Re-reads both statuses, e.g. after the user comes back from Settings.
    func refresh() {
        cameraPermission = Self.cameraStatus()
        photoPermission = Self.photoStatus()
    }

    private static func cameraStatus() -> CameraPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    private static func photoStatus() -> CameraPermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: .authorized
        case .notDetermined: .undetermined
        default: .denied
        }
    }
}
