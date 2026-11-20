import Foundation
import UniFlowCore

// Mitteilungen wie bei Studo (Version 1.3/1.4, Entscheidung des Inhabers 11.11.2026; docs/BENACHRICHTIGUNGEN-1-3.md).
// Der Hintergrundlauf (`BackgroundSyncController.perform`, am Mac zusaetzlich `MacBackgroundTicker`) liest vor und nach
// dem Abgleich denselben kleinen Ausschnitt der Datenbank (`BackgroundNewsSnapshot`) und meldet, was dazukam:
// - neue Noten: Vergleich mit dem gespeicherten Notenspiegel (Tabelle grades, QIS der LUH und LSF der Uni Hildesheim).
//   "Neue Note in <Modul> eingetragen"; den Notenwert nur mit dem eigenen Schalter. Nie beim ersten Notenspiegel.
// - Stud.IP-Nachrichten: nur die Zahl, nie Absender oder Betreff (wie bei der Uni-Mail)
// - Ankuendigungen (Stud.IP-News, Learnweb-Ankuendigungen): Kurs und Ueberschrift
// - seit 17.11.2026 (Auftrag des Inhabers, Abgleich 8 bis 18 Uhr): Ausfall, Raumaenderung oder Verlegung eines besuchten
//   Termins von heute oder morgen (`ScheduleSnapshot` im Kern); neue Noten nur noch "Neue Note eingetragen" - ohne Note
//   und ohne Modul (Sperrbildschirm). Anknuepfungspunkt fuer "Neuer Klausurtermin erkannt": `BackgroundNews.extraNotices`
//   (macht ein anderer Zweig, nur ab Pro AI).
// Jede Art hat einen eigenen Schalter (Vorgabe aus; erst der Schalter fragt iOS nach der Erlaubnis). Nachrichten und
// Ankuendigungen zaehlen nur, wenn sie juenger als 14 Tage sind (ein neu gewaehlter Kurs bringt keine Flut alter Beitraege).
//
// Stille Neuanmeldung im Hintergrund (`BackgroundReloginLedger`): nur mit gespeichertem Uni-Zugang (Schluesselbund
// dieses Geraets, `UniAutoLogin`; das Passwort geht nie an einen StudiNow-Server) und eigenem Schalter (Vorgabe an).
// Je Dienst hoechstens ein Versuch je Lauf und in 30 Minuten (bis 17.11.2026: 6 Stunden); nach einem Fehlschlag seit
// 20.11.2026 keiner mehr, bis die Anmeldung bei offener App gelang (vorher 24 Stunden Pause); ein abgelehntes Passwort
// vergisst `UniAutoLogin` sofort (nie ein zweiter Versuch damit, Schutz vor einer Kontosperre).

/// Schalter der Mitteilungen (UserDefaults der App, fuer dieses Geraet)
struct BackgroundNewsSettings {
    static let gradesKey = "uniflow.background.notify.grades"
    static let gradeValueKey = "uniflow.background.notify.gradeValue"
    static let messagesKey = "uniflow.background.notify.messages"
    static let announcementsKey = "uniflow.background.notify.announcements"
    static let scheduleKey = "uniflow.background.notify.schedule"
    static let reloginKey = "uniflow.background.relogin"

    let defaults: UserDefaults

    /// "Neue Noten" (Vorgabe aus)
    var grades: Bool {
        get { defaults.bool(forKey: Self.gradesKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.gradesKey) }
    }

    /// frueher "Notenwert in der Mitteilung zeigen"; seit 17.11.2026 ohne Wirkung (die Mitteilung nennt nie Note oder Modul)
    var gradeValue: Bool {
        get { defaults.bool(forKey: Self.gradeValueKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.gradeValueKey) }
    }

    /// "Stud.IP-Nachrichten" (Vorgabe aus)
    var messages: Bool {
        get { defaults.bool(forKey: Self.messagesKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.messagesKey) }
    }

    /// "Ankündigungen" (Vorgabe aus)
    var announcements: Bool {
        get { defaults.bool(forKey: Self.announcementsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.announcementsKey) }
    }

    /// "Ausfall und Raumänderung" heute und morgen (Vorgabe aus)
    var schedule: Bool {
        get { defaults.bool(forKey: Self.scheduleKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.scheduleKey) }
    }

    /// "Im Hintergrund neu anmelden" (Vorgabe an; wirkt nur mit gespeichertem Uni-Zugang und "Automatisch anmelden")
    var relogin: Bool {
        get { defaults.object(forKey: Self.reloginKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.reloginKey) }
    }

    var anyOn: Bool { grades || messages || announcements || schedule }

    func isOn(_ kind: BackgroundNewsKind) -> Bool {
        switch kind {
        case .grades: return grades
        case .messages: return messages
        case .announcements: return announcements
        case .schedule: return schedule
        }
    }

    func set(_ kind: BackgroundNewsKind, _ on: Bool) {
        switch kind {
        case .grades: grades = on
        case .messages: messages = on
        case .announcements: announcements = on
        case .schedule: schedule = on
        }
    }
}

/// Arten der Mitteilungen mit eigenem Schalter
enum BackgroundNewsKind: CaseIterable {
    case schedule, grades, messages, announcements
}

/// Eine Zeile des Notenspiegels
struct GradeEntry: Equatable, Sendable {
    /// Pruefungsnummer, Text, Semester, Versuch (Schluessel der Tabelle grades)
    let key: String
    let module: String
    let note: String
    let status: String
    /// Text, Semester, Versuch ohne Nummer: seit 12.11.2026 liest der Notenspiegel die Pruefungsnummer auch aus der
    /// ersten Spalte ("PrfNr."); eine bekannte Leistung, die dadurch erst jetzt eine Nummer hat, ist keine neue Note
    var looseKey: String? = nil

    /// Steht ein Ergebnis da (Note oder bestanden/nicht bestanden)? "angemeldet" ist keins.
    var hasResult: Bool {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty, n != "-" { return true }
        let s = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.contains("bestanden") || ["be", "nb", "en"].contains(s)
    }
}

/// Eine Ankuendigung (Tabelle announcements)
struct NewsAnnouncement: Equatable, Sendable {
    let id: String
    let title: String
    /// Kurstitel; nil: Stud.IP-weite Ankuendigung
    let course: String?
    let postedAt: Date?
}

/// Ausschnitt der Datenbank vor bzw. nach einem Hintergrundlauf
struct BackgroundNewsSnapshot: Equatable, Sendable {
    var grades: [GradeEntry] = []
    /// gab es schon einen gelungenen Notenabruf (oder Noten)? Sonst ist der naechste Notenspiegel der erste: nie melden
    var gradesKnown = false
    /// Stud.IP-Nachrichten: Kennung -> gesendet
    var messages: [String: Date?] = [:]
    var announcements: [NewsAnnouncement] = []
    /// besuchte Termine von heute und morgen (nil: nicht gelesen)
    var schedule: ScheduleSnapshot?

    /// Liest den Ausschnitt; fehlende Tabellen (noch nie Nachrichten gelesen) sind leer. `clock`: heute und morgen fuer
    /// die Termine (nil: ohne Termine)
    static func read(_ db: SQLiteDatabase, clock: UniFlowClock? = nil) async -> BackgroundNewsSnapshot {
        (try? await db.withConnection { conn -> BackgroundNewsSnapshot in
            var s = BackgroundNewsSnapshot()
            if let clock { s.schedule = ScheduleSnapshot.read(conn, clock: clock) }
            let rows = (try? conn.query("SELECT pruefungsnr, text, semester, versuch, note, status FROM grades")) ?? []
            s.grades = rows.map { r in
                let key = ["pruefungsnr", "text", "semester", "versuch"].map { r[$0]?.string ?? "" }.joined(separator: "\u{1}")
                let loose = ["text", "semester", "versuch"].map { r[$0]?.string ?? "" }.joined(separator: "\u{1}")
                return GradeEntry(key: key, module: r["text"]?.string ?? "", note: r["note"]?.string ?? "", status: r["status"]?.string ?? "",
                                  looseKey: loose)
            }
            let runs = (try? conn.scalar("SELECT COUNT(*) FROM qis_runs WHERE ok = 1"))?.int ?? 0
            s.gradesKnown = runs > 0 || !s.grades.isEmpty
            for r in (try? conn.query("SELECT id, sent_at FROM studip_messages")) ?? [] {
                guard let id = r["id"]?.string else { continue }
                s.messages[id] = BackgroundNews.date(r["sent_at"]?.string)
            }
            let news = (try? conn.query("""
                SELECT a.id, a.title, a.posted_at, c.title AS course FROM announcements a LEFT JOIN courses c ON c.id = a.course_id
                """)) ?? []
            s.announcements = news.compactMap { r in
                guard let id = r["id"]?.string else { return nil }
                let course = r["course"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                return NewsAnnouncement(id: id, title: r["title"]?.string ?? "", course: course, postedAt: BackgroundNews.date(r["posted_at"]?.string))
            }
            return s
        }) ?? BackgroundNewsSnapshot()
    }
}

/// Was ein Lauf Neues brachte
struct BackgroundNewsDiff: Equatable, Sendable {
    var newGrades: [GradeEntry] = []
    var newMessages = 0
    var newAnnouncements: [NewsAnnouncement] = []
    var scheduleChanges: [ScheduleChange] = []

    var isEmpty: Bool { newGrades.isEmpty && newMessages == 0 && newAnnouncements.isEmpty && scheduleChanges.isEmpty }
}

enum BackgroundNews {
    /// Nachrichten und Ankuendigungen zaehlen nur, wenn sie juenger sind
    static let maxAge: TimeInterval = 14 * 86400
    /// Mehr Einzelmitteilungen je Art und Lauf gibt es nicht (sonst eine Zusammenfassung)
    static let maxSingle = 3

    /// Anknuepfungspunkt fuer weitere Arten (z. B. "Neuer Klausurtermin erkannt", anderer Zweig, nur ab Pro AI): bekommt
    /// den Stand vor und nach dem Lauf und die Kennung des Containers, liefert Mitteilungen (Kennung ohne Praefix,
    /// Inhalt). Die App ruft ihn nur im Hintergrundlauf nach einem Abgleich von selbst; den Tarif prueft der Anbieter.
    @MainActor static var extraNotices: ((BackgroundNewsSnapshot, BackgroundNewsSnapshot, String) async -> [(id: String, content: BackgroundNotice.Content)])?

    static func diff(before: BackgroundNewsSnapshot, after: BackgroundNewsSnapshot, now: Date) -> BackgroundNewsDiff {
        var d = BackgroundNewsDiff()
        d.scheduleChanges = ScheduleSnapshot.changes(before: before.schedule, after: after.schedule)
        if before.gradesKnown {
            let had = Set(before.grades.filter(\.hasResult).map(\.key))
            // bekannt ohne Nummer (vor 12.11.2026 gespeichert), jetzt mit Nummer: nicht neu
            let hadLoose = Set(before.grades.filter { $0.hasResult && $0.key.hasPrefix("\u{1}") }.compactMap(\.looseKey))
            d.newGrades = after.grades.filter { g in
                g.hasResult && !had.contains(g.key) && !(g.looseKey.map(hadLoose.contains) ?? false)
            }
        }
        func recent(_ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) < maxAge } ?? true }
        d.newMessages = after.messages.filter { before.messages[$0.key] == nil && recent($0.value) }.count
        let known = Set(before.announcements.map(\.id))
        d.newAnnouncements = after.announcements.filter { !known.contains($0.id) && recent($0.postedAt) }
            .sorted { ($0.postedAt ?? .distantFuture) < ($1.postedAt ?? .distantFuture) }
        return d
    }

    /// Mitteilungen eines Laufs nach den Schaltern: (Kennung ohne Praefix, Inhalt). Gleiche Kennung ersetzt die alte.
    /// `platform`: woher die Nachrichten kommen ("Stud.IP", an der Uni Hildesheim "Learnweb", 12.11.2026)
    static func notices(_ d: BackgroundNewsDiff, settings: BackgroundNewsSettings, container: String,
                        platform: String = "Stud.IP") -> [(id: String, content: BackgroundNotice.Content)] {
        var out: [(String, BackgroundNotice.Content)] = []
        // Ausfall, Raumaenderung, Verlegung (heute, morgen): einzeln bis drei, sonst eine Zusammenfassung
        if settings.schedule, !d.scheduleChanges.isEmpty {
            if d.scheduleChanges.count > maxSingle, let n = BackgroundNotice.scheduleChanges(d.scheduleChanges.count) {
                out.append(("schedule.\(container).\(stableID(d.scheduleChanges.map(\.id).joined(separator: ",")))", n))
            } else {
                for c in d.scheduleChanges { out.append(("schedule.\(container).\(stableID(c.id))", BackgroundNotice.scheduleChange(c))) }
            }
        }
        // neue Noten: nie Note, nie Modul (Sperrbildschirm, Auftrag 17.11.2026); eine Mitteilung je Lauf
        if settings.grades, !d.newGrades.isEmpty {
            let id = "grades.\(container).\(stableID(d.newGrades.map(\.key).sorted().joined(separator: ",")))"
            if d.newGrades.count == 1 { out.append((id, BackgroundNotice.newGrade)) } else if let n = BackgroundNotice.newGrades(d.newGrades.count) { out.append((id, n)) }
        }
        if settings.messages, let n = BackgroundNotice.newStudIPMessages(d.newMessages, platform: platform) {
            out.append(("messages.\(container)", n))
        }
        if settings.announcements, !d.newAnnouncements.isEmpty {
            if d.newAnnouncements.count > maxSingle, let n = BackgroundNotice.newAnnouncements(d.newAnnouncements.count) {
                out.append(("news.\(container)", n))
            } else {
                for a in d.newAnnouncements { out.append(("news.\(container).\(stableID(a.id))", BackgroundNotice.newAnnouncement(a))) }
            }
        }
        return out
    }

    /// Kurze, feste Kennung (FNV-1a) fuer Mitteilungs-Kennungen: nie Modulnamen oder Texte in Kennungen
    static func stableID(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// ISO-8601 mit oder ohne Zeitzone (ohne: Berliner Zeit)
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        for (format, part) in [("yyyy-MM-dd'T'HH:mm:ss", s.prefix(19)), ("yyyy-MM-dd HH:mm:ss", s.prefix(19)), ("yyyy-MM-dd", s.prefix(10))] {
            f.dateFormat = format
            if let d = f.date(from: String(part)) { return d }
        }
        return nil
    }
}

extension BackgroundNotice {
    /// Eine neue Note: nur "Neue Note eingetragen" - ohne Note und ohne Modul (Sperrbildschirm, Auftrag 17.11.2026)
    static let newGrade = Content(title: "Neue Note eingetragen", body: "Öffne StudiNow, um sie zu sehen.")

    /// Mehrere neue Noten in einem Lauf: nur die Zahl
    static func newGrades(_ count: Int) -> Content? {
        guard count > 0 else { return nil }
        guard count > 1 else { return newGrade }
        return Content(title: "Neue Noten eingetragen", body: "\(count) neue Noten eingetragen. Öffne StudiNow, um sie zu sehen.")
    }

    /// Ausfall, Raumaenderung oder Verlegung eines besuchten Termins heute oder morgen
    static func scheduleChange(_ c: ScheduleChange) -> Content {
        let day = c.today ? "heute" : "morgen"
        let title = c.entry.title.isEmpty ? "Termin" : c.entry.title
        let time = c.entry.start.isEmpty ? "" : " um \(c.entry.start.prefix(5)) Uhr"
        switch c.kind {
        case .cancelled:
            return Content(title: "Ausfall \(day)", body: "\(title)\(time) fällt aus.")
        case .room:
            return Content(title: "Raumänderung \(day)", body: "\(title)\(time): jetzt in \(c.entry.room).")
        case .moved:
            if !c.entry.movedTo.isEmpty, let d = BackgroundNews.date(c.entry.movedTo) {
                let f = DateFormatter()
                f.locale = Locale(identifier: "de_DE")
                f.timeZone = TimeZone(identifier: "Europe/Berlin")
                f.dateFormat = "EEEE, d.M."
                return Content(title: "Verlegung \(day)", body: "\(title) ist verlegt auf \(f.string(from: d)).")
            }
            return Content(title: "Verlegung \(day)", body: "\(title) beginnt jetzt\(time).")
        }
    }

    /// Mehr als drei Aenderungen in einem Lauf: nur die Zahl
    static func scheduleChanges(_ count: Int) -> Content? {
        guard count > 0 else { return nil }
        return Content(title: "Änderungen im Stundenplan", body: "\(count) Termine heute oder morgen haben sich geändert.")
    }

    /// Nur die Zahl, nie Absender oder Betreff
    static func newStudIPMessages(_ count: Int, platform: String = "Stud.IP") -> Content? {
        guard count > 0 else { return nil }
        return Content(title: "Neue \(platform)-Nachricht", body: count == 1 ? "1 neue Nachricht in \(platform)" : "\(count) neue Nachrichten in \(platform)")
    }

    static func newAnnouncement(_ a: NewsAnnouncement) -> Content {
        Content(title: "Neue Ankündigung in \(a.course ?? "Stud.IP")", body: a.title.isEmpty ? "Öffne StudiNow, um sie zu lesen." : a.title)
    }

    static func newAnnouncements(_ count: Int) -> Content? {
        guard count > 0 else { return nil }
        return Content(title: "Neue Ankündigungen", body: "\(count) neue Ankündigungen")
    }

    /// Bitte um Anmeldung; hat der Lauf die stille Neuanmeldung mit dem gespeicherten Uni-Zugang versucht, sagt der Text das
    static func loginNeeded(_ sources: [String], reloginTried: Bool) -> Content? {
        guard reloginTried, let base = loginNeeded(sources) else { return loginNeeded(sources) }
        return Content(title: base.title,
                       body: "Die Anmeldung ist abgelaufen und ließ sich mit dem gespeicherten Uni-Zugang nicht erneuern. Öffne StudiNow und melde dich neu an, dann geht der Abgleich weiter.")
    }
}

/// Wann im Hintergrund still neu angemeldet werden darf (je Dienst, Stand in der Einstellungs-Suite des Containers,
/// damit er Neustarts der App durch iOS uebersteht).
/// Seit 20.11.2026 (docs/HINTERGRUND-ANMELDUNG-2026-11-20.md, Schutz vor einer Kontosperre): nach einem gescheiterten
/// Versuch (abgelehnt, Captcha, zweiter Faktor, unerwartete Seite, Zeit um) gar kein Versuch im Hintergrund mehr, bis
/// die Anmeldung dieses Dienstes bei offener App gelungen ist (`foregroundSucceeded`); vorher 24 Stunden Pause.
/// Ein von iOS abgebrochener Versuch zaehlt nicht als Fehlschlag (nur 30 Minuten Pause); nach `maxAborts` Abbruechen in
/// Folge gilt er doch als gescheitert (ein abgebrochener Versuch kann das Passwort schon gesendet haben).
struct BackgroundReloginLedger {
    /// nach einem gelungenen oder abgebrochenen Versuch: im Takt der Regel (30 Minuten, Auftrag 17.11.2026)
    static let minInterval: TimeInterval = AutoSyncSchedule.standard.interval
    /// so viele von iOS abgebrochene Versuche in Folge, dann wie ein Fehlschlag
    static let maxAborts = 3
    static let prefix = "uniflow.background.relogin."

    let defaults: UserDefaults

    private func key(_ portal: String, _ k: String) -> String { Self.prefix + portal + "." + k }

    func mayTry(_ portal: String, now: Date) -> Bool {
        if blocked(portal) { return false }
        guard let last = defaults.object(forKey: key(portal, "at")) as? Date else { return true }
        return now.timeIntervalSince(last) >= Self.minInterval
    }

    /// Gesperrt bis zur naechsten gelungenen Anmeldung im Vordergrund
    func blocked(_ portal: String) -> Bool { defaults.bool(forKey: key(portal, "failed")) }

    func record(_ portal: String, ok: Bool, now: Date) {
        defaults.set(now, forKey: key(portal, "at"))
        defaults.set(!ok, forKey: key(portal, "failed"))
        defaults.removeObject(forKey: key(portal, "aborts"))
    }

    /// iOS hat die Zeit beendet, waehrend der Versuch lief: kein Fehlschlag, kein weiterer Versuch in diesem Lauf
    func recordAborted(_ portal: String, now: Date) {
        defaults.set(now, forKey: key(portal, "at"))
        let n = defaults.integer(forKey: key(portal, "aborts")) + 1
        defaults.set(n, forKey: key(portal, "aborts"))
        if n >= Self.maxAborts { defaults.set(true, forKey: key(portal, "failed")) }
    }

    /// Anmeldung dieses Dienstes bei offener App gelungen: Sperre und Pause weg
    func foregroundSucceeded(_ portal: String) {
        for k in ["at", "failed", "aborts"] { defaults.removeObject(forKey: key(portal, k)) }
    }

    /// Aufruf aus den Verbindungen nach jeder gelungenen Anmeldung bzw. jedem gelungenen Abruf: wirkt nur bei offener
    /// App (`UniAutoLogin.appActive`), nie aus einem Hintergrundlauf
    @MainActor
    static func foregroundSuccess(_ portal: String, defaults: UserDefaults) {
        guard UniAutoLogin.appActive else { return }
        let l = BackgroundReloginLedger(defaults: defaults)
        guard defaults.object(forKey: l.key(portal, "at")) != nil || l.blocked(portal) else { return }
        l.foregroundSucceeded(portal)
    }
}
