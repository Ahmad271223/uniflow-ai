import SwiftUI
import UIKit
import UniFlowCore
import WebKit

// Spalten "Video" und "Lernseite" neben dem Dokument (docs/VIDEO-LERNSEITEN-2026-11-14.md). Regeln: WebSideRules.swift.
// Vorlaeufige Oberflaeche (Grundlage); die Gestaltung folgt nach der Freigabe des Plans durch den Inhaber.

/// Was in der Spalte daneben steht (neben Blatt und Loesung)
enum WebSideItem: Equatable, Identifiable {
    case video(VideoLink)
    case site(LearningSite)

    var id: String {
        switch self {
        case .video(let v): return "video:" + v.videoID
        case .site(let s): return "site:" + s.id
        }
    }
}

/// Spalte "Video": ein YouTube-Video im offiziellen eingebetteten Player
struct VideoSidePane: View {
    let link: VideoLink
    let dataStore: WKWebsiteDataStore
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            UFPaneHeader("YouTube-Video", icon: "play", closeLabel: "Video schließen", closeID: "video.close", close: onClose) {
                Button { openURL(link.watchURL) } label: {
                    Image(systemName: "arrow.up.right.square").frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(UF.text2)
                .accessibilityLabel("Auf YouTube öffnen")
                .modifier(MacHelp(text: "Auf YouTube öffnen (außerhalb der App)"))
            }
            WebSideWebView(content: .html(link.playerHTML, base: VideoLink.playerPage), dataStore: dataStore,
                           decide: { url, main in VideoSidePolicy.decide(url, mainFrame: main) })
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
                .accessibilityIdentifier("video.player")
            Text("Video von YouTube. Links aus dem Video öffnen außerhalb der App.")
                .ufFont(12).foregroundStyle(UF.muted).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .background(UF.surface2)
    }
}

/// Spalte "Lernseite": eine Seite aus der festen Liste, ohne Adresszeile, Navigation auf ihre Hosts begrenzt
struct LearningSitePane: View {
    let site: LearningSite
    let dataStore: WKWebsiteDataStore
    let onClose: () -> Void
    @StateObject private var nav = WebSideNavigation()
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            UFPaneHeader(site.name, icon: "book", closeLabel: "Lernseite schließen", closeID: "site.close", close: onClose) {
                Button { nav.goBack() } label: { Image(systemName: "chevron.backward").frame(width: 30, height: 30).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(nav.canGoBack ? UF.text2 : UF.muted).disabled(!nav.canGoBack)
                    .accessibilityLabel("Zurück")
                Button { nav.load(site.start) } label: { Image(systemName: "house").frame(width: 30, height: 30).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(UF.text2)
                    .accessibilityLabel("Startseite der Lernseite")
                Button { openURL(nav.current ?? site.start) } label: {
                    Image(systemName: "safari").frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(UF.text2)
                .accessibilityLabel("In Safari öffnen")
            }
            WebSideWebView(content: .url(site.start), dataStore: dataStore, navigation: nav,
                           decide: { url, main in LearningSitePolicy.decide(url, mainFrame: main, site: site) })
                .accessibilityIdentifier("site.web")
        }
        .background(UF.surface)
    }
}

/// Zurueck, Startseite und aktuelle Adresse der Lernseite (fuer "In Safari öffnen")
@MainActor
final class WebSideNavigation: ObservableObject {
    @Published var canGoBack = false
    @Published var current: URL?
    weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func load(_ url: URL) { webView?.load(URLRequest(url: url)) }
}

/// WKWebView der Spalten: eigener Datenspeicher, keine Benutzerskripte, kein Nachrichtenkanal; jede Navigation geht
/// durch `decide` (WebSideRules); neue Fenster und Downloads oeffnen ausserhalb der App bzw. gar nicht.
struct WebSideWebView: UIViewRepresentable {
    enum Content: Equatable {
        case url(URL)
        case html(String, base: URL)
    }

    let content: Content
    let dataStore: WKWebsiteDataStore
    var navigation: WebSideNavigation? = nil
    let decide: (URL?, Bool) -> WebSideDecision

    static func configuration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.allowsInlineMediaPlayback = true
        c.allowsPictureInPictureMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = .all
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        return c
    }

    func makeCoordinator() -> Coordinator { Coordinator(decide: decide, navigation: navigation) }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: Self.configuration(dataStore: dataStore))
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        w.allowsLinkPreview = false
        w.isOpaque = false
        navigation?.webView = w
        context.coordinator.loaded = content
        switch content {
        case .url(let u): w.load(URLRequest(url: u))
        case .html(let h, let base): w.loadHTMLString(h, baseURL: base)
        }
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        context.coordinator.decide = decide
        guard context.coordinator.loaded != content else { return }
        context.coordinator.loaded = content
        switch content {
        case .url(let u): w.load(URLRequest(url: u))
        case .html(let h, let base): w.loadHTMLString(h, baseURL: base)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var decide: (URL?, Bool) -> WebSideDecision
        weak var navigation: WebSideNavigation?
        var loaded: Content?

        init(decide: @escaping (URL?, Bool) -> WebSideDecision, navigation: WebSideNavigation?) {
            self.decide = decide
            self.navigation = navigation
        }

        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // eigene Player-Seite (loadHTMLString): keine Anfrage ans Netz, darf immer
            if action.navigationType == .other, action.targetFrame?.isMainFrame == true,
               action.request.url == loaded.flatMap({ if case .html(_, let b) = $0 { return b } else { return nil } }) {
                decisionHandler(.allow)
                return
            }
            let main = action.targetFrame?.isMainFrame ?? true
            switch decide(action.request.url, main) {
            case .allow: decisionHandler(.allow)
            case .openOutside(let url):
                decisionHandler(.cancel)
                if action.navigationType == .linkActivated || main { UIApplication.shared.open(url) }
            case .cancel: decisionHandler(.cancel)
            }
        }

        /// Antworten, die WebKit nicht anzeigen kann (Downloads), nie in der App laden
        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .cancel)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.navigation?.canGoBack = webView.canGoBack
            self.navigation?.current = webView.url
        }

        /// target=_blank, window.open: nie ein neues Fenster in der App; erlaubte Seite ausserhalb oeffnen
        @MainActor
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, case .openOutside(let out) = WebSideHosts.outside(url) { UIApplication.shared.open(out) }
            return nil
        }
    }
}

/// Spalte daneben fuer ein Video oder eine Lernseite, mit dem eigenen Datenspeicher des Containers
struct WebSidePaneView: View {
    let item: WebSideItem
    let onClose: () -> Void

    var body: some View {
        switch item {
        case .video(let v): VideoSidePane(link: v, dataStore: WebSideStore.dataStore(), onClose: onClose)
        case .site(let s): LearningSitePane(site: s, dataStore: WebSideStore.dataStore(), onClose: onClose)
        }
    }
}

extension WebSideStore {
    @MainActor private static var cache: [UUID: WKWebsiteDataStore] = [:]
    @MainActor private static var ephemeral: WKWebsiteDataStore?

    /// Datenspeicher der Spalten im offenen Container; ohne Container (Tests) ein fluechtiger
    @MainActor
    static func dataStore(container: ActiveContainer? = ActiveContainer.current) -> WKWebsiteDataStore {
        guard let c = container else {
            if let e = ephemeral { return e }
            let e = WKWebsiteDataStore.nonPersistent()
            ephemeral = e
            return e
        }
        let id = identifier(forContainer: c.websiteDataStoreID)
        if let s = cache[id] { return s }
        let s = WKWebsiteDataStore(forIdentifier: id)
        cache[id] = s
        return s
    }

    /// Container geloescht: Daten der Spalten mit entfernen
    @MainActor
    static func remove(container id: UUID) async {
        let sid = identifier(forContainer: id)
        let store = cache.removeValue(forKey: sid) ?? WKWebsiteDataStore(forIdentifier: sid)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: sid)
    }
}

/// Abschnitte "Video" und "Lernseite" unter "Daneben öffnen" (vorlaeufig, Gestaltung nach Freigabe des Plans)
struct WebSidePickerSection: View {
    let documentID: String
    let onPick: (WebSideItem) -> Void
    @State private var link = ""
    @State private var problem: String?

    private var last: VideoLink? { DocumentVideoLinks.load(documentID, defaults: ActiveContainer.current?.defaults) }
    private var sites: [LearningSite] { LearningSites.sites(for: ActiveContainer.current?.key.university) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Video").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            Text("YouTube-Link einfügen. Es läuft nur dieses Video; Links daraus öffnen außerhalb der App.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                UFTextInput("youtube.com/watch?v=…", text: $link)
                    .accessibilityIdentifier("web.videoLink")
                UFButton("Öffnen", icon: "play", kind: .primary, size: .small) { openLink() }
                    .accessibilityIdentifier("web.videoOpen")
            }
            if let problem { Text(problem).ufFont(13.12).foregroundStyle(UF.bad) }
            if let last {
                Button { onPick(.video(last)) } label: {
                    Label("Zuletzt hier: YouTube-Video \(last.videoID)", systemImage: "clock.arrow.circlepath").ufFont(13.12, 600)
                }
                .buttonStyle(.plain).foregroundStyle(UF.accentText)
            }
            Text("Lernseite").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text).padding(.top, 8)
            Text("Nur diese Seiten, ohne Adresszeile. Links zu anderen Seiten öffnen außerhalb der App.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(sites) { s in
                    Button { onPick(.site(s)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: s.symbol).foregroundStyle(UF.accent).frame(width: 22)
                            Text(s.name).ufFont(13.6, 600).foregroundStyle(UF.text).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(UF.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UF.line, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("web.site.\(s.id)")
                }
            }
        }
    }

    private func openLink() {
        guard let v = VideoLink.parse(link) else { problem = VideoLink.rejectedText; return }
        problem = nil
        onPick(.video(v))
    }
}
