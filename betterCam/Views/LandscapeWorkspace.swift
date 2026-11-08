import SwiftUI
import UIKit

enum CameraDisplay {
    case phone, duoOuter, duoInner

    var sideMargin: CGFloat {
        switch self {
        case .phone: return 8
        case .duoOuter: return 16
        case .duoInner: return 28
        }
    }

    var gripOffset: CGFloat {
        switch self {
        case .phone: return 0
        case .duoOuter: return -4
        case .duoInner: return -8
        }
    }
}

struct LandscapeWorkspace<Content: View>: View {
    private let content: (CGSize, Int, CameraDisplay) -> Content
    @Environment(\.horizontalSizeClass) private var horizontalClass
    @Environment(\.verticalSizeClass) private var verticalClass
    @State private var hingeDisplay: CameraDisplay?
    @State private var axes: DisplayAxes?

    init(@ViewBuilder content: @escaping (CGSize, Int, CameraDisplay) -> Content) {
        self.content = content
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            workspace.onHingeChange { _, context in
                hingeDisplay = context.hinge.map { $0.status == .closed ? .duoOuter : .duoInner }
            }
        } else {
            workspace
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let display = hingeDisplay ?? (horizontalClass == .regular && verticalClass == .regular ? .duoInner : .phone)
            let size = geometry.size
            // In its open, buttons-up pose Duo reports landscapeLeft. On the outer
            // display and on a phone, the grip belongs at the portrait bottom edge.
            let referenceTurns = display == .duoInner ? 2 : 0
            let turns = axes.map { ($0.sensorTurns - referenceTurns + 4) % 4 } ?? (size.height > size.width ? 1 : 0)
            let swap = !turns.isMultiple(of: 2)
            let insets = geometry.safeAreaInsets
            let dy = display == .duoInner || !swap ? insets.bottom - insets.top : 0
            let dx = display == .duoInner ? insets.trailing - insets.leading : 0
            let width = max(0, size.width - abs(dx))
            let height = max(0, size.height - abs(dy))
            let landscape = CGSize(width: swap ? height : width, height: swap ? width : height)
            content(landscape, turns, display)
                .environment(\.cameraPreviewOrientation, referenceTurns == 2 ? .down : .up)
                .frame(width: landscape.width, height: landscape.height)
                .rotationEffect(.degrees(Double(turns) * 90))
                .position(x: (size.width + dx) / 2, y: (size.height + dy) / 2)
        }
        .background {
            DisplayAxesReader { value in
                if axes != value { axes = value }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct DisplayAxes: Equatable {
    let interface: UIInterfaceOrientation

    var sensorTurns: Int {
        switch interface {
        case .portrait: return 1
        case .portraitUpsideDown: return 3
        case .landscapeLeft: return 2
        default: return 0
        }
    }

}

extension EnvironmentValues {
    @Entry var cameraPreviewOrientation: Image.Orientation = .up
}

// Follow the long axis of this display in physical coordinates. A scene rotation
// changes its direction in window coordinates, but leaves the controls on the same edge.
private struct DisplayAxesReader: UIViewRepresentable {
    let changed: (DisplayAxes) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.changed = changed
        return view
    }

    func updateUIView(_ view: Probe, context: Context) { view.changed = changed }

    final class Probe: UIView {
        var changed: ((DisplayAxes) -> Void)?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = window?.windowScene?.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.reportAxes() }
            }
        }

        private func reportAxes() {
            guard let interface = window?.windowScene?.effectiveGeometry.interfaceOrientation,
                  interface != .unknown else { return }
            changed?(DisplayAxes(interface: interface))
        }
    }
}
