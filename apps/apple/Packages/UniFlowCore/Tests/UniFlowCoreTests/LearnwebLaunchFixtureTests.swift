import Foundation
import XCTest
@testable import UniFlowCore

/// Gemeinsamer Vertrag "Hochschul-Anmeldung auf dem Geraet" (packages/shared-contracts/fixtures/learnweb/launch.json,
/// tools/gen-learnweb-fixture.py, PC-Stand 27.10.2026) gegen `UniversityProfile`, `MoodleSSO` und `LearnwebAPI`.
///
/// Abweichungen des iPads, bewusst und hier festgehalten (die Tests schlagen fehl, wenn eine davon verschwindet):
/// - Schluessel aus der Moodle-Antwort muessen alphanumerisch sein (`LearnwebToken`, so erzeugt Moodle sie mit
///   `random_string`); die Fixture nutzt "tok-123", "priv-456", "tok+/=x". Signatur und Base64 rechnet das iPad wie
///   Python (geprueft mit denselben Antworten und alphanumerischen Schluesseln).
/// - "Schluessel mit URL-sicherem Base64": der Generator ersetzt "/" in der ganzen Adresse, auch in "uniflow://"
///   ("uniflow:__token="). Die App nimmt nur `<schema>://token=` an (`isTokenRedirect`).
/// - Anmeldeseite statt Datei: das iPad prueft wie `studip_sync._stream_once` am PC den Inhalt ("<!doctype html"
///   oder "<html" am Anfang, `UniStore.startsLikeWebPage`), nicht den Content-Type wie `filestream.looks_like_html`.
/// - Erlaubte Hosts: das iPad laesst Anfragen des Abgleichs nur an die Rechner der Hochschule (Stud.IP mit WebSSO,
///   *.uni-hildesheim.de); die Anmeldeansicht selbst schraenkt keine Rechner ein.
/// Die Cookie-Kopfzeile setzt in der App `HTTPCookieStorage` (URLSessionUniTransport, App-Test).
final class LearnwebLaunchFixtureTests: XCTestCase {
    private func fixture() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/learnweb/launch.json")))
    }

    // MARK: Anmeldeprofile

    func testProfilesMatchUniversityProfile() throws {
        let fx = try fixture()
        let luh = try XCTUnwrap(fx["profiles"]?["luh"]), hi = try XCTUnwrap(fx["profiles"]?["hildesheim"])
        let l = UniversityProfile.luh, h = UniversityProfile.hildesheim

        XCTAssertEqual(luh["name"]?.string, l.name)
        XCTAssertEqual(luh["login_url"]?.string, l.loginService("studip")?.entryURLs.first?.absoluteString, "Startseite der Anmeldeansicht")
        // Anmeldung gilt, wenn users/me antwortet (StudIPSync.sessionIsValid ueber StudIPClient)
        XCTAssertEqual(luh["logged_in_check_url"]?.string, l.studipBase?.appendingPathComponent("jsonapi.php/v1/users/me").absoluteString)
        XCTAssertEqual(luh["file_host"]?.string, l.studipBase?.host)
        XCTAssertEqual(luh["learnweb_base"], .null)
        XCTAssertEqual(luh["cas_base"], .null)
        XCTAssertNil(l.learnwebBase)
        XCTAssertNil(l.casBase)
        // Stud.IP und WebSSO sind Anmeldeseiten der LUH im Profil; login.uni-hannover.de (IDM) braucht der Abgleich nicht
        let luhHosts = Set((luh["hosts"]?.array ?? []).compactMap(\.string))
        let luhTargets = Set(l.loginService("studip")?.targets.map(\.host) ?? [])
        XCTAssertEqual(luhTargets.subtracting(luhHosts), [], "jede Anmeldeseite des iPads steht in der Fixture")
        XCTAssertEqual(luhHosts.subtracting(luhTargets), ["login.uni-hannover.de"])

        XCTAssertEqual(hi["name"]?.string, h.name)
        let lw = try XCTUnwrap(h.learnwebBase?.absoluteString)
        XCTAssertEqual(hi["learnweb_base"]?.string, lw)
        XCTAssertEqual(hi["cas_base"]?.string, h.casBase?.absoluteString)
        XCTAssertEqual(hi["cas_base"]?.string, HildesheimCAS.casBase)
        XCTAssertEqual(hi["login_url"]?.string, HildesheimCAS.learnwebLoginURL(base: lw))
        XCTAssertEqual(hi["login_url"]?.string, h.loginService("cas")?.entryURLs.first?.absoluteString)
        XCTAssertEqual(hi["logged_in_check_url"]?.string, lw + "/my/")
        XCTAssertEqual(hi["file_host"]?.string, h.learnwebBase?.host)
        // alle Rechner der Fixture sind Rechner der Hochschule (gleiche Regel wie URLSessionUniTransport.allows)
        let hiDomains = [h.casBase, h.learnwebBase, h.lsfBase].compactMap { $0?.host?.lowercased() }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        for host in (hi["hosts"]?.array ?? []).compactMap(\.string) {
            XCTAssertTrue(hiDomains.contains { host == $0 || host.hasSuffix("." + $0) }, host)
        }
        XCTAssertEqual(Set((hi["hosts"]?.array ?? []).compactMap(\.string)), Set([h.learnwebBase?.host, h.lsfBase?.host].compactMap { $0 }))
    }

    // MARK: Moodle-App-Anmeldung

    func testLaunchURLLikePython() throws {
        let fx = try fixture()
        let l = try XCTUnwrap(fx["launch"])
        let base = try XCTUnwrap(l["base"]?.string), passport = try XCTUnwrap(l["passport"]?.string)
        XCTAssertEqual(MoodleSSO.launchURL(base: base, passport: passport, scheme: l["scheme"]?.string ?? ""), l["url"]?.string)
        XCTAssertEqual(MoodleSSO.launchURL(base: base, passport: passport), l["url_default_scheme"]?.string)
        XCTAssertEqual(MoodleSSO.launchURL(base: base + "/", passport: passport), l["url_default_scheme"]?.string)
    }

    /// Dieselbe Antwort mit einem anderen (alphanumerischen) Schluessel, signiert wie im Generator
    private func resigned(_ redirect: String, token: String, privateToken: String?) -> String? {
        guard let r = redirect.range(of: "token=") else { return nil }
        var raw = String(redirect[r.upperBound...]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw += "=" }
        guard let data = Data(base64Encoded: raw), let text = String(data: data, encoding: .utf8) else { return nil }
        let sig = text.components(separatedBy: ":::")[0]
        let plain = sig + ":::" + token + (privateToken.map { ":::" + $0 } ?? "")
        return "uniflow://token=" + Data(plain.utf8).base64EncodedString()
    }

    func testTokenCasesLikePython() throws {
        let fx = try fixture()
        let base = try XCTUnwrap(fx["launch"]?["base"]?.string), passport = try XCTUnwrap(fx["launch"]?["passport"]?.string)
        let cases = fx["token_cases"]?.array ?? []
        XCTAssertEqual(cases.count, 8)
        // erwartete Abweichungen: nicht alphanumerische Schluessel der Fixture
        let notAlnum: Set<String> = ["gueltig mit privatem Schluessel", "gueltig ohne privaten Schluessel", "Schluessel mit URL-sicherem Base64"]
        for c in cases {
            let name = c["name"]?.string ?? "", redirect = c["redirect"]?.string ?? ""
            let got = MoodleSSO.parseLaunchToken(redirect, base: base, passport: passport)
            let expect = c["expect"]
            guard let expect, !expect.isNull else {
                XCTAssertNil(got, name)
                XCTAssertNil(MoodleSSO.parseLaunchToken(redirect, base: base, passport: passport, scheme: "uniflow"), name)
                continue
            }
            let token = try XCTUnwrap(expect["token"]?.string)
            let priv = expect["private_token"]?.string
            if notAlnum.contains(name) {
                XCTAssertFalse(LearnwebToken.isAlnum(token, 1...256), "\(name): Abweichung gilt nur fuer Sonderzeichen")
                XCTAssertNil(got, "\(name): Schluessel mit Sonderzeichen nimmt das iPad nicht an")
                // dieselbe Signatur mit einem Schluessel aus Moodle (alphanumerisch): wie Python
                let t2 = token.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }, p2 = priv?.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                let again = try XCTUnwrap(resigned(redirect, token: t2, privateToken: p2), name)
                let ok = MoodleSSO.parseLaunchToken(again, base: base, passport: passport, scheme: "uniflow")
                XCTAssertEqual(ok?.token, t2, name)
                XCTAssertEqual(ok?.privateToken, p2.flatMap { $0.isEmpty ? nil : $0 }, name)
                // fremder Passport mit derselben Antwort: abgelehnt
                XCTAssertNil(MoodleSSO.parseLaunchToken(again, base: base, passport: passport + "x"), name)
            } else {
                XCTAssertEqual(got?.token, token, name)
                XCTAssertEqual(got?.privateToken, priv, name)
            }
        }
        // Generatorfehler: die Adresse des Falls mit URL-sicherem Base64 hat kein "://" mehr
        let urlSafe = cases.first { $0["name"]?.string == "Schluessel mit URL-sicherem Base64" }?["redirect"]?.string ?? ""
        XCTAssertTrue(urlSafe.hasPrefix("uniflow:__token="), urlSafe)
        XCTAssertFalse(MoodleSSO.isTokenRedirect(urlSafe, scheme: "uniflow"))
    }

    // MARK: Download mit Schluessel

    func testDownloadWithTokenKeepsTokenInBody() async throws {
        let fx = try fixture()
        let d = try XCTUnwrap(fx["download_with_token"])
        let url = try XCTUnwrap(d["url"]?.string)
        XCTAssertEqual(d["request"]?["url"]?.string, url, "Adresse unveraendert")
        XCTAssertEqual(d["request"]?["method"]?.string, "POST")
        XCTAssertEqual(d["request"]?["form"]?.object?.keys.sorted(), ["token"])
        XCTAssertEqual(d["request"]?["form"]?["token"]?.string, d["token"]?.string)
        // Schluessel der Fixture ("tok-123") ist nicht alphanumerisch: derselbe Ablauf mit einem Schluessel aus Moodle
        let token = try XCTUnwrap(LearnwebToken("tok123"))
        let base = try XCTUnwrap(fx["profiles"]?["hildesheim"]?["learnweb_base"]?.string)
        let api = LearnwebAPI(base: base, mode: .token(token), transport: FakeUniTransport())
        let r = try await api.downloadRequest(Learnweb.File(id: "lw-21-x", name: "Blatt 1.pdf", size: 0, mime: nil, chdate: 1,
                                                            downloadURL: url, folder: ""))
        XCTAssertEqual(r.url.absoluteString, url)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(r.body.map { String(decoding: $0, as: UTF8.self) }, "token=tok123")
        XCTAssertFalse(r.url.absoluteString.contains("tok123"))
    }

    // MARK: Anmeldeseite statt Datei

    func testHTMLInsteadOfFile() throws {
        let fx = try fixture()
        let cases = fx["html_instead_of_file"]?["cases"]?.array ?? []
        XCTAssertEqual(cases.count, 4)
        for (i, c) in cases.enumerated() {
            let body = Data((c["body_start"]?.string ?? "").utf8)
            let ctype = c["content_type"]?.string ?? ""
            let expect = c["html"]?.bool ?? false
            let device = UniStore.startsLikeWebPage(body)
            if ctype.hasPrefix("text/html") && !device {
                // Abweichung: das iPad entscheidet nach dem Inhalt (wie studip_sync._stream_once), nicht nach dem Typ
                XCTAssertTrue(expect, "Fall \(i)")
            } else {
                XCTAssertEqual(device, expect, "Fall \(i): \(ctype)")
            }
        }
        // die Abweichung gibt es wirklich (sonst diesen Zweig entfernen)
        XCTAssertTrue(cases.contains { ($0["content_type"]?.string ?? "").hasPrefix("text/html") && !UniStore.startsLikeWebPage(Data(($0["body_start"]?.string ?? "").utf8)) })
    }
}
