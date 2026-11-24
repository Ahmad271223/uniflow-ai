import LocalAuthentication
import UniFlowCore
import XCTest
@testable import UniFlow

/// "Konto löschen" nur durch die Besitzerin oder den Besitzer des Geraets (24.11.2026, `DeviceOwnerCheck`,
/// `DeleteAccountGate`) und die ehrlichen Texte zur 30-Tage-Aufbewahrung. Die Systemabfrage ersetzt der Haken
/// `DeviceOwnerCheck.evaluate`; kein Face ID, kein Code, keine echten Konten.
@MainActor
final class KontoLoeschenSchutzAppTests: XCTestCase {
    private var original: (@MainActor (String) async -> DeviceOwnerCheck.Result)!

    override func setUp() async throws {
        try await super.setUp()
        original = DeviceOwnerCheck.evaluate
    }

    override func tearDown() async throws {
        DeviceOwnerCheck.evaluate = original
        try await super.tearDown()
    }

    /// Der Haken ersetzt die Systemabfrage (unter XCTest beantwortet sie niemand) und bekommt den Grund mit
    func testHookReplacesTheSystemPrompt() async {
        var asked: [String] = []
        DeviceOwnerCheck.evaluate = { reason in asked.append(reason); return .confirmed }
        let r = await DeviceOwnerCheck.confirm()
        XCTAssertEqual(r, .confirmed)
        XCTAssertEqual(asked, [DeviceOwnerCheck.reason])

        var gate = DeleteAccountGate()
        DeviceOwnerCheck.evaluate = { _ in .cancelled }
        let step = await gate.tap(typed: "")
        XCTAssertEqual(step, .wait, "der Dialog nutzt dieselbe Pruefung")
    }

    func testConfirmedOwnerProceedsAndIsNotAskedAgain() async {
        var gate = DeleteAccountGate()
        var calls = 0
        let first = await gate.tap(typed: "") { calls += 1; return .confirmed }
        XCTAssertEqual(first, .proceed)
        XCTAssertTrue(gate.ownerConfirmed)
        // "Erneut versuchen" nach einem Fehler des Dienstes
        let again = await gate.tap(typed: "") { calls += 1; return .cancelled }
        XCTAssertEqual(again, .proceed)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(gate.message)
    }

    /// Abbrechen in der Abfrage: nichts wird geloescht, keine Fehlermeldung; das naechste Antippen fragt erneut
    func testCancelledCheckDeletesNothing() async {
        var gate = DeleteAccountGate()
        let step = await gate.tap(typed: "") { .cancelled }
        XCTAssertEqual(step, .wait)
        XCTAssertFalse(gate.ownerConfirmed)
        XCTAssertNil(gate.message)
        var calls = 0
        _ = await gate.tap(typed: "") { calls += 1; return .cancelled }
        XCTAssertEqual(calls, 1)
    }

    func testFailedCheckShowsTheMessage() async {
        var gate = DeleteAccountGate()
        let step = await gate.tap(typed: "") { .failed("gesperrt") }
        XCTAssertEqual(step, .wait)
        XCTAssertEqual(gate.message, "gesperrt")
        XCTAssertFalse(gate.needsTypedConfirmation)
    }

    /// Ohne Geraetecode (z. B. Simulator, iPad ohne Code): Loeschen bleibt moeglich, aber nur mit "LÖSCHEN" eingetippt
    func testWithoutPasscodeTheWordMustBeTyped() async {
        var gate = DeleteAccountGate()
        let first = await gate.tap(typed: "") { .noPasscode }
        XCTAssertEqual(first, .wait)
        XCTAssertTrue(gate.needsTypedConfirmation)
        XCTAssertEqual(gate.message, DeleteAccountGate.noPasscodeMessage)

        var calls = 0
        let wrong = await gate.tap(typed: "loesch") { calls += 1; return .confirmed }
        XCTAssertEqual(wrong, .wait)
        XCTAssertEqual(calls, 0, "kein zweites Mal die Systemabfrage")
        XCTAssertNotNil(gate.message)

        let right = await gate.tap(typed: " löschen ") { calls += 1; return .confirmed }
        XCTAssertEqual(right, .proceed)
        XCTAssertTrue(gate.ownerConfirmed)
        XCTAssertNil(gate.message)
        XCTAssertTrue(DeleteAccountGate.matches("LÖSCHEN"))
        XCTAssertFalse(DeleteAccountGate.matches("LOESCHEN"))
        XCTAssertFalse(DeleteAccountGate.matches(""))
    }

    func testSystemErrorsMapToResults() {
        XCTAssertEqual(DeviceOwnerCheck.result(for: LAError(.passcodeNotSet)), .noPasscode)
        for code in [LAError.Code.userCancel, .appCancel, .systemCancel, .userFallback] {
            XCTAssertEqual(DeviceOwnerCheck.result(for: LAError(code)), .cancelled, "\(code)")
        }
        guard case .failed(let m) = DeviceOwnerCheck.result(for: LAError(.biometryLockout)) else { return XCTFail("Sperre") }
        XCTAssertTrue(m.contains("gesperrt"), m)
        XCTAssertEqual(DeviceOwnerCheck.result(for: LAError(.authenticationFailed)), .failed(DeviceOwnerCheck.failedMessage))
        XCTAssertEqual(DeviceOwnerCheck.result(for: NSError(domain: "x", code: 1)), .failed(DeviceOwnerCheck.failedMessage))
    }

    /// Face ID braucht den Hinweistext im Info.plist, sonst beendet iOS die App bei der ersten Abfrage
    func testFaceIDUsageDescriptionIsInTheApp() {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String
        XCTAssertTrue(text?.contains("Konto") ?? false, text ?? "fehlt")
    }

    /// Ehrlich zur Aufbewahrung (Richtlinie 5.1.1(v): Dauer nennen; Datenschutz Abschnitt 15)
    func testDialogTextsSayWhatHappensToTheDataOnTheDevice() {
        let keep = DeleteAccountText.localData(keep: true)
        XCTAssertTrue(keep.contains("30 Tage"), keep)
        XCTAssertTrue(keep.contains("derselben Apple-ID"), keep)
        XCTAssertTrue(keep.contains("endgültig gelöscht"), keep)
        XCTAssertTrue(keep.contains("nicht in iCloud-Backups"), keep)
        XCTAssertTrue(keep.contains("StudiNow-Konto beim Dienst bleibt gelöscht"), keep)
        XCTAssertFalse(keep.contains("nicht rückgängig"), keep)
        let now = DeleteAccountText.localData(keep: false)
        XCTAssertTrue(now.contains("nicht rückgängig"), now)
        XCTAssertFalse(now.contains("30 Tage"), now)
        XCTAssertTrue(DeleteAccountText.immediately.contains("sofort endgültig"))

        let held = HeldDataText.explanation(deletedAt: Date(timeIntervalSince1970: 1_795_000_000),
                                            expiresAt: Date(timeIntervalSince1970: 1_795_000_000 + 30 * 86400))
        XCTAssertTrue(held.contains("endgültig gelöscht"), held)
        XCTAssertTrue(held.contains("bleibt gelöscht"), held)
    }
}
