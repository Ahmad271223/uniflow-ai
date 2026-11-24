import UniFlowCore
import XCTest
@testable import UniFlow

/// Gekaufte Probeklausuren von selbst abholen (`ExamShopInbox`, 22.11.2026): Hinweis, Abstand zwischen zwei Abfragen,
/// Nachsehen, solange der Dienst noch erstellt. Das Ablegen selbst prueft der Kern (`ExamGeneratorShopTests`).
@MainActor
final class ExamShopInboxAppTests: XCTestCase {
    // In 1.0.7 aus (Entscheidung des Inhabers 24.11.2026); die Tests pruefen die Funktion weiter mit Schalter an
    override func setUp() { super.setUp(); ExamGenerator.isEnabled = true }
    override func tearDown() { ExamGenerator.isEnabled = false; super.tearDown() }

    private typealias Added = ExamShopInbox.Added
    private typealias Outcome = ExamShopInbox.Outcome

    private func inbox(_ answers: [Outcome?], allowed: Bool = true) -> (ExamShopInbox, () -> Int) {
        let box = ExamShopInbox()
        var left = answers, calls = 0
        box.collectOverride = {
            calls += 1
            return left.isEmpty ? Outcome() : left.removeFirst()
        }
        box.allowed = { allowed }
        box.pause = { _ in await Task.yield() }
        return (box, { calls })
    }

    func testNoticeNamesExamModuleAndFolder() {
        let one = [Added(variant: 1, module: "Grundlagen digitaler Systeme"), Added(variant: 1, module: "Grundlagen digitaler Systeme")]
        XCTAssertEqual(ExamShopInbox.notice(one),
                       "Probeklausur 1 ist da: Bibliothek, Modul „Grundlagen digitaler Systeme“, Ordner „Probeklausuren“.",
                       "Aufgaben und Lösungen sind eine Probeklausur")
        let three = one + [Added(variant: 2, module: "Grundlagen digitaler Systeme"), Added(variant: 3, module: "Grundlagen digitaler Systeme")]
        XCTAssertEqual(ExamShopInbox.notice(three), "3 Probeklausuren sind da: Bibliothek, Modul „Grundlagen digitaler Systeme“, Ordner „Probeklausuren“.")
        let mixed = [Added(variant: 1, module: "Analysis"), Added(variant: 1, module: "Physik")]
        XCTAssertEqual(ExamShopInbox.notice(mixed), "2 Probeklausuren sind da: Bibliothek, Ordner „Probeklausuren“ im jeweiligen Modul.")
        XCTAssertNil(ExamShopInbox.notice([]), "nichts Neues, kein Hinweis")
    }

    func testOutcomeReadsTheAnswerOfTheDevice() {
        let v: JSONValue = ["added": [["variant": 2, "module": "Analysis", "which": "aufgaben"]], "pending": 1, "unplaced": 0]
        XCTAssertEqual(Outcome(v), Outcome(added: [Added(variant: 2, module: "Analysis")], pending: 1))
    }

    func testAsksAtMostOncePerMinuteUnlessForced() async {
        let (box, calls) = inbox([])
        var clock = Date(timeIntervalSince1970: 1_000_000)
        box.now = { clock }
        _ = await box.refresh()
        _ = await box.refresh()
        XCTAssertEqual(calls(), 1, "Vordergrund kurz hintereinander: eine Abfrage")
        clock += ExamShopInbox.minInterval + 1
        _ = await box.refresh()
        XCTAssertEqual(calls(), 2)
        _ = await box.refresh(force: true)
        XCTAssertEqual(calls(), 3)
    }

    func testWithoutProAINothingIsAsked() async {
        let (box, calls) = inbox([], allowed: false)
        let out = await box.refresh(force: true)
        XCTAssertNil(out)
        XCTAssertEqual(calls(), 0)
    }

    func testPlanLoadedLaterStillAsksRightAway() async {
        // am iPad 22.11.2026: beim Start noch „free“, Sekunden spaeter Pro AI – das zweite Nachfragen darf nicht warten
        let (box, calls) = inbox([])
        var proAI = false
        box.allowed = { proAI }
        _ = await box.refresh()
        XCTAssertEqual(calls(), 0)
        proAI = true
        _ = await box.refresh()
        XCTAssertEqual(calls(), 1, "der ausgefallene Versuch zaehlt nicht fuer die Minute Abstand")
    }

    func testKeepsLookingWhileTheServiceIsStillCreating() async {
        // 1. Abfrage: Dienst erstellt noch; 2.: kein Netz; 3.: fertig und abgelegt
        let done = Outcome(added: [Added(variant: 1, module: "Analysis")], pending: 0)
        let (box, calls) = inbox([Outcome(pending: 1), nil, done])
        let toast = UFToastCenter()
        let router = UFRouter()
        box.attach(router: router, toast: toast, api: nil)
        for _ in 0..<200 where box.watching != nil || calls() < 3 { await Task.yield() }
        XCTAssertEqual(calls(), 3, "nach „fertig“ fragt nichts mehr")
        XCTAssertNil(box.watching)
        XCTAssertEqual(toast.message, "Probeklausur 1 ist da: Bibliothek, Modul „Analysis“, Ordner „Probeklausuren“.")
        XCTAssertEqual(router.reloadToken, 1, "die Seiten laden neu, der Ordner ist sofort da")
    }
}
