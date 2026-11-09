import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Tarif-Matrix auf dem iPad (docs/TARIF-MATRIX-2026-11-04.md): wirksamer Tarif aus Dienst, App Store, Probe auf dem
/// iPad und Startargument; was die Seiten "Karteikarten", "Karteikarten aus Dokument" und "Wochentest erstellen" je
/// Tarif zeigen oder sperren, lokal (ohne Dienst) und mit Dienst. Alles gegen einen Schein-Transport, kein StoreKit,
/// kein Netz. Die Tests pinnen den Stand des Codes; Abweichungen vom Auftrag des Inhabers (04.11.2026) stehen in der
/// Matrix-Doku unter "ansteht".
@MainActor
final class PlanMatrixAppTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

    /// Schein-Transport: feste Antworten je Pfad (ohne Abfrage), zaehlt die Anfragen
    final class Transport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var canned: [String: JSONValue] = [:]
        private var log: [(method: String, path: String)] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let answer: JSONValue? = lock.withLock {
                log.append((request.httpMethod ?? "GET", path))
                return canned[path]
            }
            let data = (answer ?? ["detail": .string("Testfehler 404")]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
        func count(_ method: String, _ path: String) -> Int { lock.withLock { log.filter { $0.method == method && $0.path == path }.count } }
    }

    private func transport() -> Transport {
        let t = Transport()
        t.answer("/api/modules", [["id": 1, "name": "Testmathematik I", "color": "#4f5bd5"]])
        t.answer("/api/library", ["files": [
            ["id": "f-1", "name": "VL01.pdf", "title": "VL01.pdf", "module_id": 1, "downloaded_at": "2026-10-20T10:00:00", "kind": "pdf",
             "page_count": 12, "chdate": 1_761_000_000, "doc_type": "vorlesung"],
        ], "modules": [], "folders": [], "trash": []])
        t.answer("/api/flashcards", [])
        t.answer("/api/flashcard-stacks", [])
        t.answer("/api/tests", [])
        t.answer("/api/bg", ["running": false, "task": .null, "message": ""])
        return t
    }

    /// Dienst bzw. eigener Server (kein lokales Backend): die Seiten pruefen dann keinen Tarif, der Dienst tut es
    private func remote(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }
    /// lokales Backend (ohne PC, ohne Dienst): der Tarif der App gilt
    private func local(_ t: Transport) -> APIClient { APIClient(base: APIClient.localBase, transport: t) }

    private func plan(_ p: UFPlan) -> Entitlements { Entitlements(observe: false, plan: p) }

    /// Probe auf dem iPad, laufend (Tag 0) oder vorbei (Tag 7)
    private func trial(active: Bool) -> Entitlements {
        let e = Entitlements(observe: false)
        e.useLocalTrial(startedAt: t0, now: active ? t0 : day(7))
        return e
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { env.labels().contains { $0.contains(text) } }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: - Wirksamer Tarif

    /// Vorrang Dienst > App Store > Probe auf dem iPad > Free (UFPlanPrecedence); die Probe hebt nur ohne Kauf an
    func testEffectivePlanFromServicePurchaseAndLocalTrial() {
        let running = UFLocalTrial.state(startedAt: t0, now: t0)
        let over = UFLocalTrial.state(startedAt: t0, now: day(7))
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: nil), .free)
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: running), .proAI, "Probe = alles wie Pro AI")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: over), .free, "danach Free")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .plus, localTrial: over), .plus)
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .plus, localTrial: running), .plus, "wer Plus kauft, hat Plus (auf dem iPad derselbe Umfang)")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .proAI, localTrial: nil), .proAI)
        XCTAssertEqual(UFPlanPrecedence.effective(service: .proAI, purchased: .free, localTrial: over), .proAI, "Probe des StudiNow-Kontos hat Vorrang")
        XCTAssertEqual(UFPlanPrecedence.effective(service: .free, purchased: .plus, localTrial: nil), .plus, "Dienst ohne Tarif aendert nichts")
    }

    /// `Entitlements`: Probe auf dem iPad schaltet Karteikarten frei, am Ende faellt der Tarif von selbst auf Free; die
    /// Beschriftung in den Einstellungen nennt die Probe nur ohne Kauf und ohne Dienst-Probe
    func testEntitlementsFollowTheLocalAndServiceTrial() {
        let e = Entitlements(observe: false)
        XCTAssertEqual(e.plan, .free)
        XCTAssertEqual(e.access(.flashcards), .locked(.plus))
        e.useLocalTrial(startedAt: t0, now: t0)
        XCTAssertEqual(e.plan, .proAI)
        XCTAssertTrue(e.allows(.flashcards))
        XCTAssertEqual(e.statusLabel, "Probe: noch 7 Tage alles frei")
        e.refreshLocalTrial(now: day(6.5))
        XCTAssertEqual(e.statusLabel, "Probe: noch 1 Tag alles frei")
        e.refreshLocalTrial(now: day(7))
        XCTAssertEqual(e.plan, .free, "Ende der Probe: Free, nichts wird geloescht")
        XCTAssertEqual(e.access(.flashcards), .locked(.plus))
        XCTAssertEqual(e.statusLabel, "StudiNow Free")
        XCTAssertEqual(e.localTrial?.isExpired, true)
        // Probe des StudiNow-Kontos (Dienst) zaehlt zusaetzlich und hat Vorrang in der Beschriftung
        e.useServiceTrial(.proAI)
        XCTAssertEqual(e.plan, .proAI)
        XCTAssertEqual(e.statusLabel, "StudiNow Pro AI")
        e.useServiceTrial(nil)
        XCTAssertEqual(e.plan, .free)
        // Abmeldung: Probe weg, Free
        e.useLocalTrial(startedAt: t0, now: t0)
        XCTAssertEqual(e.plan, .proAI)
        e.useLocalTrial(startedAt: nil)
        XCTAssertEqual(e.plan, .free)
        XCTAssertNil(e.localTrial)
        XCTAssertFalse(e.localTrialChoiceMade)
    }

    /// Startargument -UFPlan (nur Debug): fester Tarif, Proben zaehlen nicht (Simulator-Ablaeufe je Tarif)
    func testForcedPlanIgnoresTheTrials() async {
        let saved = UserDefaults.standard.object(forKey: "UFPlan")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "UFPlan") } else { UserDefaults.standard.removeObject(forKey: "UFPlan") } }
        let e = Entitlements(observe: false)
        for (arg, expected) in [("free", UFPlan.free), ("plus", .plus), ("pro_ai", .proAI)] {
            UserDefaults.standard.set(arg, forKey: "UFPlan")
            await e.refresh()
            XCTAssertEqual(e.plan, expected, arg)
            e.useLocalTrial(startedAt: t0, now: t0)
            XCTAssertEqual(e.plan, expected, "Probe auf dem iPad aendert den festen Tarif nicht: \(arg)")
            e.useServiceTrial(.proAI)
            XCTAssertEqual(e.plan, expected, "Probe des Dienstes auch nicht: \(arg)")
            e.useServiceTrial(nil)
            e.useLocalTrial(startedAt: nil)
            XCTAssertEqual(e.allows(.flashcards), expected >= .plus, arg)
        }
    }

    // MARK: - Funktionsmatrix

    /// Auf dem iPad haengen bei Karteikarten und Tests zwei Dinge am Tarif: eigene Karteikarten (Plus, Entscheidung
    /// 04.11.2026) und Wochentest erstellen (Pro AI seit 07.11.2026: braucht die StudiNow-KI, das eigene ChatGPT ist aus).
    /// Testlauf und Lernstand haben keine Funktion in der Matrix (kein Schloss); die KI-Hilfe und die KI-Karteikarten
    /// gibt `StudiNowAIAccess` frei und stehen mit den Wochentests und dem Notizen-Abgleich auf der Pro-AI-Karte.
    func testOwnFlashcardsArePlusAndWeeklyTestsProAIOnTheDevice() {
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .free), .locked(.plus))
        for p: UFPlan in [.plus, .proAI] {
            XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: p), .allowed, p.rawValue)
        }
        XCTAssertEqual(UFFeatureMatrix.access(.weeklyTests, plan: .free), .locked(.proAI))
        XCTAssertEqual(UFFeatureMatrix.access(.weeklyTests, plan: .plus), .locked(.proAI))
        XCTAssertEqual(UFFeatureMatrix.access(.weeklyTests, plan: .proAI), .allowed)
        for f: UFFeature in [.flashcards, .weeklyTests] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: UFLocalTrial.plan), .allowed, "Probe: \(f.rawValue) frei")
        }
        // Herabstufen: Karten bleiben lesbar (wie Notizen), Ueben und Bearbeiten ab Plus; Probe = alles
        XCTAssertEqual(UFFeatureMatrix.flashcards(plan: .free), UFFlashcardAccess(canView: true, canEdit: false))
        XCTAssertFalse(UFFeatureMatrix.flashcards(plan: .free).canPractise)
        for p: UFPlan in [.plus, .proAI, UFLocalTrial.plan] {
            XCTAssertEqual(UFFeatureMatrix.flashcards(plan: p), UFFlashcardAccess(canView: true, canEdit: true), p.rawValue)
        }
        XCTAssertEqual(trial(active: false).flashcards.canEdit, false, "nach der Probe: lesen")
        XCTAssertEqual(trial(active: true).flashcards.canEdit, true, "Probe: alles")
        XCTAssertEqual(UFFlashcardAccess.readOnlyHint, "Mit Plus übst und bearbeitest du deine Karten wieder.")
        XCTAssertEqual(UFFeature.allCases.map(\.rawValue),
                       ["studipSync", "readDocuments", "modulesTimetable", "studyCalendar", "studyPlanning", "timer", "viewNotes", "uniGrades",
                        "ownChatGPT", "pencilWriting", "communityRead", "shareSolutions", "splitView", "flashcards", "autoPlan",
                        "aiHelp", "aiFlashcards", "weeklyTests", "deviceSync", "uniflowEditor"],
                       "keine Funktion fuer Testlauf oder Lernstand: auf dem Geraet ohne Schloss")
        for e: UFEntitlement in [.canAccessSharedTests, .canGenerateStudoraAITests, .canUseAdvancedAnalytics, .canUseExtendedTestHistory,
                                 .canUsePreparedWeekSets] {
            XCTAssertEqual(e.onDevice, .needsService, e.rawValue)
            XCTAssertFalse(e.availableOnDevice, e.rawValue)
        }
        for e: UFEntitlement in [.canUseAIExplanations, .canUseAIGeneratedQuestions, .canUseAISummaries, .canSyncAnnotations] {
            XCTAssertTrue(e.availableOnDevice, e.rawValue)
        }
        // Tarifkarten: Plus mit eigenen Karteikarten, ohne Wochentests; Pro AI mit KI und Abgleich, nichts "in Vorbereitung"
        XCTAssertTrue(UFPlanCard.included(.plus).contains { $0.title == "Eigene Karteikarten mit Wiederholung" })
        XCTAssertFalse(UFPlanCard.included(.plus).contains { $0.title == "Wochentests erstellen" })
        XCTAssertEqual(UFPlanCard.included(.proAI).map(\.title),
                       ["KI-Hilfe zu deinen Unterlagen", "Karteikarten aus deinen Unterlagen", "Wochentests erstellen",
                        "Notizen auf allen deinen Geräten"])
        XCTAssertEqual(UFFeature.weeklyTests.detail, "Aus deinen Unterlagen, mit der StudiNow-KI")
        XCTAssertTrue(UFLockedCard.message(.weeklyTests, access: .locked(.proAI)).contains("Enthalten ab StudiNow Pro AI."))
        // Tarifwahl: Pro AI nur mit Produkt aus dem Store, sonst der Satz ohne Preis
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: []), [.free, .plus])
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: ["de.uniflow.plus.yearly", "de.uniflow.proai.yearly"]), [.free, .plus, .proAI])
    }

    /// Kostenzeile der KI-Aktionen: ueber das eigene ChatGPT fuer jeden Tarif gleich, Credits nur mit Pro AI, sonst der
    /// Weg zu den Einstellungen (keine Tarifsperre)
    func testAICostLinesPerPlan() {
        for p in UFPlan.allCases {
            XCTAssertEqual(AICost.line(chatgpt: true, plan: p, credits: 10), "1 Anfrage über dein ChatGPT", p.rawValue)
            XCTAssertEqual(AICost.line(chatgpt: true, plan: p, credits: 10, calls: 3), "3 Anfragen über dein ChatGPT", p.rawValue)
            XCTAssertEqual(AICost.line(chatgpt: true, plan: p, credits: 10, adopted: true), AICost.line(chatgpt: true, plan: .free, credits: 10, adopted: true), p.rawValue)
        }
        XCTAssertEqual(AICost.line(chatgpt: false, plan: .proAI, credits: 10), "≈ 10 Credits")
        for p: UFPlan in [.free, .plus] {
            XCTAssertEqual(AICost.line(chatgpt: false, plan: p, credits: 10), "Kommt mit StudiNow Pro AI oder deinem eigenen ChatGPT (Einstellungen → Erweitert)", p.rawValue)
        }
        XCTAssertEqual(AICost.status(chatgpt: false, model: nil, plan: .proAI, requestsThisMonth: 2), "2 Anfragen diesen Monat · StudiNow-KI (Pro AI)")
        XCTAssertTrue(AICost.status(chatgpt: false, model: nil, plan: .free, requestsThisMonth: 0).hasPrefix("KI kommt mit StudiNow Pro AI"))
    }

    // MARK: - Seiten

    /// Seite "Karteikarten" (Entscheidung 04.11.2026): lokal (ohne Dienst) liest Free seine Karten weiter (Lesemodus mit
    /// Hinweis), ohne Karten steht die Sperrkarte; nach der Probe derselbe Lesemodus; Plus und laufende Probe voll; mit
    /// Dienst sperrt die App nicht (der Dienst antwortet 403 "Karteikarten gibt es ab StudiNow Plus.")
    func testCardsPageIsReadOnlyForFreeWithoutService() throws {
        let locked = try hostWithEnvironment(CardsPage(entitlements: plan(.free)), api: local(transport()))
        XCTAssertTrue(locked.wait { self.shows(locked, "Mit StudiNow Plus freischalten") }, locked.labels().joined(separator: " | "))
        XCTAssertTrue(shows(locked, "Enthalten ab StudiNow Plus"))
        XCTAssertFalse(shows(locked, "Karte anlegen"))

        let tFree = withCards(transport())
        let afterTrial = try hostWithEnvironment(CardsPage(entitlements: trial(active: false)), api: local(tFree))
        XCTAssertTrue(afterTrial.wait { self.shows(afterTrial, "Mit Plus übst und bearbeitest du deine Karten wieder.") },
                      "Probe vorbei: Lesemodus: \(afterTrial.labels().joined(separator: " | "))")
        XCTAssertTrue(shows(afterTrial, "Stapel öffnen: Folgen"), "Karten bleiben sichtbar")
        XCTAssertGreaterThanOrEqual(tFree.count("GET", "/api/flashcards"), 1, "Lesen bleibt frei")
        XCTAssertFalse(shows(afterTrial, "Karte anlegen"))
        XCTAssertFalse(shows(afterTrial, "Neuer Stapel"))
        XCTAssertFalse(shows(afterTrial, "Stapel bearbeiten"))
        XCTAssertFalse(shows(afterTrial, "Aktionen für Stapel"), "Lesemodus: kein Menue (…) an den Kacheln")

        for (name, ent) in [("plus", plan(.plus)), ("probe", trial(active: true))] {
            let t = withCards(transport())
            let env = try hostWithEnvironment(CardsPage(entitlements: ent), api: local(t))
            XCTAssertTrue(env.wait { self.shows(env, "Karte anlegen") }, "\(name): \(env.labels().joined(separator: " | "))")
            XCTAssertTrue(shows(env, "Aktionen für Stapel: Folgen"), name)       // Bearbeiten, Teilen, Loeschen im Menue (…) der Kachel
            XCTAssertFalse(shows(env, "Mit Plus übst"), name)
            XCTAssertFalse(shows(env, "freischalten"), name)
        }

        let tRemote = transport()
        let remoteFree = try hostWithEnvironment(CardsPage(entitlements: plan(.free)), api: remote(tRemote))
        XCTAssertTrue(remoteFree.wait { tRemote.count("GET", "/api/flashcards") >= 1 }, "mit Dienst: kein Schloss der App, der Dienst entscheidet")
        XCTAssertFalse(shows(remoteFree, "freischalten"))
        XCTAssertTrue(remoteFree.wait { self.shows(remoteFree, "Tests") }, "Weg zurueck zu den Tests nur mit Dienst")
    }

    /// Entscheidung 05.11.2026: Community ab Plus (Free: Hinweis "Community ab Plus", keine Abfrage geteilter Stapel ohne
    /// Dienst), eigene Beitraege bleiben zurueckziehbar; eigenes ChatGPT in jedem Tarif (Verbindung noch aus)
    @MainActor
    func testCommunityIsPlusOnTheDevice() async throws {
        XCTAssertEqual(UFFeatureMatrix.access(.communityRead, plan: .free), .locked(.plus))
        XCTAssertFalse(trial(active: false).allows(.communityRead), "nach der Probe: Free ohne Community")
        XCTAssertTrue(trial(active: true).allows(.communityRead), "Probe wie Pro AI")
        XCTAssertTrue(plan(.plus).allows(.communityRead))
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.from, .free)
        XCTAssertTrue(UFLockedCard.message(.communityRead, access: .locked(.plus)).hasPrefix("Community ab StudiNow Plus:"))
        XCTAssertTrue(CommunityPage.ownPostsHint.contains("zurückziehen"))

        for (p, calls) in [(UFPlan.free, 0), (.plus, 1)] {
            let t = transport()
            t.answer("/api/library", ["files": [], "modules": [["id": 1, "name": "Testmathematik I"]], "folders": [], "trash": []])
            t.answer("/api/community/card-stacks", ["stacks": [], "weeks": [:]])
            let deck = FlashcardDeck(api: local(t))
            deck.entitlements = plan(p)
            try await deck.load()
            await deck.loadShared()
            XCTAssertEqual(t.count("GET", "/api/community/card-stacks"), calls, p.rawValue)
        }
    }

    /// ein Stapel "Folgen" mit einer Karte (wie nach der Probe gespeichert)
    private func withCards(_ t: Transport) -> Transport {
        t.answer("/api/flashcard-stacks", [["id": 1, "name": "Folgen", "subject": .null, "file_id": .null, "kind": "eigene", "week": .null,
                                            "cards": 1, "due": 1, "created_at": "2026-11-01T10:00:00", "last_practised": .null]])
        t.answer("/api/flashcards", [["id": 7, "question": "Was ist eine Folge?", "answer": "Abbildung N -> R", "box": 1, "due": "2026-11-01",
                                      "stack_id": 1, "stack_name": "Folgen", "subject": .null, "file_id": .null]])
        return t
    }

    /// Seite "Tests" ohne Dienst: "Fehlende Wochentests" (Woche erzeugen) ab Pro AI mit Schloss, ohne Tests die Sperrkarte
    /// fuer Wochentests; vorhandene Tests bleiben in Free sichtbar und lassen sich oeffnen. Automatische Wochentests
    /// haengen am selben Recht (UFWeeklyAutoGate, WeeklyAppTests).
    func testExamsPageLocksWeekGenerationForFree() throws {
        for (name, ent) in [("free", plan(.free)), ("nach der Probe", trial(active: false)), ("plus", plan(.plus))] {
            let empty = try hostWithEnvironment(ExamsPage(generation: TestGenerationState(), entitlements: ent), api: local(transport()))
            XCTAssertTrue(empty.wait { self.shows(empty, "Mit StudiNow Pro AI freischalten") }, "\(name): \(empty.labels().joined(separator: " | "))")
            XCTAssertTrue(shows(empty, "Wochentests erstellen"), name)
            XCTAssertFalse(shows(empty, "Sie entstehen automatisch"), name)
        }
        let t = transport()
        t.answer("/api/tests", [["id": 5, "title": "Wochentest Testmathematik I – Folgen", "subject": "Testmathematik I", "module_id": 1,
                                 "week_no": 3, "week_start": "2026-11-02", "created_at": "2026-11-03T10:00:00", "submitted_at": .null,
                                 "duration_min": 30, "questions": 5]])
        let free = try hostWithEnvironment(ExamsPage(generation: TestGenerationState(), entitlements: plan(.free)), api: local(t))
        XCTAssertTrue(free.wait { self.shows(free, "Folgen") }, "vorhandener Test bleibt: \(free.labels().joined(separator: " | "))")
        XCTAssertTrue(shows(free, "Fehlende Wochentests"), "Knopf bleibt sichtbar (mit Schloss, ufRequires)")
        XCTAssertFalse(shows(free, "Mit StudiNow Pro AI freischalten"), "mit Tests keine grosse Sperrkarte")
        XCTAssertEqual(t.count("POST", "/api/tests/generate-week"), 0)

        let pro = try hostWithEnvironment(ExamsPage(generation: TestGenerationState(), entitlements: plan(.proAI)), api: local(transport()))
        XCTAssertTrue(pro.wait { self.shows(pro, "Sie entstehen automatisch") }, pro.labels().joined(separator: " | "))
        XCTAssertFalse(shows(pro, "freischalten"))
    }

    /// "Karteikarten aus Dokument" (KI ueber das eigene ChatGPT) haengt lokal an Plus, nicht an Pro AI: Free sieht die
    /// Sperrkarte, Plus und Probe den Dialog; mit Dienst sperrt die App nicht
    func testFlashcardComposerNeedsPlusLocallyNotProAI() throws {
        let free = try hostWithEnvironment(FlashcardComposer(moduleID: 1, fileID: "f-1", entitlements: plan(.free)).environment(\.ufAIEnabled, true),
                                           api: local(transport()))
        XCTAssertTrue(free.wait { self.shows(free, "Enthalten ab StudiNow Plus") }, free.labels().joined(separator: " | "))
        XCTAssertFalse(shows(free, "Karten erstellen"))

        for (name, ent) in [("plus", plan(.plus)), ("probe", trial(active: true)), ("pro_ai", plan(.proAI))] {
            let env = try hostWithEnvironment(FlashcardComposer(moduleID: 1, fileID: "f-1", entitlements: ent).environment(\.ufAIEnabled, true),
                                              api: local(transport()))
            XCTAssertTrue(env.wait { self.shows(env, "Karten erstellen") }, "\(name): \(env.labels().joined(separator: " | "))")
            XCTAssertFalse(shows(env, "freischalten"), name)
        }

        let remoteFree = try hostWithEnvironment(FlashcardComposer(moduleID: 1, fileID: "f-1", entitlements: plan(.free)).environment(\.ufAIEnabled, true),
                                                 api: remote(transport()))
        XCTAssertTrue(remoteFree.wait { self.shows(remoteFree, "Karten erstellen") }, "mit Dienst entscheidet der Dienst (403 plan_required)")

        // ohne ChatGPT (und ohne Pro-AI-Dienst) zeigt Plus den Weg zur Verbindung, keine Tarifsperre
        let noAI = try hostWithEnvironment(FlashcardComposer(moduleID: 1, fileID: "f-1", entitlements: plan(.plus)), api: local(transport()))
        XCTAssertTrue(noAI.wait { self.shows(noAI, "Die KI-Hilfe kommt mit der StudiNow-KI") })
        XCTAssertFalse(shows(noAI, "freischalten"))
    }

    /// Dialog "Wochentest erstellen" (07.11.2026, vorher Plus): ohne PC braucht er die StudiNow-KI und gehoert zu Pro AI.
    /// Free (auch nach der Probe) und Plus sehen die Sperrkarte mit dem Weg zu Pro AI, keinen Knopf und laden nichts;
    /// Pro AI und die laufende Probe sehen den Dialog; mit Dienst entscheidet der Dienst.
    func testWeeklyTestDialogIsProAILocally() throws {
        for (name, ent) in [("free", plan(.free)), ("nach der Probe", trial(active: false)), ("plus", plan(.plus))] {
            let t = transport()
            let env = try hostWithEnvironment(QuizComposer(moduleID: 1, entitlements: ent, generation: TestGenerationState()).environment(\.ufAIEnabled, true),
                                              api: local(t))
            XCTAssertTrue(env.wait { self.shows(env, "Mit StudiNow Pro AI freischalten") }, "\(name): \(env.labels().joined(separator: " | "))")
            XCTAssertTrue(shows(env, "Wochentests erstellen"), name)
            XCTAssertTrue(shows(env, "Enthalten ab StudiNow Pro AI"), name)
            XCTAssertFalse(env.labels().contains("Test erstellen"), "kein Start-Knopf: \(name)")
            XCTAssertEqual(t.count("GET", "/api/modules"), 0, "gesperrt laedt nichts: \(name)")
        }
        for (name, ent) in [("probe", trial(active: true)), ("pro_ai", plan(.proAI))] {
            let env = try hostWithEnvironment(QuizComposer(moduleID: 1, entitlements: ent, generation: TestGenerationState()).environment(\.ufAIEnabled, true),
                                              api: local(transport()))
            XCTAssertTrue(env.wait { self.shows(env, "Test erstellen") }, "\(name): \(env.labels().joined(separator: " | "))")
            XCTAssertFalse(shows(env, "freischalten"), name)
            XCTAssertFalse(shows(env, "Enthalten ab"), name)
        }
        let remoteFree = try hostWithEnvironment(QuizComposer(moduleID: 1, entitlements: plan(.free), generation: TestGenerationState()).environment(\.ufAIEnabled, true),
                                                 api: remote(transport()))
        XCTAssertTrue(remoteFree.wait { self.shows(remoteFree, "Test erstellen") }, "mit Dienst entscheidet der Dienst")
        XCTAssertFalse(shows(remoteFree, "freischalten"))
        // Pro AI ohne verbundene KI: der Weg dorthin, keine Tarifsperre
        let noAI = try hostWithEnvironment(QuizComposer(moduleID: 1, entitlements: plan(.proAI), generation: TestGenerationState()), api: local(transport()))
        XCTAssertTrue(noAI.wait { self.shows(noAI, "Die KI-Hilfe kommt mit der StudiNow-KI") }, noAI.labels().joined(separator: " | "))
        XCTAssertFalse(shows(noAI, "freischalten"))
    }

    // MARK: - Probe-Karte und Tarifseite

    func testTrialBannerAndPlanPageTexts() {
        let running = UFLocalTrial.state(startedAt: t0, now: t0)
        let over = UFLocalTrial.state(startedAt: t0, now: day(7))
        XCTAssertEqual(UFTrialBannerContent.make(service: nil, local: running, purchased: .free, choiceMade: false), .running(daysLeft: 7, source: .device))
        XCTAssertEqual(UFTrialBannerContent.make(service: nil, local: over, purchased: .free, choiceMade: false), .over(source: .device))
        XCTAssertNil(UFTrialBannerContent.make(service: nil, local: over, purchased: .free, choiceMade: true), "\"Bei Free bleiben\" beantwortet")
        XCTAssertNil(UFTrialBannerContent.make(service: nil, local: running, purchased: .plus, choiceMade: false), "mit Kauf keine Probe-Karte")
        XCTAssertEqual(UFTrialBannerContent.make(service: StudoraAccount.PlanStatus(plan: "pro_ai", trialActive: true, trialDaysLeft: 3, trialPlan: "pro_ai"),
                                                 local: over, purchased: .free, choiceMade: false), .running(daysLeft: 3, source: .service))
        XCTAssertEqual(UFTrialBannerContent.make(service: StudoraAccount.PlanStatus(plan: "free", needsPlanChoice: true),
                                                 local: running, purchased: .free, choiceMade: false), .over(source: .service), "Dienst vor iPad")
        XCTAssertEqual(UFTrialBannerContent.running(daysLeft: 7, source: .device).title, "Probe: noch 7 Tage alles frei")
        XCTAssertEqual(UFTrialBannerContent.over(source: .device).title, "Deine Probe ist vorbei")
        XCTAssertTrue(UFTrialBannerContent.over(source: .device).text.contains("Deine Notizen bleiben in jedem Fall erhalten und lesbar."))
        let status = PlanPickerView.trialStatus(running, proAI: false)
        XCTAssertTrue(status.title.hasPrefix("Probe aktiv: alle Funktionen bis "), status.title)
        XCTAssertTrue(status.title.hasSuffix("(noch 7 Tage)"), status.title)
        XCTAssertFalse(PlanPickerView.subtitle(proAI: false).contains("Pro AI"), "ohne Produkt aus dem Store kein Pro AI im Text")
        XCTAssertTrue(PlanPickerView.subtitle(proAI: true).contains("StudiNow Pro AI die KI von StudiNow über den StudiNow-Dienst"))
    }
}
