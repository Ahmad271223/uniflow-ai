import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

/// Stundenplan 1:1 nach viewTimetable() in app/static/views-tt.js: Kopf mit Termin/Import, Wochennavigation mit
/// Legende, Raster nur mit den Hochschulterminen der Woche. Alles zu Lernslots (Verfügbarkeit, freie Fenster,
/// Sperrzeiten, Konflikte, Neu legen) steht im Lernkalender (03.11.2026). Doppeltippen legt einen Termin an.
/// Daten: GET /api/timetable/week.
struct TimetableView: View {
    let date: String?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var week: JSONValue?
    /// Konfliktpruefung gescheitert: Meldung statt stiller leerer Liste (eine leere Liste hiesse "keine Konflikte")
    @State private var error: String?
    /// noch nicht uebernommene Stud.IP-Termine (`pending_groups` aus /api/timetable/auto-status)
    @State private var studipPending = 0
    /// offene Fragen zum eigenen Stud.IP-Kalender (nur auf dem Geraet)
    @State private var studipQuestions: JSONValue?
    /// Breite des Rasters (fuer die Spaltenwahl und den Hinweis auf ausgeblendete Wochenendtage); 0 = noch nicht gemessen
    @State private var gridWidth: CGFloat = 0

    /// ttDate im Web: bleibt fuer die Sitzung erhalten
    @MainActor static var ttDate = UFFmt.todayISO()

    /// Hinweis "Noch kein Stundenplan" wie im Web (views-tt.js): "haben bereits Termine" nur, wenn wirklich
    /// Stud.IP-Termine zum Uebernehmen vorliegen, sonst der ehrliche Stand
    static func emptyHint(studipPending: Int) -> String {
        studipPending > 0
            ? "Deine Stud.IP-Kurse haben bereits Termine. Mit „Stundenplan importieren → aus Stud.IP“ übernimmst du sie in einer Vorschau, wählst deine Übungsgruppen und bestätigst."
            : "Noch sind keine Termine deiner Kurse abgeholt; sie kommen mit dem nächsten Abgleich. Bis dahin kannst du eine Kalenderdatei (ICS) importieren oder Termine selbst eintragen."
    }

    private let H: CGFloat = 56
    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    var body: some View {
        Group {
            if let week { content(week) } else if let error { UFContent { UFEmpty(icon: "alert", text: error) } } else {
                UFContent { UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16); UFSkeleton().frame(height: 420) }
            }
        }
        .task(id: date ?? "") { await load() }
        .ufReload { await load() }
    }

    private var start: Date { PlanData.monday(Fmt.date(Self.ttDate) ?? Date()) }

    private func load() async {
        if let date { Self.ttDate = date }
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            // Ausfaelle laut Stud.IP wie in Stud.IP ausblenden (`StudIPCancelled`), selbst markierte bleiben
            let from = Fmt.isoDay(start), to = Fmt.isoDay(PlanData.add(start, 6))
            async let hidden = StudIPCancelled.keys(api, from: from, to: to)
            let reply = try await api.value("/api/timetable/week?start=\(from)")
            let w = StudIPCancellations.hiding(in: reply, keys: await hidden)
            studipPending = (try? await api.value("/api/timetable/auto-status"))?.i("pending_groups") ?? 0
            studipQuestions = api.isLocal ? (try? await api.value("/api/timetable/studip-questions")) : nil
            week = w
            error = nil
        } catch {
            // Neu laden gescheitert: der letzte Stand bleibt stehen, der Grund steht als Meldung
            if week == nil { self.error = error.localizedDescription } else { toast.show("Neu laden fehlgeschlagen: \(error.localizedDescription)", seconds: 4) }
        }
    }

    @ViewBuilder private func content(_ w: JSONValue) -> some View {
        let days = w.list("days")
        let allEv = days.flatMap { $0.list("events") }
        let lo = ([8 * 60] + allEv.map { UFTime.hm($0.s("start")) }).min()! - 60
        let hi = ([18 * 60] + allEv.map { UFTime.hm($0.s("end")) }).max()! + 60
        let term = w["term"] ?? .null
        UFContent(wide: true, maxWidth: 1600, insets: EdgeInsets(top: 19.2, leading: 22.4, bottom: 19.2, trailing: 22.4)) {
            UFPageHead("Stundenplan", sub: "\(term.s("name") ?? "") · \(UFFmt.date(term.s("start"))) – \(UFFmt.date(term.s("end")))") {
                UFButton("Termin", icon: "plus", size: .small) { actions.eventDialog(nil) }
                UFButton("Stundenplan importieren", icon: "download", kind: .primary, size: .small) { overlay.modal { TimetableImportDialog() } }
            }
            if let q = studipQuestions, !q.list("hidden").isEmpty || !q.list("busy").isEmpty {
                StudIPCalendarQuestions(questions: q) { await load() }
            }
            nav.padding(.bottom, 4)
            legendRow.padding(.bottom, 11.2)
            if allEv.isEmpty {
                UFCard {
                    (Text("Noch kein Stundenplan. ").font(.uf(14.5, 700)).foregroundColor(UF.text)
                     + Text(Self.emptyHint(studipPending: studipPending)).foregroundColor(UF.muted))
                        .ufFont(14.5)
                }
                .padding(.bottom, 12.8)
            }
            let cols = TimetableColumns.layout(days: days, width: gridWidth)
            if !cols.hidden.isEmpty { weekendHint(cols.hidden) }
            grid(days, lo: lo, hi: hi)
            Text("Tippe auf einen Termin: Teilnahme ändern, bearbeiten, Unterlagen öffnen. Nicht besuchte Veranstaltungen geben Zeit frei, die du für Lernblöcke nutzen kannst.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 9.6)
        }
    }

    // MARK: Kopfbereiche

    /// Wochennavigation und Legende (.row.wrap)
    private var nav: some View {
        let s = start, e = PlanData.add(start, 6)
        let f = Fmt.formatter("d. MMMM")
        let a = f.string(from: s)
        f.dateFormat = "d. MMMM y"
        let label = "\(a) – \(f.string(from: e))"
        return UFFlexWrap(gap: 9.6) {
            UFButton(icon: "chevron-left", size: .small) { router.go(.timetable(date: Fmt.isoDay(PlanData.add(s, -7)))) }
            Text(label).ufFont(14.5, 700).foregroundStyle(UF.text).frame(minWidth: 220)
            UFButton(icon: "chevron-right", size: .small) { router.go(.timetable(date: Fmt.isoDay(PlanData.add(s, 7)))) }
            UFButton("Heute", kind: .ghost, size: .small) { router.go(.timetable(date: UFFmt.todayISO())) }
        }
    }

    /// Legende in eigener, umbrechender Zeile (03.11.2026: in der Navigationszeile wurde sie abgeschnitten)
    private var legendRow: some View {
        UFFlexWrap(gap: 14.4, rowGap: 6) {                                   // .tt-legend
                legend("Vorlesung/Übung") { RoundedRectangle(cornerRadius: 3).fill(UF.accent) }
                legend("Feiertag, vorlesungsfrei") { RoundedRectangle(cornerRadius: 3).fill(UF.okSoft).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(UF.ok, lineWidth: 1)) }
                legend("Hinweis (antippbar)") { RoundedRectangle(cornerRadius: 3).fill(UF.infoSoft).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(UF.info, lineWidth: 1)) }
        }
    }

    private func legend<S: View>(_ text: String, @ViewBuilder swatch: () -> S) -> some View {
        HStack(spacing: 4) {
            swatch().frame(width: 12, height: 12).clipShape(RoundedRectangle(cornerRadius: 3))
            Text(text).fixedSize()
        }
        .accessibilityElement(children: .combine)
        .ufFont(12.16).foregroundStyle(UF.muted)
    }

    // MARK: Raster (.tt-wrap / .tt-grid)

    /// Wochenendtage ohne Termine ausgeblendet (nur, wenn sieben Spalten nicht passen): sichtbarer Hinweis mit Pfeil
    private func weekendHint(_ hidden: [JSONValue]) -> some View {
        let names = hidden.map { UFKind.daysLong[$0.i("weekday") ?? 0] }.joined(separator: " und ")
        return HStack(spacing: 6) {
            UFIcon("info", size: 14)
            Text("\(names) ohne Termine ausgeblendet – mit mehr Breite (Querformat, Vollbild) siehst du die ganze Woche.")
                .fixedSize(horizontal: false, vertical: true)
            UFIcon("arrow-right", size: 14)
        }
        .ufFont(12.16).foregroundStyle(UF.muted)
        .padding(.bottom, 6.4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timetable.weekendHidden")
    }

    private func grid(_ allDays: [JSONValue], lo: Int, hi: Int) -> some View {
        let px: (Int) -> CGFloat = { CGFloat($0 - lo) / 60 * H }
        let today = UFFmt.todayISO()
        // Chips im Tageskopf (Feiertag, Fristen, Hinweise) machen den Kopf hoeher: je Chip eine Zeile
        let chipRows = allDays.map { UFDayExtras.marks($0).count + $0.list("deadlines").count + $0.list("notices").count }.max() ?? 0
        let chipHeight: CGFloat = chipRows > 0 ? 2 + CGFloat(chipRows) * 23.2 : 0
        return GeometryReader { g in
            // Montag–Sonntag passen ab 92 pt je Spalte mit schmaler Zeitachse (13" hochkant: 105 pt; vorher mindestens
            // 900 pt Raster, Samstag abgeschnitten, Sonntag nur durch Wischen - Audit 03.11.2026); sonst Wochenende
            // nur mit Terminen (`TimetableColumns`), erst darunter waagrecht scrollen
            let cols = TimetableColumns.layout(days: allDays, width: g.size.width - 2)
            let days = cols.shown, col = cols.column, axisW = cols.axis
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        Color.clear.frame(width: axisW)
                        ForEach(Row.rows(days, key: "date")) { row in
                            let d = row.value
                            VStack(spacing: 0) {
                                Text((col < 100 ? ShellState.days : UFKind.daysLong)[d.i("weekday") ?? 0]).ufFont(13.12, 600)
                                    .foregroundStyle(d.s("date") == today ? UF.accentText : UF.text)
                                    .accessibilityLabel(UFKind.daysLong[d.i("weekday") ?? 0])
                                Text(dayMonth(d.s("date"))).ufFont(11.52).foregroundStyle(UF.muted)
                                // .tt-head: Feiertag/vorlesungsfrei, Fristen und Hinweise als Chips (holChips, dlChips, noteChips)
                                UFDayExtraChips(dd: d).padding(.horizontal, 4).padding(.top, 2)
                            }
                            .frame(width: col, alignment: .top)
                            .padding(.vertical, 7.2)
                            .background(UFDayExtras.background(d))
                        }
                    }
                    .ufBorderBottom()
                    HStack(alignment: .top, spacing: 0) {
                        axis(lo: lo, hi: hi, px: px).frame(width: axisW)
                            .overlay(alignment: .trailing) { Rectangle().fill(UF.line).frame(width: 1) }
                        ForEach(Row.rows(days, key: "date")) { row in
                            column(row.value, lo: lo, hi: hi, px: px, width: col, today: row.value.s("date") == today)
                        }
                    }
                }
                .frame(width: cols.total)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 } action: { gridWidth = $0 }
        .frame(height: 7.2 * 2 + 13.12 * 1.5 + 11.52 * 1.5 + chipHeight + 1 + px(hi) + 2)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .clipShape(RoundedRectangle(cornerRadius: UF.r))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
    }

    private func dayMonth(_ iso: String?) -> String {
        guard let d = Fmt.date(iso) else { return "" }
        let c = PlanData.cal.dateComponents([.day, .month], from: d)
        return String(format: "%02d.%02d.", c.day ?? 0, c.month ?? 0)
    }

    private func axis(lo: Int, hi: Int, px: @escaping (Int) -> CGFloat) -> some View {
        Color.clear
            .frame(height: px(hi))
            .overlay(alignment: .topTrailing) {
                ForEach(Array(stride(from: lo, through: hi, by: 60)), id: \.self) { m in
                    Text(UFTime.mh(m)).ufFont(10.88).foregroundStyle(UF.muted).fixedSize()
                        .padding(.trailing, 4)
                        .offset(y: px(m) - 10.88 * 1.5 / 2)
                }
            }
    }

    /// .tt-col: nur Hochschultermine (03.11.2026: Lernslots, freie Fenster und Sperrzeiten stehen im Lernkalender); Doppeltippen = neuer Termin
    private func column(_ d: JSONValue, lo: Int, hi: Int, px: @escaping (Int) -> CGFloat, width: CGFloat, today: Bool) -> some View {
        let date = d.s("date") ?? ""
        return ZStack(alignment: .topLeading) {
            // gleichzeitige Termine nebeneinander statt uebereinander (03.11.2026: einer verdeckte den anderen)
            let evs = d.list("events")
            let lanes = planLanes(evs.map { (UFTime.hm($0.s("start")), UFTime.hm($0.s("end"))) })
            ForEach(evs.indices, id: \.self) { i in
                let n = CGFloat(lanes[i].n), w = (width - 7 - 2 * (n - 1)) / n
                TimetableEventBlock(e: evs[i], width: w, px: px) { actions.openOccurrence(evs[i], date: date) }
                    .offset(x: 3 + CGFloat(lanes[i].lane) * (w + 2))
            }
        }
        .frame(width: width, height: px(hi), alignment: .topLeading)
        .background(hourLines(H))
        .background(today ? Color.mix(UF.accentSoft, 0.4, UF.surface) : .clear)
        .background(UFDayExtras.background(d))                                // .tt-col.is-hol / .is-free: gruen
        .overlay(alignment: .trailing) { Rectangle().fill(UF.line).frame(width: 1) }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 2).onEnded { v in
            // Doppelklick: Wochentag, Beginn auf 15 min gerundet, Ende +90 min, ab diesem Datum
            let m15 = Int(((Double(lo) + Double(v.location.y) / Double(H) * 60) / 15).rounded()) * 15
            let wd = d.i("weekday") ?? 0
            actions.eventDialog(nil, preset: ["weekday": .number(Double(wd)), "start_time": .string(UFTime.mh(m15)),
                                              "end_time": .string(UFTime.mh(m15 + 90)), "date_from": .string(date)])
        })
    }
}

/// Spalten der Stundenplan-Woche (reine Funktion, AuditApp20261103Tests): Zeitachse 52 pt, schmal 44 pt; alle sieben
/// Tage, wenn jede Spalte mindestens 92 pt bekommt (13" hochkant ~105 pt, iPad mini hochkant ~93 pt). Sonst Samstag
/// und Sonntag nur mit Terminen oder Hinweisen; passen auch die verbleibenden Spalten nicht, scrollt das Raster.
enum TimetableColumns {
    static let axisWide: CGFloat = 52
    static let axisCompact: CGFloat = 44
    static let minColumn: CGFloat = 92

    struct Result {
        let axis: CGFloat
        let shown: [JSONValue]
        let hidden: [JSONValue]
        let column: CGFloat
        let total: CGFloat
    }

    /// `width` 0 (noch nicht gemessen): alle Tage, nichts ausgeblendet
    static func layout(days: [JSONValue], width: CGFloat) -> Result {
        let w = max(0, width)
        let axis = w > 0 && w < 1000 ? axisCompact : axisWide
        var shown = days, hidden: [JSONValue] = []
        if w > 0, CGFloat(days.count) * minColumn > w - axis {
            let empty: (JSONValue) -> Bool = { d in
                (d.i("weekday") ?? 0) >= 5 && d.list("events").isEmpty && !UFDayExtras.hasAny(d)
            }
            hidden = days.filter(empty)
            shown = days.filter { !empty($0) }
        }
        let n = CGFloat(max(1, shown.count))
        let total = max(w, axis + n * minColumn)
        return Result(axis: axis, shown: shown, hidden: hidden, column: (total - axis) / n, total: total)
    }
}

/// .tt-ev: Flaeche in Termin-Farbe, weisse Schrift, Rand links 3px rgba(0,0,0,.18); Zustaende nicht besucht/faellt aus/verschoben
struct TimetableEventBlock: View {
    let e: JSONValue
    let width: CGFloat
    let px: (Int) -> CGFloat
    let open: () -> Void

    var body: some View {
        let top = px(UFTime.hm(e.s("start"))), h = max(24, px(UFTime.hm(e.s("end"))) - top - 2)
        let st = e.s("status") ?? "teilnahme"
        let ausfall = st == "ausfall"
        let room = e.s("room").map { $0.isEmpty ? "" : " · " + String($0.prefix(18)) } ?? ""
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                // schmal (gleichzeitige Termine): Kurzname des Fachs, umbrechend, ohne Raum (03.11.2026)
                let narrow = width < 80
                Text(narrow ? PlanNames.tinyName(e.s("title")) : UFFmt.shortName(e.s("title"))).ufFont(11.84, 700, lh: 1.2)
                    // ein Wort zu breit: eine Zeile, verkleinert statt mitten im Wort umbrochen
                    .lineLimit(narrow && PlanNames.wordsFit(PlanNames.tinyName(e.s("title")), width: width - 9, size: 11.84) ? 3 : 1)
                    .minimumScaleFactor(0.7).truncationMode(.tail)
                if narrow {
                    // schmale Spur: die Uhrzeit in einer Zeile, eher kleiner als "10:0/0" (Spalten seit 03.11.2026 schmaler)
                    Text(e.s("start") ?? "").ufFont(10, lh: 1.2).opacity(0.9).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    Text("\(e.s("start") ?? "")–\(e.s("end") ?? "")\(room)").ufFont(10, lh: 1.2).opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)       // overflow: hidden schneidet ab statt zu kuerzen
                }
            }
            .strikethrough(st == "nicht_teilnahme" || ausfall)
            .foregroundStyle(ausfall ? UF.muted : .white)
            .padding(.vertical, 4 + (ausfall ? ufB : 0)).padding(.trailing, width < 80 ? 3 : 6.4).padding(.leading, (width < 80 ? 3 : 6.4) + 3)
            .padding(.top, UFCancel.label(e) != nil ? 14 : 0)
            .frame(width: width, height: h, alignment: .topLeading)
            .clipped()
            .background(ausfall ? UF.surface2 : Color(hex: e.s("color")))
            .overlay(alignment: .leading) { if !ausfall { Rectangle().fill(Color.black.opacity(0.18)).frame(width: 3) } }
            .overlay { if ausfall { RoundedRectangle(cornerRadius: 8).strokeBorder(UF.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) } }
            // Ausfall aus einer Ankuendigung, noch nicht bestaetigt: Rahmen in Warnfarbe, der Termin steht noch
            .overlay { if UFCancel.unsure(e) { RoundedRectangle(cornerRadius: 8).strokeBorder(UF.warn, lineWidth: 2) } }
            .overlay(alignment: .topTrailing) {
                if let mark = UFCancel.label(e) { UFCancelMark(text: mark, size: 9.6, pill: true, iconOnly: width < 80).padding(3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .ufShadow(.sm)
            .opacity(st == "nicht_teilnahme" ? 0.45 : st == "verschoben" ? 0.35 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .offset(y: top)
        .help([e.s("title"), UFCancel.helpText(e)].compactMap { $0 }.joined(separator: " · "))
    }
}

/// .tt-ev.study: Flaeche --surface, Rand 1px und links 4px in Modulfarbe (nachholen: --bad)
struct TimetableStudyBlock: View {
    let p: JSONValue
    let width: CGFloat
    let px: (Int) -> CGFloat
    let open: () -> Void

    var body: some View {
        let top = px(UFTime.hm(p.s("start_time"))), h = max(24, px(UFTime.hm(p.s("end_time"))) - top - 2)
        let st = p.s("status") ?? "geplant"
        let pc = st == "nachholen" ? UF.bad : Color(hex: p.s("color"))
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Text(UFFmt.shortName(p.s("subject"))).ufFont(11.84, 700, lh: 1.2).lineLimit(1)
                Text("\(p.s("start_time") ?? "")–\(p.s("end_time") ?? "") · \(p.s("title") ?? "")").ufFont(10, lh: 1.2).opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(UF.text)
            .padding(.vertical, 4 + ufB).padding(.trailing, 6.4 + ufB).padding(.leading, 6.4 + 4)
            .frame(width: width, height: h, alignment: .topLeading)
            .background(UF.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pc, lineWidth: 1))
            .overlay(alignment: .leading) { Rectangle().fill(pc).frame(width: 4) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .ufShadow(.sm)
            .opacity(st == "erledigt" ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .offset(y: top)
        .help("\(p.s("subject") ?? ""): \(p.s("title") ?? "")")
    }
}

// MARK: - Import (importDialog, runImport, previewDialog)

struct TimetableImportDialog: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufClose) private var close
    @State private var picking: String?

    /// Eine Quelle des Imports: Kennung, Icon, Beschriftung, Hauptweg
    struct Source: Equatable {
        let id: String, icon: String, text: String, primary: Bool
    }

    /// Angebotene Quellen. Ohne PC (lokales Backend) keine KI-Wege (PDF, Bild, Text): sie endeten nach der
    /// Dateiauswahl nur mit "KI-Funktionen gibt es in dieser Version nicht" (AUFTRAG §2 Punkt 4). "Aus Stud.IP" nur
    /// an einer Hochschule mit Stud.IP; an der Uni Hildesheim kommt der LSF-Stundenplan mit dem Abgleich.
    static func sources(local: Bool, offersStudIP: Bool) -> [Source] {
        var out: [Source] = []
        if offersStudIP { out.append(Source(id: "studip", icon: "sync", text: "Aus Stud.IP übernehmen (Termine deiner Kurse)", primary: true)) }
        out.append(Source(id: "ics", icon: "calendar", text: "Kalenderdatei (ICS)", primary: !offersStudIP))
        if !local {
            out.append(Source(id: "pdf", icon: "file-text", text: "PDF-Stundenplan (Texterkennung + KI)", primary: false))
            out.append(Source(id: "image", icon: "image", text: "Screenshot / Foto (KI-Bildanalyse)", primary: false))
            out.append(Source(id: "text", icon: "type", text: "Text einfügen (KI)", primary: false))
        }
        out.append(Source(id: "manual", icon: "plus", text: "Manuell eingeben", primary: false))
        return out
    }

    var body: some View {
        UFDialog("Stundenplan importieren", icon: "download") {
            Text("Du siehst zuerst eine bearbeitbare Vorschau. Erst nach Bestätigung werden die Termine übernommen.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 5.6)
            VStack(spacing: 8) {
                ForEach(Self.sources(local: session.api?.isLocal ?? true, offersStudIP: studip.offersStudIP), id: \.id) { s in
                    source(s.id, s.icon, s.text, primary: s.primary)
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: types(picking)) { result in
            let src = picking ?? "ics"
            picking = nil
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { toast.show("Datei konnte nicht gelesen werden"); return }
            close()
            TimetableImport.run(source: src, file: (url.lastPathComponent, mime(src, url), data), session: session, overlay: overlay, toast: toast, router: router)
        }
    }

    private func source(_ src: String, _ icon: String, _ text: String, primary: Bool = false) -> some View {
        Button {
            switch src {
            case "manual": close(); PlanEnv.make(session, overlay, toast, router).eventDialog(nil)
            case "text": close(); overlay.modal { TimetableImportTextDialog() }
            case "studip": close(); TimetableImport.run(source: src, session: session, overlay: overlay, toast: toast, router: router)
            default: picking = src
            }
        } label: {
            HStack(spacing: 7.2) { UFIcon(icon, size: 16); Text(text) }.frame(maxWidth: .infinity)
        }
        .buttonStyle(UFButtonStyle(kind: primary ? .primary : .normal))
    }

    private func types(_ src: String?) -> [UTType] {
        switch src {
        case "ics": return [UTType(filenameExtension: "ics") ?? .calendarEvent, .calendarEvent]
        case "pdf": return [.pdf]
        default: return [.image]
        }
    }

    private func mime(_ src: String, _ url: URL) -> String {
        switch src {
        case "ics": return "text/calendar"
        case "pdf": return "application/pdf"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        }
    }
}

/// Modal "Stundenplan als Text"
struct TimetableImportTextDialog: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var text = ""

    var body: some View {
        UFDialog("Stundenplan als Text") {
            UFTextArea(placeholder: "Montag 08:00-09:30 Mathematik I Vorlesung Hörsaal A\nDienstag 10:00-11:30 Programmieren I ...", text: $text, minHeight: 210)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Analysieren", kind: .primary) {
                close()
                TimetableImport.run(source: "text", text: text, session: session, overlay: overlay, toast: toast, router: router)
            }
        }
    }
}

@MainActor
enum TimetableImport {
    /// Text im Wartedialog je Quelle: von der KI nur bei den KI-Wegen des eigenen Servers (vorher auch beim ICS-Import)
    nonisolated static func waitText(_ source: String) -> String {
        switch source {
        case "studip": return "Termine werden zusammengefasst."
        case "ics": return "Kalenderdatei wird gelesen."
        default: return "Die KI liest den Stundenplan. Das dauert etwa eine halbe Minute."
        }
    }

    /// runImport: Wartedialog, POST /api/timetable/import/preview (Formular), dann die Vorschau
    static func run(source: String, text: String? = nil, file: (name: String, mime: String, data: Data)? = nil,
                    session: Session, overlay: UFOverlay, toast: UFToastCenter, router: UFRouter) {
        guard let api = session.api else { return }
        let wait = overlay.modal {
            UFDialog("Import läuft…") {
                Text(waitText(source)).ufFont(14.5).foregroundStyle(UF.muted)
            } foot: { EmptyView() }
        }
        Task {
            var fields = ["source": source]
            if let text { fields["text"] = text }
            do {
                let r = try await api.form("/api/timetable/import/preview", fields: fields, file: file.map { ("upload", $0.name, $0.mime, $0.data) })
                overlay.close(wait)
                overlay.modal(wide: true) { TimetablePreviewDialog(r: r, source: source) }
            } catch {
                overlay.close(wait)
                toast.show("Import fehlgeschlagen: " + error.localizedDescription, seconds: 6)
            }
        }
    }
}

/// Modal "Importvorschau · N Veranstaltungen" (breit): Tabelle mit Auswahl, Titel, Art, Tag, Zeit, Raum, Modul
struct TimetablePreviewDialog: View {
    let r: JSONValue
    let source: String
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    struct Entry: Identifiable {
        let id: Int
        var selected: Bool
        var title, kind, start, end, room: String
        var weekday: Int
        var module: Int
        let raw: JSONValue
    }

    @State private var entries: [Entry] = []
    @State private var remove: Set<Int> = []

    var body: some View {
        let diff = r["diff"] ?? .null
        let removed = diff.list("removed")
        UFDialog("Importvorschau · \(r.list("entries").count) Veranstaltungen") {
            Text(summary(diff, removed: removed.count)).ufFont(13.12).foregroundStyle(UF.muted).padding(.bottom, 5.6)
            ScrollView {
                VStack(spacing: 0) {
                    header
                    ForEach($entries) { $e in row($e) }
                }
            }
            .frame(maxHeight: 451)                                         // max-height: 55vh
            if !removed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    UFFlexWrap(gap: 6.4) {
                        Text("Nicht mehr im neuen Plan:").ufFont(14.5, 700).foregroundStyle(UF.text)
                        ForEach(removed.indices, id: \.self) { i in
                            let x = removed[i], id = x.i("id") ?? 0
                            Button { if remove.contains(id) { remove.remove(id) } else { remove.insert(id) } } label: {
                                HStack(spacing: 4.8) {
                                    Image(systemName: remove.contains(id) ? "checkmark.square.fill" : "square").foregroundStyle(remove.contains(id) ? UF.accent : UF.muted)
                                    Text("\(x.s("title") ?? "") (\(ShellState.days[x.i("weekday") ?? 0]) \(x.s("start_time") ?? ""))")
                                }
                                .ufFont(12.8).foregroundStyle(UF.text2)
                                .padding(.vertical, 4 + ufB).padding(.horizontal, 10.4 + ufB)
                                .background(Capsule().fill(UF.surface)).overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Angehakte werden entfernt.").ufFont(11.84).foregroundStyle(UF.muted)
                }
                .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
                .padding(.top, 9.6)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Übernehmen", kind: .primary) { Task { await confirm(diff) } }
        }
        .onAppear {
            if entries.isEmpty {
                entries = r.list("entries").enumerated().map { i, e in
                    Entry(id: i, selected: Self.preselected(e, diff: diff, source: source, rows: r.list("entries")), title: e.s("title") ?? "", kind: e.s("kind") ?? "vorlesung",
                          start: e.s("start_time") ?? "", end: e.s("end_time") ?? "", room: e.s("room") ?? "", weekday: e.i("weekday") ?? 0,
                          module: e.i("module_id") ?? 0, raw: e)
                }
            }
        }
    }

    private func summary(_ diff: JSONValue, removed: Int) -> String {
        var s = "\(diff.list("new").count) neu · \(diff.list("changed").count) geändert · \(diff.list("same").count) unverändert"
        if removed > 0 { s += " · \(removed) nicht mehr enthalten" }
        s += ". "
        if r.list("entries").contains(where: { $0["uncertain"]?.bool == true }) {
            s += "Orange markierte Zeilen sind unsicher (z. B. mehrere parallele Übungsgruppen): bitte prüfen und nur deine Gruppe auswählen."
        }
        let rows = r.list("entries")
        if source == "studip", rows.contains(where: { Self.existingID(diff, $0, rows: rows) != nil }) {
            s += (s.hasSuffix(". ") ? "" : " ") + "Schon übernommene Termine sind nicht angehakt; Anhaken setzt Zeit, Raum und Art auf Stud.IP zurück."
        }
        return s
    }

    /// Vorhandene Serie zu einer Zeile wie impConfirm: aus diff.changed, sonst diff.same mit gleichem Titel und
    /// Wochentag. Kurszeiten aus Stud.IP genau ueber ihre Stud.IP-ID (Vorlesung und Gruppe eines Kurses am selben Tag
    /// haben denselben Titel; die Zuordnung zur Serie macht das lokale Backend)
    static func existing(_ diff: JSONValue, title: String?, weekday: Int?, studipID: String? = nil) -> JSONValue? {
        if let id = studipID { return (diff.list("changed") + diff.list("same")).first { $0.s("studip_id") == id } }
        return diff.list("changed").first { $0.s("title") == title && $0.i("weekday") == weekday }
            ?? diff.list("same").first { $0.s("title") == title && $0.i("weekday") == weekday }
    }

    static func existing(_ diff: JSONValue, _ e: JSONValue) -> JSONValue? {
        existing(diff, title: e.s("title"), weekday: e.i("weekday"), studipID: e.s("studip_id"))
    }

    /// Vorhandene Serie einer Zeile wie `impConfirm` seit 196555e: die `existing_id` der Zeile selbst
    /// (`diff_against_existing` setzt sie an jede Zeile mit vorhandener Serie). Strenger als die Web-App: markiert die
    /// Vorschau schon andere Zeilen, ist eine Zeile ohne Schluessel neu; die Suche ueber Titel und Wochentag traefe
    /// sonst die Serie einer anderen Zeile desselben Kurses am selben Tag. Nur ohne jede Markierung (aeltere Fassung des
    /// PC-Servers) wie bisher ueber diff.changed/diff.same; `title`/`weekday` sind dann die Werte des Dialogs.
    static func existingID(_ diff: JSONValue, _ e: JSONValue, rows: [JSONValue], title: String? = nil, weekday: Int? = nil) -> JSONValue? {
        if let x = e["existing_id"], x != .null { return x }
        if rows.contains(where: { ($0["existing_id"] ?? .null) != .null }) { return nil }
        return existing(diff, title: title ?? e.s("title"), weekday: weekday ?? e.i("weekday"), studipID: e.s("studip_id"))?["existing_id"]
    }

    /// Vorauswahl einer Zeile: wie in der Web-App alle ausser offenen Gruppen. Aus Stud.IP (auf dem Geraet der Weg zur
    /// Gruppenwahl) bleiben schon uebernommene Termine frei; sonst setzte "Übernehmen" Zeit, Raum, Art und Modul, die
    /// der Nutzer geaendert hat, auf die Werte aus Stud.IP zurueck.
    static func preselected(_ e: JSONValue, diff: JSONValue, source: String, rows: [JSONValue] = []) -> Bool {
        guard e["selected"]?.bool != false else { return false }
        return source != "studip" || existingID(diff, e, rows: rows) == nil
    }

    private var header: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 22)
            ForEach(["Veranstaltung", "Art", "Tag", "Von", "Bis", "Raum", "Modul"], id: \.self) { h in
                Text(h).frame(width: width(h), alignment: .leading)
            }
        }
        .ufFont(13.12, 700).foregroundStyle(UF.text)
        .padding(.vertical, 4.8).padding(.horizontal, 4)
        .ufBorderBottom()
    }

    private func width(_ col: String) -> CGFloat {
        ["Veranstaltung": 200, "Art": 120, "Tag": 64, "Von": 78, "Bis": 78, "Raum": 96, "Modul": 140][col] ?? 80
    }

    private func row(_ e: Binding<Entry>) -> some View {
        let raw = e.wrappedValue.raw
        let modules = (r.list("modules")).compactMap { m in m.i("id").map { ($0, UFFmt.shortName(m.s("name"))) } }
        return HStack(alignment: .center, spacing: 4) {
            Button { e.wrappedValue.selected.toggle() } label: {
                Image(systemName: e.wrappedValue.selected ? "checkmark.square.fill" : "square").foregroundStyle(e.wrappedValue.selected ? UF.accent : UF.muted)
                    .ufHitArea(slop: EdgeInsets(top: .infinity, leading: .infinity, bottom: .infinity, trailing: 2))
            }
            .buttonStyle(.plain).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                UFSmallInput(text: e.title)
                if let hint = raw.s("hint"), !hint.isEmpty { Text(hint).ufFont(11.84).foregroundStyle(UF.muted) }
                if raw["existing_id"].map({ !$0.isNull }) == true {
                    Text("vorhanden\(raw.s("old_start").map { " (bisher \($0)–\(raw.s("old_end") ?? ""))" } ?? "")").ufFont(11.84).foregroundStyle(UF.muted)
                }
            }
            .frame(width: width("Veranstaltung"), alignment: .leading)
            UFSelect(options: UFKind.all, selection: e.kind, small: true).frame(width: width("Art"), alignment: .leading)
            UFSelect(options: ShellState.days.enumerated().map { ($0.offset, $0.element) }, selection: e.weekday, small: true).frame(width: width("Tag"), alignment: .leading)
            UFTimeField(hm: e.start, small: true).frame(width: width("Von"))
            UFTimeField(hm: e.end, small: true).frame(width: width("Bis"))
            UFSmallInput(text: e.room).frame(width: width("Raum"))
            UFSelect(options: [(0, "–")] + modules, selection: e.module, small: true).frame(width: width("Modul"), alignment: .leading)
        }
        .padding(.vertical, 4.8).padding(.horizontal, 4)
        .background(raw["uncertain"]?.bool == true ? UF.warnSoft : .clear)
        .opacity(e.wrappedValue.selected ? 1 : 0.5)
        .ufBorderBottom()
    }

    /// impConfirm: gewaehlte Zeilen mit existing_id aus diff.changed/diff.same (gleicher Titel und Wochentag)
    private func confirm(_ diff: JSONValue) async {
        let chosen = entries.filter(\.selected)
        if chosen.isEmpty { toast.show("Nichts ausgewählt"); return }
        let body: [JSONValue] = chosen.map { e in
            var o = e.raw.object ?? [:]
            o["selected"] = true
            o["title"] = .string(e.title); o["kind"] = .string(e.kind); o["weekday"] = .number(Double(e.weekday))
            o["start_time"] = .string(e.start); o["end_time"] = .string(e.end); o["room"] = .string(e.room)
            o["module_id"] = e.module == 0 ? .null : .number(Double(e.module))
            o["existing_id"] = Self.existingID(diff, e.raw, rows: r.list("entries"), title: e.title, weekday: e.weekday) ?? .null
            return .object(o)
        }
        guard let api = session.api else { return }
        do {
            let res = try await api.value("/api/timetable/import/confirm", method: "POST",
                                          body: ["entries": .array(body), "source": .string(source), "import_id": r["import_id"] ?? .null,
                                                 "remove_ids": .array(remove.sorted().map { .number(Double($0)) })])
            close()
            let removedN = res.i("removed") ?? 0
            let summary = "\(res.i("new") ?? 0) neu, \(res.i("updated") ?? 0) aktualisiert\(removedN > 0 ? ", \(removedN) entfernt" : "")"
            // Lernslots, die jetzt mit Terminen zusammenfallen, legt der Lernkalender neu (03.11.2026: kein Dialog und
            // kein reslot mehr im Stundenplan) – eine Zeile, und die Ansicht wechselt dorthin
            let conflicts = res.list("conflicts").count
            if conflicts > 0 {
                toast.show("\(summary) · \(Self.conflictHint(conflicts))", seconds: 6)
                router.go(.plan())
            } else {
                toast.show(summary)
                router.reload()
            }
        } catch { toast.show(error.localizedDescription) }
    }

    /// Hinweis nach dem Import, wenn Lernslots mit den neuen Terminen zusammenfallen (importConflictHint in views-tt.js)
    static func conflictHint(_ n: Int) -> String {
        "\(n) Lernslot\(n == 1 ? " überschneidet" : "s überschneiden") sich – im Lernkalender neu legen"
    }
}

/// kleines Eingabefeld in der Importtabelle (.imp-table input: .2rem .3rem, Radius 6, Rand --line, .8rem)
struct UFSmallInput: View {
    @Binding var text: String
    var body: some View {
        TextField("", text: $text)
            .ufFont(12.8)
            .padding(.vertical, 3.2 + ufB).padding(.horizontal, 4.8 + ufB)
            .background(RoundedRectangle(cornerRadius: 6).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UF.line, lineWidth: 1))
    }
}
