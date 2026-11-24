import Testing
@testable import betterCam

@MainActor
struct ExposureModeTests {
    /// The dial observers run on the next main-queue turn.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

    @Test(arguments: ["ISO", "SS"])
    func autoResetsCompensationToZero(dial: String) async throws {
        let pm = ParameterManager()
        // Manual exposure, with the field showing an off-grid meter reading.
        pm.SS = "1/200"
        pm.ISO = "100"
        try await settle()
        pm.EV = "-1.2"

        if dial == "ISO" { pm.ISO = ExposureParameter.auto } else { pm.SS = ExposureParameter.auto }
        try await settle()
        #expect(pm.SS == ExposureParameter.auto && pm.ISO == ExposureParameter.auto)
        #expect(pm.EV == "0.0")
    }
}
