import Foundation

extension FilmEngine {
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
            let newSim = FilmSimulation(name: name, type: .lut, filterName: nil, lutData: data, dimension: dimension, isFilm: false)
            
            // 存入索引到 UserDefaults
            var savedList = UserDefaults.standard.array(forKey: "UserSavedLUTs") as? [[String: Any]] ?? []
            let metadata: [String: Any] = ["name": name, "dimension": dimension, "fileName": fileName]
            savedList.append(metadata)
            UserDefaults.standard.set(savedList, forKey: "UserSavedLUTs")
            
            availableSimulations.append(newSim)
            
        } catch {
            print("❌ 存储失败: \(error)")
        }
    }

    // 💡 持久化：从磁盘加载
    func loadSavedCustomLUTs() {
        let fileManager = FileManager.default
        guard let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let savedList = UserDefaults.standard.array(forKey: "UserSavedLUTs") as? [[String: Any]] else { return }
        
        for item in savedList {
            guard let name = item["name"] as? String,
                  let dimension = item["dimension"] as? Int,
                  let fileName = item["fileName"] as? String else { continue }
            
            let fileURL = docDir.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: fileURL) {
                let sim = FilmSimulation(name: name, type: .lut, filterName: nil, lutData: data, dimension: dimension, isFilm: false)
                self.availableSimulations.append(sim)
            }
        }
    }
    
    // 在 FilmEngine 类中添加
    func deleteSimulation(named name: String) {
        // 1. 从内存中移除对象
        availableSimulations.removeAll { $0.name == name }
        
        // 2. 物理删除 Documents 目录下的文件
        let fileManager = FileManager.default
        if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = docDir.appendingPathComponent("\(name).cube")
            try? fileManager.removeItem(at: fileURL)
        }
        
        // 3. 更新持久化列表
        var savedList = UserDefaults.standard.array(forKey: "UserSavedLUTs") as? [[String: Any]] ?? []
        savedList.removeAll { ($0["name"] as? String) == name }
        UserDefaults.standard.set(savedList, forKey: "UserSavedLUTs")
    }

    func renameSimulation(oldName: String, newName: String) {
        // 1. 更新内存数组中的名字
        if let index = availableSimulations.firstIndex(where: { $0.name == oldName }) {
            availableSimulations[index].name = newName
        }
        
        // 2. 更新 UserDefaults
        var savedList = UserDefaults.standard.array(forKey: "UserSavedLUTs") as? [[String: Any]] ?? []
        if let index = savedList.firstIndex(where: { ($0["name"] as? String) == oldName }) {
            savedList[index]["name"] = newName
            UserDefaults.standard.set(savedList, forKey: "UserSavedLUTs")
        }
    }
}
