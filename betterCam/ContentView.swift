//
//  ContentView.swift
//  betterCam
//
//  Created by Rice on 2026/1/22.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject var camera = Camera()
    var body: some View {
        ZStack {
            // for debug
            BodyFrameBackground()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScreenView()
                        .wrapInCameraFrame(thickness: 20)
                        .recessedPanel()
                        .padding(.top)
                        .frame(height: UIScreen.main.bounds.height * 0.95)
                        
                }
                ControlDialView()
                    .padding(.leading, UIScreen.main.bounds.width * 0.1)
            }
            
            .statusBar(hidden: true)
            .environmentObject(camera)
        }
    }
}




#Preview {
    ContentView()
}
