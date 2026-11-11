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
    /// QIS nennt die Nummer des Versuchs (sonst nur gezaehlt: keine Nummer anzeigen, 11.11.2026)
    let attemptKnown: Bool
    /// Hoechstzahl der Versuche laut Katalog/Pruefungsordnung, nil = unbekannt
    let maxAttempts: Int?
    /// endgueltig nicht bestanden (QIS oder Hoechstzahl erreicht)
    let final: Bool
    /// Wahlfach aus QIS ohne Katalogmodul (zaehlt in seinem Wahlbereich)
    let qis: Bool
    /// selbst verschoben oder vorgezogen (Einstellung `placements`)
    let placed: Bool
    /// Hinweise des Kerns: Turnus passt nicht, Voraussetzung nicht davor
    let hints: [String]
    /// eigener Eintrag (z. B. Studium generale einer anderen Fakultaet)
    let custom: Bool
    /// empfohlenes Fachsemester laut Katalog
    let recommended: Int?

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
        // "letzter Versuch" nur, wenn der Kern es sagt (Hoechstzahl bekannt oder QIS meldet es), nie aus der Nummer geraten
        lastAttempt = v["last_attempt"]?.bool ?? false
        attemptKnown = v["attempt_known"]?.bool ?? (attempt != nil)
        maxAttempts = v.i("max_attempts")
        final = v["final"]?.bool ?? false
        qis = v["qis"]?.bool ?? false
        placed = v["placed"]?.bool ?? false
        hints = v.list("hints").compactMap(\.string).filter { !$0.isEmpty }
        custom = v["custom"]?.bool ?? false
        recommended = v.i("semester")
    }

    var status: StudyPlanStatus { StudyPlanStatus.from(rawStatus, movedFrom: movedFrom) }
    /// verschiebbar: alles ausser Bestandenem und zur Pruefung Angemeldetem (beides liegt im Semester aus QIS, der Kern
    /// uebergeht dafuer jede eigene Lage, StudyPlanEngine.compute) und eigenen Eintraegen
    var movable: Bool { lockReason == nil }
    /// Grund, warum das Modul nicht verschiebbar ist (Menue, Details, VoiceOver, Ablegen); nil: verschiebbar
    var lockReason: String? {
        if custom { return StudyPlanText.lockedCustom }
        if qis { return StudyPlanText.lockedQIS }
        switch status {
        case .passed: return StudyPlanText.lockedPassed
        case .registered: return StudyPlanText.lockedRegistered
        default: return nil
        }
    }
    /// gewaehltes Wahlmodul, das sich gegen ein anderes tauschen laesst (nicht bestanden, nicht angemeldet)
    var replaceable: Bool { elective && movable && status != .registered && status != .failed }
    var elective: Bool { kind == "wahlpflicht" || kind == "wahl" }
}

/// Platz fuer offene Wahl im Semester (Kern: `semesters[].slots`): Platz laut Verlaufsplan, aus offenen LP eines
/// Wahlbereichs oder "Schwerpunkt wählen"
struct StudyPlanSlot: Identifiable, Equatable {
    let id: String
    let kind: String
    let title: String
    let area: String?
    let areas: [String]
    let group: String?
    let type: String
    let areaKind: String
    let lp: Double?
    let fachsemester: Int?
    var term: String = ""

    init(_ v: JSONValue, term: String) {
        id = v.s("id") ?? UUID().uuidString
        kind = v.s("kind") ?? "area"
        title = v.s("title") ?? "Wahlmodul"
        area = v.s("area")
        areas = v.list("areas").compactMap(\.string)
        group = v.s("group")
        type = v.s("type") ?? "wahl"
        areaKind = v.s("area_kind") ?? "wahlpflicht"
        lp = v.n("lp")
        fachsemester = v.i("fachsemester")
        self.term = term
    }

    var isTrack: Bool { kind == "track" }
}

/// Bereich mit Stand (Kern: `areas`)
struct StudyPlanArea: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let kind: String
    let group: String?
    let active: Bool
    let choice: Bool
    let lpRequired: Double?
    let lpMax: Double?
    let target: Double?
    let modulesRequired: Int?
    let lpDone: Double
    let lpPlanned: Double
    let lpOpen: Double?
    let count: Int
    let countDone: Int
    let options: Int
    let rule: String?

    init(_ v: JSONValue) {
        id = v.s("id") ?? ""
        name = v.s("name") ?? "Bereich"
        type = v.s("type") ?? "pflicht"
        kind = v.s("kind") ?? "pflicht"
        group = v.s("group")
        active = v["active"]?.bool ?? true
        choice = v["choice"]?.bool ?? false
        lpRequired = v.n("lp_required")
        lpMax = v.n("lp_max")
        target = v.n("target")
        modulesRequired = v.i("modules_required")
        lpDone = v.n("lp_done") ?? 0
        lpPlanned = v.n("lp_planned") ?? 0
        lpOpen = v.n("lp_open")
        count = v.i("count") ?? 0
        countDone = v.i("count_done") ?? 0
        options = v.i("options") ?? 0
        rule = v.s("rule").flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Gruppe "eins waehlen" (Schwerpunkt, Nebenfach, Vertiefungsrichtung)
struct StudyPlanGroup: Identifiable, Equatable {
    let id: String
    let label: String
    let options: [String]
    let chosen: String?
    let auto: Bool

    init(_ v: JSONValue) {
        id = v.s("id") ?? ""
        label = v.s("label") ?? "Schwerpunkt"
        options = v.list("options").compactMap(\.string)
        chosen = v.s("chosen")
        auto = v["auto"]?.bool ?? false
    }
}

/// Katalogmodul zum Waehlen (Kern: `electives` und `excluded`)
struct StudyPlanOption: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: String
    let area: String?
    let areas: [String]
    let lp: Double
    let semester: Int?
    let turnus: String
    let chosen: Bool
    let included: Bool
    let excluded: Bool

    init(_ v: JSONValue, excluded: Bool = false) {
        id = v.s("id") ?? ""
        title = v.s("title") ?? "Modul"
        kind = StudyPlanText.key(v.s("kind") ?? "wahlpflicht")
        area = v.s("area")
        areas = v.list("areas").compactMap(\.string)
        lp = v.n("lp") ?? 0
        semester = v.i("semester")
        turnus = v.s("turnus") ?? "unbekannt"
        chosen = v["chosen"]?.bool ?? false
        included = v["included"]?.bool ?? false
        self.excluded = excluded || (v["excluded"]?.bool ?? false)
    }
}

struct StudyPlanSemester: Identifiable, Equatable {
    let term: String
    let fachsemester: Int?
    let lp: Double
    let current: Bool
    var modules: [StudyPlanModule]
    /// offene Plaetze (Wahlbereiche), LP dieser Plaetze
    var slots: [StudyPlanSlot]
    let lpSlots: Double
    var id: String { term }

    init(_ v: JSONValue, currentTerm: String?) {
        let term = v.s("term") ?? v.s("name") ?? "Semester"
        self.term = term
        fachsemester = v.i("fachsemester") ?? v.i("semester")
        modules = v.list("modules").map(StudyPlanModule.init)
        lp = v.n("lp") ?? modules.reduce(0) { $0 + $1.lp }
        current = v["current"]?.bool ?? (currentTerm != nil && currentTerm == term)
        slots = v.list("slots").map { StudyPlanSlot($0, term: term) }
        lpSlots = v.n("lp_slots") ?? 0
    }

    /// frei bis zum Richtwert 30 LP
    var lpFree: Double { max(0, StudyPlanText.lpTarget - lp) }

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
    let currentTerm: String?
    let startTerm: String?
    /// Wahlbereiche, Gruppen, waehlbare und ausgeschlossene Module, eigene Lage (05.11.2026)
    let areas: [StudyPlanArea]
    let groups: [StudyPlanGroup]
    let options: [StudyPlanOption]
    let excluded: [StudyPlanOption]
    let placements: [String: String]

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
        currentTerm = current
        startTerm = v.s("start_term")
        areas = v.list("areas").map(StudyPlanArea.init).filter { !$0.id.isEmpty }
        groups = v.list("groups").map(StudyPlanGroup.init).filter { !$0.id.isEmpty }
        options = v.list("electives").map { StudyPlanOption($0) }.filter { !$0.id.isEmpty }
        excluded = v.list("excluded").map { StudyPlanOption($0, excluded: true) }.filter { !$0.id.isEmpty }
        var pl: [String: String] = [:]
        for (k, t) in v["placements"]?.object ?? [:] { if let t = t.string { pl[k] = t } }
        placements = pl
    }

    func area(_ id: String?) -> StudyPlanArea? { id.flatMap { i in areas.first { $0.id == i } } }

    /// Semester fuer "Verschieben nach …": vom aktuellen (bzw. ersten) bis vier Semester nach dem letzten im Plan
    var moveTerms: [String] {
        let known = semesters.compactMap { StudyPlanEngine.parseTerm($0.term) }
        let from = currentTerm.flatMap(StudyPlanEngine.parseTerm) ?? known.first
        guard let from, let last = known.max() else { return semesters.map(\.term) }
        return (from...max(from, last + 4)).map(StudyPlanEngine.termName)
    }

    /// Fachsemester eines Semesternamens (auch nach dem letzten Semester im Plan)
    func fachsemester(of term: String) -> Int? {
        if let s = semesters.first(where: { $0.term == term }) { return s.fachsemester }
        guard let t = StudyPlanEngine.parseTerm(term), let first = semesters.first, let f = first.fachsemester,
              let t0 = StudyPlanEngine.parseTerm(first.term) else { return nil }
        return t - t0 + f
    }

    /// waehlbare Module fuer einen Platz (Bereiche des Platzes; leer = alle Wahlbereiche), noch nicht im Plan
    func choices(for slot: StudyPlanSlot?) -> [StudyPlanOption] {
        let open = (options.filter { !$0.included && !$0.excluded }) + excluded
        guard let slot, !slot.areas.isEmpty else { return open }
        return open.filter { o in o.areas.contains { slot.areas.contains($0) } || (o.area.map(slot.areas.contains) ?? false) }
    }

    /// eigene Eintraege im Plan (fuer das Bearbeiten in den Einstellungen)
    var customModules: [StudyPlanModule] { modules.filter(\.custom) }

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
    /// QIS nennt die Nummer des Versuchs; Hoechstzahl laut Katalog (nil = unbekannt); endgueltig nicht bestanden
    let attemptKnown: Bool
    let maxAttempts: Int?
    let final: Bool
    /// Nummer des aktuellen bzw. letzten Versuchs laut Kern
    let attempt: Int?
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
        lastAttempt = own["last_attempt"]?.bool ?? false
        attempt = own.i("attempt") ?? attempts.compactMap(\.attempt).max()
        attemptKnown = own["attempt_known"]?.bool ?? attempts.contains { $0.attempt != nil }
        maxAttempts = own.i("max_attempts")
        final = own["final"]?.bool ?? false
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

// MARK: - Aendern (eigene Lage, Wahl, Schwerpunkt, eigene Eintraege)

/// Rumpf fuer POST /api/study-plan/settings je Aenderung (05.11.2026). Der Kern speichert teilweise: nur die genannten
/// Schluessel aendern sich. Ausgangsstand ist der gelesene Plan (gewaehlte Module, eigene Lage, Schwerpunkt).
enum StudyPlanEdit {
    static func dict(_ d: [String: String]) -> JSONValue { .object(d.mapValues(JSONValue.string)) }

    /// Modul in ein Semester legen (verschieben, vorziehen)
    static func move(_ plan: StudyPlan, id: String, to term: String) -> JSONValue {
        var p = plan.placements
        p[id] = term
        return ["placements": dict(p)]
    }

    /// zurueck ins empfohlene Semester
    static func resetPlacement(_ plan: StudyPlan, id: String) -> JSONValue {
        var p = plan.placements
        p[id] = nil
        return ["placements": dict(p)]
    }

    /// Modul aus dem Katalog in den Plan nehmen, optional in ein Semester
    static func choose(_ plan: StudyPlan, option: StudyPlanOption, term: String?) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if option.excluded {
            o["excluded"] = .array(plan.excluded.map(\.id).filter { $0 != option.id }.map(JSONValue.string))
        }
        if option.kind == "wahlpflicht" || option.kind == "wahl" {
            var chosen = plan.options.filter(\.chosen).map(\.id)
            if !chosen.contains(option.id) { chosen.append(option.id) }
            o["electives"] = .array(chosen.map(JSONValue.string))
        }
        if let term {
            var p = plan.placements
            p[option.id] = term
            o["placements"] = dict(p)
        }
        return .object(o)
    }

    /// gewaehltes Wahlmodul gegen ein anderes tauschen: altes ab, neues dazu, neues im Semester des alten
    static func replace(_ plan: StudyPlan, old: String, option: StudyPlanOption, term: String?) -> JSONValue {
        var chosen = plan.options.filter { $0.chosen && $0.id != old }.map(\.id)
        if !chosen.contains(option.id) { chosen.append(option.id) }
        var p = plan.placements
        p[old] = nil
        if let term { p[option.id] = term }
        return ["electives": .array(chosen.map(JSONValue.string)), "placements": dict(p)]
    }

    /// "Nicht belegen": Wahlmodul abwaehlen, sonst ausschliessen; die eigene Lage faellt weg
    static func drop(_ plan: StudyPlan, module m: StudyPlanModule) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if m.elective, plan.options.contains(where: { $0.id == m.id && $0.chosen }) {
            o["electives"] = .array(plan.options.filter { $0.chosen && $0.id != m.id }.map { .string($0.id) })
        } else {
            o["excluded"] = .array((plan.excluded.map(\.id) + [m.id]).map(JSONValue.string))
        }
        if plan.placements[m.id] != nil {
            var p = plan.placements
            p[m.id] = nil
            o["placements"] = dict(p)
        }
        return .object(o)
    }

    /// "Plan zurücksetzen": eigene Lage und "Nicht belegen" weg (Wahl, Schwerpunkt, eigene Eintraege bleiben)
    static let reset: JSONValue = ["placements": .null, "excluded": .null]

    /// Schwerpunkt (Bereich) einer Gruppe waehlen
    static func track(_ plan: StudyPlan, group: String, area: String?) -> JSONValue {
        var t: [String: String] = [:]
        for g in plan.groups where !g.auto { if let c = g.chosen { t[g.id] = c } }
        t[group] = area
        return ["tracks": dict(t)]
    }

    static func customJSON(_ m: StudyPlanModule, plan: StudyPlan) -> JSONValue {
        let fach = plan.semester(of: m.id)?.fachsemester
        return ["id": .string(m.id), "title": .string(m.title), "lp": .number(m.lp), "area": m.area.map(JSONValue.string) ?? .null,
                "semester": (m.recommended ?? fach).map { .number(Double($0)) } ?? .null]
    }

    /// eigenen Eintrag hinzufuegen (Titel, LP, Bereich, Fachsemester)
    static func addCustom(_ plan: StudyPlan, title: String, lp: Double, area: String?, fachsemester: Int?) -> JSONValue {
        let new: JSONValue = ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "lp": .number(lp),
                              "area": area.map(JSONValue.string) ?? .null,
                              "semester": fachsemester.map { .number(Double($0)) } ?? .null]
        return ["custom": .array(plan.customModules.map { customJSON($0, plan: plan) } + [new])]
    }

    static func removeCustom(_ plan: StudyPlan, id: String) -> JSONValue {
        ["custom": .array(plan.customModules.filter { $0.id != id }.map { customJSON($0, plan: plan) })]
    }
}

// MARK: - Texte und Regeln

enum StudyPlanText {
    static let title = "Studienverlauf"
    static let disclaimer = "Verbindlich ist die Prüfungsordnung deiner Hochschule."
    /// Warum ein Modul nicht verschiebbar ist (Menue, Details, VoiceOver, Ablegen; 09.11.2026). Der Kern uebergeht fuer
    /// Bestandenes und zur Pruefung Angemeldetes jede eigene Lage (Semester aus dem Notenspiegel)
    static let lockedPassed = "Bestanden – bleibt in dem Semester, in dem du es bestanden hast."
    static let lockedRegistered = "Zur Prüfung angemeldet – bleibt im aktuellen Semester. Nach einer Abmeldung lässt es sich verschieben."
    static let lockedCustom = "Eigener Eintrag – liegt im Fachsemester, das du beim Eintragen gewählt hast."
    static let noQIS = "Verbinde QIS, damit StudiNow deinen Studiengang kennt"
    /// Quelle des Notenspiegels: "LSF" an der Uni Hildesheim, "Campusmanagement" (HISinOne) an der HsH, sonst "QIS" (LUH)
    static func gradeSource(hildesheim: Bool, hsh: Bool = false) -> String { hsh ? "Campusmanagement" : hildesheim ? "LSF" : "QIS" }
    /// "in QIS", "im LSF", "im Campusmanagement"
    static func gradeSourceIn(hildesheim: Bool, hsh: Bool = false) -> String { hsh ? "im Campusmanagement" : hildesheim ? "im LSF" : "in QIS" }
    /// "aus QIS", "aus dem LSF", "aus dem Campusmanagement"
    static func gradeSourceFrom(hildesheim: Bool, hsh: Bool = false) -> String { hsh ? "aus dem Campusmanagement" : hildesheim ? "aus dem LSF" : "aus QIS" }
    static func noQIS(hildesheim: Bool, hsh: Bool = false) -> String {
        hsh ? "Melde dich im Campusmanagement an, damit StudiNow deinen Studiengang kennt"
            : hildesheim ? "Verbinde das LSF, damit StudiNow deinen Studiengang kennt" : noQIS
    }
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
    static let finalWarning = "Endgültig nicht bestanden – sprich mit der Studienberatung."
    static let lockedQIS = "Aus QIS übernommen – Stand und Semester kommen aus QIS"

    /// Regel zu den Versuchen im Detail (11.11.2026): Hoechstzahl nur, wenn Katalog/Pruefungsordnung sie nennen
    static func attemptsRule(maxAttempts: Int?) -> String {
        if let n = maxAttempts { return "Laut Prüfungsordnung höchstens \(n) Versuche." }
        return "Wie viele Versuche du hast, regelt deine Prüfungsordnung – StudiNow kennt die Zahl für diesen Studiengang nicht."
    }
    /// Richtwert je Semester 30 LP; Warnung ab mehr als 36 LP
    static let lpLimit: Double = 36
    static let lpTarget: Double = 30

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
        case .registered:
            guard m.attemptKnown, let n = m.attempt, n >= 2 else { return "Angemeldet" }
            return "Angemeldet · \(n). Versuch"
        case .failed:
            if m.final { return "Endgültig nicht bestanden" }
            guard m.attemptKnown, let n = m.attempt else { return "Nicht bestanden" }
            return "Nicht bestanden · \(n). Versuch"
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
        if m.lastAttempt && !m.final { parts.append("letzter Versuch") }
        if m.placed { parts.append("selbst eingeplant") }
        if m.custom { parts.append("eigener Eintrag") }
        if m.qis { parts.append("aus QIS, nicht im Modulkatalog") }
        parts.append(contentsOf: m.hints)
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
        if s.lpSlots > 0 { parts.append("dazu \(number(s.lpSlots)) Leistungspunkte offene Wahl") }
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

    // MARK: Wahlbereiche und eigene Lage (05.11.2026)

    /// Zeile unter dem Platz: "noch 10 von 15 LP offen", "1 von 3 Modulen gewählt", "Eine von 5 Richtungen wählen"
    static func slotLine(_ slot: StudyPlanSlot, plan: StudyPlan) -> String {
        if slot.isTrack {
            let n = plan.groups.first { $0.id == slot.group }?.options.count ?? 0
            return n > 0 ? "Eine von \(n) Richtungen wählen" : "Eine Richtung wählen"
        }
        guard let a = plan.area(slot.area) else { return "Modul wählen" }
        // was noch fehlt zuerst: Zahl der Module, sonst LP (05.11.2026, wie slotLine in app/static/study-plan-logic.js)
        if let n = a.modulesRequired, a.count < n { return "\(a.count) von \(n) Modulen gewählt" }
        if let t = a.target, let o = a.lpOpen { return "noch \(number(o)) von \(number(t)) LP offen" }
        if let n = a.modulesRequired { return "\(min(a.count, n)) von \(n) Modulen gewählt" }
        return "\(a.options) Module zur Wahl"
    }

    /// Fortschritt im Kasten "Bereiche und Wahl" (0...1 oder nil) und ob der Bedarf bestanden ist: LP und Zahl der Module
    /// muessen beide reichen; nur Zahl der Module (ohne LP-Ziel) misst die Zahl (05.11.2026, wie areaProgress im Web)
    static func areaProgress(_ a: StudyPlanArea) -> (value: Double?, done: Bool) {
        let countOK = (a.modulesRequired ?? 0) <= 0 || a.countDone >= a.modulesRequired!
        if let t = a.target, t > 0 { return (min(1, (a.lpDone + a.lpPlanned) / t), a.lpDone >= t && countOK) }
        if let n = a.modulesRequired, n > 0 { return (min(1, Double(a.count) / Double(n)), countOK) }
        return (nil, false)
    }

    /// Titel des Platzes mit LP: "Seminar (5 LP)"
    static func slotTitle(_ slot: StudyPlanSlot) -> String {
        guard let lp = slot.lp, lp > 0 else { return slot.title }
        return "\(slot.title) (\(number(lp)) LP)"
    }

    /// Bereichsnamen eines Platzes ("Vertiefung der Informatik oder Vertiefung der Informationstechnik"); nil ohne Namen
    /// oder bei mehr als drei Bereichen
    static func slotAreaNames(_ slot: StudyPlanSlot, plan: StudyPlan) -> String? {
        let ids = slot.areas.isEmpty ? (slot.area.map { [$0] } ?? []) : slot.areas
        let names = ids.compactMap { plan.area($0)?.name }.filter { !$0.isEmpty }
        guard !names.isEmpty, names.count <= 3 else { return nil }
        return names.joined(separator: " oder ")
    }

    /// Kopf des Kastens fuer offene Wahl (Inhaber 11.11.2026: „Wahlfach – wähl eins aus der Liste aus"): "Wahlpflicht:
    /// Vertiefung der Informatik" bzw. "Wahlfach"; Schwerpunkt/Nebenfach: "Schwerpunkt wählen"
    static func slotHeading(_ slot: StudyPlanSlot, plan: StudyPlan) -> String {
        if slot.isTrack { return slot.title }
        if slot.areaKind == "wahl" { return "Wahlfach" }
        return "Wahlpflicht: " + (slotAreaNames(slot, plan: plan) ?? slot.title)
    }

    /// Zweite Zeile des Kastens: Wahlfach -> Bereich, sonst der Name laut Verlaufsplan, wenn er anders heisst ("Proseminar"),
    /// dazu die LP
    static func slotSubtitle(_ slot: StudyPlanSlot, plan: StudyPlan) -> String? {
        if slot.isTrack { return slot.lp.map { lp($0) } }
        let names = slotAreaNames(slot, plan: plan)
        var name: String? = slot.areaKind == "wahl" ? (names ?? slot.title) : (slot.title != names ? slot.title : nil)
        if slot.areaKind != "wahl", names == nil { name = nil }
        let parts = [name, slot.lp.flatMap { $0 > 0 ? lp($0) : nil }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Knopf im Kasten
    static func slotButton(_ slot: StudyPlanSlot) -> String { slot.isTrack ? "Richtung wählen" : "Aus der Liste wählen" }

    /// VoiceOver je Platz: "Offener Platz, Wahlpflicht: Seminare, 5 Leistungspunkte, 0 von 1 Modulen gewählt"
    static func accessibility(_ slot: StudyPlanSlot, plan: StudyPlan) -> String {
        var parts = ["Offener Platz", slotHeading(slot, plan: plan)]
        if let sub = slotSubtitle(slot, plan: plan) { parts.append(sub.replacingOccurrences(of: " LP", with: " Leistungspunkte")) }
        parts.append(slotLine(slot, plan: plan))
        return parts.joined(separator: ", ")
    }

    /// Bereichszeile: "10 von 15 LP · 5 bestanden · 2 von 3 Modulen"
    static func areaLine(_ a: StudyPlanArea) -> String {
        var parts: [String] = []
        let have = a.lpDone + a.lpPlanned
        if let t = a.target { parts.append("\(number(have)) von \(number(t)) LP") } else { parts.append("\(number(have)) LP") }
        if a.lpDone > 0 { parts.append("\(number(a.lpDone)) bestanden") }
        if let n = a.modulesRequired { parts.append("\(min(a.count, n)) von \(n) Modulen") }
        return parts.joined(separator: " · ")
    }

    /// Rueckmeldung nach dem Verschieben: "3 Module vorgezogen – im 3. Semester sind jetzt 12 LP frei"
    static func moveMessage(title: String, from: StudyPlanSemester?, to term: String, after plan: StudyPlan) -> String {
        let source = from.flatMap { f in plan.semesters.first { $0.term == f.term } }
        let free = source.map { "im \($0.fachsemester.map { "\($0). Semester" } ?? $0.term) sind jetzt \(number($0.lpFree)) LP frei" }
        let fromT = from.flatMap { StudyPlanEngine.parseTerm($0.term) }, toT = StudyPlanEngine.parseTerm(term)
        let earlier = fromT != nil && toT != nil && toT! < fromT!
        let head: String
        if earlier {
            let pulled = plan.modules.filter { m in
                guard m.placed, let r = m.recommended, let f = plan.semester(of: m.id)?.fachsemester else { return false }
                return f < r
            }.count
            head = pulled >= 2 ? "\(pulled) Module vorgezogen" : "\(title) vorgezogen nach \(term)"
        } else {
            head = "\(title) verschoben nach \(term)"
        }
        return free.map { "\(head) – \($0)" } ?? head
    }

    /// VoiceOver-Hinweis je Karte; ein gesperrtes Modul nennt den Grund
    static func cardHint(_ m: StudyPlanModule, editable: Bool) -> String {
        guard editable, let why = m.lockReason else { return "Zeigt Details zum Modul" }
        return "Zeigt Details zum Modul. Nicht verschiebbar: \(why)"
    }

    /// Der Kern hat das Modul nicht ins Ziel gelegt (z. B. Nachholen erst nach dem letzten Versuch)
    static func moveRefused(title: String, staysIn term: String, target: String) -> String {
        "\(title) bleibt in \(term) – StudiNow konnte es nicht nach \(target) legen."
    }

    /// Hinweis beim Ziel: Turnus passt nicht
    static func turnusWarning(_ turnus: String, term: String) -> String? {
        guard let t = StudyPlanEngine.parseTerm(term) else { return nil }
        let winter = t % 2 == 1
        switch StudyPlanText.turnus(turnus) {
        case "WiSe" where !winter: return "Laut Katalog nur im Wintersemester angeboten"
        case "SoSe" where winter: return "Laut Katalog nur im Sommersemester angeboten"
        default: return nil
        }
    }

    /// Kurzname fuer die Gesamtansicht: passt der Titel nicht in die Breite, Fuellwoerter weg und lange Woerter
    /// gekuerzt ("Grundlagen der Rechnernetze" -> "Grundl. Rechnernetze" -> "Grun. Rech."), zuletzt Anfangsbuchstaben
    static func abbreviation(_ title: String, width: CGFloat, font: CGFloat) -> String {
        let fits = { (s: String) in CGFloat(s.count) * font * 0.56 <= max(20, width) }
        if fits(title) { return title }
        let filler: Set<String> = ["der", "die", "das", "und", "für", "in", "im", "zur", "zum", "von", "des", "den", "mit", "an", "&", "-", "–"]
        let words = title.split(separator: " ").map(String.init).filter { !filler.contains($0.lowercased()) }
        for keep in [7, 5, 4, 3] {
            let s = words.map { w -> String in
                let roman = w.allSatisfy { "IVX0123456789:".contains($0) }
                return roman || w.count <= keep + 1 ? w : String(w.prefix(keep)) + "."
            }.joined(separator: " ")
            if fits(s) { return s }
        }
        return words.map { w in w.allSatisfy { "IVX0123456789".contains($0) } ? " " + w : String(w.prefix(1)) }.joined()
    }

    /// Kurzform des Bereichstyps fuer das Etikett am Platz
    static func typeLabel(_ type: String) -> String? {
        switch type {
        case "studium_generale": return "Studium generale"
        case "schluessel": return "Schlüsselkompetenzen"
        case "seminar": return "Seminar"
        case "labor": return "Labor"
        case "projekt": return "Projekt"
        case "praktikum": return "Praktikum"
        case "schwerpunkt": return "Schwerpunkt"
        case "nebenfach": return "Nebenfach"
        case "vertiefung": return "Vertiefung"
        default: return nil
        }
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
