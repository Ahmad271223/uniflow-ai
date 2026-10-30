import Foundation

/// Entscheidung fuer den Hintergrundlauf der Wochentests auf dem iPad (BGProcessingTask, 8, 15 und 20 Uhr Ortszeit) wie
/// app/weekly.py, Abschnitt "Hintergrundlauf": `slot_at_or_after`, `next_slot`, `background_snapshot` und
/// `background_decision`. Reine Logik aus Uhrzeit und Stand der Plaene, damit Python und Swift dieselbe Antwort geben
/// (Pruefdaten packages/shared-contracts/fixtures/local-backend/weekly.json, Schritte "background" und
/// "background_cases"). Zeiten sind naive Ortszeit in Sekunden wie `Weekly.seconds`/`Weekly.iso` (Kalendertage ohne
/// Zone, darum gilt um die Zeitumstellung weiter 8:00 Ortszeit wie bei `BackgroundSchedule.next`).
///
/// Die Anbindung an die App (BGTaskScheduler, Anmelden des naechsten Termins, Start des Laufs) kommt spaeter in
/// UniFlow/Services und gehoert nicht hierher.
public enum WeeklyBackground {
    /// `BACKGROUND_HOURS`: dieselben Termine wie der Hintergrundabgleich
    public static let hours: [Int] = BackgroundSchedule.hours
    /// `OPEN_STATES`
    static let openStates: Set<String> = ["geplant", "wartet", "fehlgeschlagen"]
    /// `MAX_ATTEMPTS`
    static let maxAttempts = 3

    /// `slot_at_or_after(t, hours)`: erster Termin aus `hours` (volle Stunde) am Tag von `t` ab `t` einschliesslich,
    /// sonst der erste Termin am naechsten Tag
    static func slot(atOrAfter t: Int, hours: [Int] = hours) -> Int {
        let day = Weekly.today(t)
        for h in Set(hours).sorted() {
            let s = day * 86_400 + h * 3600
            if s >= t { return s }
        }
        return (day + 1) * 86_400 + (hours.min() ?? 0) * 3600
    }

    /// `next_slot(now, hours)`: naechster Termin streng nach `now` (wie `BackgroundSchedule.next`)
    static func nextSlot(_ now: Int, hours: [Int] = hours) -> Int {
        slot(atOrAfter: now + 1, hours: hours)
    }

    /// `background_snapshot(conn, now)`: nur lesen, alles, was `decide` braucht. `reusable` = es gibt schon einen
    /// geprueften oder veroeffentlichten Test mit demselben Stoffumfang (dann zaehlt das Tageslimit nicht, wie in
    /// `processPlan`).
    static func snapshot(_ c: SQLiteConnection, now: Int) throws -> JSONValue {
        let s = try Weekly.settings(c)
        let auto = try c.scalar("SELECT value FROM settings WHERE key='auto_tests'")?.string ?? "1"
        let todayN = try c.scalar("SELECT COUNT(*) AS n FROM wt_defs WHERE substr(created_at,1,10)=?",
                                  [.text(BerlinClock.isoDate(Weekly.today(now)))])?.int ?? 0
        var plans: [JSONValue] = []
        for p in try c.rows("SELECT * FROM wt_plans WHERE status IN ('geplant','wartet','fehlgeschlagen') ORDER BY id") {
            let reuse = try c.scalar("""
                SELECT id FROM wt_defs WHERE kind='wochentest' AND module_id=? AND scope_key=? AND status IN ('geprueft','veroeffentlicht') LIMIT 1
                """, [SQLiteValue(json: p["module_id"] ?? .null) ?? .null, SQLiteValue(json: p["scope_key"] ?? .null) ?? .null])
            plans.append(.object([
                "id": p["id"] ?? .null, "status": p["status"] ?? .null, "publish_at": p["publish_at"] ?? .null,
                "deadline_at": p["deadline_at"] ?? .null, "attempts": .number(Double(p["attempts"]?.int ?? 0)),
                "lock_until": p["lock_until"] ?? .null, "reusable": .bool(reuse != nil),
            ]))
        }
        return .object(["auto_tests": .bool(auto == "1"), "daily_limit": .number(Double(s.dailyLimit)),
                        "today_defs": .number(Double(todayN)), "plans": .array(plans)])
    }

    /// `background_decision(snap, now, ai, busy, hours)`: was ein Hintergrundlauf um `now` taete und wann der naechste
    /// fruehestens noetig ist.
    ///
    /// action: off (auto_tests aus), no_ai (keine KI verbunden), busy (anderer Auftrag laeuft), limit (faellig, aber
    /// Tageslimit erreicht und nichts wiederverwendbar), run (mindestens ein Plan faellig), idle (nichts faellig).
    /// due: die faelligen Plaene, genau die Bedingung aus `tick` und `claim` (offen, publish_at <= now, attempts < 3,
    /// keine laufende Sperre). next_at: naechster Termin aus `hours`, an dem es etwas zu tun geben kann, null wenn
    /// kein offener Plan mit Versuchen uebrig ist oder auto_tests aus ist. Die Reihenfolge off, no_ai, busy ist die
    /// von `WeeklyAutoTick.run`.
    public static func decide(_ snapshot: JSONValue, now: Int, ai: Bool, busy: Bool, hours: [Int] = hours) -> JSONValue {
        var action = "idle"
        var due: [JSONValue] = []
        guard snapshot["auto_tests"]?.bool ?? true else {
            return .object(["action": .string("off"), "due": .array([]), "next_at": .null])
        }
        var next: [Int] = []
        var reusable = false
        for p in snapshot["plans"]?.array ?? [] {
            guard let status = p["status"]?.string, openStates.contains(status), integer(p["attempts"]) < maxAttempts else { continue }
            let lock = p["lock_until"]?.string.flatMap { $0.isEmpty ? nil : Weekly.seconds($0) }
            let pub = p["publish_at"]?.string.flatMap(Weekly.seconds) ?? now
            if let lock, lock >= now {
                next.append(nextSlot(lock, hours: hours))                   // `claim` braucht lock_until < now
            } else if pub > now {
                next.append(slot(atOrAfter: pub, hours: hours))
            } else {
                due.append(p["id"] ?? .null)
                reusable = reusable || (p["reusable"]?.bool ?? false)
            }
        }
        if !due.isEmpty {
            if integer(snapshot["today_defs"]) >= integer(snapshot["daily_limit"]) && !reusable {
                action = "limit"                                            // erst morgen zaehlt das Tageslimit neu
                next.append(slot(atOrAfter: (Weekly.today(now) + 1) * 86_400, hours: hours))
            } else {
                action = "run"
                next.append(nextSlot(now, hours: hours))                    // wartend oder fehlgeschlagen: beim naechsten Termin wieder
            }
        }
        if !ai {
            action = "no_ai"
        } else if busy {
            action = "busy"
        }
        return .object(["action": .string(action), "due": .array(due), "next_at": next.min().map { .string(Weekly.iso($0)) } ?? .null])
    }

    /// `int(v)` fuer Zahlen und Zahlentexte, sonst 0
    static func integer(_ v: JSONValue?) -> Int {
        if let i = v?.int { return i }
        if let s = v?.string, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        return 0
    }
}
