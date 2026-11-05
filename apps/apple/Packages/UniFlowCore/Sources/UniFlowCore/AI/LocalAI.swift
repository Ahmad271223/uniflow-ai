import Foundation

/// Eine KI, die Prompts beantwortet (auf dem iPad: das ChatGPT-Abo des Nutzers, `ChatGPTSession`)
public protocol AIProvider: Sendable {
    /// Antworttext; wirft `AIError` mit Code und Meldung fuer den Nutzer
    func answer(system: String, prompt: String) async throws -> String
    /// Antwort in der Form eines JSON-Schemas (Karteikarten aus einem Dokument); eine KI ohne Schema-Unterstuetzung
    /// antwortet wie ohne Schema, der Prompt verlangt die Form ohnehin
    func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String
    /// Kostet jede Anfrage Credits beim Dienst (StudiNow-KI)? Dann nie im Hintergrund (Vorab einordnen, Index), nur auf
    /// Antippen; das eigene ChatGPT kostet StudiNow nichts.
    var isMetered: Bool { get }
}

public extension AIProvider {
    func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        try await answer(system: system, prompt: prompt)
    }

    var isMetered: Bool { false }
}

extension ChatGPTSession: AIProvider {
    public func answer(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt)
    }

    public func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        try await complete(system: system, prompt: prompt, schema: schema)
    }
}

/// KI-Anschluss des lokalen Backends mit zwei Plaetzen in der Reihenfolge der Bezahlung: das eigene ChatGPT (`set`,
/// sobald verbunden und eingeschaltet) und die StudiNow-KI (`setService`, angemeldet mit Pro AI oder Probe,
/// StudiNowAI.swift). `provider` nimmt das eigene ChatGPT zuerst. Ohne beides antworten die KI-Endpunkte wie bisher
/// "gibt es in dieser Version nicht" (nichts wird vorgetaeuscht, nichts gesendet).
public final class LocalAI: @unchecked Sendable {
    private let lock = NSLock()
    private var own: AIProvider?
    private var service: AIProvider?

    public init() {}

    /// KI fuer Anfragen nach Antippen: eigenes ChatGPT vor der StudiNow-KI
    public var provider: AIProvider? { lock.withLock { own ?? service } }

    /// KI fuer Arbeit im Hintergrund (Vorab einordnen, Erklaerungen vorab): nie eine, die Credits kostet
    public var backgroundProvider: AIProvider? { lock.withLock { [own, service].compactMap { $0 }.first { !$0.isMetered } } }

    /// StudiNow-KI des Kontos (nil ohne Anmeldung, ohne Pro AI/Probe)
    public var serviceProvider: AIProvider? { lock.withLock { service } }

    /// Eigenes ChatGPT setzen bzw. wegnehmen
    public func set(_ provider: AIProvider?) { lock.withLock { own = provider } }

    /// StudiNow-KI setzen bzw. wegnehmen
    public func setService(_ provider: AIProvider?) { lock.withLock { service = provider } }
}
