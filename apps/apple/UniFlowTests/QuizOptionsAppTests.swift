import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Wochentest mit Einstellungen (04.11.2026): Dialog mit Zahl, Schwierigkeit, Aufgabenarten und Thema; die Regel
/// "nur die Standardeinstellung ist ein gemeinsamer Test" (QuizSettings ueber WeekTestOptions des Kerns), die
/// Platzhalterkarte eines eigenen Tests ohne Suche, Wahr/Falsch- und Lueckentext-Karten im Testlauf, die Ergebnisseite
/// mit Erklaerung aus dem Test und lesbaren Formeln (FormulaText). Schein-Transport, kein Netz, keine KI.
@MainActor
final class QuizOptionsAppTests: XCTestCase {
    typealias Transport = AIViewsAppTests.Transport

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Reine Entscheidungen

    func testOnlyTheStandardSettingIsAShareableTest() {
        var s = QuizSettings()
        XCTAssertTrue(s.isStandard)
        XCTAssertEqual(s.shareBadge, "Gemeinsamer Test möglich")
        XCTAssertTrue(s.shareNote.contains("gemeinsamen Test"))
        XCTAssertEqual(s.composition, "15 Aufgaben · 4 leicht · 6 mittel · 5 schwer")
        s.count = 10
        XCTAssertFalse(s.isStandard, "andere Zahl: eigener Test")
        XCTAssertEqual(s.shareBadge, "Eigener Test, nicht geteilt")
        XCTAssertTrue(s.shareNote.hasPrefix("Eigener Test, nicht geteilt"))
        XCTAssertEqual(s.composition, "10 Aufgaben · 3 leicht · 4 mittel · 3 schwer")
        s = QuizSettings(); s.difficulty = "schwer"
        XCTAssertFalse(s.isStandard, "feste Stufe: eigener Test")
        XCTAssertEqual(s.composition, "15 Aufgaben · alle schwer")
        s = QuizSettings(); s.toggle("tf")
        XCTAssertFalse(s.isStandard, "eine Art weniger: eigener Test")
        XCTAssertEqual(s.types, ["mc", "cloze", "short", "calc"])
        s.toggle("tf")
        XCTAssertTrue(s.isStandard, "wieder alle Arten in der Reihenfolge des Backends")
        XCTAssertEqual(s.types, ["mc", "tf", "cloze", "short", "calc"])
        s = QuizSettings(); s.topic = "nur Kapitel 3"
        XCTAssertFalse(s.isStandard, "Thema: eigener Test")
        s.topic = "   "
        XCTAssertTrue(s.isStandard, "leeres Thema zaehlt nicht")
        // mindestens eine Art bleibt an
        s = QuizSettings()
        for t in ["mc", "tf", "cloze", "short", "calc"] { s.toggle(t) }
        XCTAssertEqual(s.types, ["calc"], "die letzte Art laesst sich nicht abwaehlen")
        // Rumpf fuer das Backend
        s = QuizSettings(); s.count = 5; s.difficulty = "leicht"; s.types = ["tf"]; s.topic = "  nur Kapitel 3 "
        XCTAssertEqual(s.body(module: 1, duration: 15, week: 0),
                       ["module_id": 1, "duration_min": 15, "count": 5, "difficulty": "leicht", "types": ["tf"], "topic": "nur Kapitel 3"])
        XCTAssertEqual(s.body(module: 1, duration: 15, week: 3)["week_no"], 3)
        XCTAssertEqual(s.options.topic, "nur Kapitel 3")
        s.topic = String(repeating: "x", count: 500)
        XCTAssertEqual(s.options.topic.count, WeekTestOptions.topicChars, "Thema begrenzt wie am PC")
    }

    func testGenerationStateOfAPrivateTestNeverPretendsToSearch() {
        let g = TestGenerationState()
        g.start(subject: "Testmathematik I", weekNo: 3, count: 10, shared: false)
        XCTAssertEqual(g.job?.phase, .generating, "eigener Test: keine Suche nach einem gemeinsamen Test")
        XCTAssertEqual(g.job?.count, 10)
        XCTAssertEqual(g.job?.phaseText, "Aufgaben werden erstellt … 0/10")
        XCTAssertTrue(g.job?.note.hasPrefix("Eigener Test, nicht geteilt.") ?? false)
        XCTAssertTrue(g.job?.note.contains("10 Aufgaben") ?? false)
        g.finish()
        g.start(subject: "Testmathematik I", weekNo: 3)
        XCTAssertEqual(g.job?.phase, .searching, "Standard: erst suchen")
        XCTAssertEqual(g.job?.count, 15)
        XCTAssertFalse(g.job?.note.contains("Eigener Test") ?? true)
        g.advance()
        XCTAssertEqual(g.job?.phaseText, "Aufgaben werden erstellt … 0/15")
        g.finish()
    }

    func testCardDecisionsForTrueFalseClozeAndExplanations() {
        XCTAssertEqual(ExamQuestionCard.kind("tf"), "Wahr / Falsch")
        XCTAssertEqual(ExamQuestionCard.kind("cloze"), "Lückentext")
        XCTAssertEqual(ExamQuestionCard.kind("mc"), "Multiple Choice")
        XCTAssertEqual(ExamQuestionCard.kind(nil), "Kurzantwort")
        XCTAssertEqual(ExamQuestionCard.choices(type: "tf", options: []), ["Wahr", "Falsch"], "Wahr/Falsch immer mit beiden Antworten")
        XCTAssertEqual(ExamQuestionCard.choices(type: "tf", options: ["Wahr", "Falsch"]), ["Wahr", "Falsch"])
        XCTAssertEqual(ExamQuestionCard.choices(type: "mc", options: ["A", "B", "C"]), ["A", "B", "C"])
        XCTAssertEqual(ExamQuestionCard.correctAnswer(["type": "cloze", "blank": "konvergent", "answer": "x"]), "konvergent")
        XCTAssertEqual(ExamQuestionCard.correctAnswer(["type": "cloze", "blank": " ", "answer": "x"]), "x")
        XCTAssertEqual(ExamQuestionCard.correctAnswer(["type": "short", "answer": "42"]), "42")
        let both = ExamQuestionCard.explanations(["explanation": "Weil."], feedback: ["feedback": "Fast richtig."])
        XCTAssertEqual(both.explanation, "Weil.")
        XCTAssertEqual(both.feedback, "Fast richtig.")
        let same = ExamQuestionCard.explanations(["explanation": "Weil."], feedback: ["feedback": "Weil."])
        XCTAssertNil(same.feedback, "gleicher Text nur einmal")
        let onlyGrader = ExamQuestionCard.explanations(["explanation": " "], feedback: ["feedback": "Nur Bewertung."])
        XCTAssertNil(onlyGrader.explanation)
        XCTAssertEqual(onlyGrader.feedback, "Nur Bewertung.")
        // Etikett: gemeinsam oder ehrlich "eigener Test"
        XCTAssertEqual(ExamsPage.shareLabel(["id": 1]), "Eigener Test, nicht geteilt")
        XCTAssertEqual(ExamsPage.shareLabel(["id": 1, "shared": .null]), "Eigener Test, nicht geteilt")
        XCTAssertEqual(ExamsPage.shareLabel(["shared": ["variant": 1, "of": 3, "adopted": false]]), "Gemeinsamer Test · Variante 1 von 3")
    }

    func testFormulasBecomeReadableText() {
        XCTAssertEqual(FormulaText.render("x^2 + y^2 = r^2"), "x² + y² = r²")
        XCTAssertEqual(FormulaText.render("a_n -> 0 fuer n -> unendlich"), "aₙ → 0 fuer n → unendlich")
        XCTAssertEqual(FormulaText.render("$\\frac{1}{2}$"), "½")
        XCTAssertEqual(FormulaText.render("\\frac{n+1}{n^2}"), "(n+1)/n²")
        XCTAssertEqual(FormulaText.render("\\sqrt{2} und sqrt(x+1)"), "√2 und √(x+1)")
        XCTAssertEqual(FormulaText.render("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}"), "∑ᵢ₌₁ⁿ i = n(n+1)/2", "Index mit = tiefgestellt (07.11.2026)")
        XCTAssertEqual(FormulaText.render("a_n^2 \\left( x \\right)"), "aₙ² ( x )")
        XCTAssertEqual(FormulaText.render("\\alpha \\le \\beta, x \\in \\mathbb{R}, \\pi \\cdot 2"), "α ≤ β, x ∈ ℝ, π · 2")
        XCTAssertEqual(FormulaText.render("\\leq ist nicht \\le q"), "≤ ist nicht ≤ q", "laengere Namen zuerst")
        XCTAssertEqual(FormulaText.render("(-1)^n konvergiert nicht"), "(-1)ⁿ konvergiert nicht")
        XCTAssertEqual(FormulaText.render("x^{10} und x^{-1}"), "x¹⁰ und x⁻¹")
        XCTAssertEqual(FormulaText.render("10^3 m"), "10³ m")
        XCTAssertEqual(FormulaText.render("is_int(list_items)"), "is_int(list_items)", "Bezeichner bleiben")
        XCTAssertEqual(FormulaText.render("2^k mit k = 3"), "2^k mit k = 3", "ohne Markierung lesbar; in der Ansicht echt hochgestellt (FormulaText.attributed)")
        XCTAssertEqual(FormulaText.render("Keine Formel hier."), "Keine Formel hier.")
        XCTAssertEqual(FormulaText.render("x^{a+b}"), "x^(a+b)", "nicht abbildbar bleibt lesbar")
        XCTAssertEqual(FormulaText.render("p \\lnot q, \\neg p"), "p ¬ q, ¬ p")
        XCTAssertEqual(FormulaText.render("\\text{für alle } n"), "für alle n")
    }

    // MARK: Ansichten

    private let modules: JSONValue = [["id": 1, "name": "Testmathematik I", "color": "#4f5bd5"]]
    private let moduleDetail: JSONValue = ["id": 1, "name": "Testmathematik I", "weeks": [
        ["week": 3, "label": "Lehrwoche 3", "topic": "Folgen", "count": 1,
         "vorlesungen": [["id": "f-1", "name": "VL03.pdf", "ai_title": "Folgen und Grenzwerte", "doc_type": "vorlesung"]],
         "uebungen": [], "loesungen": [], "skripte": [], "klausuren": [], "sonstiges": []],
    ]]

    private func transport() -> Transport {
        let t = Transport()
        t.answer("/api/modules", modules)
        t.answer("/api/modules/1", moduleDetail)
        t.answer("/api/tests", [])
        t.answer("/api/flashcards", [])
        t.answer("/api/bg", ["running": false, "task": .null, "message": ""])
        t.answer("/api/tests/generate", ["started": "Test"])
        return t
    }

    private func api(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }
    private func plan(_ p: UFPlan) -> Entitlements { Entitlements(observe: false, plan: p) }

    func testDialogTogglesMakeAPrivateTestAndSendTheOptions() throws {
        let t = transport()
        let generation = TestGenerationState()
        let env = try hostWithEnvironment(QuizComposer(moduleID: 1, entitlements: plan(.proAI), generation: generation).environment(\.ufAIEnabled, true),
                                          api: api(t), size: CGSize(width: 1180, height: 1400))
        env.pump(0.8)
        XCTAssertTrue(env.wait { self.shows(env.view, "VL03.pdf") || self.shows(env.view, "Folgen und Grenzwerte") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Gemeinsamer Test möglich"))
        XCTAssertTrue(shows(env.view, "Wahr / Falsch"))
        XCTAssertTrue(shows(env.view, "Thema oder Hinweise"))
        XCTAssertNotNil(button("10 Aufgaben", in: env.view))
        XCTAssertTrue(tap("10 Aufgaben", in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "Eigener Test, nicht geteilt") }, "andere Zahl: eigener Test, sofort sichtbar")
        XCTAssertTrue(shows(env.view, "10 Aufgaben · 3 leicht · 4 mittel · 3 schwer"))
        XCTAssertTrue(tap("Schwer", in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "10 Aufgaben · alle schwer") })
        XCTAssertTrue(tap("Wahr / Falsch", in: env.view))
        XCTAssertTrue(tap("Lückentext", in: env.view))
        env.pump(0.3)
        XCTAssertTrue(shows(env.view, "1 Anfrage über dein ChatGPT · eigener Test"), "Kostenzeile ohne 0-Credits-Versprechen")
        XCTAssertFalse(shows(env.view, "bei gemeinsamem Test 0 Credits"))
        XCTAssertTrue(tap("Test erstellen", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/tests/generate") == 1 })
        let body = try XCTUnwrap(t.bodies("/api/tests/generate").first)
        XCTAssertEqual(body["count"], 10)
        XCTAssertEqual(body["difficulty"], "schwer")
        XCTAssertEqual(body["types"], ["mc", "short", "calc"])
        XCTAssertEqual(body["topic"], "")
        XCTAssertEqual(body["module_id"], 1)
        XCTAssertEqual(body["week_no"], 3)
        XCTAssertTrue(env.wait { generation.job != nil || env.router.route == .exams })
        if let job = generation.job {
            XCTAssertEqual(job.shared, false, "eigener Test")
            XCTAssertEqual(job.count, 10)
            XCTAssertEqual(job.phase, .generating, "keine Suche vorgetaeuscht")
        }
        generation.finish()
    }

    // MARK: Ohne Unterlagen, Fehler des Auftrags (Befund HsH 07.11.2026: "Test erstellen haengt mal, macht mal nichts")

    func testJobFailureAndAIReasonAreReadable() {
        XCTAssertNil(QuizComposer.jobFailure(["running": false, "task": .null, "message": ""]))
        XCTAssertNil(QuizComposer.jobFailure(["running": true, "task": "Test", "message": ""]))
        XCTAssertNil(QuizComposer.jobFailure(["running": false, "message": "Test: fertig (17)"]))
        XCTAssertEqual(QuizComposer.jobFailure(["running": false, "message": .string("Test: FEHLER Leer: \(WeekTestOptions.noMaterialsHint)")]),
                       "Leer: \(WeekTestOptions.noMaterialsHint)")
        XCTAssertEqual(QuizComposer.jobFailure(["running": false, "message": "Test: FEHLER "]), "Der Test konnte nicht erstellt werden.")
        XCTAssertNil(QuizComposer.jobFailure(nil))
        XCTAssertTrue(QuizComposer.aiReason(access: .signInRequired, chatgpt: false).contains("StudiNow-Konto"))
        XCTAssertTrue(QuizComposer.aiReason(access: .planRequired, chatgpt: false).contains("Pro AI"))
        XCTAssertTrue(QuizComposer.aiReason(access: .unavailable, chatgpt: true).contains("keinen KI-Dienst"))
        XCTAssertFalse(QuizComposer.hasMaterials(nil))
        XCTAssertFalse(QuizComposer.hasMaterials(["id": 1, "weeks": [], "files": [["id": "f", "doc_type": "organisatorisch"]]]), "Organisatorisches zaehlt nicht")
        XCTAssertTrue(QuizComposer.hasMaterials(["id": 1, "weeks": [], "files": [["id": "f", "doc_type": .null]]]), "Datei ohne Einordnung zaehlt (neueste Unterlagen)")
        XCTAssertTrue(QuizComposer.hasMaterials(moduleDetail))
    }

    /// Modul ohne Unterlagen: Hinweis und "Jetzt abgleichen", "Test erstellen" bleibt aus, nichts geht ans Backend
    func testWithoutMaterialsShowsHintAndSyncAndNeverStarts() throws {
        let t = transport()
        t.answer("/api/modules/1", ["id": 1, "name": "Testmathematik I", "weeks": [], "files": []])
        let generation = TestGenerationState()
        let env = try hostWithEnvironment(QuizComposer(moduleID: 1, entitlements: plan(.proAI), generation: generation).environment(\.ufAIEnabled, true),
                                          api: api(t), size: CGSize(width: 1180, height: 1400))
        env.pump(0.8)
        XCTAssertTrue(env.wait { self.shows(env.view, "Für dieses Modul sind noch keine Unterlagen geladen") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "erst Dateien laden bzw. abgleichen"))
        XCTAssertNotNil(button("Jetzt abgleichen", in: env.view))
        let start = try XCTUnwrap(button("Test erstellen", in: env.view))
        XCTAssertTrue(start.accessibilityTraits.contains(.notEnabled), "ohne Unterlagen kein Start")
        _ = tap("Test erstellen", in: env.view)
        env.pump(0.5)
        XCTAssertEqual(t.count("POST", "/api/tests/generate"), 0)
        XCTAssertNil(generation.job)
        // "Jetzt abgleichen" ohne verbundene Hochschule: Hinweis und der Weg zu den Einstellungen
        XCTAssertTrue(tap("Jetzt abgleichen", in: env.view))
        XCTAssertTrue(env.wait { env.router.route == .settings(tab: "account") }, "\(env.router.route)")
    }

    /// Der Auftrag endet sofort mit einem Fehler (z. B. keine Unterlagen im Backend, KI nicht erreichbar): der Dialog
    /// bleibt offen, zeigt den Grund und "Erneut versuchen"; keine Platzhalterkarte, kein Wechsel der Seite
    func testImmediateJobFailureStaysOpenWithRetry() throws {
        let t = transport()
        t.answer("/api/bg", ["running": false, "task": .null, "message": .string("Test: FEHLER \(WeekTestOptions.aiTimeoutHint())")])
        let generation = TestGenerationState()
        let env = try hostWithEnvironment(QuizComposer(moduleID: 1, entitlements: plan(.proAI), generation: generation).environment(\.ufAIEnabled, true),
                                          api: api(t), size: CGSize(width: 1180, height: 1400))
        env.pump(0.8)
        XCTAssertTrue(env.wait { self.shows(env.view, "VL03.pdf") || self.shows(env.view, "Folgen und Grenzwerte") })
        XCTAssertTrue(tap("Test erstellen", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/tests/generate") == 1 })
        XCTAssertTrue(env.wait { self.shows(env.view, "Die KI hat nach 90 Sekunden nicht geantwortet") }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Erneut versuchen", in: env.view))
        XCTAssertNil(generation.job, "keine Platzhalterkarte fuer einen gescheiterten Auftrag")
        XCTAssertNotEqual(env.router.route, .exams)
        XCTAssertTrue(tap("Erneut versuchen", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/tests/generate") == 2 })
    }

    /// Ein spaeterer Fehler des Auftrags steht auf der Seite "Tests & Wiederholung" mit "Erneut versuchen"
    func testExamsPageShowsAFailedGenerationWithRetry() throws {
        let t = transport()
        t.answer("/api/flashcards?due=true", [])
        let generation = TestGenerationState()
        generation.start(subject: "Testmathematik I", weekNo: 3)
        generation.finish(message: WeekTestOptions.noMaterialsHint)
        let env = try hostWithEnvironment(ExamsPage(generation: generation, entitlements: plan(.proAI)).environment(\.ufAIEnabled, true),
                                          api: api(t), size: CGSize(width: 1180, height: 900))
        env.pump(0.8)
        XCTAssertTrue(env.wait { self.shows(env.view, "Wochentest nicht erstellt") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "noch keine Unterlagen geladen"))
        XCTAssertNotNil(button("Erneut versuchen", in: env.view))
        XCTAssertTrue(tap("Ausblenden", in: env.view))
        XCTAssertTrue(env.wait { !self.shows(env.view, "Wochentest nicht erstellt") })
        XCTAssertNil(generation.lastMessage)
    }

    private var openTest: JSONValue {
        ["id": 17, "subject": "Testmathematik I", "title": "Wochentest Testmathematik I – Folgen", "duration_min": 15, "started_at": .null, "submitted_at": .null,
         "answers": [:], "feedback": .null, "week_no": 3, "auto": 0,
         "questions": [["nr": 1, "type": "tf", "difficulty": "leicht", "question": "Jede konvergente Folge ist beschränkt.", "options": ["Wahr", "Falsch"], "points": 20],
                       ["nr": 2, "type": "cloze", "difficulty": "leicht", "question": "Eine Folge heißt ___, wenn sie einen Grenzwert hat.", "points": 20],
                       ["nr": 3, "type": "short", "difficulty": "mittel", "question": "Was ist der Grenzwert von 1/n^2?", "points": 20]]]
    }

    private var submittedTest: JSONValue {
        var t = openTest.object ?? [:]
        t["id"] = 18
        t["submitted_at"] = "2026-11-04T10:00:00"
        t["started_at"] = "2026-11-04T09:50:00"
        t["answers"] = ["1": "Falsch", "2": "konvergent", "3": "0"]
        t["feedback"] = ["total": 40, "max": 60, "summary": "Zwei von drei.", "weak_topics": [],
                         "per_question": [["nr": 1, "points": 0, "max": 20, "feedback": "Jede konvergente Folge ist beschränkt, das ist ein Satz."],
                                          ["nr": 2, "points": 20, "max": 20, "feedback": "Richtig."],
                                          ["nr": 3, "points": 20, "max": 20, "feedback": "Richtig, 1/n^2 geht gegen 0."]]]
        var qs = t["questions"]?.array ?? []
        qs[0] = Self.merged(qs[0], ["answer": "Wahr", "explanation": "Konvergente Folgen sind beschränkt (Satz aus der Vorlesung)."])
        qs[1] = Self.merged(qs[1], ["answer": "konvergent", "blank": "konvergent", "explanation": "Definition der Konvergenz."])
        qs[2] = Self.merged(qs[2], ["answer": "0", "explanation": "1/n^2 wird beliebig klein."])
        t["questions"] = .array(qs)
        return .object(t)
    }

    /// Objekt um Felder ergaenzt (Loesung und Erklaerung nach der Abgabe)
    private static func merged(_ v: JSONValue, _ extra: [String: JSONValue]) -> JSONValue {
        var o = v.object ?? [:]
        for (k, x) in extra { o[k] = x }
        return .object(o)
    }

    func testRunShowsTrueFalseAndClozeCardsWithProgress() throws {
        let t = transport()
        t.answer("/api/tests/17", openTest)
        let draftKey = "exam-draft:http://erfunden.test/:17"
        let draftStore = ActiveContainer.current?.defaults ?? .standard
        draftStore.removeObject(forKey: draftKey)
        addTeardownBlock { draftStore.removeObject(forKey: draftKey) }
        let env = try hostWithEnvironment(ExamRunPage(id: 17, task: nil), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Fortschritt 0 von 3 beantwortet") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "0 / 3"), "Fortschritt als x / n")
        XCTAssertTrue(shows(env.view, "Aufgabe 1 von 3 · Wahr / Falsch"))
        XCTAssertTrue(shows(env.view, "Aufgabe 2 von 3 · Lückentext"))
        XCTAssertTrue(shows(env.view, "Eigener Test, nicht geteilt"), "ohne shared ehrlich beschriftet")
        XCTAssertTrue(shows(env.view, "Grenzwert von 1/n²"), "Formel lesbar")
        XCTAssertNotNil(button("Wahr", in: env.view))
        XCTAssertNotNil(button("Falsch", in: env.view))
        XCTAssertTrue(tap("Falsch", in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "Fortschritt 1 von 3 beantwortet") })
        let selected = elements(in: env.view).first { $0.accessibilityLabel == "Falsch" && $0.accessibilityTraits.contains(.button) }
        XCTAssertEqual(selected?.accessibilityTraits.contains(.selected), true)
        XCTAssertTrue(shows(env.view, "Lücke zu Aufgabe 2"), "Lueckentext als Textfeld")
        XCTAssertEqual(draftStore.dictionary(forKey: draftKey) as? [String: String], ["1": "Falsch"])
    }

    func testResultShowsPercentOwnAnswersCorrectAnswerAndExplanation() throws {
        let t = transport()
        t.answer("/api/tests/18", submittedTest)
        let env = try hostWithEnvironment(ExamRunPage(id: 18, task: nil), api: api(t), size: CGSize(width: 1180, height: 1800))
        XCTAssertTrue(env.wait { self.shows(env.view, "67 %") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "40 / 60 Punkte"))
        XCTAssertTrue(shows(env.view, "2/3 richtig"))
        XCTAssertTrue(shows(env.view, "Deine Antwort: Falsch, falsch"), "eigene Antwort als falsch markiert")
        XCTAssertTrue(shows(env.view, "Deine Antwort: Wahr") == false || shows(env.view, "Wahr, richtig"), "richtige Option der Wahr/Falsch-Aufgabe")
        XCTAssertTrue(shows(env.view, "Konvergente Folgen sind beschränkt (Satz aus der Vorlesung)."), "Erklaerung aus dem Test")
        XCTAssertTrue(shows(env.view, "Jede konvergente Folge ist beschränkt, das ist ein Satz."), "Rueckmeldung der Bewertung dazu")
        XCTAssertTrue(shows(env.view, "Rückmeldung zur Antwort"))
        XCTAssertTrue(shows(env.view, "konvergent"), "Luecke als richtige Antwort")
        XCTAssertTrue(shows(env.view, "Definition der Konvergenz."))
        XCTAssertTrue(shows(env.view, "1/n² wird beliebig klein."), "Formel in der Erklaerung lesbar")
    }

    // MARK: Elemente (wie AIViewsAppTests)

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    private func texts(_ view: UIView) -> [String] {
        elements(in: view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ view: UIView, _ text: String) -> Bool { texts(view).contains { $0.contains(text) } }

    private func button(_ label: String, in view: UIView, exact: Bool = true) -> NSObject? {
        elements(in: view).first { e in
            guard e.accessibilityTraits.contains(.button), let l = e.accessibilityLabel else { return false }
            return exact ? l == label : l.hasPrefix(label)
        }
    }

    @discardableResult
    private func tap(_ label: String, in view: UIView, exact: Bool = true) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.contains(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }
}
