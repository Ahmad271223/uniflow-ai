import Foundation
import UniFlowCore

// Auf Stud.IP-Nachrichten antworten (Entscheidung des Inhabers 05.11.2026, docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md):
// Ablauf des Antwortfensters ohne Oberflaeche. Empfaenger live aus dem Posteingang (`StudIPClient.replyContext`), Senden
// ueber den schreibenden Transport des Abgebens (`URLSessionStudIPWriter`), Anmeldung wie beim Abgleich
// (`StudIPSync.ensureSession`: pruefen, still erneuern, sonst "Anmelden"). Entwurf und Verlauf in den Einstellungen des
// Containers; keine Namen gespeichert.

/// Die Nachricht, auf die geantwortet wird (aus der gespeicherten Liste, `GET /api/studip/messages`)
struct MessageReplyOriginal: Equatable, Sendable {
    /// Kennung der App ("sp-msg-…")
    let localID: String
    let subject: String
    let text: String
    let senderLabel: String
    let sentAt: String?

    var rawID: String { StudIPMessageReply.rawID(localID) }

    init(localID: String, subject: String, text: String, senderLabel: String, sentAt: String?) {
        self.localID = localID
        self.subject = subject
        self.text = text
        self.senderLabel = senderLabel
        self.sentAt = sentAt
    }

    init?(_ m: JSONValue) {
        guard let id = m.s("id"), !id.isEmpty else { return nil }
        self.init(localID: id, subject: m.s("subject") ?? "", text: m.s("text") ?? "", senderLabel: m.s("sender") ?? "", sentAt: m.s("sent_at"))
    }
}

@MainActor
final class MessageReplyModel: ObservableObject {
    /// Abhaengigkeiten (App: `StudIPSync`; Tests: feste Antworten)
    struct Dependencies {
        var connected: @MainActor () -> Bool
        var ensureSession: @MainActor (UniRenewalTrigger) async -> StudIPSync.SessionReadiness
        /// Client mit den aktuellen Cookies (nach einer Erneuerung neu bauen)
        var client: @MainActor () -> StudIPClient
        /// Einstellungen des Containers (Entwurf, Verlauf)
        var defaults: UserDefaults
        var now: () -> Date = Date.init
    }

    enum Phase: Equatable {
        case loading
        case notConnected
        case needsLogin
        /// Antworten nicht moeglich (Systemnachricht, nicht mehr im Posteingang, Fehler beim Laden)
        case unavailable(String)
        case ready
        case sending
        case sent(StudIPReplyRecord)
    }

    let original: MessageReplyOriginal
    private let deps: Dependencies

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var context: StudIPReplyContext?
    /// Namen weiterer Empfaenger (nur bei "Alle", nur im Speicher)
    @Published private(set) var others: [StudIPPerson] = []
    @Published private(set) var loadingOthers = false
    @Published var mode: StudIPReplyMode { didSet { if oldValue != mode { saveDraft(); if mode == .all { Task { await loadOthers() } } } } }
    @Published var subject: String { didSet { if oldValue != subject { saveDraft() } } }
    @Published var text: String { didSet { if oldValue != text { saveDraft() } } }
    @Published var quote: Bool { didSet { if oldValue != quote { saveDraft() } } }
    @Published private(set) var errorMessage: String?
    /// "In Stud.IP antworten" anbieten
    @Published private(set) var offersWebFallback = false
    /// Zeitpunkt eines wiederhergestellten Entwurfs (Hinweis im Fenster)
    @Published private(set) var restoredDraftAt: Date?

    init(original: MessageReplyOriginal, mode: StudIPReplyMode, dependencies: Dependencies) {
        self.original = original
        self.deps = dependencies
        let draft = StudIPReplyDrafts.load(dependencies.defaults).draft(for: original.localID)
        self.mode = draft?.mode ?? mode
        self.subject = draft?.subject ?? StudIPMessageReply.replySubject(original.subject)
        self.text = draft?.text ?? ""
        self.quote = draft?.quote ?? false
        self.restoredDraftAt = draft?.savedAt
    }

    // MARK: Abgeleitet

    /// Empfaenger der Antwort (Absender, bei "Alle" die weiteren)
    var recipients: [StudIPPerson] {
        guard let c = context else { return [] }
        return [c.sender] + (mode == .all && c.allowsReplyAll ? others : [])
    }

    /// Zitat des Originals (nur wenn der Schalter an ist)
    var quoteText: String? {
        quote ? StudIPMessageReply.quote(original.text, senderName: context?.sender.name ?? original.senderLabel, sentAt: original.sentAt) : nil
    }

    var canSend: Bool {
        phase == .ready && !recipients.isEmpty && !loadingOthers && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var replyWebURL: URL { StudIPMessageReply.replyWebURL(base: StudIPSync.base, messageID: original.rawID) }

    // MARK: Ablauf

    /// Fenster geoeffnet: Sitzung, Empfaenger
    func start() async {
        phase = .loading
        errorMessage = nil
        offersWebFallback = false
        guard StudIPMessageReply.isReplyable(senderLabel: original.senderLabel) else {
            phase = .unavailable(StudIPMessageError.systemMessage.errorDescription ?? "")
            return
        }
        guard deps.connected() else { phase = .notConnected; return }
        switch await deps.ensureSession(.userAction) {
        case .needsUser: phase = .needsLogin; return
        case .notConnected: phase = .notConnected; return
        case .ready, .renewed, .unknown: break
        }
        do {
            let c = try await withRenewal { try await self.deps.client().replyContext(messageID: self.original.rawID) }
            context = c
            if !c.allowsReplyAll, mode == .all { mode = .sender }
            phase = .ready
            if mode == .all { await loadOthers() }
        } catch StudIPError.sessionExpired {
            phase = .needsLogin
        } catch let e as StudIPMessageError {
            offersWebFallback = e.offersWebFallback && e != .systemMessage
            phase = .unavailable(e.errorDescription ?? "")
        } catch {
            offersWebFallback = true
            phase = .unavailable(Self.message(error, sending: false))
        }
    }

    /// Nach einer Anmeldung im Fenster
    func signedIn() async { await start() }

    func loadOthers() async {
        guard let c = context, c.allowsReplyAll, others.isEmpty, !loadingOthers else { return }
        loadingOthers = true
        defer { loadingOthers = false }
        do {
            others = try await withRenewal { try await self.deps.client().recipientNames(c.otherRecipientIDs) }
        } catch StudIPError.sessionExpired {
            phase = .needsLogin
        } catch {
            others = c.otherRecipientIDs.map { StudIPPerson(id: $0, name: "Stud.IP-Nutzer/in") }
        }
    }

    /// "Senden": genau ein POST; nur bei abgelaufener Sitzung (Stud.IP hat nichts angenommen) nach der stillen
    /// Erneuerung ein zweiter Versuch
    func send() async {
        guard canSend else { return }
        let to = recipients
        let subject = self.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = StudIPMessageReply.body(text: text, quote: quoteText)
        phase = .sending
        errorMessage = nil
        offersWebFallback = false
        do {
            let id = try await withRenewal {
                try await self.deps.client().sendMessage(subject: subject, text: body, recipientIDs: to.map(\.id))
            }
            let record = StudIPReplyRecord(messageID: original.localID, at: deps.now(), subject: subject,
                                           text: text.trimmingCharacters(in: .whitespacesAndNewlines), quoted: quote, mode: mode,
                                           recipients: to.count, sentID: id)
            var log = StudIPReplyLog.load(deps.defaults)
            log.add(record)
            log.save(deps.defaults)
            var drafts = StudIPReplyDrafts.load(deps.defaults)
            drafts.remove(original.localID)
            drafts.save(deps.defaults)
            restoredDraftAt = nil
            phase = .sent(record)
        } catch StudIPError.sessionExpired {
            phase = .needsLogin
        } catch let e as StudIPMessageError {
            errorMessage = e.errorDescription
            offersWebFallback = e.offersWebFallback
            phase = .ready
        } catch {
            errorMessage = Self.message(error, sending: true)
            offersWebFallback = true
            phase = .ready
        }
    }

    /// "Entwurf verwerfen": Text leer, Betreff wie neu, Entwurf weg
    func discardDraft() {
        text = ""
        quote = false
        subject = StudIPMessageReply.replySubject(original.subject)
        restoredDraftAt = nil
        var drafts = StudIPReplyDrafts.load(deps.defaults)
        drafts.remove(original.localID)
        drafts.save(deps.defaults)
    }

    /// Entwurf bei jeder Aenderung sichern (nach dem Senden nicht mehr)
    private func saveDraft() {
        if case .sent = phase { return }
        if case .sending = phase { return }
        var drafts = StudIPReplyDrafts.load(deps.defaults)
        drafts.put(StudIPReplyDraft(messageID: original.localID, mode: mode, subject: subject, text: text, quote: quote, savedAt: deps.now()))
        drafts.save(deps.defaults)
    }

    /// Eine Anfrage; meldet Stud.IP "Sitzung abgelaufen", einmal still erneuern und mit neuem Client wiederholen
    private func withRenewal<T>(_ op: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch StudIPError.sessionExpired {
            switch await deps.ensureSession(.userAction) {
            case .ready, .renewed: return try await op()
            case .needsUser, .notConnected, .unknown: throw StudIPError.sessionExpired
            }
        }
    }

    // MARK: Regeln

    static func message(_ error: Error, sending: Bool) -> String {
        if let e = error as? StudIPMessageError { return e.errorDescription ?? "\(e)" }
        if let e = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(e.code) {
            return sending ? "Keine Verbindung. Die Nachricht wurde vermutlich nicht gesendet; prüfe in Stud.IP unter „Gesendet“."
                           : "Keine Verbindung zu Stud.IP. Versuche es gleich noch einmal."
        }
        if let e = error as? StudIPError { return e.description }
        return error.localizedDescription
    }
}

extension MessageReplyModel.Dependencies {
    /// App: Sitzung und Client aus dem Abgleich des Containers (schreibender Transport wie beim Abgeben)
    @MainActor
    static func live(studip: StudIPSync, defaults: UserDefaults) -> Self {
        Self(connected: { studip.offersStudIP && studip.hasStoredSession },
             ensureSession: { await studip.ensureSession($0) },
             client: {
                 let host = StudIPSync.base.host ?? ""
                 let writer: StudIPWritingTransport = DebugUniStub.studipWriter()
                     ?? URLSessionStudIPWriter(cookies: StudIPSync.ownCookies(studip.cookies.load(), host: host), host: host)
                 // wenige Anfragen auf Knopfdruck: kurze Pause, kleine Grenze (users/me, 3 Seiten, 20 Namen, Senden)
                 return StudIPClient(base: StudIPSync.base, transport: writer, pauseMillis: 100, maxRequests: 40)
             },
             defaults: defaults)
    }
}
