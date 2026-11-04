import Foundation
import UniFlowCore

/// "Zuletzt benutzt" auf der Uebersicht und auf KI-Start (04.11.2026): Dokumente (`files.last_opened`, zuletzt
/// gelesene Seite), KI-Gespraeche (`TutorConversations`) und Wochentests (begonnen oder abgegeben) in einer Liste
/// nach Zeit, neuestes zuerst. Die Dokumente und Tests liefert `GET /api/recent?limit=` des lokalen Backends, die
/// Gespraeche liegen in der App; `merge` fuehrt beide zusammen (reine Funktion, UniFlowTests/RecentListAppTests.swift).
struct RecentItem: Identifiable, Equatable {
    enum Kind: String { case document, conversation, test }

    let kind: Kind
    /// Datei-ID (Dokument, Gespraech) bzw. Test-ID als Text
    let key: String
    let title: String
    let sub: String?
    /// Zeitpunkt (ISO, Berlin)
    let at: String
    /// Dokument und Gespraech: zuletzt gelesene Seite (1 = erste)
    let page: Int?

    var id: String { kind.rawValue + ":" + key }
    var fileID: String? { kind == .test || examAsk != nil ? nil : key }
    var testID: Int? { kind == .test ? Int(key) : examAsk?.testID }
    /// KI-Gespraech zu einer Aufgabe eines Wochentests ("Frag die KI zu Aufgabe n"): Test und Aufgabe
    var examAsk: (testID: Int, nr: String)? { kind == .conversation ? TutorConversations.parseExamKey(key) : nil }

    var icon: String {
        switch kind {
        case .document: return "file"
        case .conversation: return "sparkles"
        case .test: return "exam"
        }
    }

    var kindLabel: String {
        switch kind {
        case .document: return "Dokument"
        case .conversation: return "KI-Gespräch"
        case .test: return "Wochentest"
        }
    }

    /// Zeit fuer die Reihenfolge; unlesbare Zeiten ganz nach hinten
    var date: Date { Fmt.dateTime(at) ?? .distantPast }

    /// Dokumente und Tests aus `GET /api/recent` (`items`), Gespraeche aus der App (KI-Hilfe je Dokument, dazu Fragen
    /// auf KI-Start mit angehaengtem Dokument aus `AIRecents`); nach Zeit absteigend, je Art und Kennung nur der
    /// neueste Eintrag, hoechstens `limit`
    static func merge(backend: JSONValue?, conversations: [TutorConversations.Conversation], aiRecents: [AIRecents.Entry] = [],
                      limit: Int) -> [RecentItem] {
        var out: [RecentItem] = []
        for it in backend?.list("items") ?? [] {
            guard let kind = it.s("kind").flatMap(Kind.init(rawValue:)), let at = it.s("at"), !at.isEmpty else { continue }
            let key = it.s("id") ?? it.i("id").map(String.init) ?? ""
            guard !key.isEmpty else { continue }
            out.append(RecentItem(kind: kind, key: key, title: it.s("title") ?? "", sub: it.s("sub"), at: at, page: it.i("page")))
        }
        for c in conversations {
            // Gespraech zu einer Aufgabe eines Wochentests: Titel "Aufgabe n – <Testtitel>"
            if TutorConversations.parseExamKey(c.fileID) != nil {
                out.append(RecentItem(kind: .conversation, key: c.fileID, title: c.fileName ?? "KI-Gespräch", sub: "Wochentest", at: c.updatedAt, page: nil))
                continue
            }
            let q = c.lastQuestion.map { String($0.prefix(80)).replacingOccurrences(of: "\n", with: " ") }
            out.append(RecentItem(kind: .conversation, key: c.fileID, title: q.flatMap { $0.isEmpty ? nil : $0 } ?? "KI-Gespräch",
                                  sub: c.fileName, at: c.updatedAt, page: nil))
        }
        for e in aiRecents {
            guard let f = e.fileID, !f.isEmpty else { continue }      // ohne Dokument: steht unter "Zuletzt" auf KI-Start
            out.append(RecentItem(kind: .conversation, key: f, title: e.question, sub: e.fileName, at: e.at, page: nil))
        }
        var seen = Set<String>()
        let sorted = out.sorted { a, b in a.date == b.date ? a.id < b.id : a.date > b.date }
        return Array(sorted.filter { seen.insert($0.id).inserted }.prefix(max(0, limit)))
    }

    /// Unterzeile: "Dokument · Analysis · Seite 4 · Mo., 03.11." - nur, was es gibt
    var subtitle: String {
        var parts = [kindLabel]
        if let sub, !sub.isEmpty { parts.append(sub) }
        if let page, page > 1 { parts.append("Seite \(page)") }
        let d = UFFmt.short(String(at.prefix(10)))
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }
}
