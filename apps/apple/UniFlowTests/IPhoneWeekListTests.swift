import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Befund des Inhabers am iPhone (11.11.2026): "Wochenansicht fehlt komplett, alles muss lesbar sein". Die Woche steht
/// am iPhone hochkant als Liste Montag–Sonntag (`PhoneWeekListView`) im Lernkalender ("Woche" wieder in der Leiste) und
/// im Stundenplan (statt abgeschnittener Spalten). Volle Titel, Zeit und Raum, nichts ragt ueber den Rand. Gegenprobe:
/// iPad behaelt das Raster. Dazu Bildschirmfotos der echten Anmeldeseiten (QIS, Stud.IP) am iPhone.
@MainActor
final class IPhoneWeekListTests: IPhoneLearnTestCase {

    private func event(_ title: String, _ start: String, _ end: String, room: String = "", kind: String = "vorlesung",
                       status: String = "teilnahme", id: Int) -> JSONValue {
        ["event_id": .number(Double(id)), "title": .string(title), "start": .string(start), "end": .string(end),
         "room": .string(room), "kind": .string(kind), "status": .string(status), "color": "#7c3aed"]
    }

    private func week() -> [JSONValue] {
        let mon = PlanData.monday(Fmt.date("2026-11-09")!)
        return (0..<7).map { i -> JSONValue in
            let date = Fmt.isoDay(PlanData.add(mon, i))
            var events: [JSONValue] = []
            var packages: [JSONValue] = []
            if i == 0 { events = [event("Grundlagen der Informatik – Vorlesung", "10:00", "12:00", room: "Hörsaal A, Gebäude 3408", id: 1)] }
            if i == 2 {
                events = [event("Grundlagen der Informatik – Übung", "14:00", "16:00", room: "Seminarraum 3", kind: "uebung", id: 2),
                          event("Lineare Algebra I für Studierende der Informatik", "08:15", "09:45", room: "Hörsaal F", status: "nicht_teilnahme", id: 3)]
                packages = [["id": 7, "subject": "Grundlagen der Informatik", "title": "Übungsblatt 1", "start_time": "16:30",
                             "end_time": "17:30", "planned_minutes": 60, "status": "geplant",
                             "tasks": [["status": "erledigt"], ["status": "offen"]]]]
            }
            return ["date": .string(date), "weekday": .number(Double(i)), "events": .array(events), "packages": .array(packages)]
        }
    }

    func testWeekListIsReadableOnAllPhones() throws {
        let view = ScrollView { PhoneWeekListView(days: week(), packages: true, openEvent: { _, _ in }).padding(16) }
        let env = try hostPhone(view, api: remote(Canned()))
        XCTAssertTrue(env.wait { self.shows(env, "Grundlagen der Informatik – Vorlesung") }, dump(env))
        XCTAssertTrue(shows(env, "Lineare Algebra I für Studierende der Informatik"), "voller Titel, nicht gekürzt: \(dump(env))")
        XCTAssertTrue(shows(env, "10:00–12:00 · Hörsaal A, Gebäude 3408"), dump(env))
        XCTAssertTrue(shows(env, "nicht besucht"), dump(env))
        XCTAssertTrue(shows(env, "Übungsblatt 1"), "Lernblock mit Titel: \(dump(env))")
        XCTAssertTrue(shows(env, "Montag, 9. November"), dump(env))
        XCTAssertTrue(shows(env, "Sonntag, 15. November"), "alle sieben Tage im Lernkalender: \(dump(env))")
        // Reihenfolge nach Uhrzeit am Mittwoch: 08:15 vor 14:00 vor 16:30
        let a = frame(element(env, label: "Lineare Algebra", prefix: true)), b = frame(element(env, label: "Grundlagen der Informatik – Übung", prefix: true))
        XCTAssertLessThan(a.minY, b.minY, "nach Uhrzeit sortiert")
        assertFitsOnAllPhones(env, "woche-liste")
        shoot(env, "iphone-woche-liste")
    }

    func testTimetableListHidesEmptyWeekend() throws {
        let view = ScrollView { PhoneWeekListView(days: week(), hideEmptyWeekend: true, openEvent: { _, _ in }).padding(16) }
        let env = try hostPhone(view, api: remote(Canned()))
        XCTAssertTrue(env.wait { self.shows(env, "Freitag, 13. November") }, dump(env))
        XCTAssertFalse(shows(env, "Samstag"), "leeres Wochenende im Stundenplan weg: \(dump(env))")
        XCTAssertFalse(shows(env, "Übungsblatt 1"), "Stundenplan ohne Lernblöcke")
        XCTAssertTrue(shows(env, "Keine Termine"), dump(env))
    }

    func testListOnlyOnPhonePortrait() {
        XCTAssertTrue(PhoneWeekList.applies(width: 402))
        XCTAssertFalse(PhoneWeekList.applies(width: 874), "quer: Raster")
        XCTAssertFalse(PhoneWeekList.applies(width: 0))
        UFCompact.phoneLayoutsOverride = false
        defer { UFCompact.phoneLayoutsOverride = true }
        XCTAssertFalse(PhoneWeekList.applies(width: 402), "iPad im schmalen Split View: Raster wie bisher")
    }

    /// QIS-Anmeldung am iPhone: die Rechner-Seite (970 pt, ohne Viewport) passt nach dem Skript in die Breite, Kopfbild
    /// und Menue sind weg, die Begruessung ist klein; andere Rechner bekommen nichts
    func testQISLoginPageFitsThePhone() async throws {
        let html = """
        <html><head><style>#wrapper{width:970px}.divheader{height:200px}.headlineText h4{font-size:26px}</style></head><body>
        <div id="wrapper"><div class="divheader">Kopf</div><div class="divlinks">Links</div><div class="divcontent">
        <div class="content_max_portal_qis"><div><div class="portalcontent"><div class="welcome_text"><div class="headline">
        <div class="square square1"></div><div class="headlineText"><h4>Herzlich willkommen beim Online-Service</h4></div></div></div>
        <form class="formular"><div class="portalcontent2"><div class="containerLogin"><ol>
        <li><label class="label">Benutzername</label><input class="input_login" type="text"></li>
        <li><label class="label">Passwort</label><input class="input_login" type="password"></li>
        <li><span class="nolabel">&nbsp;</span><input class="submit" type="submit" value="Login"></li></ol></div></div></form>
        </div></div></div></div></div></body></html>
        """
        func run(_ web: WKWebView, _ js: String) async -> String? {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                web.evaluateJavaScript(js) { r, e in c.resume(returning: (r as? String) ?? e.map { "FEHLER \($0)" }) }
            }
        }
        func measure(host: String) async throws -> [String: Any] {
            let config = WKWebViewConfiguration()
            QISPhoneFit.install(in: config)
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 800), configuration: config)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: web.frame)
            window.frame = web.frame
            window.addSubview(web)
            window.isHidden = false
            defer { window.isHidden = true; web.removeFromSuperview() }
            web.loadHTMLString(html, baseURL: URL(string: "https://\(host)/qisserver/rds"))
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if await run(web, "document.querySelector('.divheader') && document.readyState == 'complete' ? 'ja' : 'nein'") == "ja" { break }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            let js = "JSON.stringify({w: document.documentElement.scrollWidth, head: getComputedStyle(document.querySelector('.divheader')).display, " +
                "h4: parseFloat(getComputedStyle(document.querySelector('h4')).fontSize), " +
                "field: document.querySelector('.input_login').getBoundingClientRect().width})"
            let json = await run(web, js) ?? "{}"
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? ["raw": json]
        }
        let qis = try await measure(host: "qis.verwaltung.uni-hannover.de")
        XCTAssertLessThanOrEqual((qis["w"] as? Double) ?? 999, 402, "Seite passt in die Breite: \(qis)")
        XCTAssertEqual(qis["head"] as? String, "none", "Kopfbild weg: \(qis)")
        XCTAssertLessThanOrEqual((qis["h4"] as? Double) ?? 99, 18, "Begruessung klein: \(qis)")
        XCTAssertGreaterThan((qis["field"] as? Double) ?? 0, 300, "Feld in voller Breite: \(qis)")
        let other = try await measure(host: "studip.uni-hannover.de")
        XCTAssertNotEqual(other["head"] as? String, "none", "nur das QIS: \(other)")
    }

    /// Erster Start am iPhone: kleiner Kopf ohne den langen Passwort-Satz, damit die Anmeldeseite Platz hat
    func testFirstLoginHeaderIsSmallOnPhone() throws {
        let bed = try ContainerTestBed(name: "iphone-erststart", clock: .fixed(berlin: "2026-11-11T09:00:00")!)
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.luh))
        let page = FirstLoginPage(step: .qis, index: 1, count: 2, studip: m.studip, qis: m.qis, hildesheim: nil,
                                  onDone: {}, onLater: {})
        let env = try hostPhone(page, api: remote(Canned()))
        XCTAssertTrue(env.wait { self.shows(env, "Schritt 2 von 2") }, dump(env))
        XCTAssertFalse(shows(env, FirstLoginPage.passwordNote), "Passwort-Satz nur im Hinweis unten: \(dump(env))")
        let title = frame(element(env, id: "firststart.title"))
        XCTAssertLessThan(title.maxY, 200, "Kopf klein: \(title)")
        shoot(env, "iphone-erststart-qis")
        let exp = expectation(description: "Aufraeumen")
        Task { await bed.tearDown(); exp.fulfill() }
        wait(for: [exp], timeout: 10)
    }

    /// Echte Anmeldeseiten am iPhone (Netz noetig; ohne Netz nur ein Foto der Fehlermeldung)
    func testLoginPagesOnPhone() async throws {
        let bed = try ContainerTestBed(name: "iphone-anmeldung", clock: .fixed(berlin: "2026-11-11T09:00:00")!)
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.luh))
        let qis = try XCTUnwrap(m.qis)
        qis.syncsAfterSignIn = false
        let studip = try hostPhone(NavigationStack {
            StudIPLoginPane(base: StudIPSync.base, dataStore: .nonPersistent(), onSignedIn: { _ in }) { EmptyView() }
                .navigationTitle("Stud.IP-Anmeldung").navigationBarTitleDisplayMode(.inline)
        }, api: remote(Canned()))
        studip.pump(12)
        shoot(studip, "iphone-anmeldung-studip")
        let qisEnv = try hostPhone(NavigationStack {
            QISLoginPane(connection: qis, onSignedIn: {}) { EmptyView() }
                .navigationTitle("QIS-Anmeldung").navigationBarTitleDisplayMode(.inline)
        }, api: remote(Canned()))
        qisEnv.pump(12)
        shoot(qisEnv, "iphone-anmeldung-qis")
        await bed.tearDown()
    }
}
