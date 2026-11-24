import SwiftUI

/// First-launch guide, shown inside the camera's screen. The camera starts once it closes.
struct TutorialOverlay: View {
    @ObservedObject var camera: Camera

    var body: some View {
        WelcomeGuide {
            camera.hasCompletedTutorial = true
            camera.isShowingTutorial = false
        }
    }
}

struct WelcomeGuide: View {
    enum Page: Int, CaseIterable {
        case controls, look, format, styles
    }

    let onFinish: () -> Void
    /// Off only for snapshot tests: ImageRenderer cannot draw a ScrollView's content.
    var scrolls = true
    @State private var page: Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let accent = Color.yellow

    /// Type and spacing for the size of the camera screen the guide fills.
    private struct Scale {
        let title: CGFloat, body: Font, note: Font, icon: CGFloat
        let inset: CGFloat, blockSpacing: CGFloat, rowSpacing: CGFloat

        init(height: CGFloat) {
            switch height {
            case ..<380:   // smaller phones
                (title, body, note, icon) = (22, .subheadline, .caption, 14)
                (inset, blockSpacing, rowSpacing) = (30, 12, 9)
            case ..<520:   // larger phones
                (title, body, note, icon) = (28, .callout, .footnote, 15)
                (inset, blockSpacing, rowSpacing) = (38, 18, 12)
            default:       // iPad, Duo
                (title, body, note, icon) = (38, .title3, .callout, 19)
                (inset, blockSpacing, rowSpacing) = (56, 26, 18)
            }
        }
    }

    init(startPage: Page = .controls, scrolls: Bool = true, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        self.scrolls = scrolls
        _page = State(initialValue: startPage)
    }

    private var isLast: Bool { page == Page.allCases.last }

    var body: some View {
        GeometryReader { geometry in
            let scale = Scale(height: geometry.size.height)
            VStack(alignment: .leading, spacing: 0) {
                header
                let page = content(scale)
                    .id(self.page)
                    .transition(pageTransition)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                // Centred in the space between header and footer; scrolls only when large
                // text sizes outgrow the camera screen.
                if scrolls {
                    GeometryReader { area in
                        ScrollView {
                            page.frame(minHeight: area.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                    }
                } else {
                    page.frame(maxHeight: .infinity)
                }
                footer
            }
            // One margin on all four sides. Header and footer carry no extra layout padding,
            // so the counter, Skip, the progress bar and the button sit exactly on it.
            .padding(scale.inset)
            .contentShape(Rectangle())
            .gesture(swipe)
        }
        .background(Color(white: 0.05))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .clipped()
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Text(verbatim: String(format: "%02d / %02d", page.rawValue + 1, Page.allCases.count))
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityLabel(Text("Step \(page.rawValue + 1) of \(Page.allCases.count)"))
            Spacer()
            if !isLast {
                Button("Skip", action: onFinish)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .expandedHitArea(horizontal: 14, vertical: 14)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == page ? Self.accent : .white.opacity(0.18))
                        .frame(width: item == page ? 22 : 8, height: 3)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            Button(action: advance) {
                Text(isLast ? LocalizedStringKey("Start Shooting") : LocalizedStringKey("Next"))
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .background(isLast ? Self.accent : .white, in: Capsule())
            }
            .buttonStyle(.plain)
            .expandedHitArea(horizontal: 4, vertical: 4)
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func content(_ scale: Scale) -> some View {
        switch page {
        case .controls:
            pageBody("WELCOME", title: "Turn. Press. Shoot.", scale: scale) {
                row(scale, symbol: "dial.medium", "Rotate the dial to switch items")
                row(scale, symbol: "circle.circle", "Press the center to select, then rotate to change it.")
                row(scale, symbol: "camera.shutter.button", "Press the shutter button to shoot.")
            }
        case .look:
            pageBody("LOOK", title: "Color & grain", scale: scale) {
                row(scale, symbol: "arrow.left.and.right", "Swipe horizontally for Profile Intensity")
                row(scale, symbol: "arrow.up.and.down", "Swipe vertically for Grain")
                note(scale, "Grain shows in the viewfinder only while you adjust it.")
            }
        case .format:
            pageBody("FORMAT", title: "Format marks", scale: scale) {
                markRow(scale, .highResolution, "48-megapixel capture. Available with JPEG and ProRAW.")
                markRow(scale, .zeroProcessing, "ZERO PROCESSING: the JPEG is developed from RAW without Apple's processing. Turn it on in MENU.")
                note(scale, "Select the format in the top bar, then rotate the dial to change it.")
            }
        case .styles:
            pageBody("STYLES", title: "Your LUTs", scale: scale) {
                row(scale, symbol: "camera.filters", "In STYLE, select MANAGE and press the center of the dial to open your LUTs.")
                row(scale, symbol: "hand.point.left", "Swipe left to rename or delete.")
            }
        }
    }

    private func pageBody<Rows: View>(
        _ eyebrow: String, title: LocalizedStringKey, scale: Scale, @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: scale.blockSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: eyebrow)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Self.accent)
                Text(title)
                    .font(.system(size: scale.title, weight: .bold, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: scale.rowSpacing) {
                rows()
            }
        }
    }

    private func row(_ scale: Scale, symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: scale.icon, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: scale.icon + 9)
                .accessibilityHidden(true)
            Text(text)
                .font(scale.body)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One badge as it appears in the top bar, next to what it means.
    private func markRow(_ scale: Scale, _ badge: CaptureMode.Badge, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ParameterLabel(title: "JPEG", badge: badge)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .padding(.trailing, 10)
                .frame(width: 84, height: 34)
                .background(.black, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))
                .accessibilityHidden(true)
            Text(text)
                .font(scale.body)
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ scale: Scale, _ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(scale.note)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.leading, scale.icon + 23)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Navigation

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 24)),
            removal: .opacity.combined(with: .offset(x: -24))
        )
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            if value.translation.width < 0 {
                if !isLast { go(to: page.rawValue + 1) }
            } else {
                go(to: page.rawValue - 1)
            }
        }
    }

    private func advance() {
        if isLast { onFinish() } else { go(to: page.rawValue + 1) }
    }

    private func go(to index: Int) {
        guard let next = Page(rawValue: index) else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) { page = next }
    }
}

private extension View {
    /// Grows the tappable area to at least 44 pt without changing layout, so a control
    /// can sit exactly on the margin and still be easy to hit.
    func expandedHitArea(horizontal: CGFloat, vertical: CGFloat) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }
}
