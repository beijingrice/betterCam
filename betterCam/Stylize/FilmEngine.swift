import CoreImage
import UIKit
import Combine

enum FilmStyleType {
    case builtIn    // 内部写死的滤镜组合
    case lut        // 基于 LUT 文件的滤镜
}

struct FilmSimulation {
    let name: String
    let type: FilmStyleType
    let filterName: String?
    let lutData: Data?
    let dimension: Int
}

class FilmEngine: ObservableObject {
    static let shared = FilmEngine()
    private let context = CIContext()
    
    // 💡 设为 @Published 确保 UI 拨盘能实时刷新
    @Published var availableSimulations: [FilmSimulation] = []

    init() {
        // 1. 先填充基础内置滤镜
        setupInitialStyles()
        // 2. 加载随 App 打包的 .cube 文件 (Xcode 里的资源)
        loadBundleLUTs()
        // 3. 加载用户手动导入并存到沙盒里的 LUT
        loadSavedCustomLUTs()
    }

    private func setupInitialStyles() {
        self.availableSimulations = [
            FilmSimulation(name: "STD", type: .builtIn, filterName: nil, lutData: nil, dimension: 0),
            FilmSimulation(name: "RICH", type: .builtIn, filterName: "CIPhotoEffectInstant", lutData: nil, dimension: 0),
            FilmSimulation(name: "NOSTALGIC", type: .builtIn, filterName: "CIPhotoEffectTransfer", lutData: nil, dimension: 0),
            FilmSimulation(name: "BW", type: .builtIn, filterName: "CIPhotoEffectNoir", lutData: nil, dimension: 0)
        ]
    }

    // 💡 扫描 Xcode 项目工程里直接拖进去的 .cube 文件
    private func loadBundleLUTs() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "cube", subdirectory: nil) else { return }
        for url in urls {
            if let result = parseCubeFile(at: url) {
                let name = url.deletingPathExtension().lastPathComponent.uppercased()
                if !availableSimulations.contains(where: { $0.name == name }) {
                    let sim = FilmSimulation(name: name, type: .lut, filterName: nil, lutData: result.data, dimension: result.dimension)
                    self.availableSimulations.append(sim)
                }
            }
        }
    }

    // 💡 核心渲染函数：在 Camera.swift 中调用
    func process(_ input: CIImage, styleName: String) -> CIImage {
        guard let sim = availableSimulations.first(where: { $0.name == styleName }), styleName != "STD" else {
            return input
        }
        
        if sim.type == .builtIn, let filter = sim.filterName {
            return input.applyingFilter(filter)
        } else if sim.type == .lut, let data = sim.lutData {
            let filter = CIFilter(name: "CIColorCube")!
            filter.setValue(sim.dimension, forKey: "inputCubeDimension")
            filter.setValue(data, forKey: "inputCubeData")
            filter.setValue(input, forKey: kCIInputImageKey)
            return filter.outputImage ?? input
        }
        return input
    }

    // 💡 解析 .cube 文件逻辑
    func parseCubeFile(at url: URL) -> (data: Data, dimension: Int)? {
        guard let content = try? String(contentsOf: url) else { return nil }
        var cubeData = [Float32]()
        var dimension: Int = 0
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                if let sizeString = trimmed.components(separatedBy: .whitespaces).last,
                   let size = Int(sizeString) {
                    dimension = size
                }
                continue
            }
            
            let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let values = components.compactMap { Float32($0) }
            
            if values.count == 3 {
                cubeData.append(contentsOf: values)
                cubeData.append(1.0) // 补全 Alpha 通道
            }
        }
        
        let expectedCount = dimension * dimension * dimension * 4
        guard dimension > 0 && cubeData.count == expectedCount else {
            print("❌ LUT 数据校验失败：\(url.lastPathComponent)")
            return nil
        }
        
        return (Data(bytes: cubeData, count: cubeData.count * 4), dimension)
    }

    // 💡 持久化：保存到磁盘
    func saveCustomLUTToDisk(data: Data, name: String, dimension: Int) {
        let fileManager = FileManager.default
        guard let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        let fileName = "\(name).lutdata"
        let fileURL = docDir.appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileURL)
            
            // 存入内存
            let newSim = FilmSimulation(name: name, type: .lut, filterName: nil, lutData: data, dimension: dimension)
            DispatchQueue.main.async {
                if !self.availableSimulations.contains(where: { $0.name == name }) {
                    self.availableSimulations.append(newSim)
                }
            }
            
            // 存入索引到 UserDefaults
            var savedList = UserDefaults.standard.array(forKey: "UserSavedLUTs") as? [[String: Any]] ?? []
            let metadata: [String: Any] = ["name": name, "dimension": dimension, "fileName": fileName]
            savedList.append(metadata)
            UserDefaults.standard.set(savedList, forKey: "UserSavedLUTs")
            
        } catch {
            print("❌ 存储失败: \(error)")
        }
    }

    // 💡 持久化：从磁盘加载
    private func loadSavedCustomLUTs() {
        let fileManager = FileManager.default
        guard let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let savedList = UserDefaults.standard.array(forKey: "UserSavedLUTs") as? [[String: Any]] else { return }
        
        for item in savedList {
            guard let name = item["name"] as? String,
                  let dimension = item["dimension"] as? Int,
                  let fileName = item["fileName"] as? String else { continue }
            
            let fileURL = docDir.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: fileURL) {
                let sim = FilmSimulation(name: name, type: .lut, filterName: nil, lutData: data, dimension: dimension)
                self.availableSimulations.append(sim)
            }
        }
    }
}
