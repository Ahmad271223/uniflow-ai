import Foundation

/// Eigene Karteikarten wie app/server.py (`list_flashcards`, `add_flashcards`, `review_flashcard`,
/// `delete_flashcard`): Leitner-System mit fuenf Faechern, richtig -> naechstes Fach (Abstaende 1, 2, 4, 8, 16 Tage),
/// falsch -> Fach 1. Karten legt der Nutzer selbst an (keine KI in V1). Sie liegen in der Datenbank des Containers
/// (Apple-Nutzer, Hochschule), "heute" kommt von der Uhr des Backends (`date.today()` in Berlin).
///
/// Werte aus dem Rumpf wie in Python: Wahrheitswerte nach Python (`bool(...)`, `x and y`), Zahlen als int bzw. float
/// wie `json.loads` (PyJSON, damit in den Textspalten derselbe Text steht). Woran Python scheitert (Karte ist kein
/// Objekt, Liste als Wert, `cards` ist keine Liste), wird 500; wie bei `db.cursor()` bleibt dann nichts gespeichert.
/// Ersetzt die Platzhalter aus S2 (PendingServicesEndpoints).
enum FlashcardEndpoints: LocalEndpointModule {
    static let name = "Karteikarten"

    /// Tage bis zur naechsten Wiederholung je Fach 1...5
    static let intervals = [1, 2, 4, 8, 16]

    static func register(on router: LocalRouter) {
        router.get("/api/flashcards") { req, ctx in
            let due = try req.boolQuery("due") ?? false
            var sql = "SELECT fc.*, f.name AS file_name FROM flashcards fc LEFT JOIN files f ON f.id=fc.file_id WHERE 1=1"
            var params: [SQLiteValue] = []
            if let fileID = req.query("file_id"), !fileID.isEmpty {
                sql += " AND fc.file_id=?"
                params.append(.text(fileID))
            }
            if due {
                sql += " AND (fc.due IS NULL OR fc.due <= ?)"
                params.append(.text(ctx.clock.today))
            }
            sql += " ORDER BY fc.id DESC"
            let rows = try await ctx.database.rows(sql, params)
            return .json(.array(rows.map(JSONValue.object)))
        }

        router.post("/api/flashcards") { req, ctx in
            let body = try req.pythonObjectBody()
            let cards = try cardList(body.value("cards"))
            let fileID = body.value("file_id")
            let now = ctx.clock.nowISO, today = ctx.clock.today
            try await ctx.database.transaction { c in
                var subject: SQLiteValue = .null
                if truthy(fileID) {
                    let r = try c.queryOne("SELECT c.subject FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?",
                                           [try bind(fileID, "file_id")])
                    subject = r?["subject"] ?? .null
                }
                for card in cards {
                    guard case .object(let members) = card else {
                        throw LocalHTTPError(status: 500, message: "Karteikarte ist kein Objekt")   // c.get scheitert
                    }
                    let question = members.value("question"), answer = members.value("answer")
                    guard truthy(question), truthy(answer) else { continue }
                    try c.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due) VALUES (?,?,?,?,?,1,?)",
                                  [try bind(fileID, "file_id"), subject, try bind(question, "question"), try bind(answer, "answer"),
                                   .text(now), .text(today)])
                }
            }
            // wie Python: Zahl der gesendeten Karten, auch der uebersprungenen ohne Frage oder Antwort
            return .json(["ok": true, "count": .number(Double(cards.count))])
        }

        router.post("/api/flashcards/{card_id:int}/review") { req, ctx in
            let correct = truthy(try req.pythonObjectBody().value("correct"))
            let id = SQLiteValue.integer(Int64(req.intParam("card_id")))
            let today = LocalTimetable.today(ctx.clock)
            return .json(try await ctx.database.transaction { c -> JSONValue in
                // HTTPException(404) ohne Text wie in server.py
                guard let row = try c.queryOne("SELECT box FROM flashcards WHERE id=?", [id]) else { throw LocalHTTPError.notFound() }
                let box = correct ? try nextBox(row["box"]) : 1
                let due = BerlinClock.isoDate(today + (try interval(box)))
                try c.execute("UPDATE flashcards SET box=?, due=? WHERE id=?", [.integer(Int64(box)), .text(due), id])
                return ["box": .number(Double(box)), "due": .string(due)]
            })
        }

        // Regel G6 wie server._changed: kein Treffer -> 404 "Karteikarte nicht gefunden"
        router.delete("/api/flashcards/{card_id:int}") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("card_id")))
            try await ctx.database.transaction { c in
                if try c.execute("DELETE FROM flashcards WHERE id=?", [id]) == 0 { throw LocalHTTPError.notFound("Karteikarte nicht gefunden") }
            }
            return .ok
        }
    }

    // MARK: Leitner

    /// `min(5, (box or 1) + 1)`: NULL, 0 und leere Werte zaehlen als Fach 1. Was in Python scheitert (Text, Kommazahl
    /// unter 4, Bytes), wird 500. Nur Daten von aussen koennen anders als 1...5 sein.
    static func nextBox(_ v: SQLiteValue?) throws -> Int {
        let fail = LocalHTTPError(status: 500, message: "Fach der Karteikarte ist keine ganze Zahl")
        switch v {
        case nil, .null?: return 2
        case .integer(let b)?:
            if b == 0 { return 2 }
            return b >= 4 ? 5 : Int(b + 1)                                   // ohne Ueberlauf bei sehr grossen Werten
        case .real(let d)?:
            if d == 0 { return 2 }
            if d + 1 >= 5 { return 5 }                                       // min(5, x) gibt dann die ganze Zahl 5
            throw fail                                                       // Kommazahl als Listenindex: TypeError
        case .text(let s)?:
            if s.isEmpty { return 2 }
            throw fail
        case .blob(let b)?:
            if b.isEmpty { return 2 }
            throw fail
        }
    }

    /// `[1, 2, 4, 8, 16][box - 1]` mit Pythons Indizes von hinten (Fach 0 bis -4 nur bei Daten von aussen)
    static func interval(_ box: Int) throws -> Int {
        var i = box - 1
        if i < 0 { i += intervals.count }
        guard intervals.indices.contains(i) else { throw LocalHTTPError(status: 500, message: "Fach \(box) gibt es nicht") }
        return intervals[i]
    }

    // MARK: Werte wie in Python

    /// `body.get("cards") or []`; ein anderer wahrer Wert als eine Liste laesst Python beim Durchlaufen scheitern
    static func cardList(_ v: PyJSON?) throws -> [PyJSON] {
        guard truthy(v) else { return [] }
        guard case .array(let a)? = v else { throw LocalHTTPError(status: 500, message: "cards ist keine Liste von Karten") }
        return a
    }

    /// Wahrheitswert wie `bool(x)` in Python
    static func truthy(_ v: PyJSON?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .int(let digits)?: return digits != "0"
        case .float(let d)?: return d != 0                                     // auch NaN ist wahr wie in Python
        case .string(let s)?: return !s.isEmpty
        case .array(let a)?: return !a.isEmpty
        case .object(let m)?: return !m.isEmpty
        }
    }

    /// Parameter wie Pythons sqlite3: int als INTEGER (zu gross: OverflowError), float als REAL, True/False als 1/0;
    /// Listen und Objekte lassen sich nicht binden (500)
    static func bind(_ v: PyJSON?, _ field: String) throws -> SQLiteValue {
        switch v {
        case nil, .null?: return .null
        case .bool(let b)?: return .integer(b ? 1 : 0)
        case .int(let digits)?:
            guard let i = Int64(digits) else { throw LocalHTTPError(status: 500, message: "\(field): Zahl zu groß") }
            return .integer(i)
        case .float(let d)?: return .real(d)
        case .string(let s)?: return .text(s)
        case .array?, .object?: throw LocalHTTPError(status: 500, message: "\(field): Listen und Objekte lassen sich nicht speichern")
        }
    }
}
