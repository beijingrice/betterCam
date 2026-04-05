//
//  MetalWHViews.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//
import Metal
import MetalKit
import UIKit
import Combine

class MetalWHProcessor: ObservableObject {
    // View Dimensions
    let overlayWidth: Int = 128
    let overlayHeight: Int = 64
    
    // Enabled Exposure Indicator
    @Published var exposureIndicatorMode: ExposureMode = .off
    
    static let shared = MetalWHProcessor()
    
    // Basic Metal Components
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    
    // Pipeline status
    private var waveformPipeline: MTLComputePipelineState?
    private var histogramPipeline: MTLComputePipelineState?
    private var histogramBuffer: MTLBuffer?
    
    @Published var waveformImage: CGImage?
    @Published var histogramImage: CGImage?
    
    private init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        
        if let device = device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        
        
    }
    
    private func setupPipelines() {
        guard let device = device, let library = device.makeDefaultLibrary() else { return }
        
        if let waveformKernel = library.makeFunction(name: "waveformKernel") {
            waveformPipeline = try? device.makeComputePipelineState(function: waveformKernel)
        }
        
        if let histKernel = library.makeFunction(name: "histKernel") {
            histogramPipeline = try? device.makeComputePipelineState(function: histKernel)
        }
        
        histogramBuffer = device.makeBuffer(length: 128 * MemoryLayout<UInt32>.stride, options: .storageModeShared)
    }
    
    func process(pixelBuffer: CVPixelBuffer) {
        guard self.exposureIndicatorMode != .off else { return }
        
        if self.exposureIndicatorMode == .waveform {
            self.processWaveform(from: pixelBuffer)
            // clean up VRAM
            if histogramImage != nil {
                DispatchQueue.main.async {
                    self.histogramImage = nil
                }
            }
        } else if self.exposureIndicatorMode == .histogram {
            self.processHistogram(from: pixelBuffer)
            // clean up VRAM
            if waveformImage != nil {
                DispatchQueue.main.async {
                    self.waveformImage = nil
                }
            }
        } else if self.exposureIndicatorMode == .off {
            // clean up VRAM
            if waveformImage != nil || histogramImage != nil {
                DispatchQueue.main.async {
                    self.waveformImage = nil
                    self.histogramImage = nil
                }
            }
        }
    }
    
    func processWaveform(from pixelBuffer: CVPixelBuffer) {
        guard exposureIndicatorMode == .waveform,
              let pipeline = waveformPipeline,
              let queue = commandQueue,
              let cache = textureCache else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let inputTexture = CVMetalTextureGetTexture(cvTexture!) else { return }
        
        // 输出纹理强制设为 128x64
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: overlayWidth, height: overlayHeight, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        guard let outputTexture = device?.makeTexture(descriptor: desc) else { return }
        
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(width: (outputTexture.width + 15) / 16,
                                   height: (outputTexture.height + 15) / 16,
                                   depth: 1)
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            let cgImage = self.makeCGImage(from: outputTexture)
            DispatchQueue.main.async {
                self.waveformImage = cgImage
            }
        }
        commandBuffer.commit()
    }

    // MARK: - Histogram Process
    func processHistogram(from pixelBuffer: CVPixelBuffer) {
        guard exposureIndicatorMode == .histogram,
              let pipeline = histogramPipeline,
              let queue = commandQueue,
              let cache = textureCache,
              let hBuffer = histogramBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let inputTexture = CVMetalTextureGetTexture(cvTexture!) else { return }

        // 重置统计数据
        memset(hBuffer.contents(), 0, hBuffer.length)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setBuffer(hBuffer, offset: 0, index: 0)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let gridSize = MTLSize(width: (inputTexture.width + w - 1) / w,
                               height: (inputTexture.height + h - 1) / h,
                               depth: 1)

        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.renderHistogramUI()
        }
        commandBuffer.commit()
    }

    private func renderHistogramUI() {
        guard let buffer = histogramBuffer else { return }
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: 256)
        
        var maxCount: Float = 1.0
        for i in 0..<256 { maxCount = max(maxCount, Float(ptr[i])) }

        // 适配 128x64 规格
        let size = CGSize(width: CGFloat(overlayWidth), height: CGFloat(overlayHeight))
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            
            // 💡 优化：256 bins 对应 128 像素，每像素合并 2 bins
            let binsPerPixel = 2
            
            for x in 0..<overlayWidth {
                let binIndex = x * binsPerPixel
                // 取两个相邻 bin 的平均值保证曲线平滑
                let count = Float(ptr[binIndex] + ptr[binIndex + 1]) / 2.0
                let barHeight = CGFloat(count / maxCount) * size.height
                
                ctx.fill(CGRect(x: CGFloat(x), y: size.height - barHeight, width: 1.0, height: barHeight))
            }
        }

        DispatchQueue.main.async {
            self.histogramImage = image.cgImage
        }
    }
    
    func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let rowBytes = width * 4
        var data = [UInt8](repeating: 0, count: rowBytes * height)
        
        texture.getBytes(&data, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
