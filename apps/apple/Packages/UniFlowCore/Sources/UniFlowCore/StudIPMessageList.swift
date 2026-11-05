import Foundation

// Seite "Nachrichten" (04.11.2026): alle auf dem Geraet gespeicherten Stud.IP-Nachrichten (Tabelle studip_messages,
// gefuellt von `StudIPExtras.store`, nur die Liste des Posteingangs) fuer GET /api/studip/messages?q=. Nur lesend, keine
// Python-Entsprechung (der PC-Server gleicht den Posteingang nicht ab, docs/paritaet/ipad-app.md). Die Nachrichten
// gehen von hier an keine KI und keinen Dienst.

extension StudIPExtras {

    /// Zeitpunkt einer Stud.IP-Zeitangabe ("2026-11-02T08:15:00+01:00", auch mit Sekundenbruchteilen); nil, wenn
    /// unlesbar. Fuer die Reihenfolge (Zeitzonen-Versatz kann im Herbst wechseln) und fuer "neu seit".
    public static func messageInstant(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Passt eine Nachricht zur Suche? Jedes Wort der Suche muss in Absender, Betreff oder Text stehen (ohne Gross-/
    /// Kleinschreibung und Akzente: "prufung" findet "Prüfung")
    static func messageMatches(_ m: JSONValue, words: [String]) -> Bool {
        let hay = [str(m["sender"]), str(m["subject"]), str(m["text"])].joined(separator: "\n")
        return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// `GET /api/studip/messages?q=`: {messages: [{id, sender, subject, text, sent_at, url, dates, recipients}], total, fetched_at, q}.
    /// `recipients`: Zahl der Empfaenger mit einem selbst (fuer "Allen antworten"), null, wenn Stud.IP sie nicht nennt.
    /// Neueste zuerst (nach Zeitpunkt, bei Gleichstand nach Kennung); `total` zaehlt alle gespeicherten, `fetched_at`
    /// ist der juengste Abruf (nil ohne Nachrichten). Ohne Tabelle (noch kein Abgleich) leer.
    public static func messageList(_ c: SQLiteConnection, query: String? = nil) throws -> JSONValue {
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var all: [JSONValue] = []
        var fetched: String?
        if try has(c, "studip_messages") {
            let meta = try messageMeta(c)
            for r in try c.rows("SELECT id, sender, subject, preview, sent_at, url, dates, fetched_at FROM studip_messages") {
                let dates = (r["dates"]?.string).flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .array([])
                all.append(["id": r["id"] ?? .null, "sender": r["sender"] ?? .null, "subject": r["subject"] ?? .null,
                            "text": r["preview"] ?? .null, "sent_at": r["sent_at"] ?? .null, "url": r["url"] ?? .null,
                            "dates": dates.array != nil ? dates : .array([]),
                            "recipients": (r["id"]?.string).flatMap { meta[$0] }.map { .number(Double($0)) } ?? .null])
                if let f = r["fetched_at"]?.string, !f.isEmpty, fetched.map({ PyText.less($0, f) }) ?? true { fetched = f }
            }
        }
        let sorted = all.sorted { a, b in
            let x = messageInstant(a["sent_at"]?.string), y = messageInstant(b["sent_at"]?.string)
            switch (x, y) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                let sa = str(a["sent_at"]), sb = str(b["sent_at"])
                return sa != sb ? PyText.less(sb, sa) : PyText.less(str(a["id"]), str(b["id"]))
            }
        }
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = words.isEmpty ? sorted : sorted.filter { messageMatches($0, words: words) }
        return ["messages": .array(shown), "total": .number(Double(all.count)), "fetched_at": fetched.map(JSONValue.string) ?? .null,
                "q": .string(q)]
    }
}
