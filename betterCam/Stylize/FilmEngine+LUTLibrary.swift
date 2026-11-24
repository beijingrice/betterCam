import Foundation

extension FilmEngine {
    private static let lutIndexKey = "UserSavedLUTs"

    func loadSavedCustomLUTs() {
        let index = preferences.array(forKey: Self.lutIndexKey) as? [[String: Any]] ?? []
        var names = Set((availableSimulations.map(\.name) + [Self.manageName]).map { $0.lowercased() })
        var files = Set<String>()
        var styles: [FilmSimulation] = []

        // Legacy imports could append the same name or file more than once.
        for record in index.reversed() {
            guard let name = record["name"] as? String,
                  let dimension = record["dimension"] as? Int,
                  let fileName = record["fileName"] as? String,
                  fileName.hasSuffix(".lutdata"),
                  (fileName as NSString).lastPathComponent == fileName,
                  !names.contains(name.lowercased()), !files.contains(fileName),
                  let data = try? Data(contentsOf: documents.appendingPathComponent(fileName)),
                  let cube = try? FilmLUT(
                      data: data, dimension: dimension,
                      domainMin: Self.savedDomain(record["domainMin"]) ?? .zero,
                      domainMax: Self.savedDomain(record["domainMax"]) ?? SIMD3(repeating: 1)
                  ) else { continue }
            let encoding = (record["encoding"] as? String).flatMap(LUTEncoding.init(rawValue:)) ?? .linearSRGB
            styles.append(FilmSimulation(name: name, look: .cube(cube, encoding), grain: .imported, fileName: fileName))
            names.insert(name.lowercased())
            files.insert(fileName)
        }
        availableSimulations.append(contentsOf: styles.reversed())
    }

    func saveCustomLUT(_ cube: FilmLUT, name: String, encoding: LUTEncoding) throws {
        let uniqueName = try checkedName(name)
        let fileName = "\(UUID().uuidString).lutdata"
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try cube.data.write(to: documents.appendingPathComponent(fileName), options: .atomic)
        let style = FilmSimulation(name: uniqueName, look: .cube(cube, encoding), grain: .imported, fileName: fileName)
        replaceLibrary(with: availableSimulations + [style])
    }

    func deleteCustomLUT(fileName: String) throws {
        guard let index = availableSimulations.firstIndex(where: { $0.fileName == fileName }) else { return }
        do {
            try FileManager.default.removeItem(at: documents.appendingPathComponent(fileName))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The entry can still be removed if its data file is already gone.
        }
        var styles = availableSimulations
        styles.remove(at: index)
        replaceLibrary(with: styles)
    }

    func renameCustomLUT(fileName: String, name: String) throws {
        guard let index = availableSimulations.firstIndex(where: { $0.fileName == fileName }) else { return }
        let newName = try checkedName(name, excluding: fileName)
        var styles = availableSimulations
        styles[index].name = newName
        replaceLibrary(with: styles)
    }

    func setCustomLUTEncoding(fileName: String, encoding: LUTEncoding) {
        guard let index = availableSimulations.firstIndex(where: { $0.fileName == fileName }),
              case let .cube(cube, _) = availableSimulations[index].look else { return }
        var styles = availableSimulations
        styles[index].look = .cube(cube, encoding)
        replaceLibrary(with: styles)
    }

    private func checkedName(_ name: String, excluding fileName: String? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(Self.manageName) != .orderedSame,
              !availableSimulations.contains(where: {
                  (fileName == nil || $0.fileName != fileName) && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
              }) else { throw LUTError.duplicateName }
        return trimmed
    }

    private func replaceLibrary(with styles: [FilmSimulation]) {
        let index: [[String: Any]] = styles.compactMap { style in
            guard let file = style.fileName, case let .cube(cube, encoding) = style.look else { return nil }
            return [
                "name": style.name,
                "fileName": file,
                "dimension": cube.dimension,
                "domainMin": [cube.domainMin.x, cube.domainMin.y, cube.domainMin.z],
                "domainMax": [cube.domainMax.x, cube.domainMax.y, cube.domainMax.z],
                "encoding": encoding.rawValue
            ]
        }
        preferences.set(index, forKey: Self.lutIndexKey)
        availableSimulations = styles
    }

    private static func savedDomain(_ value: Any?) -> SIMD3<Float>? {
        guard let values = value as? [NSNumber], values.count == 3 else { return nil }
        return SIMD3(values[0].floatValue, values[1].floatValue, values[2].floatValue)
    }
}
