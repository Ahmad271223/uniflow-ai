import Foundation

// StudiNow-KI auf dem iPad (05.11.2026, Entscheidung des Inhabers: KI in 1.0 ueber Pro AI). Das iPad hat Dateien,
// Seitentexte und Notizen selbst, der Dienst nicht; darum baut das lokale Backend den Prompt wie fuer das eigene ChatGPT
// und gibt ihn mit dem Sitzungs-Token des StudiNow-Kontos an den Dienst (`POST /api/ai/relay`, app/ai_relay.py), genau
// wie die Windows-App. Was Geld kostet, entscheidet allein der Dienst: Aufgabe aus einer festen Liste, System-Text,
// Schema, Recht des Tarifs, Kontingent, Credits, harte Obergrenze je Konto, Modellmischung (app/ai_router.py).
// "Ganzes Dokument" geht wie unter Windows an `POST /api/ai/document/{plan,step}` mit den Seitentexten des iPads.
//
// Reihenfolge der Bezahlung wie ueberall: Geteiltes/Gespeichertes (0 Credits, vorher im Endpunkt) -> eigenes ChatGPT,
// wenn verbunden (`LocalAI.provider` nimmt es zuerst) -> StudiNow-KI mit Credits.

/// Aufgabe einer KI-Anfrage fuer die StudiNow-KI, wie `ai.for_task(...)` in app/ai.py (Kontextvariable, damit die
/// Signatur von `AIProvider` gleich bleibt). Ohne Aufgabe antwortet die StudiNow-KI nicht (kein freier Prompt).
public struct AIRelayTask: Sendable, Equatable {
    /// `tutor:<modus>`, `flashcards`, `week_test`, `weekly`, `grade` (app/ai_relay.py `_tasks`)
    public var name: String
    /// gleiche Anfrage = gleiche Antwort beim Dienst (nur geteilte ganze Seiten, 0 Credits beim Treffer)
    public var cache = false
    /// "Neu erklaeren lassen": nicht aus dem Zwischenspeicher des Dienstes
    public var fresh = false
    /// Text fuer die Wahl des Modells (Markierung, Frage)
    public var routeText: String?
    /// Parameter des Wochentests (`week_test`)
    public var options: JSONValue?
    /// Wochentest mit Klausuraufgabe (`week_test`)
    public var exam: Bool?
    /// Ausschnitt der Seite als JPEG ("Bereich an KI"); nur bei `tutor:*`
    public var image: Data?
    public var requestID: String?
    /// StudiNow-Wissensbank (20.11.2026, app/wissensbank.py): Angaben zur Stelle (`datei`, `kurs`, `seite`, `text`) fuer
    /// `tutor:explain`/`tutor:steps`; geht nur mit, wenn der Dienst die Funktion meldet (`StudiNowAI.wissensbankEnabled`)
    public var wissensbank: JSONValue?

    public init(_ name: String, cache: Bool = false, fresh: Bool = false, routeText: String? = nil, options: JSONValue? = nil,
                exam: Bool? = nil, image: Data? = nil, requestID: String? = nil, wissensbank: JSONValue? = nil) {
        self.name = name
        self.cache = cache
        self.fresh = fresh
        self.routeText = routeText
        self.options = options
        self.exam = exam
        self.image = image
        self.requestID = requestID
        self.wissensbank = wissensbank
    }

    /// Aufgabe der laufenden Anfrage (nil = keine; dann antwortet nur das eigene ChatGPT)
    @TaskLocal public static var current: AIRelayTask?

    /// Aufgaben, die der Dienst kennt (`ai_relay._tasks`); `study_plan` = KI-Lernplan (07.11.2026, AIStudyPlan.swift)
    public static func isKnown(_ name: String) -> Bool {
        if name.hasPrefix("tutor:") { return AIPromptTexts.tutorModes.contains { "tutor:" + $0.key == name } }
        return ["flashcards", "week_test", "weekly", "grade", "study_plan", MailRewrite.task].contains(name)
    }

    /// `tutor:<modus>`; unbekannte Modi wie in app/ai.py als `explain`
    public static func tutor(_ mode: String) -> String {
        AIPromptTexts.tutorModes.contains { $0.key == mode } ? "tutor:" + mode : "tutor:explain"
    }

    /// `op` mit dieser Aufgabe ausfuehren; Rueckgabe dazu der Credits-Stand der letzten Antwort des Dienstes (`credits`
    /// mit `charged`, `replay`), `.null` ohne StudiNow-KI (eigenes ChatGPT)
    public static func run<T: Sendable>(_ task: AIRelayTask, _ op: @Sendable () async throws -> T) async throws -> (value: T, credits: JSONValue) {
        let r = try await runReport(task, op)
        return (r.value, r.credits)
    }

    /// Wie `run`, dazu die Felder der Wissensbank aus der Antwort des Dienstes (`AIRelayMeter.wissensbank`, sonst `.null`)
    public static func runReport<T: Sendable>(_ task: AIRelayTask, _ op: @Sendable () async throws -> T) async throws
        -> (value: T, credits: JSONValue, wissensbank: JSONValue) {
        let meter = AIRelayMeter()
        let value = try await AIRelayMeter.$current.withValue(meter) {
            try await $current.withValue(task) { try await op() }
        }
        return (value, meter.credits, meter.wissensbank)
    }
}

/// StudiNow-Wissensbank in der App (20.11.2026, app/wissensbank.py): Felder der Antwort des Dienstes und Texte.
/// Der Dienst entscheidet alles (Pro AI, LUH, Treffer ueber den Wortlaut, 1 Credit); die App zeigt nur das Abzeichen
/// und nach einer Wiederholung die Ja/Nein-Frage. Ein alter Dienst liefert die Felder nicht: dann zeigt die App nichts.
public enum Wissensbank {
    public static let badge = "Aus der StudiNow-Wissensbank"
    public static let question = "Gefällt dir diese Antwort besser?"
    public static let thanksYes = "Danke! Wir prüfen die Antwort und nehmen sie vielleicht in die Wissensbank auf."
    public static let thanksNo = "Danke für deine Rückmeldung."
    /// Modi, fuer die die App die Stelle mitschickt (wie `wissensbank.MODES` im Dienst)
    public static let modes: Set<String> = ["explain", "steps"]
    /// so viel Seitentext bzw. markierter Text geht hoechstens mit (wie `wissensbank.TEXT_MAX`)
    public static let textMax = 20_000
    /// Modi, in denen die Angaben zur Stelle an den Dienst gehen: dazu die freie Frage (`ask`) - der genaue Abgleich
    /// bleibt im Dienst auf explain/steps beschraenkt, bei einer Frage kann er der KI aber passende Auszuege mitgeben
    /// (`app/wissensbank_ki.py`, 22.11.2026)
    public static let requestModes: Set<String> = ["explain", "steps", "ask"]
    public static let contextLine = "Mit Wissen aus der StudiNow-Wissensbank"
    public static let rememberedLine = "Gemerkte KI-Antwort"
    /// Felder der Relay-Antwort, die die App weiterreicht
    static let fieldNames = ["source", "wissensbank_key", "wissensbank", "feedback_token", "feedback_question",
                             "wissensbank_kontext", "gemerkt"]

    /// Angaben zur Stelle fuer den Dienst: Dateititel wie in Stud.IP, Kurs, Seite und der verglichene Text (markierter
    /// Text, sonst die ganze Seite); nil, wenn der Modus nicht passt oder es keinen Text gibt.
    /// `teilbar`: In der Anfrage steckt nichts Persoenliches (keine Frage, keine eigene Loesung, kein Verlauf, keine
    /// eigenen Notizen - auch nicht im Bild). Nur dann darf der Dienst die KI-Antwort fuer andere merken bzw. eine
    /// gemerkte liefern; das Feld geht nur als `true` mit.
    public static func request(mode: String, fileName: String, course: String, page: Int, pageText: String, selection: String,
                               teilbar: Bool = false) -> JSONValue? {
        guard requestModes.contains(mode), !fileName.isEmpty else { return nil }
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = sel.isEmpty ? pageText : selection
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var o: [String: JSONValue] = ["datei": .string(fileName), "kurs": .string(course), "seite": .number(Double(page)),
                                      "text": .string(String(text.prefix(textMax)))]
        if teilbar, modes.contains(mode) { o["teilbar"] = true }
        return .object(o)
    }

    /// Felder der Wissensbank aus einer Antwort des Dienstes; `.null`, wenn er keine schickt (alter Dienst, Schalter aus)
    public static func fields(in response: JSONValue) -> JSONValue {
        var o: [String: JSONValue] = [:]
        for k in fieldNames { if let v = response[k], !v.isNull { o[k] = v } }
        let known = o["wissensbank_key"] != nil || ["wissensbank", "gemerkt"].contains(o["source"]?.string ?? "")
            || o["wissensbank_kontext"]?.bool == true
        return known ? .object(o) : .null
    }

    /// Antwort kommt aus der Wissensbank
    public static func isFromWissensbank(_ info: JSONValue?) -> Bool { info?["source"]?.string == "wissensbank" }

    /// Gemerkte KI-Antwort: die erste KI-Antwort zu genau dieser Stelle, vom Dienst an den Naechsten weitergegeben
    public static func isRemembered(_ info: JSONValue?) -> Bool { info?["source"]?.string == "gemerkt" }

    /// KI-Antwort, der der Dienst passende Auszuege aus der Wissensbank mitgegeben hat
    public static func usesContext(_ info: JSONValue?) -> Bool { info?["wissensbank_kontext"]?.bool == true }

    /// Solche Antworten gehen nie in den geteilten Erklaerungsspeicher: Sie enthalten Wissen aus der Bibliothek bzw.
    /// kommen schon aus einem Speicher des Dienstes (sonst landete das bei Konten ohne Wissensbank)
    public static func staysOutOfSharedStore(_ info: JSONValue?) -> Bool {
        isFromWissensbank(info) || isRemembered(info) || usesContext(info)
    }

    /// Zeile unter dem Abzeichen: "geprueft" bzw. die Hinweise der Bibliothek ("KI-Loesung, ungeprueft" ...)
    public static func detail(_ info: JSONValue?) -> String? {
        guard isFromWissensbank(info) else { return nil }
        var parts: [String] = []
        if let s = info?["wissensbank"]?["status"]?.string, !s.isEmpty { parts.append(s) }
        for h in info?["wissensbank"]?["hinweise"]?.array ?? [] { if let t = h.string, !t.isEmpty { parts.append(t) } }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Einmal-Kennung fuer die Ja/Nein-Frage (nur nach einer Wiederholung)
    public static func feedbackToken(_ info: JSONValue?) -> String? {
        guard let t = info?["feedback_token"]?.string, !t.isEmpty else { return nil }
        return t
    }
}

/// Ergebnis der letzten Anfrage an den Dienst in diesem Aufruf (wie `ai_relay._LAST`): Credits-Stand, Treffer im
/// Zwischenspeicher, Modell
public final class AIRelayMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _credits: JSONValue = .null
    private var _shared = false
    private var _wissensbank: JSONValue = .null

    public init() {}

    @TaskLocal public static var current: AIRelayMeter?

    public var credits: JSONValue { lock.withLock { _credits } }
    public var shared: Bool { lock.withLock { _shared } }
    /// Felder der Wissensbank der letzten Antwort (`Wissensbank.fields`), `.null` ohne
    public var wissensbank: JSONValue { lock.withLock { _wissensbank } }

    func record(_ response: JSONValue) {
        lock.withLock {
            if let c = response["credits"], !c.isNull { _credits = c }
            _shared = response["shared"]?.bool ?? false
            _wissensbank = Wissensbank.fields(in: response)
        }
    }
}

/// Handlung zu einem Fehler der StudiNow-KI (Knopf unter der Meldung)
public enum StudiNowAIAction: String, Sendable, Equatable {
    /// "Tarife ansehen" (Einstellungen → Konto & Tarif)
    case plans
    /// "Mit StudiNow-Konto anmelden" (Einstellungen → Konto & Tarif)
    case signIn
    /// "Credits kaufen": die Credits reichen nicht und das Konto darf Pakete kaufen (15.11.2026, CreditPacks.swift)
    case credits
}

/// Texte zu den Fehlern der StudiNow-KI (Status und Code des Dienstes, app/ai_relay.py, app/entitlements.py,
/// app/credits.py). Die Texte ersetzen die Meldung des Dienstes in der Antwort des lokalen Backends; der Code bleibt,
/// damit die Oberflaeche den passenden Knopf zeigt (`action`).
public enum StudiNowAIText {
    public static let accountRequired = "Melde dich mit deinem StudiNow-Konto an, dann antwortet die StudiNow-KI (Einstellungen → Konto & Tarif)."
    public static let sessionExpired = "Deine Anmeldung beim StudiNow-Konto ist abgelaufen. Bitte melde dich neu an."
    public static let unreachable = "Der StudiNow-Dienst ist gerade nicht erreichbar. Prüfe deine Internetverbindung und versuche es gleich noch einmal."
    public static let subscriptionRequired = "Für die StudiNow-KI brauchst du StudiNow Pro AI. Deine Probe ist vorbei oder dein Abo ist abgelaufen."
    public static let quotaExhausted = "Dein Monatskontingent für diese KI-Funktion ist aufgebraucht. Am 1. des nächsten Monats gibt es neues."
    public static let rateLimited = "Gerade kommen zu viele Anfragen auf einmal. Bitte warte einen Moment und versuche es dann erneut."
    public static let unavailable = "Die StudiNow-KI ist gerade nicht verfügbar. Bitte versuche es später erneut."
    /// 503 `ai_overloaded` / `ai_provider_busy` (app/ai_async.py, app/ai_providers.py), auch nach dem zweiten Versuch
    public static let busy = "Die StudiNow-KI ist gerade ausgelastet. Bitte versuche es in ein paar Sekunden noch einmal."
    public static let unsupported = "Diese KI-Funktion gibt es mit der StudiNow-KI auf dem iPad noch nicht."
    public static let badAnswer = "Unerwartete Antwort der StudiNow-KI. Bitte versuche es erneut."

    /// "Die StudiNow-KI gibt es ab StudiNow Pro AI …" je nach verlangtem Tarif (`required_plan`)
    public static func planRequired(_ required: String?) -> String {
        if required == "plus" { return "Diese KI-Funktion gibt es ab StudiNow Plus." }
        return "Die StudiNow-KI gehört zu StudiNow Pro AI (100 Credits im Monat) und zur 7-Tage-Probe."
    }

    /// Text fuer Status und Code des Dienstes; `serverMessage` bleibt bei unbekannten Codes und bei `credits_exhausted`
    /// (der Dienst nennt dort den Rest und den naechsten Monat)
    public static func message(status: Int, code: String, serverMessage: String, requiredPlan: String? = nil, retryAfter: Int? = nil) -> String {
        if let known = ServiceErrorText.known(code: code) { return known }
        switch code {
        case "account_required": return accountRequired
        case "unauthenticated": return sessionExpired
        case "service_unreachable": return unreachable
        case "subscription_required", "subscription_unverified": return subscriptionRequired
        case "plan_required": return planRequired(requiredPlan)
        case "quota_exhausted": return quotaExhausted
        case "rate_limited": return ServiceErrorText.retryHint(retryAfter).map { "\(rateLimited) (\($0))" } ?? rateLimited
        case "credits_exhausted": return serverMessage.isEmpty ? "Deine Credits für diesen Monat sind aufgebraucht. Am 1. gibt es neue." : serverMessage
        case "ai_task_unsupported": return unsupported
        case _ where StudiNowAI.busyCodes.contains(code): return busy
        default: break
        }
        if status == 402 { return subscriptionRequired }
        if status == 503 || status >= 500 && serverMessage.isEmpty { return unavailable }
        return serverMessage.isEmpty ? unavailable : serverMessage
    }

    /// Knopf zur Meldung: Tarif bei fehlendem Recht, Kontingent oder Credits; Anmeldung ohne (gueltige) Sitzung
    public static func action(code: String?) -> StudiNowAIAction? {
        switch code {
        case "subscription_required", "subscription_unverified", "plan_required", "quota_exhausted", "credits_exhausted",
             "ai_trial_budget_exhausted":
            return .plans
        case "account_required", "unauthenticated":
            return .signIn
        default:
            return nil
        }
    }
}

/// Ob die KI-Stellen des iPads die StudiNow-KI nutzen (rein, testbar). Reihenfolge der Pruefung wie in
/// docs/ABO-SYSTEM.md Abschnitt 6b: ohne Dienst-Adresse nie; angemeldet mit Pro AI oder laufender Probe (beim Dienst
/// oder auf dem iPad) bereit; Pro AI ohne Anmeldung -> "Mit StudiNow-Konto anmelden"; sonst der Tarif-Hinweis.
public enum StudiNowAIAccess: String, Sendable, Equatable {
    /// StudiNow-KI antwortet (Credits beim Dienst)
    case ready
    /// Pro AI bzw. Probe auf dem iPad, aber nicht beim StudiNow-Konto angemeldet
    case signInRequired
    /// Free oder Plus: Tarif-Hinweis, nichts wird gesendet
    case planRequired
    /// Build ohne Dienst-Adresse
    case unavailable

    /// - Parameters:
    ///   - localPlan: wirksamer Tarif auf dem iPad (App Store, Probe auf dem iPad), Schluessel wie `plans.ORDER`
    ///   - servicePlan: Tarif beim Dienst (`GET /api/entitlements` `plan`), nil solange nicht geladen
    ///   - serviceTrialActive: laufende Probe des Kontos (25 Credits)
    public static func decide(serviceConfigured: Bool, signedIn: Bool, localPlan: String, servicePlan: String?,
                              serviceTrialActive: Bool) -> StudiNowAIAccess {
        guard serviceConfigured else { return .unavailable }
        let proLocally = localPlan == "pro_ai"
        if signedIn {
            return proLocally || servicePlan == "pro_ai" || serviceTrialActive ? .ready : .planRequired
        }
        return proLocally ? .signInRequired : .planRequired
    }

    /// Nur der KI-Chat (Entscheidung des Inhabers 15.11.2026): angemeldet mit Plus (auf dem Geraet oder beim Dienst),
    /// ohne Pro AI und ohne Probe. Dann antwortet die StudiNow-KI auf die freie Frage, bezahlt allein aus gekauften
    /// Credits; alles andere (Erklaeren, Karteikarten, Tests) bleibt Pro AI. `decide` liefert dafuer weiter
    /// `.planRequired`, damit alle uebrigen KI-Stellen wie bisher den Tarif-Hinweis zeigen.
    public static func chatOnly(serviceConfigured: Bool, signedIn: Bool, localPlan: String, servicePlan: String?,
                                serviceTrialActive: Bool) -> Bool {
        guard serviceConfigured, signedIn,
              decide(serviceConfigured: serviceConfigured, signedIn: signedIn, localPlan: localPlan, servicePlan: servicePlan,
                     serviceTrialActive: serviceTrialActive) == .planRequired else { return false }
        return localPlan == "plus" || servicePlan == "plus"
    }
}

/// Die StudiNow-KI fuer Plus: nur der KI-Chat (`CreditPacks.chatTasks`, die freie Frage). Jede andere Aufgabe wird hier
/// abgewiesen, ohne dass etwas an den Dienst geht - der Dienst prueft dasselbe noch einmal (Recht der Route und
/// Reservierung der Credits).
public final class StudiNowChatAI: AIProvider, @unchecked Sendable {
    public let inner: StudiNowAI

    public init(_ inner: StudiNowAI) { self.inner = inner }

    public var isMetered: Bool { true }

    public func answer(system: String, prompt: String) async throws -> String {
        try await answer(system: system, prompt: prompt, schema: nil)
    }

    public func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        guard let task = AIRelayTask.current, CreditPacks.chatTasks.contains(task.name) else {
            throw StudiNowAI.error(403, "plan_required", CreditText.chatLock, extra: ["required_plan": "pro_ai"])
        }
        return try await inner.answer(system: system, prompt: prompt, schema: schema)
    }
}

/// Die StudiNow-KI als `AIProvider` des lokalen Backends: Prompt + Aufgabe an `POST /api/ai/relay`, Antworttext zurueck,
/// Credits-Stand in `AIRelayMeter.current`. Fehler des Dienstes kommen als `LocalHTTPError` mit Status, Code und
/// Zusatzfeldern (z. B. `credits`, `required_plan`) und einem Text aus `StudiNowAIText` bis zur Oberflaeche durch.
public final class StudiNowAI: AIProvider, @unchecked Sendable {
    public let base: String
    let http: ServiceHTTPTransport
    let tokens: AccountTokenStore
    /// Einwilligung vor jeder Anfrage (App Store 5.1.2(i), AIConsent.swift): ohne sie geht nichts an den Dienst
    let consent: AIConsentGate
    /// neuer Credits-Stand nach einer Antwort (App: Kostenzeile in KI-Hilfe und KI-Start)
    private let onCredits: (@Sendable (JSONValue) -> Void)?
    /// Sitzung beim Dienst abgelaufen (401): App meldet das Konto ab
    private let onSignedOut: (@Sendable () -> Void)?

    /// Groesstes Bild fuer `tutor:*` (wie `ai.TUTOR_IMAGE_MAX_BYTES`)
    public static let imageMaxBytes = AIEndpoints.tutorImageMaxBytes

    /// 503 "ausgelastet" des Dienstes (Notbremse `ai_overloaded` in app/ai_async.py, Rate-Limit des Anbieters
    /// `ai_provider_busy` in app/ai_providers.py, beide mit Retry-After): nichts wurde berechnet. Die App fragt einmal
    /// von selbst nach (Audit P43, 08.11.2026), mit derselben Anfrage, also derselben `request_id`, die der Dienst nie
    /// doppelt berechnet; danach `StudiNowAIText.busy`.
    public static let busyCodes: Set<String> = ["ai_overloaded", "ai_provider_busy"]
    /// hoechstens so lange vor dem zweiten Versuch warten (Retry-After des Dienstes: 3 bzw. 5 s; ohne Angabe 2 s)
    public static let busyRetryMaxSeconds = 10.0

    /// Wartezeit vor dem zweiten Versuch: Retry-After plus Streuung bis zum selben Betrag (`unit` 0...1), hoechstens
    /// `busyRetryMaxSeconds` (Audit P64-F7, 09.11.2026). Ohne Streuung kamen alle abgewiesenen Geraete genau nach 3 bzw.
    /// 5 s gleichzeitig wieder und trafen die Notbremse erneut.
    static func busyWait(retryAfter: Int?, unit: Double = Double.random(in: 0...1)) -> Double {
        let base = min(max(Double(retryAfter ?? 2), 0), busyRetryMaxSeconds)
        return min(base + base * min(max(unit, 0), 1), busyRetryMaxSeconds)
    }

    /// Warten vor dem zweiten Versuch (Tests ersetzen es)
    let retrySleep: @Sendable (Double) async throws -> Void

    private let flagLock = NSLock()
    private var _wissensbank = false
    /// Der Dienst meldet die Wissensbank fuer dieses Konto (`wissensbank: true` in GET /api/entitlements). Nur dann gehen
    /// die Angaben zur Stelle (`AIRelayTask.wissensbank`) mit; sonst bleibt die Anfrage wie bisher.
    public var wissensbankEnabled: Bool {
        get { flagLock.withLock { _wissensbank } }
        set { flagLock.withLock { _wissensbank = newValue } }
    }

    /// `consent` ist Pflicht (kein Standardwert): jede StudiNow-KI fragt vor der ersten Anfrage nach der Einwilligung
    public init(base: String, http: ServiceHTTPTransport, tokens: AccountTokenStore, consent: AIConsentGate,
                onCredits: (@Sendable (JSONValue) -> Void)? = nil, onSignedOut: (@Sendable () -> Void)? = nil,
                retrySleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) {
        self.base = base.hasSuffix("/") ? String(base.dropLast()) : base
        self.http = http
        self.tokens = tokens
        self.consent = consent
        self.onCredits = onCredits
        self.onSignedOut = onSignedOut
        self.retrySleep = retrySleep
    }

    public var isMetered: Bool { true }

    public func answer(system: String, prompt: String) async throws -> String {
        try await answer(system: system, prompt: prompt, schema: nil)
    }

    /// `system` und `schema` waehlt der Dienst selbst zur Aufgabe; gesendet werden nur Aufgabe und Prompt
    public func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        guard let task = AIRelayTask.current, AIRelayTask.isKnown(task.name) else {
            throw Self.error(404, "ai_task_unsupported", StudiNowAIText.unsupported)
        }
        var body: [String: JSONValue] = ["task": .string(task.name), "prompt": .string(prompt),
                                         "request_id": .string(String((task.requestID ?? Self.newRequestID()).prefix(80)))]
        if task.cache, task.image == nil { body["cache"] = true }
        if task.fresh { body["fresh"] = true }
        if let r = task.routeText, !r.isEmpty { body["route_text"] = .string(String(r.prefix(2000))) }
        if let o = task.options { body["options"] = o }
        if let e = task.exam { body["exam"] = .bool(e) }
        // auch mit Bild (21.11.2026): die Angaben tragen dann nur den im Ausschnitt erkannten Text (`AIEndpoints`)
        if let wb = task.wissensbank, wissensbankEnabled, task.name.hasPrefix("tutor:") { body["wissensbank"] = wb }
        if let image = task.image {
            guard task.name.hasPrefix("tutor:") else { throw Self.error(400, "image_not_allowed", "Bilder gibt es nur für die KI-Hilfe.") }
            guard image.count <= Self.imageMaxBytes else {
                throw Self.error(413, "image_invalid", "Der Bereich ist zu groß für die KI. Bitte einen kleineren Ausschnitt wählen.")
            }
            body["image"] = .string(image.base64EncodedString())
        }
        let d = try await json("POST", "/api/ai/relay", body: .object(body))
        guard let answer = d["answer"]?.string else { throw Self.error(502, "service_error", StudiNowAIText.badAnswer) }
        AIRelayMeter.current?.record(d)
        return answer
    }

    /// `request_id` je Anfrage: dieselbe Kennung wird beim Dienst nie zweimal berechnet
    static func newRequestID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func error(_ status: Int, _ code: String, _ message: String, extra: [String: JSONValue] = [:]) -> LocalHTTPError {
        var d: [String: JSONValue] = ["detail": .string(message), "code": .string(code)]
        for (k, v) in extra where k != "detail" && k != "code" { d[k] = v }
        return LocalHTTPError(status: status, detail: .object(d))
    }

    /// Datei vom Dienst laden (Klausur-Generator: PDF einer gekauften Probeklausur). Wie `json`: nur mit Token und
    /// Einwilligung; Fehler als `LocalHTTPError`.
    public func download(_ path: String) async throws -> Data {
        guard let token = tokens.load(), !token.isEmpty else {
            throw Self.error(401, "account_required", StudiNowAIText.accountRequired)
        }
        guard await consent.ensureConsent() else {
            throw Self.error(403, AIConsentText.code, AIConsentText.declined)
        }
        let r: ServiceHTTPResponse
        do {
            r = try await http.send(AIHTTPRequest(method: "GET", url: base + path, headers: ["Authorization": "Bearer \(token)"]))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.error(503, "service_unreachable", StudiNowAIText.unreachable)
        }
        guard (200..<300).contains(r.status) else {
            if r.status == 401 {
                try? tokens.save(nil)
                onSignedOut?()
                throw Self.error(401, "account_required", StudiNowAIText.sessionExpired)
            }
            let j = (try? JSONValue.parse(r.body)) ?? .null
            let fields = (j["detail"]?.object ?? j.object) ?? [:]
            throw Self.error(r.status, fields["code"]?.string ?? "http_\(r.status)", fields["detail"]?.string ?? StudiNowAIText.badAnswer)
        }
        return r.body
    }

    /// JSON-Anfrage an den Dienst mit dem Token des Kontos (wie `ai_relay.service_json`); Fehler als `LocalHTTPError`
    /// mit Status, Code, Zusatzfeldern und Text aus `StudiNowAIText`. Ohne Token und ohne Einwilligung
    /// (`AIConsentGate`, 403 `ai_consent_required`) wird nichts gesendet.
    public func json(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        guard let token = tokens.load(), !token.isEmpty else {
            throw Self.error(401, "account_required", StudiNowAIText.accountRequired)
        }
        guard await consent.ensureConsent() else {
            throw Self.error(403, AIConsentText.code, AIConsentText.declined)
        }
        try Task.checkCancellation()
        var headers = ["Accept": "application/json", "Authorization": "Bearer \(token)"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let data = body?.serialized()
        for attempt in 0..<2 {
            let r: ServiceHTTPResponse
            do {
                r = try await http.send(AIHTTPRequest(method: method, url: base + path, headers: headers, body: data))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // "Stopp" in der KI-Hilfe (11.11.2026): URLSession bricht mit URLError(.cancelled) ab - das ist kein
                // "Dienst nicht erreichbar", sondern ein Abbruch, und so geht er bis zur Oberflaeche
                if Task.isCancelled { throw CancellationError() }
                throw Self.error(503, "service_unreachable", StudiNowAIText.unreachable)
            }
            let j = (try? JSONValue.parse(r.body)) ?? .null
            guard (200..<300).contains(r.status) else {
                // FastAPI: {"detail": {...}} oder {"detail": "...", "code": ...}
                var fields = (j["detail"]?.object ?? j.object) ?? [:]
                if let top = j.object { for (k, v) in top where k != "detail" && fields[k] == nil { fields[k] = v } }
                let code = fields["code"]?.string ?? (r.status == 401 ? "unauthenticated" : "http_\(r.status)")
                let server = fields["detail"]?.string ?? j["detail"]?.string ?? ""
                let retry = r.headers.first { $0.key.lowercased() == "retry-after" }.flatMap { Int($0.value) } ?? fields["retry_after"]?.int
                if r.status == 401 {
                    try? tokens.save(nil)
                    onSignedOut?()
                    throw Self.error(401, "account_required", StudiNowAIText.sessionExpired)
                }
                // ausgelastet: einmal nach Retry-After (hoechstens `busyRetryMaxSeconds`) dieselbe Anfrage noch einmal
                if attempt == 0, r.status == 503, Self.busyCodes.contains(code) {
                    try await retrySleep(Self.busyWait(retryAfter: retry))
                    try Task.checkCancellation()
                    continue
                }
                let text = StudiNowAIText.message(status: r.status, code: code, serverMessage: server,
                                                  requiredPlan: fields["required_plan"]?.string, retryAfter: retry)
                throw Self.error(r.status, code, text, extra: fields)
            }
            guard j.object != nil else { throw Self.error(502, "service_error", StudiNowAIText.badAnswer) }
            if let c = j["credits"], c.object != nil { onCredits?(c) }
            return j
        }
        throw Self.error(503, "ai_overloaded", StudiNowAIText.busy)
    }
}
