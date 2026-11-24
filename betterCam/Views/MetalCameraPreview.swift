import CoreImage
import ImageIO
import MetalKit
import SwiftUI

final class CameraPreviewFrames {
    struct Snapshot {
        let revision: UInt64
        let image: CIImage
        let mirrored: Bool
        let look: FilmRenderSettings
        let grainVisibility: Float
    }

    // Grain only shows while the look gesture is active, then lingers briefly and fades,
    // so composing sees the colour look without a layer of moving specks on top.
    static let grainHold: TimeInterval = 1.0
    static let grainFade: TimeInterval = 0.4

    static func grainVisibility(adjusting: Bool, releasedAt: TimeInterval?, now: TimeInterval) -> Float {
        if adjusting { return 1 }
        guard let releasedAt else { return 0 }
        let fading = (now - releasedAt - grainHold) / grainFade
        return Float(min(max(1 - fading, 0), 1))
    }

    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var image: CIImage?
    private var mirrored = false
    private var look: FilmRenderSettings = .standard
    private var adjustingGrain = false
    private var grainReleasedAt: TimeInterval?

    func update(image: CIImage, mirrored: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.image = image
        self.mirrored = mirrored
        revision &+= 1
    }

    func update(look: FilmRenderSettings) {
        lock.lock()
        defer { lock.unlock() }
        self.look = look
        revision &+= 1
    }

    func setAdjustingGrain(_ adjusting: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard adjusting != adjustingGrain else { return }
        adjustingGrain = adjusting
        grainReleasedAt = adjusting ? nil : ProcessInfo.processInfo.systemUptime
        revision &+= 1
    }

    func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        let visibility = Self.grainVisibility(
            adjusting: adjustingGrain, releasedAt: grainReleasedAt, now: ProcessInfo.processInfo.systemUptime
        )
        return image.map {
            Snapshot(revision: revision, image: $0, mirrored: mirrored, look: look, grainVisibility: visibility)
        }
    }
}

struct MetalCameraPreview: UIViewRepresentable {
    let frames: CameraPreviewFrames
    let orientation: Image.Orientation
    let switchingLens: Bool

    func makeCoordinator() -> Renderer { Renderer(frames: frames) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        (view.layer as? CAMetalLayer)?.colorspace = FilmEngine.deliveryColorSpace
        view.framebufferOnly = false
        view.delegate = context.coordinator
        view.isPaused = context.coordinator.device == nil
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "Preview")
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.orientation = orientation.exifOrientation
        context.coordinator.switchingLens = switchingLens
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
        view.isPaused = true
        view.delegate = nil
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        private let frames: CameraPreviewFrames
        private let commands: MTLCommandQueue?
        private let context: CIContext?
        private let inFlight = DispatchSemaphore(value: 2)
        private var lastDraw: DrawState?
        private let black = CIImage(color: .black)

        var orientation = CGImagePropertyOrientation.up
        var switchingLens = false

        private struct DrawState: Equatable {
            let revision: UInt64
            let orientation: CGImagePropertyOrientation
            let switchingLens: Bool
            let size: CGSize
        }

        init(frames: CameraPreviewFrames) {
            self.frames = frames
            let queue = device?.makeCommandQueue()
            commands = queue
            context = queue.map {
                CIContext(mtlCommandQueue: $0, options: [
                    .workingColorSpace: FilmEngine.workingColorSpace,
                    .cacheIntermediates: false
                ])
            }
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            lastDraw = nil
        }

        func draw(in view: MTKView) {
            guard let frame = frames.snapshot(), let context, let commands else { return }
            let draw = DrawState(
                revision: frame.revision, orientation: orientation,
                switchingLens: switchingLens, size: view.drawableSize
            )
            guard draw != lastDraw, draw.size.width > 0, draw.size.height > 0,
                  inFlight.wait(timeout: .now()) == .success else { return }
            guard let drawable = view.currentDrawable, let command = commands.makeCommandBuffer() else {
                inFlight.signal()
                return
            }

            let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
            let oriented = frame.image.oriented(draw.orientation)
            let scale = min(bounds.width / oriented.extent.width, bounds.height / oriented.extent.height)
            let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
            let centered = scaled.transformed(by: CGAffineTransform(
                translationX: bounds.midX - scaled.extent.midX, y: bounds.midY - scaled.extent.midY
            ))
            // One fixed pattern: grain only shows briefly while it is being adjusted, and a
            // new pattern every camera frame flickered.
            let seed: UInt32 = 0x71E3C4B9
            var look = frame.look
            look.grainAmount *= frame.grainVisibility
            var image = FilmEngine.process(centered, settings: look, grainSeed: seed)
            if draw.switchingLens {
                image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: 30 * view.contentScaleFactor
                ]).cropped(to: centered.extent)
            }
            image = image.composited(over: black.cropped(to: bounds))

            let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
            destination.colorSpace = FilmEngine.deliveryColorSpace
            do {
                _ = try context.startTask(toRender: image, to: destination)
                let slot = inFlight
                command.addCompletedHandler { _ in slot.signal() }
                command.present(drawable)
                command.commit()
                lastDraw = draw
            } catch {
                inFlight.signal()
            }
        }
    }
}

private extension Image.Orientation {
    var exifOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
