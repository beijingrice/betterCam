import AppIntents

// 💡 关键：必须遵守 CameraCaptureIntent 协议
@available(iOS 18.0, *)
struct StartBetterCamIntent: CameraCaptureIntent {
    static var title: LocalizedStringResource = "Launch betterCam"
    static var description = IntentDescription("Launch betterCam to take photos.")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // 系统按下快门时会执行这里
        return .result()
    }
}
