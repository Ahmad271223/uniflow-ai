import Foundation

/// `GET /api/exam-registration` (nur lokal, docs/PRUEFUNGSANMELDUNG-2026-11-05.md): Meldezeitraum des Studiengangs,
/// "Diese Prüfungen solltest du anmelden" aus dem persoenlichen Studienverlauf (`StudyPlanEngine`), Klausurtermine aus
/// allen Quellen (`Exams`), QIS-Noten (bestanden -> nicht gelistet, Vermerk AN -> angemeldet) und die gelesenen Zeilen
/// von "Info über angemeldete Prüfungen" (`QISRegistrationsSync`). Rechnet nur; angemeldet wird nie von der App.
/// Hochschule aus `settings.university` (`ExamRegistrationPeriods.for(university:)`): LUH (QIS, Meldezeitraeume je
/// Studiengang) und Uni Hildesheim (LSF, Start der POS-Anmeldung ohne einheitliche Frist: `open_end`, keine Warnung
/// "endet in", Karte nur kurz vor und in den ersten `openEndCardDays` Tagen; Gelesenes aus "Meine POS-Anmeldungen").
public enum ExamRegistrationAPI {
    public static let hint = "Tippe im QIS auf „Prüfungsanmeldung/-abmeldung“, wähle die Prüfung und bestätige selbst. StudiNow füllt nichts aus und schickt nichts ab."
    public static let disclaimer = "Verbindlich sind die Fristen im QIS und auf den Seiten des Prüfungsamts. Module aus anderen Studiengängen können andere Zeiträume haben."
    /// Warnung, wenn der Meldezeitraum in hoechstens so vielen Tagen endet und noch Pruefungen fehlen
    public static let warnDays = 3
    /// Fenster ohne Ende (Uni Hildesheim): Karte auf der Uebersicht nur so viele Tage ab dem Start
    public static let openEndCardDays = 14

    /// Texte je Pruefungssystem ("QIS" der LUH, "LSF" der Uni Hildesheim)
    /// Knopf "Im QIS zur Prüfung anmelden" / "Im LSF zur Prüfung anmelden": "zur Prüfung", damit niemand ihn fuer die
    /// Anmeldung am QIS haelt (Befund des Inhabers 09.11.2026)
    public static func openLabel(_ system: String) -> String { "Im \(system) zur Prüfung anmelden" }
    static let suggestStatuses: Set<String> = ["offen", "geplant", "nicht_bestanden", "angemeldet"]

    static func vbp(_ exam: String?) -> Bool {
        let e = (exam ?? "").lowercased()
        return e.contains("vbp") || e.contains("veranstaltungsbegleitend")
    }

    /// Pruefungsleistung "keine" (nur Studienleistung): kein Meldezeitraum
    static func noExam(_ exam: String?) -> Bool {
        let e = PyText.strip((exam ?? "").lowercased())
        return e == "keine" || e.hasPrefix("keine ") || e == "-" || e == "–"
    }

    /// Tage vor dem Termin, bis zu denen man laut LUH-Regel zuruecktreten kann (Klausur 7, muendlich 1), sonst nil
    static func withdrawDays(_ exam: String?, rules: [(form: String, days: Int?, text: String)]) -> (Int, String)? {
        let e = (exam ?? "").lowercased()
        if vbp(exam) { return nil }
        let form = e.contains("mündlich") || e.contains("muendlich") ? "Mündliche Prüfung" : (e.isEmpty || e.contains("klausur") ? "Klausur" : nil)
        guard let form, let r = rules.first(where: { $0.form == form }), let d = r.days else { return nil }
        return (d, r.text)
    }

    /// Klausurtermine je Namensschluessel des Moduls (frueheste zuerst)
    static func examsByKey(_ items: [[String: JSONValue]]) -> [String: [[String: JSONValue]]] {
        var out: [String: [[String: JSONValue]]] = [:]
        for it in items {
            var names: [String] = []
            if let m = it["module_name"]?.string, !m.isEmpty { names.append(m) }
            if let c = it["course_title"]?.string, !c.isEmpty { names.append(c) }
            if let t = it["title"]?.string, let w = it["kind_label"]?.string, t.hasPrefix(w + " ") { names.append(String(t.dropFirst(w.count + 1))) }
            var keys = Set<String>()
            for n in names {
                let k = StudyPlanEngine.nameKey(n)
                if !k.isEmpty, keys.insert(k).inserted { out[k, default: []].append(it) }
            }
        }
        return out
    }

    public static func response(_ c: SQLiteConnection, today: String) throws -> JSONValue {
        let university = try c.scalar("SELECT value FROM settings WHERE key='university'")?.string ?? Migrations.defaultUniversity
        guard let data = ExamRegistrationPeriods.for(university: university), data.university == university else {
            return ["supported": false, "university": .string(university), "show_card": false, "suggestions": [], "registered": [],
                    "warnings": [], "periods": [], "qis_url": .null, "hint": .string(hint), "disclaimer": .string(disclaimer)]
        }
        let qisURL: JSONValue = .string(data.qisMenu)
        let system = data.system
        guard let day = BerlinClock.parseISODate(today) else { throw LocalHTTPError(status: 400, message: "Tag unlesbar") }

        // Studienverlauf
        let settings = try StudyPlanAPI.loadSettings(c), grades = try StudyPlanAPI.gradeRows(c)
        let picked = StudyPlanEngine.pickCatalog(try DatabaseStudyCatalogSource(c).catalogs(), settings: settings.json, grades: grades)
        let full = picked.catalog.map { StudyPlanEngine.compute(catalog: $0, grades: grades, settings: settings.json, today: today) }

        // Studiengang -> Terminseite
        let name = picked.catalog?["program"]?.string ?? StudyPlanEngine.programOf(grades)
        let degree = picked.catalog?["degree"]?.string
        let program = data.resolve(name: name, degree: degree)
        let window = data.window(program, today: today, kind: "meldung")
        let termName = window?.term ?? StudyPlanEngine.termName(StudyPlanEngine.currentTerm(today))
        // VbP nur, wenn ihr Fenster zum selben Semester gehoert (sonst passt es nicht zu den Vorschlaegen)
        let vbpWindow = data.window(program, today: today, kind: "vbp_meldung").flatMap { $0.term == termName ? $0 : nil }
        let term = StudyPlanEngine.parseTerm(termName) ?? StudyPlanEngine.currentTerm(today)

        // Klausurtermine, Anmeldungen, App-Module
        let exams = try Exams.upcoming(c, today: day)
        let examIndex = examsByKey(exams)
        let regs = try QISRegistrationsSync.rows(c)
        var appModules: [String: [Int]] = [:]
        for r in try c.rows("SELECT id, name FROM modules ORDER BY id") {
            if let id = r["id"]?.int { appModules[StudyPlanEngine.nameKey(r["name"]), default: []].append(id) }
        }

        func registration(code: String?, key: String) -> QISRegistration? {
            regs.first { r in
                guard r.registered else { return false }
                if let code, !code.isEmpty, let nr = r.pruefungsnr, PyText.strip(nr) == code { return true }
                return !key.isEmpty && StudyPlanEngine.nameKey(r.text) == key
            }
        }

        func examFields(_ key: String, exam: String?, reg: QISRegistration?, into o: inout [String: JSONValue]) {
            let e = examIndex[key]?.first
            var date = e?["date"]?.string, time = e?["time"]?.string
            if date == nil, let d = reg?.isoDate, (BerlinClock.parseISODate(d) ?? 0) >= day { date = d; time = reg?.clock }
            o["exam_date"] = StudyPlanEngine.opt(date)
            o["exam_time"] = StudyPlanEngine.opt(time.flatMap { $0.isEmpty ? nil : $0 })
            o["exam_room"] = e?["room"] ?? StudyPlanEngine.opt(reg?.room)
            o["exam_source"] = e?["source_label"] ?? (date != nil && reg != nil ? .string("aus \(system == "LSF" ? "dem " : "")\(system) (angemeldet)") : .null)
            var until: String? = reg?.isoWithdraw
            var rule: String?
            if let (n, text) = withdrawDays(exam, rules: data.rules) {
                rule = text
                if until == nil, let d = date.flatMap(BerlinClock.parseISODate) { until = BerlinClock.isoDate(d - n) }
            }
            o["withdraw_until"] = StudyPlanEngine.opt(until)
            o["withdraw_rule"] = StudyPlanEngine.opt(rule)
        }

        var suggestions: [[String: JSONValue]] = []
        var order: [String: Int] = [:]
        var planMessage: String?
        if let full {
            let start = (full.plan["start_term"]?.string).flatMap(StudyPlanEngine.parseTerm) ?? term
            for (i, m) in full.modules.enumerated() {
                guard let id = m["id"]?.string, let st = full.state[id], st.term == term, suggestStatuses.contains(st.status) else { continue }
                let exam = m["exam"]?.string
                if m["kind"]?.string == "abschluss" || noExam(exam) { continue }
                let key = StudyPlanEngine.nameKey(m["title"])
                let reg = registration(code: m["code"]?.string.map(PyText.strip), key: key)
                var o: [String: JSONValue] = [
                    "id": .string(id), "title": m["title"] ?? .null, "lp": .number(StudyPlanEngine.lpOf(m)), "exam": m["exam"] ?? .null,
                    "kind": m["kind"] ?? .null, "code": m["code"] ?? .null, "status": .string(st.status),
                    "fachsemester": .number(Double(term - start + 1)), "period": .string(vbp(exam) ? "vbp" : "meldung"),
                    "last_attempt": .bool(st.lastAttempt), "app_module_ids": .array((appModules[key] ?? []).map { .number(Double($0)) }),
                ]
                if st.status == "nicht_bestanden" {
                    let next = (st.attempt ?? 1) + 1
                    o["reason_kind"] = "wiederholung"
                    // Nummer nur, wenn QIS die Versuche zaehlt (11.11.2026); sonst waere sie geraten
                    o["reason"] = .string("Wiederholung" + (st.known ? " – \(next). Versuch" : "")
                                          + (st.movedFrom.map { " (nicht bestanden im \($0))" } ?? ""))
                } else if let from = st.movedFrom, (st.reason ?? "").contains("nachholen") {
                    o["reason_kind"] = "nachholen"
                    o["reason"] = .string("nachholen – laut Plan im \(from)")
                } else {
                    o["reason_kind"] = "plan"
                    o["reason"] = .string("laut deinem Plan im \(term - start + 1). Semester")
                }
                // Anmeldeseite zuerst: seit 10.11.2026 liest der Studienverlauf die Anmeldungen mit (Status "angemeldet"
                // auch ohne Zeile im Notenspiegel); die Quelle bleibt die Seite, auf der die Anmeldung steht
                if reg != nil {
                    o["registered"] = true
                    o["registered_via"] = "qis_info"
                } else if st.status == "angemeldet" {
                    o["registered"] = true
                    o["registered_via"] = "notenspiegel"
                } else {
                    o["registered"] = false
                    o["registered_via"] = .null
                }
                examFields(key, exam: exam, reg: reg, into: &o)
                order[id] = i
                suggestions.append(o)
            }
        } else {
            planMessage = "Ohne Studienverlauf kennt StudiNow deinen Plan nicht. Gezeigt werden die kommenden Klausuren deiner Module."
            // ohne Plan: kommende Klausuren der eigenen Module (je Modul die erste)
            var seen = Set<String>()
            for (i, e) in exams.enumerated() {
                let title = e["module_name"]?.string ?? e["course_title"]?.string ?? e["title"]?.string ?? "Prüfung"
                let key = StudyPlanEngine.nameKey(title)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                let reg = registration(code: nil, key: key)
                let viaQIS = (e["sources"]?.array ?? []).contains { $0["kind"]?.string == "qis" }
                // gelesene Anmeldung mit Termin (Exams-Quelle "anmeldung")
                let viaInfo = (e["sources"]?.array ?? []).contains { $0["kind"]?.string == "anmeldung" }
                let id = e["id"]?.string ?? "exam-\(i)"
                var o: [String: JSONValue] = [
                    "id": .string(id), "title": .string(title), "lp": .null, "exam": .null, "kind": .null, "code": .null,
                    "status": .null, "fachsemester": .null, "period": "meldung", "last_attempt": false,
                    "app_module_ids": .array(e["module_id"]?.int.map { [JSONValue.number(Double($0))] } ?? []),
                    "reason_kind": "klausur", "reason": .string("Klausurtermin bekannt"),
                    "registered": .bool(viaQIS || viaInfo || reg != nil),
                    "registered_via": viaQIS ? JSONValue.string("notenspiegel") : (reg != nil || viaInfo ? JSONValue.string("qis_info") : JSONValue.null),
                ]
                examFields(key, exam: nil, reg: reg, into: &o)
                order[id] = i
                suggestions.append(o)
            }
        }
        // offene zuerst, dann nach Termin (ohne Termin zuletzt), dann Reihenfolge des Plans
        suggestions.sort { a, b in
            let ra = a["registered"]?.bool ?? false, rb = b["registered"]?.bool ?? false
            if ra != rb { return !ra }
            let da = a["exam_date"]?.string ?? "9999", db = b["exam_date"]?.string ?? "9999"
            if da != db { return da < db }
            return (order[a["id"]?.string ?? ""] ?? 0) < (order[b["id"]?.string ?? ""] ?? 0)
        }
        let open = suggestions.filter { $0["registered"]?.bool != true }
        let openMain = open.filter { $0["period"]?.string != "vbp" }
        let openVbp = open.filter { $0["period"]?.string == "vbp" }

        var warnings: [JSONValue] = []
        func endText(_ w: ExamRegistrationWindow) -> String {
            switch w.daysLeft {
            case 0: return "heute"
            case 1: return "morgen"
            default: return "in \(w.daysLeft) Tagen"
            }
        }
        func plural(_ n: Int) -> String { n == 1 ? "1 geplante Prüfung ist" : "\(n) geplante Prüfungen sind" }
        // ohne bekanntes Ende (Uni Hildesheim) gibt es kein "endet in": die Frist steht je Pruefung im LSF
        if let w = window, w.phase == .open, !w.period.openEnd, w.daysLeft <= warnDays, !openMain.isEmpty {
            warnings.append(["kind": "ende", "tone": "bad",
                             "text": .string("Die Anmeldung endet \(endText(w)). \(plural(openMain.count)) noch nicht angemeldet.")])
        }
        if let w = vbpWindow, w.phase == .open, !w.period.openEnd, w.daysLeft <= warnDays, !openVbp.isEmpty {
            warnings.append(["kind": "vbp_ende", "tone": "bad",
                             "text": .string("Die Anmeldung für VbP endet \(endText(w)). \(plural(openVbp.count)) noch nicht angemeldet.")])
        }

        let run = try QISRegistrationsSync.lastRun(c)
        let showCard = (window.map { w in
            if w.phase == .soon { return true }
            guard w.phase == .open else { return false }
            // ohne Ende: nur die ersten Tage ab dem Start (sonst stuende die Karte das ganze Semester da)
            return !w.period.openEnd || (BerlinClock.parseISODate(w.period.start).map { day - $0 <= openEndCardDays } ?? false)
        } ?? false) || (vbpWindow?.phase == .open && !openVbp.isEmpty)
        let registeredJSON: [JSONValue] = regs.map { r in
            ["pruefungsnr": StudyPlanEngine.opt(r.pruefungsnr), "text": .string(r.text), "semester": StudyPlanEngine.opt(r.semester),
             "date": StudyPlanEngine.opt(r.isoDate), "date_text": StudyPlanEngine.opt(r.datum), "time": StudyPlanEngine.opt(r.clock),
             "room": StudyPlanEngine.opt(r.room), "status": StudyPlanEngine.opt(r.status), "registered": .bool(r.registered),
             "withdraw_until": StudyPlanEngine.opt(r.isoWithdraw), "form": StudyPlanEngine.opt(r.form)]
        }
        return [
            "supported": true, "university": .string(university),
            "program": program.map { p in
                ["name": StudyPlanEngine.opt(name.map(ExamRegistrationPeriods.programName)), "degree": StudyPlanEngine.opt(degree),
                 "slug": .string(p.slug), "url": .string(p.url), "verified": .bool(p.table != nil), "variant": StudyPlanEngine.opt(p.variant),
                 "all_programs": .bool(p.isDefault)]
            } ?? .null,
            "program_name": StudyPlanEngine.opt(name.map(ExamRegistrationPeriods.programName)),
            "source": ["url": .string(program?.url ?? data.generalURL), "general_url": .string(data.generalURL),
                       "checked_at": StudyPlanEngine.opt(program?.checkedAt ?? data.checkedAt)],
            "term": .string(termName), "window": window?.json ?? .null, "vbp_window": vbpWindow?.json ?? .null,
            "periods": .array(data.periods(program, term: window?.term).map(\.json)),
            "show_card": .bool(showCard),
            "plan_available": .bool(full != nil), "plan_message": StudyPlanEngine.opt(planMessage),
            "suggestions": .array(suggestions.map(JSONValue.object)),
            "open_count": .number(Double(open.count)), "registered_count": .number(Double(suggestions.count - open.count)),
            "registered": .array(registeredJSON),
            "registrations_checked_at": run?["at"] ?? .null, "registrations_ok": run?["ok"] ?? .null,
            "registrations_message": run?["message"] ?? .null,
            "warnings": .array(warnings), "qis_url": qisURL, "hint": .string(data.hint ?? hint),
            "rules": .array(data.rules.map { .string($0.text) }), "disclaimer": .string(data.disclaimer ?? disclaimer),
            "system": .string(system), "open_label": .string(openLabel(system)), "period_note": StudyPlanEngine.opt(data.periodNote),
        ]
    }
}
