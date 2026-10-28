import SwiftUI
import UniFlowCore

// Termin-Panel, Termin-Dialog und Verfuegbarkeit 1:1 nach app/static/views-tt.js (openEvent, eventDialog,
// availabilityDialog); vom Stundenplan, vom Lernkalender und von der Übersicht genutzt.

enum UFKind {
    /// KIND_TXT in core.js (Reihenfolge wie im Web)
    static let all: [(String, String)] = [
        ("vorlesung", "Vorlesung"), ("uebung", "Übung"), ("hoersaaluebung", "Hörsaalübung"), ("gruppenuebung", "Gruppenübung"),
        ("tutorium", "Tutorium"), ("labor", "Labor"), ("seminar", "Seminar"), ("sonstiges", "Sonstiges"), ("persoenlich", "Persönlich"),
    ]
    static func text(_ k: String?) -> String { all.first { $0.0 == k }?.1 ?? (k ?? "") }
    /// KIND_ICON / KIND_LABEL in views-plan.js
    static let icon: [String: String] = ["vorlesung": "book", "uebung": "pencil", "gruppenuebung": "users", "hoersaaluebung": "pencil",
                                         "tutorium": "users", "persoenlich": "user", "sonstiges": "calendar"]
    static let label: [String: String] = ["vorlesung": "Vorlesung", "uebung": "Übung", "gruppenuebung": "Übung", "hoersaaluebung": "Übung",
                                          "tutorium": "Tutorium", "persoenlich": "Persönlich", "sonstiges": "Termin"]
    static let daysLong = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
}

// MARK: - Termin-Drawer (openEvent)

struct EventDrawer: View {
    let eventID: Int
    let date: String
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var e: JSONValue?
    @State private var occ: JSONValue = .null
    @State private var mats: [JSONValue] = []
    @State private var matsError: String?

    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    /// Herkunft einer Serie lesbar (vorher stand die interne Kennung da: "· lsf", "· manual", "· ics")
    static func sourceText(_ source: String?) -> String? {
        switch source {
        case "studip", "studip-auto", "studip-manual": return "aus Stud.IP"
        case "lsf", "lsf-auto": return "aus dem LSF"
        case "ics": return "aus einer Kalenderdatei"
        case "manual": return "eigener Termin"
        case "pdf", "image", "text": return "aus dem Import"
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let e { content(e) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task { await load(first: true) }
        .ufReload { await load(first: false) }
    }

    /// "Termin nicht gefunden" (geloescht) und "Abruf fehlgeschlagen" (Fehlerantwort) sind zwei Meldungen; Unterlagen,
    /// die sich nicht laden lassen, stehen als Meldung statt als "Keine passenden Unterlagen"
    private func load(first: Bool) async {
        guard let api = session.api else { return }
        let events: JSONValue
        do { events = try await api.value("/api/timetable/events") } catch {
            toast.show("Termin laden fehlgeschlagen: \(error.localizedDescription)", seconds: 4)
            if first { close() }
            return
        }
        guard let ev = events.items.first(where: { $0.i("id") == eventID }) else {
            if first { toast.show("Termin nicht gefunden"); close() }
            return
        }
        let day = try? await api.value("/api/timetable/day?date=\(date)")
        occ = day?.list("events").first { $0.i("event_id") == eventID }
            ?? ["status": .string(ev.i("attend") == 0 ? "nicht_teilnahme" : "teilnahme"), "start": ev["start_time"] ?? .null, "end": ev["end_time"] ?? .null]
        do {
            mats = try await api.value("/api/timetable/event-materials/\(eventID)?date=\(date)").items
            matsError = nil
        } catch {
            mats = []
            matsError = error.localizedDescription
        }
        e = ev
    }

    @ViewBuilder private func content(_ e: JSONValue) -> some View {
        let st = occ.s("status") ?? "teilnahme"
        let attend = (e.i("attend") ?? (e["attend"]?.bool == false ? 0 : 1)) != 0
        UFDrawerFrame {
            UFDot(color: occ.s("color").map { Color(hex: $0) } ?? UF.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(e.s("title") ?? "").ufFont(14.5, 700).foregroundStyle(UF.text)
                Text(subline(e)).ufFont(13.12).foregroundStyle(UF.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            UFButton(icon: "x", kind: .ghost) { close() }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Text("Teilnahme: \(attendText(st, attend: attend))").ufFont(14.5, 700).foregroundStyle(UF.text)
                if e.s("rrule") != "once" {
                    Text(([e.s("rrule") == "biweekly" ? "Alle zwei Wochen" : "Wöchentlich"] + [Self.sourceText(e.s("source"))].compactMap { $0 })
                            .joined(separator: " · "))
                        .ufFont(11.84).foregroundStyle(UF.muted)
                }
                VStack(spacing: 8) {
                    attButton("today_attend", icon: "check", "Ich nehme teil", on: st == "teilnahme")
                    attButton("today_skip", icon: "x", "Ich nehme heute nicht teil", on: st == "nicht_teilnahme" && attend)
                    attButton("permanent_skip", icon: "log-out", "Ich besuche diese Veranstaltung dauerhaft nicht", on: !attend)
                    attButton("cancelled", icon: "alert", "Veranstaltung fällt aus", on: st == "ausfall")
                    if !attend { attButton("permanent_attend", icon: "rotate", "Wieder dauerhaft besuchen", on: false) }
                    if occ["exception"].map({ !$0.isNull }) == true {
                        UFButton("Ausnahme für diesen Tag zurücksetzen", kind: .ghost, size: .small) { Task { await attendance("reset") } }
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 9.6)
            }
            .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))

            HStack(spacing: 7.2) { UFIcon("book", size: 16); Text("Passende Unterlagen") }
                .ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                .padding(.top, 16).padding(.bottom, 6.4)
            if let matsError {
                Text("Unterlagen ließen sich nicht laden: \(matsError)").ufFont(13.12).foregroundStyle(UF.warn)
            } else if mats.isEmpty {
                Text("Keine passenden Unterlagen gefunden.").ufFont(13.12).foregroundStyle(UF.muted)
            } else {
                ForEach(Row.rows(mats)) { row in UFEventDocRow(f: row.value) { overlay.closeAll(); router.go(.doc(row.value.s("id") ?? "")) } }
            }
            if let m = e.i("module_id") {
                UFButton("Modul öffnen", icon: "book", size: .small) { overlay.closeDrawer(); router.go(.module(m)) }.padding(.top, 8)
            }
        } foot: {
            UFButton("Bearbeiten", icon: "pencil", size: .small) { actions.eventDialog(e, preset: ["date": .string(date)]) }
            UFButton("Lernblock danach", icon: "plus", size: .small) {
                let end = UFTime.hm(occ.s("end"))
                actions.useFreeWindow(date: date, start: end, end: min(end + 90, 22 * 60), materials: mats, moduleID: e.i("module_id"))
            }
            UFFlexSpacer()
            UFButton(icon: "trash", kind: .danger, size: .small) {
                Task {
                    if await overlay.confirm("Ganze Veranstaltungsreihe aus dem Stundenplan entfernen?"), let api = session.api,
                       await toast.attempt("Entfernen", { _ = try await api.value("/api/timetable/events/\(eventID)", method: "DELETE") }) {
                        close()
                        router.reload()
                    }
                }
            }
        }
    }

    private func subline(_ e: JSONValue) -> String {
        var s = "\(UFKind.text(e.s("kind"))) · \(UFFmt.short(date)) · \(occ.s("start") ?? "")–\(occ.s("end") ?? "")"
        if let r = e.s("room"), !r.isEmpty { s += " · \(r)" }
        if let l = e.s("lecturer"), !l.isEmpty { s += " · \(l)" }
        return s
    }

    private func attendText(_ st: String, attend: Bool) -> String {
        switch st {
        case "teilnahme": return "Ich nehme teil"
        case "nicht_teilnahme": return attend ? "Heute nicht" : "Dauerhaft nicht"
        case "ausfall": return "Fällt aus"
        case "verschoben": return "Verschoben"
        default: return st
        }
    }

    private func attButton(_ mode: String, icon: String, _ text: String, on: Bool) -> some View {
        Button { Task { await attendance(mode) } } label: {
            HStack(spacing: 7.2) { UFIcon(icon, size: 15); Text(text) }.frame(maxWidth: .infinity)
        }
        .buttonStyle(UFButtonStyle(kind: on ? .primary : .normal))
    }

    /// Teilnahme speichern; scheitert es, steht der Grund als Meldung und es wird weder Zeit freigegeben noch neu
    /// geladen (vorher try? ... else { return }: nichts Sichtbares)
    private func attendance(_ mode: String) async {
        guard let api = session.api, let e else { return }
        let r: JSONValue
        do {
            r = try await api.value("/api/timetable/attendance", method: "POST",
                                    body: ["event_id": .number(Double(eventID)), "date": .string(date), "mode": .string(mode)])
        } catch { toast.show("Teilnahme speichern fehlgeschlagen: \(error.localizedDescription)", seconds: 4); return }
        let freed = r.i("freed_minutes") ?? 0
        if ["today_skip", "permanent_skip", "cancelled"].contains(mode) && freed >= 30 {
            let w = r.list("windows").first
            let start = w?.i("start") ?? UFTime.hm(occ.s("start")), end = w?.i("end") ?? UFTime.hm(occ.s("end"))
            let materials = r.list("materials"), module = e.i("module_id")
            let actions = actions
            overlay.modal {
                FreedTimeDialog(minutes: freed, permanent: mode == "permanent_skip") {
                    actions.useFreeWindow(date: date, start: start, end: end, materials: materials, moduleID: module)
                }
            }
        } else {
            toast.show("Teilnahme gespeichert")
        }
        router.reload()
    }
}

/// Modal "Du hast jetzt X frei" nach Nicht-Teilnahme oder Ausfall
struct FreedTimeDialog: View {
    let minutes: Int
    let permanent: Bool
    let use: () -> Void
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Du hast jetzt \(UFFmt.min(minutes)) frei", icon: "sun") {
            Text("\(permanent ? "Die Vorlesung gilt nicht als gelernt. " : "")Möchtest du die Zeit nutzen, z. B. die Vorlesung selbstständig mit den Folien bearbeiten?")
                .ufFont(14.5).foregroundStyle(UF.muted)
        } foot: {
            UFButton("Frei lassen") { close() }
            UFButton("Zeit nutzen", kind: .primary) { close(); use() }
        }
    }
}

/// a.doc-row im Termin-Panel: Icon, Titel (500) und direkt dahinter Typ · Minuten (inline wie im Web)
struct UFEventDocRow: View {
    let f: JSONValue
    let open: () -> Void

    var body: some View {
        let st = f.s("status")
        Button(action: open) {
            HStack(spacing: 9.6) {
                UFIcon(f.s("doc_type") == "uebung" ? "pencil" : "book", size: 16).foregroundStyle(UF.accentText).frame(width: 24)
                (Text(f.s("ai_title") ?? f.s("name") ?? "").font(.uf(14.5, 500)).foregroundColor(st == "erledigt" ? UF.muted : UF.accentText)
                    .strikethrough(st == "erledigt")
                 + Text(st == "neu" ? "  Neu  " : "").font(.uf(10.88, 600)).foregroundColor(UF.accentText)
                 + Text("\(f.s("doc_type") ?? "")\(f.i("est_minutes").map { " · ca. \($0) min" } ?? "")").font(.uf(12.48)).foregroundColor(UF.muted))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7.2).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Termin-Dialog (eventDialog)

struct EventDialog: View {
    let event: JSONValue?
    let preset: [String: JSONValue]
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var modules: [JSONValue] = []
    @State private var title = ""
    @State private var kind = "vorlesung"
    @State private var module = 0
    @State private var weekday = 0
    @State private var start = "08:00"
    @State private var end = "09:30"
    @State private var room = ""
    @State private var lecturer = ""
    @State private var rrule = "weekly"
    @State private var from = ""
    @State private var to = ""
    @State private var scope = "series"
    @State private var loaded = false

    var body: some View {
        UFDialog(event == nil ? "Neuer Termin" : "Termin bearbeiten") {
            UFField("Titel") { UFTextInput("z. B. Mathematik I – Vorlesung", text: $title) }
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Art") { UFSelect(options: UFKind.all, selection: $kind, fill: true) }
                UFField("Modul") {
                    UFSelect(options: [(0, "– keins –")] + modules.compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } }, selection: $module, fill: true)
                }
            }
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Wochentag") { UFSelect(options: UFKind.daysLong.enumerated().map { ($0.offset, $0.element) }, selection: $weekday, fill: true) }
                UFField("Beginn") { UFTimeField(hm: $start) }
                UFField("Ende") { UFTimeField(hm: $end) }
            }
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Raum") { UFTextInput(text: $room) }
                UFField("Dozent/in") { UFTextInput(text: $lecturer) }
            }
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Rhythmus") {
                    UFSelect(options: [("weekly", "Wöchentlich"), ("biweekly", "Alle zwei Wochen"), ("once", "Einzeltermin")], selection: $rrule, fill: true)
                }
                UFField("Von") { UFDateField(iso: $from, allowEmpty: true) }
                UFField("Bis") { UFDateField(iso: $to, allowEmpty: true) }
            }
            if let e = event, e.s("rrule") != "once" {
                UFField("Änderung gilt für") {
                    UFSelect(options: [("single", "Nur diesen Termin (\(UFFmt.short(preset["date"]?.string ?? UFFmt.todayISO())))"),
                                       ("future", "Diesen und alle zukünftigen Termine"), ("series", "Die gesamte Veranstaltungsreihe")],
                             selection: $scope, fill: true)
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .task {
            if !loaded { apply(); loaded = true }
            // Module fuer die Auswahl; scheitert das, bleibt die Zuordnung des Termins (module) unveraendert und
            // der Grund steht als Meldung (vorher stille leere Liste)
            guard let api = session.api else { return }
            await toast.attempt("Module laden") { modules = try await api.value("/api/modules").items }
        }
    }

    /// Vorgaben, dann der Termin, dann preset (wie { ...defaults, ...e, ...preset })
    private func apply() {
        var v: [String: JSONValue] = event?.object ?? [:]
        for (k, x) in preset { v[k] = x }
        title = v["title"]?.string ?? ""
        kind = v["kind"]?.string ?? "vorlesung"
        module = v["module_id"]?.int ?? 0
        weekday = v["weekday"]?.int ?? 0
        start = v["start_time"]?.string ?? "08:00"
        end = v["end_time"]?.string ?? "09:30"
        room = v["room"]?.string ?? ""
        lecturer = v["lecturer"]?.string ?? ""
        rrule = v["rrule"]?.string ?? "weekly"
        from = v["date_from"]?.string ?? ""
        to = v["date_to"]?.string ?? ""
    }

    private func save() async {
        guard let api = session.api else { return }
        var body: JSONValue = ["title": .string(title), "kind": .string(kind), "module_id": module == 0 ? .null : .number(Double(module)),
                               "weekday": .number(Double(weekday)), "start_time": .string(start), "end_time": .string(end), "room": .string(room),
                               "lecturer": .string(lecturer), "rrule": .string(rrule), "date_from": from.isEmpty ? .null : .string(from),
                               "date_to": to.isEmpty ? .null : .string(to)]
        do {
            if let id = event?.i("id") {
                body["scope"] = .string(event?.s("rrule") != "once" ? scope : "series")
                body["date"] = .string(preset["date"]?.string ?? UFFmt.todayISO())
                _ = try await api.value("/api/timetable/events/\(id)", method: "PATCH", body: body)
            } else {
                _ = try await api.value("/api/timetable/events", method: "POST", body: body)
            }
            close()
            toast.show("Gespeichert")
            router.reload()
        } catch { toast.show(error.localizedDescription) }
    }
}

// MARK: - Persoenliche Verfuegbarkeit (availabilityDialog)

struct AvailabilityDialog: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    struct Blocked: Identifiable { let id = UUID(); var weekday: Int; var start: String; var end: String; var title: String }

    @State private var start = "08:00"
    @State private var end = "21:00"
    @State private var travel = 30
    @State private var minSlot = 30
    @State private var pause = 15
    @State private var perDay = 240
    @State private var free: Set<Int> = []
    @State private var blocked: [Blocked] = []

    var body: some View {
        UFDialog("Persönliche Verfügbarkeit", icon: "clock") {
            Text("Freie Kalenderzeit ist nicht automatisch Lernzeit: Fahrtzeiten, Sperrzeiten und Mindestlänge werden abgezogen.")
                .ufFont(13.12).foregroundStyle(UF.muted)
            UFGridLayout(columns: 2) {
                UFField("Früheste Lernzeit") { UFTimeField(hm: $start) }
                UFField("Späteste Lernzeit") { UFTimeField(hm: $end) }
                UFField("Fahrtzeit Zuhause ↔ Uni (Minuten)") { UFNumberField(value: $travel) }
                UFField("Mindestdauer eines Lernslots (Minuten)") { UFNumberField(value: $minSlot) }
                UFField("Pause zwischen Aufgaben (Minuten)") { UFNumberField(value: $pause) }
                UFField("Maximale Lernzeit pro Tag (Minuten)") { UFNumberField(value: $perDay) }
            }
            UFField("Lernfreie Wochentage") {
                HStack(spacing: 9.6) {
                    ForEach(0..<7, id: \.self) { i in
                        UFChip(text: ShellState.days[i], on: free.contains(i)) { if free.contains(i) { free.remove(i) } else { free.insert(i) } }
                    }
                }
            }
            UFField("Sperrzeiten (z. B. Job, Sport, Mittag)") {
                VStack(alignment: .leading, spacing: 8) {
                    if blocked.isEmpty { Text("Keine Sperrzeiten.").ufFont(13.12).foregroundStyle(UF.muted) }
                    ForEach($blocked) { $b in
                        HStack(spacing: 9.6) {
                            UFSelect(options: ShellState.days.enumerated().map { ($0.offset, $0.element) }, selection: $b.weekday)
                            UFTimeField(hm: $b.start).frame(width: 90)
                            UFTimeField(hm: $b.end).frame(width: 90)
                            UFTextInput("Bezeichnung", text: $b.title)
                            UFButton(icon: "x", kind: .ghost, size: .small) { blocked.removeAll { $0.id == b.id } }
                        }
                    }
                    UFButton("Sperrzeit", icon: "plus", size: .small) { blocked.append(Blocked(weekday: 0, start: "12:00", end: "13:00", title: "")) }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .task { await load() }
    }

    private func load() async {
        guard let s = try? await session.api?.value("/api/settings") else { return }
        start = s.s("learn_start") ?? "08:00"
        end = s.s("learn_end") ?? "21:00"
        travel = s.i("travel_minutes") ?? 30
        minSlot = s.i("min_slot_minutes") ?? 30
        pause = s.i("break_minutes") ?? 15
        perDay = s.i("minutes_per_day") ?? 240
        free = Set(s.list("free_days").compactMap { $0.int })
        blocked = s.list("blocked_times").map { Blocked(weekday: $0.i("weekday") ?? 0, start: $0.s("start") ?? "12:00", end: $0.s("end") ?? "13:00", title: $0.s("title") ?? "") }
    }

    /// gleiche Felder wie avOk im Web (Zahlen als Zeichenkette aus den Eingabefeldern)
    private func save() async {
        let body: JSONValue = [
            "learn_start": .string(start), "learn_end": .string(end), "travel_minutes": .string("\(travel)"), "min_slot_minutes": .string("\(minSlot)"),
            "break_minutes": .string("\(pause)"), "hours_per_day": .string(String(format: "%.2f", Double(perDay) / 60)),
            "free_days": .array(free.sorted().map { .number(Double($0)) }),
            "blocked_times": .array(blocked.map { ["weekday": .number(Double($0.weekday)), "start": .string($0.start), "end": .string($0.end), "title": .string($0.title)] }),
        ]
        do {
            _ = try await session.api?.value("/api/settings", method: "PUT", body: body)
            close()
            toast.show("Verfügbarkeit gespeichert")
            router.reload()
        } catch { toast.show(error.localizedDescription) }
    }
}

// MARK: - Feiertage, Fristen und Hinweise je Kalendertag (holClass, holChips, dlChips, noteChips in core.js)

/// Felder `marks`, `deadlines` und `notices` eines Kalendertags (GET /api/calendar, /api/timetable/week): gruene
/// Markierung fuer Feiertag, Pause und vorlesungsfreie Zeit, Fristen aus dem Learnweb als Chips mit Link, Termine aus
/// Ankuendigungen der Lehrenden als Hinweis. Stundenplan, Lernkalender (Woche, Monat, Tag, Mini-Kalender) und die
/// Uebersicht zeigen sie wie die Web-App.
enum UFDayExtras {
    enum Tint { case none, holiday, lectureFree }

    /// holClass: Feiertag oder Pause kraeftig, vorlesungsfreie Zeit leicht
    static func tint(_ dd: JSONValue) -> Tint {
        let kinds = dd.list("marks").compactMap { $0.s("kind") }
        if kinds.contains("feiertag") || kinds.contains("pause") { return .holiday }
        return kinds.isEmpty ? .none : .lectureFree
    }

    /// Hintergrund der Spalte bzw. Zelle (.is-hol / .is-free)
    static func background(_ dd: JSONValue) -> Color {
        switch tint(dd) {
        case .holiday: return UF.okSoft
        case .lectureFree: return UF.okSoft.opacity(0.5)
        case .none: return .clear
        }
    }

    /// Fuellfarbe einer Zelle mit eigener Grundfarbe (Tageskopf, Monatszelle)
    static func fill(_ dd: JSONValue, over base: Color) -> Color {
        switch tint(dd) {
        case .holiday: return UF.okSoft
        case .lectureFree: return Color.mix(UF.okSoft, 0.5, base)
        case .none: return base
        }
    }

    /// Kurzform der Markierung wie holChips(compact)
    static func shortLabel(_ label: String) -> String {
        ["Vorlesungsfreie Zeit": "vorlesungsfrei", "Weihnachtspause": "Pause", "Exkursions- und Projektwoche": "Projektwoche",
         "Exkursionswoche": "Exkursion"][label] ?? label
    }

    /// Markierungen ohne Doppelte (je Bezeichnung die erste)
    static func marks(_ dd: JSONValue) -> [JSONValue] {
        var seen = Set<String>(), out: [JSONValue] = []
        for m in dd.list("marks") {
            let l = m.s("label") ?? ""
            if seen.insert(l).inserted { out.append(m) }
        }
        return out
    }

    /// Nur http(s)-Adressen werden geoeffnet (safeUrl im Web)
    static func safeURL(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }

    static func hasAny(_ dd: JSONValue) -> Bool {
        !dd.list("marks").isEmpty || !dd.list("deadlines").isEmpty || !dd.list("notices").isEmpty
    }
}

/// Chips eines Tages: Markierungen (gruen), Fristen (Modulfarbe, sonst rot; Tippen oeffnet das Learnweb), erkannte
/// Abgaben, Tests und Pruefungen (wie Fristen, mit Dokument-Symbol; Tippen oeffnet die PDF auf der Seite bzw. die
/// Ankuendigung), Hinweise aus Ankuendigungen (blau, Tippen oeffnet den Beitrag). `compact`: nur Uhrzeit und Art.
struct UFDayExtraChips: View {
    let dd: JSONValue
    var compact = true
    /// Chips untereinander (Tageskopf) statt umbrechend (Tagesansicht)
    var stacked = true
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let marks = UFDayExtras.marks(dd), dls = dd.list("deadlines"), notes = dd.list("notices")
        if !marks.isEmpty || !dls.isEmpty || !notes.isEmpty {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 2.4) { chips(marks, dls, notes) }
                } else {
                    UFFlexWrap(gap: 4.8, rowGap: 4) { chips(marks, dls, notes) }
                }
            }
        }
    }

    @ViewBuilder
    private func chips(_ marks: [JSONValue], _ dls: [JSONValue], _ notes: [JSONValue]) -> some View {
        ForEach(marks.indices, id: \.self) { i in
            let m = marks[i]
            let label = m.s("label") ?? ""
            chip(compact ? UFDayExtras.shortLabel(label) : label, fg: UF.ok, bg: UF.okSoft, border: UF.ok)
                .help(label)
        }
        ForEach(dls.indices, id: \.self) { i in
            let x = dls[i]
            let color = x.s("color").map { Color(hex: $0) } ?? UF.bad
            let detected = x["detected"]?.bool == true
            let time = x.s("time").flatMap { $0.isEmpty ? nil : $0 }
            let what = compact || detected ? (detected && !compact ? (x.s("title") ?? "Termin") : (x.s("kind_label") ?? "Frist"))
                : "\(x.s("kind_label") ?? "Frist"): \(x.s("title") ?? "")"
            let text = (time.map { "\($0) " } ?? "") + what
            Button {
                if detected { DueOpen.open(x, router: router, openURL: openURL) }
                else if let u = UFDayExtras.safeURL(x.s("url")) { openURL(u) }
            } label: {
                chip(text, fg: color, bg: color.opacity(0.12), border: color, icon: detected ? "file-text" : nil, bold: time)
            }
            .buttonStyle(.plain)
            .help("\(x.s("kind_label") ?? "") \(time ?? "") · \(x.s("full_title") ?? x.s("title") ?? "")\(x.s("course_title").map { " · \($0)" } ?? "")")
            .accessibilityLabel(detected ? "\(x.s("title") ?? "Termin")\(time.map { " \($0)" } ?? ""), \(x.s("origin") ?? "erkannt")"
                                         : "Frist \(x.s("time") ?? ""): \(x.s("title") ?? "")")
        }
        ForEach(notes.indices, id: \.self) { i in
            let n = notes[i]
            let text = (n.s("time").map { "\($0) " } ?? "") + (compact ? (n.s("kind_label") ?? "Termin") : "\(n.s("kind_label") ?? "Termin"): \(n.s("title") ?? "")")
            Button {
                if let u = UFDayExtras.safeURL(n.s("url")) { openURL(u) }
            } label: {
                chip(text, fg: UF.info, bg: UF.infoSoft, border: UF.info, icon: "info", bold: n.s("time"))
            }
            .buttonStyle(.plain)
            .help("\(n.s("title") ?? "")\(n.s("course_title").map { " · \($0)" } ?? ""): \(n.s("snippet") ?? "")")
            .accessibilityLabel("Hinweis aus Ankündigung: \(n.s("title") ?? "")")
        }
    }

    private func chip(_ text: String, fg: Color, bg: Color, border: Color, icon: String? = nil, bold: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { UFIcon(icon, size: 10) }
            if let bold, !bold.isEmpty, text.hasPrefix(bold) {
                Text(bold).font(.uf(10.4, 700)) + Text(String(text.dropFirst(bold.count))).font(.uf(10.4, 400))
            } else {
                Text(text).font(.uf(10.4, 400))
            }
        }
        .foregroundStyle(fg)
        .lineLimit(1)
        .padding(.vertical, 1.6).padding(.horizontal, 5.6)
        .background(Capsule().fill(bg))
        .overlay(Capsule().strokeBorder(border.opacity(0.6), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
