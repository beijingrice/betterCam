//
//  LUTManagerView.swift
//  betterCam
//
//  Created by Rice on 2026/1/29.
//

import SwiftUI
internal import UniformTypeIdentifiers
struct LUTManagerView: View {
    @ObservedObject var camera: Camera
    @ObservedObject var engine = FilmEngine.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var isShowingRenameAlert = false
    @State private var lutToRename: FilmSimulation?
    @State private var newNameText = ""
    @State private var showFilePicker = false
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("My LUTs")) {
                    // 假设 FilmEngine.shared.availableSimulations 存储了所有 LUT
                    ForEach(engine.availableSimulations, id: \.name) { lut in
                        HStack {
                            Text(lut.name)
                            Spacer()
                        }
                        .swipeActions(edge: .trailing) {
                            if lut.type != .builtIn && lut.type != .builtInLut {
                                Button(role: .destructive) {
                                    // 执行删除逻辑
                                    deleteLUT(lut)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                
                                Button {
                                    // 执行重命名弹窗逻辑
                                    renameLUT(lut)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
                
                Section {
                    Button(action: {
                        showFilePicker = true
                    }) {
                        Label("Import New LUT (.cube)", systemImage: "plus")
                    }
                }
                
            }
            .navigationTitle("LUTs management")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        camera.inCameraView = true
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                handleFileImport(result: result)
            }
            .alert("Rename LUT", isPresented: $isShowingRenameAlert) {
                TextField("Enter new name", text: $newNameText)
                
                Button("Cancel", role: .cancel) {
                    lutToRename = nil
                    newNameText = ""
                }
                
                Button("OK") {
                    if let oldLut = lutToRename, !newNameText.isEmpty {
                        // 调用你 FilmEngine 里的重命名逻辑
                        FilmEngine.shared.renameSimulation(oldName: oldLut.name, newName: newNameText)
                        
                        // 刷新 Camera 中的 styleOptions 列表，确保相机转盘同步更新
                        camera.syncAllLUTsToOptions()
                    }
                    lutToRename = nil
                    newNameText = ""
                }
            } message: {
                Text("Please enter a new name for this LUT.")
            }
        }
    }
    
    func handleFileImport(result: Result<[URL], Error>) {
        guard let selectedURL = try? result.get().first else { return }
        
        guard selectedURL.startAccessingSecurityScopedResource() else { return }
        
        if let (lutData, dimension) = FilmEngine.shared.parseCubeFile(at: selectedURL) {
            let fileName = selectedURL.deletingPathExtension().lastPathComponent
            
            FilmEngine.shared.saveCustomLUTToDisk(data: lutData, name: fileName, dimension: dimension)
            camera.syncAllLUTsToOptions()
        }
        selectedURL.stopAccessingSecurityScopedResource()
    }
    
    func deleteLUT(_ lut: FilmSimulation) {
        FilmEngine.shared.deleteSimulation(named: lut.name)
        camera.syncAllLUTsToOptions()
    }
    
    func renameLUT(_ lut: FilmSimulation) {
        self.lutToRename = lut
        self.newNameText = lut.name  // 预填当前名字，方便用户修改
        self.isShowingRenameAlert = true
    }
}
