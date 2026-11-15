import Foundation

/// Doppelt geplante Lernpakete zusammenfuehren (Fehler vom echten iPhone vom 14.11.2026, docs/PLANER-KEINE-DOPPELPLANUNG.md),
/// 1:1 nach app/plan_merge.py; gemeinsame Abgleichsdatei plan-merge.json (`StudyPlanMergeTests`).
///
/// Ursache: Jedes Geraet plant selbst (erste Planung nach der Einrichtung, neue Dokumente nach dem eigenen Abgleich mit
/// der Hochschule), bevor der Geraete-Abgleich die Planung des anderen Geraets gebracht hat. Der Abgleich erkennt ein
/// Paket nur dann als dasselbe, wenn Tag, Fach und Titel gleich sind; liegt dieselbe Unterlage auf dem anderen Geraet an
/// einem anderen Tag, stehen danach beide Planungen nebeneinander (dieselbe Datei zweimal, vier Pakete an einem Tag).
///
/// Regel (auf jedem Geraet und im Dienst dieselbe):
/// - Der Schluessel einer automatischen Aufgabe ist ihre Unterlage: Datei + Ausschnitt (Seiten, "Teil k/n"). Er ist auf
///   jedem Geraet gleich (Datei-IDs kommen von der Hochschule) und braucht keine neue Spalte. Wochentest und
///   Wiederholung: Fach + Lehrwoche + Art.
/// - Stehen zwei Aufgaben fuer dieselbe Unterlage im Plan, bleibt genau eine: eine angefasste immer (erledigt, begonnen,
///   verschoben, von Hand angelegt, gesperrt, mit Lernzeit, mit Verlauf); sonst die, die schon im Konto steht (das
///   Geraet uebernimmt die Planung des Kontos statt seiner eigenen); sonst die frueher geplante (`created_at` des
///   Pakets, unveraenderlich und abgeglichen); sonst die mit der kleineren Nummer im Dienst. Zwei Geraete, die dieselben
///   zwei Zeilen sehen, entfernen dieselbe: kein Hin und Her mit Loeschmarken.
/// - Entfernt wird nur eine unberuehrte automatische Aufgabe, und nur, wenn eine andere dieselbe Unterlage abdeckt. Ein
///   Paket verschwindet erst, wenn es dadurch leer ist.
enum StudyPlanMerge {
    /// `COVER`: steht im Plan (wie `StudyPlan.plannedFiles`)
    static let cover = ["geplant", "in_bearbeitung", "erledigt", "nachholen"]
    /// `OPEN`: unberuehrt (nachholen setzt die Uhr, nicht der Mensch)
    static let open: Set<String> = ["geplant", "nachholen"]
    /// `SINGLE`: je Fach und Lehrwoche genau einmal
    static let single: Set<String> = ["test", "wiederholung"]
    static let far = "9999"
    /// `BALANCE_DAYS`: so viele Tage ab morgen prueft `balanceDays`
    static let balanceDaysAhead = 28
    static let appliedDevice = "~dienst"

    struct Result: Equatable {
        var tasks = 0
        var packages = 0
        var empty = 0
        var moved = 0

        var changed: Bool { tasks + packages + empty + moved > 0 }
        var json: JSONValue { ["tasks": .number(Double(tasks)), "packages": .number(Double(packages)), "empty": .number(Double(empty)), "moved": .number(Double(moved))] }
    }

    /// `slot`: Ausschnitt der Unterlage (von, bis, aus der Gliederung?, Teil k, von n)
    struct Slot: Equatable {
        var from = 0
        var to = 0
        var outline = false
        var part = 0
        var parts = 0
    }

    private static let partRE = try! NSRegularExpression(pattern: "\\(Teil ([0-9]+)/([0-9]+)\\)$")
    private static let pagesRE = try! NSRegularExpression(pattern: "· S\\. ([0-9]+)(?:–([0-9]+))?$")

    private static func match(_ re: NSRegularExpression, _ s: String) -> (start: String.Index, groups: [Int?])? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let whole = Range(m.range, in: s) else { return nil }
        let groups = (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).flatMap { Int(s[$0]) } }
        return (whole.lowerBound, groups)
    }

    static func slot(title raw: String?, pageFrom: Int?, pageTo: Int?) -> Slot {
        var title = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var out = Slot()
        if let m = match(partRE, title), let k = m.groups[0], let n = m.groups[1] {
            out.part = k
            out.parts = n
            title = String(title[..<m.start]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let a = pageFrom {
            out.from = a
            out.to = pageTo ?? a
            out.outline = true
        } else if let m = match(pagesRE, title), let a = m.groups[0] {
            out.from = a
            out.to = m.groups[1] ?? a
        }
        return out
    }

    /// `same_material`: decken zwei Ausschnitte derselben Datei in derselben Lehrwoche dasselbe ab? Gleiche Seiten bzw.
    /// gleicher Teil; die ganze Datei gegen Abschnitte aus der Gliederung (aeltere App ohne Gliederung neben der neuen);
    /// verschieden geteilt. Verschiedene Seiten und verschiedene Teile derselben Teilung nicht.
    static func sameMaterial(_ x: Slot, _ y: Slot) -> Bool {
        let rx = x.from > 0, ry = y.from > 0
        if rx && ry {
            if x.from != y.from || x.to != y.to { return false }
        } else if rx != ry {
            return (rx ? x : y).outline
        }
        return !(x.parts != 0 && x.parts == y.parts && x.part != y.part)
    }

    /// `same_planned`: in derselben Lehrwoche `sameMaterial`, sonst nur genau derselbe Ausschnitt
    static func samePlanned(_ a: (week: Int?, slot: Slot), _ b: (week: Int?, slot: Slot)) -> Bool {
        if a.week == b.week { return sameMaterial(a.slot, b.slot) }
        return a.slot.from == b.slot.from && a.slot.to == b.slot.to && a.slot.part == b.slot.part && a.slot.parts == b.slot.parts
    }

    private static func hasTable(_ c: SQLiteConnection, _ name: String) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(name)]) != nil
    }

    /// `_remote_ids`: Nummer der Zeile im Dienst (kleinste, falls mehrere Zeilen des Dienstes hier eine sind)
    private static func remoteIDs(_ c: SQLiteConnection, _ entity: String) throws -> [Int64: Int64] {
        guard try hasTable(c, "sync_link_map") else { return [:] }
        var out: [Int64: Int64] = [:]
        for r in try c.query("SELECT local_id, remote_id FROM sync_link_map WHERE entity=?", [.text(entity)]) {
            guard let l = r["local_id"]?.string.flatMap({ Int64($0) }) ?? r["local_id"]?.int64,
                  let rid = r["remote_id"]?.string.flatMap({ Int64($0) }) ?? r["remote_id"]?.int64 else { continue }
            out[l] = min(rid, out[l] ?? rid)
        }
        return out
    }

    /// `_order`: im Konto vor nur hier, frueher geplant, kleinere Nummer im Dienst
    private struct Order: Comparable {
        let touched: Int
        let local: Int
        let plannedAt: String
        let number: Int64
        let id: Int64

        static func < (a: Order, b: Order) -> Bool {
            if a.touched != b.touched { return a.touched < b.touched }
            if a.local != b.local { return a.local < b.local }
            if a.plannedAt != b.plannedAt { return PyText.less(a.plannedAt, b.plannedAt) }
            if a.number != b.number { return a.number < b.number }
            return a.id < b.id
        }
    }

    private static func order(_ remote: [Int64: Int64], id: Int64, plannedAt: String?, touched: Int = 0) -> Order {
        let planned = (plannedAt ?? "").isEmpty ? far : plannedAt!
        return Order(touched: touched, local: remote[id] == nil ? 1 : 0, plannedAt: planned, number: remote[id] ?? id, id: id)
    }

    private static func untouched(_ c: SQLiteConnection) throws -> Set<Int64> {
        Set(try c.query("SELECT p.id FROM study_packages p WHERE \(StudyPlanModules.untouchedAutoSQL) AND p.status IN ('geplant','nachholen')")
            .compactMap { $0["id"]?.int64 })
    }

    private static func truthy(_ v: SQLiteValue?) -> Bool { LocalModules.truthy(v) }

    private static func isNull(_ v: SQLiteValue?) -> Bool { v == nil || v == .null }

    /// `merge_duplicates(conn)`: fuehrt doppelt geplante Unterlagen zusammen. Ohne Doppel und ohne leere Pakete aendert
    /// der Aufruf nichts (keine Zeile wird angefasst).
    @discardableResult
    static func mergeDuplicates(_ c: SQLiteConnection) throws -> Result {
        var out = Result()
        let untouched = try untouched(c)
        // Paket ohne jede Aufgabe (seine Aufgaben stehen in der Planung des anderen Geraets): wie nach dem Verschieben
        // der letzten Aufgabe (`recalcPackage`) belegt es keine Uhrzeit mehr. Nicht loeschen: kaemen seine Aufgaben
        // noch, stellt `refreshStatuses` den Status wieder her.
        for p in try c.query("""
            SELECT p.id FROM study_packages p WHERE COALESCE(p.source,'')<>'smart'
            AND NOT EXISTS (SELECT 1 FROM study_tasks t WHERE t.package_id=p.id) ORDER BY p.id
            """) {
            guard let id = p["id"]?.int64, untouched.contains(id) else { continue }
            try StudyPlan.recalcPackage(c, .integer(id))
            out.empty += 1
        }
        let marks = Array(repeating: "?", count: cover.count).joined(separator: ",")
        let tasks = try c.query("""
            SELECT t.id, t.package_id, t.type, t.file_id, t.title, t.status, t.moved_from, t.done_at, t.actual_minutes, t.page_from, t.page_to,
                   t.steps_done, t.test_id, p.module_id, p.week_no, p.created_at AS planned_at
            FROM study_tasks t JOIN study_packages p ON p.id=t.package_id
            WHERE t.status IN (\(marks)) ORDER BY t.id
            """, cover.map { .text($0) })
        var groups: [String: [SQLiteRow]] = [:]
        var keys: [String] = []
        for t in tasks {
            let key: String
            if let file = t["file_id"]?.string, !file.isEmpty {
                key = "f\u{1f}" + file
            } else if let type = t["type"]?.string, single.contains(type), let m = t["module_id"]?.int64, let w = t["week_no"]?.int64 {
                key = "t\u{1f}\(m)\u{1f}\(w)\u{1f}\(type)"
            } else {
                continue                                        // freie Aufgaben ohne Datei: nie
            }
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(t)
        }
        keys = keys.filter { (groups[$0]?.count ?? 0) > 1 }
        if keys.isEmpty { return out }
        let history = try hasTable(c, "task_history")
            ? Set(try c.query("SELECT DISTINCT task_id FROM task_history").compactMap { $0["task_id"]?.int64 }) : []
        let remote = try remoteIDs(c, "study_tasks")

        func removable(_ t: SQLiteRow) -> Bool {
            guard let id = t["id"]?.int64, let pid = t["package_id"]?.int64, untouched.contains(pid), open.contains(t["status"]?.string ?? "") else { return false }
            let steps = t["steps_done"]
            let noSteps = isNull(steps) || steps?.string == "" || steps?.string == "[]"
            return isNull(t["moved_from"]) && isNull(t["done_at"]) && isNull(t["actual_minutes"]) && noSteps && isNull(t["test_id"]) && !history.contains(id)
        }

        var drop: [SQLiteRow] = []
        for key in keys {
            let file = key.hasPrefix("f")
            let ranked = (groups[key] ?? []).map { t in
                (row: t, free: removable(t), order: order(remote, id: t["id"]?.int64 ?? 0, plannedAt: t["planned_at"]?.string, touched: removable(t) ? 1 : 0))
            }.sorted { $0.order < $1.order }
            var kept: [(week: Int?, slot: Slot)] = []
            for x in ranked {
                let s = (week: x.row["week_no"]?.int,
                         slot: file ? slot(title: x.row["title"]?.string, pageFrom: x.row["page_from"]?.int, pageTo: x.row["page_to"]?.int) : Slot())
                if x.free && kept.contains(where: { samePlanned(s, $0) }) { drop.append(x.row) } else { kept.append(s) }
            }
        }
        if drop.isEmpty { return out }
        for t in drop { try c.execute("DELETE FROM study_tasks WHERE id=?", [t["id"] ?? .null]) }
        for pid in Set(drop.compactMap { $0["package_id"]?.int64 }).sorted() {
            guard let p = try c.queryOne("SELECT source, start_time, end_time FROM study_packages WHERE id=?", [.integer(pid)]) else { continue }
            // Block des Stundenplaners: bleibt als Lernzeit stehen, Dauer = Stundenbudget; Unterlagen fuellt der Planer nach
            if p["source"]?.string == "smart" { continue }
            if try c.queryOne("SELECT 1 FROM study_tasks WHERE package_id=?", [.integer(pid)]) == nil {
                try c.execute("DELETE FROM study_packages WHERE id=?", [.integer(pid)])
                out.packages += 1
                continue
            }
            try StudyPlan.recalcPackage(c, .integer(pid))
            // der Block reicht nur noch ueber die Aufgaben, die geblieben sind (nie laenger als vorher)
            let span = try c.queryOne("""
                SELECT MIN(start_time) a, MAX(end_time) b FROM study_tasks WHERE package_id=? AND start_time IS NOT NULL
                AND end_time IS NOT NULL AND status NOT IN ('erledigt','uebersprungen','verschoben')
                """, [.integer(pid)])
            if let ps = p["start_time"]?.string, let pe = p["end_time"]?.string, !ps.isEmpty, !pe.isEmpty,
               let sa = span?["a"]?.string, let sb = span?["b"]?.string, !sa.isEmpty, !sb.isEmpty {
                let a = PyText.less(sa, ps) ? ps : sa, b = PyText.less(pe, sb) ? pe : sb
                if PyText.less(a, b) && (a != ps || b != pe) {
                    try c.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?", [.text(a), .text(b), .integer(pid)])
                }
            }
        }
        out.tasks = drop.count
        return out
    }

    // MARK: Tageslimit ueber alle Geraete

    /// `balance_days(conn, today)`: Jedes Geraet prueft beim Einordnen nur die Pakete, die es kennt. Liegen an einem
    /// kuenftigen Tag danach Pakete aus dem Konto neben eigenen und ist der Tag damit ueber dem Limit (Lernzeit je Tag
    /// schon aufgebraucht, mehr Faecher als eingestellt) oder liegen zwei Bloecke uebereinander, weicht das zuletzt
    /// geplante unberuehrte automatische Paket: anderes freies Fenster bzw. der naechste Lerntag mit Platz. Welches
    /// weicht, haengt nur an abgeglichenen Werten (Anlagezeit, dann Nummer im Dienst), also auf jedem Geraet dasselbe. Von Hand
    /// Angelegtes, Begonnenes, Gesperrtes und Bloecke des Stundenplaners bleiben immer liegen. Heute bleibt, wie es ist.
    /// Liefert die Zahl verlegter Pakete.
    @discardableResult
    static func balanceDays(_ c: SQLiteConnection, today t0: Int) throws -> Int {
        guard try hasTable(c, "sync_link_map") else { return 0 }
        let iso = StudyPlan.iso
        let days = try c.query("""
            SELECT DISTINCT p.date FROM study_packages p WHERE p.date BETWEEN ? AND ?
            AND p.sync_device=? AND p.status='geplant' AND COALESCE(p.source,'')<>'smart'
            AND \(StudyPlanModules.untouchedAutoSQL)
            AND EXISTS (SELECT 1 FROM study_packages o WHERE o.date=p.date AND o.id<>p.id
                        AND COALESCE(o.sync_device,'')<>? AND o.status NOT IN ('verschoben','uebersprungen'))
            ORDER BY p.date
            """, [.text(iso(t0 + 1)), .text(iso(t0 + balanceDaysAhead)), .text(appliedDevice), .text(appliedDevice)]).compactMap { $0["date"]?.string }
        if days.isEmpty { return 0 }
        let s = try StudyPlan.Settings(c)
        let budget = s.minutesPerDay, subjectsMax = max(1, s.subjectsPerDay)
        let remote = try remoteIDs(c, "study_packages")
        var moved = 0

        func load(_ day: String) throws -> [SQLiteRow] {
            try c.query("SELECT * FROM study_packages WHERE date=? AND status NOT IN ('verschoben','uebersprungen') ORDER BY id", [.text(day)])
        }
        func subject(_ p: SQLiteRow) -> String {
            if let m = p["module_id"]?.int64 { return "m\(m)" }
            return "s" + (p["subject"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func minutes(_ p: SQLiteRow) -> Int { p["planned_minutes"]?.int ?? 0 }
        func span(_ p: SQLiteRow) -> (String, String)? {
            guard let a = p["start_time"]?.string, let b = p["end_time"]?.string, !a.isEmpty, !b.isEmpty else { return nil }
            return (a, b)
        }
        func unslot(_ id: Int64) throws {
            try c.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE id=?", [.integer(id)])
            try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id=? AND status NOT IN ('erledigt','uebersprungen','verschoben')", [.integer(id)])
        }
        func fits(_ day: Int, _ p: SQLiteRow) throws -> Bool {
            if !s.isLearnDay(day) { return false }
            if try LocalFreeWindows.compute(c, day: day, settings: s.raw).isEmpty { return false }
            let there = try load(iso(day))
            let subs = Set(there.map(subject))
            return there.reduce(0) { $0 + minutes($1) } + minutes(p) <= budget && (subs.contains(subject(p)) || subs.count < subjectsMax)
        }

        for day in days {
            guard let d = BerlinClock.parseISODate(day) else { continue }
            let movable = try untouched(c)
            let pkgs = try load(day)
            let canMove = pkgs.filter { p in
                guard let id = p["id"]?.int64 else { return false }
                return movable.contains(id) && p["status"]?.string == "geplant" && (p["source"]?.string ?? "") != "smart"
            }
            let ids = Set(canMove.compactMap { $0["id"]?.int64 })
            let stay = pkgs.filter { !ids.contains($0["id"]?.int64 ?? -1) }
            var used = stay.reduce(0) { $0 + minutes($1) }
            var subs = Set(stay.map(subject))
            var spans = stay.compactMap(span)
            // zuerst geplant bleibt zuerst liegen. Anders als beim Zusammenfuehren zaehlt hier nicht, ob die Zeile schon
            // im Konto steht: sonst verlegte jedes der beiden Geraete sein eigenes, noch nicht gesendetes Paket.
            let ordered = canMove.map { (row: $0, order: order(remote, id: $0["id"]?.int64 ?? 0, plannedAt: $0["created_at"]?.string)) }
                .sorted { a, b in
                    if a.order.plannedAt != b.order.plannedAt { return PyText.less(a.order.plannedAt, b.order.plannedAt) }
                    if a.order.local != b.order.local { return a.order.local < b.order.local }
                    return a.order.number != b.order.number ? a.order.number < b.order.number : a.order.id < b.order.id
                }.map(\.row)
            for first in ordered {
                var p = first
                guard let id = p["id"]?.int64 else { continue }
                if used < budget && (subs.contains(subject(p)) || subs.count < subjectsMax) {
                    if let (a, b) = span(p), spans.contains(where: { PyText.less(a, $0.1) && PyText.less($0.0, b) }) {
                        try unslot(id)                          // zwei Bloecke uebereinander: neues freies Fenster
                        try StudyPlan.assignSlots(c, day: d, packageID: .integer(id), spill: StudyPlan.spillDays)
                        moved += 1
                        guard let now = try c.queryOne("SELECT * FROM study_packages WHERE id=?", [.integer(id)]), now["date"]?.string == day else {
                            continue                            // kein Platz mehr an diesem Tag: liegt jetzt spaeter
                        }
                        p = now
                    }
                    used += minutes(p)
                    subs.insert(subject(p))
                    if let x = span(p) { spans.append(x) }
                    continue
                }
                var target: Int?
                var n = 0, e = d
                while n < StudyPlan.spillDays && target == nil && e - d < 60 {
                    e += 1
                    if !s.isLearnDay(e) { continue }
                    n += 1
                    if try fits(e, p) { target = e }
                }
                guard let target else { continue }              // nirgends Platz: bleibt, wo es ist
                try unslot(id)
                try c.execute("UPDATE study_packages SET date=? WHERE id=?", [.text(iso(target)), .integer(id)])
                try StudyPlan.assignSlots(c, day: target, packageID: .integer(id), spill: StudyPlan.spillDays)
                moved += 1
            }
        }
        return moved
    }

    /// `after_pull`: nach dem Abruf vom Konto und vor dem Senden zusammenfuehren, dann das Tageslimit pruefen
    @discardableResult
    static func afterPull(_ c: SQLiteConnection, today: Int) throws -> Result {
        var out = try mergeDuplicates(c)
        out.moved = try balanceDays(c, today: today)
        return out
    }
}
