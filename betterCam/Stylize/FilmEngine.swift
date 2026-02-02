import CoreImage
import UIKit
import Combine

enum FilmStyleType {
    case builtIn    // 内部写死的滤镜组合
    case lut // 基于 LUT 文件的滤镜
    case builtInLut
}

struct FilmSimulation {
    var name: String
    let type: FilmStyleType
    let filterName: String?
    let lutData: Data?
    let dimension: Int
    let isFilm: Bool
}

class FilmEngine: ObservableObject {
    static let shared = FilmEngine()
    private let context = CIContext()
    private var staticGrainOverlay: CIImage?
    
    // 💡 设为 @Published 确保 UI 拨盘能实时刷新
    @Published var availableSimulations: [FilmSimulation] = []

    init() {
        // 1. 先填充基础内置滤镜
        setupInitialStyles()
        // 2. 加载随 App 打包的 .cube 文件 (Xcode 里的资源)
        loadBundleLUTs()
        // 3. 加载用户手动导入并存到沙盒里的 LUT
        loadSavedCustomLUTs()
        // Get noise generator ready
        prepareStaticGrain()
    }
    
    private func prepareStaticGrain() {
        let noiseGenerator = CIFilter(name: "CIRandomGenerator")!
        guard let noise = noiseGenerator.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 2000, height: 2000)) else { return }
        
        // 预设好黑白感、对比度以及基础亮度（EV -3.5 让它若隐若现）
        let processedNoise = noise
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.1
            ])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -3.5])
        
        self.staticGrainOverlay = processedNoise
    }
    
    /*
    private func applyDynamicGrain(to input: CIImage, intensity: Float) -> CIImage {
        guard let grainLayer = staticGrainOverlay else { return input }
        
        // 1. 调整噪点图的透明度来控制强度
        let grainWithIntensity = grainLayer
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity))
            ])
        
        // 2. 铺满屏幕
        let tiledGrain = grainWithIntensity
            .applyingFilter("CIAffineTile")
            .cropped(to: input.extent)

        // 3. 混合
        return input.applyingFilter("CIOverlayBlendMode", parameters: [
            kCIInputImageKey: tiledGrain,
            kCIInputBackgroundImageKey: input
        ])
    }
     */
    
    /*
    private func applyDynamicGrain(to input: CIImage, intensity: Float) -> CIImage {
        guard let grainLayer = staticGrainOverlay else { return input }
            
            // 1. 映射参数：根据强度系数派生出尺寸和粗糙度
            // 基础倍率 1.0，随强度最高增加到 2.5 倍大小
            let grainSize = 1.0 + CGFloat(intensity * 1.5)
            
            // 粗糙度：强度越高，模糊越小（越锐利）。模糊半径从 1.5 降至 0
            let blurRadius = CGFloat(max(0, 1.5 - (intensity * 1.5)))

            // 2. 应用尺寸变换 (CGAffineTransform)
            let scaledGrain = grainLayer.transformed(by: CGAffineTransform(scaleX: grainSize, y: grainSize))
            
            // 3. 应用粗糙度控制 (高斯模糊)
            let processedGrain = scaledGrain.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: blurRadius
            ])
            
            // 4. 调整透明度 (Alpha)
            // 这里的 w 系数可以稍微调高，确保在大尺寸下依然有足够的覆盖感
            let grainWithAlpha = processedGrain
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity * 1.2))
                ])
            
            // 5. 铺满并混合
            let tiledGrain = grainWithAlpha
                .applyingFilter("CIAffineTile")
                .cropped(to: input.extent)

            // 使用 Overlay 混合模式能更好地保留原图暗部细节
            return input.applyingFilter("CIOverlayBlendMode", parameters: [
                kCIInputImageKey: tiledGrain,
                kCIInputBackgroundImageKey: input
            ])
    }
     */
    
    /*
    private func applyDynamicGrain(to input: CIImage, intensity: Float) -> CIImage {
        guard let grainLayer = staticGrainOverlay else { return input }
        
        // 1. 计算缩放中心
        let grainSize = 1.0 + CGFloat(intensity * 1.5)
        let extent = grainLayer.extent
        let center = CGPoint(x: extent.midX, y: extent.midY) // 💡 获取纹理中心点
        
        // 2. 实现中心缩放逻辑
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: center.x, y: center.y)      // A. 先移到中心
        transform = transform.scaledBy(x: grainSize, y: grainSize)        // B. 进行缩放
        transform = transform.translatedBy(x: -center.x, y: -center.y)    // C. 移回原点
        
        // 💡 额外步骤：加入随强度变化的微小位移，防止缩放感太死板
        let randomShift = CGFloat(intensity * 50.0)
        transform = transform.translatedBy(x: randomShift, y: -randomShift)
        
        let scaledGrain = grainLayer.transformed(by: transform)
        
        // 3. 后续处理（粗糙度与透明度）
        let blurRadius = CGFloat(max(0, 1.5 - (intensity * 1.5)))
        let processedGrain = scaledGrain.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: blurRadius
        ])
        
        let grainWithAlpha = processedGrain
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity * 1.2))
            ])
        
        // 4. 铺满与混合
        let tiledGrain = grainWithAlpha
            .applyingFilter("CIAffineTile")
            .cropped(to: input.extent)

        return input.applyingFilter("CIOverlayBlendMode", parameters: [
            kCIInputImageKey: tiledGrain,
            kCIInputBackgroundImageKey: input
        ])
    }
     */
    
    /* - GOOD ONE
    private func applyDynamicGrain(to input: CIImage, intensity: Float) -> CIImage {
        // 1. 实时生成基础随机纹理
        // 💡 重点：我们不再裁剪固定尺寸，而是每次都重新请求输出
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }
        
        // 2. 动态缩放 (Size)
        // 模仿 Lightroom 的逻辑：强度越高，颗粒通常看起来越聚拢或越粗
        let grainSize = 1.0 + CGFloat(intensity * 2.0)
        let scaledNoise = noise.transformed(by: CGAffineTransform(scaleX: grainSize, y: grainSize))
        
        // 3. 动态对比度与亮度调制
        // 💡 这里的关键是让噪点只在中间调和暗部明显，亮部收敛，这样才自然
        let whitePoint = 1.0 - (intensity * 0.5) // 随强度调整白点
        let processedNoise = scaledNoise
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.0 + (intensity * 0.5) // 随强度增加颗粒对比度
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity * 0.6)) // 控制整体混合强度
            ])

        // 4. 使用“柔光” (Soft Light) 模式
        // Snapseed 和 Lightroom 常用 Soft Light 或 Overlay 来实现自然过渡，
        // 因为这两种模式不会简单地覆盖像素，而是根据原图亮度进行增益。
        let combined = CIFilter(name: "CISoftLightBlendMode", parameters: [
            kCIInputImageKey: processedNoise.cropped(to: input.extent),
            kCIInputBackgroundImageKey: input
        ])?.outputImage

        return combined ?? input
    }
     */
    
    /* BETTER ONE
    private func applyDynamicGrain(to input: CIImage, intensity: Float) -> CIImage {
        // 1. 获取基础噪点
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }
        
        // 2. 计算变换参数
        let grainSize = 1.0 + CGFloat(intensity * 2.5) // 增大一点缩放范围，让变化更明显
        let inputExtent = input.extent
        let center = CGPoint(x: inputExtent.midX, y: inputExtent.midY) // 💡 锁定画面中心
        
        // 3. 构建变换矩阵 (从中心缩放)
        // 💡 核心逻辑：先移到中心 -> 再缩放 -> 再移回原点
        // 这样噪点就会以屏幕中心为轴心变大，而不是往角落跑
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: center.x, y: center.y)
        transform = transform.scaledBy(x: grainSize, y: grainSize)
        transform = transform.translatedBy(x: -center.x, y: -center.y)
        
        // 💡 秘密武器：相位偏移 (Phase Shift)
        // 随着强度改变，让噪点纹理发生巨大的位移。
        // 这会让大脑认为这是“新生成的一层噪点”，而不是“原来的噪点被拉大了”，彻底消除缩放感。
        let phaseShift = CGFloat(intensity * 1000.0)
        transform = transform.translatedBy(x: phaseShift, y: phaseShift)
        
        let scaledNoise = noise.transformed(by: transform)
        
        // 4. 动态画质调优 (模拟 Lightroom 质感)
        // 随着颗粒变大，为了防止出现马赛克方块感，我们可以略微降低锐度
        let blurRadius = intensity * 0.5 // 极其微小的模糊，让大颗粒边缘更圆润
        
        let processedNoise = scaledNoise
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius]) // 柔化颗粒
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.0 + (intensity * 0.8) // 增强对比度，让颗粒更扎实
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                // 随强度动态调整透明度：颗粒越大，单体透明度应略微降低以保持整体通透
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity * 0.5))
            ])

        // 5. 混合 (保持 Soft Light)
        // 记得要在混合前 crop 到原图大小，否则性能会爆炸
        let combined = CIFilter(name: "CISoftLightBlendMode", parameters: [
            kCIInputImageKey: processedNoise.cropped(to: inputExtent),
            kCIInputBackgroundImageKey: input
        ])?.outputImage

        return combined ?? input
    }
     */
    
    private func applyDynamicGrain(to input: CIImage, intensity: Float) -> CIImage {
        // 1. 生成原始噪点
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }
        
        // 2. 模拟颗粒结块 (Blur - 控制尺寸)
        // 保持原来的逻辑：强度越大，模糊半径越大，颗粒越大块
        let blurRadius = Double(intensity * 1.5)
        let blurredNoise = noise.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: blurRadius
        ])
        
        // 3. 💡 关键修改：暴力去亮 + 极端对比度
        // 目标：把噪点层变成“白纸上的黑点”，而不是“灰纸上的灰点”
        
        let processedGrain = blurredNoise
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,    // 彻底去色
                kCIInputContrastKey: 2.0 + (intensity * 3.0), // 极高对比度，让颗粒边缘像刀切一样硬
                kCIInputBrightnessKey: 0.0
            ])
            // 💡 核心魔法：使用 ColorMatrix 进行“暗部偏移”
            .applyingFilter("CIColorMatrix", parameters: [
                // R, G, B 全部乘以 1 (保持原值)，但 Bias (偏移) 减去 0.3 ~ 0.5
                // 这意味着：原来的中灰(0.5)会变成(0.1)甚至(0.0)的纯黑。
                // 只有原来的极亮部(0.9+)才能勉强保留一点点灰度，其余全被压成黑色。
                "inputBiasVector": CIVector(x: -0.3 - CGFloat(intensity * 0.2),
                                            y: -0.3 - CGFloat(intensity * 0.2),
                                            z: -0.3 - CGFloat(intensity * 0.2),
                                            w: 0)
            ])
        
        // 4. 调整透明度
        // 因为现在是纯黑颗粒，不需要太高透明度就能看得很清楚
        let alpha = 0.2 + (intensity * 0.1)
        let finalGrain = processedGrain.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
        ])

        // 5. 混合模式改为 Overlay 或 HardLight
        // 裁剪很重要，否则性能崩溃
        let croppedGrain = finalGrain.cropped(to: input.extent)
        
        // 💡 如果你觉得 Overlay 还是不够黑，可以试试 "CILinearBurnBlendMode" (线性加深) 或 Stay with Overlay
        // Overlay 在处理深色层时，会显著压暗背景，非常适合模拟银盐阻光效果。
        let combined = CIFilter(name: "CIOverlayBlendMode", parameters: [
            kCIInputImageKey: croppedGrain,
            kCIInputBackgroundImageKey: input
        ])?.outputImage

        return combined ?? input
    }
    private func setupInitialStyles() {
        self.availableSimulations = [
            FilmSimulation(name: "STD", type: .builtIn, filterName: nil, lutData: nil, dimension: 0, isFilm: false),
            
            // --- 彩色系列 ---
            // 鲜艳/正片
            FilmSimulation(name: "CHROME", type: .builtIn, filterName: "CIPhotoEffectChrome", lutData: nil, dimension: 0, isFilm: false),
            // 拍立得/即时
            FilmSimulation(name: "INSTANT", type: .builtIn, filterName: "CIPhotoEffectInstant", lutData: nil, dimension: 0, isFilm: false),
            // 褪色/复古
            FilmSimulation(name: "FADE", type: .builtIn, filterName: "CIPhotoEffectFade", lutData: nil, dimension: 0, isFilm: false),
            // 冲印/冷调
            FilmSimulation(name: "PROCESS", type: .builtIn, filterName: "CIPhotoEffectProcess", lutData: nil, dimension: 0, isFilm: false),
            // 传送/怀旧
            FilmSimulation(name: "TRANSFER", type: .builtIn, filterName: "CIPhotoEffectTransfer", lutData: nil, dimension: 0, isFilm: false),
            
            // --- 黑白系列 ---
            // 纯净黑白
            FilmSimulation(name: "MONO", type: .builtIn, filterName: "CIPhotoEffectMono", lutData: nil, dimension: 0, isFilm: false),
            // 电影黑白
            FilmSimulation(name: "NOIR", type: .builtIn, filterName: "CIPhotoEffectNoir", lutData: nil, dimension: 0, isFilm: false),
            // 银盐黑白
            FilmSimulation(name: "TONAL", type: .builtIn, filterName: "CIPhotoEffectTonal", lutData: nil, dimension: 0, isFilm: false)
        ]
    }

    // 💡 扫描 Xcode 项目工程里直接拖进去的 .cube 文件
    private func loadBundleLUTs() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "cube", subdirectory: nil) else { return }
        for url in urls {
            if let result = parseCubeFile(at: url) {
                let name = url.deletingPathExtension().lastPathComponent.uppercased()
                if !availableSimulations.contains(where: { $0.name == name }) {
                    let sim = FilmSimulation(name: name, type: .builtInLut, filterName: nil, lutData: result.data, dimension: result.dimension, isFilm: true)
                    self.availableSimulations.append(sim)
                }
            }
        }
    }
    
    
    func process(_ input: CIImage, styleName: String, lutIntensity: Float, grainIntensity: Float) -> CIImage {
        guard styleName != "STD" || grainIntensity > 0 else {
            return input
        }
        
        var output = input
        
        // 2. 找到对应的滤镜配置
        if let sim = availableSimulations.first(where: { $0.name == styleName }), styleName != "STD" {
            var filteredImage: CIImage?
            
            if sim.type == .builtIn, let filterName = sim.filterName {
                filteredImage = input.applyingFilter(filterName)
            } else if (sim.type == .lut || sim.type == .builtInLut), let data = sim.lutData {
                let filter = CIFilter(name: "CIColorCube")!
                filter.setValue(sim.dimension, forKey: "inputCubeDimension")
                filter.setValue(data, forKey: "inputCubeData")
                filter.setValue(input, forKey: kCIInputImageKey)
                filteredImage = filter.outputImage
            }
            
            // 💡 关键：根据 lutIntensity 混合原图和滤镜图
            if let filtered = filteredImage {
                // 使用遮罩滤镜实现 alpha 混合
                let blendFilter = CIFilter(name: "CIBlendWithAlphaMask")!
                blendFilter.setValue(filtered, forKey: kCIInputImageKey) // 上层：滤镜后的图
                blendFilter.setValue(input, forKey: kCIInputBackgroundImageKey) // 下层：原图
                
                // 创建一个纯色的强度遮罩
                let alphaColor = CIColor(red: CGFloat(lutIntensity), green: CGFloat(lutIntensity), blue: CGFloat(lutIntensity), alpha: CGFloat(lutIntensity))
                let maskImage = CIImage(color: alphaColor).cropped(to: input.extent)
                blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)
                
                output = blendFilter.outputImage ?? input
            }
        }
        
        // 3. 💡 关键：根据 grainIntensity 应用噪点
        if grainIntensity > 0 && styleName != "STD" && styleName != "MANAGE" {
            output = applyDynamicGrain(to: output, intensity: grainIntensity)
        }
        
        return output
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
            let newSim = FilmSimulation(name: name, type: .lut, filterName: nil, lutData: data, dimension: dimension, isFilm: false)
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
            
            availableSimulations.append(newSim)
            
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
