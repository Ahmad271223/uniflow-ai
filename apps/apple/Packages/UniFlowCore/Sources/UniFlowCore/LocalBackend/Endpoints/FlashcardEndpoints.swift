import Foundation

/// Eigene Karteikarten wie app/server.py (`list_flashcards`, `add_flashcards`, `review_flashcard`, `patch_flashcard`,
/// `delete_flashcard`) und ihre Stapel (`/api/flashcard-stacks`, 04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md):
/// Leitner-System mit fuenf Faechern, richtig -> naechstes Fach (Abstaende 1, 2, 4, 8, 16 Tage), falsch -> Fach 1.
/// Jede Karte gehoert zu genau einem Stapel (Name, Modul = Fach, optional Quelldokument); geuebt wird in EINEM Stapel
/// (`?stack_id=`), "Heute faellig" zaehlt je Stapel. Frage, Antwort, Fach und Stapel einer Karte lassen sich
/// nachtraeglich aendern (PATCH), Fach und Faelligkeit (Leitner) bleiben dabei. Die Karten liegen in der Datenbank des
/// Containers (Apple-Nutzer, Hochschule), "heute" kommt von der Uhr des Backends (`date.today()` in Berlin).
///
/// Werte aus dem Rumpf wie in Python: Wahrheitswerte nach Python (`bool(...)`, `x and y`), Zahlen als int bzw. float
/// wie `json.loads` (PyJSON, damit in den Textspalten derselbe Text steht). Woran Python scheitert (Karte ist kein
/// Objekt, Liste als Wert, `cards` ist keine Liste), wird 500; wie bei `db.cursor()` bleibt dann nichts gespeichert.
/// Fixture: packages/shared-contracts/fixtures/local-backend/flashcards.json (tools/gen-flashcards-fixture.py).
enum FlashcardEndpoints: LocalEndpointModule {
    static let name = "Karteikarten"

    /// Tage bis zur naechsten Wiederholung je Fach 1...5
    static let intervals = [1, 2, 4, 8, 16]

    /// `STACK_SQL`: Stapel mit Dateiname, Zahl der Karten und der heute faelligen (erster Parameter: heute)
    static let stackSQL = "SELECT s.*, f.name AS file_name, (SELECT COUNT(*) FROM flashcards fc WHERE fc.stack_id = s.id) AS cards, "
        + "(SELECT COUNT(*) FROM flashcards fc WHERE fc.stack_id = s.id AND (fc.due IS NULL OR fc.due <= ?) AND COALESCE(fc.hidden, 0) = 0) AS due "
        + "FROM flashcard_stacks s LEFT JOIN files f ON f.id = s.file_id"

    static func register(on router: LocalRouter) {
        // MARK: Stapel

        router.get("/api/flashcard-stacks") { _, ctx in
            let today = ctx.clock.today
            let rows = try await ctx.database.transaction { c -> [[String: JSONValue]] in
                try ensureStacks(c)
                return try c.rows(stackSQL + " ORDER BY s.id DESC", [.text(today)])
            }
            return .json(.array(rows.map(JSONValue.object)))
        }

        // Neuer Stapel: name (Pflicht), subject (Fach, sonst das Fach des Dokuments), file_id (optionales Quelldokument)
        router.post("/api/flashcard-stacks") { req, ctx in
            let body = try req.pythonObjectBody()
            let name = try stackName(body.value("name"))
            let now = ctx.clock.nowISO, today = ctx.clock.today
            return .json(try await ctx.database.transaction { c -> JSONValue in
                let fileID = try fileValue(c, body.value("file_id"))
                var subject = try subjectValue(body.value("subject"))
                let f = fileID.isNull ? nil : try fileInfo(c, fileID)
                if !body.has("subject"), let f { subject = f["subject"] ?? .null }
                var (kind, week) = stackMeta(f)
                if body.has("week") { week = try weekValue(body.value("week")) }
                if body.has("kind") { kind = .text(try kindValue(body.value("kind"))) }
                try c.execute("INSERT INTO flashcard_stacks(name, subject, file_id, created_at, kind, week) VALUES (?,?,?,?,?,?)",
                              [.text(name), subject, fileID, .text(now), kind, week])
                return try stackRow(c, .integer(c.lastInsertRowID), today) ?? .null
            })
        }

        // Umbenennen, in ein anderes Modul verschieben (die Karten folgen), Quelldokument setzen oder loesen
        router.patch("/api/flashcard-stacks/{stack_id:int}") { req, ctx in
            let body = try req.pythonObjectBody()
            let id = SQLiteValue.integer(Int64(req.intParam("stack_id")))
            let today = ctx.clock.today
            var given: [String] = [], givenParams: [SQLiteValue] = []
            if body.has("name") { given.append("name=?"); givenParams.append(.text(try stackName(body.value("name")))) }
            if body.has("subject") { given.append("subject=?"); givenParams.append(try subjectValue(body.value("subject"))) }
            if body.has("week") { given.append("week=?"); givenParams.append(try weekValue(body.value("week"))) }
            if body.has("kind") { given.append("kind=?"); givenParams.append(.text(try kindValue(body.value("kind")))) }
            let base = (sets: given, params: givenParams)
            return .json(try await ctx.database.transaction { c -> JSONValue in
                var sets = base.sets, params = base.params
                if body.has("file_id") { sets.append("file_id=?"); params.append(try fileValue(c, body.value("file_id"))) }
                guard try c.queryOne("SELECT id FROM flashcard_stacks WHERE id=?", [id]) != nil else { throw LocalHTTPError.notFound("Stapel nicht gefunden") }
                if !sets.isEmpty { try c.execute("UPDATE flashcard_stacks SET \(sets.joined(separator: ", ")) WHERE id=?", params + [id]) }
                if body.has("subject") {
                    try c.execute("UPDATE flashcards SET subject=? WHERE stack_id=?", [try subjectValue(body.value("subject")), id])
                }
                return try stackRow(c, id, today) ?? .null
            })
        }

        // Loeschen: ohne move_to samt Karten, mit move_to wandern die Karten (mit Lernstand) in den Zielstapel und
        // bekommen dessen Fach
        router.delete("/api/flashcard-stacks/{stack_id:int}") { req, ctx in
            let stackID = req.intParam("stack_id")
            let moveTo = try WeeklyEndpoints.intQuery(req, "move_to")
            let id = SQLiteValue.integer(Int64(stackID))
            return .json(try await ctx.database.transaction { c -> JSONValue in
                guard try c.queryOne("SELECT id FROM flashcard_stacks WHERE id=?", [id]) != nil else { throw LocalHTTPError.notFound("Stapel nicht gefunden") }
                var moved = 0, deleted = 0
                if let moveTo {
                    if moveTo == stackID { throw LocalHTTPError(status: 422, message: "Zielstapel ist der gelöschte Stapel") }
                    guard let target = try c.queryOne("SELECT id, subject FROM flashcard_stacks WHERE id=?", [.integer(Int64(moveTo))]) else {
                        throw LocalHTTPError.notFound("Zielstapel nicht gefunden")
                    }
                    moved = try c.execute("UPDATE flashcards SET stack_id=?, subject=? WHERE stack_id=?",
                                          [.integer(Int64(moveTo)), target["subject"] ?? .null, id])
                } else {
                    deleted = try c.execute("DELETE FROM flashcards WHERE stack_id=?", [id])
                }
                try c.execute("DELETE FROM flashcard_stacks WHERE id=?", [id])
                return ["ok": true, "moved": .number(Double(moved)), "deleted": .number(Double(deleted))]
            })
        }

        // MARK: Karten

        router.get("/api/flashcards") { req, ctx in
            let due = try req.boolQuery("due") ?? false
            let stackID = try WeeklyEndpoints.intQuery(req, "stack_id")
            var sql = "SELECT fc.*, f.name AS file_name, s.name AS stack_name FROM flashcards fc LEFT JOIN files f ON f.id=fc.file_id "
                + "LEFT JOIN flashcard_stacks s ON s.id=fc.stack_id WHERE 1=1"
            var params: [SQLiteValue] = []
            if let fileID = req.query("file_id"), !fileID.isEmpty {
                sql += " AND fc.file_id=?"
                params.append(.text(fileID))
            }
            if let stackID {                                                 // geuebt wird in einem Stapel
                sql += " AND fc.stack_id=?"
                params.append(.integer(Int64(stackID)))
            }
            if due {
                // versteckte Karten (Trainer) sind nie faellig; die Liste ohne due zeigt sie weiter
                sql += " AND (fc.due IS NULL OR fc.due <= ?) AND COALESCE(fc.hidden, 0) = 0"
                params.append(.text(ctx.clock.today))
            }
            sql += " ORDER BY fc.id DESC"
            let query = (sql: sql, params: params)
            let rows = try await ctx.database.transaction { c -> [[String: JSONValue]] in
                try ensureStacks(c)
                return try c.rows(query.sql, query.params)
            }
            return .json(.array(rows.map(JSONValue.object)))
        }

        // Karten anlegen. Stapel: stack_id (vorhandener Stapel; die Karten bekommen sein Fach), sonst stack_name (Stapel
        // mit diesem Namen im Fach des Dokuments, sonst neu mit dem Dokument als Quelle), sonst der Stapel des
        // Dokuments bzw. "Allgemein"/"Ohne Modul" (`autoStack`)
        router.post("/api/flashcards") { req, ctx in
            let body = try req.pythonObjectBody()
            let cards = try cardList(body.value("cards"))
            let fileID = body.value("file_id"), stackID = body.value("stack_id"), stackName = body.value("stack_name")
            let now = ctx.clock.nowISO, today = ctx.clock.today
            let sid = try await ctx.database.transaction { c -> SQLiteValue in
                var subject: SQLiteValue = .null
                var file: SQLiteRow?
                if truthy(fileID) {
                    file = try fileInfo(c, try bind(fileID, "file_id"))
                    subject = file?["subject"] ?? .null
                }
                var sid: SQLiteValue = .null
                for card in cards {
                    guard case .object(let members) = card else {
                        throw LocalHTTPError(status: 500, message: "Karteikarte ist kein Objekt")   // c.get scheitert
                    }
                    let question = members.value("question"), answer = members.value("answer")
                    guard truthy(question), truthy(answer) else { continue }
                    if sid.isNull {
                        if truthy(stackID) {
                            guard let st = try c.queryOne("SELECT id, subject FROM flashcard_stacks WHERE id=?", [try bind(stackID, "stack_id")]) else {
                                throw LocalHTTPError.notFound("Stapel nicht gefunden")
                            }
                            sid = st["id"] ?? .null
                            subject = st["subject"] ?? .null
                        } else if case .string(let raw)? = stackName, !PyText.strip(raw).isEmpty {
                            let name = PyText.strip(raw)
                            if let st = try c.queryOne("SELECT id FROM flashcard_stacks WHERE name=? AND subject IS ? ORDER BY id LIMIT 1", [.text(name), subject]) {
                                sid = st["id"] ?? .null
                            } else {
                                let (kind, week) = stackMeta(truthy(fileID) ? file : nil)
                                try c.execute("INSERT INTO flashcard_stacks(name, subject, file_id, created_at, kind, week) VALUES (?,?,?,?,?,?)",
                                              [.text(name), subject, truthy(fileID) ? try bind(fileID, "file_id") : .null, .text(now), kind, week])
                                sid = .integer(c.lastInsertRowID)
                            }
                        } else {
                            sid = .integer(try autoStack(c, fileID: fileID, subject: subject, now: now))
                        }
                    }
                    try c.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due, stack_id) VALUES (?,?,?,?,?,1,?,?)",
                                  [try bind(fileID, "file_id"), subject, try bind(question, "question"), try bind(answer, "answer"),
                                   .text(now), .text(today), sid])
                }
                return sid
            }
            // wie Python: Zahl der gesendeten Karten, auch der uebersprungenen ohne Frage oder Antwort
            return .json(["ok": true, "count": .number(Double(cards.count)), "stack_id": sid.json ?? .null])
        }

        router.post("/api/flashcards/{card_id:int}/review") { req, ctx in
            let correct = truthy(try req.pythonObjectBody().value("correct"))
            let id = SQLiteValue.integer(Int64(req.intParam("card_id")))
            let today = LocalTimetable.today(ctx.clock)
            let now = ctx.clock.nowISO
            return .json(try await ctx.database.transaction { c -> JSONValue in
                // HTTPException(404) ohne Text wie in server.py
                guard let row = try c.queryOne("SELECT box FROM flashcards WHERE id=?", [id]) else { throw LocalHTTPError.notFound() }
                let box = correct ? try nextBox(row["box"]) : 1
                let due = BerlinClock.isoDate(today + (try interval(box)))
                try c.execute("UPDATE flashcards SET box=?, due=?, last_result=? WHERE id=?",
                              [.integer(Int64(box)), .text(due), .text(correct ? "right" : "wrong"), id])
                try touchStack(c, id, now)
                return ["box": .number(Double(box)), "due": .string(due)]
            })
        }

        // Karteikarten-Trainer (freies Ueben) wie `patch_flashcard`: Lesezeichen, versteckt und letztes Urteil
        // ("right" | "wrong" | null = noch nicht gelernt). Nachtraeglich bearbeiten (04.11.2026): question, answer
        // (nicht leer), subject (Fach oder null) und stack_id (vorhandener Stapel; die Karte bekommt sein Fach, wenn
        // subject nicht mitkommt). Fach und Faelligkeit (Leitner) bleiben unberuehrt.
        router.patch("/api/flashcards/{card_id:int}") { req, ctx in
            let body = try req.pythonObjectBody()
            let id = SQLiteValue.integer(Int64(req.intParam("card_id")))
            let now = ctx.clock.nowISO
            var sets: [String] = [], params: [SQLiteValue] = []
            for k in ["bookmarked", "hidden"] where body.has(k) {
                sets.append("\(k)=?")
                params.append(.integer(truthy(body.value(k)) ? 1 : 0))
            }
            var practised = false
            if body.has("last_result") {
                switch body.value("last_result") {
                case nil, .null?: params.append(.null)
                case .string(let s)? where s == "right" || s == "wrong": params.append(.text(s)); practised = true
                default: throw LocalHTTPError(status: 422, message: "last_result: right, wrong oder null erwartet")
                }
                sets.append("last_result=?")
            }
            for k in ["question", "answer"] where body.has(k) {
                guard case .string(let s)? = body.value(k), !PyText.strip(s).isEmpty else {
                    throw LocalHTTPError(status: 422, message: "Frage und Antwort dürfen nicht leer sein")
                }
                sets.append("\(k)=?")
                params.append(.text(PyText.strip(s)))
            }
            if body.has("subject") { sets.append("subject=?"); params.append(try subjectValue(body.value("subject"))) }
            let stackID: SQLiteValue? = try {
                guard body.has("stack_id") else { return nil }
                guard case .int(let digits)? = body.value("stack_id") else { throw LocalHTTPError(status: 422, message: "stack_id: ganze Zahl erwartet") }
                return try bind(.int(digits), "stack_id")
            }()
            let base = (sets: sets, params: params)
            let row = try await ctx.database.transaction { c -> JSONValue in
                var sets = base.sets, params = base.params
                if let stackID {
                    guard let target = try c.queryOne("SELECT id, subject FROM flashcard_stacks WHERE id=?", [stackID]) else {
                        throw LocalHTTPError.notFound("Stapel nicht gefunden")
                    }
                    sets.append("stack_id=?"); params.append(stackID)
                    if !body.has("subject") { sets.append("subject=?"); params.append(target["subject"] ?? .null) }
                }
                if !sets.isEmpty, try c.execute("UPDATE flashcards SET \(sets.joined(separator: ", ")) WHERE id=?", params + [id]) == 0 {
                    throw LocalHTTPError.notFound("Karteikarte nicht gefunden")
                }
                if practised { try touchStack(c, id, now) }
                guard let row = try c.queryOne("SELECT * FROM flashcards WHERE id=?", [id]) else {
                    throw LocalHTTPError.notFound("Karteikarte nicht gefunden")
                }
                return .object(row.json)
            }
            return .json(row)
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

    // MARK: Stapel-Helfer wie in server.py

    /// `db.ensure_flashcard_stacks`: Karten ohne Stapel bekommen einen (nach einem Abgleich mit einem aelteren Geraet
    /// oder Einfuegen von aussen); sonst ohne Wirkung
    static func ensureStacks(_ c: SQLiteConnection) throws {
        for sql in Migrations.flashcardStackSQL { try c.execute(sql) }
    }

    static func stackRow(_ c: SQLiteConnection, _ id: SQLiteValue, _ today: String) throws -> JSONValue? {
        try c.queryOne(stackSQL + " WHERE s.id=?", [.text(today), id]).map { .object($0.json) }
    }

    /// `STACK_KINDS`
    static let kinds = ["vorlesung", "uebung", "eigene"]

    /// `_file_info`: Fach und Art des Kurses, Titel (sonst Dateiname), Name, Ordner und KI-Einordnung eines Dokuments;
    /// nil, wenn es die Datei nicht gibt
    static func fileInfo(_ c: SQLiteConnection, _ fileID: SQLiteValue) throws -> SQLiteRow? {
        try c.queryOne("SELECT c.subject, c.kind AS course_kind, COALESCE(NULLIF(f.title, ''), f.name) AS title, f.name, "
                       + "f.studip_folder, a.doc_type FROM files f LEFT JOIN courses c ON c.id=f.course_id "
                       + "LEFT JOIN analysis a ON a.file_id=f.id WHERE f.id=?", [fileID])
    }

    /// `_file_stack_meta`: Art und Lehrwoche eines Stapels aus seinem Dokument (Einordnung wie `study.effective_type`:
    /// Vorlesungsfolien -> vorlesung, Uebungsblaetter -> uebung, sonst eigene; Woche aus Dateiname/Ordner, `week_hint`)
    static func stackMeta(_ f: SQLiteRow?) -> (kind: SQLiteValue, week: SQLiteValue) {
        guard let f else { return (.text("eigene"), .null) }
        let name = f["name"]?.string, folder = f["studip_folder"]?.string
        let t = StudyClassify.effectiveType(name: name, folder: folder, aiType: f["doc_type"]?.string, courseKind: f["course_kind"]?.string).type
        let week = StudyClassify.weekHint(name: name, folder: folder)
        return (.text(t == "vorlesung" || t == "uebung" ? t : "eigene"), week.map { .integer(Int64($0)) } ?? .null)
    }

    /// `_week_value`: Lehrwoche als ganze Zahl ab 1 oder null (= Allgemein)
    static func weekValue(_ v: PyJSON?) throws -> SQLiteValue {
        switch v {
        case nil, .null?: return .null
        case .int(let digits)?:
            guard let n = Int64(digits), n >= 1 else { throw LocalHTTPError(status: 422, message: "week: ganze Zahl ab 1 oder null erwartet") }
            return .integer(n)
        default: throw LocalHTTPError(status: 422, message: "week: ganze Zahl ab 1 oder null erwartet")
        }
    }

    /// `_kind_value`: vorlesung | uebung | eigene
    static func kindValue(_ v: PyJSON?) throws -> String {
        guard case .string(let s)? = v, kinds.contains(s) else { throw LocalHTTPError(status: 422, message: "kind: vorlesung, uebung oder eigene erwartet") }
        return s
    }

    /// `_stack_name`: Text ohne Leerraum aussen, nicht leer
    static func stackName(_ v: PyJSON?) throws -> String {
        guard case .string(let s)? = v, !PyText.strip(s).isEmpty else { throw LocalHTTPError(status: 422, message: "Name des Stapels fehlt") }
        return PyText.strip(s)
    }

    /// `_subject_value`: Fach als Text (ohne Leerraum aussen, leer = kein Fach) oder null
    static func subjectValue(_ v: PyJSON?) throws -> SQLiteValue {
        switch v {
        case nil, .null?: return .null
        case .string(let s)?: return PyText.strip(s).isEmpty ? .null : .text(PyText.strip(s))
        default: throw LocalHTTPError(status: 422, message: "subject: Text oder null erwartet")
        }
    }

    /// `_file_value`: Quelldokument eines Stapels, Kennung eines vorhandenen Dokuments oder null
    static func fileValue(_ c: SQLiteConnection, _ v: PyJSON?) throws -> SQLiteValue {
        switch v {
        case nil, .null?, .string("")?: return .null
        case .string(let s)?:
            guard try fileInfo(c, .text(s)) != nil else { throw LocalHTTPError.notFound("Dokument nicht gefunden") }
            return .text(s)
        default: throw LocalHTTPError(status: 422, message: "file_id: Text oder null erwartet")
        }
    }

    /// `_auto_stack`: Stapel fuer Karten ohne Stapelangabe, wie die Migration: der Stapel des Dokuments (Name = Titel
    /// bzw. Dateiname, sonst die Kennung), ohne Dokument "Allgemein" je Fach bzw. "Ohne Modul"
    static func autoStack(_ c: SQLiteConnection, fileID: PyJSON?, subject: SQLiteValue, now: String) throws -> Int64 {
        let name: String
        let meta: (kind: SQLiteValue, week: SQLiteValue)
        let subjectOrNull: SQLiteValue = truthySQL(subject) ? subject : .null
        if truthy(fileID) {
            let bound = try bind(fileID, "file_id")
            if let s = try c.queryOne("SELECT id FROM flashcard_stacks WHERE file_id=? ORDER BY id LIMIT 1", [bound]), let id = s["id"]?.int64 { return id }
            let f = try fileInfo(c, bound)
            let title = f?["title"]?.string ?? ""
            name = title.isEmpty ? pyStr(fileID) : title
            meta = stackMeta(f)
        } else {
            name = truthySQL(subject) ? "Allgemein" : "Ohne Modul"
            meta = (.text("eigene"), .null)
            if let s = try c.queryOne("SELECT id FROM flashcard_stacks WHERE file_id IS NULL AND subject IS ? AND name=? ORDER BY id LIMIT 1",
                                      [subjectOrNull, .text(name)]), let id = s["id"]?.int64 { return id }
        }
        try c.execute("INSERT INTO flashcard_stacks(name, subject, file_id, created_at, kind, week) VALUES (?,?,?,?,?,?)",
                      [.text(name), subjectOrNull, truthy(fileID) ? try bind(fileID, "file_id") : .null, .text(now), meta.kind, meta.week])
        return c.lastInsertRowID
    }

    /// `_touch_stack`: Wiederholung oder Uebung einer Karte setzt die letzte Uebung ihres Stapels
    static func touchStack(_ c: SQLiteConnection, _ cardID: SQLiteValue, _ now: String) throws {
        try c.execute("UPDATE flashcard_stacks SET last_practised=? WHERE id=(SELECT stack_id FROM flashcards WHERE id=?)", [.text(now), cardID])
    }

    /// `bool(x)` fuer einen Wert aus der Datenbank (Fach: Text oder NULL)
    static func truthySQL(_ v: SQLiteValue) -> Bool {
        switch v {
        case .null: return false
        case .integer(let i): return i != 0
        case .real(let d): return d != 0
        case .text(let s): return !s.isEmpty
        case .blob(let b): return !b.isEmpty
        }
    }

    /// `str(x)` fuer einen wahren Wert aus dem Rumpf (Text, Zahl, True)
    static func pyStr(_ v: PyJSON?) -> String {
        switch v {
        case .string(let s)?: return s
        case .int(let digits)?: return digits
        case .float(let d)?: return PyJSON.repr(d)
        case .bool(let b)?: return b ? "True" : "False"
        default: return ""
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
