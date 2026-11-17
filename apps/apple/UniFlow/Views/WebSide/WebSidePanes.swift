import SwiftUI
import UIKit
import UniFlowCore
import WebKit

// Spalten "Video" und "Lernseite" neben dem Dokument (docs/VIDEO-LERNSEITEN-2026-11-14.md). Regeln: WebSideRules.swift.
// Vorlaeufige Oberflaeche (Grundlage); die Gestaltung folgt nach der Freigabe des Plans durch den Inhaber.

/// Was in der Spalte daneben steht (neben Blatt und Loesung)
enum WebSideItem: Equatable, Identifiable {
    case video(VideoLink)
    /// YouTube selbst (mobile Seite) zum Suchen und Ansehen, nur YouTube, ohne Adresszeile (Auftrag 17.11.2026)
    case youTube(YouTubeVisit)
    /// Vorlesungsaufzeichnung aus den eigenen Kursen (Opencast, eigener Player ohne Browser)
    case recording(OpencastEntry)
    case site(LearningSite)

    var id: String {
        switch self {
        case .video(let v): return "video:" + v.videoID
        case .youTube(let y): return "youtube:" + (y.video?.videoID ?? "start")
        case .recording(let e): return "recording:" + e.id
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
            VStack(alignment: .leading, spacing: 8) {
                if !UFEditorAvailability.readerOnly {
                    Label("Schreib im Dokument mit, während das Video läuft.", systemImage: "pencil.and.scribble")
                        .ufFont(13.12, 600).foregroundStyle(UF.text2)
                }
                Text("Video von YouTube im eingebetteten Player. Links aus dem Video, das YouTube-Logo und „Ansehen auf YouTube“ öffnen außerhalb der App.")
                    .ufFont(12.5).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .background(UF.surface2)
    }
}

/// Spalte "YouTube" (Auftrag 17.11.2026): die YouTube-Seite selbst zum Suchen und Ansehen. Zurueck, Vor, Neu laden und
/// Startseite im Kopf, keine Adresszeile; Navigation nur auf YouTube (`YouTubeSidePolicy`). Vor dem ersten Oeffnen der
/// Hinweis, dass Daten an Google gehen - erst danach entsteht die Web-Ansicht. Das Video spielt auf der YouTube-Seite
/// selbst; das zuletzt angesehene wird am Dokument gemerkt ("Zuletzt hier").
struct YouTubeSidePane: View {
    let visit: YouTubeVisit
    let dataStore: WKWebsiteDataStore
    let onClose: () -> Void
    @StateObject private var nav = WebSideNavigation()
    @State private var accepted = YouTubeNotice.accepted(defaults: YouTubeSidePane.defaults)
    /// nach "YouTube-Daten löschen": Web-Ansicht neu anlegen
    @State private var generation = 0
    @Environment(\.openURL) private var openURL

    /// Einstellungen des offenen Containers (Hinweis gesehen, zuletzt angesehenes Video); nur auf dem Geraet
    static var defaults: UserDefaults { ActiveContainer.current?.defaults ?? .standard }

    /// Adresse fuer "Auf YouTube öffnen (außerhalb der App)": die gerade offene YouTube-Seite, sonst die Startseite
    static func outsideURL(current: URL?) -> URL {
        if let current, current.host != "consent.youtube.com", YouTubeSidePolicy.decide(current, mainFrame: true) == .allow { return current }
        return URL(string: "https://www.youtube.com/")!
    }

    var body: some View {
        VStack(spacing: 0) {
            UFPaneHeader("YouTube", icon: "play", closeLabel: "YouTube schließen", closeID: "youtube.close", close: onClose) {
                if accepted { controls }
            }
            if accepted { web } else { notice }
        }
        .background(UF.surface)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            headerButton("chevron.backward", "Zurück", "youtube.back", enabled: nav.canGoBack) { nav.goBack() }
            headerButton("chevron.forward", "Vor", "youtube.forward", enabled: nav.canGoForward) { nav.goForward() }
            headerButton("arrow.clockwise", "Neu laden", "youtube.reload") { nav.reload(fallback: visit.startURL) }
            headerButton("house", "Startseite von YouTube", "youtube.home") { nav.load(YouTubeSidePolicy.start) }
            Menu {
                Button { openURL(Self.outsideURL(current: nav.current)) } label: {
                    Label("Auf YouTube öffnen (außerhalb der App)", systemImage: "arrow.up.right.square")
                }
                Button(role: .destructive) { clearData() } label: { Label("YouTube-Daten löschen", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .foregroundStyle(UF.text2)
            .accessibilityLabel("Mehr zu YouTube")
            .accessibilityIdentifier("youtube.more")
        }
    }

    private func headerButton(_ symbol: String, _ label: String, _ id: String, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 32, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(enabled ? UF.text2 : UF.muted.opacity(0.55)).disabled(!enabled)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            .modifier(MacHelp(text: label))
    }

    private var web: some View {
        ZStack(alignment: .bottom) {
            WebSideWebView(content: .url(visit.startURL), dataStore: dataStore, navigation: nav, mobile: true, newWindowsInPlace: true,
                           decide: { url, main in YouTubeSidePolicy.decide(url, mainFrame: main) })
                .id(generation)
                .accessibilityIdentifier("youtube.web")
            if let problem = nav.problem {
                VStack(spacing: 12) {
                    Text(problem).ufFont(14.5, 600).foregroundStyle(UF.text).multilineTextAlignment(.center)
                    UFButton("Noch mal versuchen", icon: "refresh", kind: .primary, size: .small) { nav.reload(fallback: visit.startURL) }
                        .accessibilityIdentifier("youtube.retry")
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(UF.surface)
            }
            if nav.signInBlocked { signInNotice }
        }
        .overlay(alignment: .top) {
            if nav.isLoading { ProgressView().progressViewStyle(.linear).tint(UF.accent).frame(height: 2) }
        }
        .onChange(of: nav.current) { _, url in remember(url) }
    }

    /// Anmelden angetippt: nichts geladen, kurzer Hinweis unten in der Spalte
    private var signInNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Anmelden geht hier nicht").ufFont(14.5, 650).foregroundStyle(UF.text)
            Text("Du kannst YouTube hier ohne Anmeldung nutzen. Mit deinem Google-Konto öffnest du YouTube außerhalb der App.")
                .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                UFButton("OK", kind: .primary, size: .small) { nav.signInBlocked = false }
                    .accessibilityIdentifier("youtube.signInOK")
                UFButton("Außerhalb öffnen", size: .small) {
                    nav.signInBlocked = false
                    openURL(Self.outsideURL(current: nav.current))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UF.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UF.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("youtube.signInNotice")
    }

    /// Hinweis vor dem ersten Oeffnen: solange er steht, gibt es keine Web-Ansicht (nichts geht an YouTube)
    private var notice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(YouTubeNotice.title).ufFont(17, 650, em: -0.01).foregroundStyle(UF.text)
                Text(YouTubeNotice.text).ufFont(14.5).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                Text(YouTubeNotice.detail).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    UFButton("Öffnen", icon: "play", kind: .primary) {
                        YouTubeNotice.accept(defaults: Self.defaults)
                        accepted = true
                    }
                    .accessibilityIdentifier("youtube.noticeOpen")
                    UFButton("Abbrechen", action: onClose)
                        .accessibilityIdentifier("youtube.noticeCancel")
                }
                .padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: 460, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("youtube.notice")
    }

    /// Video auf der YouTube-Seite geoeffnet: am Dokument merken (nur auf dem Geraet)
    private func remember(_ url: URL?) {
        guard let v = YouTubeSidePolicy.watchedVideo(url) else { return }
        DocumentVideoLinks.save(v, for: visit.documentID, defaults: ActiveContainer.current?.defaults, onYouTube: true)
    }

    private func clearData() {
        Task {
            await WebSideStore.removeYouTubeData(from: dataStore)
            nav.problem = nil
            nav.signInBlocked = false
            generation += 1
        }
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

/// Zurueck, Vor, Neu laden, Startseite und aktuelle Adresse der Spalte (fuer "In Safari öffnen" und "Zuletzt hier")
@MainActor
final class WebSideNavigation: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var current: URL?
    @Published var isLoading = false
    /// Seite liess sich nicht laden (kein Netz); Text fuer den Hinweis in der Spalte
    @Published var problem: String?
    /// Anmelden wurde angetippt und nicht geladen (`WebSideDecision.signIn`)
    @Published var signInBlocked = false
    weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func load(_ url: URL) { problem = nil; webView?.load(URLRequest(url: url)) }
    /// Neu laden; nach einem Fehler ohne geladene Seite die Startadresse
    func reload(fallback: URL) {
        problem = nil
        if let w = webView, w.url != nil { w.reload() } else { load(fallback) }
    }

    /// Stand der Web-Ansicht uebernehmen. YouTube wechselt Seiten ohne neues Laden (Suche, Video): deshalb beobachtet,
    /// nicht nur nach dem Laden gelesen.
    func sync(from w: WKWebView) {
        if canGoBack != w.canGoBack { canGoBack = w.canGoBack }
        if canGoForward != w.canGoForward { canGoForward = w.canGoForward }
        if current != w.url { current = w.url }
        if isLoading != w.isLoading { isLoading = w.isLoading }
    }
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
    /// mobile Fassung der Seite anfordern (YouTube in der schmalen Spalte; das iPad fragt sonst wie ein Mac)
    var mobile = false
    /// neue Fenster (target=_blank), die `decide` erlaubt, in derselben Spalte laden statt ausserhalb (YouTube)
    var newWindowsInPlace = false
    let decide: (URL?, Bool) -> WebSideDecision

    /// Video laeuft in der Spalte weiter, waehrend man im Dokument schreibt: Abspielen in der Seite (kein erzwungenes
    /// Vollbild), Bild-in-Bild erlaubt, Vollbild auf Wunsch ueber den Knopf des Players. Abspielen beginnt nur nach
    /// einem Antippen. Ton bei geschlossener App: nein (die App hat dafuer keine Hintergrund-Freigabe).
    static func configuration(dataStore: WKWebsiteDataStore, mobile: Bool = false) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.allowsInlineMediaPlayback = true
        c.allowsPictureInPictureMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = .all
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.isElementFullscreenEnabled = true
        if mobile { c.defaultWebpagePreferences.preferredContentMode = .mobile }
        return c
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(decide: decide, navigation: navigation, newWindowsInPlace: newWindowsInPlace)
    }

    static func dismantleUIView(_ w: WKWebView, coordinator: Coordinator) {
        coordinator.observations = []
        w.stopLoading()
    }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: Self.configuration(dataStore: dataStore, mobile: mobile))
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        w.allowsLinkPreview = false
        w.isOpaque = false
        navigation?.webView = w
        context.coordinator.observe(w)
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
        let newWindowsInPlace: Bool
        var observations: [NSKeyValueObservation] = []

        init(decide: @escaping (URL?, Bool) -> WebSideDecision, navigation: WebSideNavigation?, newWindowsInPlace: Bool = false) {
            self.decide = decide
            self.navigation = navigation
            self.newWindowsInPlace = newWindowsInPlace
        }

        /// Adresse, Zurueck/Vor und Laden beobachten (Seiten, die ohne neues Laden wechseln, melden sonst nichts)
        @MainActor
        func observe(_ w: WKWebView) {
            guard navigation != nil else { return }
            let sync: @Sendable (WKWebView) -> Void = { [weak self] w in
                Task { @MainActor in self?.navigation?.sync(from: w) }
            }
            observations = [w.observe(\.url) { w, _ in sync(w) }, w.observe(\.canGoBack) { w, _ in sync(w) },
                            w.observe(\.canGoForward) { w, _ in sync(w) }, w.observe(\.isLoading) { w, _ in sync(w) }]
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
            case .signIn:
                decisionHandler(.cancel)
                navigation?.signInBlocked = true
            }
        }

        /// Seite laesst sich nicht laden (kein Netz, Zeitueberschreitung): Hinweis in der Spalte statt leerer Flaeche.
        /// Von der App selbst abgebrochene Navigationen (ausserhalb geoeffnet, Anmeldung) sind kein Fehler.
        @MainActor
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            guard e.domain == NSURLErrorDomain, e.code != NSURLErrorCancelled else { return }
            self.navigation?.problem = "Die Seite lädt nicht. Prüf deine Internetverbindung."
        }

        /// Antworten, die WebKit nicht anzeigen kann (Downloads), nie in der App laden
        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .cancel)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.navigation?.sync(from: webView)
        }

        /// target=_blank, window.open: nie ein neues Fenster in der App; erlaubte Seite ausserhalb oeffnen
        @MainActor
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = action.request.url else { return nil }
            if newWindowsInPlace {
                // YouTube: eine YouTube-Seite bleibt in der Spalte, alles andere wie jede Navigation
                switch decide(url, true) {
                case .allow: webView.load(action.request)
                case .openOutside(let out): UIApplication.shared.open(out)
                case .signIn: navigation?.signInBlocked = true
                case .cancel: break
                }
                return nil
            }
            if case .openOutside(let out) = WebSideHosts.outside(url) { UIApplication.shared.open(out) }
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
        case .youTube(let y): YouTubeSidePane(visit: y, dataStore: WebSideStore.dataStore(), onClose: onClose)
        case .recording(let e): RecordingSidePane(entry: e, onClose: onClose)
        case .site(let s): LearningSitePane(site: s, dataStore: WebSideStore.dataStore(), onClose: onClose)
        }
    }
}

// MARK: - iPhone: ueber dem Dokument (Auftrag 17.11.2026 "auch auf iPhone und macOS")

/// iPhone-Leseansicht (kein Platz fuer eine Spalte daneben): Video, YouTube oder Lernseite stehen ueber dem Dokument
/// (quer: links daneben), mit demselben Kopf und X wie die Spalte am iPad. Der Griff dazwischen verschiebt die Teilung.
/// Ohne Auswahl (`item == nil`) nur das Dokument, unveraendert.
struct WebSideOverReader<Content: View>: View {
    let item: WebSideItem?
    let onClose: () -> Void
    @ViewBuilder var content: Content
    /// Anteil der Hoehe (quer: Breite) fuer Video bzw. Seite
    @State private var fraction = WebSideOverReaderLayout.start
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let total = wide ? geo.size.width : geo.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if let item {
                    WebSidePaneView(item: item, onClose: onClose)
                        .id("web-" + item.id)
                        .frame(width: wide ? total * fraction : nil, height: wide ? nil : total * fraction)
                    handle(wide: wide, total: total)
                }
                content
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func handle(wide: Bool, total: CGFloat) -> some View {
        ZStack {
            UF.surface2
            Capsule().fill(UF.muted.opacity(0.6)).frame(width: wide ? 4 : 36, height: wide ? 36 : 4)
        }
        .frame(width: wide ? 16 : nil, height: wide ? nil : 16)
        .contentShape(Rectangle().inset(by: -10))
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { g in
                let start = dragStart ?? fraction
                dragStart = start
                let moved = wide ? g.translation.width : g.translation.height
                fraction = WebSideOverReaderLayout.clamp(start + moved / max(1, total))
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityLabel("Teilung verschieben")
        .accessibilityIdentifier("web.over.handle")
    }
}

enum WebSideOverReaderLayout {
    static let start: CGFloat = 0.5
    /// Video bzw. Seite nie kleiner als ein knappes Drittel und nie so gross, dass das Dokument verschwindet
    static func clamp(_ f: CGFloat) -> CGFloat { min(0.78, max(0.3, f)) }
}

/// Auswahl "Video oder Lernseite" als eigenes Blatt (iPhone-Leseansicht): derselbe Abschnitt wie am iPad unter
/// "Daneben öffnen". Ein eingefuegter Link wird wie dort am Dokument gemerkt.
struct WebSidePickerSheet: View {
    let documentID: String
    var moduleID: Int?
    let onPick: (WebSideItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                WebSidePickerSection(documentID: documentID, moduleID: moduleID) { item in
                    if case .video(let v) = item {
                        DocumentVideoLinks.save(v, for: documentID, defaults: ActiveContainer.current?.defaults)
                    }
                    onPick(item)
                    dismiss()
                }
                .padding(20)
            }
            .background(UF.bg)
            .navigationTitle("Video oder Lernseite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
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

    /// "YouTube-Daten löschen": Cookies und gespeicherte Daten von YouTube/Google aus dem Speicher der Spalten entfernen
    /// (Lernseiten bleiben). Danach fragt YouTube wieder nach der Einwilligung.
    @MainActor
    static func removeYouTubeData(from store: WKWebsiteDataStore) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { isYouTubeData($0.displayName) }
        guard !records.isEmpty else { return }
        await store.removeData(ofTypes: types, for: records)
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

/// Aufzeichnung daneben: derselbe Player wie im Moduldetail (gestreamt oder geladen), Kopf der Spalte mit X
struct RecordingSidePane: View {
    let entry: OpencastEntry
    let onClose: () -> Void
    @EnvironmentObject private var studip: StudIPSync

    var body: some View { RecordingPlayerView(entry: entry, library: studip.recordings, onClosePane: onClose) }
}

/// Abschnitte "Video" und "Lernseite" unter "Daneben öffnen" (Plan freigegeben 14.11.2026)
struct WebSidePickerSection: View {
    let documentID: String
    var moduleID: Int?
    let onPick: (WebSideItem) -> Void
    @EnvironmentObject private var studip: StudIPSync
    @State private var link = ""
    @State private var problem: String?
    @State private var recordings: [OpencastEntry] = []

    private var lastRecord: DocumentVideoRecord? { DocumentVideoLinks.record(documentID, defaults: ActiveContainer.current?.defaults) }

    /// "Zuletzt hier": ein auf der YouTube-Seite angesehenes Video oeffnet wieder dort, ein eingefuegter Link im
    /// eingebetteten Player
    static func lastItem(_ r: DocumentVideoRecord, documentID: String) -> WebSideItem {
        r.onYouTube == true ? .youTube(YouTubeVisit(documentID: documentID, video: r.link)) : .video(r.link)
    }
    private var sites: [LearningSite] { LearningSites.sites(for: ActiveContainer.current?.key.university) }

    /// Gruppen der Lernseiten in dieser Reihenfolge
    static let groups: [(title: String, kinds: Set<String>)] = [
        ("Deine Hochschule", ["university", "library"]),
        ("Nachschlagen", ["reference", "dictionary"]),
        ("Rechnen und Üben", ["tool", "learning"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            videoSection
            sitesSection
        }
        .task(id: moduleID) {
            guard let moduleID else { return }
            let all = await studip.recordings.blocks(moduleID: moduleID).flatMap(\.entries).filter { !$0.gone }
            recordings = Array(all.sorted { ($0.video.created ?? 0) > ($1.video.created ?? 0) }.prefix(6))
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Video").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            Text(Self.videoIntro(readerOnly: UFEditorAvailability.readerOnly))
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            UFButton("YouTube öffnen", icon: "play", kind: .primary) { onPick(.youTube(YouTubeVisit(documentID: documentID))) }
                .accessibilityIdentifier("web.youtubeOpen")
            let last = lastRecord
            if last != nil || !recordings.isEmpty {
                VStack(spacing: 0) {
                    if let last {
                        row(icon: "play.rectangle", title: "Zuletzt hier: YouTube-Video", sub: Self.lastSubtitle(last.link),
                            id: "web.lastVideo") { onPick(Self.lastItem(last, documentID: documentID)) }
                    }
                    ForEach(Array(recordings.enumerated()), id: \.element.id) { i, e in
                        if i > 0 || last != nil { Rectangle().fill(UF.line).frame(height: 1).padding(.leading, 48) }
                        row(icon: "video", title: e.video.title, sub: "Aufzeichnung · \(e.label) · \(e.courseTitle)",
                            id: "web.recording.\(i)") { onPick(.recording(e)) }
                    }
                }
                .background(UF.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UF.line, lineWidth: 1))
            }
            // zweiter, kleinerer Weg (bis 17.11.2026 der einzige): ein Link zu einem einzelnen Video im eingebetteten Player
            Text("Oder einen Link einfügen – dann läuft nur dieses eine Video:")
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            HStack(spacing: 8) {
                UFTextInput("YouTube-Link einfügen", text: $link)
                    .accessibilityIdentifier("web.videoLink")
                    .onSubmit(openLink)
                UFButton("Öffnen", size: .small) { openLink() }
                    .accessibilityIdentifier("web.videoOpen")
            }
            if let problem {
                Text(problem).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("web.videoProblem")
            }
        }
    }

    /// Einleitung des Abschnitts "Video": am iPhone wird gelesen, nicht geschrieben, und das Video steht ueber dem Dokument
    static func videoIntro(readerOnly: Bool) -> String {
        readerOnly
            ? "Such dein Video bei YouTube und schau es über dem Dokument. Links zu anderen Seiten öffnen außerhalb der App."
            : "Such dein Video bei YouTube und schreib im Dokument mit. Links zu anderen Seiten öffnen außerhalb der App."
    }

    /// Beschriftung rechts in den Zeilen "Zuletzt hier" und der Aufzeichnungen
    static func openLabel(readerOnly: Bool) -> String { readerOnly ? "Öffnen" : "Daneben öffnen" }

    static func lastSubtitle(_ v: VideoLink) -> String {
        v.start > 0 ? "ab \(v.start / 60):\(String(format: "%02d", v.start % 60))" : "von vorn"
    }

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lernseite").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
            Text("Ausgewählte Seiten zum Nachschlagen, ohne Adresszeile. Links zu anderen Seiten öffnen außerhalb der App.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(Self.groups, id: \.title) { g in
                let list = sites.filter { g.kinds.contains($0.kind) }
                if !list.isEmpty {
                    Text(g.title).ufFont(12.8, 600).foregroundStyle(UF.muted).padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(list) { site in tile(site) }
                    }
                }
            }
        }
    }

    private func tile(_ s: LearningSite) -> some View {
        Button { onPick(.site(s)) } label: {
            HStack(spacing: 10) {
                Image(systemName: s.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(UF.accent)
                    .frame(width: 34, height: 34).background(UF.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).ufFont(13.6, 600).foregroundStyle(UF.text).lineLimit(2).multilineTextAlignment(.leading)
                    Text(s.start.host?.replacingOccurrences(of: "www.", with: "") ?? "").ufFont(11.5).foregroundStyle(UF.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(UF.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UF.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("web.site.\(s.id)")
    }

    private func row(icon: String, title: String, sub: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(UF.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).ufFont(14.5, 600).foregroundStyle(UF.text).lineLimit(2)
                    Text(sub).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(Self.openLabel(readerOnly: UFEditorAvailability.readerOnly)).ufFont(12.8, 600).foregroundStyle(UF.accentText)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func openLink() {
        guard let v = VideoLink.parse(link) else { problem = VideoLink.rejectedText; return }
        problem = nil
        onPick(.video(v))
    }
}
