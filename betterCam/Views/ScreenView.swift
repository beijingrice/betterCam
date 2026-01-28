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
        .fileImporter(isPresented: $camera.showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) {
            result in handleImport(result: result)
        }
        .alert("导入胶片模拟", isPresented: $showRenameAlert) {
                    TextField("输入滤镜名称", text: $newLUTName)
                    Button("取消", role: .cancel) { tempLUTData = nil }
            Button("保存") {
                if let data = tempLUTData {
                    saveNewLUT(data: data, name: newLUTName, dimension: tempDimension)
                }
            }
        } message: {
            Text("请为你的自定义 LUT 起一个名字")
        }
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
