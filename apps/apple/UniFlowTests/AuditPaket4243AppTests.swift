import CloudKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Audit 08.11.2026, Pakete 42/43 auf dem iPad (docs/audit/AUDIT-2026-11-08-PAKET-42-43.md):
/// - P42-04: zwei Geraete aendern denselben CloudKit-Datensatz (Loesung aktualisieren, Kommentar bearbeiten): der zweite
///   bekommt `serverRecordChanged`. Vorher kam der englische Text von CloudKit bei der Oberflaeche an.
/// - P43-08: "Karteikarten aus Dokument": die Vorschau gehoert zum Dokument, aus dem die KI sie erstellt hat. Vorher
///   speicherte "Übernehmen" nach einem Wechsel des Dokuments die Karten mit dem NEUEN Dokument als Quelle (und dessen
///   Fach), und eine spaet ankommende Antwort fuer Dokument A landete in der Vorschau von Dokument B.
@MainActor
final class AuditPaket4243AppTests: XCTestCase {

    func testP42_04ChangedOnAnotherDeviceHasAGermanText() {
        let mapped = CKCommunityCloud.map(CKError(.serverRecordChanged))
        XCTAssertEqual(mapped.serviceError.localizedDescription,
                       "Der Eintrag wurde gerade auf einem anderen Gerät geändert. Lade neu und versuche es noch einmal.")
        XCTAssertEqual(CloudKitCommunityService.serviceError(CKCommunityCloud.map(CKError(.serverRecordChanged))).localizedDescription,
                       "Der Eintrag wurde gerade auf einem anderen Gerät geändert. Lade neu und versuche es noch einmal.")
        // bekannte Faelle unveraendert
        XCTAssertEqual(CKCommunityCloud.map(CKError(.networkUnavailable)), .offline)
        XCTAssertEqual(CKCommunityCloud.map(CKError(.permissionFailure)), .permission)
    }

    func testP43_08PreviewBelongsToTheDocumentTheCardsCameFrom() {
        // ohne Vorschau: jedes Dokument
        XCTAssertTrue(FlashcardComposer.keepsPreview(cardsFrom: nil, selected: "f-2"))
        // Vorschau aus f-1: bleibt nur bei f-1
        XCTAssertTrue(FlashcardComposer.keepsPreview(cardsFrom: "f-1", selected: "f-1"))
        XCTAssertFalse(FlashcardComposer.keepsPreview(cardsFrom: "f-1", selected: "f-2"), "anderes Dokument: Vorschau verwerfen")
        XCTAssertFalse(FlashcardComposer.keepsPreview(cardsFrom: "f-1", selected: ""), "kein Dokument mehr gewaehlt")
    }
}
