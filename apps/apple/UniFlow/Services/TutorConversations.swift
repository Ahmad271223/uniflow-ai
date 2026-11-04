import Foundation
import UniFlowCore

/// Gespraeche der KI-Hilfe je Dokument (Weitermachen wie zuvor, 04.11.2026): die letzten 15 Gespraeche mit allen
/// Beitraegen (Fragen, Antworten, Karten, Quellen, Modus fuer die Anschlussfragen, `explain` fuer "Schon erklärt")
/// liegen als JSON-Datei im Container (`<Container>/tutor-conversations.json`), das aelteste faellt heraus. Nichts
/// davon verlaesst das Geraet. Der Editor laedt das Gespraech des Dokuments beim Oeffnen der KI-Hilfe und schreibt
/// jede Aenderung; "Neu" loescht es. Dazu die Quelle fuer "Zuletzt benutzt" (KI-Gespraeche).
@MainActor
final class TutorConversations: ObservableObject {
    struct Message: Codable, Equatable {
        var fromUser: Bool
        var text: String
        var cards: [JSONValue] = []
        var sources: [JSONValue] = []
        var saved = false
        var mode = "ask"
        var explain: JSONValue? = nil
    }

    struct Conversation: Codable, Equatable, Identifiable {
        var fileID: String
        var fileName: String?
        var messages: [Message]
        /// letzter Beitrag (ISO, Berlin, wie das Backend)
        var updatedAt: String
        var id: String { fileID }
        /// letzte Frage des Nutzers (Beschriftung in "Zuletzt benutzt")
        var lastQuestion: String? { messages.last { $0.fromUser }?.text }
    }

    static let keep = 15

    /// Gespraeche aus "Frag die KI zu Aufgabe n" (Ergebnis eines Wochentests, 04.11.2026) liegen in derselben Liste
    /// unter "exam:<Test-ID>:<Aufgabe>" statt einer Datei-ID; `fileName` ist dann der Titel "Aufgabe n – <Testtitel>"
    nonisolated static let examPrefix = "exam:"

    nonisolated static func examKey(testID: Int, nr: String) -> String { "\(examPrefix)\(testID):\(nr)" }

    /// (Test, Aufgabe) aus einem Schluessel; nil fuer Gespraeche zu Dokumenten
    nonisolated static func parseExamKey(_ key: String) -> (testID: Int, nr: String)? {
        guard key.hasPrefix(examPrefix) else { return nil }
        let rest = key.dropFirst(examPrefix.count)
        guard let colon = rest.firstIndex(of: ":"), let id = Int(rest[..<colon]) else { return nil }
        let nr = String(rest[rest.index(after: colon)...])
        return nr.isEmpty ? nil : (id, nr)
    }
    static let fileName = "tutor-conversations.json"
    /// folgt dem aktiven Container (die App); Tests und Vorschauen bekommen eine eigene Datei
    static let shared = TutorConversations()

    @Published private(set) var conversations: [Conversation] = []
    private let fixedURL: URL?
    private var loadedFrom: URL?
    var now: () -> Date = Date.init

    init(fileURL: URL? = nil) {
        fixedURL = fileURL
        reload()
    }

    /// Datei des aktiven Containers (nil ohne Container: nichts lesen, nichts schreiben)
    private var url: URL? {
        fixedURL ?? ActiveContainer.current.map { $0.layout.root.appendingPathComponent(Self.fileName) }
    }

    /// Container gewechselt (Konto, Hochschule): dessen Datei lesen
    private func follow() {
        guard let u = url else { conversations = []; loadedFrom = nil; return }
        if loadedFrom != u { reload(from: u) }
    }

    func reload() { if let u = url { reload(from: u) } }

    private func reload(from u: URL) {
        loadedFrom = u
        conversations = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode([Conversation].self, from: $0) } ?? []
    }

    private func persist() {
        guard let u = url, let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: u, options: .atomic)
    }

    /// Gespraech zu einem Dokument (leer, wenn keins gemerkt ist)
    func messages(for fileID: String) -> [Message] {
        follow()
        return conversations.first { $0.fileID == fileID }?.messages ?? []
    }

    /// Stand nach jeder Aenderung merken (neuestes zuerst, hoechstens `keep`); leere Gespraeche werden entfernt
    func save(fileID: String, fileName: String?, messages: [Message]) {
        follow()
        guard !messages.isEmpty else { clear(fileID: fileID); return }
        let c = Conversation(fileID: fileID, fileName: fileName ?? conversations.first { $0.fileID == fileID }?.fileName,
                             messages: messages, updatedAt: Fmt.isoDateTime(now()))
        conversations = Array(([c] + conversations.filter { $0.fileID != fileID }).prefix(Self.keep))
        persist()
    }

    func clear(fileID: String) {
        follow()
        guard conversations.contains(where: { $0.fileID == fileID }) else { return }
        conversations.removeAll { $0.fileID == fileID }
        persist()
    }

    /// Alle Gespraeche, neuestes zuerst (fuer "Zuletzt benutzt")
    func recent() -> [Conversation] {
        follow()
        return conversations
    }
}
