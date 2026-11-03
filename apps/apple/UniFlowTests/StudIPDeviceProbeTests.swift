import Foundation
import XCTest
import UniFlowCore
@testable import UniFlow

/// Geraete-Probe (03.11.2026): laeuft NUR auf einem Geraet oder Simulator mit angemeldetem Stud.IP-Container und nur mit
/// der Umgebungsvariable `UF_DEVICE_PROBE=1` (Xcode: Schema → Test → Arguments → Environment; xcodebuild:
/// `TEST_RUNNER_UF_DEVICE_PROBE=1`). Sonst wird sie uebersprungen, damit kein Testlauf je zur Hochschule geht.
///
/// Prueft gegen die echte LUH, ausschliesslich GET mit dem gespeicherten Sitzungs-Cookie (nichts wird markiert,
/// geschrieben oder gespeichert; die Datenbank des Containers bleibt unberuehrt):
/// 1. Schwarzes Brett: Themenliste des Plugins und je Thema der RSS-Feed – Themen, Anzahl, die ersten drei Titel.
/// 2. Forum der JSON:API: je Kurs `courses/{id}/forum-categories` (Status, Anzahl), je Kategorie `forum-categories/{id}/entries`,
///    je Thema `forum-entries/{id}/entries` – damit der Koordinator sieht, warum das Forum leer kam (404 = noch keine
///    Kategorie im Kurs, 403 = Forum im Kurs aus).
/// Ausgabe im Testprotokoll, jede Zeile mit "[Probe]". Keine Personennamen (Titel von Anzeigen und Kursen, Zahlen, Status).
final class StudIPDeviceProbeTests: XCTestCase {

    private func say(_ s: String) {
        print("[Probe] " + s)
        NSLog("[Probe] %@", s)
    }

    /// Sitzungs-Cookies des ersten LUH-Containers auf diesem Geraet (Schluesselbund der App, Ordner der Container)
    private func luhCookies() -> [HTTPCookie] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: ContainerPaths.base, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let all = StudIPCookieStore(container: id).load()
            say("Container \(id.uuidString.prefix(8)): \(all.count) Cookies")
            let cookies = all.filter { $0.domain.contains("uni-hannover") }
            // LUH heisst das Sitzungs-Cookie Studip_Session (03.11.2026), andere Stud.IP-Fassungen Seminar_Session
            if cookies.contains(where: { $0.name == "Seminar_Session" || $0.name == "Studip_Session" }) { return cookies }
        }
        return []
    }

    private func client() throws -> StudIPClient {
        guard ProcessInfo.processInfo.environment["UF_DEVICE_PROBE"] == "1" else {
            throw XCTSkip("Geräte-Probe nur mit UF_DEVICE_PROBE=1 auf dem angemeldeten iPad (TEST_RUNNER_UF_DEVICE_PROBE=1 bei xcodebuild)")
        }
        let cookies = luhCookies()
        guard !cookies.isEmpty else { throw XCTSkip("Kein angemeldeter Stud.IP-Container (LUH) auf diesem Gerät") }
        return StudIPClient(base: StudIPSync.base, transport: URLSessionStudIPTransport(cookies: cookies, host: StudIPSync.base.host ?? ""))
    }

    private func status(_ error: Error) -> String {
        if case StudIPError.http(let s, _) = error { return "HTTP \(s)" }
        if case StudIPError.sessionExpired = error { return "Sitzung abgelaufen" }
        return "\(error)"
    }

    func testBulletinBoardAndForumOnTheDevice() async throws {
        let client = try client()

        // 0. Nachrichten (nur Liste, nie Einzelansicht; nur Anzahl und Absender-Art, kein Inhalt)
        do {
            let uid = try await client.currentUserID()
            let j = try await client.json("jsonapi.php/v1/users/\(uid)/inbox?page[limit]=100")
            let data = j["data"]?.array ?? []
            let unread = data.filter { $0["attributes"]?["is-read"]?.bool == false }.count
            let system = data.filter { ($0["relationships"]?["sender"]?["data"]?["id"]?.string ?? "").contains("system") }.count
            say("Nachrichten: \(data.count) in der Liste (Gesamt laut Stud.IP \(j["meta"]?["page"]?["total"]?.int ?? -1)), ungelesen \(unread), Systemnachrichten \(system)")
        } catch { say("Nachrichten: \(status(error))") }

        // 1. Schwarzes Brett
        let d = await StudIPBulletin.fetch(client: client, missing: [:], lastFetchedAt: nil, clock: .system)
        XCTAssertFalse(d.sessionExpired, "Stud.IP-Sitzung abgelaufen: in der App neu anmelden")
        say("Schwarzes Brett: \(d.topics.count) Themen, \(d.entries?.count ?? -1) Anzeigen gelesen"
            + (d.feedUnavailable ? " – RSS im Plugin abgeschaltet" : "") + (d.missing[StudIPBulletin.missingName] != nil ? " – Plugin nicht gefunden (404/keine Themenliste)" : ""))
        for t in d.topics {
            let titles = (d.entries ?? []).filter { $0.topic == t.title }
            say("Thema „\(t.title)“ – laut Stud.IP \(t.count), gelesen \(titles.count): "
                + titles.prefix(3).map { "„\($0.title)“ (\($0.postedAt))" }.joined(separator: ", "))
        }
        XCTAssertFalse(d.topics.isEmpty, "Themenliste nicht gefunden: plugins.php/schwarzesbrettplugin/category/list ohne <ul class=\"sb-categories\">")
        XCTAssertGreaterThan(d.entries?.count ?? 0, 0, "kein RSS-Eintrag gelesen")

        // 2. Forum (JSON:API), nur GET
        let uid = try await client.currentUserID()
        let courses = try await client.courses(userID: uid)
        say("Forum: \(courses.count) Kurse")
        var withCategories = 0, entriesTotal = 0
        for c in courses.prefix(40) {
            do {
                let cats = try await client.json("jsonapi.php/v1/courses/\(c.id)/forum-categories?page[limit]=50")["data"]?.array ?? []
                withCategories += 1
                var line = "Kurs „\(c.title)“: forum-categories 200 (\(cats.count))"
                for cat in cats.prefix(3) {
                    guard let catID = cat["id"]?.string else { continue }
                    do {
                        let entries = try await client.json("jsonapi.php/v1/forum-categories/\(catID)/entries?page[limit]=50")["data"]?.array ?? []
                        entriesTotal += entries.count
                        line += " · Kategorie: \(entries.count) Themen"
                        if let first = entries.first, let eid = first["id"]?.string {
                            do {
                                let posts = try await client.json("jsonapi.php/v1/forum-entries/\(eid)/entries?page[limit]=100")["data"]?.array ?? []
                                line += " (erstes Thema: \(posts.count) Antworten)"
                            } catch {
                                line += " (erstes Thema: Antworten \(status(error)))"
                            }
                        }
                    } catch {
                        line += " · Kategorie: entries \(status(error))"
                    }
                }
                say(line)
            } catch {
                say("Kurs „\(c.title)“: forum-categories \(status(error))")
            }
        }
        say("Forum: \(withCategories) Kurse mit Kategorien, \(entriesTotal) Themen insgesamt")
    }

    /// Alle JSON:API-Routen dieser Stud.IP-Installation (discovery) und je Route, ob sie fuer dieses Konto antwortet
    /// (nur GET mit page[limit]=1, nur Status und Anzahl, kein Inhalt). Keine HTML-Seiten: Kurs- und Startseiten
    /// koennten in Stud.IP "gesehen"-Marken setzen.
    func testStudIPSurveyOnTheDevice() async throws {
        let client = try client()
        let uid = try await client.currentUserID()
        let disco = try await client.json("jsonapi.php/v1/discovery")
        var routes: [(String, String)] = []
        for r in disco["data"]?.array ?? [] {
            let path = r["attributes"]?["pattern"]?.string ?? r["id"]?.string ?? ""
            let methods = r["attributes"]?["methods"]?.array?.compactMap(\.string).joined(separator: ",") ?? (r["attributes"]?["method"]?.string ?? "")
            routes.append((path, methods))
        }
        if routes.isEmpty { say("Discovery: Format unbekannt: \(String(describing: disco).prefix(400))") }
        let gets = routes.filter { $0.1.uppercased().contains("GET") || $0.1.isEmpty }.map(\.0)
        say("Discovery: \(routes.count) Routen, davon GET \(gets.count)")
        for g in gets.sorted() { say("Route GET \(g)") }
        // Kurse fuer Kurs-Routen: zwei aktuelle
        let courses = (try? await client.courses(userID: uid)) ?? []
        let sample = courses.prefix(2).map(\.id)
        var tried = 0
        for g in gets.sorted() {
            guard tried < 220 else { say("… Abbruch nach 220 Abrufen"); break }
            var path = g.hasPrefix("/") ? String(g.dropFirst()) : g
            if path.hasPrefix("v1/") { path = String(path.dropFirst(3)) }
            if path.contains("{") || path.contains(":") || path.contains("(") {
                // nur Nutzer- und Kurs-Muster mit genau einem Platzhalter einsetzen
                let placeholders = path.components(separatedBy: "/").filter { $0.hasPrefix("{") || $0.hasPrefix(":") || $0.hasPrefix("(") }
                guard placeholders.count == 1 else { continue }
                if path.hasPrefix("users/") { path = path.replacingOccurrences(of: placeholders[0], with: uid) }
                else if path.hasPrefix("courses/"), let c = sample.first { path = path.replacingOccurrences(of: placeholders[0], with: c) }
                else { continue }
            }
            tried += 1
            let sep = path.contains("?") ? "&" : "?"
            do {
                let j = try await client.json("jsonapi.php/v1/\(path)\(sep)page[limit]=1")
                let total = j["meta"]?["page"]?["total"]?.int
                let n = j["data"]?.array?.count
                say("OK  \(g) → " + (total.map { "\($0) Einträge" } ?? n.map { "\($0) Einträge (Seite)" } ?? "Objekt"))
            } catch {
                say("--  \(g) → \(status(error))")
            }
        }
    }
}
