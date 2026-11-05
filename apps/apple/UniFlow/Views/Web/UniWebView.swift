import SwiftUI
import UIKit
import UniFlowCore
import WebKit

// In-App-Browser fuer Links zur eigenen Hochschule (Wunsch des Inhabers 04.11.2026: "wenn man auf einen Stud.IP-Link
// tippt, soll man direkt in Stud.IP drin sein"). Vorher gingen alle Links an Safari, das keine Anmeldung der App kennt.
// Jetzt: Links zu Stud.IP, WebSSO und QIS (LUH) bzw. Learnweb, LSF und CAS (Uni Hildesheim) der Hochschule des offenen
// Containers oeffnen hier, mit dem Datenspeicher der Anmeldeansichten (dieselben Cookies wie der Abgleich); alles
// andere wie bisher (`SafeLinks`: http(s) ans System, sonst verwerfen). Docs: docs/IPAD-STUDIP-SYNC.md, Abschnitt 13.

/// Wohin ein Link geht (rein, testbar)
enum UniLinks {
    /// Rechner und Pfadanfang, die der In-App-Browser oeffnet
    struct Scope: Equatable {
        let host: String
        let pathPrefix: String

        func matches(host h: String, path: String) -> Bool { h == host && path.hasPrefix(pathPrefix) }
    }

    enum Route: Equatable {
        /// im In-App-Browser (Adresse ggf. auf https gehoben)
        case inApp(URL)
        /// an das System (Safari bzw. die zustaendige App), wie bisher
        case system
        /// verwerfen (kein http(s), z. B. uniflow:// aus fremdem Text)
        case discard
    }

    /// Bereiche der Hochschule aus dem Profil (`UniversityProfile`): Stud.IP, Identitaetsanbieter (WebSSO bzw. CAS),
    /// QIS der LUH; Learnweb (alle Jahresinstanzen /learnweb…), LSF der Uni Hildesheim. Die Startseite der Hochschule
    /// und andere Dienste (ILIAS, Mail, IDM) bleiben beim System.
    static func scopes(_ u: UniversityKey) -> [Scope] {
        let p = u.profile
        var out: [Scope] = []
        func whole(_ url: URL?) { if let h = url?.host?.lowercased() { out.append(Scope(host: h, pathPrefix: "/")) } }
        whole(p.studipBase)
        whole(p.lsfBase)
        for t in p.loginService("qis")?.targets ?? [] { out.append(Scope(host: t.host, pathPrefix: "/")) }
        for t in UniLoginHelper.idpTargets(u) { out.append(Scope(host: t.host, pathPrefix: t.pathPrefix)) }
        if let cas = p.casBase, let h = cas.host?.lowercased() {
            out.append(Scope(host: h, pathPrefix: cas.path.hasSuffix("/") ? cas.path : cas.path + "/"))
        }
        if let lw = p.learnwebBase, let h = lw.host?.lowercased() {
            // "/learnweb2026" -> "/learnweb" (jaehrlicher Wechsel der Instanz)
            let first = lw.path.split(separator: "/").first.map(String.init) ?? ""
            let stem = String(first.reversed().drop { $0.isNumber }.reversed())
            if !stem.isEmpty {
                out.append(Scope(host: h, pathPrefix: "/" + stem))
                if h.hasPrefix("www.") { out.append(Scope(host: String(h.dropFirst(4)), pathPrefix: "/" + stem)) }
            }
        }
        if u == .hsh {
            // Hochschule Hannover: ganzes Moodle und Campusmanagement, das alte QIS (Iframe) nur unter /qisserver/
            whole(UniversityProfile.hshMoodle)
            whole(UniversityProfile.hshCampus)
            out.append(Scope(host: "icms.hs-hannover.de", pathPrefix: "/qisserver/"))
        }
        var unique: [Scope] = []
        for s in out where !unique.contains(s) { unique.append(s) }
        return unique
    }

    /// Ziel eines Links. `university`: Hochschule des offenen Containers (nil: keiner offen, alles wie bisher).
    static func route(_ url: URL, university: UniversityKey?) -> Route {
        guard SafeLinks.allows(url) else { return .discard }
        guard let u = university, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host?.lowercased(),
              c.user == nil, c.password == nil else { return .system }
        if let port = c.port, port != 443, port != 80 { return .system }
        let path = c.path.isEmpty ? "/" : c.path
        guard scopes(u).contains(where: { $0.matches(host: host, path: path) }) else { return .system }
        // die Rechner der Hochschule sprechen HTTPS; der In-App-Browser laedt nie http
        var secure = c
        secure.scheme = "https"
        secure.port = nil
        return .inApp(secure.url ?? url)
    }

    /// Entscheidung fuer eine Navigation im Hauptrahmen des In-App-Browsers
    enum MainFrame: Equatable {
        case load
        /// stattdessen diese (https-)Adresse laden
        case upgrade(URL)
        /// an das System geben (anderer Rechner)
        case handOff(URL)
        case block
    }

    static func mainFrame(_ url: URL, university: UniversityKey) -> MainFrame {
        if url.scheme?.lowercased() == "about" { return .load }
        switch route(url, university: university) {
        case .inApp(let target): return target == url ? .load : .upgrade(target)
        case .system: return .handOff(url)
        case .discard: return .block
        }
    }
}

/// Zustand einer Seite im In-App-Browser (Titel, Vor/Zurueck, Laden) und die Regeln fuer Navigationen
@MainActor
final class UniWebPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    /// zuletzt geladene Datei, die WebKit nicht selbst zeigt (zum Teilen/Sichern)
    @Published var download: URL?
    let load = UFWebLoadState()
    let university: UniversityKey
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private var downloads: [ObjectIdentifier: URL] = [:]

    init(dataStore: WKWebsiteDataStore, university: UniversityKey) {
        self.university = university
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // kein Skript auf Stud.IP, Learnweb, LSF oder QIS; nur auf der Anmeldeseite des WebSSO bzw. CAS:
        // "Angemeldet bleiben" und Benutzername (`UniLoginHelper`)
        UniLoginHelper.install(in: config, dataStore: dataStore)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        load.webView = webView
        observations = [
            webView.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            webView.observe(\.url) { [weak self] w, _ in MainActor.assumeIsolated { self?.url = w.url } },
            webView.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            webView.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.isLoading = w.isLoading } },
        ]
    }

    func open(_ url: URL) {
        load.lastURL = url
        webView.load(URLRequest(url: url))
    }

    /// Andere Rechner gehen wie bisher an das System (nur http(s))
    static func handOff(_ url: URL) {
        guard SafeLinks.allows(url) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // eingebettete Rahmen (z. B. Videos in Courseware) duerfen laden; nie andere Schemata
        if navigationAction.targetFrame?.isMainFrame == false {
            let scheme = url.scheme?.lowercased() ?? ""
            decisionHandler(["https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
            return
        }
        switch UniLinks.mainFrame(url, university: university) {
        case .load:
            load.lastURL = url
            decisionHandler(.allow)
        case .upgrade(let secure):
            decisionHandler(.cancel)
            open(secure)
        case .handOff(let other):
            decisionHandler(.cancel)
            Self.handOff(other)
        case .block:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // Dateien, die WebKit nicht zeigt (z. B. ZIP): laden und zum Teilen/Sichern anbieten
        decisionHandler(navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        load.failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { load.failed(error) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { load.failure = nil }

    // MARK: WKUIDelegate

    /// Neue Fenster (target=_blank, window.open): Hochschul-Seiten hier, alles andere an das System
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            switch UniLinks.mainFrame(url, university: university) {
            case .load: open(url)
            case .upgrade(let secure): open(secure)
            case .handOff(let other): Self.handOff(other)
            case .block: break
            }
        }
        return nil
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let target = try? AppTemp.file("browser", name: suggestedFilename.isEmpty ? "Datei" : suggestedFilename)
        if let target { downloads[ObjectIdentifier(download)] = target }
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        self.download = downloads.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        load.failed(error)
    }
}

/// Webansicht der Seite (die eine WKWebView von `UniWebPage`)
private struct UniWebContainer: UIViewRepresentable {
    let page: UniWebPage
    func makeUIView(context: Context) -> WKWebView { page.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// In-App-Browser als Blatt: Titel, Zurueck/Vor, Neu laden, Teilen, "In Safari öffnen", "Fertig". Vor dem ersten Laden
/// stehen die gemerkten Cookies der Hochschule im Datenspeicher (`prepare`); beim Schliessen gehen erneuerte Cookies
/// zurueck in den Schluesselbund und an den Abgleich (`UniWebBrowser`). Lesen in Stud.IP ist eine Handlung des
/// Menschen: Stud.IP markiert dabei Nachrichten als gelesen, wie im Browser.
struct UniWebView: View {
    let start: URL
    @StateObject var page: UniWebPage
    let prepare: () async -> Void
    let close: () -> Void
    @State private var started = false

    init(start: URL, page: UniWebPage, prepare: @escaping () async -> Void, close: @escaping () -> Void) {
        self.start = start
        _page = StateObject(wrappedValue: page)
        self.prepare = prepare
        self.close = close
    }

    /// Titel: Seitentitel, sonst der Rechner
    static func title(page: String, url: URL?) -> String {
        let t = page.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (url?.host ?? "Hochschule") : t
    }

    /// angezeigte Adresse (vor dem ersten Laden die Startadresse)
    private var current: URL { page.url ?? start }

    var body: some View {
        NavigationStack {
            UniWebContainer(page: page)
                .ufWebLoadFailure(page.load)
                .overlay(alignment: .top) {
                    if page.isLoading { ProgressView().progressViewStyle(.linear).tint(UF.accent) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let file = page.download {
                        HStack(spacing: 9.6) {
                            Text("Geladen: \(file.lastPathComponent)").ufFont(13.12).foregroundStyle(UF.text2).lineLimit(1)
                            Spacer()
                            ShareLink(item: file) { Text("Teilen oder sichern").ufFont(13.12, 600) }
                            Button("Schließen") { page.download = nil }.ufFont(13.12)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9.6)
                        .background(UF.surface)
                    }
                }
                .navigationTitle(Self.title(page: page.title, url: current))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fertig") { close() }.accessibilityIdentifier("uniweb.done")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if SafeLinks.allows(current) {
                            ShareLink(item: current) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Teilen")
                            Button { UniWebPage.handOff(current) } label: { Image(systemName: "safari") }
                                .accessibilityLabel("In Safari öffnen")
                                .accessibilityIdentifier("uniweb.safari")
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { page.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!page.canGoBack).accessibilityLabel("Zurück")
                        Button { page.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!page.canGoForward).accessibilityLabel("Vor")
                        Spacer()
                        Button {
                            if page.isLoading { page.webView.stopLoading() } else { page.load.retry() }
                        } label: { Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise") }
                            .accessibilityLabel(page.isLoading ? "Laden anhalten" : "Neu laden")
                    }
                }
        }
        .task {
            guard !started else { return }
            started = true
            await prepare()
            page.open(start)
        }
    }
}

/// Blatt-Controller des In-App-Browsers: meldet das Schliessen (auch durch Wischen), damit die Cookies zurueckgehen
final class UniWebHostingController: UIHostingController<UniWebView> {
    var onDismissed: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismissed?()
            onDismissed = nil
        }
    }
}

/// Oeffnet Links der Hochschule im In-App-Browser (global ueber `OpenURLAction` in UniFlowApp)
@MainActor
enum UniWebBrowser {
    /// Ergebnis fuer `OpenURLAction`: Hochschul-Links hier, sonst wie bisher (`SafeLinks`)
    static func action(for url: URL, containers: ContainerManager) -> OpenURLAction.Result {
        switch UniLinks.route(url, university: containers.active?.key.university) {
        case .discard: return .discarded
        case .system: return .systemAction
        case .inApp(let target): return open(target, containers: containers) ? .handled : .systemAction
        }
    }

    /// oberstes sichtbares Blatt des vorderen Fensters (Links aus anderen Blaettern heraus oeffnen darueber)
    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// Blatt zeigen; false, wenn kein Container offen ist oder kein Fenster da ist (dann das System)
    @discardableResult
    static func open(_ url: URL, containers: ContainerManager) -> Bool {
        guard let c = containers.active, let top = topController() else { return false }
        let store = containers.websiteDataStore(for: c)
        let studip = containers.studip
        let hildesheim = containers.hildesheim
        let page = UniWebPage(dataStore: store, university: c.key.university)
        weak var sheet: UIViewController?
        let view = UniWebView(start: url, page: page, prepare: {
            // gemerkte Anmeldung (auch des WebSSO bzw. CAS) und das Stud.IP-Cookie des Abgleichs in den Datenspeicher
            await UniWebSessions.ready(store)
            await studip.seedWebSession()
        }, close: { sheet?.dismiss(animated: true) })
        let controller = UniWebHostingController(rootView: view)
        controller.modalPresentationStyle = .pageSheet
        controller.onDismissed = {
            Task { @MainActor in await finished(store: store, studip: studip, hildesheim: hildesheim) }
        }
        sheet = controller
        top.present(controller, animated: true)
        return true
    }

    /// Nach dem Schliessen: Cookies der Hochschule merken (`UniWebSessions`), eine neue Stud.IP-Sitzung an den Abgleich
    /// geben, abgelaufene Learnweb-/LSF-Anmeldung ueber die (vielleicht eben erneuerte) CAS-Anmeldung still erneuern
    static func finished(store: WKWebsiteDataStore, studip: StudIPSync, hildesheim: HildesheimConnection?) async {
        await UniWebSessions.save(store)
        await studip.adoptBrowserSession()
        if let hildesheim, !hildesheim.expiredSources.isEmpty {
            _ = await hildesheim.renewSilently(trigger: .userAction)
        }
    }
}
