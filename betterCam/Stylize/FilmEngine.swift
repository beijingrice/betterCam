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
    
    
    private func applyDynamicGrain(to input: CIImage, intensity: Float) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }
        
        let blurRadius = Double(intensity * 0.4)
        let processedGrain = noise
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            // 💡 关键：建立低反差、去色的中灰平衡贴图。
            // 对比度要低（1.0 ~ 1.15），让颗粒温润发灰，绝不能非黑即白。
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 0.8 + (intensity * 0.15), // 极低的动态高反差
                kCIInputBrightnessKey: 0.0
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0.4, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0.4, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0.4, w: 0),
                        "inputBiasVector": CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0) // 💡 这一步保证了没有死黑
            ])
        
        let croppedGrain = processedGrain.cropped(to: input.extent)
        
        let softLightFilter = CIFilter(name: "CISoftLightBlendMode")
        softLightFilter?.setValue(croppedGrain, forKey: kCIInputImageKey)
        softLightFilter?.setValue(input, forKey: kCIInputBackgroundImageKey)
        
        guard let combined = softLightFilter?.outputImage else { return input }
        
        let gray = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        
        // 构造一个“温柔”的遮罩。逻辑：中灰区 100% 颗粒，死黑/死白区仍保留约 30% 到 50% 颗粒。
        // 这里的 Bias 和系数是精挑细选的，让遮罩层永远不会变成纯黑。
        guard let gentleMask = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: gray,
            "inputRVector": CIVector(x: -1.2, y: 0, z: 0, w: 0), // 温和压制高光
            "inputBiasVector": CIVector(x: 1.1, y: 1.1, z: 1.1, w: 0) // 💡 极高基准亮度，保护黑场绝不掉色
        ])?.outputImage else { return combined }
        
        let finalOpacity = 0.12 + (intensity * 0.3) // 整体基础压得很低
        
        // 先把遮罩的基准透明度提起来 (加亮 Bias)
        let attenuatedMask = gentleMask.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: CGFloat(finalOpacity - 0.5)
        ])
        
        // 物理级合成
        let blendFilter = CIFilter(name: "CIBlendWithMask")
        blendFilter?.setValue(combined, forKey: kCIInputImageKey)           // 有温和噪点的染色图
        blendFilter?.setValue(input, forKey: kCIInputBackgroundImageKey)    // 干净原图
        blendFilter?.setValue(attenuatedMask, forKey: kCIInputMaskImageKey) // 温和遮罩
        
        return blendFilter?.outputImage ?? combined
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
}
