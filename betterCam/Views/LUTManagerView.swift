import SwiftUI
internal import UniformTypeIdentifiers

struct LUTManagerView: View {
    @ObservedObject var camera: Camera
    @ObservedObject private var engine = FilmEngine.shared

    @State private var showFilePicker = false
    @State private var showImportEncoding = false
    @State private var pendingImport: (name: String, cube: FilmLUT)?
    @State private var showRename = false
    @State private var renameTarget: FilmSimulation?
    @State private var newName = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            List {
                Section("My LUTs") {
                    ForEach(engine.availableSimulations, id: \.name) { style in
                        HStack {
                            Text(style.name)
                            Spacer()
                            if let fileName = style.fileName, let encoding = style.customEncoding {
                                Menu(encoding.title) {
                                    ForEach(LUTEncoding.allCases, id: \.self) { option in
                                        Button(option.title) {
                                            engine.setCustomLUTEncoding(fileName: fileName, encoding: option)
                                        }
                                    }
                                }
                                .accessibilityLabel("LUT color space")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if let fileName = style.fileName {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    applyChange { try engine.deleteCustomLUT(fileName: fileName) }
                                }
                                Button("Rename", systemImage: "pencil") {
                                    renameTarget = style
                                    newName = style.name
                                    showRename = true
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }

                Button {
                    showFilePicker = true
                } label: {
                    Label("Import New LUT (.cube)", systemImage: "plus")
                }
            }
            .scrollContentBackground(.hidden)
            .background(.black)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("LUTs management")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { camera.inCameraView = true }
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    pendingImport = (url.deletingPathExtension().lastPathComponent, try FilmLUT(contentsOf: url))
                    showImportEncoding = true
                } catch {
                    present(error)
                }
            }
            .confirmationDialog("LUT color space", isPresented: $showImportEncoding, titleVisibility: .visible) {
                Button("sRGB") { saveImport(encoding: .sRGB) }
                Button("Linear sRGB") { saveImport(encoding: .linearSRGB) }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: {
                Text("Choose the color space this LUT was made for.")
            }
            .alert("Rename LUT", isPresented: $showRename) {
                TextField("Enter new name", text: $newName)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("OK") { rename() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("LUT could not be updated", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
    }

    private func saveImport(encoding: LUTEncoding) {
        guard let entry = pendingImport else { return }
        pendingImport = nil
        applyChange { try engine.saveCustomLUT(entry.cube, name: entry.name, encoding: encoding) }
    }

    private func rename() {
        guard let target = renameTarget, let fileName = target.fileName else { return }
        renameTarget = nil
        applyChange { try engine.renameCustomLUT(fileName: fileName, name: newName) }
    }

    private func applyChange(_ action: () throws -> Void) {
        do {
            try action()
            camera.parameterManager.syncAllLUTsToOptions()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

#Preview {
    LUTManagerView(camera: Camera())
}
