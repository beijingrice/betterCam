//
//  ScreenView.swift
//  betterCam
//
//  Created by Rice on 2026/1/24.
//
import SwiftUI
internal import UniformTypeIdentifiers

struct ScreenView: View {
    @EnvironmentObject var camera: Camera
    @State private var tempLUTData: Data? = nil
    @State private var showRenameAlert = false
    @State private var newLUTName = ""
    @State private var tempDimension: Int = 0
    var body: some View {
        ZStack {
            CameraPreview()
                .background(Color.black)
            VStack(spacing: 0) {
                TopBarView()
                Spacer()
                BottomBarView()
            }
        }
        .aspectRatio(4/3, contentMode: .fit)
    }
    
    private func handleImport(result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                // 💡 接收元组数据
                if let result = FilmEngine.shared.parseCubeFile(at: url) {
                    self.tempLUTData = result.data
                    self.tempDimension = result.dimension // 你需要新加一个 @State var tempDimension = 0
                    self.newLUTName = url.deletingPathExtension().lastPathComponent.uppercased()
                    self.showRenameAlert = true
                }
            }
        }
    }

    private func saveNewLUT(data: Data, name: String, dimension: Int) {
        let cleanName = name.isEmpty ? "CUSTOM" : name.uppercased()
        let newSim = FilmSimulation(name: cleanName, type: .lut, filterName: nil, lutData: data, dimension: dimension, isFilm: false)
        
        FilmEngine.shared.availableSimulations.append(newSim)
        
        if let addIndex = camera.styleOptions.firstIndex(of: "ADD") {
            camera.styleOptions.insert(cleanName, at: addIndex)
        }
        camera.style = cleanName
    }
}
