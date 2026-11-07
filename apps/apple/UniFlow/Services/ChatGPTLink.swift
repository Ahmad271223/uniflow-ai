import AuthenticationServices
import Combine
import Foundation
import Network
import SwiftUI
import UniFlowCore

/// Zustand der ChatGPT-Verbindung im Schluesselbund dieses Geraets, je Apple-Nutzer (`DataContainerKey.userScope`);
/// nie synchronisiert, nie beim Dienst. Konto loeschen entfernt ihn (`ContainerManager.deleteAllData`).
struct ChatGPTKeychainStore: ChatGPTStateStore {
    static let service = "de.uniflow.ai.chatgpt"
    let userScope: String
    private var keychain: KeychainStore { KeychainStore(service: Self.service) }

    func load() -> ChatGPTState? {
        keychain.data(userScope).flatMap { try? JSONDecoder().decode(ChatGPTState.self, from: $0) }
    }

    func save(_ state: ChatGPTState) throws { try keychain.write(JSONEncoder().encode(state), account: userScope) }

    /// true, wenn danach nichts mehr da ist
    @discardableResult
    static func remove(userScope: String) -> Bool { KeychainStore(service: service).remove(userScope) }
}

/// Anfragen an OpenAI ueber URLSession (nur feste https-Adressen aus `ChatGPTConstants`)
struct URLSessionAITransport: AIHTTPTransport {
    func send(_ request: AIHTTPRequest) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: request.url), url.scheme == "https" else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: 120)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("StudiNow/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Rueckleitung der Anmeldung auf `http://127.0.0.1:<Port>/auth/callback` (so dokumentiert OpenAI es fuer Apps auf dem
/// Geraet): ein Listener nur auf der Loopback-Adresse, eine einzige Anfrage, danach zu.
final class ChatGPTLoopback: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    /// Port, auf dem der Listener wartet
    func start() async throws -> UInt16 {
        // nur an der Loopback-Schnittstelle (von aussen nicht erreichbar); die Gegenstelle prueft handle zusaetzlich
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        lock.withLock { listener = l }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var done = false
            l.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; cont.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let e): done = true; cont.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Abfrage der Rueckleitung (`code`, `state`, `client_id` …)
    func query() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                if let result { cont.resume(with: result) } else { waiter = cont }
            }
        }
    }

    func stop(_ error: Error? = nil) {
        let w: CheckedContinuation<[String: String], Error>? = lock.withLock {
            listener?.cancel()
            listener = nil
            let w = waiter
            waiter = nil
            if result == nil, let error { result = .failure(error) }
            return w
        }
        if let error { w?.resume(throwing: error) }
    }

    private func finish(_ q: [String: String]) {
        let w: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = .success(q)
            let w = waiter
            waiter = nil
            return w
        }
        w?.resume(returning: q)
    }

    private func handle(_ c: NWConnection) {
        if case .hostPort(let host, _) = c.endpoint {
            let loopback: Bool
            switch host {
            case .ipv4(let a): loopback = a == .loopback
            case .ipv6(let a): loopback = a == .loopback || a.asIPv4 == .loopback
            case .name(let n, _): loopback = n == "localhost"
            @unknown default: loopback = false
            }
            guard loopback else { c.cancel(); return }
        }
        c.start(queue: .global(qos: .userInitiated))
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            var q: [String: String] = [:]
            var ok = false
            if parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: "http://127.0.0.1" + parts[1]),
               comps.path == ChatGPTConstants.callbackPath {
                for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
                ok = true
            }
            let text = ok ? "StudiNow ist verbunden. Du kannst dieses Fenster schließen." : "Unbekannte Adresse."
            let body = Data("<!doctype html><meta charset=utf-8><title>StudiNow</title><p style=\"font-family:-apple-system;margin:2em\">\(text)</p>".utf8)
            let header = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            // letzte Nachricht mit FIN: der Browser liest die Antwort ganz, danach schliesst die Verbindung sauber
            c.send(content: Data(header.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { c.cancel() }
            })
            if ok { self?.finish(q) }
        }
    }
}

/// Fenster fuer die Anmeldeseite von OpenAI
private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

/// KI ueber das ChatGPT-Abo des Nutzers (docs/KI-CHATGPT-PLAN.md, Phase 3): Verbindung je Apple-Nutzer, Anmeldung bei
/// OpenAI mit Rueckleitung auf 127.0.0.1, Modellwahl, Schalter. Ist die KI verbunden und eingeschaltet, beantwortet das
/// lokale Backend die KI-Endpunkte damit (`LocalContext.ai`). An keinen Tarif gebunden (Bedingungen von OpenAI).
@MainActor
final class ChatGPTLink: ObservableObject {
    /// Von OpenAI vergebene Client-ID (Info.plist `StudoraChatGPTClientID`); bis zur Aufnahme leer
    nonisolated static var configuredClientID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "StudoraChatGPTClientID") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Unterbau in jedem Build (Schluesselbund je Apple-Nutzer, Stand, Loeschen mit dem Konto): die Erstregistrierung
    /// bei OpenAI laeuft mit `dynamic_agent_client` (docs/KI-CHATGPT-PLAN.md, Abschnitt 9) und braucht keine vorab
    /// vergebene Client-ID mehr. Eine konfigurierte ID (`configuredClientID`) wird weiter benutzt, wenn eine da ist.
    /// Ob die Verbindung angeboten wird, entscheidet `isEnabled`.
    nonisolated static var available: Bool { true }

    /// Schalter "Eigenes ChatGPT verbinden" (05.11.2026, wie `StudyTimer.isEnabled`): Sign in with ChatGPT ist fuer
    /// StudiNow von OpenAI noch nicht freigegeben (app/plans.py `INTEGRATIONS["chatgpt"].status = "disabled"`); am
    /// Geraet des Inhabers blieb die Anmeldung nach Kontowahl bzw. E-Mail haengen. Aus: keine Anmeldung, kein Knopf
    /// "ChatGPT verbinden" (Einstellungen, KI-Hilfe, KI-Start, Tests) und seit 07.11.2026 auch keine Karte "bald
    /// verfügbar" mehr in den Einstellungen (App-Pruefung: nichts versprechen); `soonText` bleibt die Meldung von
    /// `connect()`; die KI-Wege
    /// zeigen den Tarif-Hinweis (`planHint`) bzw. nutzen einen Server (eigener PC, StudiNow-Dienst). Eine frueher
    /// gespeicherte Verbindung bleibt im Schluesselbund, wird aber nicht benutzt. docs/KI-CHATGPT-PLAN.md Abschnitt 11.
    nonisolated static let isEnabled = false

    /// Meldung von `connect()`, solange `isEnabled` aus ist (keine Karte in den Einstellungen)
    nonisolated static let soonText = "Mit ChatGPT anmelden – bald verfügbar"

    /// Hinweis an den KI-Stellen ohne KI: wie es weitergeht - StudiNow-KI (Pro AI) oder der eigene OpenAI-Schluessel
    /// (Einstellungen → Erweitert, in jedem Tarif; 07.11.2026), ohne eine Anmeldung bei ChatGPT anzubieten
    nonisolated static let planHint = "Die KI-Hilfe kommt mit der StudiNow-KI in StudiNow Pro AI – oder mit deinem eigenen ChatGPT: OpenAI-Schlüssel unter Einstellungen → Erweitert → Eigenes ChatGPT eintragen (in jedem Tarif)."

    /// Ziel der Knoepfe an den KI-Stellen ohne KI: mit Schalter die ChatGPT-Karte (Erweitert), sonst die Tarife (Konto)
    nonisolated static var settingsTab: String { isEnabled ? "advanced" : "account" }

    @Published private(set) var status: ChatGPTSession.Status?
    @Published private(set) var connecting = false
    @Published private(set) var models: [String] = []
    @Published var message: String?

    /// Eigenes ChatGPT ueber den eigenen OpenAI-Schluessel (07.11.2026, OpenAIKeyLink.swift): gehoert zum selben
    /// Apple-Nutzer, haengt am selben Backend und zaehlt hier als "eigenes ChatGPT" (`enabled`, `ufAIEnabled`)
    let apiKey = OpenAIKeyLink()
    private var forward: AnyCancellable?

    private(set) var session: ChatGPTSession?
    private var scope: String?
    private var host: LocalBackendHost?
    private var auth: ASWebAuthenticationSession?
    private var loopback: ChatGPTLoopback?
    private let presenter = AuthPresenter()

    init() {
        forward = apiKey.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// KI-Anfragen ueber das eigene ChatGPT gerade moeglich: ueber das Abo (nie, solange `isEnabled` aus ist) oder
    /// ueber den eigenen Schluessel
    var enabled: Bool { Self.isEnabled && status?.enabledForAI == true || apiKey.enabled }

    /// Modell, das gerade antwortet (Kostenzeile): das des Abos vor dem des Schluessels (Reihenfolge wie `LocalAI`)
    var activeModel: String? {
        if Self.isEnabled, status?.enabledForAI == true { return status?.model }
        return apiKey.enabled ? apiKey.status?.model : nil
    }

    /// Container geoeffnet oder geschlossen: Verbindung des Apple-Nutzers laden und ins Backend haengen
    func use(userScope: String?, host: LocalBackendHost?) {
        apiKey.use(userScope: userScope, host: host)
        self.host = host
        if userScope != scope {
            scope = userScope
            models = []
            session = userScope.map {
                ChatGPTSession(store: ChatGPTKeychainStore(userScope: $0), http: URLSessionAITransport(), signature: ChatGPTAppleSignature())
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let session, Self.available else {
            status = nil
            await attach(nil)
            return
        }
        try? await session.useConfiguredClientID(Self.configuredClientID)
        let s = await session.status
        status = s
        await attach(Self.isEnabled && s.enabledForAI ? session : nil)
    }

    private func attach(_ provider: AIProvider?) async {
        guard let host, let backend = try? await host.backend() else { return }
        backend.context.ai.set(provider)
    }

    // MARK: Verbinden

    /// Anmeldeversuch beim Kern beginnen (ohne Fenster, auch fuer Tests): `newAccount` = anderes ChatGPT-Konto, also
    /// neue Registrierung (Client-ID, Profil und Zugangsdaten weg, der Stand wird gleich neu geladen); `reconsent` =
    /// Zustimmungsseite erzwingen, damit der Nutzer die Nutzung seines Abos freigibt
    func loginAttempt(port: UInt16, newAccount: Bool = false, reconsent: Bool = false) async throws -> ChatGPTLoginAttempt {
        guard let session else { throw AIError("chatgpt_flow", "ChatGPT ist fuer diesen Nutzer nicht eingerichtet.") }
        let attempt = try await session.beginLogin(redirectURI: "http://127.0.0.1:\(port)\(ChatGPTConstants.callbackPath)",
                                                   newAccount: newAccount, reconsent: reconsent)
        if newAccount { await refresh() }
        return attempt
    }

    func connect(newAccount: Bool = false, reconsent: Bool = false) async {
        // ausgeschaltet: keine Anmeldeseite (sie hinge nach der Kontowahl), nur der Hinweis
        guard Self.isEnabled else { message = Self.soonText + "."; return }
        guard let session, !connecting else { return }
        connecting = true
        message = nil
        defer { connecting = false }
        let lb = ChatGPTLoopback()
        loopback = lb
        do {
            let port = try await lb.start()
            let attempt = try await loginAttempt(port: port, newAccount: newAccount, reconsent: reconsent)
            guard let url = URL(string: attempt.url) else { throw AIError("chatgpt_flow", "Anmeldeadresse ungültig.") }
            // Die Rueckleitung kommt ueber den Listener; die Sitzung zeigt nur die Seite von OpenAI (kein eigenes Schema)
            let a = ASWebAuthenticationSession(url: url, callbackURLScheme: "studora-chatgpt") { _, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    lb.stop(AIError("chatgpt_flow", "Anmeldung abgebrochen."))
                }
            }
            a.presentationContextProvider = presenter
            a.prefersEphemeralWebBrowserSession = false
            auth = a
            guard a.start() else { throw AIError("chatgpt_flow", "Die Anmeldeseite von OpenAI ließ sich nicht öffnen.") }
            let query = try await withTimeout(ChatGPTConstants.flowTimeout) { try await lb.query() }
            a.cancel()
            try await session.completeLogin(query: query)
            await refresh()
            await loadModels()
        } catch let e as AIError {
            message = e.message
            await session.cancelLogin()
        } catch {
            message = "Verbindung nicht abgeschlossen: \(error.localizedDescription)"
            await session.cancelLogin()
        }
        auth?.cancel()
        auth = nil
        lb.stop()
        loopback = nil
    }

    private func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AIError("chatgpt_flow", "Die Anmeldung hat zu lange gedauert. Bitte erneut „ChatGPT verbinden“.")
            }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    func disconnect() async {
        guard let session else { return }
        do { try await session.disconnect() } catch { message = "Trennen fehlgeschlagen: \(error.localizedDescription)" }
        models = []
        await refresh()
    }

    /// Hinweis, wenn das Konto keine Modellliste liefert (leer oder abgelehnt): die KI laeuft trotzdem, StudiNow
    /// probiert die bekannten Modelle (`ChatGPTSession.fallbackModels`) der Reihe nach
    static let noModelListMessage = "Dein ChatGPT-Konto erlaubt keine Modellliste; StudiNow probiert die bekannten Modelle automatisch."

    /// Hinweis zur Liste: nil, wenn Modelle da sind; bei leerer Liste oder einem Fehler der Liste (ausser "neu
    /// verbinden", das die Karte selbst zeigt) der feste Hinweis
    static func modelListNote(models: [String], error: AIError?) -> String? {
        if let error, error.code == "chatgpt_login_needed" { return error.message }
        return models.isEmpty ? noModelListMessage : nil
    }

    func loadModels() async {
        guard let session, status?.connected == true else { return }
        let rejected = Set(await session.rejectedModels)
        var listed: [String] = []
        var failure: AIError?
        do {
            listed = try await session.models()
        } catch let e as AIError {
            failure = e
        } catch {
            failure = AIError("chatgpt_http_error", error.localizedDescription)
        }
        models = listed
        message = Self.modelListNote(models: listed, error: failure)
        // ohne Wahl: das erste Modell des Katalogs (Reihenfolge von OpenAI), sonst der erste feste Kandidat, damit die KI
        // gleich arbeitet (aenderbar, aber nie noetig)
        if (status?.model ?? "").isEmpty, failure?.code != "chatgpt_login_needed",
           let first = ChatGPTSession.modelCandidates(listed: listed, catalogOrder: await session.modelsFromCatalog, excluding: rejected).first {
            try? await session.setModel(first)
        }
        await refresh()
    }

    func setModel(_ slug: String) async {
        do { try await session?.setModel(slug) } catch let e as AIError { message = e.message } catch {}
        await refresh()
    }

    func setUseForAI(_ on: Bool) async {
        try? await session?.setUseForAI(on)
        await refresh()
    }
}

/// KI ueber ChatGPT gerade nutzbar (verbunden, eingeschaltet, Modell gewaehlt); Standard aus, damit Ansichten ohne
/// Anschluss (Tests, Vorschauen) wie bisher ohne KI erscheinen
private struct UFAIEnabledKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var ufAIEnabled: Bool {
        get { self[UFAIEnabledKey.self] }
        set { self[UFAIEnabledKey.self] = newValue }
    }
}

/// Reicht `ChatGPTLink.enabled` als `ufAIEnabled` an alle Ansichten weiter (beobachtet die Verbindung)
struct UFAIEnabledProvider: ViewModifier {
    @ObservedObject var link: ChatGPTLink
    func body(content: Content) -> some View { content.environment(\.ufAIEnabled, link.enabled) }
}

/// Der ChatGPT-Anschluss fuer Ansichten, die ihn zeigen (Einstellungen → Erweitert); nil ohne Anschluss (Tests,
/// Vorschauen), dann erscheint die Karte nicht
private struct UFChatGPTLinkKey: EnvironmentKey { static let defaultValue: ChatGPTLink? = nil }

extension EnvironmentValues {
    var ufChatGPTLink: ChatGPTLink? {
        get { self[UFChatGPTLinkKey.self] }
        set { self[UFChatGPTLinkKey.self] = newValue }
    }
}
