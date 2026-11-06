import SwiftUI
import UniFlowCore

// Klausurtermine immer sichtbar (Frage des Inhabers 04.11.2026: "Kannst du schauen, ob du die Klausur-Pins bei
// Stud.IP immer anzeigen kannst?"). Eine Liste aus allen Quellen, GET /api/exams/upcoming (Kern: Exams, PC:
// app/exams.py): Stud.IP-Termine mit Art "Klausur", Klausurtermin am Modul, QIS-Anmeldungen, Fristen, Ankuendigungen,
// Nachrichten, auf dem Geraet auch in Dokumenten erkannte. Gezeigt:
// - Uebersicht: Karte "Nächste Klausuren" oben (nur wenn es welche gibt), `UpcomingExamsCard`
// - Lernkalender und Stundenplan: eigener Pin je Klausur (Farbe `UFExam.color`, Symbol), immer zuerst unter den
//   Hinweisen eines Tages; Hinweise "Prüfung" aus Ankuendigungen desselben Moduls stehen dann nicht noch einmal da
// - Modulseite: naechste Klausur im Kopf, `ModuleNextExam`
// - Pruefungsanmeldung (05.11.2026, ExamRegistrationViews.swift): Abzeichen "angemeldet"/"nicht angemeldet" je Klausur
//   und eine Zeile zum Meldezeitraum mit "Im QIS anmelden" in der Karte "Nächste Klausuren"

enum UFExam {
    /// Farbe der Klausur-Pins (kraeftiges Violett: von Fristen rot, Hinweisen blau und Ferien gruen klar zu trennen)
    static let color = Color(light: 0x8a2be2, dark: 0xc58cf5)
    static let soft = Color(light: 0xf1e6fc, dark: 0x2f1d42)
    static let icon = "exam"

    /// Kommende Klausuren (leer ohne Verbindung oder bei Fehler; ein PC-Server ohne den Pfad liefert 404 -> leer)
    static func load(_ api: APIClient?, module: Int? = nil) async -> [JSONValue] {
        guard let api else { return [] }
        let path = "/api/exams/upcoming" + (module.map { "?module_id=\($0)" } ?? "")
        return (try? await api.value(path))?.list("items") ?? []
    }

    /// Klausuren an die Kalendertage einer Antwort haengen (Feld `exams` je Tag, GET /api/calendar und
    /// /api/timetable/week); ohne Klausuren unveraendert
    static func attach(_ cal: JSONValue, _ exams: [JSONValue]) -> JSONValue {
        guard !exams.isEmpty, case .object(var o) = cal, let days = o["days"]?.array else { return cal }
        var byDate: [String: [JSONValue]] = [:]
        for e in exams { if let d = e.s("date") { byDate[d, default: []].append(e) } }
        o["days"] = .array(days.map { d in
            guard let k = d.s("date"), let list = byDate[k], case .object(var x) = d else { return d }
            x["exams"] = .array(list)
            return .object(x)
        })
        return .object(o)
    }

    /// "in 12 Tagen", "morgen", "heute"
    static func countdown(_ e: JSONValue) -> String {
        if let s = e.s("in_days"), !s.isEmpty { return s }
        return DueStore.inDays(e.i("days_left") ?? 0)
    }

    /// "Fr., 12.02.2027"
    static func dateText(_ e: JSONValue) -> String {
        "\(UFFmt.weekdayShort(e.s("date")))., \(UFFmt.date(e.s("date")))"
    }

    /// "09:00–11:00 · Hörsaal F 303" (nur was bekannt ist); `room: false` ohne Raum (der steht dann als `UFRoomLink` daneben)
    static func placeText(_ e: JSONValue, room: Bool = true) -> String? {
        var parts: [String] = []
        if let t = e.s("time"), !t.isEmpty { parts.append(e.s("end").map { $0.isEmpty ? "\(t) Uhr" : "\(t)–\($0) Uhr" } ?? "\(t) Uhr") }
        if room, let r = e.s("room"), !r.isEmpty { parts.append(r) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Erste Quelle mit Adresse (nur http/https)
    static func sourceURL(_ e: JSONValue) -> URL? {
        e.list("sources").lazy.compactMap { UFDayExtras.safeURL($0.s("url")) }.first
    }

    /// Text fuer VoiceOver: "Klausur Analysis I, Freitag, 12.02.2027, in 100 Tagen, 09:00 Uhr, Hörsaal F 303, aus Stud.IP-Terminen"
    static func accessibility(_ e: JSONValue) -> String {
        [e.s("title") ?? "Klausur", dateText(e), countdown(e), placeText(e), e.s("source_label")].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// Karte "Nächste Klausuren" der Uebersicht: bis zu vier kommende Klausuren mit Tag, Countdown, Modul, Uhrzeit und Raum
/// und Quelle; ohne Klausuren nichts (auch kein Platz). Laedt selbst (`token` wechselt: neu laden).
struct UpcomingExamsCard: View {
    let api: APIClient?
    /// z. B. der Tag der Uebersicht: nach Mitternacht neu
    var token: String = ""
    @State private var items: [JSONValue] = []
    @EnvironmentObject private var router: UFRouter
    static let limit = 4

    /// Pruefungsanmeldung (05.11.2026): Abzeichen angemeldet/nicht angemeldet je Klausur und Zeile zum Meldezeitraum
    @State private var registration: ExamRegistrationState?

    var body: some View {
        // immer eine echte Ansicht: an einer leeren (noch keine Klausuren) startet `.task` nie, die Karte blieb leer
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            UpcomingExamsList(items: items, registration: registration) { e in
                if let m = e.i("module_id") { router.go(.module(m)) } else if let d = e.s("date") { router.go(.plan(view: "day", date: d)) }
            }
        }
        .task(id: token) { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        items = await UFExam.load(api)
        registration = await ExamRegistrationState.load(api)
    }
}

/// Inhalt der Karte ohne Laden: ohne Klausuren nichts (kein Platz), sonst die Karte mit Abstand nach unten
struct UpcomingExamsList: View {
    let items: [JSONValue]
    /// Pruefungsanmeldung (nil: keine Abzeichen, keine Zeile)
    var registration: ExamRegistrationState?
    let open: (JSONValue) -> Void

    init(items: [JSONValue], registration: ExamRegistrationState? = nil, open: @escaping (JSONValue) -> Void) {
        self.items = items
        self.registration = registration
        self.open = open
    }

    var body: some View {
        if !items.isEmpty {
            Self.card(items, registration: registration, open: open).padding(.bottom, 19.2)
        }
    }

    static let limit = UpcomingExamsCard.limit

    @ViewBuilder static func card(_ items: [JSONValue], registration: ExamRegistrationState? = nil,
                                  open: @escaping (JSONValue) -> Void) -> some View {
        UFCard {
            UFCardHead("Nächste Klausuren", icon: UFExam.icon)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Row.rows(Array(items.prefix(limit)), key: "id")) { row in
                    let e = row.value
                    let reg = registration?.suggestion(exam: e)
                    let room = e.s("room").flatMap { Rooms.mayLink($0) ? $0 : nil }
                    Button { open(e) } label: { line(e, registered: reg?.registered, roomAside: room != nil) }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(UFExam.accessibility(e) + (reg.map { ", " + ExamRegistrationText.status($0) } ?? ""))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("exam.row")
                    // Raumfinder (05.11.2026): Raum antippen -> Ort mit Google-Maps-Link
                    if let room { UFRoomLink(text: room, size: 12.8).padding(.leading, 70).padding(.top, -4) }
                }
                if items.count > limit {
                    Text("und \(items.count - limit) weitere").ufFont(12.8).foregroundStyle(UF.muted)
                }
                if let registration { ExamRegistrationExamsFooter(state: registration) }
            }
        }
        .accessibilityIdentifier("exams.card")
    }

    /// `registered`: Abzeichen der Pruefungsanmeldung (nil: keins)
    private static func line(_ e: JSONValue, registered: Bool? = nil, roomAside: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Tag als Kachel in der Klausurfarbe
            VStack(spacing: 0) {
                Text(UFFmt.weekdayShort(e.s("date"))).ufFont(11.2, 600)
                Text(String(UFFmt.date(e.s("date")).prefix(6))).ufFont(14.4, 700)
            }
            .foregroundStyle(UFExam.color)
            .frame(width: 58).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UFExam.soft))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UFFmt.shortName(e.s("title"))).ufFont(14.5, 650).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(UFExam.countdown(e)).ufFont(12.8, 650).foregroundStyle(UFExam.color).fixedSize()
                }
                if let p = UFExam.placeText(e, room: !roomAside) { Text(p).ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true) }
                if let s = e.s("source_label"), !s.isEmpty {
                    Text(s).ufFont(12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                if let registered {
                    UFBadge(registered ? "angemeldet" : "nicht angemeldet", tone: registered ? .ok : .warn).fixedSize()
                        .accessibilityIdentifier("exam.registration")
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Naechste Klausur eines Moduls fuer den Kopf der Modulseite: "Nächste Klausur: Fr., 12.02.2027 · in 100 Tagen ·
/// 09:00 Uhr · Hörsaal F 303 (aus Stud.IP-Terminen)"; ohne Klausur nichts
struct ModuleNextExam: View {
    let api: APIClient?
    let moduleID: Int
    @State private var next: JSONValue?

    var body: some View {
        Group {
            if let e = next {
                let room = e.s("room").flatMap { Rooms.mayLink($0) ? $0 : nil }
                VStack(alignment: .leading, spacing: 4) {
                    Self.label(e, room: room == nil)
                    // Raumfinder (05.11.2026): Raum der Klausur mit Ort und Google-Maps-Link
                    if let room { UFRoomLink(text: room, size: 12.8, color: UFExam.color) }
                }
            }
        }
        .task(id: moduleID) { next = await UFExam.load(api, module: moduleID).first }
    }

    static func text(_ e: JSONValue, room: Bool = true) -> String {
        var s = "\(e.s("kind_label") ?? "Klausur"): \(UFExam.dateText(e)) · \(UFExam.countdown(e))"
        if let p = UFExam.placeText(e, room: room) { s += " · \(p)" }
        return s
    }

    static func label(_ e: JSONValue, room: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            UFIcon(UFExam.icon, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(text(e, room: room)).ufFont(13.6, 650).fixedSize(horizontal: false, vertical: true)
                if let s = e.s("source_label"), !s.isEmpty { Text(s).ufFont(12).foregroundStyle(UF.muted) }
            }
        }
        .foregroundStyle(UFExam.color)
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UFExam.soft))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module.nextExam")
    }
}
