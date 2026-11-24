import SwiftUI
import Testing
@testable import betterCam

@MainActor
struct ParameterLabelTests {
    private struct Bitmap {
        let width: Int, height: Int
        let pixels: [UInt8]
        func lit(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 60
        }
        /// Columns that contain any drawn pixel.
        var litColumns: [Int] {
            (0..<width).filter { x in (0..<height).contains { lit(x, $0) } }
        }
    }

    private func render(_ title: String, badge: CaptureMode.Badge?, name: String) throws -> Bitmap {
        let view = ParameterLabel(title: title, badge: badge)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .frame(width: 120, height: 40)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Keep a copy for eyeballing when run on a Mac host; ignored if the folder is absent.
        if let folder = ProcessInfo.processInfo.environment["BADGE_RENDER_DIR"],
           let destination = CGImageDestinationCreateWithURL(
               URL(fileURLWithPath: folder).appendingPathComponent("\(name).png") as CFURL,
               "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    @Test(arguments: [("JPEG", CaptureMode.Badge.highResolution), ("JPEG", .zeroProcessing),
                      ("ProRAW", .highResolution), ("DNG+J", .zeroProcessing)])
    func badgeSitsAfterTheWord(title: String, badge: CaptureMode.Badge) throws {
        let plain = try render(title, badge: nil, name: "\(title)-plain")
        let badged = try render(title, badge: badge, name: "\(title)-\(badge)")
        let word = plain.litColumns
        let wordEnd = try #require(word.last)

        // The word itself is drawn exactly as without the badge: same place, same size.
        for x in 0...wordEnd {
            for y in 0..<plain.height {
                #expect(plain.lit(x, y) == badged.lit(x, y), "\(title) changed at \(x),\(y)")
                if plain.lit(x, y) != badged.lit(x, y) { return }
            }
        }
        // And the badge adds ink only to the right of the last letter.
        let extra = badged.litColumns.filter { $0 > wordEnd }
        #expect(!extra.isEmpty, "\(title) badge not drawn")
    }
}
