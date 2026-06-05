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
    private let renderQueue = DispatchQueue(label: "com.bettercam.whRenderQueue")
    private let indicatorFrameInterval: TimeInterval = 0.12
    private let histogramSmoothing: Float = 0.72
    private var lastIndicatorFrameTimestamp: TimeInterval = 0
    private var isWaveformProcessing = false
    private var isHistogramProcessing = false
    private var smoothedHistogram = [Float](repeating: 0, count: 256)
    
    @Published var waveformImage: CGImage?
    @Published var histogramImage: CGImage?
    
    private init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        
        if let device = device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        
        setupPipelines()
    }
    
    private func setupPipelines() {
        guard let device = device, let library = device.makeDefaultLibrary() else { return }
        
        if let waveformKernel = library.makeFunction(name: "waveformKernel") {
            waveformPipeline = try? device.makeComputePipelineState(function: waveformKernel)
        }
        
        if let histKernel = library.makeFunction(name: "histKernel") {
            histogramPipeline = try? device.makeComputePipelineState(function: histKernel)
        }
        
        histogramBuffer = device.makeBuffer(length: 256 * MemoryLayout<UInt32>.stride, options: .storageModeShared)
    }
    
    func process(pixelBuffer: CVPixelBuffer) {
        if self.exposureIndicatorMode == .off {
            if waveformImage != nil || histogramImage != nil {
                DispatchQueue.main.async {
                    self.resetIndicatorState()
                }
            }
            return
        }
        guard shouldProcessIndicatorFrame() else { return }
        
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
        }
    }
    
    private func shouldProcessIndicatorFrame() -> Bool {
        let now = Date().timeIntervalSince1970
        guard now - lastIndicatorFrameTimestamp >= indicatorFrameInterval else { return false }
        lastIndicatorFrameTimestamp = now
        return true
    }
    
    func resetIndicatorState() {
        isWaveformProcessing = false
        isHistogramProcessing = false
        lastIndicatorFrameTimestamp = 0
        smoothedHistogram = [Float](repeating: 0, count: 256)
        waveformImage = nil
        histogramImage = nil
    }
    
    func processWaveform(from pixelBuffer: CVPixelBuffer) {
        guard !isWaveformProcessing else { return }
        guard exposureIndicatorMode == .waveform,
              let pipeline = waveformPipeline,
              let queue = commandQueue,
              let cache = textureCache else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture = cvTexture,
              let inputTexture = CVMetalTextureGetTexture(cvTexture) else { return }
        
        // 输出纹理强制设为 128x64
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: overlayWidth, height: overlayHeight, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        guard let outputTexture = device?.makeTexture(descriptor: desc) else { return }
        
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        isWaveformProcessing = true
        
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
                self.isWaveformProcessing = false
                if self.exposureIndicatorMode == .waveform {
                    self.waveformImage = cgImage // storage target view
                }
            }
        }
        commandBuffer.commit()
    }

    // MARK: - Histogram Process
    func processHistogram(from pixelBuffer: CVPixelBuffer) {
        guard !isHistogramProcessing else { return }
        guard exposureIndicatorMode == .histogram,
              let pipeline = histogramPipeline,
              let queue = commandQueue,
              let cache = textureCache,
              let hBuffer = histogramBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture = cvTexture,
              let inputTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        // 重置统计数据
        memset(hBuffer.contents(), 0, hBuffer.length)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        isHistogramProcessing = true

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
            guard let self = self else { return }
            let ptr = hBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
            let counts = (0..<256).map { ptr[$0] }
            self.renderQueue.async {
                let cgImage = self.renderHistogramUI(counts: counts)
                DispatchQueue.main.async {
                    self.isHistogramProcessing = false
                    if self.exposureIndicatorMode == .histogram {
                        self.histogramImage = cgImage
                    }
                }
            }
        }
        commandBuffer.commit()
    }

    private func renderHistogramUI(counts: [UInt32]) -> CGImage? {
        var maxCount: Float = 1.0
        for i in 0..<min(counts.count, 256) {
            smoothedHistogram[i] = smoothedHistogram[i] * histogramSmoothing + Float(counts[i]) * (1.0 - histogramSmoothing)
            maxCount = max(maxCount, sqrt(smoothedHistogram[i]))
        }

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
                let count = (smoothedHistogram[binIndex] + smoothedHistogram[binIndex + 1]) / 2.0
                let barHeight = CGFloat(sqrt(count) / maxCount) * size.height
                
                ctx.fill(CGRect(x: CGFloat(x), y: size.height - barHeight, width: 1.0, height: barHeight))
            }
        }
        
        return image.cgImage
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
