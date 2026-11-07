import Foundation

// Eigenes ChatGPT ueber den eigenen OpenAI-API-Schluessel des Nutzers (Auftrag des Inhabers vom 07.11.2026, Version 1.0).
// Anders als "Sign in with ChatGPT" (ChatGPTSession, braucht die Freigabe von OpenAI und ist aus, `ChatGPTLink.isEnabled`)
// braucht ein API-Schluessel keine Partnerfreigabe: der Nutzer legt ihn bei platform.openai.com selbst an und traegt ihn
// in den Einstellungen ein. Der Schluessel liegt nur im Schluesselbund dieses Geraets (App: `OpenAIKeyKeychainStore`,
// ThisDeviceOnly), geht nie an den StudiNow-Dienst und steht in keiner Meldung und keinem Protokoll (`Status.keyHint`
// zeigt nur die letzten vier Zeichen). Jede Anfrage geht direkt vom iPad an api.openai.com und kostet den Nutzer Geld
// bei OpenAI - darum `isMetered` (nie im Hintergrund, nur nach Antippen) und in jedem Tarif (auch Free, Entscheidung
// 05.11.2026, Bedingungen von OpenAI: keine Kopplung an einen bezahlten Tarif).

/// Was StudiNow sich zum eigenen Schluessel merkt (im Schluesselbund, je Apple-Nutzer)
public struct OpenAIKeyState: Codable, Equatable, Sendable {
    public var apiKey: String = ""
    public var model: String = ""
    public var useForAI: Bool = true
    /// Zeitpunkt der letzten erfolgreichen Pruefung (`GET /v1/models`), nil = nie geprueft
    public var checkedAt: Double?
    /// letzter Fehler einer Anfrage (nur Text, nie der Schluessel)
    public var lastError: String?

    public init() {}
}

/// Ablage des Zustands (App: Schluesselbund; Tests: Speicher)
public protocol OpenAIKeyStateStore: Sendable {
    func load() -> OpenAIKeyState?
    func save(_ state: OpenAIKeyState) throws
    func remove() throws
}

/// Feste Regeln zum Schluessel und zur Modellwahl (rein, testbar)
public enum OpenAIKeyRules {
    /// Modell, wenn der Nutzer keins waehlt und die Liste es fuehrt: das guenstige Standardmodell (Wunsch des Inhabers)
    public static let defaultModel = "gpt-4o-mini"
    /// Seite, auf der der Nutzer seinen Schluessel anlegt bzw. den Verbrauch sieht
    public static let keysURL = "https://platform.openai.com/api-keys"
    public static let usageURL = "https://platform.openai.com/usage"
    public static let keyMinLength = 20
    public static let keyMaxLength = 400

    /// Schluessel in gueltiger Form: aussen ohne Leerraum, beginnt mit "sk-", ohne Leerraum innen, 20-400 Zeichen,
    /// nur sichtbare ASCII-Zeichen; sonst nil
    public static func normalize(_ raw: String) -> String? {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.hasPrefix("sk-"), k.count >= keyMinLength, k.count <= keyMaxLength,
              k.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return nil }
        return k
    }

    /// Anzeige eines Schluessels: nur die letzten vier Zeichen ("sk-…ab12")
    public static func masked(_ key: String) -> String {
        guard key.count >= 8 else { return key.isEmpty ? "" : "sk-…" }
        return "sk-…" + String(key.suffix(4))
    }

    /// Chat-Modelle aus `GET /v1/models` mit einem API-Schluessel: "gpt-…" und "o…", ohne Spezialmodelle (Audio, Bild,
    /// Einbettungen, Suche, Transkription, Moderation, Realtime, Instruct, Codex, Vorschauen mit Datum bleiben)
    public static func isChatModel(_ id: String) -> Bool {
        let l = id.lowercased()
        guard l.hasPrefix("gpt-") || l.range(of: #"^o\d"#, options: .regularExpression) != nil else { return false }
        let special = ["audio", "realtime", "search", "transcribe", "tts", "image", "embedding", "instruct", "moderation",
                       "dall", "whisper", "computer", "vision", "oss", "codex", "chatgpt-4o-latest"]
        return !special.contains { l.contains($0) }
    }

    /// Nur die Chat-Modelle, alphabetisch (so antwortet OpenAI), das Standardmodell und seine Familie vorn
    public static func chatModels(_ ids: [String]) -> [String] {
        let chat = ids.filter(isChatModel)
        let (minis, rest) = (chat.filter { $0.lowercased().contains("mini") }, chat.filter { !$0.lowercased().contains("mini") })
        var out: [String] = []
        var seen = Set<String>()
        for id in minis.sorted(by: PyText.less) + rest.sorted(by: PyText.less) where seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// Modell ohne Wahl: `defaultModel`, wenn die Liste es fuehrt; sonst das neueste "mini"-Modell ohne Datum; sonst das
    /// Hauptmodell der Liste (`ChatGPTSession.preferredModel`); nil bei leerer Liste
    public static func pickDefault(_ ids: [String]) -> String? {
        let chat = chatModels(ids)
        if chat.contains(defaultModel) { return defaultModel }
        func dated(_ id: String) -> Bool { id.range(of: #"\d{4}-\d{2}-\d{2}|-\d{4}$"#, options: .regularExpression) != nil }
        let minis = chat.filter { $0.lowercased().hasPrefix("gpt-") && $0.lowercased().contains("mini") && !dated($0) }
        if let m = minis.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first { return m }
        return ChatGPTSession.preferredModel(chat) ?? chat.first
    }
}

/// KI ueber den eigenen OpenAI-Schluessel als `AIProvider` des lokalen Backends: Modelle (`GET /v1/models`), Anfragen
/// an `POST /v1/responses` (dieselbe Form wie mit dem ChatGPT-Abo, `ChatGPTProtocol`), Fehler mit Code und Text.
/// Gesendet wird nur, was die App ausdruecklich uebergibt; der Schluessel steht nur in der Kopfzeile `Authorization`.
public actor OpenAIKeySession: AIProvider {
    private let store: OpenAIKeyStateStore
    private let http: AIHTTPTransport
    private let now: @Sendable () -> Double
    private var state: OpenAIKeyState
    private var modelsCache: (at: Double, ids: [String])?

    public init(store: OpenAIKeyStateStore, http: AIHTTPTransport, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store
        self.http = http
        self.now = now
        state = store.load() ?? OpenAIKeyState()
    }

    // MARK: Stand

    public struct Status: Equatable, Sendable {
        public var hasKey: Bool
        /// "sk-…ab12", leer ohne Schluessel
        public var keyHint: String
        public var model: String
        public var useForAI: Bool
        /// Schluessel schon einmal erfolgreich geprueft
        public var checked: Bool
        public var lastError: String?
        /// KI-Anfragen moeglich: Schluessel da, eingeschaltet, Modell gewaehlt
        public var enabledForAI: Bool { hasKey && useForAI && !model.isEmpty }

        public init(hasKey: Bool, keyHint: String, model: String, useForAI: Bool, checked: Bool, lastError: String?) {
            self.hasKey = hasKey
            self.keyHint = keyHint
            self.model = model
            self.useForAI = useForAI
            self.checked = checked
            self.lastError = lastError
        }
    }

    public var status: Status {
        Status(hasKey: !state.apiKey.isEmpty, keyHint: OpenAIKeyRules.masked(state.apiKey), model: state.model, useForAI: state.useForAI,
               checked: state.checkedAt != nil, lastError: state.lastError)
    }

    /// Kostet den Nutzer Geld bei OpenAI: nie im Hintergrund (Vorab einordnen, Dokument-Index), nur nach Antippen
    public nonisolated var isMetered: Bool { true }

    private func persist() throws { try store.save(state) }

    // MARK: Schluessel

    /// Schluessel eintragen (Form pruefen, speichern); ein anderer Schluessel vergisst Pruefung, Fehler und Modellliste
    public func setKey(_ raw: String) throws {
        guard let key = OpenAIKeyRules.normalize(raw) else {
            throw AIError("openai_key_invalid", "Das sieht nicht nach einem OpenAI-API-Schlüssel aus (beginnt mit „sk-“, ohne Leerzeichen).")
        }
        if key != state.apiKey {
            state.apiKey = key
            state.checkedAt = nil
            state.lastError = nil
            modelsCache = nil
        }
        try persist()
    }

    /// Schluessel und alles dazu vom Geraet loeschen
    public func removeKey() throws {
        state = OpenAIKeyState()
        modelsCache = nil
        try store.remove()
    }

    public func setModel(_ slug: String) throws {
        let s = PyText.strip(slug)
        guard !s.isEmpty, PyText.length(s) <= 100, !s.unicodeScalars.contains(where: PyText.isSpace) else {
            throw AIError("openai_model_invalid", "Ungültiger Modellname.")
        }
        state.model = s
        state.lastError = nil
        try persist()
    }

    public func setUseForAI(_ on: Bool) throws {
        state.useForAI = on
        try persist()
    }

    // MARK: Modelle

    /// Chat-Modelle des Kontos (`GET /v1/models`), 10 Minuten gemerkt; `force` fragt neu (Verbindung testen). Ein
    /// gueltiger Schluessel merkt sich die Pruefung; ohne Modellwahl wird das Standardmodell gesetzt.
    public func models(force: Bool = false) async throws -> [String] {
        guard !state.apiKey.isEmpty else { throw AIError("openai_key_missing", "Kein OpenAI-Schlüssel eingetragen.") }
        if !force, let c = modelsCache, now() - c.at < 600 { return c.ids }
        let r: (status: Int, body: Data)
        do {
            r = try await http.send(AIHTTPRequest(method: "GET", url: ChatGPTConstants.modelsURL,
                                                  headers: ["Accept": "application/json", "Authorization": "Bearer \(state.apiKey)"]))
        } catch {
            throw AIError("ai_provider_unreachable", "OpenAI ist nicht erreichbar.")
        }
        guard (200..<300).contains(r.status) else {
            let e = Self.error(status: r.status, body: r.body)
            try remember(e)
            throw e
        }
        let json = (try? JSONValue.parse(r.body)) ?? .null
        let ids = OpenAIKeyRules.chatModels(ChatGPTProtocol.modelList(json).ids)
        modelsCache = (now(), ids)
        state.checkedAt = now()
        state.lastError = nil
        if state.model.isEmpty, let pick = OpenAIKeyRules.pickDefault(ids) { state.model = pick }
        try persist()
        return ids
    }

    /// "Verbindung testen": Modelle neu laden (prueft den Schluessel)
    public func test() async throws -> [String] { try await models(force: true) }

    // MARK: Anfragen

    public nonisolated func answer(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt, schema: nil)
    }

    public nonisolated func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        try await complete(system: system, prompt: prompt, schema: schema)
    }

    /// Antworttext der Responses API (Ereignisstrom wie mit dem ChatGPT-Abo); 401 = Schluessel ungueltig, 429 =
    /// Guthaben oder Rate, 404/400 mit Modell = Modell nicht verfuegbar (in den Einstellungen ein anderes waehlen)
    public func complete(system: String, prompt: String, schema: JSONValue? = nil) async throws -> String {
        guard status.enabledForAI else {
            throw AIError("openai_key_not_enabled", state.apiKey.isEmpty ? "Kein OpenAI-Schlüssel eingetragen."
                          : state.model.isEmpty ? "Bitte in den Einstellungen ein Modell wählen." : "KI über den eigenen Schlüssel ist ausgeschaltet.")
        }
        let body = ChatGPTProtocol.responsesBody(model: state.model, system: system, prompt: prompt, schema: schema).serialized()
        let headers = ["Authorization": "Bearer \(state.apiKey)", "Content-Type": "application/json", "Accept": "text/event-stream"]
        let r: (status: Int, body: Data)
        do {
            r = try await http.send(AIHTTPRequest(method: "POST", url: ChatGPTConstants.responsesURL, headers: headers, body: body))
        } catch {
            throw AIError("ai_provider_unreachable", "OpenAI ist nicht erreichbar.")
        }
        guard (200..<300).contains(r.status) else {
            let e = Self.error(status: r.status, body: r.body, model: state.model)
            try remember(e)
            throw e
        }
        do {
            let streamed = try ChatGPTProtocol.streamedText(r.body)
            if state.lastError != nil { state.lastError = nil; try persist() }
            return streamed.text
        } catch let e as AIError {
            throw AIError(e.code, e.message.replacingOccurrences(of: "ChatGPT", with: "OpenAI"))
        }
    }

    private func remember(_ e: AIError) throws {
        state.lastError = PyText.slice(e.message, 0, 300)
        try persist()
    }

    /// Fehler nach Status und Antwort von OpenAI; der Text nennt nie den Schluessel
    public static func error(status: Int, body: Data, model: String = "") -> AIError {
        let detail = ChatGPTSession.errorText(String(decoding: body.prefix(600), as: UTF8.self))
        switch status {
        case 401:
            return AIError("openai_key_invalid", "OpenAI lehnt den Schlüssel ab. Bitte in den Einstellungen prüfen oder einen neuen Schlüssel eintragen.")
        case 402, 429:
            let quota = detail.lowercased().contains("quota") || detail.lowercased().contains("billing")
            return AIError("openai_quota", quota ? "Dein OpenAI-Guthaben ist aufgebraucht oder es fehlt eine Zahlungsmethode (platform.openai.com → Billing)."
                                               : "OpenAI nimmt gerade zu viele Anfragen an (Rate-Limit). Bitte kurz warten und noch einmal versuchen.")
        case 403:
            return AIError("openai_forbidden", "OpenAI erlaubt diese Anfrage mit deinem Schlüssel nicht: \(PyText.slice(detail, 0, 200))")
        default:
            if ChatGPTSession.isModelRejection(status: status, body: body) {
                return AIError("openai_model", "Das Modell \(model.isEmpty ? "" : "„\(model)“ ")ist mit deinem Schlüssel nicht verfügbar. Bitte in den Einstellungen ein anderes wählen.")
            }
            return AIError("ai_provider_error", "OpenAI antwortete mit Fehler \(status): \(PyText.slice(detail, 0, 200))")
        }
    }
}
