import Foundation

/// Notenspiegel auswerten wie app/grades_model.py (28.10.2026): Ebenen (Bereich, Modul, Pruefung), Doppelte aus der
/// zweiten QIS-Ansicht mit langen Semesternamen, aktueller Schnitt der bestandenen benoteten Module nach LP gewichtet
/// und nach der ersten Nachkommastelle abgeschnitten, dazu der genaue Wert. Vertrag: fixtures/local-backend/grades.json
/// (tools/gen-grades-fixture.py).
///
/// Wie Python: Zeichenketten werden nach Codepunkten verglichen (Doppelte, Suche in den Zellen), nicht nach
/// Unicode-Aequivalenz wie Swifts `==`; die Sortierung ist stabil.
enum GradesModel {
    static let arts: Set<String> = ["PL", "SL", "LN", "LA", "SO", "KL", "MP", "PA", "HA", "RE", "BA", "MA", "PR", "TN", "AN", "SP", "ML"]
    static let semRE = PyRegex(#"^(WiSe|SoSe|Wintersemester|Sommersemester|WS|SS)\s*(\d{2,4})(?:\s*/\s*(\d{2,4}))?$"#, ignoreCase: true)
    static let noteRE = PyRegex(#"^\d,\d$"#)
    static let dateRE = PyRegex(#"^\d{2}\.\d{2}\.\d{4}$"#)
    static let statusRE = PyRegex(#"^(bestanden|nicht bestanden|angemeldet.*|abgemeldet|endgültig nicht bestanden|prüfung vorhanden|"#
                                  + #"anerkannt|zugelassen|nicht zugelassen|krank|rücktritt)$"#, ignoreCase: true)
    static let bereichRE = PyRegex(#"^(kompetenzbereich|pflichtmodule|wahlpflichtmodule|wahlmodule|wahlpflichtbereich|wahlbereich|"#
                                   + #"gesamtkonto|studienbereich|schwerpunkt\b|vertiefung\b|fachstudium|grundstudium|hauptstudium)"#, ignoreCase: true)
    /// `re.fullmatch(r"\d+(,\d+)?", s)`
    static let creditsRE = PyRegex(#"\d+(,\d+)?\z"#)
    /// `re.fullmatch(r"[A-ZÄÖÜ]{2,4}", s)`
    static let vermerkRE = PyRegex(#"[A-ZÄÖÜ]{2,4}\z"#)
    static let semKeyRE = PyRegex(#"^(WiSe|SoSe) (\d{2})"#)

    /// `norm_semester`: "Wintersemester 23/24" -> "WiSe 23/24", "Sommersemester 24" -> "SoSe 24"; Unbekanntes bleibt
    static func normSemester(_ s: String?) -> String {
        let s = PyText.strip(s ?? "")
        guard let m = semRE.match(s) else { return s }
        let winter = PyText.lower(m.group(1) ?? "").hasPrefix("wi") || PyText.lower(m.group(1) ?? "").hasPrefix("ws")
        let a = lastTwo(m.group(2) ?? ""), b = lastTwo(m.group(3) ?? "")
        if winter, !b.isEmpty { return "WiSe \(a)/\(b)" }
        return winter ? "WiSe \(a)" : "SoSe \(a)"
    }

    /// `s[-2:]` nach Codepunkten
    private static func lastTwo(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.suffix(2)))
    }

    /// `_num`: float(str(v).strip().replace(",", ".")), sonst nil
    static func num(_ v: JSONValue?) -> Double? {
        guard let v else { return nil }
        let text: String
        switch v {
        case .string(let s): text = s
        case .number(let d): return d
        default: return nil                                  // str(None) = "None", str(True) = "True": kein float
        }
        return PyConvert.float(PyText.strip(text).replacingOccurrences(of: ",", with: "."))
    }

    /// `str.isdigit()`: nicht leer, jedes Zeichen eine Ziffer (auch hochgestellte wie in Python)
    static func isDigit(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.properties.numericType == .decimal || $0.properties.numericType == .digit }
    }

    /// `s.split(" | ")` nach Codepunkten
    static func cells(_ raw: String) -> [String] {
        let u = Array(raw.unicodeScalars), sep = Array(" | ".unicodeScalars)
        var out: [String] = [], start = 0, i = 0
        while i + sep.count <= u.count {
            if Array(u[i..<(i + sep.count)]) == sep {
                out.append(String(String.UnicodeScalarView(u[start..<i])))
                i += sep.count
                start = i
            } else {
                i += 1
            }
        }
        out.append(String(String.UnicodeScalarView(u[start...])))
        return out
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// `fields_from_raw`: Felder aus den Zellen einer Zeile (Inhalt statt Spaltenposition)
    static func fieldsFromRaw(_ raw: String?) -> [String: String] {
        let cells = cells(raw ?? "").map(PyText.strip)
        var out: [String: String] = [:]
        if let first = cells.first, isDigit(first) { out["pruefungsnr"] = first }
        var statusIndex: Int?
        for i in cells.indices.dropFirst() {
            let c = cells[i]
            if out["art"] == nil, arts.contains(c.uppercased()) {
                out["art"] = c.uppercased()
            } else if out["semester"] == nil, semRE.match(c) != nil {
                out["semester"] = c
            } else if out["note"] == nil, noteRE.match(c) != nil {
                out["note"] = c
            } else if out["status"] == nil, statusRE.match(c) != nil {
                out["status"] = c
                statusIndex = i
            } else if out["datum"] == nil, dateRE.match(c) != nil {
                out["datum"] = c
            }
        }
        if let si = statusIndex, si + 1 < cells.count, creditsRE.match(cells[si + 1]) != nil {
            out["credits"] = cells[si + 1]
        }
        if let datum = out["datum"], let di = cells.firstIndex(where: { same($0, datum) }) {
            if di + 1 < cells.count, isDigit(cells[di + 1]), cells[di + 1].unicodeScalars.count <= 2 {
                out["versuch"] = cells[di + 1]
            }
            if di + 2 < cells.count, vermerkRE.match(cells[di + 2]) != nil {
                out["vermerk"] = cells[di + 2]
            }
        }
        return out
    }

    private static func text(_ v: JSONValue?) -> String? {
        if case .string(let s) = v { return s }
        return nil
    }

    /// Python-Wahrheitswert eines Feldes (`if g.get(k)`): nicht None, nicht leer, nicht 0
    private static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .none, .some(.null): return false
        case .some(.string(let s)): return !s.isEmpty
        case .some(.number(let d)): return d != 0
        case .some(.bool(let b)): return b
        default: return true
        }
    }

    private static func level(_ r: [String: JSONValue]) -> String {
        if bereichRE.match(text(r["text"]) ?? "") != nil { return "bereich" }
        if truthy(r["art"]) || !PyText.strip(text(r["versuch"]) ?? "").isEmpty { return "pruefung" }
        return "modul"
    }

    /// `model`: gespeicherte Zeilen -> bereinigte Zeilen mit level, semester_norm, passed, graded; ohne Doppelte
    static func model(_ rows: [[String: JSONValue]]) -> [[String: JSONValue]] {
        var out: [[String: JSONValue]] = []
        var seen = Set<[[UInt32]]>()
        for r in rows {
            let f = fieldsFromRaw(text(r["raw"]))
            var g = r
            for (k, v) in f {                                 // Kopfzeile geht vor, Inhalt fuellt Luecken
                switch g[k] {
                case .none, .some(.null): g[k] = .string(v)
                case .some(.string(let cur)) where PyText.strip(cur).isEmpty: g[k] = .string(v)
                default: break
                }
            }
            if g["art"] == nil { g["art"] = .string(f["art"] ?? "") }
            // verschobene Zeilen (weniger Zellen): Inhalt geht vor, wenn die Spaltenzuordnung offensichtlich falsch ist
            if truthy(g["semester"]), semRE.match(text(g["semester"]) ?? "") == nil, f["semester"] == nil {
                g["semester"] = .string("")
            }
            if truthy(g["note"]), noteRE.match(text(g["note"]) ?? "") == nil {
                g["note"] = .string(f["note"] ?? "")
            }
            if truthy(g["status"]), statusRE.match(text(g["status"]) ?? "") == nil, let s = f["status"], !s.isEmpty {
                g["status"] = .string(s)
            }
            if let c = f["credits"], !c.isEmpty, (num(g["credits"]) ?? 0) == 0 {
                g["credits"] = .string(c)
            }
            let semNorm = normSemester(text(g["semester"]))
            g["semester_norm"] = .string(semNorm)
            let nr = truthy(g["pruefungsnr"]) ? text(g["pruefungsnr"]) : text(g["text"])
            let key = [nr ?? "\u{0}none", text(g["art"]) ?? "", semNorm, PyText.strip(text(g["versuch"]) ?? ""),
                       text(g["note"]) ?? "", text(g["datum"]) ?? ""].map { $0.unicodeScalars.map(\.value) }
            guard seen.insert(key).inserted else { continue }
            g["level"] = .string(level(g))
            let note = num(g["note"])
            let passed = ["bestanden", "anerkannt"].contains(PyText.lower(PyText.strip(text(g["status"]) ?? "")))
            g["passed"] = .bool(passed)
            g["graded"] = .bool(note.map { $0 >= 1.0 && $0 <= 4.0 } == true && passed)
            out.append(g)
        }
        return out
    }

    /// `truncate1`: erste Nachkommastelle, ohne Rundung
    static func truncate1(_ x: Double) -> Double { (x * 10 + 1e-9).rounded(.down) / 10 }

    /// `round(x, 1)` wie Python (exakter Binaerwert, Gleichstand zur geraden Ziffer)
    static func round1(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.1f", x)) ?? x
    }

    private static func isTrue(_ v: JSONValue?) -> Bool {
        if case .bool(true) = v { return true }
        return false
    }

    /// `summary` und die Antwort von `qis.summary(conn)` ohne last_run/documents: sortierte Zeilen und Kennzahlen
    static func summary(_ rows: [[String: JSONValue]]) -> [String: JSONValue] {
        let m = model(rows)
        let modules = m.filter { text($0["level"]) == "modul" }
        let useModules = modules.contains { isTrue($0["graded"]) }
        let basis = useModules ? modules : m.filter { text($0["level"]) != "bereich" }
        let graded = basis.filter { isTrue($0["graded"]) }
        let weights = graded.map { (n: num($0["note"]) ?? 0, w: num($0["credits"]) ?? 0) }
        let lp = PyMath.sum(weights.map(\.w))
        let exact: Double?
        if lp != 0 { exact = PyMath.sum(weights.map { $0.n * $0.w }) / lp }
        else if !weights.isEmpty { exact = PyMath.sum(weights.map(\.n)) / Double(weights.count) }
        else { exact = nil }
        let passed = basis.filter { isTrue($0["passed"]) }
        let bereiche: [JSONValue] = m.filter { text($0["level"]) == "bereich" }.map { r in
            .object(["text": r["text"] ?? .null,
                     "note": .string(truthy(r["note"]) ? text(r["note"]) ?? "" : ""),
                     "credits": .string(truthy(r["credits"]) ? text(r["credits"]) ?? "" : ""),
                     "status": .string(truthy(r["status"]) ? text(r["status"]) ?? "" : "")])
        }
        let failed = m.filter { text($0["level"]) == "pruefung" && PyText.lower(text($0["status"]) ?? "").hasPrefix("nicht") }.count
        // qis.summary: Bereiche, Module, Pruefungen; darin neueste Semester zuerst, dann Text (stabil wie sorted)
        let order = ["bereich": 0, "modul": 1, "pruefung": 2]
        let sorted = m.enumerated().sorted { a, b in
            let ka = (order[text(a.element["level"]) ?? ""] ?? 0, semKey(text(a.element["semester_norm"]) ?? ""))
            let kb = (order[text(b.element["level"]) ?? ""] ?? 0, semKey(text(b.element["semester_norm"]) ?? ""))
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            let ta = text(a.element["text"]) ?? "", tb = text(b.element["text"]) ?? ""
            if !same(ta, tb) { return PyText.less(ta, tb) }
            return a.offset < b.offset
        }.map(\.element)
        return [
            "grades": .array(sorted.map(JSONValue.object)),
            "average": exact.map { .number(truncate1($0)) } ?? .null,
            "average_exact": exact.map { .number(QISParser.round2($0)) } ?? .null,
            "graded_count": .number(Double(graded.count)),
            "graded_credits": .number(round1(lp)),
            "credits": .number(round1(PyMath.sum(passed.map { num($0["credits"]) ?? 0 }))),
            "passed": .number(Double(passed.count)),
            "basis": .string(useModules ? "module" : "leistungen"),
            "bereiche": .array(bereiche),
            "failed_attempts": .number(Double(failed)),
        ]
    }

    /// `_sem_key`: neueste Semester zuerst ("WiSe 25/26" -> (-2025, -2), "SoSe 26" -> (-2026, -1)); ohne Semester ans Ende
    struct SemKey: Comparable {
        let a: Int, b: Int
        static func < (l: SemKey, r: SemKey) -> Bool { (l.a, l.b) < (r.a, r.b) }
    }

    static func semKey(_ s: String) -> SemKey {
        guard let m = semKeyRE.match(s), let y = Int(m.group(2) ?? "") else { return SemKey(a: 1, b: 0) }
        return SemKey(a: -(2000 + y), b: m.group(1) == "WiSe" ? -2 : -1)
    }
}
