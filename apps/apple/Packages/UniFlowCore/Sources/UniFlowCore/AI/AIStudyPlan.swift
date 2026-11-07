import Foundation

// KI-Lernplan (Auftrag des Inhabers vom 07.11.2026): aus Modulen, Lehrwochen mit ihren Unterlagen, Klausurterminen,
// Lernzeit-Einstellungen und der freien Zeit je Tag schlaegt die KI Lernbloecke mit Thema und Dauer vor. Der Nutzer
// sieht den Vorschlag und uebernimmt ihn; nichts wird ungefragt eingetragen (`POST /api/calendar/ai-suggest` liefert
// nur den Vorschlag, `POST /api/calendar/ai-apply` legt die gewaehlten Bloecke an; AIPlanEndpoints.swift).
//
// Datenschutz: an die KI gehen nur Modultitel, Lehrwochen, Dateinamen mit Art und Dauer, Klausurtermine, Daten und
// Minuten - keine Namen von Personen, keine Kursnummern, keine Seitentexte, keine Noten (`AIStudyPlan.prompt`,
// AIStudyPlanTests). Dieselbe Prompt-Logik laeuft ueber das eigene ChatGPT (jeder Tarif) und ueber die StudiNow-KI
// (Pro AI, Aufgabe `study_plan` in app/ai_relay.py, Credits).

public enum AIStudyPlan {
    // MARK: Eingabe

    public struct FileInput: Equatable, Sendable {
        public var id: String
        public var name: String
        /// vorlesung | uebung | skript | …
        public var kind: String
        public var minutes: Int
        public init(id: String, name: String, kind: String, minutes: Int) { self.id = id; self.name = name; self.kind = kind; self.minutes = minutes }
    }

    public struct UnitInput: Equatable, Sendable {
        public var week: Int
        public var label: String
        public var topic: String
        public var files: [FileInput]
        public init(week: Int, label: String, topic: String, files: [FileInput]) { self.week = week; self.label = label; self.topic = topic; self.files = files }
    }

    public struct ModuleInput: Equatable, Sendable {
        public var id: Int64
        public var name: String
        public var priority: Int
        /// Klausurtermin (ISO-Datum), wenn bekannt
        public var examDate: String?
        public var units: [UnitInput]
        public init(id: Int64, name: String, priority: Int, examDate: String?, units: [UnitInput]) {
            self.id = id; self.name = name; self.priority = priority; self.examDate = examDate; self.units = units
        }
    }

    public struct DayInput: Equatable, Sendable {
        /// ISO-Datum
        public var date: String
        /// Lehrwoche dieses Tages (0 = keine, Ferien)
        public var week: Int
        /// freie Lernzeit laut Stundenplan, Sperrzeiten und schon geplanten Lernslots
        public var freeMinutes: Int
        /// schon geplante Lernpakete ("Modul · Titel · 60 min")
        public var planned: [String]
        public init(date: String, week: Int, freeMinutes: Int, planned: [String]) {
            self.date = date; self.week = week; self.freeMinutes = freeMinutes; self.planned = planned
        }
    }

    public struct Input: Equatable, Sendable {
        public var today: String
        public var minutesPerDay: Int
        public var subjectsPerDay: Int
        public var days: [DayInput]
        public var modules: [ModuleInput]
        public init(today: String, minutesPerDay: Int, subjectsPerDay: Int, days: [DayInput], modules: [ModuleInput]) {
            self.today = today; self.minutesPerDay = minutesPerDay; self.subjectsPerDay = subjectsPerDay; self.days = days; self.modules = modules
        }
    }

    // MARK: Grenzen

    /// hoechstens so viele Lehrwochen je Modul und Dateien je Woche gehen in den Prompt
    public static let unitsPerModule = 6
    public static let filesPerUnit = 8
    public static let maxBlocks = 40
    public static let blockMinutes = 15...240
    public static let taskMinutes = 10...180

    // MARK: Prompt

    /// Antwortform fuer die KI (JSON-Schema fuer `text.format`)
    public static let schema: JSONValue = [
        "type": "object",
        "properties": [
            "blocks": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "date": ["type": "string"], "module": ["type": "string"], "title": ["type": "string"],
                    "minutes": ["type": "integer"], "why": ["type": "string"],
                    "tasks": ["type": "array", "items": [
                        "type": "object",
                        "properties": ["type": ["type": "string"], "title": ["type": "string"], "file": ["type": ["string", "null"]],
                                       "minutes": ["type": "integer"]],
                        "required": ["type", "title", "minutes"], "additionalProperties": false]],
                ],
                "required": ["date", "module", "title", "minutes", "tasks"], "additionalProperties": false]],
        ],
        "required": ["blocks"], "additionalProperties": false,
    ]

    static let weekdayNames = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]

    /// Wochentag eines ISO-Datums (Montag = 0), nil bei unlesbarem Datum
    static func weekday(_ iso: String) -> Int? { BerlinClock.parseISODate(iso).map(BerlinClock.weekday) }

    /// Der Prompt: nur Titel, Wochen, Dateinamen, Arten, Dauern, Termine und Zeiten
    public static func prompt(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("Erstelle einen Lernplan fuer die folgenden Tage. Heute ist \(input.today).")
        lines.append("Gewuenschte Lernzeit: etwa \(input.minutesPerDay) Minuten je Lerntag, \(input.subjectsPerDay) Fach/Faecher je Tag.")
        lines.append("")
        lines.append("LERNTAGE (nur diese Daten sind erlaubt; freie Minuten nach Stundenplan; schon geplante Bloecke nicht noch einmal einplanen):")
        for d in input.days {
            var l = "- \(d.date)"
            if let w = weekday(d.date) { l += " (\(weekdayNames[w]))" }
            l += d.week >= 1 ? ", Lehrwoche \(d.week)" : ", vorlesungsfrei"
            l += ", frei: \(d.freeMinutes) min"
            if !d.planned.isEmpty { l += ", schon geplant: " + d.planned.joined(separator: "; ") }
            lines.append(l)
        }
        lines.append("")
        lines.append("MODULE mit offenem Stoff (Lehrwoche: Dateien als 'Name [Art, Minuten]'):")
        for m in input.modules {
            var head = "## \(m.name) (Prioritaet \(m.priority))"
            if let e = m.examDate, !e.isEmpty { head += ", Klausur am \(e)" }
            lines.append(head)
            for u in m.units.prefix(unitsPerModule) {
                var l = "- Lehrwoche \(u.week)"
                if !u.label.isEmpty { l += " (\(u.label))" }
                if !u.topic.isEmpty { l += ", Thema: \(u.topic)" }
                l += ": " + u.files.prefix(filesPerUnit).map { "\($0.name) [\($0.kind), \($0.minutes) min]" }.joined(separator: "; ")
                lines.append(l)
            }
        }
        lines.append("")
        lines.append("""
        REGELN:
        - Plane nur die genannten Tage und ueberschreite die freien Minuten eines Tages nicht; lass einen Tag aus, wenn er voll ist.
        - Erst den Stoff der aktuellen und der vergangenen Lehrwochen (Vorlesung vor Uebung), dann weiter; nahe Klausuren und hohe Prioritaet zuerst.
        - Je Block ein Modul mit 1-4 Aufgaben; 'module' exakt wie oben, 'file' exakt der Dateiname aus der Liste oder null (freie Aufgabe wie Wiederholung).
        - 'type' je Aufgabe: vorlesung, uebung, skript, wiederholung oder frei. 'title' kurz und konkret (Thema statt Dateiname), 'why' ein Satz.
        - Antworte nur mit JSON: {"blocks": [{"date", "module", "title", "minutes", "why", "tasks": [{"type", "title", "file", "minutes"}]}]}
        """)
        return lines.joined(separator: "\n")
    }

    // MARK: Vorschlag pruefen

    public struct Task: Equatable, Sendable {
        public var type: String
        public var title: String
        public var fileID: String?
        public var fileName: String?
        public var minutes: Int
        public init(type: String, title: String, fileID: String?, fileName: String?, minutes: Int) {
            self.type = type; self.title = title; self.fileID = fileID; self.fileName = fileName; self.minutes = minutes
        }
        public var json: JSONValue {
            ["type": .string(type), "title": .string(title), "file_id": fileID.map(JSONValue.string) ?? .null,
             "file": fileName.map(JSONValue.string) ?? .null, "minutes": .number(Double(minutes))]
        }
    }

    public struct Block: Equatable, Sendable {
        public var date: String
        public var moduleID: Int64
        public var module: String
        public var title: String
        public var week: Int?
        public var minutes: Int
        public var why: String
        public var tasks: [Task]
        public init(date: String, moduleID: Int64, module: String, title: String, week: Int?, minutes: Int, why: String, tasks: [Task]) {
            self.date = date; self.moduleID = moduleID; self.module = module; self.title = title; self.week = week
            self.minutes = minutes; self.why = why; self.tasks = tasks
        }
        public var json: JSONValue {
            ["date": .string(date), "module_id": .number(Double(moduleID)), "module": .string(module), "title": .string(title),
             "week": week.map { .number(Double($0)) } ?? .null, "minutes": .number(Double(minutes)), "why": .string(why),
             "tasks": .array(tasks.map(\.json))]
        }
    }

    static let taskTypes: Set<String> = ["vorlesung", "uebung", "skript", "wiederholung", "frei", "loesung", "test"]

    private static func key(_ s: String) -> String { PyText.strip(s).lowercased() }

    /// Antwort der KI gegen die Eingabe pruefen: nur erlaubte Tage, bekannte Module (Name exakt, Gross/Klein egal),
    /// Dateien nur aus dem Modul (sonst freie Aufgabe), Minuten in Grenzen, je Tag hoechstens das Anderthalbfache der
    /// Lernzeit, hoechstens `maxBlocks`. Bloecke ohne brauchbare Aufgabe bekommen eine freie Aufgabe mit dem Titel.
    public static func check(_ answer: JSONValue, input: Input) -> [Block] {
        guard let raw = answer["blocks"]?.array ?? answer.array else { return [] }
        let days = Dictionary(input.days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let modules = Dictionary(input.modules.map { (key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        var perDay: [String: Int] = [:]
        var out: [Block] = []
        for b in raw {
            guard out.count < maxBlocks, let date = b["date"]?.string.map(PyText.strip), let day = days[date],
                  let m = b["module"]?.string.flatMap({ modules[key($0)] }) else { continue }
            let files = Dictionary(m.units.flatMap(\.files).map { (key($0.name), $0) }, uniquingKeysWith: { a, _ in a })
            let filesByID = Dictionary(m.units.flatMap(\.files).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var tasks: [Task] = []
            for t in b["tasks"]?.array ?? [] {
                let title = PyText.strip(t["title"]?.string ?? "")
                guard !title.isEmpty else { continue }
                let typeRaw = key(t["type"]?.string ?? "frei")
                var type = taskTypes.contains(typeRaw) ? typeRaw : "frei"
                let fileRef = t["file"]?.string.map(PyText.strip) ?? ""
                let file = fileRef.isEmpty ? nil : (files[key(fileRef)] ?? filesByID[fileRef])
                if file == nil, ["vorlesung", "uebung", "skript", "loesung"].contains(type) { type = "frei" }
                if let f = file, type == "frei" { type = f.kind }
                let minutes = Swift.min(taskMinutes.upperBound, Swift.max(taskMinutes.lowerBound, Int(t["minutes"]?.double ?? Double(file?.minutes ?? 30))))
                tasks.append(Task(type: type, title: PyText.slice(title, 0, 120), fileID: file?.id, fileName: file?.name, minutes: minutes))
                if tasks.count >= 4 { break }
            }
            let title = PyText.slice(PyText.strip(b["title"]?.string ?? ""), 0, 120)
            if tasks.isEmpty {
                let minutes = Swift.min(blockMinutes.upperBound, Swift.max(blockMinutes.lowerBound, Int(b["minutes"]?.double ?? 45)))
                tasks = [Task(type: "frei", title: title.isEmpty ? "Lernen" : title, fileID: nil, fileName: nil, minutes: minutes)]
            }
            let total = tasks.reduce(0) { $0 + $1.minutes }
            guard blockMinutes.contains(total) || total > blockMinutes.upperBound else { continue }
            let cap = Swift.max(60, input.minutesPerDay) * 3 / 2
            guard perDay[date, default: 0] + total <= cap else { continue }
            perDay[date, default: 0] += total
            let week = m.units.first { u in tasks.contains { t in u.files.contains { $0.id == t.fileID } } }?.week
            out.append(Block(date: date, moduleID: m.id, module: m.name, title: title.isEmpty ? m.name : title, week: week ?? (day.week >= 1 ? day.week : nil),
                             minutes: total, why: PyText.slice(PyText.strip(b["why"]?.string ?? ""), 0, 200), tasks: tasks))
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Bloecke aus der Antwort von `ai-suggest` (vom Nutzer gewaehlt) fuer `ai-apply`; nur die Form, nicht die
    /// Datenbank (das prueft der Endpunkt). Unlesbare Bloecke fallen weg.
    public static func blocks(fromApply raw: JSONValue?) -> [Block] {
        var out: [Block] = []
        for b in raw?.array ?? [] {
            guard let date = b["date"]?.string, BerlinClock.parseISODate(date) != nil, let mid = b["module_id"]?.double else { continue }
            var tasks: [Task] = []
            for t in b["tasks"]?.array ?? [] {
                let title = PyText.strip(t["title"]?.string ?? "")
                guard !title.isEmpty else { continue }
                let type = key(t["type"]?.string ?? "frei")
                let minutes = Swift.min(taskMinutes.upperBound, Swift.max(taskMinutes.lowerBound, Int(t["minutes"]?.double ?? 30)))
                tasks.append(Task(type: taskTypes.contains(type) ? type : "frei", title: PyText.slice(title, 0, 120),
                                  fileID: t["file_id"]?.string, fileName: t["file"]?.string, minutes: minutes))
            }
            guard !tasks.isEmpty, tasks.count <= 4 else { continue }
            let title = PyText.slice(PyText.strip(b["title"]?.string ?? ""), 0, 120)
            out.append(Block(date: date, moduleID: Int64(mid), module: b["module"]?.string ?? "", title: title, week: b["week"]?.int,
                             minutes: tasks.reduce(0) { $0 + $1.minutes }, why: b["why"]?.string ?? "", tasks: tasks))
            if out.count >= maxBlocks { break }
        }
        return out
    }
}
