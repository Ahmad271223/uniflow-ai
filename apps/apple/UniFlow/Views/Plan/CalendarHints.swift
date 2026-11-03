import SwiftUI
import UniFlowCore

// Hinweise im Kalenderkopf antippbar (Auftrag des Inhabers 03.11.2026): jeder Chip eines Tages (Feiertag und
// vorlesungsfreie Zeit, Learnweb- und Courseware-Fristen, erkannte Abgaben/Tests/Klausuren, Termine aus
// Ankuendigungen: Ausfall, Verlegung, Raum, Pruefung, Frist, Online, Termin) oeffnet ein Detailblatt mit Art, Datum
// und Uhrzeit, Kurs, dem Satz aus der Quelle und der Quelle selbst. Felder aus GET /api/calendar bzw.
// /api/timetable/week (`marks`, `deadlines`, `notices`; Hinweise mit course_id, module_id, posted_at, Fristen mit
// source seit 03.11.2026, gleich in app/announcements.py, app/holidays.py und im Kern).

/// Ein Hinweis eines Kalendertags in lesbarer Form (rein, ohne Ansicht; `CalendarHintAppTests`)
struct UFHint: Identifiable {
    enum Category: Equatable { case mark, deadline, detected, notice }

    let id: String
    let category: Category
    /// Art laut Quelle (feiertag, pause, vorlesungsfrei; abgabe, test_ende …; ausfall, verlegt, raum …)
    let kind: String
    /// Art fuer Menschen: "Klausur / Prüfung", "Frist", "Ausfall?", "Verlegung?", "Raumänderung", "Online", …
    let kindText: String
    let icon: String
    let tone: UFTone
    let title: String
    /// ISO-Tag
    let date: String
    let time: String?
    let course: String?
    /// Satz aus der Quelle (Ankuendigung, erkannte Fundstelle) bzw. Name im Learnweb
    let snippet: String?
    /// Herkunft lesbar: "Stud.IP-Ankündigung „Titel“ vom 02.11.2026", "Learnweb-Kalender", "Gesetzlicher Feiertag"
    let source: String
    /// nur http(s)
    let url: URL?
    let announcementID: String?
    let courseID: String?
    let moduleID: Int?
    let raw: JSONValue

    // MARK: Aufbau aus den Feldern eines Kalendertags

    /// Alle Hinweise eines Tages in der Reihenfolge der Chips (Markierungen, Fristen, Hinweise)
    static func all(_ dd: JSONValue) -> [UFHint] {
        let date = dd.s("date") ?? ""
        return UFDayExtras.marks(dd).map { mark($0, date: date) }
            + dd.list("deadlines").map { deadline($0, date: date) }
            + dd.list("notices").map { notice($0, date: date) }
    }

    static func mark(_ m: JSONValue, date: String) -> UFHint {
        let kind = m.s("kind") ?? ""
        let label = m.s("label") ?? ""
        let holiday = kind == "feiertag"
        return UFHint(id: "mark|\(date)|\(label)", category: .mark, kind: kind,
                      kindText: holiday ? "Feiertag" : kind == "pause" ? "Vorlesungsfrei (Unterbrechung)" : "Vorlesungsfreie Zeit",
                      icon: holiday ? "sun" : "calendar", tone: .ok, title: label, date: date, time: nil, course: nil,
                      snippet: holiday ? "An diesem Tag finden keine Lehrveranstaltungen statt."
                                       : "In dieser Zeit finden in der Regel keine Vorlesungen statt; Prüfungen und Blockveranstaltungen sind möglich.",
                      source: holiday ? "Gesetzlicher Feiertag" : "Semesterzeiten der Hochschule",
                      url: nil, announcementID: nil, courseID: nil, moduleID: nil, raw: m)
    }

    static func deadline(_ x: JSONValue, date: String) -> UFHint {
        let detected = x["detected"]?.bool == true
        let kind = x.s("kind") ?? ""
        let time = x.s("time").flatMap { $0.isEmpty ? nil : $0 }
        if detected {
            // erkannte Abgabe, Test, Klausur oder Anmeldung aus Dokument oder Ankuendigung (DueStore)
            let (text, icon, tone): (String, String, UFTone) = switch kind {
            case "klausur": ("Klausur / Prüfung", "exam", .bad)
            case "test": ("Test", "exam", .bad)
            case "abgabe": ("Abgabe", "flag", .bad)
            case "anmeldung": ("Anmeldung", "flag", .warn)
            default: ("Termin", "calendar", .info)
            }
            return UFHint(id: "detected|\(x.s("id") ?? "")", category: .detected, kind: kind, kindText: text, icon: icon, tone: tone,
                          title: x.s("title") ?? "Termin", date: date, time: time, course: x.s("course_title") ?? x.s("module_name"),
                          snippet: x.s("snippet").flatMap { $0.isEmpty ? nil : $0 },
                          source: (x.s("origin").flatMap { $0.isEmpty ? nil : $0 } ?? "Erkannt") + " (automatisch erkannt)",
                          url: nil, announcementID: x["announcement_ids"]?.array?.first?.string, courseID: x.s("course_id"),
                          moduleID: x.i("module_id"), raw: x)
        }
        let studip = x.s("source") == "studip"
        let full = x.s("full_title")
        return UFHint(id: "deadline|\(x.s("id") ?? "")", category: .deadline, kind: kind,
                      kindText: x.s("kind_label") ?? "Frist", icon: kind.hasPrefix("test") ? "exam" : "flag", tone: .bad,
                      title: x.s("title") ?? "Frist", date: date, time: time, course: x.s("course_title"),
                      snippet: full != nil && full != x.s("title") ? full : nil,
                      source: studip ? "Aufgabe aus Stud.IP Courseware" : "Frist aus dem Learnweb-Kalender",
                      url: UFDayExtras.safeURL(x.s("url")), announcementID: nil, courseID: nil, moduleID: nil, raw: x)
    }

    /// Art eines Hinweises aus einer Ankuendigung (`KIND_LABELS` in app/announcements.py, lesbarer)
    static func noticeKind(_ kind: String) -> (text: String, icon: String, tone: UFTone) {
        switch kind {
        case "ausfall": return ("Ausfall?", "alert", .warn)
        case "verlegt": return ("Verlegung?", "move", .warn)
        case "raum": return ("Raumänderung", "move", .info)
        case "pruefung": return ("Klausur / Prüfung", "exam", .bad)
        case "frist": return ("Frist", "flag", .bad)
        case "online": return ("Online", "users", .info)
        default: return ("Termin", "calendar", .info)
        }
    }

    static func notice(_ n: JSONValue, date: String) -> UFHint {
        let kind = n.s("kind") ?? ""
        let k = noticeKind(kind)
        let src = ["studip": "Stud.IP-Ankündigung", "learnweb": "Learnweb-Ankündigung"][n.s("source") ?? ""] ?? "Ankündigung"
        var source = "\(src) „\(n.s("title") ?? "")“"
        if let posted = n.s("posted_at"), posted.count >= 10 { source += " vom \(UFFmt.date(String(posted.prefix(10))))" }
        return UFHint(id: "notice|\(n.s("announcement_id") ?? "")|\(date)|\(kind)|\(n.s("time") ?? "")", category: .notice, kind: kind,
                      kindText: k.text, icon: k.icon, tone: k.tone, title: n.s("title") ?? "Hinweis", date: date,
                      time: n.s("time").flatMap { $0.isEmpty ? nil : $0 }, course: n.s("course_title"),
                      snippet: n.s("snippet").flatMap { $0.isEmpty ? nil : $0 }, source: source, url: UFDayExtras.safeURL(n.s("url")),
                      announcementID: n.s("announcement_id"), courseID: n.s("course_id"), moduleID: n.i("module_id"), raw: n)
    }

    // MARK: Anzeige

    /// "Donnerstag, 12. November 2026 · 10:15 Uhr"
    var dateText: String {
        guard let d = Fmt.date(date) else { return date }
        let s = Fmt.formatter("EEEE, d. MMMM y").string(from: d)
        return time.map { "\(s), \($0) Uhr" } ?? s
    }

    /// Ausfall aus einer Ankuendigung (Entscheidung "Fällt aus" / "Findet statt" am Termin)
    var isCancellation: Bool { category == .notice && kind == "ausfall" }

    /// Termin des Tages, um den es geht: bei einem Ausfall der Termin mit diesem Hinweis (`cancel_hint`), sonst ein
    /// Termin desselben Kurses bzw. Moduls (mit Uhrzeit der, der dann laeuft oder bis 15 Minuten spaeter beginnt,
    /// wie mark_cancellations). Nur Hinweise aus Ankuendigungen haben einen Termin.
    func relatedEvent(in events: [JSONValue]) -> JSONValue? {
        guard category == .notice else { return nil }
        let evs = events.filter { $0.s("status") != "verschoben" }
        if isCancellation, let a = announcementID, let e = evs.first(where: { UFCancel.hint($0)?.s("announcement_id") == a }) { return e }
        var cand = evs.filter { e in
            (courseID != nil && e.s("course_id") == courseID) || (moduleID != nil && e.i("module_id") == moduleID)
        }
        if let t = time {
            let m = UFTime.hm(t)
            cand = cand.filter { e in
                let s = UFTime.hm(e.s("start")), end = UFTime.hm(e.s("end"))
                return s - 15 <= m && m < max(s + 1, end)
            }
        }
        if let c = courseID, cand.contains(where: { $0.s("course_id") == c }) { cand = cand.filter { $0.s("course_id") == c } }
        return cand.first
    }
}

// MARK: - Detailblatt

/// Detail eines Hinweises: Art, Titel, Datum und Uhrzeit, Kurs, Satz aus der Quelle, Quelle; "Quelle öffnen" (nur
/// http(s) bzw. das erkannte Dokument), "Zum Termin" und bei einem unsicheren Ausfall "Fällt aus" / "Findet statt"
struct UFHintDialog: View {
    let hint: UFHint
    /// Termine desselben Tages (fuer "Zum Termin")
    var events: [JSONValue] = []
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @Environment(\.openURL) private var openURL

    var body: some View {
        let event = hint.relatedEvent(in: events)
        UFDialog(hint.title) {
            VStack(alignment: .leading, spacing: 14) {
                UFBadge(hint.kindText, tone: hint.tone, icon: hint.icon)
                    .accessibilityIdentifier("hint.kind")
                VStack(alignment: .leading, spacing: 8) {
                    row("calendar", hint.dateText, id: "hint.date")
                    if let c = hint.course, !c.isEmpty { row("book", c, id: "hint.course") }
                    if let e = event { row("clock", Self.eventLine(e), id: "hint.event") }
                }
                if let sn = hint.snippet {
                    Text(hint.category == .mark || hint.category == .deadline ? sn : "„\(sn)“")
                        .ufFont(14.5).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
                        .accessibilityIdentifier("hint.snippet")
                }
                Text("Quelle: \(hint.source)").ufFont(13.12).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hint.source")
                if hint.isCancellation, let e = event { cancelState(e) }
            }
        } foot: {
            Group {
                if let e = event {
                    UFButton("Zum Termin", icon: "calendar", size: .small) {
                        close()
                        PlanEnv.make(session, overlay, toast, router).openOccurrence(e, date: hint.date)
                    }
                    .accessibilityIdentifier("hint.toEvent")
                }
                if hint.category == .detected, DueOpen.route(hint.raw) != nil {
                    UFButton("Quelle öffnen", icon: "arrow-right", size: .small) {
                        close()
                        DueOpen.open(hint.raw, router: router, openURL: openURL)
                    }
                } else if let u = hint.url {
                    UFButton("Quelle öffnen", icon: "arrow-right", size: .small) { openURL(u) }
                        .accessibilityIdentifier("hint.openSource")
                }
                UFButton("Schließen", kind: .ghost, size: .small) { close() }
            }
            .fixedSize()
        }
        .accessibilityIdentifier("hint.dialog")
    }

    private func row(_ icon: String, _ text: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UFIcon(icon, size: 15).foregroundStyle(UF.muted)
            Text(text).ufFont(14.5).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    /// "Vorlesung 10:15–11:45 · Raum B 302"
    static func eventLine(_ e: JSONValue) -> String {
        var s = "\(UFFmt.shortName(e.s("title"))), \(e.s("start") ?? "")–\(e.s("end") ?? "")"
        if let r = e.s("room"), !r.isEmpty { s += ", \(r)" }
        return s
    }

    @ViewBuilder private func cancelState(_ e: JSONValue) -> some View {
        if e.s("status") == "ausfall" {
            UFCancelMark(text: UFCancel.sureText, size: 13.12)
        } else if e.i("event_id") == nil {
            Text("Einzeltermin aus deinem Stud.IP-Kalender: Der Termin bleibt im Plan.").ufFont(13.12).foregroundStyle(UF.muted)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Aus dem Text erkannt, nicht sicher. Der Termin bleibt im Plan, bis du entscheidest.")
                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                if UFCancel.unsure(e), let id = e.i("event_id") {
                    HStack(spacing: 8) {
                        UFButton("Fällt aus", icon: "alert", kind: .primary, size: .small) { Task { await decide(id, "cancelled") } }
                            .accessibilityIdentifier("hint.cancelled")
                        UFButton("Findet statt", icon: "check", size: .small) { Task { await decide(id, "today_attend") } }
                            .accessibilityIdentifier("hint.attend")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.warnSoft))
        }
    }

    /// vorhandene Ausnahmen wie im Termin-Panel (cancelled bzw. today_attend), Fehler sichtbar
    private func decide(_ eventID: Int, _ mode: String) async {
        guard let api = session.api else { return }
        if await toast.attempt("Speichern", {
            _ = try await api.value("/api/timetable/attendance", method: "POST",
                                    body: ["event_id": .number(Double(eventID)), "date": .string(hint.date), "mode": .string(mode)])
        }) {
            toast.show(mode == "cancelled" ? "Als Ausfall eingetragen" : "Termin findet statt")
            close()
            router.reload()
        }
    }
}
