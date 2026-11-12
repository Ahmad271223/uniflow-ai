import Foundation
import UniFlowCore

// Mitteilungen wie bei Studo (Version 1.3/1.4, Entscheidung des Inhabers 11.11.2026; docs/BENACHRICHTIGUNGEN-1-3.md).
// Der Hintergrundlauf (`BackgroundSyncController.perform`, am Mac zusaetzlich `MacBackgroundTicker`) liest vor und nach
// dem Abgleich denselben kleinen Ausschnitt der Datenbank (`BackgroundNewsSnapshot`) und meldet, was dazukam:
// - neue Noten: Vergleich mit dem gespeicherten Notenspiegel (Tabelle grades, QIS der LUH und LSF der Uni Hildesheim).
//   "Neue Note in <Modul> eingetragen"; den Notenwert nur mit dem eigenen Schalter. Nie beim ersten Notenspiegel.
// - Stud.IP-Nachrichten: nur die Zahl, nie Absender oder Betreff (wie bei der Uni-Mail)
// - Ankuendigungen (Stud.IP-News, Learnweb-Ankuendigungen): Kurs und Ueberschrift
// Jede Art hat einen eigenen Schalter (Vorgabe aus; erst der Schalter fragt iOS nach der Erlaubnis). Nachrichten und
// Ankuendigungen zaehlen nur, wenn sie juenger als 14 Tage sind (ein neu gewaehlter Kurs bringt keine Flut alter Beitraege).
//
// Stille Neuanmeldung im Hintergrund (`BackgroundReloginLedger`): nur mit gespeichertem Uni-Zugang (Schluesselbund
// dieses Geraets, `UniAutoLogin`; das Passwort geht nie an einen StudiNow-Server) und eigenem Schalter (Vorgabe an).
// Je Dienst hoechstens ein Versuch in 6 Stunden, nach einem Fehlschlag erst nach 24 Stunden wieder; ein abgelehntes
// Passwort vergisst `UniAutoLogin` sofort (nie ein zweiter Versuch damit, Schutz vor einer Kontosperre).

/// Schalter der Mitteilungen (UserDefaults der App, fuer dieses Geraet)
struct BackgroundNewsSettings {
    static let gradesKey = "uniflow.background.notify.grades"
    static let gradeValueKey = "uniflow.background.notify.gradeValue"
    static let messagesKey = "uniflow.background.notify.messages"
    static let announcementsKey = "uniflow.background.notify.announcements"
    static let reloginKey = "uniflow.background.relogin"

    let defaults: UserDefaults

    /// "Neue Noten" (Vorgabe aus)
    var grades: Bool {
        get { defaults.bool(forKey: Self.gradesKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.gradesKey) }
    }

    /// "Notenwert in der Mitteilung zeigen" (Vorgabe aus: sonst stuende die Note auf dem Sperrbildschirm)
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

    /// "Im Hintergrund neu anmelden" (Vorgabe an; wirkt nur mit gespeichertem Uni-Zugang und "Automatisch anmelden")
    var relogin: Bool {
        get { defaults.object(forKey: Self.reloginKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.reloginKey) }
    }

    var anyOn: Bool { grades || messages || announcements }

    func isOn(_ kind: BackgroundNewsKind) -> Bool {
        switch kind {
        case .grades: return grades
        case .messages: return messages
        case .announcements: return announcements
        }
    }

    func set(_ kind: BackgroundNewsKind, _ on: Bool) {
        switch kind {
        case .grades: grades = on
        case .messages: messages = on
        case .announcements: announcements = on
        }
    }
}

/// Arten der Mitteilungen mit eigenem Schalter
enum BackgroundNewsKind: CaseIterable {
    case grades, messages, announcements
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

    /// Liest den Ausschnitt; fehlende Tabellen (noch nie Nachrichten gelesen) sind leer
    static func read(_ db: SQLiteDatabase) async -> BackgroundNewsSnapshot {
        (try? await db.withConnection { conn -> BackgroundNewsSnapshot in
            var s = BackgroundNewsSnapshot()
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

    var isEmpty: Bool { newGrades.isEmpty && newMessages == 0 && newAnnouncements.isEmpty }
}

enum BackgroundNews {
    /// Nachrichten und Ankuendigungen zaehlen nur, wenn sie juenger sind
    static let maxAge: TimeInterval = 14 * 86400
    /// Mehr Einzelmitteilungen je Art und Lauf gibt es nicht (sonst eine Zusammenfassung)
    static let maxSingle = 3

    static func diff(before: BackgroundNewsSnapshot, after: BackgroundNewsSnapshot, now: Date) -> BackgroundNewsDiff {
        var d = BackgroundNewsDiff()
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
    static func notices(_ d: BackgroundNewsDiff, settings: BackgroundNewsSettings, container: String) -> [(id: String, content: BackgroundNotice.Content)] {
        var out: [(String, BackgroundNotice.Content)] = []
        if settings.grades, !d.newGrades.isEmpty {
            if d.newGrades.count > maxSingle, let n = BackgroundNotice.newGrades(d.newGrades.count) {
                out.append(("grades.\(container)", n))
            } else {
                for g in d.newGrades {
                    let value = settings.gradeValue ? g.note.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    out.append(("grade.\(container).\(stableID(g.key))", BackgroundNotice.newGrade(module: g.module, value: value.isEmpty ? nil : value)))
                }
            }
        }
        if settings.messages, let n = BackgroundNotice.newStudIPMessages(d.newMessages) {
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
    /// "Neue Note in <Modul> eingetragen" (mit `value` nur, wenn der Schalter "Notenwert zeigen" an ist)
    static func newGrade(module: String, value: String?) -> Content {
        let base = "Neue Note in \(module) eingetragen"
        return Content(title: "Neue Note", body: value.map { "\(base): \($0)" } ?? base)
    }

    /// Mehr als drei neue Noten in einem Lauf: eine Zusammenfassung ohne Module
    static func newGrades(_ count: Int) -> Content? {
        guard count > 0 else { return nil }
        return Content(title: "Neue Noten", body: "\(count) neue Noten eingetragen. Öffne StudiNow, um sie zu sehen.")
    }

    /// Nur die Zahl, nie Absender oder Betreff
    static func newStudIPMessages(_ count: Int) -> Content? {
        guard count > 0 else { return nil }
        return Content(title: "Neue Stud.IP-Nachricht", body: count == 1 ? "1 neue Nachricht in Stud.IP" : "\(count) neue Nachrichten in Stud.IP")
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
/// damit er Neustarts der App durch iOS uebersteht)
struct BackgroundReloginLedger {
    static let minInterval: TimeInterval = 6 * 3600
    static let afterFailure: TimeInterval = 24 * 3600
    static let prefix = "uniflow.background.relogin."

    let defaults: UserDefaults

    func mayTry(_ portal: String, now: Date) -> Bool {
        guard let last = defaults.object(forKey: Self.prefix + portal + ".at") as? Date else { return true }
        let failed = defaults.bool(forKey: Self.prefix + portal + ".failed")
        return now.timeIntervalSince(last) >= (failed ? Self.afterFailure : Self.minInterval)
    }

    func record(_ portal: String, ok: Bool, now: Date) {
        defaults.set(now, forKey: Self.prefix + portal + ".at")
        defaults.set(!ok, forKey: Self.prefix + portal + ".failed")
    }
}
