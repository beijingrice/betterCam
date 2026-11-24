import SwiftUI

struct TutorialOverlay: View {
    @ObservedObject var camera: Camera
    @State private var showsControls = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 520
            let columns = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                               : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))

            VStack(spacing: 0) {
                ScrollView {
                    columns {
                        if showsControls {
                            section("Physical Control:") {
                                Text("Rotate the dial to switch items")
                                Text("Press center to select")
                            }
                            section("Capture:") {
                                Text("Press the shutter button to shoot.")
                            }
                        } else {
                            section("In camera screen:") {
                                Label("Swipe horizontally for Profile Intensity", systemImage: "arrow.left.and.right")
                                Label("Swipe vertically for Grain", systemImage: "arrow.up.and.down")
                            }
                            section("In bottom bar of camera screen:") {
                                Text("In STYLE, select MANAGE and press the center of the dial to open your LUTs.")
                                Text("Swipe left to rename or delete.")
                            }
                        }
                    }
                    .padding(wide ? 24 : 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(showsControls)
                .scrollBounceBehavior(.basedOnSize)

                Divider()
                HStack {
                    Spacer()
                    Button(action: advance) {
                        Text(showsControls ? LocalizedStringKey("Start Shooting") : LocalizedStringKey("Got it"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 4)
            }
        }
        .background(Color(white: 0.06))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .clipped()
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content().font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func advance() {
        if showsControls {
            camera.hasCompletedTutorial = true
            camera.isShowingTutorial = false
        } else {
            showsControls = true
        }
    }
}
