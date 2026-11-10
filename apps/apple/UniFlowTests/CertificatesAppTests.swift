import os
import Security
import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Bescheinigungen in der App (06.11.2026, `CertificateCenter`, Views/Services/CertificatesPage.swift): LUH-QIS aus dem
/// Debug-Stub (Menue "Meine Bescheinigungen" wie live gesehen, verpublish liefert direkt die PDF) mit dem Cookie der
/// Webansicht des Containers; Liste lesen erzeugt kein Dokument, Herunterladen genau ein Aufruf, Kopie mit Datum,
/// Datei ueber das lokale Backend, abgelaufene Sitzung -> "Anmeldung nötig" am QIS. Dazu Route, Regeln der Seite und
/// welches Portal je Hochschule (HsH Campusmanagement, Hildesheim PLuS statt LSF). Erfundene Seiten, kein Netz.
/// 10.11.2026 (Meldung des Inhabers "Bescheinigungen holt er auch nicht"): abgelaufene QIS-Sitzung -> einmal still mit
/// dem gemerkten Passwort anmelden und genau einmal neu lesen bzw. laden (unsichtbare Webansicht ersetzt, erfundene
/// Zugangsdaten); gespeicherter Stand "Anmeldung nötig" bei wieder angemeldeter Verbindung -> beim Oeffnen neu lesen.
@MainActor
final class CertificatesAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    private let clock = UniFlowClock.fixed(berlin: "2026-11-06T10:00:00")!
    private let host = "qis.verwaltung.uni-hannover.de"

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "besch", clock: clock)
    }

    override func tearDown() async throws {
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        services = []
        await bed.tearDown()
        try await super.tearDown()
    }

    private var services: [String] = []

    /// QIS aus dem Debug-Stub; angemeldet nur, solange `session` wahr ist (sonst die Anmeldeseite, wie abgelaufen)
    private func installQIS(session: OSAllocatedUnfairLock<Bool>) {
        let dir = ContainerTestBed.stubDirectory
        let login = #"<html><body><form action="x" method="post"><input type="text" name="asdf"><input type="password" name="fdsa"></form></body></html>"#
        UniStubProtocol.install { r in
            guard session.withLock({ $0 }), r.cookie.contains("JSESSIONID=qis-sitzung-test") else { return .text(login) }
            let reply = DebugStubTransport(directory: dir).reply(r.url, body: r.body)
            return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
    }

    /// gemerktes Passwort (erfunden) im Test-Schluesselbund dieses Containers, App "aktiv"
    private func remember(_ m: ContainerManager, _ c: ActiveContainer) throws {
        services.append(m.credentialService)
        XCTAssertNotEqual(m.credentialService, UniCredentialStore.service, "Tests nie im echten Dienst")
        try UniCredentialStore(service: m.credentialService, container: c.layout.identifier)
            .save(UniCredential(username: "testnutzer-erfunden", password: "Pw-Test-erfunden-123", savedAt: Date()))
        UniAutoLogin.appActiveOverride = true
    }

    private func verpublish() -> Int { UniStubProtocol.requests.filter { $0.url.absoluteString.contains("verpublish") }.count }

    private func installQIS(loggedIn: Bool = true) {
        let dir = ContainerTestBed.stubDirectory
        let login = #"<html><body><form action="x" method="post"><input type="text" name="asdf"><input type="password" name="fdsa"></form></body></html>"#
        UniStubProtocol.install { r in
            guard loggedIn, r.cookie.contains("JSESSIONID=qis-sitzung-test") else { return .text(login) }
            let reply = DebugStubTransport(directory: dir).reply(r.url, body: r.body)
            return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
    }

    private func luh() async throws -> (ContainerManager, ActiveContainer, QISConnection) {
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        let q = try XCTUnwrap(m.qis)
        q.syncsAfterSignIn = false
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("JSESSIONID", "qis-sitzung-test", domain: host))
        q.signedIn()
        return (m, c, q)
    }

    func testLUHListAndDownloadThroughTheStub() async throws {
        let (_, c, q) = try await luh()
        installQIS()
        let center = CertificateCenter(portal: .qis(q))
        XCTAssertEqual(center.portalName, "QIS")
        XCTAssertTrue(center.isConnected)
        XCTAssertTrue(center.shouldRefresh(status: "never", checkedAt: nil), "nie gelesen: beim Oeffnen lesen")
        let report = await center.refresh()
        let r = try XCTUnwrap(report)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.offers, 1, "ein Eintrag wie im echten QIS")
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.absoluteString.contains("verpublish") }, "die Liste erzeugt kein Dokument")
        XCTAssertTrue(UniStubProtocol.requests.allSatisfy { $0.url.host == host })
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.absoluteString.contains("prfAnm") || $0.url.absoluteString.contains("type=4") })

        let list = try await c.api.value("/api/certificates")
        XCTAssertEqual(list["portal"]?.string, "QIS")
        XCTAssertEqual(list["status"]?.string, "ok")
        let offer = try XCTUnwrap(list["offers"]?.array?.first)
        XCTAssertEqual(offer["title"]?.string, "Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG")
        XCTAssertEqual(offer["kinds"]?.array?.compactMap(\.string), ["immatrikulation", "bafoeg"])
        XCTAssertEqual(offer["confirmed"]?.bool, true)
        XCTAssertEqual(offer["file"], .null)
        XCTAssertFalse(center.shouldRefresh(status: list.s("status"), checkedAt: list.s("checked_at"), now: clock.now), "frisch gelesen")
        let id = try XCTUnwrap(offer.s("id"))

        let before = UniStubProtocol.requests.filter { $0.url.absoluteString.contains("verpublish") }.count
        let file = await center.download(id)
        let url = try XCTUnwrap(file, center.message ?? "")
        XCTAssertTrue(try Data(contentsOf: url).starts(with: Array("%PDF".utf8)))
        XCTAssertEqual(UniStubProtocol.requests.filter { $0.url.absoluteString.contains("verpublish") }.count, before + 1, "genau ein Aufruf")
        let after = try await c.api.value("/api/certificates")
        let row = try XCTUnwrap(after["offers"]?.array?.first)
        XCTAssertEqual(row["file"]?["fetched_at"]?.string, clock.nowISO)
        XCTAssertTrue(CertificatesPage.subline(row).contains("Stand: 06.11.2026, 10:00"), CertificatesPage.subline(row))
        let (bytes, http) = try await c.api.data("/api/certificates/\(id)/file")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(bytes.starts(with: Array("%PDF".utf8)))
        // kein asi in den Einstellungen oder der Datenbank
        let db = try await c.host.backend().context.database
        let raw = try await db.scalar("SELECT value FROM settings WHERE key='certificates'")?.string ?? ""
        XCTAssertFalse(raw.contains("StubSitzung01"))
        XCTAssertFalse(raw.contains("asi="))
    }

    func testExpiredSessionAsksForTheQISLogin() async throws {
        let (_, _, q) = try await luh()
        installQIS(loggedIn: false)
        let center = CertificateCenter(portal: .qis(q))
        let r = await center.refresh()
        XCTAssertEqual(r?.needsLogin, true)
        XCTAssertTrue(center.needsLogin)
        XCTAssertEqual(q.state, .needsLogin, "dieselbe Anmeldung wie beim Notenabruf")
        XCTAssertFalse(center.isConnected)
        XCTAssertFalse(center.shouldRefresh(status: "login", checkedAt: nil), "nicht von selbst gegen die Anmeldeseite")
    }

    func testExpiredSessionSignsInSilentlyAndReadsTheListOnce() async throws {
        let (m, c, q) = try await luh()
        try remember(m, c)
        let session = OSAllocatedUnfairLock(initialState: false)
        installQIS(session: session)
        var logins: [UniAutoLoginRequest] = []
        UniAutoLogin.runnerOverride = { r in logins.append(r); session.withLock { $0 = true }; return .success }
        let center = CertificateCenter(portal: .qis(q))
        XCTAssertTrue(center.isConnected, "die App haelt die Sitzung noch fuer gueltig")
        let report = await center.refresh()
        let r = try XCTUnwrap(report)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertFalse(r.needsLogin)
        XCTAssertEqual(r.offers, 1)
        XCTAssertEqual(logins.count, 1, "genau eine stille Anmeldung")
        XCTAssertEqual(logins.first?.entry, QISClient.startURL)
        XCTAssertFalse(center.needsLogin)
        XCTAssertTrue(center.isConnected)
        XCTAssertNotEqual(q.state, .needsLogin)
        XCTAssertEqual(verpublish(), 0, "die Liste erzeugt kein Dokument")
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.absoluteString.contains("prfAnm") || $0.url.absoluteString.contains("type=4") })
        let list = try await c.api.value("/api/certificates")
        XCTAssertEqual(list["status"]?.string, "ok")

        // Herunterladen mit abgelaufener Sitzung: der erste Aufruf trifft die Anmeldeseite (kein Dokument), dann einmal
        // still anmelden ist verbraucht (`UniAutoLoginMachine`: keine zweite Runde so kurz danach) -> "Anmeldung nötig"
        session.withLock { $0 = false }
        let id = try XCTUnwrap(list["offers"]?.array?.first?.s("id"))
        let none = await center.download(id)
        XCTAssertNil(none)
        XCTAssertTrue(center.needsLogin)
        XCTAssertEqual(q.state, .needsLogin)
        XCTAssertEqual(logins.count, 1, "keine Schleife")
        XCTAssertEqual(verpublish(), 1, "nur der eine Versuch, kein zweiter ohne Anmeldung")
        // gespeicherter Stand der Liste bleibt, es gibt keine Datei
        let after = try await c.api.value("/api/certificates")
        XCTAssertEqual(after["offers"]?.array?.first?["file"], .null)
    }

    func testExpiredSessionAtDownloadSignsInSilentlyAndLoadsOneDocument() async throws {
        let (m, c, q) = try await luh()
        try remember(m, c)
        let session = OSAllocatedUnfairLock(initialState: true)
        installQIS(session: session)
        var logins = 0
        UniAutoLogin.runnerOverride = { _ in logins += 1; session.withLock { $0 = true }; return .success }
        let center = CertificateCenter(portal: .qis(q))
        let first = await center.refresh()
        XCTAssertEqual(first?.ok, true)
        XCTAssertEqual(logins, 0, "gueltige Sitzung: keine Anmeldung")
        let list = try await c.api.value("/api/certificates")
        let id = try XCTUnwrap(list["offers"]?.array?.first?.s("id"))

        session.withLock { $0 = false }                            // QIS hat inzwischen abgemeldet
        let file = await center.download(id)
        let url = try XCTUnwrap(file, center.message ?? "")
        XCTAssertTrue(try Data(contentsOf: url).starts(with: Array("%PDF".utf8)))
        XCTAssertEqual(logins, 1, "genau eine stille Anmeldung")
        XCTAssertEqual(verpublish(), 2, "der erste Aufruf traf die Anmeldeseite (kein Dokument), dann genau einer")
        XCTAssertFalse(center.needsLogin)
        XCTAssertNotEqual(q.state, .needsLogin)
    }

    func testStoredLoginStatusIsReadAgainOnceTheConnectionIsBack() async throws {
        let (_, _, q) = try await luh()
        let session = OSAllocatedUnfairLock(initialState: false)
        installQIS(session: session)
        let center = CertificateCenter(portal: .qis(q))
        let r = await center.refresh()                             // ohne gemerktes Passwort: "Anmeldung nötig"
        XCTAssertEqual(r?.needsLogin, true)
        XCTAssertTrue(center.needsLogin)
        XCTAssertFalse(center.shouldRefresh(status: "login", checkedAt: nil))
        let silent = await center.silentLogin()
        XCTAssertFalse(silent, "ohne gemerktes Passwort nichts")
        // der Nutzer meldet sich woanders an (QIS-Karte, Notenabruf): die Seite liest beim Oeffnen von selbst neu
        session.withLock { $0 = true }
        q.signedIn()
        let fresh = CertificateCenter(portal: .qis(q))
        XCTAssertTrue(fresh.shouldRefresh(status: "login", checkedAt: "2026-11-06T09:59:00", now: clock.now),
                      "Stand \"Anmeldung nötig\" bleibt nicht haengen")
        let again = await fresh.refresh()
        XCTAssertEqual(again?.ok, true)
        XCTAssertFalse(fresh.needsLogin)
        XCTAssertEqual(verpublish(), 0)
    }

    func testPortalPerUniversity() throws {
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.hsh))
        let hsh = try XCTUnwrap(CertificateCenter.make(qis: m.qis, hsh: m.hsh, hildesheim: m.hildesheim))
        XCTAssertEqual(hsh.portalName, "Campusmanagement")
        XCTAssertFalse(hsh.isConnected, "ohne Campusmanagement-Anmeldung nicht anfragen")
        let m2 = bed.manager()
        _ = try bed.open(m2, bed.account(.hildesheim))
        let hil = try XCTUnwrap(CertificateCenter.make(qis: m2.qis, hsh: m2.hsh, hildesheim: m2.hildesheim))
        XCTAssertEqual(hil.portalName, "PLuS", "Bescheinigungen der Uni Hildesheim liegen im PLuS, nicht im LSF")
        XCTAssertEqual(CertificatePortal.plusStudyService.host, "plus.uni-hildesheim.de")
        XCTAssertTrue(CertificatePortal.plusStudyService.absoluteString.contains("initialTab=showTabReport"))
        XCTAssertTrue(PLuSLogin.isSignedIn(html: #"<a href="/qisserver/rds?state=user&type=3&category=auth.logout">Abmelden</a>"#, url: URL(string: "https://plus.uni-hildesheim.de/qisserver/pages/x")))
        XCTAssertFalse(PLuSLogin.isSignedIn(html: "Ihre Sitzung ist abgelaufen. Anmelden", url: URL(string: "https://plus.uni-hildesheim.de/x")))
        XCTAssertFalse(PLuSLogin.isSignedIn(html: "category=auth.logout", url: URL(string: "https://www.uni-hildesheim.de/sso/login")))
        XCTAssertNil(CertificateCenter.make(qis: nil, hsh: nil, hildesheim: nil))
    }

    func testRouteAndPageRules() throws {
        XCTAssertEqual(UFRoute(hash: "#/bescheinigungen"), .certificates)
        XCTAssertEqual(UFRoute.certificates.navKey, "services", "Uni & Noten bleibt markiert")
        XCTAssertEqual(UFRoute.certificates.hash, "#/bescheinigungen")
        XCTAssertTrue(UFRouter.showsBackArrow(on: .certificates))
        let offers: [JSONValue] = [
            ["id": "a", "title": "Immatrikulationsbescheinigung", "kind": "immatrikulation", "kind_label": "Immatrikulations- / Studienbescheinigung",
             "semester": "WiSe 2026/27", "confirmed": true, "file": ["fetched_at": "2026-11-06T14:03:00", "semester": "WiSe 2026/27"]],
            ["id": "b", "title": "Notenspiegel (alle Leistungen) deutsch", "kind": "notenspiegel", "kind_label": "Notenspiegel / Leistungsübersicht (PDF)",
             "semester": .null, "confirmed": false, "file": .null],
            ["id": "c", "title": "Enrolment Certificate", "kind": "immatrikulation", "kind_label": "Immatrikulations- / Studienbescheinigung",
             "semester": .null, "confirmed": true, "file": .null],
        ]
        let groups = CertificatesPage.groups(offers)
        XCTAssertEqual(groups.map(\.kind), ["immatrikulation", "notenspiegel"])
        XCTAssertEqual(groups.first?.offers.count, 2)
        XCTAssertEqual(CertificatesPage.subline(offers[0]), "WiSe 2026/27 · Stand: 06.11.2026, 14:03")
        XCTAssertEqual(CertificatesPage.subline(offers[1]), "noch nicht geladen · Aufbau noch nicht mit echtem Konto geprüft")
        XCTAssertTrue(CertificatesPage.emptyText(status: "never", portal: "PLuS").contains("Liste aktualisieren"))
        XCTAssertTrue(CertificatesPage.emptyText(status: "login", portal: "QIS").hasPrefix("Melde dich bei QIS an"))
        XCTAssertEqual(CertificatesPage.fileName("Studienzeit- / Immatrikulationsbescheinigung", stand: "2026-11-06T14:03:00"),
                       "Studienzeit- - Immatrikulationsbescheinigung (Stand 06.11.2026).pdf")
    }
}
