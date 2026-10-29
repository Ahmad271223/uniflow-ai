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

    /// Text des Modus; unbekannte Modi wie `explain`
    static func tutorInstruction(_ mode: String) -> String {
        AIPromptTexts.tutorModes.first { $0.key.unicodeScalars.elementsEqual(mode.unicodeScalars) }?.text
            ?? AIPromptTexts.tutorModes.first { $0.key == "explain" }!.text
    }

    public static func tutor(mode: String, pageText: String, selection: String = "", question: String = "", ownSolution: String = "",
                             course: String = "", fileName: String = "", page: PyJSON? = nil, sources: [PyJSON]? = nil) -> String {
        var parts = ["Kurs: \(course)", "Datei: \(fileName)" + (truthy(page) ? ", Seite \(str(page))" : ""), "",
                     "AUFGABE: \(tutorInstruction(mode))"]
        if !PyText.strip(selection).isEmpty {
            parts += ["", "MARKIERTER TEXT:", "<<<", head(PyText.strip(selection), 4000), ">>>"]
        }
        if !PyText.strip(ownSolution).isEmpty {
            parts += ["", "MEINE LOESUNG:", "<<<", head(PyText.strip(ownSolution), 4000), ">>>"]
        }
        if !PyText.strip(question).isEmpty {
            parts += ["", "MEINE FRAGE: \(head(PyText.strip(question), 1000))"]
        }
        let content = head(PyText.strip(pageText), 9000)
        parts += ["", "SEITENINHALT (Kontext):", "<<<", content.isEmpty ? "[kein Text extrahierbar]" : content, ">>>"]
        if let sources, !sources.isEmpty, mode != "flashcards" {
            parts += ["", "QUELLEN aus den Unterlagen des Studierenden. Stuetzt du dich auf eine, nenne sie direkt dahinter als "
                          + "[Nummer], z. B. [2]. Nenne nur diese Nummern, erfinde keine Quellen und keine Seitenzahlen:"]
            for src in sources {
                var line = "[\(str(get(src, "n")))] \(str(or(get(src, "title"), get(src, "name")))), Seite \(str(get(src, "page")))"
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

    // MARK: Wochenplan (`ai.week_plan_prompt`)

    static let days = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]

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

    /// `int(x * 60)` fuer Stunden pro Tag (ganze Zahl oder Kommazahl)
    static func minutes(_ hours: PyJSON?) -> String {
        switch hours {
        case .some(.int(let digits)): return String((Int(digits) ?? 0) * 60)
        case .some(.float(let d)): return String(Int((d * 60).rounded(.towardZero)))
        case .some(.bool(let b)): return b ? "60" : "0"
        default: return "0"
        }
    }

    public static func weekPlan(weekStart: Day, materials: [PyJSON], subjects: [PyJSON], settings: PyJSON, carryOver: [PyJSON], today: Day) -> String {
        let freeDays: [String] = {
            guard case .array(let a)? = get(settings, "free_days") else { return [] }
            return a.compactMap { if case .int(let d) = $0, let i = Int(d), days.indices.contains(i) { return days[i] }; return nil }
        }()
        let free = freeDays.isEmpty ? "keine" : freeDays.joined(separator: ", ")
        let end = weekStart.adding(6)
        var pastNote = ""
        if weekStart <= today, today <= end {
            pastNote = "- Heute ist \(days[today.weekday]), der \(today.iso). Tage vor heute NICHT belegen.\n"
        } else if today < weekStart {
            pastNote = "- Heute ist der \(today.iso), die Planung gilt fuer die kommende Woche.\n"
        }
        let matLines = materials.map { m in
            "- file_id=\(str(get(m, "id"))) | Fach: \(str(get(m, "subject"))) | Kurs: \(head(str(get(m, "course_title")), 40)) | "
                + "\(str(or(get(m, "doc_type"), .string("?")))) | "
                + "Schwierigkeit \(str(or(get(m, "difficulty"), .string("?"))))/5 | ca. \(str(or(get(m, "est_minutes"), .string("?")))) min | "
                + str(or(get(m, "title"), get(m, "name")))
        }.joined(separator: "\n")
        let subjLines = subjects.map { "- \(str(get($0, "subject"))) (Wochentest \(str(get($0, "test_minutes"))) min)" }.joined(separator: "\n")
        let carry = carryOver.map { "- \(str(get($0, "title"))) (\(str(get($0, "subject"))))" }.joined(separator: "\n")
        return """
        Erstelle einen Lernplan fuer die Woche ab Montag \(weekStart.iso) (bis Sonntag \(end.iso)).

        Rahmen:
        \(pastNote)- HARTES LIMIT: maximal \(minutes(get(settings, "hours_per_day"))) Minuten pro Tag (Summe aller Bloecke eines Tages, Tests eingeschlossen). Lernbeginn ab \(str(get(settings, "day_start")))
        - Freie Tage (dort NICHTS einplanen, auch keine Tests): \(free)
        - Lieber weniger Bloecke als das Tageslimit ueberschreiten; nicht alles muss in diese Woche
        - Bloecke zwischen 30 und 120 Minuten, Pausen nicht einplanen (werden automatisch gemacht)
        - Reihenfolge nach Sinn: erst Vorlesung lesen, dann die passende Uebung, dann Wiederholung
        - Schwierige Themen (4-5) auf mehrere Bloecke verteilen und frueh in der Woche
        - Jedes Fach bekommt genau EINEN Block "test" mit der angegebenen Testdauer, bevorzugt am Ende der Woche (Fr/Sa), nie am freien Tag
        - Nicht erledigte Punkte der Vorwoche zuerst einplanen

        Faecher:
        \(subjLines)

        Nicht erledigt aus der Vorwoche:
        \(carry.isEmpty ? "- keine" : carry)

        Neue / offene Materialien (nach Schwierigkeit und Kurs geordnet):
        \(matLines.isEmpty ? "- (keine neuen Materialien)" : matLines)

        Gib ein JSON-Objekt zurueck:
        {
          "notes": "2-3 Saetze: wie die Woche aufgebaut ist und worauf der Fokus liegt",
          "items": [
            {"day": 0-6, "start_time": "HH:MM", "duration_min": Zahl, "subject": "Fachname exakt wie oben",
              "file_id": "file_id oder null", "title": "konkrete Aufgabe, z. B. 'GDS Kap. 2 lesen + Zusammenfassung'",
              "kind": "lernen" | "ueben" | "wiederholen" | "test"}
          ]
        }
        day: 0=Montag ... 6=Sonntag. Keine Ueberschneidungen am gleichen Tag.
        """
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

    public static func weekTest(subject: String, durationMin: Int, materialsBlock: String, examBlock: String = "") -> String {
        let d = Dictionary(uniqueKeysWithValues: AIPromptTexts.weekTestDifficulty.map { ($0.level, $0.count) })
        let exam = PyText.strip(examBlock).isEmpty ? "" :
            "\nAltklausur des Moduls (Ausschnitt). Genau EINE der 5 schweren Aufgaben ist im Stil dieser Klausur "
            + "(Aufbau, Umfang, Art der Fragestellung) und hat \"exam_style\": true; alle anderen \"exam_style\": false:\n"
            + examBlock + "\n"
        return """
        Erstelle einen Wochentest fuer das Fach "\(subject)" mit einer Bearbeitungszeit von \(durationMin) Minuten.
        Genau \(AIPromptTexts.weekTestTotal) Aufgaben: genau \(d["leicht"]!) leicht, genau \(d["mittel"]!) mittel und genau \(d["schwer"]!) schwer (schwer = klausurnah).
        Mischung aus Multiple-Choice (genau eine richtige Antwort), Kurzantwort und Rechen-/Programmieraufgaben.
        Die Aufgaben muessen sich auf die Materialien dieser Woche beziehen und alle Materialien abdecken.
        Rechne jede Musterloesung selbst nach. Punkte insgesamt = 100.

        Materialien dieser Woche:
        \(materialsBlock)
        \(exam)
        Gib ein JSON-Objekt zurueck:
        {
          "title": "Wochentest \(subject) – Thema(n)",
          "questions": [
            {"nr": 1, "type": "mc" | "short" | "calc", "difficulty": "leicht" | "mittel" | "schwer",
              "question": "Aufgabentext (LaTeX-frei, Formeln als Text)",
              "options": ["A ...", "B ...", "C ...", "D ..."],   // nur bei mc
              "answer": "Musterloesung / richtige Option",
              "points": Zahl, "exam_style": false}
          ]
        }
        """
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
