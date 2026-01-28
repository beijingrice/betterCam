import AppIntents

// 💡 关键：必须遵守 CameraCaptureIntent 协议
@available(iOS 18.0, *)
struct StartBetterCamIntent: CameraCaptureIntent {
    static var title: LocalizedStringResource = "启动 BetterCam"
    static var description = IntentDescription("立即打开 BetterCam 拍摄胶片感照片")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // 系统按下快门时会执行这里
        return .result()
    }
}
