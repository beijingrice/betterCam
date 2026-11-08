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
    @Published private(set) var exposureIndicatorMode: ExposureMode = .off
    
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
    private let frameSlot = DispatchSemaphore(value: 1)
    private var renderMode: ExposureMode = .off
    private var renderGeneration = 0
    private var displayGeneration = 0
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
    
    func setMode(_ mode: ExposureMode) {
        guard mode != exposureIndicatorMode else { return }
        exposureIndicatorMode = mode
        waveformImage = nil
        histogramImage = nil
        displayGeneration += 1
        let generation = displayGeneration
        renderQueue.async {
            self.renderMode = mode
            self.renderGeneration = generation
            self.lastIndicatorFrameTimestamp = 0
            self.smoothedHistogram = [Float](repeating: 0, count: 256)
        }
    }

    func process(pixelBuffer: CVPixelBuffer) {
        guard frameSlot.wait(timeout: .now()) == .success else { return }
        renderQueue.async {
            let now = ProcessInfo.processInfo.systemUptime
            guard self.renderMode != .off,
                  now - self.lastIndicatorFrameTimestamp >= self.indicatorFrameInterval,
                  let texture = self.inputTexture(from: pixelBuffer) else {
                self.frameSlot.signal()
                return
            }
            let submitted: Bool
            switch self.renderMode {
            case .waveform: submitted = self.processWaveform(texture)
            case .histogram: submitted = self.processHistogram(texture)
            case .off: submitted = false
            }
            if submitted {
                self.lastIndicatorFrameTimestamp = now
            } else {
                self.frameSlot.signal()
            }
        }
    }

    private func inputTexture(from pixelBuffer: CVPixelBuffer) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
                                                  0, &texture)
        return texture
    }

    private func processWaveform(_ texture: CVMetalTexture) -> Bool {
        guard let pipeline = waveformPipeline, let queue = commandQueue,
              let inputTexture = CVMetalTextureGetTexture(texture) else { return false }
        // 输出纹理强制设为 128x64
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: overlayWidth, height: overlayHeight, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        guard let outputTexture = device?.makeTexture(descriptor: desc) else { return false }
        
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(width: (outputTexture.width + 15) / 16,
                                   height: (outputTexture.height + 15) / 16,
                                   depth: 1)
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        let generation = renderGeneration
        commandBuffer.addCompletedHandler { [self, texture] buffer in
            defer { frameSlot.signal() }
            withExtendedLifetime(texture) {
                guard buffer.status == .completed else { return }
                let image = makeCGImage(from: outputTexture)
                DispatchQueue.main.async {
                    if self.displayGeneration == generation { self.waveformImage = image }
                }
            }
        }
        commandBuffer.commit()
        return true
    }

    // MARK: - Histogram Process
    private func processHistogram(_ texture: CVMetalTexture) -> Bool {
        guard let pipeline = histogramPipeline, let queue = commandQueue, let hBuffer = histogramBuffer,
              let inputTexture = CVMetalTextureGetTexture(texture) else { return false }

        // 重置统计数据
        memset(hBuffer.contents(), 0, hBuffer.length)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

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
        
        let generation = renderGeneration
        commandBuffer.addCompletedHandler { [self, texture] buffer in
            withExtendedLifetime(texture) {
                renderQueue.async {
                    defer { self.frameSlot.signal() }
                    guard buffer.status == .completed, self.renderGeneration == generation else { return }
                    let ptr = hBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
                    let image = self.renderHistogramUI(counts: Array(UnsafeBufferPointer(start: ptr, count: 256)))
                    DispatchQueue.main.async {
                        if self.displayGeneration == generation { self.histogramImage = image }
                    }
                }
            }
        }
        commandBuffer.commit()
        return true
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
