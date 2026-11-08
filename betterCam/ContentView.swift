import SwiftUI

struct ContentView: View {
    @ObservedObject var camera: Camera
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsCamera: Bool { camera.inCameraView && !camera.isShowingMenu }
    private var pageAnimation: Animation { .easeInOut(duration: reduceMotion ? 0.15 : 0.24) }
    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
    }

    var body: some View {
        LandscapeWorkspace { size, turns, display in
            ZStack {
                if camera.isShowingMenu {
                    MenuView(camera: camera)
                        .transition(panelTransition)
                        .zIndex(1)
                } else if !camera.inCameraView {
                    LUTManagerView(camera: camera)
                        .transition(panelTransition)
                        .zIndex(1)
                } else {
                    cameraBody(size: size, turns: turns, display: display)
                        .transition(.opacity)
                }
            }
            .animation(pageAnimation, value: showsCamera)
        }
        .background {
            ZStack {
                Color.black
                if showsCamera {
                    BodyFrameBackground().transition(.opacity).zIndex(1)
                }
            }
            .ignoresSafeArea()
            .animation(pageAnimation, value: showsCamera)
        }
        .statusBar(hidden: true)
        .onChange(of: camera.isShowingTutorial) { _, isShowing in
            if !isShowing { camera.startCamera() }
        }
        .environmentObject(camera)
        .environmentObject(camera.parameterManager)
        .environmentObject(camera.lensManager)
    }

    private func cameraBody(size: CGSize, turns: Int, display: CameraDisplay) -> some View {
        let sideMargin = display.sideMargin
        let verticalMargin: CGFloat = 8
        let bezel: CGFloat = 8
        let gripGap = min(32, size.width * 0.035)
        let dialSize = min(140, max(96, size.width * 0.16))
        let lcdWidth = max(0, min(size.width - 2 * (sideMargin + bezel) - gripGap - dialSize,
                                  (size.height - 2 * (verticalMargin + bezel)) * 4 / 3))
        let bodyWidth = lcdWidth + 2 * bezel + gripGap + dialSize
        let gripOffset: CGFloat = display == .phone && turns != 0
            ? min(8, max(0, (size.width - bodyWidth) / 2 - 4))
            : display.gripOffset
        return HStack(alignment: .center, spacing: gripGap) {
            ScreenView()
                .allowsHitTesting(!camera.isShowingTutorial)
                .overlay {
                    if camera.isShowingTutorial {
                        TutorialOverlay(camera: camera)
                    }
                }
                .frame(width: lcdWidth, height: lcdWidth * 3 / 4)
                .wrapInCameraFrame(thickness: bezel)
                .recessedPanel()
            ControlDialView(dialSize: dialSize, verticalSpacing: min(60, max(8, size.height - 2 * verticalMargin - dialSize - 70)))
                .allowsHitTesting(!camera.isShowingTutorial)
                .offset(x: gripOffset)
        }
    }
}
