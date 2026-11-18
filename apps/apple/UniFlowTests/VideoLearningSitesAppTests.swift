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

    // MARK: YouTube direkt (Auftrag 17.11.2026)

    private func yt(_ s: String, main: Bool = true) -> WebSideDecision { YouTubeSidePolicy.decide(URL(string: s), mainFrame: main) }

    func testYouTubePaneAllowsStartSearchWatchShortsChannelAndConsent() {
        XCTAssertEqual(YouTubeSidePolicy.start.absoluteString, "https://m.youtube.com/")
        XCTAssertEqual(YouTubeSidePolicy.decide(YouTubeSidePolicy.start, mainFrame: true), .allow)
        for inside in ["https://m.youtube.com/", "https://m.youtube.com/results?search_query=fourier+reihe",
                       "https://m.youtube.com/watch?v=dQw4w9WgXcQ", "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=90s",
                       "https://m.youtube.com/shorts/dQw4w9WgXcQ", "https://m.youtube.com/@3blue1brown",
                       "https://m.youtube.com/channel/UCYO_jab_esuFRV4b17AJtAw", "https://m.youtube.com/playlist?list=PL123",
                       "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtube.com/watch?v=dQw4w9WgXcQ",
                       "https://M.YouTube.com/feed/trending", "https://youtu.be/dQw4w9WgXcQ",
                       "https://consent.youtube.com/m?continue=https%3A%2F%2Fm.youtube.com%2F&gl=DE",
                       "https://consent.youtube.com/save", "about:blank"] {
            XCTAssertEqual(yt(inside), .allow, inside)
        }
    }

    func testYouTubePaneOpensEveryOtherSiteOutside() {
        for out in ["https://example.com/", "https://www.google.com/search?q=x", "https://de.wikipedia.org/wiki/Fourier-Reihe",
                    "https://policies.google.com/privacy", "https://support.google.com/youtube", "https://apps.apple.com/app/youtube/id544007664",
                    "https://music.youtube.com/", "https://studio.youtube.com/", "https://www.youtubekids.com/", "https://tv.youtube.com/",
                    "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", "https://googleads.g.doubleclick.net/aclk?x=1",
                    "mailto:info@example.org", "tel:+4951112345"] {
            let u = URL(string: out)!
            XCTAssertEqual(yt(out), .openOutside(u), out)
        }
        // YouTubes Weiterleitung zu einer fremden Seite (Link in einer Beschreibung): ausserhalb, nicht in der Spalte
        let redirect = "https://www.youtube.com/redirect?event=video_description&q=https%3A%2F%2Fexample.com%2F"
        XCTAssertEqual(yt(redirect), .openOutside(URL(string: redirect)!))
        // http nie in der Spalte
        XCTAssertEqual(yt("http://m.youtube.com/watch?v=dQw4w9WgXcQ"), .openOutside(URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!))
    }

    func testYouTubePaneRejectsLookalikeHostsAndUnsafeSchemes() {
        for trick in ["https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ", "https://evil-youtube.com/", "https://m.youtube.com.evil.example/",
                      "https://evilyoutube.com/", "https://youtube.com@evil.example/", "https://m.youtube.com:443@evil.example/watch",
                      "https://evil.example/?u=https://m.youtube.com/", "https://m.youtube.com./", "https://xn--yutube-cxa.com/",
                      "https://youtu.be.evil.example/dQw4w9WgXcQ", "https://consent.youtube.com.evil.example/"] {
            let d = yt(trick)
            XCTAssertNotEqual(d, .allow, trick)
            XCTAssertNotEqual(d, .signIn, trick)
            XCTAssertEqual(yt(trick, main: false), .cancel, "eingebettet: \(trick)")
            XCTAssertFalse(YouTubeSidePolicy.isResource(URL(string: trick)), trick)
        }
        for bad in ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>", "file:///etc/passwd", "blob:https://m.youtube.com/abc",
                    "vnd.youtube://watch?v=dQw4w9WgXcQ", "youtube://watch?v=dQw4w9WgXcQ", "itms-apps://apps.apple.com/app/id544007664",
                    "ftp://m.youtube.com/"] {
            XCTAssertEqual(yt(bad), .cancel, bad)
            XCTAssertEqual(yt(bad, main: false), .cancel, "eingebettet: \(bad)")
        }
        XCTAssertEqual(YouTubeSidePolicy.decide(nil, mainFrame: true), .cancel)
    }

    /// Anmelden mit dem Google-Konto: nie in der Spalte (die App sieht kein Passwort) - Hinweis statt Seite; versteckt
    /// eingebettet gar nicht
    func testYouTubePaneNeverLoadsGoogleSignIn() {
        for s in ["https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F",
                  "https://accounts.google.com/v3/signin/identifier?continue=x", "https://accounts.google.de/accounts/SetSID",
                  "https://accounts.youtube.com/accounts/CheckConnection", "https://myaccount.google.com/",
                  "https://m.youtube.com/signin?next=%2F", "https://www.youtube.com/signin_prompt?app=m", "http://accounts.google.com/"] {
            XCTAssertEqual(yt(s), .signIn, s)
            XCTAssertEqual(yt(s, main: false), .cancel, "eingebettet: \(s)")
            XCTAssertTrue(YouTubeSidePolicy.isSignIn(URL(string: s)!), s)
        }
        XCTAssertFalse(YouTubeSidePolicy.isSignIn(URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!))
        XCTAssertFalse(YouTubeSidePolicy.isSignIn(URL(string: "https://example.com/signin")!), "fremde Seite: ausserhalb, kein Hinweis")
        // die anderen Spalten kennen die Entscheidung nicht
        XCTAssertNotEqual(VideoSidePolicy.decide(URL(string: "https://accounts.google.com/"), mainFrame: true), .signIn)
    }

    /// Player, Einwilligung, Bilder, Videodaten und Werbung von YouTube/Google bleiben erlaubt (nichts wird ausgeblendet)
    func testYouTubePaneAllowsYouTubeFramesAndResources() {
        for sub in ["https://www.youtube.com/embed/dQw4w9WgXcQ", "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
                    "https://consent.youtube.com/m?continue=x", "https://rr3---sn-4g5e6nsz.googlevideo.com/videoplayback?x=1",
                    "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", "https://www.gstatic.com/youtube/img/x.png",
                    "https://yt3.ggpht.com/abc=s88", "https://googleads.g.doubleclick.net/pagead/id", "https://www.google.com/recaptcha/api2/anchor",
                    "https://tpc.googlesyndication.com/safeframe/1-0-40/html/container.html"] {
            XCTAssertEqual(yt(sub, main: false), .allow, sub)
            XCTAssertTrue(YouTubeSidePolicy.isResource(URL(string: sub)), sub)
        }
        XCTAssertEqual(yt("about:blank", main: false), .allow)
        XCTAssertEqual(yt("about:srcdoc", main: false), .allow)
        XCTAssertEqual(yt("https://example.com/frame", main: false), .cancel, "fremde Rahmen nicht laden")
        XCTAssertEqual(yt("http://www.youtube.com/embed/dQw4w9WgXcQ", main: false), .cancel, "nur https")
        XCTAssertFalse(YouTubeSidePolicy.isResource(URL(string: "http://i.ytimg.com/vi/x.jpg")))
        XCTAssertFalse(YouTubeSidePolicy.isResource(URL(string: "https://cdn.example.com/x.js")))
        XCTAssertFalse(YouTubeSidePolicy.isResource(nil))
    }

    /// "Zuletzt hier" geht auch fuer ein auf der YouTube-Seite angesehenes Video und oeffnet es wieder dort
    func testWatchedVideoIsRememberedAndReopensOnYouTube() throws {
        XCTAssertEqual(YouTubeSidePolicy.watchedVideo(URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ&pp=abc")),
                       VideoLink(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(YouTubeSidePolicy.watchedVideo(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s"))?.start, 90)
        for no in ["https://m.youtube.com/", "https://m.youtube.com/results?search_query=x", "https://m.youtube.com/shorts/dQw4w9WgXcQ",
                   "https://m.youtube.com/@kanal", "https://m.youtube.com/watch?v=kurz", "https://example.com/watch?v=dQw4w9WgXcQ",
                   "https://consent.youtube.com/watch?v=dQw4w9WgXcQ", "http://m.youtube.com/watch?v=dQw4w9WgXcQ",
                   "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ"] {
            XCTAssertNil(YouTubeSidePolicy.watchedVideo(URL(string: no)), no)
        }
        XCTAssertNil(YouTubeSidePolicy.watchedVideo(nil))

        let suite = "uniflow.tests.youtube.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        let v = VideoLink(videoID: "dQw4w9WgXcQ")
        DocumentVideoLinks.save(v, for: "f1", defaults: d, onYouTube: true)
        let r = try XCTUnwrap(DocumentVideoLinks.record("f1", defaults: d))
        XCTAssertEqual(r.onYouTube, true)
        XCTAssertEqual(WebSidePickerSection.lastItem(r, documentID: "f1", youTubeBrowse: true), .youTube(YouTubeVisit(documentID: "f1", video: v)))
        XCTAssertEqual(WebSidePickerSection.lastItem(r, documentID: "f1"), .video(v), "Schalter aus (Standard): eingebetteter Player")
        XCTAssertEqual(YouTubeVisit(documentID: "f1", video: v).startURL.absoluteString, "https://m.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeVisit(documentID: "f1").startURL, YouTubeSidePolicy.start)
        XCTAssertEqual(YouTubeSidePolicy.decide(YouTubeVisit(documentID: "f1", video: VideoLink(videoID: "dQw4w9WgXcQ", start: 90)).startURL,
                                                mainFrame: true), .allow)
        // eingefuegter Link (wie bisher): eingebetteter Player
        DocumentVideoLinks.save(v, for: "f1", defaults: d)
        let pasted = try XCTUnwrap(DocumentVideoLinks.record("f1", defaults: d))
        XCTAssertNil(pasted.onYouTube)
        XCTAssertEqual(WebSidePickerSection.lastItem(pasted, documentID: "f1"), .video(v))
        // Stand vor dem 17.11.2026 (ohne das Feld) bleibt lesbar
        d.set(Data(#"{"version":1,"link":{"videoID":"dQw4w9WgXcQ","start":30},"marks":[]}"#.utf8), forKey: DocumentVideoLinks.key("f2"))
        XCTAssertEqual(DocumentVideoLinks.load("f2", defaults: d), VideoLink(videoID: "dQw4w9WgXcQ", start: 30))
        XCTAssertNotEqual(WebSideItem.youTube(YouTubeVisit(documentID: "f1")).id, WebSideItem.video(v).id)
    }

    /// Hinweis vor dem ersten Oeffnen: Entscheidung gemerkt (je Container), Text nennt Google und die Uebertragung
    func testYouTubeNoticeIsShownOnceAndSaysWhatHappens() throws {
        let suite = "uniflow.tests.youtube.notice.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(YouTubeNotice.accepted(defaults: d))
        XCTAssertFalse(YouTubeNotice.accepted(defaults: nil))
        YouTubeNotice.accept(defaults: d)
        XCTAssertTrue(YouTubeNotice.accepted(defaults: d))
        YouTubeNotice.reset(defaults: d)
        XCTAssertFalse(YouTubeNotice.accepted(defaults: d))
        XCTAssertTrue(YouTubeNotice.text.contains("Google") && YouTubeNotice.text.contains("übertragen") && YouTubeNotice.text.contains("Cookies"))
        XCTAssertTrue(YouTubeNotice.detail.contains("Anmelden"))
    }

    /// Web-Ansicht der YouTube-Spalte: mobile Seite, Abspielen in der Seite (kein erzwungenes Vollbild), Bild-in-Bild und
    /// Vollbild moeglich, kein Skript der App, eigener Speicher; "YouTube-Daten löschen" trifft nur YouTube/Google
    func testYouTubeWebViewPlaysInlineWithoutAppScripts() {
        let store = WKWebsiteDataStore.nonPersistent()
        let c = WebSideWebView.configuration(dataStore: store, mobile: true)
        XCTAssertTrue(c.websiteDataStore === store)
        XCTAssertTrue(c.allowsInlineMediaPlayback)
        XCTAssertTrue(c.allowsPictureInPictureMediaPlayback)
        XCTAssertTrue(c.preferences.isElementFullscreenEnabled)
        XCTAssertEqual(c.defaultWebpagePreferences.preferredContentMode, .mobile)
        XCTAssertTrue(c.userContentController.userScripts.isEmpty)
        XCTAssertFalse(c.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertEqual(WebSideWebView.configuration(dataStore: store).defaultWebpagePreferences.preferredContentMode, .recommended,
                       "Lernseiten wie bisher")
        for name in ["youtube.com", "google.com", "googlevideo.com", "ytimg.com", "YouTube.com", "doubleclick.net", "youtu.be"] {
            XCTAssertTrue(WebSideStore.isYouTubeData(name), name)
        }
        for name in ["wikipedia.org", "duden.de", "uni-hannover.de", "notyoutube.com", "youtube.com.evil.example", ""] {
            XCTAssertFalse(WebSideStore.isYouTubeData(name), name)
        }
        XCTAssertEqual(YouTubeSidePane.outsideURL(current: URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")).absoluteString,
                       "https://m.youtube.com/watch?v=dQw4w9WgXcQ")
        for other in ["https://consent.youtube.com/m?continue=x", "https://example.com/", "https://accounts.google.com/"] {
            XCTAssertEqual(YouTubeSidePane.outsideURL(current: URL(string: other)).absoluteString, "https://www.youtube.com/", other)
        }
        XCTAssertEqual(YouTubeSidePane.outsideURL(current: nil).absoluteString, "https://www.youtube.com/")
    }

    /// iPhone (Auftrag 17.11.2026 "auch iPhone und macOS"): Video bzw. Seite ueber dem Dokument; Texte sprechen dort
    /// nicht vom Schreiben und nicht von "daneben"; die Teilung laesst das Dokument nie verschwinden
    func testPhoneWordingAndSplitAboveReader() {
        for on in [false, true] {
            XCTAssertTrue(WebSidePickerSection.videoIntro(readerOnly: false, youTubeBrowse: on).contains("schreib im Dokument mit"))
            XCTAssertFalse(WebSidePickerSection.videoIntro(readerOnly: true, youTubeBrowse: on).contains("schreib"))
            XCTAssertTrue(WebSidePickerSection.videoIntro(readerOnly: true, youTubeBrowse: on).contains("über dem Dokument"))
        }
        XCTAssertEqual(WebSidePickerSection.openLabel(readerOnly: false), "Daneben öffnen")
        XCTAssertEqual(WebSidePickerSection.openLabel(readerOnly: true), "Öffnen")
        XCTAssertEqual(WebSideOverReaderLayout.clamp(WebSideOverReaderLayout.start), WebSideOverReaderLayout.start)
        XCTAssertEqual(WebSideOverReaderLayout.clamp(0), 0.3)
        XCTAssertEqual(WebSideOverReaderLayout.clamp(1), 0.78)
    }

    // MARK: Schalter "YouTube öffnen" (18.11.2026)

    /// Entscheidung des Inhabers 18.11.2026: "YouTube öffnen" nicht in 1.0.6. Standard aus; kein Weg fuehrt auf die
    /// YouTube-Seite - auch kein gespeicherter Stand aus der Testfassung ("Zuletzt hier" mit `onYouTube`). Daraus wird
    /// der eingebettete Player mit demselben Video, ohne gueltiges Video nichts. Eingefuegter Link, Aufzeichnungen und
    /// Lernseiten bleiben unveraendert.
    func testYouTubeBrowseIsOffByDefaultAndNothingLeadsToTheYouTubePage() throws {
        XCTAssertFalse(YouTubeBrowse.enabled, "ausgeliefert: aus")
        let v = VideoLink(videoID: "dQw4w9WgXcQ", start: 90)
        XCTAssertEqual(WebSideItem.shown(.youTube(YouTubeVisit(documentID: "f1", video: v))), .video(v))
        XCTAssertNil(WebSideItem.shown(.youTube(YouTubeVisit(documentID: "f1"))), "YouTube-Startseite: nichts")
        XCTAssertNil(WebSideItem.shown(.youTube(YouTubeVisit(documentID: "f1", video: VideoLink(videoID: "kurz")))), "kein gültiges Video")
        XCTAssertEqual(WebSideItem.shown(.video(v)), .video(v))
        XCTAssertEqual(WebSideItem.shown(.site(wiki)), .site(wiki))
        XCTAssertEqual(WebSideItem.shown(.youTube(YouTubeVisit(documentID: "f1")), youTubeBrowse: true),
                       .youTube(YouTubeVisit(documentID: "f1")), "mit Schalter an wie am 17.11.2026")

        // gespeicherter Stand aus der Testfassung: auf der YouTube-Seite angesehen
        let suite = "uniflow.tests.youtube.aus.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        d.set(Data(#"{"version":1,"link":{"videoID":"dQw4w9WgXcQ","start":42},"marks":[],"onYouTube":true}"#.utf8),
              forKey: DocumentVideoLinks.key("f1"))
        let r = try XCTUnwrap(DocumentVideoLinks.record("f1", defaults: d))
        XCTAssertEqual(r.onYouTube, true)
        XCTAssertEqual(WebSidePickerSection.lastItem(r, documentID: "f1"), .video(VideoLink(videoID: "dQw4w9WgXcQ", start: 42)))
        d.set(Data(#"{"version":1,"link":{"videoID":"x","start":0},"marks":[],"onYouTube":true}"#.utf8), forKey: DocumentVideoLinks.key("f2"))
        XCTAssertNil(WebSidePickerSection.lastItem(try XCTUnwrap(DocumentVideoLinks.record("f2", defaults: d)), documentID: "f2"),
                     "ohne gültiges Video kein Eintrag „Zuletzt hier“")

        // Texte wie in 1.0.5: kein "Such dein Video bei YouTube"
        for reader in [false, true] {
            XCTAssertFalse(WebSidePickerSection.videoIntro(readerOnly: reader).contains("Such dein Video bei YouTube"))
            XCTAssertTrue(WebSidePickerSection.videoIntro(readerOnly: reader).contains("nur dieses eine Video"))
            XCTAssertTrue(WebSidePickerSection.videoIntro(readerOnly: reader, youTubeBrowse: true).contains("Such dein Video bei YouTube"))
        }
        XCTAssertEqual(WebSidePickerSection.videoIntro(readerOnly: false),
                       "Schau ein Video und schreib im Dokument mit. Es läuft nur dieses eine Video; Links daraus öffnen außerhalb der App.")

        // Start-Argument nur in Debug: ohne Argument bleibt der Standard
        let launch = try XCTUnwrap(UserDefaults(suiteName: suite + ".start"))
        addTeardownBlock { launch.removePersistentDomain(forName: suite + ".start") }
        defer { YouTubeBrowse.enabled = false }
        YouTubeBrowse.applyDebugLaunch(defaults: launch)
        XCTAssertFalse(YouTubeBrowse.enabled)
        launch.set(true, forKey: "UFYouTubeBrowse")
        YouTubeBrowse.applyDebugLaunch(defaults: launch)
        #if DEBUG
        XCTAssertTrue(YouTubeBrowse.enabled, "-UFYouTubeBrowse YES")
        #else
        XCTAssertFalse(YouTubeBrowse.enabled)
        #endif
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

    /// Vertragsdatei aus dem Repo; am Mac ("Designed for iPad", Sandbox ohne Zugriff auf den Repo-Ordner) die Kopie im
    /// Testbundle (project.yml, `ContainerTestBed.repoURL`) - nicht die der App, gegen die verglichen wird
    private func repoFile() throws -> Data {
        try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/learning-sites.json"))
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
    /// Format fuer "Zeit merken" (zweiter Schritt) schon da: Zeitmarken je Seite; alte Fassung (nur Link) lesbar;
    /// dasselbe Video behaelt seine Marken, ein anderes beginnt leer
    func testVideoRecordIsReadyForTimeMarks() throws {
        let suite = "uniflow.tests.video.marks.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        // erste Fassung: nur der Link
        d.set(try JSONEncoder().encode(VideoLink(videoID: "dQw4w9WgXcQ")), forKey: DocumentVideoLinks.key("f1"))
        XCTAssertEqual(DocumentVideoLinks.record("f1", defaults: d)?.link.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(DocumentVideoLinks.record("f1", defaults: d)?.marks, [])
        var r = try XCTUnwrap(DocumentVideoLinks.record("f1", defaults: d))
        r.marks = [.init(pageKey: "p2", seconds: 750)]
        d.set(try JSONEncoder().encode(r), forKey: DocumentVideoLinks.key("f1"))
        DocumentVideoLinks.save(VideoLink(videoID: "dQw4w9WgXcQ", start: 30), for: "f1", defaults: d)
        XCTAssertEqual(DocumentVideoLinks.record("f1", defaults: d)?.marks, [.init(pageKey: "p2", seconds: 750)], "dasselbe Video")
        XCTAssertEqual(DocumentVideoLinks.record("f1", defaults: d)?.link.start, 30)
        DocumentVideoLinks.save(VideoLink(videoID: "aqz-KE-bpKQ"), for: "f1", defaults: d)
        XCTAssertEqual(DocumentVideoLinks.record("f1", defaults: d)?.marks, [], "anderes Video: neue Marken")
        let json = String(decoding: try XCTUnwrap(d.data(forKey: DocumentVideoLinks.key("f1"))), as: UTF8.self)
        XCTAssertTrue(json.contains("\"version\":1") && json.contains("\"marks\""))
    }

    /// Free: Eintrag sichtbar mit Schloss "(ab Plus)" (oeffnet die Tarifwahl), Plus: ohne Schloss
    func testEntryIsLockedForFreeLikeSplitView() {
        let title = "Video oder Lernseite daneben …"
        XCTAssertEqual(UFFeatureMatrix.access(.splitView, plan: .free).isAllowed, false)
        XCTAssertTrue(DocumentView.lockedLabel(title, UFFeatureMatrix.access(.splitView, plan: .free)).contains("Plus"))
        XCTAssertEqual(DocumentView.lockedLabel(title, UFFeatureMatrix.access(.splitView, plan: .plus)), title)
    }

    /// Lernseiten gruppiert wie in der Auswahl; jede Seite der Liste landet in genau einer Gruppe
    func testPickerGroupsCoverEverySite() {
        let kinds = WebSidePickerSection.groups.map(\.kinds)
        for s in LearningSites.builtIn {
            XCTAssertEqual(kinds.filter { $0.contains(s.kind) }.count, 1, s.id)
        }
        XCTAssertEqual(WebSidePickerSection.lastSubtitle(VideoLink(videoID: "dQw4w9WgXcQ", start: 750)), "ab 12:30")
        XCTAssertEqual(WebSidePickerSection.lastSubtitle(VideoLink(videoID: "dQw4w9WgXcQ")), "von vorn")
    }
    /// Wikipedia (Entscheidung: von Anfang an dabei): Suche und Artikel bleiben in der Spalte, alles, was aus
    /// Wikipedia herausfuehrt (Einzelnachweise, Commons, Spenden, Schwesterprojekte), oeffnet ausserhalb der App
    func testWikipediaStaysWikipediaAndEverythingElseOpensOutside() throws {
        let s = try XCTUnwrap(LearningSites.builtIn.first { $0.id == "wikipedia-de" })
        for inside in ["https://de.m.wikipedia.org/wiki/Fourier-Transformation", "https://de.wikipedia.org/wiki/Spezial:Suche?search=Laplace",
                       "https://de.m.wikipedia.org/w/index.php?title=Signal&action=info"] {
            XCTAssertEqual(LearningSitePolicy.decide(URL(string: inside), mainFrame: true, site: s), .allow, inside)
        }
        for out in ["https://commons.wikimedia.org/wiki/File:X.png", "https://donate.wikimedia.org/", "https://de.wiktionary.org/wiki/Signal",
                    "https://en.wikipedia.org/wiki/Signal", "https://doi.org/10.1000/182", "https://www.ieee.org/"] {
            let u = URL(string: out)!
            XCTAssertEqual(LearningSitePolicy.decide(u, mainFrame: true, site: s), .openOutside(u), out)
            XCTAssertEqual(LearningSitePolicy.decide(u, mainFrame: false, site: s), .cancel, "eingebettet: \(out)")
        }
    }
}
