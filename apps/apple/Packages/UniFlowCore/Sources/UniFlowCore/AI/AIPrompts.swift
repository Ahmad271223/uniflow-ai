import Foundation

/// Prompts der KI wie app/ai.py, byte-gleich (Vertrag packages/shared-contracts/ai/contract.json, AIContractTests).
/// Eingaben sind Python-Werte (`PyJSON`): `str()` von Zahlen, `None` und Wahrheitswerte wie in Python; Kuerzungen
/// wie Pythons Slicing nach Codepunkten.
public enum AIPrompts {
    // MARK: Python-Hilfen

    /// `d.get(key)`; nil fuer fehlende Schluessel und Nicht-Objekte
    static func get(_ v: PyJSON?, _ key: String) -> PyJSON? {
        guard case .object(let members)? = v else { return nil }
        return members.last { $0.key == key }?.value
    }

    /// Wahrheitswert wie `bool(x)` in Python
    static func truthy(_ v: PyJSON?) -> Bool {
        switch v {
        case .none, .some(.null): return false
        case .some(.bool(let b)): return b
        case .some(.int(let digits)): return digits != "0"
        case .some(.float(let d)): return d != 0
        case .some(.string(let s)): return !s.isEmpty
        case .some(.array(let a)): return !a.isEmpty
        case .some(.object(let m)): return !m.isEmpty
        }
    }

    /// `str(x)`; fehlend wie `None`
    static func str(_ v: PyJSON?) -> String { PyText.str(v ?? .null) }

    /// `a or b`
    static func or(_ a: PyJSON?, _ b: PyJSON?) -> PyJSON? { truthy(a) ? a : b }

    /// `s[:n]`
    static func head(_ s: String, _ n: Int) -> String { PyText.slice(s, 0, n) }

    // MARK: Tutor (`ai.tutor_prompt`)

    /// Schluessel der Modi wie `ai.TUTOR_MODES` (fuer die Auswahl in der App)
    public static var tutorModeKeys: [String] { AIPromptTexts.tutorModes.map(\.key) }

    /// Text des Modus; unbekannte Modi wie `explain`
    static func tutorInstruction(_ mode: String) -> String {
        AIPromptTexts.tutorModes.first { $0.key.unicodeScalars.elementsEqual(mode.unicodeScalars) }?.text
            ?? AIPromptTexts.tutorModes.first { $0.key == "explain" }!.text
    }

    /// `ai.TUTOR_HISTORY_TURNS` / `ai.TUTOR_HISTORY_CHARS`
    public static let tutorHistoryTurns = 6
    static let tutorHistoryChars = 1500

    /// `ai.tutor_history`: nur {role, text} mit Text, die letzten `tutorHistoryTurns`; role user oder assistant
    public static func tutorHistory(_ raw: PyJSON?) -> [(role: String, text: String)] {
        guard case .array(let items)? = raw else { return [] }
        let out: [(role: String, text: String)] = items.compactMap { item in
            guard case .object(let members) = item, case .string(let t)? = members.first(where: { $0.key == "text" })?.value,
                  !PyText.strip(t).isEmpty else { return nil }
            let role = members.first(where: { $0.key == "role" })?.value
            return (role == .string("user") ? "user" : "assistant", t)
        }
        return Array(out.suffix(tutorHistoryTurns))
    }

    // MARK: Kontext aus Stud.IP (`ai.studip_context`)

    /// `ai.STUDIP_CONTEXT_CHARS` / `ai.STUDIP_CONTEXT_SESSIONS`
    public static let studipContextChars = 700
    static let studipContextSessions = 3

    /// `_one_line(t, n)`: Leerraum (Leerzeichen, Tab, Zeilenwechsel) verdichtet, aussen ohne Leerzeichen, nach `n`
    /// Zeichen gekuerzt mit " …"
    static func oneLine(_ t: String?, _ n: Int) -> String {
        var u = Array((t ?? "").unicodeScalars)
        var out: [Unicode.Scalar] = []
        var gap = false
        for c in u {
            if [" ", "\t", "\r", "\n", "\u{0C}", "\u{0B}"].contains(c) { gap = true; continue }
            if gap, !out.isEmpty { out.append(" ") }
            gap = false
            out.append(c)
        }
        u = out
        guard u.count > n else { return String(String.UnicodeScalarView(u)) }
        var head = Array(u[0..<n])
        while head.last == " " { head.removeLast() }
        return String(String.UnicodeScalarView(head)) + " …"
    }

    /// `ai.studip_context(course_desc, misc, sessions)`: Kursbeschreibung, Sonstiges und bis zu drei Sitzungsthemen
    /// (`date` ISO, `topic`) als Zeilen, hoechstens `studipContextChars` Zeichen; leer ohne Inhalt
    public static func studipContext(courseDescription: String?, miscellaneous: String?, sessions: [(date: String, topic: String)]) -> String {
        var lines: [String] = []
        let d = oneLine(courseDescription, 300)
        if !d.isEmpty { lines.append("Kursbeschreibung: \(d)") }
        let m = oneLine(miscellaneous, 200)
        if !m.isEmpty { lines.append("Hinweise zum Kurs: \(m)") }
        for x in sessions.prefix(studipContextSessions) {
            let t = oneLine(x.topic, 200)
            guard !t.isEmpty else { continue }
            let day = Array(x.date.unicodeScalars)
            if day.count >= 10 {
                lines.append("Sitzung am \(PyText.slice(x.date, 8, 10)).\(PyText.slice(x.date, 5, 7)).: \(t)")
            } else {
                lines.append("Sitzung: \(t)")
            }
        }
        return head(lines.joined(separator: "\n"), studipContextChars)
    }

    /// Ueberschrift der eigenen Notizen zur Seite im Tutor-Prompt (gleich in app/ai.py `OWN_NOTES_HEADING`)
    public static let ownNotesHeading = "MEINE NOTIZEN ZU DIESER SEITE (Seitennotizen und Blatt daneben; Handschrift automatisch erkannt, kann Lesefehler enthalten):"

    /// `studip` (2.11.2026): Kursbeschreibung und Sitzungsthemen der Woche (`studipContext`), nur wenn vorhanden.
    /// `pageIndex` (4.11.2026, nur Geraet): Einordnung der Seite aus der Bibliothek (`PageExplain.indexContext`) bei
    /// eigenen Fragen; leer laesst den Prompt byte-gleich mit app/ai.py
    /// `ownNotes` (5.11.2026, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md): Seitennotizen und Blatt daneben dieser Seite
    /// (Textfelder und erkannte Handschrift), wie `own_notes` in app/ai.py; leer = kein Block
    /// Zusatz im Prompt, wenn ein Ausschnitt der Seite als Bild mitgeht ("Bereich an KI", 05.11.2026)
    public static let tutorImageNote = "ANGEHAENGTES BILD: Ausschnitt der Seite, den ich eingekreist habe (PDF, meine Handschrift und Notizen). Beziehe dich vor allem darauf; der markierte Text oben ist die Texterkennung dieses Ausschnitts und kann Fehler enthalten."

    public static func tutor(mode: String, pageText: String, selection: String = "", question: String = "", ownSolution: String = "",
                             course: String = "", fileName: String = "", page: PyJSON? = nil, sources: [PyJSON]? = nil,
                             history: [(role: String, text: String)] = [], studip: String = "", pageIndex: String = "",
                             ownNotes: String = "") -> String {
        var parts = ["Kurs: \(course)", "Datei: \(fileName)" + (truthy(page) ? ", Seite \(str(page))" : ""), "",
                     "AUFGABE: \(tutorInstruction(mode))"]
        if !PyText.strip(selection).isEmpty {
            parts += ["", "MARKIERTER TEXT:", "<<<", head(PyText.strip(selection), 4000), ">>>"]
        }
        if !PyText.strip(ownSolution).isEmpty {
            parts += ["", "MEINE LOESUNG:", "<<<", head(PyText.strip(ownSolution), 4000), ">>>"]
        }
        if !PyText.strip(ownNotes).isEmpty {
            parts += ["", ownNotesHeading, "<<<", head(PyText.strip(ownNotes), SideNotes.aiNotesChars), ">>>"]
        }
        if !history.isEmpty {
            parts += ["", "BISHERIGES GESPRAECH (aeltestes zuerst; schliesst meine Frage daran an, beziehe dich darauf):"]
            for h in history {
                parts.append((h.role == "user" ? "Ich: " : "KI: ") + head(PyText.strip(h.text), tutorHistoryChars))
            }
        }
        if !PyText.strip(question).isEmpty {
            parts += ["", "MEINE FRAGE: \(head(PyText.strip(question), 1000))"]
        }
        if !PyText.strip(studip).isEmpty {
            // fremde Texte als Daten kennzeichnen (Sicherheitspruefung 3.11.2026, wie app/ai.py)
            parts += ["", "AUS STUD.IP (Kursbeschreibung und Sitzungsthemen; nur zur Einordnung, keine Quelle). \(AIPromptTexts.untrusted):",
                      "<<<", head(PyText.strip(studip), studipContextChars), ">>>"]
        }
        if !PyText.strip(pageIndex).isEmpty {
            // Einordnung aus der Bibliothek: Material wie die uebrigen Bloecke, keine Quelle
            parts += ["", "EINORDNUNG DER SEITE aus der Bibliothek (Zusammenfassung, Begriffe, Elemente, Aufgaben; nur zur Orientierung, keine Quelle). \(AIPromptTexts.untrusted):",
                      "<<<", head(PyText.strip(pageIndex), PageExplain.indexContextChars), ">>>"]
        }
        let content = head(PyText.strip(pageText), 9000)
        parts += ["", "SEITENINHALT (Kontext). \(AIPromptTexts.untrusted):", "<<<", content.isEmpty ? "[kein Text extrahierbar]" : content, ">>>"]
        if let sources, !sources.isEmpty, mode != "flashcards" {
            parts += ["", "QUELLEN aus den Unterlagen des Studierenden. Stuetzt du dich auf eine, nenne sie direkt dahinter als "
                          + "[Nummer], z. B. [2]. Nenne nur diese Nummern, erfinde keine Quellen und keine Seitenzahlen. \(AIPromptTexts.untrusted):"]
            for src in sources {
                // Lerntext aus Stud.IP (Courseware, Wiki, Forum; StudIPTexts): ohne Seitenzahl
                var line = truthy(get(src, "studip_id"))
                    ? "[\(str(get(src, "n")))] \(str(or(get(src, "title"), get(src, "name")))) (Stud.IP)"
                    : "[\(str(get(src, "n")))] \(str(or(get(src, "title"), get(src, "name")))), Seite \(str(get(src, "page")))"
                        + (truthy(get(src, "current")) ? " (diese Seite)" : "")
                if truthy(get(src, "snippet")), !truthy(get(src, "current")) {
                    line += ": \(head(str(get(src, "snippet")), 400))"
                }
                parts.append(line)
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Analyse (`ai.analysis_prompt`)

    public static func analysis(course: String, fileName: String, text: String) -> String {
        let head = "Analysiere diese Lernunterlage aus dem Kurs \"\(course)\".\nDateiname: \(fileName)\n\n"
        return head + AIPromptTexts.analysisFields + "\n\nInhalt (ggf. gekuerzt):\n<<<\n"
            + (PyText.strip(text).isEmpty ? "[kein Text extrahierbar - schaetze anhand des Dateinamens]" : text) + "\n>>>"
    }

    // MARK: Tag (der KI-Wochenplan `ai.week_plan_prompt` ist entfallen, der Tag bleibt fuer die Wochentests)

    /// Tag als (Jahr, Monat, Tag) fuer Vergleiche und Rechnen ohne Zeitzone
    public struct Day: Comparable, Sendable {
        public let year: Int, month: Int, day: Int
        public init?(iso: String) {
            let p = iso.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
            year = p[0]; month = p[1]; day = p[2]
        }
        init(_ y: Int, _ m: Int, _ d: Int) { year = y; month = m; day = d }

        private static var calendar: Calendar {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            return c
        }
        private var date: Date { Day.calendar.date(from: DateComponents(year: year, month: month, day: day))! }

        /// `date.isoformat()`
        public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
        /// `date.weekday()`: Montag = 0
        var weekday: Int { (Day.calendar.component(.weekday, from: date) + 5) % 7 }
        func adding(_ days: Int) -> Day {
            let c = Day.calendar.dateComponents([.year, .month, .day], from: Day.calendar.date(byAdding: .day, value: days, to: date)!)
            return Day(c.year!, c.month!, c.day!)
        }
        public static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
    }

    // MARK: Wochentest (`ai.test_text_block`, `ai.exam_text_block`, `ai._test_prompt`)

    static func materialLabel(_ m: PyJSON) -> String {
        "\(str(or(get(m, "title"), get(m, "name")))) (\(str(get(m, "doc_type"))), Schwierigkeit \(str(get(m, "difficulty"))))"
    }

    public static func testTextBlock(_ materials: [PyJSON]) -> String {
        materials.map { "### \(materialLabel($0))\n\(head(str(or(get($0, "text"), .string(""))), 3500))" }.joined(separator: "\n\n")
    }

    public static func examTextBlock(_ exam: PyJSON?) -> String {
        guard truthy(exam) else { return "" }
        return "### \(str(or(get(exam, "title"), get(exam, "name"))))\n\(head(str(or(get(exam, "text"), .string(""))), 3500))"
    }

    /// `ai._test_prompt`: Regel vom 29.10.2026 (Standard: 15 Aufgaben 4/6/5, alle Aufgabenarten) bzw. die Parameter des
    /// Dialogs (04.11.2026: Zahl, Schwierigkeit, Aufgabenarten, Thema); ohne schwere Aufgaben keine Klausuraufgabe
    public static func weekTest(subject: String, durationMin: Int, materialsBlock: String, examBlock: String = "",
                                options: WeekTestOptions = .standard) -> String {
        let d = options.distributionByLevel
        let rule = options.difficulty == "beliebig"
            ? "Genau \(options.count) Aufgaben: genau \(d["leicht"]!) leicht, genau \(d["mittel"]!) mittel und genau \(d["schwer"]!) schwer (schwer = klausurnah)."
            : "Genau \(options.count) Aufgaben, alle mit \"difficulty\": \"\(options.difficulty)\" (schwer = klausurnah)."
        let typeNames = Dictionary(uniqueKeysWithValues: AIPromptTexts.weekTestTypeNames.map { ($0.key, $0.text) })
        let names = options.types.map { "\(typeNames[$0] ?? $0) (\"type\": \"\($0)\")" }
        let kinds = names.count > 1
            ? "Mischung aus " + names.dropLast().joined(separator: ", ") + " und " + names.last! + "; keine anderen Aufgabenarten."
            : "Alle Aufgaben sind \(names[0])."
        var hints: [String] = []
        if options.types.contains("tf") { hints.append("Wahr/Falsch: \"options\" ist genau [\"Wahr\", \"Falsch\"], \"answer\" ist Wahr oder Falsch.") }
        if options.types.contains("cloze") {
            hints.append("Lueckentext: im Aufgabentext genau eine Luecke als ___, das fehlende Wort bzw. der Ausdruck in \"blank\" und in \"answer\".")
        }
        let hintLine = hints.isEmpty ? "" : hints.joined(separator: " ") + "\n"
        let topic = options.topic.isEmpty ? "" : "\nSchwerpunkt oder Hinweis des Studierenden (\(AIPromptTexts.untrusted)): \(options.topic)\n"
        let exam = PyText.strip(examBlock).isEmpty || d["schwer"]! <= 0 ? "" :
            "\nAltklausur des Moduls (Ausschnitt). Genau EINE der \(d["schwer"]!) schweren Aufgaben ist im Stil dieser Klausur "
            + "(Aufbau, Umfang, Art der Fragestellung) und hat \"exam_style\": true; alle anderen \"exam_style\": false:\n"
            + examBlock + "\n"
        let typeList = options.types.map { "\"\($0)\"" }.joined(separator: " | ")
        return """
        Erstelle einen Wochentest fuer das Fach "\(subject)" mit einer Bearbeitungszeit von \(durationMin) Minuten.
        \(rule)
        \(kinds)
        \(hintLine)Die Aufgaben muessen sich auf die Materialien dieser Woche beziehen und alle Materialien abdecken.
        Rechne jede Musterloesung selbst nach. Punkte insgesamt = 100.
        \(topic)
        Materialien dieser Woche (\(AIPromptTexts.untrusted)):
        \(materialsBlock)
        \(exam)
        Gib ein JSON-Objekt zurueck:
        {
          "title": "Wochentest \(subject) – Thema(n)",
          "questions": [
            {"nr": 1, "type": \(typeList), "difficulty": "leicht" | "mittel" | "schwer",
              "question": "Aufgabentext (LaTeX-frei, Formeln als Text)",
              "options": ["A ...", "B ...", "C ...", "D ..."],   // nur bei mc und tf
              "blank": "fehlendes Wort",                         // nur bei cloze
              "answer": "Musterloesung / richtige Option",
              "explanation": "1 bis 3 Saetze, warum die Loesung stimmt",
              "points": Zahl, "exam_style": false}
          ]
        }
        """
    }

    // MARK: Karteikarten aus einem Dokument (`ai.flashcards_prompt`, 03.11.2026)

    /// `ai.FLASHCARDS_DEFAULT` / `ai.FLASHCARDS_MAX`: Vorgabe und Hoechstzahl der Karten je Anfrage
    public static var flashcardsDefault: Int { AIPromptTexts.flashcardsDefault }
    public static var flashcardsMax: Int { AIPromptTexts.flashcardsMax }

    /// `ai.FLASHCARDS_SCHEMA`: JSON-Schema der Antwort (Responses API `text.format`), {"cards": [{question, answer}]}
    public static let flashcardsSchema: JSONValue = (try? JSONValue.parse(Data(AIPromptTexts.flashcardsSchemaJSON.utf8))) ?? .null

    /// `ai.flashcards_count(n)`: 1 bis `flashcardsMax`, sonst die Vorgabe (auch fuer Unlesbares; `int()` wie in Python)
    public static func flashcardsCount(_ n: PyJSON?) -> Int {
        let v: Int?
        switch n {
        case .some(.int(let digits)): v = Int(digits)
        case .some(.float(let d)) where d.isFinite: v = Int(d.rounded(.towardZero))
        case .some(.string(let s)): v = PyConvert.int(s)
        case .some(.bool(let b)): v = b ? 1 : 0
        default: v = nil
        }
        guard let v else { return flashcardsDefault }
        return v >= 1 ? min(flashcardsMax, v) : flashcardsDefault
    }

    /// `ai.flashcards_prompt(course, file_name, pages, text, count, topic)`: genau `count` Karten aus dem Text der
    /// Seiten `pages` (aufsteigend) von `fileName`; `topic` grenzt den Stoff ein. Antwort in der Form von `flashcardsSchema`.
    public static func flashcards(course: String, fileName: String, pages: [Int], text: String, count: Int = 10,
                                  topic: String = "") -> String {
        var whereText = ""
        if let first = pages.first, let last = pages.last {
            whereText = pages.count == 1 ? ", Seite \(first)" : ", Seiten \(first)–\(last)"
        }
        var parts = ["Kurs: \(course)", "Datei: \(fileName)\(whereText)", "",
                     "AUFGABE: Erstelle genau \(count) Karteikarten aus dem Inhalt. Vorn eine klare Frage, hinten eine kurze, "
                     + "vollstaendige Antwort (1-3 Saetze, Formeln als Text). Decke die wichtigsten Begriffe, Zusammenhaenge und "
                     + "Rechenwege ab; keine Karte doppelt, nichts erfinden, was nicht im Inhalt steht."]
        if !PyText.strip(topic).isEmpty {
            parts += ["", "SCHWERPUNKT: \(head(PyText.strip(topic), 300))"]
        }
        let content = head(PyText.strip(text), AIPromptTexts.flashcardsTextChars)
        parts += ["", "INHALT. \(AIPromptTexts.untrusted):", "<<<", content.isEmpty ? "[kein Text extrahierbar]" : content, ">>>",
                  "", #"Gib ein JSON-Objekt zurueck: {"cards": [{"question": "Frage", "answer": "Antwort"}]}"#]
        return parts.joined(separator: "\n")
    }

    // MARK: Bewertung (`ai.grade_prompt`)

    public static func grade(subject: String, questions: [PyJSON], answers: PyJSON) -> String {
        let qa = questions.map { q -> String in
            let nr = str(get(q, "nr"))
            let given = or(get(answers, nr), .string(""))
            let answer = truthy(given) ? str(given) : "[keine Antwort]"
            return "Aufgabe \(nr) (\(str(get(q, "points"))) P., \(str(get(q, "type")))): \(str(get(q, "question")))\n"
                + "  Musterloesung: \(str(get(q, "answer")))\n  Antwort des Studierenden: \(answer)"
        }
        return """
        Bewerte diesen Wochentest im Fach "\(subject)". Sei fair aber streng, Teilpunkte sind erlaubt.
        Bei Multiple-Choice zaehlt nur die exakte Option (Buchstabe oder Text).

        \(qa.joined(separator: "\n"))

        Gib ein JSON-Objekt zurueck:
        {
          "total": Zahl,
          "max": Zahl,
          "per_question": [{"nr": 1, "points": Zahl, "max": Zahl, "feedback": "1-2 Saetze, was richtig/falsch war"}],
          "summary": "3-4 Saetze Gesamtfeedback mit konkreten Lernempfehlungen",
          "weak_topics": ["Thema", ...]
        }
        """
    }
}
