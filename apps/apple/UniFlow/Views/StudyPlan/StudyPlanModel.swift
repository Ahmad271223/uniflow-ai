import SwiftUI
import UniFlowCore

// Studienverlauf (Auftrag des Inhabers 04.11.2026, docs/STUDIENVERLAUF-2026-11-04.md): Daten der Seite aus dem
// lokalen Backend (gleich am PC-Server). Die Ansicht rechnet nichts selbst; Plan, Status und Verschiebungen kommen
// fertig vom Kern. Hier nur Lesen (tolerant gegen fehlende oder anders benannte Felder) und Beschriftung.
//
// Endpunkte und erwartete Felder (gebaut gegen die Beschreibung im Dokument):
//   GET  /api/study-plan            {available, reason?, message?, program, degree?, po, catalog_term, lp_done, lp_total,
//                                    notes:[String|{text,tone}], disclaimer, suggested_po?, po_confirmed?, qis_program?,
//                                    semesters:[{term, fachsemester, lp, current?, modules:[{id, title, lp, kind, turnus,
//                                    area?, status, attempt|versuch?, grade|note?, moved_from?, reason?, last_attempt?}]}]}
//   GET  /api/study-plan/module/{id} Fakten (oben oder unter "facts"), texts {content, goals, literature}, own {status,
//                                    attempts:[{semester, grade, status, attempt, date}]}, materials:[{kind: course|file,
//                                    id, title, sub?, route?}] (oder getrennt "courses"/"files"), source {url, page}
//   GET  /api/study-plan/settings   {po, po_options, start_term, term_options, electives:[ids], elective_options:[{id,
//                                    title, lp, area}], elective_lp_required?, catalog_url?}
//   POST /api/study-plan/settings   {po, start_term, electives:[ids]} (+ catalog_url fuer den eigenen Link)
//   GET  /api/study-catalog/status  {state: searching|downloading|parsing|ready|seed|library|not_found|error, message?,
//                                    progress? (0…1), error?}

// MARK: - Status eines Moduls

/// Anzeigeform des Status (der Kern liefert `bestanden`, `angemeldet`, `nicht_bestanden`, `offen`, `geplant`; ein
/// verschobenes Modul traegt zusaetzlich `moved_from`)
enum StudyPlanStatus: Equatable {
    case passed, registered, failed, moved, planned, open

    /// Status aus dem Rohwert ("nicht bestanden", "NICHT_BESTANDEN", "nachholen" …) und der Verschiebung
    static func from(_ raw: String?, movedFrom: String?) -> StudyPlanStatus {
        let s = StudyPlanText.key(raw ?? "")
        switch s {
        case "bestanden", "passed", "be": return .passed
        case "angemeldet", "registered", "an": return .registered
        case "nicht_bestanden", "failed", "nb", "endgueltig_nicht_bestanden": return .failed
        default: break
        }
        if movedFrom != nil || ["verschoben", "nachholen", "nachgeholt", "moved"].contains(s) { return .moved }
        return ["geplant", "planned", "plan"].contains(s) ? .planned : .open
    }

    var tone: UFTone {
        switch self {
        case .passed: return .ok
        case .registered: return .info
        case .failed: return .bad
        case .moved: return .warn
        case .planned, .open: return .neutral
        }
    }

    var icon: String {
        switch self {
        case .passed: return "check"
        case .registered: return "flag"
        case .failed: return "alert"
        case .moved: return "move"
        case .planned: return "calendar"
        case .open: return "circle"
        }
    }

    /// zaehlt zum Filter "Offen" (alles, was noch nicht bestanden ist)
    var isOpen: Bool { self != .passed }
}

// MARK: - Plan

struct StudyPlanModule: Identifiable, Equatable {
    let id: String
    let title: String
    let code: String?
    let lp: Double
    let kind: String
    let turnus: String
    let area: String?
    let rawStatus: String?
    let attempt: Int?
    let grade: String?
    let movedFrom: String?
    let reason: String?
    let lastAttempt: Bool

    init(_ v: JSONValue) {
        id = v.s("id") ?? v.i("id").map(String.init) ?? UUID().uuidString
        title = v.s("title") ?? v.s("name") ?? "Modul"
        code = v.s("code")
        lp = v.n("lp") ?? v.n("credits") ?? 0
        kind = StudyPlanText.key(v.s("kind") ?? "pflicht")
        turnus = v.s("turnus") ?? "unbekannt"
        area = v.s("area")
        rawStatus = v.s("status")
        attempt = v.i("attempt") ?? v.i("versuch") ?? v.i("attempts")
        grade = v.s("grade") ?? v.s("note") ?? v.n("grade").map(StudyPlanText.grade)
        movedFrom = (v.s("moved_from") ?? v.s("postponed_from")).flatMap { $0.isEmpty ? nil : $0 }
        reason = (v.s("reason") ?? v.s("moved_reason")).flatMap { $0.isEmpty ? nil : $0 }
        lastAttempt = v["last_attempt"]?.bool ?? ((attempt ?? 0) >= 3 && StudyPlanStatus.from(v.s("status"), movedFrom: nil) == .failed)
    }

    var status: StudyPlanStatus { StudyPlanStatus.from(rawStatus, movedFrom: movedFrom) }
}

struct StudyPlanSemester: Identifiable, Equatable {
    let term: String
    let fachsemester: Int?
    let lp: Double
    let current: Bool
    var modules: [StudyPlanModule]
    var id: String { term }

    init(_ v: JSONValue, currentTerm: String?) {
        term = v.s("term") ?? v.s("name") ?? "Semester"
        fachsemester = v.i("fachsemester") ?? v.i("semester")
        modules = v.list("modules").map(StudyPlanModule.init)
        lp = v.n("lp") ?? modules.reduce(0) { $0 + $1.lp }
        current = v["current"]?.bool ?? (currentTerm != nil && currentTerm == term)
    }

    /// Richtwert 30 LP je Semester; ueber 36 LP warnt die Spalte (wie die Regel im Kern)
    var overloaded: Bool { lp > StudyPlanText.lpLimit + 0.01 }
}

struct StudyPlanNote: Equatable {
    let text: String
    let tone: UFTone

    init(_ v: JSONValue) {
        let text = v.string ?? v.s("text") ?? ""
        self.text = text
        switch StudyPlanText.key(v.s("tone") ?? v.s("kind") ?? "") {
        case "bad", "danger", "error", "last_attempt": tone = .bad
        case "warn", "warning", "moved": tone = .warn
        case "ok", "success": tone = .ok
        case "info": tone = .info
        default:
            let t = text.lowercased()
            tone = t.contains("letzter versuch") ? .bad : (t.contains("nachzuholen") || t.contains("verschoben") || t.contains("über") ? .warn : .info)
        }
    }
}

/// Warum es (noch) keinen Plan gibt
enum StudyPlanGap: Equatable {
    case noQIS, catalogLoading, noCatalog, other(String)

    static func from(reason: String?, message: String?) -> StudyPlanGap {
        switch StudyPlanText.key(reason ?? "") {
        case "no_qis", "qis", "no_grades", "no_program", "keine_qis", "qis_missing": return .noQIS
        case "catalog_loading", "loading", "searching", "downloading", "parsing", "catalog_searching", "pending", "building", "queued":
            return .catalogLoading
        case "no_catalog", "no_catalog_po", "catalog_missing", "not_found", "unknown_program", "no_source", "kein_katalog": return .noCatalog
        default: return .other(message ?? reason ?? "Unbekannter Grund")
        }
    }
}

struct StudyPlan: Equatable {
    let available: Bool
    let gap: StudyPlanGap?
    /// Text des Kerns ohne Plan ("Für die Prüfungsordnung 2017 gibt es noch keinen Katalog.")
    let message: String?
    let program: String?
    let degree: String?
    let po: String?
    let catalogTerm: String?
    let lpDone: Double
    let lpTotal: Double
    let notes: [StudyPlanNote]
    let disclaimer: String
    let suggestedPO: String?
    let poConfirmed: Bool
    let qisProgram: String?
    let semesters: [StudyPlanSemester]

    init(_ v: JSONValue) {
        available = v["available"]?.bool ?? !v.list("semesters").isEmpty
        message = v.s("message").flatMap { $0.isEmpty ? nil : $0 }
        var gap = available ? nil : StudyPlanGap.from(reason: v.s("reason"), message: v.s("message"))
        // Der Kern nennt ohne Notenspiegel nur "no_catalog"; fehlt dazu der Studiengang aus QIS (`qis_program` null),
        // kennt StudiNow den Studiengang noch nicht: QIS verbinden
        if gap == .noCatalog, let q = v["qis_program"], q.isNull || q.string?.isEmpty == true, v.s("program") == nil { gap = .noQIS }
        self.gap = gap
        program = v.s("program")
        degree = v.s("degree")
        po = v.s("po") ?? v.i("po").map(String.init)
        catalogTerm = v.s("catalog_term")
        let current = v.s("current_term")
        semesters = v.list("semesters").map { StudyPlanSemester($0, currentTerm: current) }
        lpDone = v.n("lp_done") ?? 0
        lpTotal = v.n("lp_total") ?? 0
        notes = v.list("notes").map(StudyPlanNote.init).filter { !$0.text.isEmpty }
        disclaimer = v.s("disclaimer").flatMap { $0.isEmpty ? nil : $0 } ?? StudyPlanText.disclaimer
        suggestedPO = v.s("suggested_po") ?? v.i("suggested_po").map(String.init)
        poConfirmed = v["po_confirmed"]?.bool ?? (suggestedPO == nil)
        qisProgram = v.s("qis_program") ?? v.s("qis_abschluss")
    }

    var modules: [StudyPlanModule] { semesters.flatMap(\.modules) }

    /// Titel je Modul-id (Voraussetzungen im Detail, wenn der Kern nur ids liefert)
    var titles: [String: String] { Dictionary(modules.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }) }

    /// "Technische Informatik B.Sc."; ohne Katalog der Studiengang aus QIS
    var programLine: String {
        let line = [program, degree].compactMap { $0 }.joined(separator: " ")
        return line.isEmpty ? (qisProgram ?? "") : line
    }

    /// "PO 2022 · Katalog WS 2025/26"
    var subLine: String {
        [po.map { "PO \($0)" }, catalogTerm.map { "Katalog \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    var currentSemester: StudyPlanSemester? { semesters.first(where: \.current) }

    /// Modul nach id oder Titel (Sprung aus der Modulseite: "Im Studienverlauf zeigen")
    func module(matching focus: String) -> StudyPlanModule? {
        if let m = modules.first(where: { $0.id == focus }) { return m }
        let f = StudyPlanText.normalized(focus)
        guard !f.isEmpty else { return nil }
        return modules.first { StudyPlanText.normalized($0.title) == f }
            ?? modules.first { let t = StudyPlanText.normalized($0.title); return !t.isEmpty && (f.hasPrefix(t) || t.hasPrefix(f)) }
    }

    func semester(of moduleID: String) -> StudyPlanSemester? {
        semesters.first { $0.modules.contains { $0.id == moduleID } }
    }
}

// MARK: - Katalogsuche

struct StudyCatalogStatus: Equatable {
    let state: String
    let message: String?
    let progress: Double?

    init(_ v: JSONValue) {
        state = StudyPlanText.key(v.s("state") ?? v.s("status") ?? "searching")
        message = (v.s("message") ?? v.s("detail") ?? v.s("error")).flatMap { $0.isEmpty ? nil : $0 }
        progress = v.n("progress").map { max(0, min(1, $0 > 1 ? $0 / 100 : $0)) }
    }

    /// Suche oder Laden laeuft noch: die Seite fragt weiter nach
    var busy: Bool { ["searching", "downloading", "parsing", "loading", "building", "queued", "pending", "found"].contains(state) }
    /// fertig: Plan neu lesen
    var ready: Bool { ["ready", "seed", "library", "loaded", "done", "ok"].contains(state) }
    var failed: Bool { state == "error" || state == "failed" }
    var notFound: Bool { state == "not_found" || state == "no_catalog" }

    /// Zeile unter dem Fortschritt: Text des Kerns, sonst je Schritt
    var text: String {
        if let message { return message }
        switch state {
        case "searching", "queued", "pending": return "StudiNow sucht den Modulkatalog deines Studiengangs …"
        case "found": return "Modulkatalog gefunden …"
        case "downloading", "loading": return "Modulkatalog wird geladen …"
        case "parsing", "building": return "Module werden gelesen …"
        case "library": return "Aus der Bibliothek übernommen"
        case "seed": return "Aus dem StudiNow-Grundstock"
        case "ready", "loaded", "done", "ok": return "Modulkatalog geladen"
        case "error", "failed": return "Der Modulkatalog ließ sich nicht laden."
        default: return "Modulkatalog wird vorbereitet …"
        }
    }
}

// MARK: - Moduldetail

struct StudyModuleDetail: Equatable {
    struct Prerequisite: Equatable, Identifiable { let id: String; let title: String }
    struct Attempt: Equatable { let attempt: Int?; let term: String?; let grade: String?; let status: StudyPlanStatus; let date: String? }
    struct Material: Equatable, Identifiable {
        let id: String
        let kind: String
        let title: String
        let sub: String?
        let route: UFRoute?
    }
    struct Section: Equatable, Identifiable { let id: String; let title: String; let text: String }

    let id: String
    let title: String
    let code: String?
    let lp: Double
    let semester: Int?
    let turnus: String
    let kind: String
    let area: String?
    let exam: String?
    let coursework: String?
    let prerequisites: [Prerequisite]
    let language: String?
    let workloadH: Int?
    let sections: [Section]
    let status: StudyPlanStatus
    let attempts: [Attempt]
    let lastAttempt: Bool
    let movedFrom: String?
    let reason: String?
    let materials: [Material]
    let sourceURL: URL?
    let sourcePage: Int?
    /// Modultexte werden gerade im Hintergrund geladen (Katalog aus Grundstock oder Bibliothek, `texts_loading`)
    let textsLoading: Bool

    init(_ v: JSONValue, titles: [String: String] = [:]) {
        let f = v["facts"].flatMap { $0.object == nil ? nil : $0 } ?? v
        func s(_ k: String) -> String? { (f.s(k) ?? v.s(k)).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        id = s("id") ?? v.i("id").map(String.init) ?? ""
        title = s("title") ?? s("name") ?? "Modul"
        code = s("code")
        lp = f.n("lp") ?? v.n("lp") ?? 0
        semester = f.i("semester") ?? v.i("semester")
        turnus = s("turnus") ?? "unbekannt"
        kind = StudyPlanText.key(s("kind") ?? "pflicht")
        area = s("area_name") ?? s("area")
        exam = s("exam")
        coursework = s("coursework")
        language = s("language")
        workloadH = f.i("workload_h") ?? v.i("workload_h")
        prerequisites = (f["prerequisites"] ?? v["prerequisites"])?.array?.compactMap { p in
            if let id = p.string { return Prerequisite(id: id, title: titles[id] ?? StudyPlanText.titleFromID(id)) }
            guard let id = p.s("id") else { return nil }
            return Prerequisite(id: id, title: p.s("title") ?? titles[id] ?? StudyPlanText.titleFromID(id))
        } ?? []
        let texts = v["texts"] ?? v["local_text"] ?? v["module_texts"] ?? .null
        textsLoading = v["texts_loading"]?.bool ?? false
        sections = [("content", "Inhalte"), ("goals", "Lernziele"), ("literature", "Literatur")].compactMap { key, name in
            guard let t = texts.s(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return Section(id: key, title: name, text: t)
        }
        let own = v["own"] ?? v["mine"] ?? v["state"] ?? .null
        let moved = (own.s("moved_from") ?? v.s("moved_from")).flatMap { $0.isEmpty ? nil : $0 }
        movedFrom = moved
        reason = (own.s("reason") ?? v.s("reason")).flatMap { $0.isEmpty ? nil : $0 }
        status = StudyPlanStatus.from(own.s("status") ?? v.s("status"), movedFrom: moved)
        attempts = own.list("attempts").map { a in
            Attempt(attempt: a.i("attempt") ?? a.i("versuch"), term: a.s("semester") ?? a.s("term"),
                    grade: a.s("grade") ?? a.s("note") ?? a.n("grade").map(StudyPlanText.grade),
                    status: StudyPlanStatus.from(a.s("status"), movedFrom: nil), date: a.s("date") ?? a.s("datum"))
        }
        let lastTry = attempts.compactMap(\.attempt).max() ?? own.i("attempt") ?? 0
        lastAttempt = own["last_attempt"]?.bool ?? (status == .failed && lastTry >= 3)
        // Unterlagen: "materials" oder wie der Kern getrennt "app_modules" (Fach der App), "courses" und "files"
        var mats = v.list("materials")
        if mats.isEmpty {
            func tagged(_ list: [JSONValue], _ kind: String) -> [JSONValue] { list.map { var c = $0; c["kind"] = .string(kind); return c } }
            mats = tagged(v.list("app_modules"), "module") + tagged(v.list("courses"), "course") + tagged(v.list("files"), "file")
        }
        let appModule = v.list("app_modules").first?.i("id")
        materials = mats.enumerated().map { i, m in
            let kind = StudyPlanText.key(m.s("kind") ?? m.s("type") ?? "file")
            let kindKey = ["module", "course", "file"].contains(kind) ? kind : (m["course_id"] != nil || m["name"] != nil ? "file" : "course")
            let rawID = m.s("id") ?? m.i("id").map(String.init)
            let title = m.s("title") ?? m.s("name") ?? "Unterlage"
            var route: UFRoute?
            if let h = m.s("route"), h.hasPrefix("#") { route = UFRoute(hash: h) }
            else if kindKey == "module" { route = m.i("id").map { UFRoute.module($0) } }
            else if kindKey == "course" { route = (m.i("module_id") ?? appModule).map { UFRoute.module($0) } }
            else if let rawID { route = .doc(rawID) }
            let sub = m.s("sub") ?? m.s("detail") ?? (kindKey == "course" ? m.s("semester") : nil)
                ?? (kindKey == "module" ? "Fach in StudiNow" : nil)
            return Material(id: "\(kindKey)-\(rawID ?? String(i))", kind: kindKey, title: title, sub: sub, route: route)
        }
        let src = v["source"] ?? .null
        let page = src.i("page") ?? v.i("source_page") ?? f.i("source_page")
        sourcePage = page
        sourceURL = StudyPlanText.sourceURL(src.s("url") ?? v.s("source_url"), page: page)
    }
}

// MARK: - Einstellungen

struct StudyPlanSettings: Equatable {
    struct Elective: Equatable, Identifiable { let id: String; let title: String; let lp: Double; let area: String? }

    var po: String?
    var poOptions: [String]
    var startTerm: String?
    var termOptions: [String]
    var electives: [String]
    var electiveOptions: [Elective]
    var electiveLPRequired: Double?
    var catalogURL: String?

    init(_ v: JSONValue, today: Date = Date()) {
        po = v.s("po") ?? v.i("po").map(String.init)
        var pos = (v.list("po_options").isEmpty ? v.list("pos") : v.list("po_options"))
            .compactMap { $0.string ?? $0.s("po") ?? $0.int.map(String.init) }
        if let p = po, !pos.contains(p) { pos.append(p) }
        poOptions = pos
        startTerm = v.s("start_term")
        var terms = v.list("term_options").compactMap(\.string)
        if terms.isEmpty { terms = StudyPlanText.recentTerms(today: today) }
        if let t = startTerm, !terms.contains(t) { terms.insert(t, at: 0) }
        termOptions = terms
        electives = v.list("electives").compactMap { $0.string ?? $0.s("id") }
        electiveOptions = v.list("elective_options").compactMap { e in
            guard let id = e.s("id") else { return nil }
            return Elective(id: id, title: e.s("title") ?? id, lp: e.n("lp") ?? 0, area: e.s("area_name") ?? e.s("area"))
        }
        electiveLPRequired = v.n("elective_lp_required") ?? v.n("elective_lp")
        catalogURL = v.s("catalog_url")
    }

    /// LP der gewaehlten Wahlpflichtmodule
    func chosenLP(_ chosen: Set<String>) -> Double {
        electiveOptions.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.lp }
    }

    /// Rumpf fuer POST /api/study-plan/settings: Wahlmodule in der Reihenfolge der Liste (stabil fuer den Vergleich)
    func body(po: String?, startTerm: String?, electives chosen: Set<String>, catalogURL: String? = nil) -> JSONValue {
        let known = electiveOptions.map(\.id).filter { chosen.contains($0) }
        let extra = chosen.subtracting(known).sorted()
        var o: [String: JSONValue] = [
            "po": po.map(JSONValue.string) ?? .null,
            "start_term": startTerm.map(JSONValue.string) ?? .null,
            "electives": .array((known + extra).map(JSONValue.string)),
        ]
        if let catalogURL { o["catalog_url"] = .string(catalogURL) }
        return .object(o)
    }
}

// MARK: - Texte und Regeln

enum StudyPlanText {
    static let title = "Studienverlauf"
    static let disclaimer = "Verbindlich ist die Prüfungsordnung deiner Hochschule."
    static let noQIS = "Verbinde QIS, damit StudiNow deinen Studiengang kennt"
    static let noQISSub = "Aus deinem Notenspiegel liest StudiNow Studiengang und Prüfungsordnung. Deine Noten bleiben auf diesem Gerät."
    static let noCatalog = "Noch kein Katalog für deinen Studiengang"
    static let noCatalogSub = "Für deinen Studiengang kennt StudiNow noch keinen Modulkatalog. Hast du einen Link zum Modulhandbuch (PDF)? Dann lädt StudiNow ihn wie ein Browser."
    static let linkField = "Link zum Modulhandbuch einfügen"
    static let linkSaved = "Gespeichert. StudiNow sucht jetzt den Katalog unter diesem Link."
    static let linkInvalid = "Bitte einen vollständigen Link mit https:// einfügen."
    static let loading = "Studienverlauf wird berechnet …"
    static let materialsEmpty = "Noch keine Kurse oder Dateien in StudiNow, die zu diesem Modul gehören."
    static let localOnly = "Modultexte liegen nur auf diesem Gerät."
    static let lastAttemptWarning = "Letzter Versuch – sprich mit der Studienberatung."
    /// Richtwert je Semester 30 LP; Warnung ab mehr als 36 LP
    static let lpLimit: Double = 36

    /// Schluessel ohne Umlaute, klein, mit Unterstrich ("Nicht bestanden" -> "nicht_bestanden")
    static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// Titel fuer Vergleiche: nur Buchstaben und Ziffern, ohne Umlaute
    static func normalized(_ s: String) -> String {
        String(s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// "programmieren-1" -> "Programmieren 1" (nur, wenn der Kern keinen Titel nennt)
    static func titleFromID(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Zahl deutsch ohne ueberfluessige Nachkommastellen: 5 -> "5", 2.5 -> "2,5"
    static func number(_ d: Double) -> String {
        if d.rounded() == d { return String(Int(d)) }
        return String(format: "%.1f", d).replacingOccurrences(of: ".", with: ",")
    }

    static func lp(_ d: Double) -> String { "\(number(d)) LP" }

    /// Note als Text: 1.7 -> "1,7"
    static func grade(_ d: Double) -> String { String(format: "%.1f", d).replacingOccurrences(of: ".", with: ",") }

    /// "84 von 180 LP"
    static func progress(_ done: Double, _ total: Double) -> String { "\(number(done)) von \(number(total)) LP" }

    static func percent(_ done: Double, _ total: Double) -> Double { total > 0 ? max(0, min(100, done / total * 100)) : 0 }

    static func kind(_ k: String) -> String {
        switch k {
        case "pflicht": return "Pflicht"
        case "wahlpflicht": return "Wahlpflicht"
        case "wahl": return "Wahl"
        case "abschluss", "abschlussarbeit": return "Abschluss"
        default: return k.prefix(1).uppercased() + k.dropFirst()
        }
    }

    /// Farbe der Art: Pflicht ruhig grau, Wahlpflicht Lavendel, Wahl Tuerkis, Abschluss Butter
    static func kindPair(_ k: String) -> CommunityPair {
        switch k {
        case "wahlpflicht": return CommunityPalette.lavender
        case "wahl": return CommunityPalette.teal
        case "abschluss", "abschlussarbeit": return CommunityPalette.butter
        default: return CommunityPair(bg: UF.surface2, fg: UF.text2, solid: UF.lineStrong)
        }
    }

    /// Kurzform des Turnus auf der Karte; nil bei unbekanntem Turnus
    static func turnus(_ t: String) -> String? {
        switch t.uppercased().replacingOccurrences(of: " ", with: "") {
        case "WS", "WISE", "WINTER": return "WiSe"
        case "SS", "SOSE", "SOMMER": return "SoSe"
        case "WS+SS", "SS+WS", "JEDES", "BEIDE": return "jedes Semester"
        default: return nil
        }
    }

    /// Langform fuer VoiceOver und das Detail
    static func turnusLong(_ t: String) -> String {
        switch turnus(t) {
        case "WiSe": return "Wintersemester"
        case "SoSe": return "Sommersemester"
        case "jedes Semester": return "jedes Semester"
        default: return "unbekannt"
        }
    }

    /// Text der Statuspille
    static func status(_ m: StudyPlanModule) -> String {
        switch m.status {
        case .passed: return m.grade.map { "Bestanden · \($0)" } ?? "Bestanden"
        case .registered: return "Angemeldet"
        case .failed: return m.attempt.map { "Nicht bestanden · Versuch \($0)" } ?? "Nicht bestanden"
        case .moved: return m.movedFrom.map { "Verschoben · aus \($0)" } ?? "Nachholen"
        case .planned: return "Geplant"
        case .open: return "Offen"
        }
    }

    static func status(_ s: StudyPlanStatus) -> String {
        switch s {
        case .passed: return "Bestanden"
        case .registered: return "Angemeldet"
        case .failed: return "Nicht bestanden"
        case .moved: return "Verschoben"
        case .planned: return "Geplant"
        case .open: return "Offen"
        }
    }

    /// VoiceOver je Karte: "Programmieren I, 5 LP, Pflicht, Wintersemester, Bestanden · 1,7"
    static func accessibility(_ m: StudyPlanModule) -> String {
        var parts = [m.title, "\(number(m.lp)) Leistungspunkte", kind(m.kind)]
        if turnus(m.turnus) != nil { parts.append(turnusLong(m.turnus)) }
        parts.append(status(m).replacingOccurrences(of: " · ", with: ", "))
        if m.status != .moved, let f = m.movedFrom { parts.append("aus \(f)") }
        if let r = m.reason { parts.append(r) }
        if m.lastAttempt { parts.append("letzter Versuch") }
        return parts.joined(separator: ", ")
    }

    /// Zeile unter der Statuspille: Grund, bei einem nicht bestandenen, weitergereichten Modul mit Herkunft
    static func reasonLine(_ m: StudyPlanModule) -> String? {
        let from = m.status != .moved ? m.movedFrom.map { "aus \($0)" } : nil
        let parts = [from, m.reason].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// VoiceOver je Semester: "WiSe 26/27, 3. Fachsemester, 30 LP, aktuelles Semester"
    static func accessibility(_ s: StudyPlanSemester) -> String {
        var parts = [s.term]
        if let f = s.fachsemester { parts.append("\(f). Fachsemester") }
        parts.append("\(number(s.lp)) Leistungspunkte" + (s.overloaded ? ", mehr als der Richtwert" : ""))
        if s.current { parts.append("aktuelles Semester") }
        return parts.joined(separator: ", ")
    }

    /// Quelle mit Seite: die PDF springt mit "#page=12" auf die Seite
    static func sourceURL(_ s: String?, page: Int?) -> URL? {
        guard let s, var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              c.host?.isEmpty == false else { return nil }
        if let page, c.fragment == nil { c.fragment = "page=\(page)" }
        return c.url
    }

    static func sourceLabel(page: Int?) -> String {
        page.map { "Im Modulkatalog ansehen (S. \($0))" } ?? "Im Modulkatalog ansehen"
    }

    /// eingefuegter Link zum Modulhandbuch: nur http(s) mit Rechnernamen, Leerzeichen am Rand weg
    static func catalogURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = c.host, host.contains(".") else { return nil }
        return c.url
    }

    /// Semester rund um heute (neuestes zuerst), falls der Kern keine Liste nennt: "WiSe 26/27", "SoSe 26", …
    static func recentTerms(today: Date, count: Int = 12) -> [String] {
        let cal = Fmt.calendar
        var year = cal.component(.year, from: today)
        let month = cal.component(.month, from: today)
        // WiSe ab Oktober (Januar-Maerz gehoert zum WiSe des Vorjahres), SoSe April-September
        var winter = month >= 10 || month <= 3
        if month <= 3 { year -= 1 }
        var out: [String] = []
        for _ in 0..<count {
            out.append(winter ? String(format: "WiSe %02d/%02d", year % 100, (year + 1) % 100) : String(format: "SoSe %02d", year % 100))
            if winter { winter = false } else { winter = true; year -= 1 }
        }
        return out
    }

    /// Fachsemester-Zeile: "3. Fachsemester"
    static func fach(_ n: Int?) -> String? { n.map { "\($0). Fachsemester" } }

    /// Feste Farbe je Bereich (Streifen links an der Karte)
    static func areaColor(_ area: String?) -> Color {
        guard let area, !area.isEmpty else { return UF.lineStrong }
        let p = CommunityPalette.people
        return p[Int(CommunityPalette.stableHash(area) % UInt64(p.count))].solid
    }
}

/// Filter ueber dem Board
enum StudyPlanFilter: String, CaseIterable, Hashable {
    case all, open, passed

    var label: String {
        switch self {
        case .all: return "Alle"
        case .open: return "Offen"
        case .passed: return "Bestanden"
        }
    }

    func keeps(_ m: StudyPlanModule) -> Bool {
        switch self {
        case .all: return true
        case .open: return m.status.isOpen
        case .passed: return m.status == .passed
        }
    }
}
