import Foundation

/// Eine KI, die Prompts beantwortet (auf dem iPad: das ChatGPT-Abo des Nutzers, `ChatGPTSession`)
public protocol AIProvider: Sendable {
    /// Antworttext; wirft `AIError` mit Code und Meldung fuer den Nutzer
    func answer(system: String, prompt: String) async throws -> String
}

extension ChatGPTSession: AIProvider {
    public func answer(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt)
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
