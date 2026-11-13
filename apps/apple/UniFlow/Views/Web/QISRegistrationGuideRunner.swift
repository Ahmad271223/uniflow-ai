import SwiftUI
import UniFlowCore
import WebKit

// "Im QIS zur Prüfung anmelden" fuehrt direkt zum Modul (Wunsch des Inhabers 13.11.2026). Der In-App-Browser
// (`UniWebPage`) geht den Weg im QIS wie ein Mensch: "Mein Studium" -> "Prüfungsanmeldung/-abmeldung" -> Anmeldebaum,
// klappt die Zweige bis zum Modul auf und markiert die Zeile. Welcher Link als Naechstes kommt, entscheidet der Kern
// (`QISRegistrationGuide`); hier wird nur geladen (GET) und markiert.
//
// Harte Regel: Die App tippt nie auf Anmelden, Abmelden oder Logout und sendet kein Formular. Anmeldung beim QIS,
// Hinweise bestaetigen und "Prüfung anmelden" tut der Mensch; danach geht der Weg von selbst weiter (Anmeldung,
// Hinweise) bzw. haelt an (sobald der Mensch selbst navigiert). Gelesen wird nur die Struktur der Seite, nichts
// gespeichert (kein asi, keine Namen, keine Matrikelnummer).

/// Uebergabe vom Knopf an den Browser: welche Pruefungen zu suchen sind (der Knopf oeffnet die Adresse ueber `openURL`)
@MainActor
enum QISGuideRequests {
    struct Request {
        let url: URL
        let targets: [QISRegistrationTarget]
        let first: Int
        let at: Date
    }

    private(set) static var pending: Request?

    static func set(url: URL, targets: [QISRegistrationTarget], first: Int = 0, now: Date = Date()) {
        pending = targets.isEmpty ? nil : Request(url: url, targets: targets, first: min(max(0, first), targets.count - 1), at: now)
    }

    /// Fuer genau diese Adresse und nur kurz nach dem Tippen (sonst oeffnete ein spaeterer QIS-Link noch die Suche)
    static func take(for url: URL, now: Date = Date()) -> Request? {
        defer { pending = nil }
        guard let r = pending, r.url == url, now.timeIntervalSince(r.at) < 10 else { return nil }
        return r
    }
}

/// Weg zum Modul in einem In-App-Browser
@MainActor
final class QISRegistrationGuideRunner: ObservableObject {
    enum Status: Equatable {
        case searching
        /// markiert (Text der Zeile)
        case found(String)
        /// Anmeldeseite des QIS: der Mensch meldet sich an
        case login
        /// Hinweise der Pruefungsanmeldung: der Mensch bestaetigt
        case confirm
        case notFound
        case unknown
        /// der Mensch navigiert selbst
        case paused
    }

    static let world = WKContentWorld.world(name: "uniflow-qis-guide")

    @Published private(set) var status: Status = .searching
    @Published private(set) var current: Int
    let targets: [QISRegistrationTarget]
    /// Einstieg ("Mein Studium" ohne asi, `qis_url`): jede Suche beginnt hier frisch
    let entry: URL
    weak var page: UniWebPage?
    private var progress = QISRegistrationGuide.Progress()
    /// Tests: statt zu laden die Adressen sammeln
    var loader: ((URL) -> Void)?

    init(targets: [QISRegistrationTarget], entry: URL, first: Int = 0) {
        self.targets = targets
        self.entry = entry
        current = targets.isEmpty ? 0 : min(max(0, first), targets.count - 1)
    }

    var target: QISRegistrationTarget? { targets.indices.contains(current) ? targets[current] : nil }

    /// Suche (neu) beginnen: frisch ab "Mein Studium", mit den Links der aktuellen Sitzung. So geht nach einer
    /// Anmeldung auch das naechste Modul, ohne das QIS zu verlassen (Fehler des Inhabers 13.11.2026: mit dem
    /// Zurueck-Knopf landete man auf alten Seiten der Anmeldung, und nur das eine Modul ging).
    func start(_ index: Int? = nil) {
        if let index, targets.indices.contains(index) { current = index }
        progress = QISRegistrationGuide.Progress()
        status = target == nil ? .unknown : .searching
        if target != nil { load(entry) }
    }

    private func load(_ url: URL) {
        if let loader { loader(url) } else { page?.open(url) }
    }

    /// Navigation des Hauptrahmens: tippt der Mensch selbst (Link, Formular, Zurueck/Vor, Neu laden), haelt die Suche
    /// an; nur Anmeldung und Hinweise (der Mensch soll dort tippen) setzen danach fort
    func navigation(_ type: WKNavigationType) {
        guard type != .other else { return }
        switch status {
        case .searching, .found, .notFound, .unknown: status = .paused
        case .login, .confirm, .paused: break
        }
    }

    /// Seite fertig geladen (nur QIS): naechsten Schritt bestimmen
    func pageFinished(url: URL, html: String) {
        guard let target, [.searching, .login, .confirm].contains(status) else { return }
        switch QISRegistrationGuide.step(html: html, url: url, target: target, progress: &progress) {
        case .follow(let next):
            status = .searching
            load(next)
        case .highlight(let h):
            status = .found(h.text)
            Task { _ = await page?.highlight(h) }
        case .login: status = .login
        case .confirmNotice: status = .confirm
        case .notFound: status = .notFound
        case .unknown: status = .unknown
        }
    }

    /// Text der Leiste unter dem Browser (einfache Sprache)
    static func text(_ status: Status, title: String) -> String {
        switch status {
        case .searching: return "Suche „\(title)“ in der Prüfungsanmeldung …"
        case .found(let row):
            return "„\(row)“ ist markiert. Tippe dort selbst auf „Prüfung anmelden“ und bestätige. StudiNow meldet nichts für dich an."
        case .login: return "Bitte melde dich im QIS an (iPadOS schlägt dein gespeichertes Passwort über der Tastatur vor). Danach geht es von selbst weiter zu „\(title)“."
        case .confirm: return "Bitte lies die Hinweise und bestätige sie selbst. Danach sucht StudiNow „\(title)“ weiter."
        case .notFound: return "„\(title)“ steht nicht im Anmeldebaum. Vielleicht heißt die Prüfung im QIS anders oder ist noch nicht freigeschaltet. Klappe den Baum bitte selbst auf."
        case .unknown: return "Diese Seite kennt StudiNow nicht. Du kannst selbst weitergehen oder neu suchen."
        case .paused: return "Du bist selbst im QIS unterwegs. „Neu suchen“ bringt dich wieder zu „\(title)“."
        }
    }

    /// Einzige Stelle mit Seitenskript fuer den Weg (UniversityLoginPolicyTests): nur Rahmen/Farbe setzen und scrollen,
    /// eigene Inhaltswelt, Werte nur als Argumente; kein Klick, kein Wert, kein Formular, kein Kanal zur App
    static func mark(_ h: QISRegistrationGuide.Highlight, in webView: WKWebView) async -> Bool {
        let r = try? await webView.callAsyncJavaScript(highlightScript, arguments: ["addr": h.address, "text": h.text],
                                                       in: nil, contentWorld: world)
        return r as? Bool ?? false
    }

    /// Markiert den Link (bzw. seine Zeile im Baum) und scrollt ihn in die Mitte; klickt nichts. Vergleich der Adresse
    /// ohne asi/jsessionid/Anker, Parameter sortiert; sonst ueber den Text.
    static let highlightScript = """
        function norm(h) {
          try {
            var u = new URL(h, location.href); u.hash = '';
            var ps = [];
            u.searchParams.forEach(function (v, k) { k = k.toLowerCase(); if (k !== 'asi' && k !== 'jsessionid') ps.push(k + '=' + v); });
            ps.sort();
            return u.origin + u.pathname + '?' + ps.join('&');
          } catch (e) { return ''; }
        }
        var want = norm(addr), hit = null, as = document.querySelectorAll('a[href]');
        for (var i = 0; i < as.length && !hit; i++) { if (norm(as[i].href) === want) hit = as[i]; }
        for (var j = 0; j < as.length && !hit; j++) { if (as[j].textContent.replace(/\\s+/g, ' ').trim() === text) hit = as[j]; }
        if (!hit) return false;
        var box = hit.closest('li') || hit.closest('tr') || hit;
        box.style.outline = '3px solid #E8A33D';
        box.style.outlineOffset = '2px';
        box.style.background = 'rgba(232, 163, 61, 0.18)';
        box.style.borderRadius = '6px';
        box.scrollIntoView({ block: 'center' });
        return true;
        """
}

/// Leiste unter dem Browser: Stand der Suche, "Neu suchen", "Andere Prüfung"
struct QISGuideBar: View {
    @ObservedObject var guide: QISRegistrationGuideRunner

    var body: some View {
        if let target = guide.target {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    if guide.status == .searching { ProgressView().controlSize(.small) }
                    Text(QISRegistrationGuideRunner.text(guide.status, title: target.title))
                        .ufFont(13.12, 600).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("qisguide.status")
                }
                HStack(spacing: 8) {
                    UFButton("Neu suchen", icon: "sync", size: .small) { guide.start() }
                        .accessibilityIdentifier("qisguide.restart")
                    if guide.targets.count > 1 {
                        Menu {
                            ForEach(Array(guide.targets.enumerated()), id: \.offset) { i, t in
                                Button(t.title) { guide.start(i) }
                            }
                        } label: {
                            Text("Andere Prüfung").ufFont(13.12, 600)
                        }
                        .accessibilityIdentifier("qisguide.other")
                    }
                }
            }
            .padding(12.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UF.surface)
        }
    }
}
