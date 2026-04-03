//
//  MetalWHViews.swift
//  betterCam
//
//  Created by Rice on 2026/4/3.
//

import Foundation
import Metal
import MetalKit
import CoreImage
import UIKit

extension Camera {
    
    func setupMetal() {
        guard let device = device else { return }
        commandQueue = device.makeCommandQueue()
        let library = device.makeDefaultLibrary()
        
        // 初始化 Waveform 管线
        if let kernel = library?.makeFunction(name: "waveformKernel") {
            pipelineState = try? device.makeComputePipelineState(function: kernel)
        }
        
        // 初始化 Histogram 计算管线
        if let histKernel = library?.makeFunction(name: "histogram_compute") {
            histogramComputePipeline = try! device.makeComputePipelineState(function: histKernel)
        }
        
        // 初始化直方图 Buffer (256个等级)
        histogramBuffer = device.makeBuffer(length: 256 * MemoryLayout<UInt32>.stride, options: .storageModeShared)
    }

    // MARK: - Waveform Process
    func processWaveform(from pixelBuffer: CVPixelBuffer) {
        guard exposureIndicatorMode == .waveform,
              let pipeline = pipelineState,
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
              let pipeline = histogramComputePipeline,
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

    // MARK: - Helpers
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
