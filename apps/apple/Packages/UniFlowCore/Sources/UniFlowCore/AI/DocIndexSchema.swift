import Foundation

// Gemeinsamer Dokument-Index ("Bibliothek", docs/DOKUMENT-INDEX-2026-11-04.md): Schema der Eintraege, byte-gleich mit
// packages/shared-contracts/doc-index.schema.json und app/doc_index.py (DocIndexTests und tests/test_doc_index.py
// pruefen den Text). Dazu der Pruefer fuer die genutzte Teilmenge von JSON Schema und die Modelle der Eintraege.

/// Die Form eines Eintrags je Seite (Antwort der KI und Inhalt des verschluesselten Datensatzes), Version 1.
public enum DocIndexSchema {
    public static let version = 1

    /// Der Vertragstext (mit dem abschliessenden Zeilenwechsel der Datei)
    public static let json = #"""
{
  "$schema": "https://json-schema.org/draft/2019-09/schema",
  "$id": "https://studinow.app/contracts/doc-index/v1/doc-index.schema.json",
  "title": "StudiNow Dokument-Index (Bibliothek), Eintrag einer Seite",
  "description": "Eine Quelle fuer Geraet (Swift-Kern, DocIndexSchema) und Dienst (app/doc_index.py): Form der KI-Antwort je Seite und des verschluesselten Datensatzes. Unter $defs.summary die Zusammenfassung je Datei (Seite 0) mit den Katalogangaben des Regals ($defs.catalog). Aenderungen nur mit neuer version; DocIndexTests (Swift) und tests/test_doc_index.py (Python) pruefen, dass beide Seiten genau diesen Text eingebettet haben.",
  "version": 1,
  "type": "object",
  "additionalProperties": false,
  "required": ["summary", "terms", "elements", "tasks"],
  "properties": {
    "summary": {"type": "string", "maxLength": 500},
    "terms": {"type": "array", "maxItems": 12, "items": {"type": "string", "maxLength": 80}},
    "elements": {
      "type": "array",
      "maxItems": 40,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["order", "type", "title", "explanation", "position", "uncertain"],
        "properties": {
          "order": {"type": "integer", "minimum": 1},
          "type": {"type": "string", "enum": ["skizze", "diagramm", "tabelle", "formel", "definition", "satz", "beispiel", "aufgabe", "text"]},
          "title": {"type": "string", "maxLength": 120},
          "explanation": {"type": "string", "maxLength": 600},
          "position": {"type": "string", "enum": ["oben", "mitte", "unten", "links", "rechts", "ganz"]},
          "task": {"type": ["string", "null"], "maxLength": 40},
          "uncertain": {"type": "boolean"}
        }
      }
    },
    "tasks": {
      "type": "array",
      "maxItems": 20,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["label", "asks"],
        "properties": {
          "label": {"type": "string", "maxLength": 40},
          "asks": {"type": "string", "maxLength": 400},
          "solution": {"type": ["string", "null"], "maxLength": 4000}
        }
      }
    }
  },
  "$defs": {
    "catalog": {
      "type": "object",
      "additionalProperties": false,
      "required": ["university", "studyProgram", "semester", "moduleKey", "moduleName", "week", "date", "kind", "kindLabel"],
      "properties": {
        "university": {"type": "string", "maxLength": 40},
        "studyProgram": {"type": "string", "maxLength": 120},
        "semester": {"type": "string", "maxLength": 40},
        "moduleKey": {"type": "string", "maxLength": 64},
        "moduleName": {"type": "string", "maxLength": 200},
        "week": {"type": "integer", "minimum": -2},
        "date": {"type": "string", "maxLength": 10},
        "kind": {"type": "string", "enum": ["vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium", "klausur", "altklausur", "skript", "loesung", "sonstiges"]},
        "kindLabel": {"type": "string", "maxLength": 40}
      }
    },
    "summary": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "fileName", "pageCount", "pageHashes", "catalog", "createdAt"],
      "properties": {
        "v": {"type": "integer", "const": 1},
        "fileName": {"type": "string", "maxLength": 300},
        "title": {"type": ["string", "null"], "maxLength": 300},
        "pageCount": {"type": "integer", "minimum": 0},
        "pageHashes": {"type": "array", "items": {"type": "string", "maxLength": 64}},
        "overview": {"type": ["string", "null"], "maxLength": 500},
        "catalog": {
          "type": "object",
          "additionalProperties": false,
          "required": ["university", "studyProgram", "semester", "moduleKey", "moduleName", "week", "date", "kind", "kindLabel"],
          "properties": {
            "university": {"type": "string", "maxLength": 40},
            "studyProgram": {"type": "string", "maxLength": 120},
            "semester": {"type": "string", "maxLength": 40},
            "moduleKey": {"type": "string", "maxLength": 64},
            "moduleName": {"type": "string", "maxLength": 200},
            "week": {"type": "integer", "minimum": -2},
            "date": {"type": "string", "maxLength": 10},
            "kind": {"type": "string", "enum": ["vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium", "klausur", "altklausur", "skript", "loesung", "sonstiges"]},
            "kindLabel": {"type": "string", "maxLength": 40}
          }
        },
        "createdAt": {"type": "string", "maxLength": 32}
      }
    },
    "pageRecord": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "page", "pageHash", "entry", "createdAt"],
      "properties": {
        "v": {"type": "integer", "const": 1},
        "page": {"type": "integer", "minimum": 1},
        "pageHash": {"type": "string", "maxLength": 64},
        "entry": {"type": "object"},
        "withImage": {"type": "boolean"},
        "model": {"type": ["string", "null"], "maxLength": 100},
        "createdAt": {"type": "string", "maxLength": 32}
      }
    }
  }
}

"""#

    public static let schema: JSONValue = (try? JSONValue.parse(Data(json.utf8))) ?? .null
    /// `$defs.summary`: Zusammenfassung je Datei (Seite 0)
    public static var summarySchema: JSONValue { schema["$defs"]?["summary"] ?? .null }
    /// `$defs.catalog`: Katalogangaben des Regals
    public static var catalogSchema: JSONValue { schema["$defs"]?["catalog"] ?? .null }
    /// `$defs.pageRecord`: verschluesselter Datensatz einer Seite
    public static var pageRecordSchema: JSONValue { schema["$defs"]?["pageRecord"] ?? .null }

    /// Das Schema fuer die Responses API (`text.format`): ohne `$defs`, `$schema`, `$id`, `title`, `description`, `version`
    public static var aiSchema: JSONValue {
        var o = schema.object ?? [:]
        for k in ["$defs", "$schema", "$id", "title", "description", "version"] { o.removeValue(forKey: k) }
        return .object(o)
    }

    public static let elementTypes = ["skizze", "diagramm", "tabelle", "formel", "definition", "satz", "beispiel", "aufgabe", "text"]
    public static let positions = ["oben", "mitte", "unten", "links", "rechts", "ganz"]
}

/// Pruefer fuer die Teilmenge von JSON Schema, die der Dokument-Index nutzt (dieselben Regeln und Meldungen wie
/// `validate` in app/doc_index.py): type (auch Liste), required, properties, additionalProperties, items, enum, const,
/// minimum, maxLength (Codepunkte wie `len()` in Python), maxItems.
public enum JSONSchemaLite {
    public static func validate(_ value: JSONValue, schema: JSONValue, path: String = "$") -> [String] {
        var errors: [String] = []
        if let types = schema["type"] {
            let allowed = types.array?.compactMap(\.string) ?? types.string.map { [$0] } ?? []
            if !allowed.isEmpty, !allowed.contains(where: { matches(value, $0) }) {
                return ["\(path): Typ \(typeName(value)), erwartet \(allowed.joined(separator: "/"))"]
            }
        }
        if let e = schema["enum"]?.array, !e.contains(value) { errors.append("\(path): \(repr(value)) nicht erlaubt") }
        if let c = schema["const"], c != value { errors.append("\(path): \(repr(value)) statt \(repr(c))") }
        if let n = value.double, let min = schema["minimum"]?.double, n < min { errors.append("\(path): \(repr(value)) unter \(repr(.number(min)))") }
        if let s = value.string, let max = schema["maxLength"]?.int, s.unicodeScalars.count > max {
            errors.append("\(path): \(s.unicodeScalars.count) Zeichen, hoechstens \(max)")
        }
        if let a = value.array {
            if let max = schema["maxItems"]?.int, a.count > max { errors.append("\(path): \(a.count) Eintraege, hoechstens \(max)") }
            if let items = schema["items"] {
                for (i, item) in a.enumerated() { errors += validate(item, schema: items, path: "\(path)[\(i)]") }
            }
        }
        if let o = value.object {
            let props = schema["properties"]?.object ?? [:]
            for key in schema["required"]?.array?.compactMap(\.string) ?? [] where o[key] == nil { errors.append("\(path).\(key): fehlt") }
            // Reihenfolge wie app/doc_index.py: erst die Pflichtfelder in ihrer Reihenfolge, dann die uebrigen nach Name
            let required = schema["required"]?.array?.compactMap(\.string) ?? []
            let order = required.filter { props[$0] != nil } + props.keys.filter { !required.contains($0) }.sorted()
            for key in order {
                if let sub = props[key], let v = o[key] { errors += validate(v, schema: sub, path: "\(path).\(key)") }
            }
            if schema["additionalProperties"] == .bool(false) {
                for key in o.keys.sorted() where props[key] == nil { errors.append("\(path).\(key): unbekanntes Feld") }
            }
        }
        return errors
    }

    static func matches(_ v: JSONValue, _ type: String) -> Bool {
        switch type {
        case "object": return v.object != nil
        case "array": return v.array != nil
        case "string": return v.string != nil
        case "boolean": return v.bool != nil
        case "null": return v.isNull
        case "number": return v.double != nil
        case "integer": return v.double.map { $0.isFinite && $0 == $0.rounded() } ?? false
        default: return false
        }
    }

    /// Typname wie Python (`type(value).__name__`)
    static func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "NoneType"
        case .bool: return "bool"
        case .number(let d): return d.isFinite && d == d.rounded() ? "int" : "float"
        case .string: return "str"
        case .array: return "list"
        case .object: return "dict"
        }
    }

    /// `repr(value)` wie Python fuer die Meldungen (Texte in einfachen Anfuehrungszeichen, Zahlen ohne ".0")
    static func repr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .number(let d): return d.isFinite && d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): return "'" + s.replacingOccurrences(of: "'", with: "\\'") + "'"
        default: return v.jsonString(sortedKeys: true)
        }
    }
}

/// Ein Element einer Seite (Skizze, Formel, Aufgabe ...), in Lesereihenfolge
public struct DocIndexElement: Equatable, Sendable {
    public var order: Int
    public var type: String
    public var title: String
    public var explanation: String
    public var position: String
    /// Aufgabe, zu der das Element gehoert ("Aufgabe 3b"), sonst nil
    public var task: String?
    public var uncertain: Bool

    public init(order: Int, type: String, title: String, explanation: String, position: String = "ganz", task: String? = nil, uncertain: Bool = false) {
        self.order = order; self.type = type; self.title = title; self.explanation = explanation
        self.position = position; self.task = task; self.uncertain = uncertain
    }

    public var json: JSONValue {
        ["order": .number(Double(order)), "type": .string(type), "title": .string(title), "explanation": .string(explanation),
         "position": .string(position), "task": task.map(JSONValue.string) ?? .null, "uncertain": .bool(uncertain)]
    }

    /// Anzeigename der Art ("Skizze", "Formel" ...)
    public var typeLabel: String { DocIndexElement.typeLabels[type] ?? type }

    public static let typeLabels = ["skizze": "Skizze", "diagramm": "Diagramm", "tabelle": "Tabelle", "formel": "Formel", "definition": "Definition",
                                    "satz": "Satz", "beispiel": "Beispiel", "aufgabe": "Aufgabe", "text": "Text"]
}

/// Eine Aufgabe auf der Seite: was verlangt ist; die Loesung nur auf ausdruecklichen Wunsch
public struct DocIndexTask: Equatable, Sendable {
    public var label: String
    public var asks: String
    public var solution: String?

    public init(label: String, asks: String, solution: String? = nil) { self.label = label; self.asks = asks; self.solution = solution }

    public var json: JSONValue {
        ["label": .string(label), "asks": .string(asks), "solution": solution.map(JSONValue.string) ?? .null]
    }
}

/// Der Eintrag einer Seite (die Antwort der KI, geprueft und in fester Ordnung)
public struct DocIndexEntry: Equatable, Sendable {
    public var summary: String
    public var terms: [String]
    public var elements: [DocIndexElement]
    public var tasks: [DocIndexTask]

    public init(summary: String, terms: [String] = [], elements: [DocIndexElement] = [], tasks: [DocIndexTask] = []) {
        self.summary = summary; self.terms = terms; self.elements = elements; self.tasks = tasks
    }

    public var json: JSONValue {
        ["summary": .string(summary), "terms": .array(terms.map(JSONValue.string)),
         "elements": .array(elements.map(\.json)), "tasks": .array(tasks.map(\.json))]
    }

    /// `check_entry`: Schema, dazu `order` 1..n lueckenlos und eindeutige Aufgaben; leer = in Ordnung
    public static func check(_ json: JSONValue) -> [String] {
        var errors = JSONSchemaLite.validate(json, schema: DocIndexSchema.schema)
        if !errors.isEmpty { return errors }
        let orders = (json["elements"]?.array ?? []).compactMap { $0["order"]?.int }.sorted()
        if orders != Array(0..<orders.count).map({ $0 + 1 }) { errors.append("$.elements: order muss 1..n ohne Luecken sein") }
        let labels = (json["tasks"]?.array ?? []).compactMap { $0["label"]?.string }
        if Set(labels).count != labels.count { errors.append("$.tasks: Aufgaben doppelt") }
        return errors
    }

    /// `normalized_entry`: geprueften Eintrag in fester Ordnung uebernehmen (Elemente nach order, Aufgaben nach label,
    /// Begriffe ohne Doppelte in der Reihenfolge der Antwort, Texte aussen ohne Leerraum); nil, wenn `check` Fehler nennt
    public init?(validating json: JSONValue) {
        guard DocIndexEntry.check(json).isEmpty else { return nil }
        summary = PyText.strip(json["summary"]?.string ?? "")
        var seen = Set<String>()
        terms = (json["terms"]?.array ?? []).compactMap { t -> String? in
            let s = PyText.strip(t.string ?? "")
            guard !s.isEmpty, seen.insert(PyText.lower(s)).inserted else { return nil }
            return s
        }
        elements = (json["elements"]?.array ?? []).compactMap { e -> DocIndexElement? in
            guard let order = e["order"]?.int, let type = e["type"]?.string, let pos = e["position"]?.string else { return nil }
            let task = e["task"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return DocIndexElement(order: order, type: type, title: PyText.strip(e["title"]?.string ?? ""),
                                   explanation: PyText.strip(e["explanation"]?.string ?? ""), position: pos, task: task,
                                   uncertain: e["uncertain"]?.bool ?? false)
        }.sorted { $0.order < $1.order }
        tasks = (json["tasks"]?.array ?? []).compactMap { t -> DocIndexTask? in
            guard let label = t["label"]?.string else { return nil }
            let solution = t["solution"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return DocIndexTask(label: PyText.strip(label), asks: PyText.strip(t["asks"]?.string ?? ""), solution: solution)
        }.sorted { $0.label < $1.label }
    }

    /// Antwort der KI (Text) -> Eintrag; wirft `AIError` mit den Fehlern des Pruefers (`ai_invalid_index`)
    public static func parse(answer: String) throws -> DocIndexEntry {
        let json = try AIAnswers.parseJSON(answer).json
        let errors = check(json)
        guard errors.isEmpty, let entry = DocIndexEntry(validating: json) else {
            throw AIError("ai_invalid_index", "Die Antwort passt nicht zum Index-Schema: " + errors.prefix(5).joined(separator: "; "))
        }
        return entry
    }
}

/// Katalogangaben des Regals (`$defs.catalog`): nur, was sich aus den Kursdaten ableiten laesst, nie Namen von Personen
public struct DocIndexCatalog: Equatable, Sendable {
    public var university: String
    public var studyProgram: String
    public var semester: String
    public var moduleKey: String
    public var moduleName: String
    public var week: Int
    /// Datum der Datei (YYYY-MM-DD, Berliner Ortszeit der Aenderung)
    public var date: String
    public var kind: String
    public var kindLabel: String

    public static let generalProgram = "Allgemein"

    public init(university: String, studyProgram: String = DocIndexCatalog.generalProgram, semester: String, moduleKey: String, moduleName: String,
                week: Int, date: String, kind: String, kindLabel: String) {
        self.university = university; self.studyProgram = studyProgram; self.semester = semester; self.moduleKey = moduleKey
        self.moduleName = moduleName; self.week = week; self.date = date; self.kind = kind; self.kindLabel = kindLabel
    }

    public var json: JSONValue {
        ["university": .string(university), "studyProgram": .string(studyProgram), "semester": .string(semester), "moduleKey": .string(moduleKey),
         "moduleName": .string(moduleName), "week": .number(Double(week)), "date": .string(date), "kind": .string(kind), "kindLabel": .string(kindLabel)]
    }

    public init?(json: JSONValue) {
        guard JSONSchemaLite.validate(json, schema: DocIndexSchema.catalogSchema).isEmpty,
              let u = json["university"]?.string, let p = json["studyProgram"]?.string, let s = json["semester"]?.string,
              let mk = json["moduleKey"]?.string, let mn = json["moduleName"]?.string, let w = json["week"]?.int, let d = json["date"]?.string,
              let k = json["kind"]?.string, let kl = json["kindLabel"]?.string else { return nil }
        self.init(university: u, studyProgram: p, semester: s, moduleKey: mk, moduleName: mn, week: w, date: d, kind: k, kindLabel: kl)
    }

    /// Art im Regal aus der Einordnung der Bibliothek (`StudyClassify.effectiveType`: doc_type und sub_label), dieselbe
    /// Tabelle wie `catalog_kind` in app/doc_index.py
    public static func kind(docType: String?, subLabel: String?) -> (kind: String, label: String) {
        let t = docType ?? "", l = subLabel ?? ""
        let kind: String
        switch t {
        case "klausur": kind = l == "Altklausur" ? "altklausur" : "klausur"
        case "uebung": kind = ["Hörsaalübung": "hoersaaluebung", "Gruppenübung": "gruppenuebung", "Tutorium": "tutorium"][l] ?? "uebung"
        case "vorlesung", "skript", "loesung": kind = t
        default: kind = "sonstiges"
        }
        return (kind, kindLabels[kind] ?? kind)
    }

    /// Reihenfolge der Arten im Regal (wie `KIND_ORDER`)
    public static let kindOrder = ["vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium", "klausur", "altklausur", "skript", "loesung", "sonstiges"]
    public static let kindLabels = ["vorlesung": "Vorlesung", "uebung": "Übung", "hoersaaluebung": "Hörsaalübung", "gruppenuebung": "Gruppenübung",
                                    "tutorium": "Tutorium", "klausur": "Klausur", "altklausur": "Altklausur", "skript": "Skript", "loesung": "Lösung",
                                    "sonstiges": "Sonstiges"]
}

/// Zusammenfassung je Datei (Datensatz Seite 0, `$defs.summary`): Name, Seitenzahl, Seiten-Abdruecke, Katalog
public struct DocIndexFileSummary: Equatable, Sendable {
    public var fileName: String
    public var title: String?
    public var pageCount: Int
    public var pageHashes: [String]
    public var overview: String?
    public var catalog: DocIndexCatalog
    public var createdAt: String

    public init(fileName: String, title: String? = nil, pageCount: Int, pageHashes: [String], overview: String? = nil,
                catalog: DocIndexCatalog, createdAt: String) {
        self.fileName = fileName; self.title = title; self.pageCount = pageCount; self.pageHashes = pageHashes
        self.overview = overview; self.catalog = catalog; self.createdAt = createdAt
    }

    public var json: JSONValue {
        ["v": .number(Double(DocIndexSchema.version)), "fileName": .string(fileName), "title": title.map(JSONValue.string) ?? .null,
         "pageCount": .number(Double(pageCount)), "pageHashes": .array(pageHashes.map(JSONValue.string)),
         "overview": overview.map(JSONValue.string) ?? .null, "catalog": catalog.json, "createdAt": .string(createdAt)]
    }

    public init?(json: JSONValue) {
        guard JSONSchemaLite.validate(json, schema: DocIndexSchema.summarySchema).isEmpty, let name = json["fileName"]?.string,
              let count = json["pageCount"]?.int, let hashes = json["pageHashes"]?.array?.compactMap(\.string),
              let catalog = json["catalog"].flatMap(DocIndexCatalog.init(json:)), let created = json["createdAt"]?.string else { return nil }
        self.init(fileName: name, title: json["title"]?.string, pageCount: count, pageHashes: hashes, overview: json["overview"]?.string,
                  catalog: catalog, createdAt: created)
    }
}

/// Inhalt des verschluesselten Datensatzes einer Seite (`$defs.pageRecord`)
public struct DocIndexPageRecord: Equatable, Sendable {
    public var page: Int
    public var pageHash: String
    public var entry: DocIndexEntry
    public var withImage: Bool
    public var model: String?
    public var createdAt: String

    public init(page: Int, pageHash: String, entry: DocIndexEntry, withImage: Bool = false, model: String? = nil, createdAt: String) {
        self.page = page; self.pageHash = pageHash; self.entry = entry; self.withImage = withImage; self.model = model; self.createdAt = createdAt
    }

    public var json: JSONValue {
        ["v": .number(Double(DocIndexSchema.version)), "page": .number(Double(page)), "pageHash": .string(pageHash), "entry": entry.json,
         "withImage": .bool(withImage), "model": model.map(JSONValue.string) ?? .null, "createdAt": .string(createdAt)]
    }

    public init?(json: JSONValue) {
        guard JSONSchemaLite.validate(json, schema: DocIndexSchema.pageRecordSchema).isEmpty, let page = json["page"]?.int,
              let hash = json["pageHash"]?.string, let entry = json["entry"].flatMap(DocIndexEntry.init(validating:)),
              let created = json["createdAt"]?.string else { return nil }
        self.init(page: page, pageHash: hash, entry: entry, withImage: json["withImage"]?.bool ?? false, model: json["model"]?.string, createdAt: created)
    }
}
