import SwiftUI
import Testing
@testable import betterCam

@MainActor
struct WelcomeGuideTests {
    @Test func everyPageRendersInEveryLanguage() throws {
        let folder = ProcessInfo.processInfo.environment["GUIDE_RENDER_DIR"]
        for language in ["en", "ja", "zh-Hans"] {
            for size in [CGSize(width: 456, height: 342), CGSize(width: 720, height: 540)] {
                for page in WelcomeGuide.Page.allCases {
                    let view = WelcomeGuide(startPage: page, scrolls: false) {}
                        .frame(width: size.width, height: size.height)
                        .environment(\.locale, Locale(identifier: language))
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try #require(renderer.cgImage, "\(language) \(page) \(size)")
                    #expect(image.width == Int(size.width * 2))
                    if let folder, let destination = CGImageDestinationCreateWithURL(
                        URL(fileURLWithPath: folder)
                            .appendingPathComponent("\(language)-\(Int(size.width))-\(page.rawValue).png") as CFURL,
                        "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil)
                        CGImageDestinationFinalize(destination)
                    }
                }
            }
        }
    }
}
