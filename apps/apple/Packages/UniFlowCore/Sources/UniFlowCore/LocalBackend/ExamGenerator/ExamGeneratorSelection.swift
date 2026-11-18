import Foundation

/// Klausur-Generator, Stufe (a): Auswahl der Unterlagen eines Moduls (Auftrag des Inhabers vom 17.11.2026).
///
/// Vorgabe im Wortlaut: bis zu 10 Probeklausuren je Auftrag; als Material hoechstens 300 Seiten Vorlesung oder Skript
/// (gemischt), dazu hoechstens 10 Altklausuren und hoechstens 10 Uebungs-PDFs, alles aus EINEM Modul. Die Regeln stehen
/// nur hier; die Ansicht (`ExamGeneratorPicker`) und spaeter der Dienst pruefen mit denselben Zahlen.
///
/// Drei Gruppen:
/// - `material`: Vorlesung, Skript und alles andere, das weder Klausur noch Uebung ist (zaehlt nach Seiten)
/// - `exams`: Altklausuren (zaehlen nach Dateien) und ihre Loesungen
/// - `exercises`: Uebungen (zaehlen nach Dateien) und ihre Loesungen
///
/// Loesungen zaehlen nicht als Klausur bzw. Uebung, sind aber je Gruppe genauso begrenzt (zu jeder Klausur ihre Loesung).
public enum ExamGeneratorSelection {
    public struct Limits: Sendable, Equatable {
        public var materialPages = 300
        public var examFiles = 10
        public var exerciseFiles = 10
        public var mockExams = 10
        public init() {}

        public var json: JSONValue {
            ["material_pages": .number(Double(materialPages)), "exam_files": .number(Double(examFiles)),
             "exercise_files": .number(Double(exerciseFiles)), "mock_exams": .number(Double(mockExams))]
        }
    }

    public static let limits = Limits()

    public enum Group: String, Sendable, CaseIterable {
        case material, exams, exercises
    }

    /// Eine PDF des Moduls in der Auswahl
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// "Vorlesung", "Altklausur", "Klausur-Lösung", ... (`StudyClassify.effectiveType`)
        public var label: String
        public var group: Group
        public var isSolution: Bool
        /// Seitenzahl; nil = Datei fehlt auf dem Geraet oder laesst sich nicht lesen (dann nicht waehlbar)
        public var pages: Int?
        public var chdate: Int64

        public init(id: String, title: String, label: String, group: Group, isSolution: Bool, pages: Int?, chdate: Int64 = 0) {
            self.id = id; self.title = title; self.label = label; self.group = group
            self.isSolution = isSolution; self.pages = pages; self.chdate = chdate
        }

        public var isAvailable: Bool { (pages ?? 0) > 0 }

        public var json: JSONValue {
            ["id": .string(id), "title": .string(title), "label": .string(label), "group": .string(group.rawValue),
             "solution": .bool(isSolution), "pages": pages.map { .number(Double($0)) } ?? .null,
             "available": .bool(isAvailable), "chdate": .number(Double(chdate))]
        }

        public init?(json: JSONValue) {
            guard let id = json["id"]?.string, let group = json["group"]?.string.flatMap(Group.init(rawValue:)) else { return nil }
            self.init(id: id, title: json["title"]?.string ?? id, label: json["label"]?.string ?? "", group: group,
                      isSolution: json["solution"]?.bool ?? false, pages: json["pages"]?.int, chdate: Int64(json["chdate"]?.int ?? 0))
        }
    }

    /// Gruppe einer Datei aus ihrer Art (`doc_type`) und Bezeichnung (`sub_label`)
    public static func group(docType: String, label: String) -> (group: Group, isSolution: Bool) {
        switch docType {
        case "klausur": return (.exams, false)
        case "uebung": return (.exercises, false)
        case "loesung": return (label == "Klausur-Lösung" ? .exams : .exercises, true)
        default: return (.material, false)
        }
    }

    // MARK: Pruefen

    /// Stand einer Auswahl: Zaehler je Gruppe und was gegen den Start spricht
    public struct Check: Sendable, Equatable {
        public var materialPages = 0
        public var materialFiles = 0
        public var examFiles = 0
        public var examSolutions = 0
        public var exerciseFiles = 0
        public var exerciseSolutions = 0
        /// alle Seiten der Auswahl (fuer den Kostenvoranschlag)
        public var totalPages = 0
        /// Saetze fuer den Nutzer; leer = die Auswahl darf starten
        public var problems: [String] = []
        /// Hinweis, der den Start nicht sperrt
        public var hint: String?

        public init() {}

        public var isValid: Bool { problems.isEmpty }
    }

    public static let textNothing = "Wähle mindestens eine Vorlesung, ein Skript oder eine Übung aus."
    public static let hintNoExam = "Ohne Altklausur kennt die KI das Format deiner Klausur nicht. Das Ergebnis wird dann ungenauer."

    /// Prueft die gewaehlten Dateien gegen die Grenzen. Nicht waehlbare und unbekannte Kennungen zaehlen nicht.
    public static func check(_ items: [Item], selected: Set<String>, mockExams: Int = 1, limits: Limits = limits) -> Check {
        var c = Check()
        for it in items where selected.contains(it.id) && it.isAvailable {
            let pages = it.pages ?? 0
            c.totalPages += pages
            switch (it.group, it.isSolution) {
            case (.material, _): c.materialPages += pages; c.materialFiles += 1
            case (.exams, false): c.examFiles += 1
            case (.exams, true): c.examSolutions += 1
            case (.exercises, false): c.exerciseFiles += 1
            case (.exercises, true): c.exerciseSolutions += 1
            }
        }
        if c.materialFiles == 0 && c.exerciseFiles == 0 { c.problems.append(textNothing) }
        if c.materialPages > limits.materialPages {
            c.problems.append("Zu viele Seiten: höchstens \(limits.materialPages) Seiten Vorlesung und Skript (gewählt: \(c.materialPages)).")
        }
        if c.examFiles > limits.examFiles { c.problems.append("Höchstens \(limits.examFiles) Altklausuren (gewählt: \(c.examFiles)).") }
        if c.examSolutions > limits.examFiles {
            c.problems.append("Höchstens \(limits.examFiles) Lösungen zu Altklausuren (gewählt: \(c.examSolutions)).")
        }
        if c.exerciseFiles > limits.exerciseFiles { c.problems.append("Höchstens \(limits.exerciseFiles) Übungen (gewählt: \(c.exerciseFiles)).") }
        if c.exerciseSolutions > limits.exerciseFiles {
            c.problems.append("Höchstens \(limits.exerciseFiles) Lösungen zu Übungen (gewählt: \(c.exerciseSolutions)).")
        }
        if !(1...limits.mockExams).contains(mockExams) {
            c.problems.append("Wähle 1 bis \(limits.mockExams) Probeklausuren.")
        }
        if c.examFiles == 0, c.problems.isEmpty { c.hint = hintNoExam }
        return c
    }

    // MARK: "Alles auswählen"

    /// Vorschlag fuer "Alles auswählen": so viel wie in die Grenzen passt. Klausuren und Uebungen: die neuesten zuerst.
    /// Material: zuerst Vorlesung und Skript in der Reihenfolge des Semesters, danach der Rest; eine Datei, die nicht
    /// mehr in die Seiten passt, wird uebersprungen (eine kleinere dahinter kann noch passen).
    public static func all(_ items: [Item], limits: Limits = limits) -> Set<String> {
        var out = Set<String>()
        let usable = items.filter(\.isAvailable)
        func newest(_ group: Group, solution: Bool, max: Int) {
            let list = usable.filter { $0.group == group && $0.isSolution == solution }.sorted { ($0.chdate, $0.id) > ($1.chdate, $1.id) }
            for it in list.prefix(max) { out.insert(it.id) }
        }
        newest(.exams, solution: false, max: limits.examFiles)
        newest(.exams, solution: true, max: limits.examFiles)
        newest(.exercises, solution: false, max: limits.exerciseFiles)
        newest(.exercises, solution: true, max: limits.exerciseFiles)
        let core: Set<String> = ["Vorlesung", "Skript", "Mitschrift"]
        let material = usable.filter { $0.group == .material }
        let ordered = material.filter { core.contains($0.label) }.sorted { ($0.chdate, $0.id) < ($1.chdate, $1.id) }
            + material.filter { !core.contains($0.label) }.sorted { ($0.chdate, $0.id) < ($1.chdate, $1.id) }
        var pages = 0
        for it in ordered {
            let p = it.pages ?? 0
            if pages + p <= limits.materialPages { pages += p; out.insert(it.id) }
        }
        return out
    }

    // MARK: Dateien eines Moduls

    /// Zeile aus der Datenbank, noch ohne Seitenzahl aus der Datei
    struct Row: Sendable {
        var item: Item
        var localPath: String?
    }

    static let rowsSQL = """
        SELECT f.id, f.name, f.title, f.chdate, f.local_path, f.page_count, f.studip_folder,
               c.kind AS course_kind, a.doc_type,
               (SELECT o.page_count FROM file_outline o WHERE o.file_id=f.id AND o.chdate IS f.chdate) AS outline_pages
        FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
        WHERE c.active=1 AND c.module_id=? AND f.deleted_at IS NULL
        ORDER BY f.chdate, f.id
        """

    /// PDFs der aktiven Kurse des Moduls mit Gruppe; Seitenzahl aus der Datenbank, soweit sie dort steht
    static func rows(_ c: SQLiteConnection, moduleID: Int64) throws -> [Row] {
        let stored = try LectureWeeks.stored(c)
        return try c.query(rowsSQL, [.integer(moduleID)]).compactMap { r in
            guard let id = r["id"]?.string, let name = r["name"]?.string, PyText.lower(name).hasSuffix(".pdf") else { return nil }
            let f = LectureWeeks.withStoredType(StudyClassify.enrichFile(r.json), stored: stored)
            let label = f["sub_label"]?.string ?? "Sonstiges"
            let g = group(docType: f["doc_type"]?.string ?? "sonstiges", label: label)
            let title = r["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? name
            let known = [r["page_count"]?.int, r["outline_pages"]?.int].compactMap { $0 }.first { $0 > 0 }
            return Row(item: Item(id: id, title: title, label: label, group: g.group, isSolution: g.isSolution, pages: known,
                                  chdate: r["chdate"]?.int64 ?? 0),
                       localPath: r["local_path"]?.string)
        }
    }

    /// Seitenzahl aus der Datei, wo die Datenbank keine kennt; ohne Datei auf dem Geraet bleibt sie nil
    static func withPages(_ rows: [Row], files: LocalFiles?) -> [Item] {
        rows.map { row in
            var it = row.item
            guard let files, let url = row.localPath.flatMap({ files.url(stored: $0) }), files.exists(stored: row.localPath) else {
                it.pages = nil                                            // nicht geladen: auch eine gemerkte Zahl hilft nicht
                return it
            }
            if it.pages == nil, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                it.pages = files.tools.pdfPageCount(data).flatMap { $0 > 0 ? $0 : nil }
            }
            return it
        }
    }
}

/// - `GET /api/modules/{id}/exam-generator/files` -> {limits, files: [{id, title, label, group, solution, pages, available}]}
///
/// Nur auf dem Geraet (liest die Seitenzahl aus den PDFs). Der Auftrag selbst laeuft spaeter im Dienst.
public enum ExamGeneratorEndpoints: LocalEndpointModule {
    public static let name = "Klausur-Generator"

    public static func register(on router: LocalRouter) {
        router.get("/api/modules/{module_id:int}/exam-generator/files") { req, ctx in
            let m = Int64(req.intParam("module_id"))
            let rows = try await ctx.database.withConnection { c -> [ExamGeneratorSelection.Row] in
                guard try c.queryOne("SELECT 1 FROM modules WHERE id=?", [.integer(m)]) != nil else { throw LocalHTTPError.notFound("Modul nicht gefunden") }
                return try ExamGeneratorSelection.rows(c, moduleID: m)
            }
            let items = ExamGeneratorSelection.withPages(rows, files: ctx.files)
            return .json(["limits": ExamGeneratorSelection.limits.json, "files": .array(items.map(\.json))])
        }
        registerShop(on: router)
    }
}
