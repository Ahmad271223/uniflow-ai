import Foundation

/// Eine KI, die Prompts beantwortet (auf dem iPad: das ChatGPT-Abo des Nutzers, `ChatGPTSession`)
public protocol AIProvider: Sendable {
    /// Antworttext; wirft `AIError` mit Code und Meldung fuer den Nutzer
    func answer(system: String, prompt: String) async throws -> String
    /// Antwort in der Form eines JSON-Schemas (Karteikarten aus einem Dokument); eine KI ohne Schema-Unterstuetzung
    /// antwortet wie ohne Schema, der Prompt verlangt die Form ohnehin
    func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String
}

public extension AIProvider {
    func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        try await answer(system: system, prompt: prompt)
    }
}

extension ChatGPTSession: AIProvider {
    public func answer(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt)
    }

    public func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        try await complete(system: system, prompt: prompt, schema: schema)
    }
}

/// KI-Anschluss des lokalen Backends: die App setzt die KI, sobald der Nutzer ChatGPT verbunden und eingeschaltet hat,
/// und nimmt sie beim Trennen wieder weg. Ohne KI antworten die KI-Endpunkte wie bisher "gibt es in dieser Version
/// nicht" (nichts wird vorgetaeuscht).
public final class LocalAI: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AIProvider?

    public init() {}

    public var provider: AIProvider? { lock.withLock { current } }

    public func set(_ provider: AIProvider?) { lock.withLock { current = provider } }
}
