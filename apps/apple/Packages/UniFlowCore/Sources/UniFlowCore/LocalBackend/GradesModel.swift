import Foundation

/// Notenspiegel auswerten wie app/grades_model.py (28.10.2026): Ebenen (Bereich, Modul, Pruefung), Doppelte aus der
/// zweiten QIS-Ansicht mit langen Semesternamen, aktueller Schnitt der bestandenen benoteten Module nach LP gewichtet
/// und nach der ersten Nachkommastelle abgeschnitten, dazu der genaue Wert. Vertrag: fixtures/local-backend/grades.json
/// (tools/gen-grades-fixture.py).
///
/// Wie Python: Zeichenketten werden nach Codepunkten verglichen (Doppelte, Suche in den Zellen), nicht nach
/// Unicode-Aequivalenz wie Swifts `==`; die Sortierung ist stabil.
///
/// Regel des Inhabers (12.11.2026): QIS ist die einzige Quelle fuer bestandene Leistungen, Noten und die Summe der LP.
/// Jede bestandene QIS-Leistung zaehlt einmal (`count`, `creditsDone`), auch ohne Modulzeile; Uni & Noten,
/// Studienverlauf und Uebersicht zeigen dieselbe Zahl. Vorher fehlten Pruefungszeilen ohne bestandene Modulzeile (sobald
/// es ein benotetes Modul gab), "BE"/"bestanden (anerkannt)"/"angerechnet" und Note ohne Status galten nicht als
/// bestanden, und Module wie "Vertiefung der Betriebssysteme" galten als Bereichszeile. Zugehoerigkeit einer Pruefung zu
/// ihrem Modul (dann zaehlen die LP der Modulzeile): gleicher Text, sonst Nummer (110 -> 111, 11 -> 1101), sonst die
/// Modulzeile direkt davor (nicht, wenn die Pruefung nach dem Semester des bestandenen Moduls liegt). Ist das Modul
/// nicht bestanden, zaehlen seine bestandenen Pruefungen (zusammen hoechstens die LP der Modulzeile).
///
/// Echter LUH-Notenspiegel (12.11.2026, fixtures/qis-notenspiegel, wie grades_model.py): Spalte "Prf.Art" entscheidet
/// (PL/SL Leistung, ohne Art Modul/Bereich; SL unbenotet); Note "0,0" = anerkannt ohne Note (`anerkannt`, Note leer);
/// `modul_nr`/`modul_text` je Leistung; von mehreren bestandenen Eintraegen derselben Pruefung gilt der neueste nach
/// Datum (aeltere `superseded`); `datum_iso` je Zeile.
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
    /// Modultitel, die wie ein Bereich anfangen ("Vertiefung der Betriebssysteme"): keine Bereichszeile
    static let moduleTitleRE = PyRegex(#"^(schwerpunkt|vertiefung)\s+(der|des|die|das|dem|den|in|im|zu|zur|zum|von|vom|für|fuer|mit)\b"#,
                                       ignoreCase: true)

    /// `is_bereich_text`: Bereichs-/Summenzeile laut Text, nicht ein Modul wie "Vertiefung der ..."
    static func isBereichText(_ text: String) -> Bool {
        bereichRE.match(text) != nil && moduleTitleRE.match(text) == nil
    }

    /// `is_passed`: Status bestanden/BE/anerkannt/angerechnet (auch "bestanden (anerkannt)"), ohne Status (oder "AN") mit
    /// Note 1,0-4,0; nie eine Pruefungsanmeldung
    static func isPassed(_ r: [String: JSONValue]) -> Bool {
        if text(r["source"]) == "anmeldung" { return false }
        let s = PyText.lower(PyText.strip(text(r["status"]) ?? ""))
        if s == "be" || ["bestanden", "anerkannt", "angerechnet"].contains(where: { s.unicodeScalars.starts(with: $0.unicodeScalars) }) {
            return true
        }
        let rawNote = PyText.strip(text(r["note"]) ?? "")
        guard s.isEmpty || s == "an", noteRE.match(rawNote) != nil, let n = num(.string(rawNote)) else { return false }
        return n >= 1.0 && n <= 4.0
    }

    // MARK: Semester (12.11.2026)

    // Alle Schreibweisen des QIS/HIS (Meldung des Inhabers: Studierende hoeherer Semester bekamen einen falschen
    // Studienverlauf, weil "WS 2024/25", "W24", "24/25 WS", "SoSe2025", "20242" oder eine leere Semesterspalte nicht
    // erkannt wurden), wie grades_model.parse_term
    private static let termFrontRE = PyRegex(#"^(wintersemester|sommersemester|wise|sose|ws|ss|wi|so|w|s) ?(\d{2}|\d{4})(?: ?[/-] ?(\d{2}|\d{4}))?$"#)
    private static let termBackRE = PyRegex(#"^(\d{2}|\d{4})(?: ?[/-] ?(\d{2}|\d{4}))? ?(wintersemester|sommersemester|wise|sose|ws|ss|w|s)$"#)
    private static let hisTermRE = PyRegex(#"^(\d{4})([12])$"#)
    private static let trailingParenRE = PyRegex(#"\([^()]*\)\s*$"#)
    private static let letterGapRE = PyRegex(#"(?<=[a-z]) (?=[a-z])"#)
    private static let dateDERE = PyRegex(#"^(\d{1,2})\.(\d{1,2})\.(\d{4})$"#)
    private static let dateISORE = PyRegex(#"^(\d{4})-(\d{2})-(\d{2})"#)

    /// `parse_term`: Semester -> Zahl (Jahr*2, +1 im Winter): "WiSe 24/25", "WS 2024/25", "Wintersemester 2024/2025", "W24",
    /// "24/25 WS", "2024W", "SoSe 25", "SS 2025", "S25", "20242" (HIS-Schluessel); sonst nil
    static func parseTerm(_ s: String?) -> Int? {
        guard let s else { return nil }
        let cleaned = trailingParenRE.sub(s).replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "\u{A0}", with: " ")
        var t = PyText.lower(cleaned).unicodeScalars.split(whereSeparator: PyText.isSpace)
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        t = letterGapRE.sub(t)
        let year: Int, winter: Bool
        if let m = hisTermRE.match(t), let y = PyText.int(digits: m.group(1) ?? "") {
            year = y
            winter = m.group(2) == "2"
        } else {
            let kind: String, ys: String
            if let m = termFrontRE.match(t) {
                kind = m.group(1) ?? ""; ys = m.group(2) ?? ""
            } else if let m = termBackRE.match(t) {
                kind = m.group(3) ?? ""; ys = m.group(1) ?? ""
            } else {
                return nil
            }
            guard let y = PyText.int(digits: ys) else { return nil }
            year = y + (ys.unicodeScalars.count == 2 ? 2000 : 0)
            winter = kind.hasPrefix("w")
        }
        guard (1990...2099).contains(year) else { return nil }
        return year * 2 + (winter ? 1 : 0)
    }

    /// `term_name`: "WiSe 26/27", "SoSe 27"
    static func termName(_ t: Int) -> String {
        let year = t / 2
        func two(_ n: Int) -> String { String(format: "%02d", ((n % 100) + 100) % 100) }
        return t % 2 == 1 ? "WiSe \(two(year))/\(two(year + 1))" : "SoSe \(two(year))"
    }

    /// `term_of_date`: Semester einer Pruefung aus ihrem Datum, wenn die Semesterspalte fehlt: Januar-April -> WiSe davor
    /// (Pruefungszeitraum Februar/Maerz), Mai-Oktober -> SoSe (Juli-September), November/Dezember -> WiSe
    static func termOfDate(_ d: String?) -> Int? {
        guard let raw = d else { return nil }
        let d = PyText.strip(raw)
        let month: Int, year: Int
        if let m = dateDERE.match(d), let mo = PyText.int(digits: m.group(2) ?? ""), let y = PyText.int(digits: m.group(3) ?? "") {
            month = mo; year = y
        } else if let m = dateISORE.match(d), let y = PyText.int(digits: m.group(1) ?? ""), let mo = PyText.int(digits: m.group(2) ?? "") {
            month = mo; year = y
        } else {
            return nil
        }
        guard (1...12).contains(month), (1990...2099).contains(year) else { return nil }
        if month <= 4 { return (year - 1) * 2 + 1 }
        return month <= 10 ? year * 2 : year * 2 + 1
    }

    /// `row_term`: Semester einer QIS-Zeile aus der Semesterspalte, sonst aus dem Pruefungsdatum
    static func rowTerm(_ r: [String: JSONValue]) -> Int? {
        parseTerm(r["semester"]?.string) ?? termOfDate(r["datum"]?.string)
    }

    /// `norm_semester`: "Wintersemester 2023/24", "WS 23/24", "W23" -> "WiSe 23/24", "Sommersemester 2024" -> "SoSe 24";
    /// Unbekanntes bleibt (ohne Leerraum aussen)
    static func normSemester(_ s: String?) -> String {
        parseTerm(s).map(termName) ?? PyText.strip(s ?? "")
    }

    /// `_is_term_cell`: Semester in einer Zelle, ohne reine Ziffern (HIS-Schluessel koennte auch eine Nummer sein)
    private static func isTermCell(_ c: String) -> Bool {
        !isDigit(c) && parseTerm(c) != nil
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
            } else if out["semester"] == nil, isTermCell(c) {
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

    /// `_level`: mit Spalte "Prf.Art" (LUH, `artColumn`: eine Zeile traegt PL/SL) entscheidet allein die Art: PL/SL ist
    /// eine Leistung, ohne Art eine Modul- oder Bereichszeile (auch mit Wert in "Versuch")
    private static func level(_ r: [String: JSONValue], artColumn: Bool = false) -> String {
        if isBereichText(text(r["text"]) ?? "") { return "bereich" }
        if truthy(r["art"]) { return "pruefung" }
        if artColumn && text(r["source"]) != "anmeldung" { return "modul" }
        return PyText.strip(text(r["versuch"]) ?? "").isEmpty ? "modul" : "pruefung"
    }

    /// `iso_date`: "21.08.2026" -> "2026-08-21", sonst ""
    static func isoDate(_ d: String?) -> String {
        guard let d, let m = dateDERE.match(PyText.strip(d)), let day = PyText.int(digits: m.group(1) ?? ""),
              let month = PyText.int(digits: m.group(2) ?? ""), let year = PyText.int(digits: m.group(3) ?? ""),
              (1...12).contains(month), (1...31).contains(day), (1990...2099).contains(year) else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// `is_recognized`: Note "0,0" = anerkannt ohne Note (zaehlt nicht zum Schnitt, die LP zaehlen)
    static func isRecognized(_ note: String?) -> Bool {
        let s = PyText.strip(note ?? "")
        return noteRE.match(s) != nil && num(.string(s)) == 0
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
            if truthy(g["semester"]), parseTerm(text(g["semester"])) == nil, f["semester"] == nil {
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
            var semNorm = normSemester(text(g["semester"]))
            if semNorm.isEmpty, let t = termOfDate(text(g["datum"])) { semNorm = termName(t) }   // leere Semesterspalte: Datum
            g["semester_norm"] = .string(semNorm)
            // LUH: Note "0,0" heisst anerkannt ohne Note (12.11.2026: vorher stand "0,0" als Note in Uni & Noten und im
            // Studienverlauf); bestanden laut Status, zaehlt nicht zum Schnitt, die LP zaehlen
            let recognized = isRecognized(text(g["note"]))
            g["anerkannt"] = .bool(recognized)
            if recognized { g["note"] = .string("") }
            g["datum_iso"] = .string(isoDate(text(g["datum"])))
            let nr = truthy(g["pruefungsnr"]) ? text(g["pruefungsnr"]) : text(g["text"])
            let key = [nr ?? "\u{0}none", text(g["art"]) ?? "", semNorm, PyText.strip(text(g["versuch"]) ?? ""),
                       text(g["note"]) ?? "", text(g["datum"]) ?? ""].map { $0.unicodeScalars.map(\.value) }
            guard seen.insert(key).inserted else { continue }
            let note = num(g["note"])
            let passed = isPassed(g)
            g["passed"] = .bool(passed)
            // Studienleistung (SL) ist immer unbenotet
            g["graded"] = .bool(note.map { $0 >= 1.0 && $0 <= 4.0 } == true && passed && text(g["art"]) != "SL")
            out.append(g)
        }
        // Spalte "Prf.Art" vorhanden (LUH): PL/SL sind Leistungen, Zeilen ohne Art Modul- oder Bereichszeilen
        let artColumn = out.contains { ["PL", "SL"].contains(text($0["art"]) ?? "") }
        for i in out.indices { out[i]["level"] = .string(level(out[i], artColumn: artColumn)) }
        return count(out)
    }

    // MARK: Zaehlende Leistungen (12.11.2026)

    /// `_name_key`: Text klein, Leerraum zusammengefasst (Codepunkte)
    private static func nameKey(_ r: [String: JSONValue]) -> [UInt32] {
        let words = PyText.lower(text(r["text"]) ?? "").unicodeScalars.split(whereSeparator: PyText.isSpace)
        return Array(words.map { $0.map(\.value) }.joined(separator: [32]))
    }

    /// `_nr`: Pruefungsnummer nur aus ASCII-Ziffern, sonst ""
    private static func nr(_ r: [String: JSONValue]) -> String {
        let n = PyText.strip(text(r["pruefungsnr"]) ?? "")
        return !n.isEmpty && n.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 } ? n : ""
    }

    /// `_nr_child`: 1101 unter 11 (Praefix), 111 unter 110 (letzte Ziffer)
    static func nrChild(_ p: String, _ m: String) -> Bool {
        guard !p.isEmpty, !m.isEmpty, p != m else { return false }
        if p.count > m.count, p.hasPrefix(m) { return true }
        return p.count == m.count && m.count >= 3 && m.hasSuffix("0") && p.dropLast() == m.dropLast()
    }

    /// `_chrono`: SoSe 24 -> 48, WiSe 24/25 -> 49
    static func chrono(_ semesterNorm: String) -> Int? {
        guard let m = semKeyRE.match(semesterNorm), let y = Int(m.group(2) ?? "") else { return nil }
        return y * 2 + (m.group(1) == "WiSe" ? 1 : 0)
    }

    private static func lvl(_ r: [String: JSONValue]) -> String { text(r["level"]) ?? "" }

    /// `_when`: Reihenfolge fuer "der neueste Eintrag": Datum, dann Semester, dann Position
    private static func when(_ r: [String: JSONValue], _ i: Int) -> (String, Int, Int) {
        let iso = text(r["datum_iso"]) ?? ""
        return (iso.isEmpty ? isoDate(text(r["datum"])) : iso, rowTerm(r) ?? -1, i)
    }

    /// `_parent`: Modulzeile (Index) einer Pruefungszeile oder nil
    private static func parent(_ m: [[String: JSONValue]], _ i: Int) -> Int? {
        let p = m[i]
        let mods = m.indices.filter { lvl(m[$0]) == "modul" && text(m[$0]["source"]) != "anmeldung" }
        let key = nameKey(p)
        let same = mods.filter { !key.isEmpty && nameKey(m[$0]) == key }
        if let j = same.min(by: { ($0 > i ? 1 : 0, abs($0 - i)) < ($1 > i ? 1 : 0, abs($1 - i)) }) { return j }
        let n = nr(p)
        let byNr = mods.filter { nrChild(n, nr(m[$0])) }
        // max nach (Laenge der Modulnummer, davor, naeher); bei Gleichstand wie Pythons max die erste
        if var best = byNr.first {
            func k(_ j: Int) -> (Int, Int, Int) { (nr(m[j]).count, j < i ? 1 : 0, -abs(j - i)) }
            for j in byNr.dropFirst() where k(j) > k(best) { best = j }
            return best
        }
        var j = i - 1
        while j >= 0 {
            let l = lvl(m[j])
            if l == "pruefung" { j -= 1; continue }
            if l != "modul" || text(m[j]["source"]) == "anmeldung" { return nil }
            if isTrue(m[j]["passed"]), let pm = chrono(text(m[j]["semester_norm"]) ?? ""),
               let pp = chrono(text(p["semester_norm"]) ?? ""), pp > pm { return nil }
            return j
        }
        return nil
    }

    /// LP einer Zeile fuer die Summe: Zahl > 0, sonst 0
    private static func lp(_ r: [String: JSONValue]) -> Double {
        guard let v = num(r["credits"]), v.isFinite, v > 0 else { return 0 }
        return v
    }

    /// `count`: je Zeile `counted` (zaehlt als bestandene Leistung) und `lp_counted` (ihre LP in der Summe).
    /// Bestandene Modulzeile: ihre LP (ohne LP dort die der bestandenen Pruefungen darunter), die Pruefungen darunter
    /// nicht noch einmal. Nicht bestandenes Modul: seine bestandenen Pruefungen, zusammen hoechstens die LP der
    /// Modulzeile. Bestandene Pruefung ohne Modulzeile: ihre LP. Bereichs-/Summenzeilen und Anmeldungen nie.
    static func count(_ rows: [[String: JSONValue]]) -> [[String: JSONValue]] {
        var m = rows
        for i in m.indices {
            m[i]["counted"] = false; m[i]["lp_counted"] = .number(0); m[i]["superseded"] = false
            m[i]["modul_nr"] = .null; m[i]["modul_text"] = .null
        }
        // Mehrere bestandene Eintraege derselben Pruefung (gleiche Nummer und gleicher Text, z. B. Notenverbesserung): es
        // gilt der neueste nach Datum (dann Semester, dann Reihenfolge); die aelteren zaehlen weder zum Schnitt noch zu den
        // LP (12.11.2026: vorher zaehlten beide). Nicht bestandene Eintraege sind Fehlversuche und ersetzen nichts.
        func candidate(_ r: [String: JSONValue]) -> Bool {
            lvl(r) == "pruefung" && isTrue(r["passed"]) && text(r["source"]) != "anmeldung"
        }
        var newest: [[[UInt32]]: Int] = [:]
        for i in m.indices where candidate(m[i]) {
            let n = nr(m[i])
            let k = [n.isEmpty ? nameKey(m[i]) : n.unicodeScalars.map(\.value), nameKey(m[i])]
            if let j = newest[k] {
                let a = when(m[i], i), b = when(m[j], j)
                if PyText.less(b.0, a.0) || (a.0.unicodeScalars.elementsEqual(b.0.unicodeScalars) && (a.1, a.2) >= (b.1, b.2)) { newest[k] = i }
            } else {
                newest[k] = i
            }
        }
        let keep = Set(newest.values)
        for i in m.indices where candidate(m[i]) && !keep.contains(i) { m[i]["superseded"] = true; m[i]["graded"] = false }

        var kids: [Int: [Int]] = [:], alone: [Int] = []
        for i in m.indices where lvl(m[i]) == "pruefung" {
            let j = parent(m, i)
            // Modul der Leistung (QIS: die Modulzeile davor; Nummer und Text fuer Studienverlauf und Anzeige)
            if let j {
                let n = nr(m[j])
                m[i]["modul_nr"] = n.isEmpty ? .null : .string(n)
                m[i]["modul_text"] = m[j]["text"] ?? .null
            }
            guard isTrue(m[i]["passed"]), !isTrue(m[i]["superseded"]) else { continue }
            if let j { kids[j, default: []].append(i) } else { alone.append(i) }
        }
        for i in m.indices where lvl(m[i]) == "modul" {
            let own = lp(m[i])
            if isTrue(m[i]["passed"]) {
                m[i]["counted"] = true
                m[i]["lp_counted"] = .number(own > 0 ? own : PyMath.sum((kids[i] ?? []).map { lp(m[$0]) }))
            } else {
                var left = own > 0 ? own : .infinity
                for k in kids[i] ?? [] {
                    let take = min(lp(m[k]), left)
                    m[k]["counted"] = true
                    m[k]["lp_counted"] = .number(take)
                    left -= take
                }
            }
        }
        for i in alone { m[i]["counted"] = true; m[i]["lp_counted"] = .number(lp(m[i])) }
        return m
    }

    /// `counted_lp`: Summe `lp_counted` bereinigter Zeilen, auf eine Stelle gerundet
    static func countedLP(_ m: [[String: JSONValue]]) -> Double {
        round1(PyMath.sum(m.map { $0["lp_counted"]?.double ?? 0 }))
    }

    /// `credits_done`: LP aller bestandenen QIS-Leistungen (je Leistung einmal), die eine Zahl fuer "LP erreicht"
    /// ueberall (Uni & Noten `summary`, Studienverlauf `StudyPlanEngine.compute`)
    static func creditsDone(_ rows: [[String: JSONValue]]) -> Double { countedLP(model(rows)) }

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
        let passed = m.filter { isTrue($0["counted"]) }
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
            "credits": .number(countedLP(m)),
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
