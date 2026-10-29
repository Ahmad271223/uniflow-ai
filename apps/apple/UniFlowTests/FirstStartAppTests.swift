import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Erster Start nach der Hochschulwahl (docs/OFFEN-V1.md, Punkt 2): Anmeldeseiten der Hochschule, "Später anmelden",
/// Erstabgleich mit Fortschritt, gefuellter Startbildschirm. Ohne Netz: Stud.IP, QIS, Learnweb und LSF antworten aus
/// dem Debug-Stub-Ordner (apps/apple/DebugStub/erststart, erfundene Daten), derselbe, den der Simulator mit
/// `-UFOnboarding login -UFLoginStub <ordner>` nutzt.
@MainActor
final class FirstStartAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    /// Montag, 26.10.2026, 10:00 in Berlin
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "erststart", clock: clock)
    }

    override func tearDown() async throws {
        await bed.tearDown()
        try await super.tearDown()
    }

    private var stub: DebugStubTransport { DebugStubTransport(directory: ContainerTestBed.stubDirectory) }

    // MARK: Ablauf und Regeln (reine Funktionen)

    func testStepsPerUniversityAndSkipRules() {
        XCTAssertEqual(FirstLoginStep.steps(for: .luh), [.studip, .qis], "LUH: Stud.IP, danach QIS")
        XCTAssertEqual(FirstLoginStep.steps(for: .hildesheim), [.learnweb, .lsf], "Hildesheim: CAS fuer Learnweb, danach LSF")
        for s in FirstLoginStep.allCases {
            XCTAssertFalse(s.title.isEmpty)
            XCTAssertFalse(s.intro.contains("später"), "keine Vertroestung auf der Anmeldeseite: \(s.intro)")
        }
        XCTAssertTrue(FirstLoginPage.laterHint.contains("Karte zum Verbinden"))
    }

    func testSyncRowsFollowTheStudIPPhaseAndQIS() {
        // Stud.IP nie angemeldet, QIS nicht verbunden: alles uebersprungen, fertig
        let skipped = FirstSyncProgress.luh(phase: .signedOut, hasSession: false, summary: nil, qis: .notConnected, qisMessage: nil)
        XCTAssertEqual(skipped.map(\.state), [.skipped, .skipped, .skipped, .skipped])
        XCTAssertEqual(skipped.map(\.id), ["files", "timetable", "recordings", "grades"])
        XCTAssertTrue(FirstSyncProgress.isFinished(skipped))
        XCTAssertEqual(FirstSyncProgress.title(finished: true, anyLoaded: false), "Fertig")
        // Dateien laufen: Stundenplan und Aufzeichnungen warten, QIS laeuft
        let files = FirstSyncProgress.luh(phase: .running("Lade 2 von 5: Blatt.pdf"), hasSession: true, summary: nil, qis: .running, qisMessage: nil)
        XCTAssertEqual(files.map(\.state), [.running, .waiting, .waiting, .running])
        XCTAssertEqual(files[0].detail, "Lade 2 von 5: Blatt.pdf")
        XCTAssertFalse(FirstSyncProgress.isFinished(files))
        XCTAssertEqual(FirstSyncProgress.title(finished: false, anyLoaded: false), "Dein Studium wird geladen …")
        // Stundenplan laeuft: Dateien fertig
        let tt = FirstSyncProgress.luh(phase: .running("Stundenplan wird geladen …"), hasSession: true, summary: nil, qis: .ok(clock.now), qisMessage: "3 Leistungen")
        XCTAssertEqual(tt.map(\.state), [.done, .running, .waiting, .done])
        XCTAssertEqual(tt[3].detail, "3 Leistungen")
        // Aufzeichnungen laufen
        let rec = FirstSyncProgress.luh(phase: .running("Aufzeichnungen werden geprüft …"), hasSession: true, summary: nil, qis: nil, qisMessage: nil)
        XCTAssertEqual(rec.map(\.state), [.done, .done, .running, .skipped])
        // fertig mit Zusammenfassung
        let done = FirstSyncProgress.luh(phase: .idle, hasSession: true, summary: "5 neu/geändert", qis: .ok(clock.now), qisMessage: "0 Leistungen")
        XCTAssertEqual(done.map(\.state), [.done, .done, .done, .done])
        XCTAssertEqual(done[0].detail, "5 neu/geändert")
        XCTAssertTrue(FirstSyncProgress.isFinished(done))
        XCTAssertEqual(FirstSyncProgress.title(finished: true, anyLoaded: true), "Alles da – los geht’s")
        // Sitzung abgelaufen, Fehler, QIS-Anmeldung noetig: fertig, aber mit Hinweis
        let expired = FirstSyncProgress.luh(phase: .needsLogin, hasSession: true, summary: nil, qis: .needsLogin, qisMessage: "Anmeldung bei QIS abgelaufen. Bitte neu anmelden.")
        XCTAssertEqual(expired.map(\.state), [.needsLogin, .needsLogin, .needsLogin, .needsLogin])
        XCTAssertTrue(FirstSyncProgress.isFinished(expired))
        let failed = FirstSyncProgress.luh(phase: .failed("Keine Internetverbindung"), hasSession: true, summary: nil, qis: .failed("x"), qisMessage: nil)
        XCTAssertEqual(failed.map(\.state), [.failed, .failed, .failed, .failed])
        XCTAssertEqual(failed[0].detail, "Keine Internetverbindung")
        XCTAssertEqual(failed[3].detail, "x")
    }

    func testSyncRowsForHildesheim() {
        let waiting = FirstSyncProgress.hildesheim(learnweb: .connected, lsf: .notConnected, messages: [])
        XCTAssertEqual(waiting.map(\.state), [.waiting, .skipped, .skipped])
        XCTAssertEqual(waiting[1].detail, "LSF später anmelden")
        XCTAssertFalse(FirstSyncProgress.isFinished(waiting))
        let running = FirstSyncProgress.hildesheim(learnweb: .running, lsf: .running, messages: [])
        XCTAssertEqual(running.map(\.state), [.running, .running, .running])
        let done = FirstSyncProgress.hildesheim(learnweb: .ok(clock.now), lsf: .ok(clock.now),
                                                messages: ["2 neue/geänderte Dateien aus 1 Learnweb-Kursen", "Stundenplan: 1 neu, 0 unverändert, 0 entfernt", "Notenspiegel: 2 Leistungen"])
        XCTAssertEqual(done.map(\.state), [.done, .done, .done])
        XCTAssertEqual(done.map { $0.detail ?? "" }, ["2 neue/geänderte Dateien aus 1 Learnweb-Kursen", "Stundenplan: 1 neu, 0 unverändert, 0 entfernt", "Notenspiegel: 2 Leistungen"])
        XCTAssertTrue(FirstSyncProgress.isFinished(done))
        let login = FirstSyncProgress.hildesheim(learnweb: .needsLogin, lsf: .failed("LSF kaputt"), messages: ["LSF-Stundenplan: HTTP 500"])
        XCTAssertEqual(login.map(\.state), [.needsLogin, .failed, .failed])
        XCTAssertEqual(login[1].detail, "LSF-Stundenplan: HTTP 500")
        XCTAssertEqual(login[2].detail, "LSF kaputt")
        for s in [FirstSyncRow.State.waiting, .running, .done, .skipped, .needsLogin, .failed] {
            XCTAssertFalse(FirstSyncPage.label(s).isEmpty)
        }
    }

    // MARK: Debug-Stub (derselbe Ordner wie im Simulator)

    func testStubFolderAnswersBothUniversities() async throws {
        let t = stub
        let me = try await t.get(StudIPSync.base.appendingPathComponent("jsonapi.php/v1/users/me"), accept: nil)
        XCTAssertEqual(me.status, 200)
        XCTAssertTrue(String(decoding: me.body, as: UTF8.self).contains("u-demo"))
        let missing = try await t.get(StudIPSync.base.appendingPathComponent("jsonapi.php/v1/unbekannt"), accept: nil)
        XCTAssertEqual(missing.status, 404)
        // Learnweb-REST unterscheidet sich nur im Koerper
        let rest = URL(string: "https://www.uni-hildesheim.de/learnweb2026/webservice/rest/server.php")!
        let courses = try await t.send(UniRequest(url: rest, method: "POST", body: Data("wsfunction=core_enrol_get_users_courses&wstoken=x".utf8)))
        XCTAssertTrue(courses.text.contains("Bildungssoziologie"))
        let site = try await t.send(UniRequest(url: rest, method: "POST", body: Data("wsfunction=core_webservice_get_site_info".utf8)))
        XCTAssertTrue(site.text.contains("userid"))
        // QIS-Seiten fuehren bis zu den Leistungen (QISClient wie in der App)
        let r = try await QISClient(transport: t, retry: .none).fetch()
        XCTAssertEqual(r.grades.count, 3)
        XCTAssertFalse(r.grades.contains { $0.raw.contains("Beispiel") }, "Stammdaten der Nachbildung nie in den Leistungen")
        // ohne Startargument -UFLoginStub (so laufen die Tests) bleibt alles echt: keine Nachbildung, nichts "angemeldet"
        XCTAssertFalse(DebugUniStub.isActive)
        let real = URL(string: "https://example.invalid/x")!
        for s in ["studip", "qis", "learnweb", "lsf"] {
            XCTAssertEqual(DebugUniStub.loginPage(s, real: real), real)
            XCTAssertFalse(DebugUniStub.isSignedIn(ContainerTestBed.stubDirectory.appendingPathComponent("\(s)-angemeldet.html"), service: s))
            XCTAssertTrue(FileManager.default.fileExists(atPath: ContainerTestBed.stubDirectory.appendingPathComponent("\(s).html").path), s)
        }
        XCTAssertNil(DebugUniStub.transportFactory)
        XCTAssertNil(DebugUniStub.studipTransport())
        XCTAssertTrue(DebugUniStub.studipCookies().isEmpty)
    }

    // MARK: LUH: Anmeldeseiten -> Erstabgleich -> gefuellter Startbildschirm

    func testLUHFirstStartSyncFillsTheDashboardAndQISGrades() async throws {
        let m = bed.manager()
        let a = bed.account(.luh)
        XCTAssertEqual(a.stage, .universityLogin, "nach der Hochschulwahl sofort die Anmeldeseiten")
        let c = try bed.open(m, a)
        let qis = try XCTUnwrap(m.qis)
        qis.syncsAfterSignIn = false
        XCTAssertFalse(FirstLoginFlow.anyConnected(studip: m.studip, qis: qis, hildesheim: nil), "nichts verbunden: Später fuehrt direkt zur Uebersicht")
        XCTAssertFalse(FirstLoginFlow.isConnected(.studip, studip: m.studip, qis: qis, hildesheim: nil))
        XCTAssertFalse(FirstLoginFlow.isConnected(.qis, studip: m.studip, qis: qis, hildesheim: nil))

        // Schritt 1: Stud.IP angemeldet (die Anmeldeansicht uebergibt die Cookies); der Abgleich laeuft mit dem Stub
        m.studip.signedIn(cookies: [bed.cookie("Seminar_Session", "s1", domain: StudIPSync.base.host!)])
        XCTAssertTrue(m.studip.hasStoredSession)
        XCTAssertTrue(FirstLoginFlow.isConnected(.studip, studip: m.studip, qis: qis, hildesheim: nil), "verbundener Schritt wird uebersprungen")
        XCTAssertTrue(FirstLoginFlow.anyConnected(studip: m.studip, qis: qis, hildesheim: nil))
        await m.studip.run(client: StudIPClient(base: StudIPSync.base, transport: stub, pauseMillis: 0))
        XCTAssertEqual(m.studip.phase, .idle, m.studip.lastSummary ?? "")
        var rows = FirstSyncProgress.luh(phase: m.studip.phase, hasSession: true, summary: m.studip.lastSummary, qis: qis.state, qisMessage: qis.lastMessage)
        XCTAssertEqual(rows.map(\.state), [.done, .done, .done, .skipped], "\(rows)")
        XCTAssertTrue(rows[0].detail?.hasPrefix("5 neu/geändert") ?? false, rows[0].detail ?? "")

        // Startbildschirm: Dateien, Stundenplan, Module
        let dash = try await c.api.value("/api/dashboard")
        XCTAssertEqual(dash["new_total"], 5, "fuenf erfundene Dateien aus drei Kursen")
        let lib = try await c.api.value("/api/library")
        let names = (lib["files"]?.array ?? []).compactMap { $0["name"]?.string }.sorted()
        XCTAssertEqual(names, ["01_Vorlesung_Mengen.pdf", "02_Vorlesung_Induktion.pdf", "Blatt01.pdf", "Programmieren_VL01.pdf", "Uebungsblatt_01.pdf"])
        let week = try await c.api.value("/api/timetable/week?start=2026-10-26")
        let monday = week.list("days").first?.list("events").map { $0.s("start") ?? "" } ?? []
        XCTAssertEqual(monday, ["08:15"], "Mathematik montags aus dem Stud.IP-Stundenplan")
        let modules = (try await c.api.value("/api/modules").array ?? []).compactMap { $0["name"]?.string }
        XCTAssertTrue(modules.contains("Programmieren I"), "\(modules)")
        XCTAssertTrue(modules.contains { $0.contains("Mathematik") }, "\(modules)")
        let search = try await c.api.value("/api/search?q=induktion")
        XCTAssertGreaterThan(search["pages"]?.array?.count ?? 0, 0, "Suche findet Text der erfundenen PDF")

        // Schritt 2: QIS angemeldet -> Noten; mit dem Stub (UniStubProtocol liefert die Seiten des Ordners)
        let dir = ContainerTestBed.stubDirectory
        UniStubProtocol.install { r in
            let t = DebugStubTransport(directory: dir)
            let reply = t.reply(r.url, body: r.body)
            return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
        qis.signedIn()
        XCTAssertTrue(qis.isConnected)
        let report = await qis.run(force: true)
        XCTAssertEqual(report?.grades, 3, report?.message ?? "")
        rows = FirstSyncProgress.luh(phase: m.studip.phase, hasSession: true, summary: m.studip.lastSummary, qis: qis.state, qisMessage: qis.lastMessage)
        XCTAssertEqual(rows.map(\.state), [.done, .done, .done, .done])
        XCTAssertEqual(rows[3].detail, "3 Leistungen")
        XCTAssertTrue(FirstSyncProgress.isFinished(rows))
        let grades = try await c.api.value("/api/grades")
        XCTAssertEqual(grades["grades"]?.array?.count, 3)
        // Schnitt wie app/grades_model.py: nach der ersten Nachkommastelle abgeschnitten, dazu genau
        XCTAssertEqual(grades["average_exact"], 1.96, "(2,0·8 + 1,3·6 + 2,7·5) / 19")
        XCTAssertEqual(grades["average"], 1.9)
        XCTAssertEqual(grades["credits"], 19)

        // Ende: Oberflaeche; beim naechsten Start nicht wieder die Anmeldeseiten
        a.markLoginDone()
        XCTAssertEqual(a.stage, .ready)
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip), .local(.connected), "keine Karte Stud.IP verbinden mehr")
    }

    /// "Später anmelden" ohne jede Anmeldung: Oberflaeche mit den bisherigen Karten "… verbinden"
    func testLaterWithoutLoginShowsTheConnectCards() throws {
        let m = bed.manager()
        let a = bed.account(.hildesheim)
        let c = try bed.open(m, a)
        let h = try XCTUnwrap(m.hildesheim)
        XCTAssertEqual(a.stage, .universityLogin)
        XCTAssertFalse(FirstLoginFlow.anyConnected(studip: m.studip, qis: nil, hildesheim: h))
        XCTAssertFalse(FirstLoginFlow.isConnected(.learnweb, studip: m.studip, qis: nil, hildesheim: h))
        XCTAssertFalse(FirstLoginFlow.isConnected(.lsf, studip: m.studip, qis: nil, hildesheim: h))
        let rows = FirstSyncProgress.hildesheim(learnweb: h.learnweb, lsf: h.lsf, messages: h.messages)
        XCTAssertEqual(rows.map(\.state), [.skipped, .skipped, .skipped])
        a.markLoginDone()
        XCTAssertEqual(a.stage, .ready)
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip), .local(.otherSources))
        XCTAssertTrue(h.needsAttention(.learnweb) && h.needsAttention(.lsf), "Karten Learnweb verbinden / LSF verbinden")
        // Hochschule gewechselt: die LUH dieses Nutzers bekommt ihre Anmeldeseiten einmal
        a.chooseUniversity(.luh)
        XCTAssertEqual(a.stage, .universityLogin)
        a.markLoginDone()
        a.chooseUniversity(.hildesheim)
        XCTAssertEqual(a.stage, .ready, "Hildesheim schon durch")
    }
}
