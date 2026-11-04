import Foundation

/// Validator des geteilten Katalogformats (packages/shared-contracts/study-catalog.schema.json) mit denselben Regeln und
/// derselben Fehlerliste wie `validate` in app/study_catalog.py: "pfad: code" mit code aus required, type, enum, range,
/// format, unique, ref, forbidden, too_long. Faelle: fixtures/study-catalog/validator-cases.json. Ein Katalog aus der
/// Bibliothek wird nur uebernommen, wenn die Liste leer ist.
public enum StudyCatalogValidator {
    static let kinds: Set<String> = ["pflicht", "wahlpflicht", "wahl", "abschluss"]
    static let turnus: Set<String> = ["WS", "SS", "WS+SS", "unbekannt"]
    static let textKeys = ["content", "goals", "literature"]
    static let maxText = 500

    static func isNull(_ v: JSONValue?) -> Bool { v == nil || v == .null }

    static func isInt(_ v: JSONValue?) -> Bool {
        guard case .number(let d)? = v else { return false }
        return d == d.rounded(.towardZero) && d.isFinite
    }

    public static func validate(_ catalog: JSONValue) -> [String] {
        guard case .object(let c) = catalog else { return [": type"] }
        var errs: [String] = []

        func text(_ path: String, _ v: JSONValue?, nullable: Bool = false) {
            if isNull(v) {
                if !nullable { errs.append("\(path): required") }
                return
            }
            guard case .string(let s)? = v else { errs.append("\(path): type"); return }
            if s.isEmpty { errs.append("\(path): range") } else if StudyCatalogText.length(s) > maxText { errs.append("\(path): too_long") }
        }

        func number(_ path: String, _ v: JSONValue?, lo: Double? = nil, hi: Double? = nil, integer: Bool = false, nullable: Bool = true,
                    exclusive: Bool = false) {
            if isNull(v) {
                if !nullable { errs.append("\(path): required") }
                return
            }
            guard case .number(let d)? = v, !integer || isInt(v) else { errs.append("\(path): type"); return }
            if let lo, exclusive ? d <= lo : d < lo { errs.append("\(path): range"); return }
            if let hi, d > hi { errs.append("\(path): range") }
        }

        if c["v"] != .number(1) { errs.append("v: " + (c["v"] == nil ? "required" : "enum")) }
        for k in ["university", "program", "degree", "po"] { text(k, c[k]) }
        if isNull(c["catalog_term"]) {
            errs.append("catalog_term: required")
        } else if StudyCatalogText.termNumber(c["catalog_term"]?.string) == nil {
            errs.append("catalog_term: format")
        }
        if c["code"] == nil { errs.append("code: required") } else { text("code", c["code"], nullable: true) }
        number("regular_semesters", c["regular_semesters"], lo: 1, hi: 20, integer: true)
        number("total_lp", c["total_lp"], lo: 0, exclusive: true)
        if case .object(let src)? = c["source"] {
            if isNull(src["url"]) {
                errs.append("source.url: required")
            } else if !(src["url"]?.string?.hasPrefix("https://") ?? false) {
                errs.append("source.url: format")
            }
            if !isNull(src["fetched_at"]), src["fetched_at"]?.string == nil { errs.append("source.fetched_at: type") }
            if !isNull(src["sha256"]), !(src["sha256"]?.string.map { CatalogRx.matches("^[0-9a-f]{64}$", $0) } ?? false) {
                errs.append("source.sha256: format")
            }
        } else {
            errs.append("source: " + (isNull(c["source"]) ? "required" : "type"))
        }
        if c["module_texts"] != nil { errs.append("module_texts: forbidden") }

        let idRx = "^[a-z0-9]+(-[a-z0-9]+)*$"
        var areaIDs = Set<String>()
        var areas: [JSONValue] = []
        if let a = c["areas"]?.array { areas = a } else { errs.append("areas: " + (isNull(c["areas"]) ? "required" : "type")) }
        for (i, av) in areas.enumerated() {
            let p = "areas[\(i)]"
            guard case .object(let a) = av else { errs.append("\(p): type"); continue }
            if isNull(a["id"]) {
                errs.append("\(p).id: required")
            } else if let id = a["id"]?.string, CatalogRx.matches(idRx, id) {
                if areaIDs.contains(id) { errs.append("\(p).id: unique") } else { areaIDs.insert(id) }
            } else {
                errs.append("\(p).id: format")
            }
            text("\(p).name", a["name"])
            number("\(p).lp_required", a["lp_required"], lo: 0)
            number("\(p).lp_max", a["lp_max"], lo: 0)
            if case .number(let req)? = a["lp_required"], case .number(let mx)? = a["lp_max"], mx < req { errs.append("\(p).lp_max: range") }
            if !(a["kind"]?.string.map(kinds.contains) ?? false) { errs.append("\(p).kind: " + (isNull(a["kind"]) ? "required" : "enum")) }
        }

        var modules: [JSONValue] = []
        if let m = c["modules"]?.array { modules = m } else { errs.append("modules: " + (isNull(c["modules"]) ? "required" : "type")) }
        let moduleIDs = Set(modules.compactMap { $0.object?["id"]?.string })
        var seen = Set<String>()
        for (i, mv) in modules.enumerated() {
            let p = "modules[\(i)]"
            guard case .object(let m) = mv else { errs.append("\(p): type"); continue }
            let mid = m["id"]?.string
            if isNull(m["id"]) {
                errs.append("\(p).id: required")
            } else if let id = mid, CatalogRx.matches(idRx, id) {
                if seen.contains(id) { errs.append("\(p).id: unique") } else { seen.insert(id) }
            } else {
                errs.append("\(p).id: format")
            }
            text("\(p).title", m["title"])
            text("\(p).code", m["code"], nullable: true)
            if !isNull(m["area"]), !(m["area"]?.string.map(areaIDs.contains) ?? false) { errs.append("\(p).area: ref") }
            if !(m["kind"]?.string.map(kinds.contains) ?? false) { errs.append("\(p).kind: " + (isNull(m["kind"]) ? "required" : "enum")) }
            if m["lp"] == nil { errs.append("\(p).lp: required") } else { number("\(p).lp", m["lp"], lo: 0) }
            number("\(p).semester", m["semester"], lo: 1, hi: 20, integer: true)
            if !(m["turnus"]?.string.map(turnus.contains) ?? false) { errs.append("\(p).turnus: " + (isNull(m["turnus"]) ? "required" : "enum")) }
            text("\(p).exam", m["exam"], nullable: true)
            text("\(p).coursework", m["coursework"], nullable: true)
            if let pre = m["prerequisites"]?.array {
                for (j, r) in pre.enumerated() {
                    guard let s = r.string else { errs.append("\(p).prerequisites[\(j)]: type"); continue }
                    if s == mid || !moduleIDs.contains(s) { errs.append("\(p).prerequisites[\(j)]: ref") }
                }
            } else {
                errs.append("\(p).prerequisites: " + (isNull(m["prerequisites"]) ? "required" : "type"))
            }
            text("\(p).language", m["language"], nullable: true)
            number("\(p).workload_h", m["workload_h"], lo: 0)
            number("\(p).source_page", m["source_page"], lo: 1, integer: true)
            for k in textKeys where m[k] != nil { errs.append("\(p).\(k): forbidden") }
        }

        // Studienverlaufsplan (optional): Quelle und Plaetze fuer Wahlmodule je Semester
        if !isNull(c["study_plan"]) {
            if case .object(let sp)? = c["study_plan"] {
                if isNull(sp["url"]) {
                    errs.append("study_plan.url: required")
                } else if !(sp["url"]?.string?.hasPrefix("https://") ?? false) {
                    errs.append("study_plan.url: format")
                }
                if !isNull(sp["fetched_at"]), sp["fetched_at"]?.string == nil { errs.append("study_plan.fetched_at: type") }
                if !isNull(sp["sha256"]), !(sp["sha256"]?.string.map { CatalogRx.matches("^[0-9a-f]{64}$", $0) } ?? false) {
                    errs.append("study_plan.sha256: format")
                }
            } else {
                errs.append("study_plan: type")
            }
        }
        if !isNull(c["plan_slots"]) {
            let slots = c["plan_slots"]?.array ?? []
            if c["plan_slots"]?.array == nil { errs.append("plan_slots: type") }
            for (i, sv) in slots.enumerated() {
                let p = "plan_slots[\(i)]"
                guard case .object(let s) = sv else { errs.append("\(p): type"); continue }
                number("\(p).semester", s["semester"], lo: 1, hi: 20, integer: true, nullable: false)
                text("\(p).title", s["title"])
                if let ar = s["areas"]?.array {
                    for (j, a) in ar.enumerated() {
                        guard let id = a.string else { errs.append("\(p).areas[\(j)]: type"); continue }
                        if !areaIDs.contains(id) { errs.append("\(p).areas[\(j)]: ref") }
                    }
                } else {
                    errs.append("\(p).areas: " + (isNull(s["areas"]) ? "required" : "type"))
                }
                number("\(p).lp", s["lp"], lo: 0)
                number("\(p).lp_max", s["lp_max"], lo: 0)
                if case .number(let lp)? = s["lp"], case .number(let mx)? = s["lp_max"], mx < lp { errs.append("\(p).lp_max: range") }
            }
        }
        return errs
    }
}
