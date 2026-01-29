//
//  CameraPreview.swift
//  betterCam
//
//  Created by Rice on 2026/1/23.
//

import Foundation
import SwiftUI
import UIKit
struct CameraPreview: View {
    @EnvironmentObject var camera: Camera
    let aspectRatio: CGSize = CGSize(width: 4.0, height: 3.0)
    var body: some View {
        if let image = camera.currentPreviewImage {
            Image(image, scale: 1.0, orientation: .up, label: Text("Preview"))
                .resizable()
                .aspectRatio(aspectRatio, contentMode: .fit) // 强制 4:3 比例
        } else {
            Color.black // 启动时的黑屏占位
        }
    }
}
