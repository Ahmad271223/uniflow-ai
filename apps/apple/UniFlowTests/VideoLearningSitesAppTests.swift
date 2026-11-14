import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Video und Lernseiten neben dem Dokument (docs/VIDEO-LERNSEITEN-2026-11-14.md): Entscheidung des Inhabers "nur
/// Lernseiten, kein freier Browser". Geprueft werden die Regeln, die das sicherstellen.
@MainActor
final class VideoLearningSitesAppTests: XCTestCase {

    // MARK: Video-Link

    func testRecognisesYouTubeLinksInAllCommonForms() {
        let id = "dQw4w9WgXcQ"
        for text in ["https://www.youtube.com/watch?v=\(id)", "youtube.com/watch?v=\(id)&list=PL123", "  https://youtu.be/\(id)\n",
                     "https://m.youtube.com/watch?v=\(id)", "https://www.youtube.com/shorts/\(id)", "https://www.youtube.com/live/\(id)",
                     "https://www.youtube-nocookie.com/embed/\(id)", "http://youtube.com/embed/\(id)?rel=0"] {
            XCTAssertEqual(VideoLink.parse(text)?.videoID, id, text)
        }
        XCTAssertEqual(VideoLink.parse("https://youtu.be/\(id)?t=90")?.start, 90)
        XCTAssertEqual(VideoLink.parse("https://www.youtube.com/watch?v=\(id)&t=1m30s")?.start, 90)
        XCTAssertEqual(VideoLink.parse("https://www.youtube.com/watch?v=\(id)&t=1h2m3s")?.start, 3723)
        XCTAssertEqual(VideoLink.parse("https://www.youtube.com/embed/\(id)?start=45")?.start, 45)
        XCTAssertEqual(VideoLink.parse("https://youtu.be/\(id)?t=quatsch")?.start, 0)
    }

    func testRejectsEverythingThatIsNotASingleVideo() {
        for text in ["", "hallo", "https://www.youtube.com/", "https://www.youtube.com/results?search_query=fourier",
                     "https://www.youtube.com/playlist?list=PL123", "https://www.youtube.com/@kanal", "https://www.youtube.com/watch?v=kurz",
                     "https://vimeo.com/123456", "https://example.com/watch?v=dQw4w9WgXcQ", "https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ",
                     "javascript:alert(1)", "ftp://youtu.be/dQw4w9WgXcQ"] {
            XCTAssertNil(VideoLink.parse(text), text)
        }
    }

    func testEmbedUsesOfficialPrivacyEnhancedPlayer() {
        let v = VideoLink(videoID: "dQw4w9WgXcQ", start: 90)
        let c = URLComponents(url: v.embedURL, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "www.youtube-nocookie.com")
        XCTAssertEqual(c.path, "/embed/dQw4w9WgXcQ")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["rel"], "0")
        XCTAssertEqual(q["playsinline"], "1")
        XCTAssertEqual(q["start"], "90")
        XCTAssertEqual(q["origin"], "https://studinow.app")
        XCTAssertTrue(v.playerHTML.contains(v.embedURL.absoluteString))
        XCTAssertFalse(v.playerHTML.contains("<script"), "kein Skript der App in der Player-Seite")
        XCTAssertEqual(v.watchURL.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90s")
    }

    // MARK: Sperre Video

    func testVideoPaneKeepsOnlyThePlayer() {
        let ok: WebSideDecision = .allow
        XCTAssertEqual(VideoSidePolicy.decide(VideoLink.playerPage, mainFrame: true), ok)
        XCTAssertEqual(VideoSidePolicy.decide(URL(string: "about:blank"), mainFrame: false), ok)
        XCTAssertEqual(VideoSidePolicy.decide(URL(string: "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?rel=0"), mainFrame: false), ok)
        XCTAssertEqual(VideoSidePolicy.decide(URL(string: "https://consent.youtube.com/m?continue=x"), mainFrame: false), ok)
        XCTAssertEqual(VideoSidePolicy.decide(URL(string: "https://googleads.g.doubleclick.net/pagead/x"), mainFrame: false), ok,
                       "Werbung von YouTube wird nicht ausgeblendet")
        // aus dem Video heraus: ausserhalb der App
        let watch = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        XCTAssertEqual(VideoSidePolicy.decide(watch, mainFrame: false), .openOutside(watch))
        XCTAssertEqual(VideoSidePolicy.decide(watch, mainFrame: true), .openOutside(watch))
        let home = URL(string: "https://www.youtube.com/")!
        XCTAssertEqual(VideoSidePolicy.decide(home, mainFrame: true), .openOutside(home))
        let other = URL(string: "https://example.com/")!
        XCTAssertEqual(VideoSidePolicy.decide(other, mainFrame: true), .openOutside(other))
        XCTAssertEqual(VideoSidePolicy.decide(other, mainFrame: false), .cancel, "fremde Rahmen im Player nicht laden")
        XCTAssertEqual(VideoSidePolicy.decide(URL(string: "javascript:alert(1)"), mainFrame: true), .cancel)
        XCTAssertEqual(VideoSidePolicy.decide(URL(string: "http://www.youtube-nocookie.com/embed/x"), mainFrame: false), .cancel, "nur https")
        XCTAssertEqual(VideoSidePolicy.decide(nil, mainFrame: true), .cancel)
    }

    // MARK: Sperre Lernseite

    private var wiki: LearningSite {
        LearningSite(id: "wikipedia-de", name: "Wikipedia", kind: "reference", university: nil,
                     start: URL(string: "https://de.m.wikipedia.org/")!, hosts: ["de.wikipedia.org", "de.m.wikipedia.org"])
    }

    func testLearningSiteStaysOnItsOwnHosts() {
        let s = wiki
        XCTAssertEqual(LearningSitePolicy.decide(URL(string: "https://de.m.wikipedia.org/wiki/Fourier-Reihe"), mainFrame: true, site: s), .allow)
        XCTAssertEqual(LearningSitePolicy.decide(URL(string: "https://de.wikipedia.org/w/index.php?search=Laplace"), mainFrame: true, site: s),
                       .allow, "Suche der Seite selbst bleibt auf der Seite")
        let outside = URL(string: "https://www.google.com/search?q=x")!
        XCTAssertEqual(LearningSitePolicy.decide(outside, mainFrame: true, site: s), .openOutside(outside))
        XCTAssertEqual(LearningSitePolicy.decide(outside, mainFrame: false, site: s), .cancel)
        for trick in ["https://de.wikipedia.org.evil.com/", "https://evilde.wikipedia.org.com/", "https://wikipedia.org/",
                      "https://en.wikipedia.org/wiki/X"] {
            XCTAssertNotEqual(LearningSitePolicy.decide(URL(string: trick), mainFrame: true, site: s), .allow, trick)
        }
        XCTAssertEqual(LearningSitePolicy.decide(URL(string: "http://de.wikipedia.org/wiki/X"), mainFrame: true, site: s),
                       .openOutside(URL(string: "https://de.wikipedia.org/wiki/X")!), "http nie in der Spalte")
        let mail = URL(string: "mailto:info@example.org")!
        XCTAssertEqual(LearningSitePolicy.decide(mail, mainFrame: true, site: s), .openOutside(mail))
        XCTAssertEqual(LearningSitePolicy.decide(URL(string: "file:///etc/passwd"), mainFrame: true, site: s), .cancel)
        XCTAssertEqual(LearningSitePolicy.decide(URL(string: "javascript:alert(1)"), mainFrame: true, site: s), .cancel)
    }

    // MARK: Liste

    private func repoFile() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../packages/shared-contracts/learning-sites.json").standardized
        return try Data(contentsOf: url)
    }

    func testBuiltInListIsTheSharedContractAndValid() throws {
        let fromRepo = try XCTUnwrap(LearningSites.decode(try repoFile()))
        XCTAssertEqual(LearningSites.builtIn, fromRepo, "Grundstock in der App = packages/shared-contracts/learning-sites.json")
        XCTAssertGreaterThanOrEqual(fromRepo.count, 8)
        XCTAssertTrue(fromRepo.allSatisfy(\.isValid))
        XCTAssertEqual(Set(fromRepo.map(\.id)).count, fromRepo.count, "Kennungen eindeutig")
        // keine Suchmaschinen, keine fremden KI-Dienste, keine Videoportale als Startseite
        let banned = ["google.", "bing.", "openai", "chatgpt", "deepseek", "deepl", "perplexity", "claude", "gemini", "youtube",
                      "duckduckgo", "translate."]
        for s in fromRepo {
            for h in s.hosts + [s.start.host ?? ""] {
                XCTAssertFalse(banned.contains { h.contains($0) }, "\(s.id): \(h)")
            }
        }
    }

    func testListPerUniversityAndRejectsBadEntries() throws {
        let luh = LearningSites.sites(for: .luh).map(\.id)
        XCTAssertEqual(Array(luh.prefix(2)), ["uni-luh", "tib"], "eigene Hochschule zuerst")
        XCTAssertFalse(luh.contains("uni-hildesheim") || luh.contains("hsh"))
        XCTAssertTrue(luh.contains("wikipedia-de"))
        let hi = LearningSites.sites(for: .hildesheim).map(\.id)
        XCTAssertTrue(hi.contains("uni-hildesheim") && !hi.contains("tib"))

        func list(_ site: String) -> Data { Data(#"{"version":1,"sites":[\#(site)]}"#.utf8) }
        let good = #"{"id":"a","name":"A","kind":"tool","start":"https://a.example.org/","hosts":["example.org"]}"#
        XCTAssertEqual(LearningSites.decode(list(good))?.count, 1)
        for bad in [#"{"id":"a","name":"A","kind":"tool","start":"https://a.example.org/","hosts":["*.example.org"]}"#,
                    #"{"id":"a","name":"A","kind":"tool","start":"http://a.example.org/","hosts":["example.org"]}"#,
                    #"{"id":"a","name":"A","kind":"tool","start":"https://other.org/","hosts":["example.org"]}"#,
                    #"{"id":"a","name":"A","kind":"tool","start":"https://a.example.org/","hosts":["https://example.org"]}"#,
                    #"{"id":"a","name":"A","kind":"tool","start":"https://a.example.org/","hosts":["org"]}"#,
                    #"{"id":"","name":"A","kind":"tool","start":"https://a.example.org/","hosts":["example.org"]}"#] {
            XCTAssertNil(LearningSites.decode(list(bad)), bad)
        }
        XCTAssertNil(LearningSites.decode(Data(#"{"version":2,"sites":[\#(good)]}"#.utf8)), "unbekannte Version")
        XCTAssertNil(LearningSites.decode(Data("kaputt".utf8)))
    }

    // MARK: Datenspeicher und Merken

    func testOwnDataStoreSeparateFromUniLogins() {
        let a = UUID(), b = UUID()
        let sa = WebSideStore.identifier(forContainer: a)
        XCTAssertEqual(sa, WebSideStore.identifier(forContainer: a), "fest je Container")
        XCTAssertNotEqual(sa, a, "nicht der Speicher der Hochschul-Anmeldung")
        XCTAssertNotEqual(sa, WebSideStore.identifier(forContainer: b))
        let store = WKWebsiteDataStore.nonPersistent()
        let config = WebSideWebView.configuration(dataStore: store)
        XCTAssertTrue(config.websiteDataStore === store)
        XCTAssertFalse(config.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(config.userContentController.userScripts.isEmpty, "kein Skript der App in Lernseiten")
        XCTAssertFalse(config.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(WebSideStore.dataStore(container: nil) === WebSideStore.dataStore(container: nil))
        XCTAssertFalse(WebSideStore.dataStore(container: nil).isPersistent, "ohne Container fluechtig")
    }

    func testVideoLinkRememberedPerDocumentOnDeviceOnly() throws {
        let suite = "uniflow.tests.video.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(DocumentVideoLinks.load("f1", defaults: d))
        DocumentVideoLinks.save(VideoLink(videoID: "dQw4w9WgXcQ", start: 30), for: "f1", defaults: d)
        XCTAssertEqual(DocumentVideoLinks.load("f1", defaults: d), VideoLink(videoID: "dQw4w9WgXcQ", start: 30))
        XCTAssertNil(DocumentVideoLinks.load("f2", defaults: d), "je Dokument")
        DocumentVideoLinks.save(nil, for: "f1", defaults: d)
        XCTAssertNil(DocumentVideoLinks.load("f1", defaults: d))
    }
}
