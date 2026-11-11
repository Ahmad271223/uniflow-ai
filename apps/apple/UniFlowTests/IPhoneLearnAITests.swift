import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// KI-Start auf dem iPhone (402 x 874, schmal): Aktionen als eine seitlich scrollende Reihe, Frage-Feld unten fest
/// (ueber Tab-Leiste bzw. Tastatur), Hilfe in voller Breite, Gespraech mit Feld unten, Wochentest und Dokumentwahl als
/// Blatt von unten. Gegenprobe iPad quer: Feld in der Mitte, Dialog mittig. Schein-Transport, keine KI.
@MainActor
final class IPhoneLearnAITests: IPhoneLearnTestCase {

    private func transport() -> Canned {
        let t = Canned()
        t.answer("/api/modules", [["id": 1, "name": "Testmathematik I", "color": "#4f5bd5"], ["id": 2, "name": "Testphysik", "color": "#1f9d5b"]])
        t.answer("/api/library", ["files": [
            ["id": "f-1", "name": "VL01.pdf", "title": "VL01.pdf", "ai_title": "Folgen und Grenzwerte in metrischen Räumen", "module_id": 1,
             "downloaded_at": "2026-10-20T10:00:00", "kind": "pdf", "last_opened": "2026-10-30T10:00:00", "page_count": 12, "chdate": 1_761_000_000],
            ["id": "f-2", "name": "Blatt01.pdf", "title": "Blatt01.pdf", "module_id": 1, "downloaded_at": "2026-10-21T10:00:00", "kind": "pdf",
             "page_count": 3, "chdate": 1_761_100_000]], "modules": [], "folders": [], "trash": []])
        t.answer("/api/ai/tutor", ["answer": "Eine **Folge** ist eine Abbildung von ℕ nach ℝ.\n\n- konvergent: hat einen Grenzwert\n- divergent: sonst", "cards": .null, "sources": []])
        return t
    }

    private func recents(_ entries: Int = 0) throws -> AIRecents {
        let name = "uniflow.tests.iphone.ai.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        let r = AIRecents(defaults: d, scope: "p")
        for i in 0..<entries {
            r.record(question: "Was ist eine Cauchy-Folge? (\(i + 1))", answer: "Eine Folge, deren Glieder sich **beliebig nahe** kommen.",
                     fileID: "f-1", fileName: "Folgen und Grenzwerte")
        }
        return r
    }

    private static let placeholder = "Frag etwas … z. B. Erkläre mir den Satz von Bolzano"

    private func start(_ recents: AIRecents) -> some View {
        AIStartView(entitlements: Entitlements(observe: false, plan: .plus), recents: recents).environment(\.ufAIEnabled, true)
    }

    /// Start schmal: eine Reihe Pillen (gleiche Hoehe, rechts angeschnitten), Feld unten, nichts zu breit
    func testStartHasScrollingPillsAndComposerAtTheBottom() throws {
        let env = try hostPhone(start(try recents(2)), api: remote(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "Was möchtest du heute lernen?") && self.shows(env, "Zuletzt: Was ist") }, dump(env))
        let ask = frame(button(env, "Fragen", prefix: true)), help = frame(button(env, "Hilfe", prefix: true))
        let quiz = frame(button(env, "Wochentest", prefix: true))
        XCTAssertFalse(ask.isNull, dump(env))
        XCTAssertEqual(ask.minY, quiz.minY, accuracy: 2, "Pillen in einer Reihe")
        XCTAssertEqual(ask.minY, help.minY, accuracy: 2, "Pillen in einer Reihe")
        XCTAssertGreaterThan(help.maxX, Self.phone.width, "die Reihe laeuft rechts weiter (scrollt seitlich)")
        let input = frame(element(env, label: Self.placeholder))
        XCTAssertGreaterThan(input.minY, Self.phone.height * 0.65, "Frage-Feld unten: \(input)")
        XCTAssertGreaterThan(input.width, Self.phone.width - 100, "Feld fast in voller Breite: \(input)")
        XCTAssertTrue(shows(env, "Modul: Alle Module"))
        XCTAssertNotNil(button(env, "Angehängt: Folgen und Grenzwerte in metrischen Räumen", prefix: true), dump(env))
        assertFitsOnAllPhones(env, "ki-start")
        shoot(env, "iphone-ki-start")
    }

    /// Hilfe ohne KI: Karte in voller Breite unter den Pillen, Beispiel setzt den Text ins Feld
    func testHelpCardFullWidth() throws {
        let env = try hostPhone(start(try recents()), api: remote(transport()))
        XCTAssertTrue(env.wait { self.button(env, "Hilfe", prefix: true) != nil }, dump(env))
        XCTAssertTrue(tap(env, "Hilfe", prefix: true))
        XCTAssertTrue(env.wait { self.button(env, "Hilfe schließen") != nil }, dump(env))
        let close = frame(button(env, "Hilfe schließen"))
        XCTAssertGreaterThan(close.maxX, Self.phone.width - 50, "Karte reicht bis an den Rand: \(close)")
        XCTAssertTrue(shows(env, AIHelpContent.costLine))
        assertFits(env, "ki-hilfe")
        shoot(env, "iphone-ki-hilfe")
    }

    /// Gespraech schmal: Antwort, Aktionen ueber dem Feld als Reihe, Feld unten fest
    func testChatKeepsComposerAndActionsAtTheBottom() throws {
        let env = try hostPhone(start(try recents(1)), api: remote(transport()))
        XCTAssertTrue(env.wait { self.button(env, "Zuletzt: Was ist eine Cauchy-Folge? (1)") != nil }, dump(env))
        XCTAssertTrue(tap(env, "Zuletzt: Was ist eine Cauchy-Folge? (1)"))
        XCTAssertTrue(env.wait { self.shows(env, "Neues Gespräch") }, dump(env))
        let input = frame(element(env, label: Self.placeholder))
        XCTAssertGreaterThan(input.minY, Self.phone.height * 0.6, "Feld unten: \(input)")
        let pill = frame(button(env, "Karteikarten", prefix: true))
        XCTAssertLessThan(pill.maxY, input.minY + 1, "Aktionen ueber dem Feld")
        XCTAssertTrue(shows(env, "Im Dokument mit KI-Hilfe öffnen"))
        assertFitsOnAllPhones(env, "ki-gespraech")
        shoot(env, "iphone-ki-gespraech")
    }

    /// Wochentest und Dokument anhaengen oeffnen schmal ein Blatt von unten (nicht mittig)
    func testQuizAndDocumentPickerOpenAsSheets() throws {
        let env = try hostPhone(start(try recents()), api: remote(transport()))
        XCTAssertTrue(env.wait { self.button(env, "Wochentest", prefix: true) != nil }, dump(env))
        XCTAssertTrue(tap(env, "Wochentest", prefix: true))
        XCTAssertTrue(waitSheet(env, showing: "Wochentest erstellen"), dump(env))
        XCTAssertTrue(env.wait { self.shows(env, "15 Aufgaben") }, dump(env))
        XCTAssertNotNil(element(env, label: "Thema oder Hinweise"), dump(env))
        assertFits(env, "ki-wochentest-blatt")
        shoot(env, "iphone-ki-wochentest-blatt")
        XCTAssertTrue(tap(env, "Abbrechen"))
        XCTAssertTrue(env.wait { !self.sheetOpen(env) }, "Abbrechen schliesst das Blatt")
        env.pump(0.4)
        XCTAssertTrue(tap(env, "Angehängt:", prefix: true))
        XCTAssertTrue(waitSheet(env, showing: "Dokument anhängen"), dump(env))
        XCTAssertTrue(shows(env, "Blatt01.pdf"))
        shoot(env, "iphone-ki-dokument-blatt")
        XCTAssertTrue(tap(env, "Blatt01.pdf", prefix: true))
        XCTAssertTrue(env.wait { !self.sheetOpen(env) && self.button(env, "Angehängt: Blatt01.pdf", prefix: true) != nil }, dump(env))
    }

    /// iPad quer unveraendert: Feld nicht unten fest, Wochentest als Dialog mittig (kein Blatt)
    func testPadKeepsCenteredComposerAndModal() throws {
        let env = try hostPad(start(try recents()), api: remote(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "Was möchtest du heute lernen?") }, dump(env))
        let input = frame(element(env, label: Self.placeholder))
        XCTAssertLessThan(input.maxY, Self.pad.height * 0.8, "Feld in der Mitte: \(input)")
        XCTAssertLessThan(input.width, 830, "Spalte hoechstens 820 pt")
        XCTAssertNil(element(env, id: "ai.start.bottom"))
        XCTAssertTrue(tap(env, "Wochentest", prefix: true))
        XCTAssertTrue(env.wait { self.shows(env, "Wochentest erstellen") }, dump(env))
        XCTAssertFalse(sheetOpen(env), "breit kein Blatt")
    }
}
