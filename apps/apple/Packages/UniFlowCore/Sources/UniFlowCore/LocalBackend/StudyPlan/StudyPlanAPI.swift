import Foundation

/// Antworten der Studienverlauf-Endpunkte wie app/study_plan.py (`plan_response`, `module_response`,
/// `settings_response`, `save_settings`): Einstellungen je Container in `settings.study_plan`
/// (`{"po", "start_term", "electives"}` als `json.dumps`), QIS-Zeilen bereinigt wie `grades_model.model`.
/// Gegen Python geprueft mit fixtures/study-plan-engine/endpoints.json.
public enum StudyPlanAPI {
    /// Gespeicherte Einstellungen (`load_settings`): po nur nicht leer, start_term nur lesbar, electives sortiert
    struct Settings {
        var po: String?
        var startTerm: String?
        var electives: [String]
        /// eigener Link zum Modulhandbuch (nur https, StudyCatalogPipeline.cleanCatalogURL); nur gespeichert, wenn gesetzt
        var catalogURL: String? = nil

        var json: [String: JSONValue] {
            var o: [String: JSONValue] = ["po": StudyPlanEngine.opt(po), "start_term": StudyPlanEngine.opt(startTerm),
                                          "electives": .array(electives.map(JSONValue.string))]
            if let catalogURL { o["catalog_url"] = .string(catalogURL) }
            return o
        }

        var stored: PyJSON {
            var m = [PyJSON.Member("po", po.map(PyJSON.string) ?? .null),
                     PyJSON.Member("start_term", startTerm.map(PyJSON.string) ?? .null),
                     PyJSON.Member("electives", .array(electives.map(PyJSON.string)))]
            if let catalogURL { m.append(PyJSON.Member("catalog_url", .string(catalogURL))) }
            return .object(m)
        }
    }

    static func sortedUnique(_ items: [String]) -> [String] {
        var out: [String] = []
        for e in items where !e.isEmpty && !out.contains(where: { $0.unicodeScalars.elementsEqual(e.unicodeScalars) }) { out.append(e) }
        return out.sorted(by: PyText.less)
    }

    static func loadSettings(_ c: SQLiteConnection) throws -> Settings {
        var v: [String: JSONValue] = [:]
        if let raw = try c.queryOne("SELECT value FROM settings WHERE key=?", [.text(StudyPlanEngine.settingsKey)])?[0].string,
           !raw.isEmpty, let parsed = try? JSONValue.parse(Data(raw.utf8)), let o = parsed.object {
            v = o
        }
        let po = v["po"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let start = v["start_term"]?.string.flatMap { StudyPlanEngine.parseTerm($0) == nil ? nil : $0 }
        return Settings(po: po, startTerm: start, electives: sortedUnique(v["electives"]?.array?.compactMap(\.string) ?? []),
                        catalogURL: StudyCatalogPipeline.cleanCatalogURL(v["catalog_url"]?.string))
    }

    static func gradeRows(_ c: SQLiteConnection) throws -> [[String: JSONValue]] {
        GradesModel.model(try c.rows("SELECT * FROM grades ORDER BY id"))
    }

    /// `GET /api/study-plan`
    public static func plan(_ c: SQLiteConnection, today: String, source: StudyCatalogSource? = nil) throws -> JSONValue {
        let source = source ?? DatabaseStudyCatalogSource(c)
        let settings = try loadSettings(c), grades = try gradeRows(c)
        let catalogs = try source.catalogs()
        let picked = StudyPlanEngine.pickCatalog(catalogs, settings: settings.json, grades: grades)
        var out: [String: JSONValue]
        if let cat = picked.catalog {
            out = StudyPlanEngine.compute(catalog: cat, grades: grades, settings: settings.json, today: today).plan
        } else {
            out = StudyPlanEngine.unavailable(picked.reason ?? "no_catalog", po: settings.po)
        }
        let suggested = StudyPlanEngine.pickCatalog(catalogs, settings: [:], grades: grades).catalog
        out["suggested_po"] = suggested.map { $0["po"] ?? .null } ?? .null
        out["po_confirmed"] = .bool(settings.po != nil)
        out["qis_program"] = StudyPlanEngine.opt(StudyPlanEngine.abschlussOf(grades))
        return .object(out)
    }

    /// `GET /api/study-plan/module/{id}`: Fakten, lokaler Text, eigener Stand, Kurse und Dateien der App; 404 ohne
    /// Katalog oder Modul
    public static func module(_ c: SQLiteConnection, id moduleID: String, today: String, source: StudyCatalogSource? = nil) throws -> JSONValue {
        let source = source ?? DatabaseStudyCatalogSource(c)
        let settings = try loadSettings(c), grades = try gradeRows(c)
        guard let cat = StudyPlanEngine.pickCatalog(try source.catalogs(), settings: settings.json, grades: grades).catalog else {
            throw LocalHTTPError(status: 404, message: "Kein Katalog")
        }
        let full = StudyPlanEngine.compute(catalog: cat, grades: grades, settings: settings.json, today: today)
        guard let m = full.byID[moduleID] else { throw LocalHTTPError(status: 404, message: "Modul nicht im Katalog") }
        let textOf = StudyPlanEngine.textOf, opt = StudyPlanEngine.opt as (String?) -> JSONValue
        var areas: [String: [String: JSONValue]] = [:]
        for a in cat["areas"]?.array ?? [] { if let o = a.object, let id = o["id"]?.string { areas[id] = o } }
        let area = m["area"]?.string.flatMap { areas[$0] }
        let st = full.state[moduleID]
        let attempts: [JSONValue] = (full.hist[moduleID] ?? []).map { r in
            ["text": r["text"] ?? .null, "semester": r["semester"] ?? .null, "status": r["status"] ?? .null,
             "grade": r["note"] ?? .null, "attempt": StudyPlanEngine.opt(StudyPlanEngine.intOrNil(r["versuch"])),
             "date": r["datum"] ?? .null]
        }
        let own: JSONValue = [
            "status": .string(st?.status ?? "nicht_gewaehlt"), "term": opt(st?.term.map(StudyPlanEngine.termName)),
            "attempt": StudyPlanEngine.opt(st?.attempt), "grade": opt(st?.grade), "moved_from": opt(st?.movedFrom),
            "reason": opt(st?.reason), "last_attempt": .bool(st?.lastAttempt ?? false), "attempts": .array(attempts),
        ]
        func ref(_ i: String) -> JSONValue {
            ["id": .string(i), "title": .string(textOf(full.byID[i]?["title"])),
             "status": .string(full.state[i]?.status ?? "nicht_gewaehlt")]
        }
        let pre = StudyPlanEngine.prereqs(m).filter { full.byID[$0] != nil }.map(ref)
        let requiredFor = full.modules.compactMap { $0["id"]?.string }
            .filter { StudyPlanEngine.prereqs(full.byID[$0]!).contains(moduleID) }.map(ref)
        let key = StudyPlanEngine.nameKey(m["title"])
        var appModules: [JSONValue] = [], mids: Set<Int> = []
        for r in try c.rows("SELECT id, name FROM modules ORDER BY id") where StudyPlanEngine.nameKey(r["name"]) == key {
            appModules.append(["id": r["id"] ?? .null, "name": r["name"] ?? .null])
            if let i = r["id"]?.int { mids.insert(i) }
        }
        var courses: [JSONValue] = [], courseIDs: [SQLiteValue] = []
        for r in try c.rows("SELECT id, title, semester, kind, subject, module_id FROM courses WHERE COALESCE(active, 1)=1 ORDER BY title, id") {
            let subject = textOf(r["subject"]).isEmpty ? r["title"] : r["subject"]
            guard r["module_id"]?.int.map(mids.contains) == true || StudyPlanEngine.nameKey(subject) == key else { continue }
            courses.append(["id": r["id"] ?? .null, "title": r["title"] ?? .null, "semester": r["semester"] ?? .null,
                            "kind": r["kind"] ?? .null, "module_id": r["module_id"] ?? .null])
            if let s = r["id"]?.string { courseIDs.append(.text(s)) }
        }
        var files: [JSONValue] = []
        if !courses.isEmpty {
            let marks = Array(repeating: "?", count: courseIDs.count).joined(separator: ",")
            files = try c.rows("SELECT id, name, course_id, mime FROM files WHERE course_id IN (\(marks)) ORDER BY name, id LIMIT 200",
                               courseIDs).map(JSONValue.object)
        }
        let src = cat["source"]?.object ?? [:]
        let n = StudyPlanEngine.numJSON
        return [
            "available": true, "id": .string(moduleID), "title": .string(textOf(m["title"])), "code": m["code"] ?? .null,
            "area": m["area"] ?? .null, "area_name": area.map { $0["name"] ?? .null } ?? .null,
            "kind": m["kind"] ?? .null, "lp": .number(StudyPlanEngine.lpOf(m)), "semester": n(m["semester"]),
            "turnus": m["turnus"] ?? .null, "exam": m["exam"] ?? .null, "coursework": m["coursework"] ?? .null,
            "language": m["language"] ?? .null, "workload_h": n(m["workload_h"]), "prerequisites": .array(pre),
            "required_for": .array(requiredFor), "texts": try source.moduleText(catalog: cat, moduleID: moduleID) ?? .null,
            "own": own, "app_modules": .array(appModules), "courses": .array(courses), "files": .array(files),
            "source": ["url": src["url"] ?? .null, "page": n(m["source_page"])],
            "program": cat["program"] ?? .null, "po": cat["po"] ?? .null, "catalog_term": cat["catalog_term"] ?? .null,
            "disclaimer": .string(StudyPlanEngine.disclaimer),
        ]
    }

    /// `GET /api/study-plan/settings`: Einstellungen mit Vorschlaegen und Auswahllisten
    public static func settings(_ c: SQLiteConnection, today: String, source: StudyCatalogSource? = nil) throws -> JSONValue {
        let source = source ?? DatabaseStudyCatalogSource(c)
        let s = try loadSettings(c), grades = try gradeRows(c)
        let catalogs = try source.catalogs()
        let suggested = StudyPlanEngine.pickCatalog(catalogs, settings: [:], grades: grades).catalog
        let cat = StudyPlanEngine.pickCatalog(catalogs, settings: s.json, grades: grades).catalog
        let known = grades.filter { !StudyPlanEngine.isBereich($0) }.compactMap { StudyPlanEngine.parseTerm($0["semester"]) }
        var pos: [String] = []
        for c in catalogs {
            let p = StudyPlanEngine.pyStr(c["po"])
            if !p.isEmpty, !pos.contains(p) { pos.append(p) }
        }
        let current = StudyPlanEngine.currentTerm(today)
        let areas = (cat?["areas"]?.array ?? []).compactMap(\.object)
        var names: [String: JSONValue] = [:]
        for a in areas { if let id = a["id"]?.string { names[id] = a["name"] ?? .null } }
        let wp = areas.filter { $0["kind"]?.string == "wahlpflicht" }.map { StudyPlanEngine.num($0["lp_required"]) ?? 0 }
        var options: [JSONValue] = []
        for v in cat?["modules"]?.array ?? [] {
            guard let m = v.object, let id = m["id"]?.string, !id.isEmpty,
                  StudyPlanEngine.electiveKinds.contains(StudyPlanEngine.textOf(m["kind"])) else { continue }
            options.append(["id": .string(id), "title": .string(StudyPlanEngine.textOf(m["title"])), "kind": m["kind"] ?? .null,
                            "lp": .number(StudyPlanEngine.lpOf(m)), "semester": StudyPlanEngine.numJSON(m["semester"]),
                            "area": m["area"] ?? .null,
                            "area_name": m["area"]?.string.flatMap { names[$0] } ?? .null])
        }
        var out = s.json
        out["suggested_po"] = suggested.map { $0["po"] ?? .null } ?? .null
        out["suggested_start_term"] = StudyPlanEngine.opt(known.min().map(StudyPlanEngine.termName))
        out["abschluss"] = StudyPlanEngine.opt(StudyPlanEngine.abschlussOf(grades))
        out["po_options"] = .array(pos.map(JSONValue.string))
        out["term_options"] = .array((0..<12).map { .string(StudyPlanEngine.termName(current - $0)) })
        out["elective_options"] = .array(options)
        out["elective_lp_required"] = wp.isEmpty ? .null : .number(wp.reduce(0, +))
        out["catalogs"] = .array(catalogs.map { c in
            ["po": c["po"] ?? .null, "code": c["code"] ?? .null, "program": c["program"] ?? .null,
             "degree": c["degree"] ?? .null, "catalog_term": c["catalog_term"] ?? .null]
        })
        return .object(out)
    }

    /// `POST /api/study-plan/settings`: nur die genannten Schluessel; 400 bei falschem Typ oder unbekanntem Semester
    public static func save(_ c: SQLiteConnection, body: [String: JSONValue], today: String,
                            source: StudyCatalogSource? = nil) throws -> JSONValue {
        var s = try loadSettings(c)
        if let v = body["po"] {
            switch v {
            case .null: s.po = nil
            case .string(let t): let p = PyText.strip(t); s.po = p.isEmpty ? nil : p
            default: throw LocalHTTPError(status: 400, message: "po muss Text sein")
            }
        }
        if let v = body["start_term"] {
            switch v {
            case .null: s.startTerm = nil
            case .string(let t):
                let raw = PyText.strip(t)
                if raw.isEmpty {
                    s.startTerm = nil
                } else {
                    guard let term = StudyPlanEngine.parseTerm(t) else {
                        throw LocalHTTPError(status: 400, message: "Unbekanntes Semester: \(raw)")
                    }
                    s.startTerm = StudyPlanEngine.termName(term)
                }
            default: throw LocalHTTPError(status: 400, message: "start_term muss Text sein")
            }
        }
        if let v = body["electives"] {
            guard let list = v.array, list.allSatisfy({ $0.string != nil }) else {
                throw LocalHTTPError(status: 400, message: "electives muss eine Liste von Modul-ids sein")
            }
            s.electives = sortedUnique(list.compactMap(\.string))
        }
        if let v = body["catalog_url"] {
            switch v {
            case .null: s.catalogURL = nil
            case .string(let t) where PyText.strip(t).isEmpty: s.catalogURL = nil
            case .string(let t):
                guard let u = StudyCatalogPipeline.cleanCatalogURL(t) else {
                    throw LocalHTTPError(status: 400, message: "catalog_url muss ein https-Link sein (höchstens 500 Zeichen)")
                }
                s.catalogURL = u
            default: throw LocalHTTPError(status: 400, message: "catalog_url muss Text sein")
            }
        }
        try LocalSettings.write(c, key: StudyPlanEngine.settingsKey, value: s.stored)
        return try settings(c, today: today, source: source)
    }
}
