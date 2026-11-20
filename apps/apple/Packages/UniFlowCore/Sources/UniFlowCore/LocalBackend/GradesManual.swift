import Foundation

/// Selbst eingetragene Leistungen wie app/grades_manual.py (Entscheidung des Inhabers 20.11.2026: "man soll selber
/// Noten eintragen koennen, wenn man will, und Klausuren abhaken ... wenn unsere App das nicht erkennt, dann soll das
/// automatisch uebernommen werden und auch bei LP angerechnet werden").
///
/// - Tabelle `grades_manual` nur auf dem Geraet (wie `grades`), angelegt erst beim ersten Eintrag; nicht im
///   Geraete-Abgleich (`DeviceSync`), nie auf dem Server.
/// - Ein Eintrag gehoert zu einem Katalogmodul (`module_id`, Kuerzel, Titel) oder einem eigenen Eintrag des
///   Studienverlaufs ("eigen-<n>"); LP aus dem Katalog bzw. eigenen Eintrag, nur ohne solche die eingetragenen. Note
///   optional (1,0 bis 5,0); ueber 4,0 heisst nicht bestanden (bleibt stehen, zaehlt nicht).
/// - QIS geht vor (`resolve`): meldet QIS eine bestandene Leistung zu demselben Modul (Pruefungs- oder Modulnummer =
///   Kuerzel, gleicher Namensschluessel von Text oder Modultext, oder ein Teil eines zusammengesetzten Titels), ist der
///   Eintrag `replaced` und zaehlt nicht. Bereichszeilen und Pruefungsanmeldungen zaehlen dafuer nie.
/// - Zaehlende Eintraege gehen als Zeile mit `source: "manuell"` in den Studienverlauf (`rows`) und in Uni & Noten
///   (`GradesModel.summary`). Ohne Eintraege bleiben alle Antworten wie bisher.
public enum GradesManual {
    static let table = "grades_manual"
    static let source = "manuell"
    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS grades_manual (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            module_id TEXT,
            code TEXT,
            title TEXT NOT NULL,
            lp REAL,
            grade TEXT,
            passed INTEGER NOT NULL DEFAULT 1,
            semester TEXT,
            created_at TEXT,
            updated_at TEXT
        );
        """
    static let maxEntries = 200, maxTitle = 120, maxID = 200, maxCode = 40
    static let maxLP = 60.0
    static let gradeError = "Note bitte zwischen 1,0 und 5,0 eintragen, z. B. 2,3."
    static let lpError = "Leistungspunkte bitte als Zahl zwischen 0 und 60 eintragen."
    static let termError = "Semester bitte wie „WiSe 24/25“ oder „SoSe 25“ eintragen."

    static func invalid(_ text: String) -> LocalHTTPError { LocalHTTPError(status: 400, message: text) }

    // MARK: Werte

    private static func blank(_ v: JSONValue?) -> Bool {
        guard let v else { return true }
        if v.isNull { return true }
        if let s = v.string { return PyText.strip(s).isEmpty }
        return false
    }

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// "2,3", "2.3", 2.3 -> 2.3; leer -> nil; sonst Fehler (1,0 bis 5,0, hoechstens eine Nachkommastelle)
    static func parseGrade(_ v: JSONValue?) throws -> Double? {
        if blank(v) { return nil }
        let g: Double
        switch v! {
        case .number(let n): g = n
        case .string(let raw):
            let s = PyText.strip(raw).replacingOccurrences(of: ",", with: ".")
            guard s.count <= 4, !s.hasPrefix("."), s.filter({ $0 == "." }).count <= 1,
                  s.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }), let d = Double(s) else { throw invalid(gradeError) }
            g = d
        default: throw invalid(gradeError)
        }
        guard g.isFinite, g >= 1.0, g <= 5.0, abs(round1(g) - g) <= 1e-9 else { throw invalid(gradeError) }
        return round1(g)
    }

    /// 2.3 -> "2,3"
    static func gradeText(_ g: Double?) -> String? {
        g.map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") }
    }

    /// LP: Zahl oder Text ("7,5"); leer -> nil; 0 bis 60
    static func parseLP(_ v: JSONValue?) throws -> Double? {
        if blank(v) { return nil }
        let x: Double
        switch v! {
        case .number(let n): x = n
        case .string(let s):
            guard let d = Double(PyText.strip(s).replacingOccurrences(of: ",", with: ".")) else { throw invalid(lpError) }
            x = d
        default: throw invalid(lpError)
        }
        guard x.isFinite, x >= 0, x <= maxLP else { throw invalid(lpError) }
        return round1(x)
    }

    /// LP als QIS-Text: 5 -> "5", 7.5 -> "7,5"
    static func lpText(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(format: "%.1f", x).replacingOccurrences(of: ".", with: ",")
    }

    static func parseSemester(_ v: JSONValue?) throws -> String? {
        if blank(v) { return nil }
        guard let s = v?.string, let t = GradesModel.parseTerm(s) else { throw invalid(termError) }
        return GradesModel.termName(t)
    }

    /// `" ".join(v.split())[:limit].strip()`
    static func cleanText(_ v: JSONValue?, _ limit: Int) -> String {
        guard let s = v?.string else { return "" }
        let joined = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return PyText.strip(String(joined.prefix(limit)))
    }

    // MARK: Tabelle

    static func hasTable(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]) != nil
    }

    static func entry(_ r: [String: JSONValue]) -> [String: JSONValue] {
        func s(_ k: String) -> JSONValue {
            guard let v = r[k]?.string, !v.isEmpty else { return .null }
            return .string(v)
        }
        let passed = (r["passed"]?.double ?? 0) != 0
        return ["id": r["id"] ?? .null, "module_id": s("module_id"), "code": s("code"), "title": .string(r["title"]?.string ?? ""),
                "lp": .number(r["lp"]?.double ?? 0), "grade": s("grade"), "passed": .bool(passed), "semester": s("semester"),
                "created_at": r["created_at"] ?? .null, "updated_at": r["updated_at"] ?? .null]
    }

    /// Alle Eintraege (nach id); ohne Tabelle keine (Lesen legt nichts an)
    public static func load(_ c: SQLiteConnection) throws -> [[String: JSONValue]] {
        guard try hasTable(c) else { return [] }
        return try c.rows("SELECT * FROM grades_manual ORDER BY id").map(entry)
    }

    /// Titel, Kuerzel und LP eines Katalogmoduls (gewaehlter Katalog wie im Studienverlauf) oder eines eigenen Eintrags
    static func facts(_ c: SQLiteConnection, moduleID: String, source: StudyCatalogSource? = nil) throws -> (title: String, code: String?, lp: Double)? {
        let settings = try StudyPlanAPI.loadSettings(c)
        if let e = settings.custom.first(where: { $0.id == moduleID }) { return (e.title, nil, e.lp) }
        let source = source ?? DatabaseStudyCatalogSource(c)
        guard let cat = StudyPlanEngine.pickCatalog(try source.catalogs(), settings: settings.json,
                                                    grades: try StudyPlanAPI.gradeRows(c)).catalog else { return nil }
        let (mods, _) = StudyPlanEngine.effectiveModules(cat)
        guard let m = mods.first(where: { $0["id"]?.string == moduleID }) else { return nil }
        let code = PyText.strip(StudyPlanEngine.textOf(m["code"]))
        return (PyText.strip(StudyPlanEngine.textOf(m["title"])), code.isEmpty ? nil : code, StudyPlanEngine.lpOf(m))
    }

    /// Eintrag anlegen oder aendern (`POST /api/grades/manual`): `id` aendert, sonst je `module_id` ein Eintrag
    public static func save(_ c: SQLiteConnection, body: [String: JSONValue], now: String,
                            source: StudyCatalogSource? = nil) throws -> [String: JSONValue] {
        let moduleID = cleanText(body["module_id"], maxID)
        let known = moduleID.isEmpty ? nil : try facts(c, moduleID: moduleID, source: source)
        let title = known.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? cleanText(body["title"], maxTitle)
        guard !title.isEmpty else { throw invalid("Bitte den Namen des Moduls oder der Prüfung eintragen.") }
        let code: String? = known != nil ? known!.code : { let s = cleanText(body["code"], maxCode); return s.isEmpty ? nil : s }()
        // LP des Katalogmoduls bzw. eigenen Eintrags gehen vor; nur ohne solche zaehlen die eingetragenen
        let lp: Double
        if let k = known, k.lp != 0 { lp = k.lp } else { lp = try parseLP(body["lp"]) ?? 0 }
        let grade = try parseGrade(body["grade"])
        var passed = true
        if let p = body["passed"], !p.isNull {
            guard let b = p.bool else { throw invalid("„bestanden“ muss ja oder nein sein.") }
            passed = b
        }
        if let g = grade, g > 4.0 { passed = false }                       // 5,0: nicht bestanden, zaehlt nicht
        let semester = try parseSemester(body["semester"])
        try c.executeScript(tableSQL)
        var row: [String: JSONValue]?
        if let rid = body["id"], !rid.isNull {
            guard case .number(let n) = rid, n == n.rounded(), abs(n) < 1e15 else { throw invalid("Eintrag unbekannt.") }
            row = try c.rows("SELECT * FROM grades_manual WHERE id=?", [.integer(Int64(n))]).first
            if row == nil { throw LocalHTTPError(status: 404, message: "Eintrag unbekannt.") }
        } else if !moduleID.isEmpty {
            row = try c.rows("SELECT * FROM grades_manual WHERE module_id=? ORDER BY id LIMIT 1", [.text(moduleID)]).first
        }
        func t(_ s: String?) -> SQLiteValue { s.map(SQLiteValue.text) ?? .null }
        let values: [SQLiteValue] = [moduleID.isEmpty ? .null : .text(moduleID), t(code), .text(title), .real(lp),
                                     t(gradeText(grade)), .integer(passed ? 1 : 0), t(semester)]
        let id: Int64
        if let row, let existing = row["id"]?.double {
            id = Int64(existing)
            try c.execute("UPDATE grades_manual SET module_id=?, code=?, title=?, lp=?, grade=?, passed=?, semester=?, updated_at=? WHERE id=?",
                          values + [.text(now), .integer(id)])
        } else {
            let n = try c.scalar("SELECT COUNT(*) FROM grades_manual")?.int ?? 0
            guard n < maxEntries else { throw invalid("Höchstens \(maxEntries) eigene Einträge.") }
            try c.execute("INSERT INTO grades_manual(module_id, code, title, lp, grade, passed, semester, created_at, updated_at) "
                          + "VALUES (?,?,?,?,?,?,?,?,?)", values + [.text(now), .text(now)])
            id = try c.scalar("SELECT last_insert_rowid()")?.int64 ?? 0
        }
        return entry(try c.rows("SELECT * FROM grades_manual WHERE id=?", [.integer(id)]).first ?? [:])
    }

    /// `DELETE /api/grades/manual/{id}`: false, wenn es den Eintrag nicht gibt
    public static func delete(_ c: SQLiteConnection, id: Int) throws -> Bool {
        guard try hasTable(c) else { return false }
        try c.execute("DELETE FROM grades_manual WHERE id=?", [.integer(Int64(id))])
        return c.changes > 0
    }

    // MARK: QIS geht vor

    /// Erste bestandene QIS-Zeile (bereinigt, `GradesModel.model`) zu dem Modul des Eintrags, sonst nil
    static func qisMatch(_ e: [String: JSONValue], _ rows: [[String: JSONValue]]) -> [String: JSONValue]? {
        let textOf = StudyPlanEngine.textOf
        let code = PyText.strip(textOf(e["code"]))
        let key = StudyPlanEngine.nameKey(e["title"])
        let parts = StudyPlanEngine.titleParts(e["title"]).parts
        for r in rows {
            let src = textOf(r["source"])
            guard src != "anmeldung", src != source, r["passed"]?.bool == true, textOf(r["level"]) != "bereich" else { continue }
            let nr = PyText.strip(textOf(r["pruefungsnr"])), mnr = PyText.strip(textOf(r["modul_nr"]))
            if !code.isEmpty && (code == nr || code == mnr) { return r }
            let mt = PyText.strip(textOf(r["modul_text"]))
            if !key.isEmpty && (StudyPlanEngine.nameKey(r["text"]) == key || (!mt.isEmpty && StudyPlanEngine.nameKey(r["modul_text"]) == key)) {
                return r
            }
            if !parts.isEmpty && (StudyPlanEngine.partIndex(r["text"], parts) != nil
                                  || (!mt.isEmpty && StudyPlanEngine.partIndex(r["modul_text"], parts) != nil)) {
                return r
            }
        }
        return nil
    }

    /// Eintraege mit `replaced`, `replaced_by` und `counted` (bestanden und nicht durch QIS ersetzt)
    public static func resolve(_ rows: [[String: JSONValue]], _ entries: [[String: JSONValue]]) -> [[String: JSONValue]] {
        entries.map { e in
            let hit = qisMatch(e, rows)
            var g = e
            g["replaced"] = .bool(hit != nil)
            g["replaced_by"] = hit.map { h -> JSONValue in
                let sn = h["semester_norm"]?.string ?? ""
                return ["text": .string(h["text"]?.string ?? ""), "note": .string(h["note"]?.string ?? ""),
                        "semester": .string(sn.isEmpty ? (h["semester"]?.string ?? "") : sn)]
            } ?? .null
            g["counted"] = .bool(e["passed"]?.bool == true && hit == nil)
            return g
        }
    }

    static func gradeNum(_ e: [String: JSONValue]) -> Double? { (try? parseGrade(e["grade"])) ?? nil }

    /// Zeile wie eine bereinigte QIS-Modulzeile fuer den Studienverlauf (`row_of`)
    static func row(_ e: [String: JSONValue]) -> [String: JSONValue] {
        let g = gradeNum(e), lp = e["lp"]?.double ?? 0
        let graded = g.map { $0 <= 4.0 } ?? false
        let sem = e["semester"]?.string ?? ""
        let code = e["code"]?.string ?? ""
        return ["id": .null, "source": .string(source), "manual_id": e["id"] ?? .null, "module_id": e["module_id"] ?? .null,
                "pruefungsnr": .string(code), "text": .string(e["title"]?.string ?? ""), "semester": .string(sem),
                "semester_norm": .string(sem), "note": .string(graded ? gradeText(g)! : ""), "status": "bestanden",
                "credits": .string(lpText(lp)), "versuch": "", "datum": "", "datum_iso": "", "abschluss": .null, "raw": .null,
                "art": "", "level": "modul", "passed": true, "graded": .bool(graded), "anerkannt": false, "counted": true,
                "lp_counted": .number(lp), "superseded": false, "modul_nr": .null, "modul_text": .null]
    }

    /// Zeilen der zaehlenden Eintraege (`counted`)
    static func rows(_ resolved: [[String: JSONValue]]) -> [[String: JSONValue]] {
        resolved.filter { $0["counted"]?.bool == true }.map(row)
    }

    static func isManual(_ r: [String: JSONValue]) -> Bool { r["source"]?.string == source }
}
