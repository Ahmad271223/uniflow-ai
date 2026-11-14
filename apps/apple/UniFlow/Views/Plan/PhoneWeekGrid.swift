import SwiftUI
import UniFlowCore

/// Woche am iPhone als echtes Raster (Auftrag des Inhabers 14.11.2026: „bei Planer steht Woche, aber es wird eine
/// Tagesansicht gezeigt“). Sieben Spalten Montag–Sonntag mit Zeitachse links, darin Uni-Termine und Lernblöcke an
/// ihrem Platz – dieselbe Spuren-Rechnung wie am iPad (`planLanes`), nur fürs schmale iPhone gezeichnet: winzige
/// Zeitachse, Kurznamen über mehrere Zeilen, sehr kurze Blöcke nur als Farbe. Nichts scrollt waagerecht.
/// Das iPad behält `PlanWeekGrid` unverändert; die Tagesliste (`PhoneWeekListView`) bleibt für den Stundenplan.
enum PhoneWeekGeometry {
    /// Zeitachse links (Beschriftung "08" statt "08:00")
    static let axis: CGFloat = 26
    /// Höhe einer Stunde
    static let hour: CGFloat = 46
    /// Abstand zwischen zwei Spalten
    static let gap: CGFloat = 1.5

    static func column(width: CGFloat, days: Int) -> CGFloat {
        let n = CGFloat(max(1, days))
        return max(0, (width - axis - gap * (n - 1)) / n)
    }

    static func y(_ minute: Int, lo: Int) -> CGFloat { CGFloat(minute - lo) / 60 * hour }

    /// Sichtbarer Zeitraum: 8–19 Uhr, erweitert um alles, was früher beginnt oder später endet (volle Stunden).
    /// Nie vor 0 und nie nach 24 Uhr: kaputte Zeiten aus altem Planer-Bestand ("25:15") zogen die Achse bis "26"
    /// (Foto des Inhabers 14.11.2026).
    static func range(_ days: [JSONValue]) -> (lo: Int, hi: Int) {
        var starts = [8 * 60], ends = [19 * 60]
        for dd in days {
            for e in dd.list("events") where e.s("status") != "verschoben" {
                let t = UFTime.span(e.s("start"), e.s("end"))
                starts.append(t.start); ends.append(t.end)
            }
            for p in dd.list("packages") where p.s("start_time") != nil {
                let t = UFTime.span(p.s("start_time"), p.s("end_time"))
                starts.append(t.start); ends.append(t.end)
            }
        }
        let lo = max(0, (starts.min() ?? 480) / 60 * 60)
        let hi = min(UFTime.dayEnd, Int((Double(ends.max() ?? 1140) / 60).rounded(.up)) * 60)
        return (lo, max(lo + 60, hi))
    }

    /// Lage eines Blocks in seiner Spalte (Spuren nebeneinander, mindestens 16 pt hoch)
    static func block(start: Int, end: Int, lane: PlanLane, width: CGFloat, lo: Int) -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        let top = y(start, lo: lo)
        let h = max(16, y(end, lo: lo) - top - 1)
        let n = CGFloat(lane.n)
        let w = max(0, (width - 2) / n - (lane.n > 1 ? 1 : 0))
        return (1 + CGFloat(lane.lane) * (width - 2) / n, top, w, h)
    }

    /// Sehr kurzer oder sehr schmaler Block: nur Farbe, kein Text (sonst stünde dort „…“)
    static func showsText(width: CGFloat, height: CGFloat) -> Bool { height >= 26 && width >= 26 }
}

/// Ein Eintrag der Woche (Uni-Termin oder Lernblock) für Raster und VoiceOver
struct PhoneWeekEntry: Identifiable {
    enum Kind { case event, package }
    let id: String
    let kind: Kind
    let value: JSONValue
    let start: Int
    let end: Int

    var done: Bool {
        switch kind {
        case .event: return value.s("status") == "nicht_teilnahme" || value.s("status") == "ausfall"
        case .package: return value.s("status") == "erledigt"
        }
    }

    var title: String {
        switch kind {
        case .event: return value.s("title") ?? ""
        case .package: return value.s("subject") ?? value.s("title") ?? "Lernblock"
        }
    }

    var color: Color {
        switch kind {
        case .event: return Color(hex: value.s("color"))
        case .package: return PlanNames.studyColor(value)
        }
    }

    /// „Grundlagen der Informatik, Vorlesung, Mittwoch 11. November, 14:00 bis 16:00, nicht besucht“
    func accessibility(day: JSONValue) -> String {
        let f = Fmt.formatter("EEEE d. MMMM")
        let when = Fmt.date(day.s("date")).map { f.string(from: $0) } ?? ""
        var parts = [title]
        switch kind {
        case .event:
            if let k = value.s("kind"), let label = UFKind.label[k] { parts.append(label) }
        case .package:
            parts.append("Lernblock")
            if let t = value.s("title"), !t.isEmpty, t != title { parts.append(t) }
        }
        parts.append(when)
        parts.append("\(UFTime.mh(start)) bis \(UFTime.mh(end))")
        switch kind {
        case .event:
            if let r = value.s("room"), !r.isEmpty { parts.append(r) }
            if let s = ["nicht_teilnahme": "nicht besucht", "ausfall": "fällt aus"][value.s("status") ?? ""] { parts.append(s) }
        case .package:
            let tasks = value.list("tasks")
            if !tasks.isEmpty { parts.append("\(tasks.filter { $0.s("status") == "erledigt" }.count) von \(tasks.count) erledigt") }
            if done { parts.append("erledigt") }
        }
        return parts.joined(separator: ", ")
    }

    /// Einträge eines Tages mit Uhrzeit, nach Beginn
    static func timed(_ dd: JSONValue) -> [PhoneWeekEntry] {
        let evs = dd.list("events").filter { $0.s("status") != "verschoben" }.enumerated().map { i, e in
            let t = UFTime.span(e.s("start"), e.s("end"))
            return PhoneWeekEntry(id: "e\(i)-\(e.i("event_id") ?? 0)", kind: .event, value: e, start: t.start, end: t.end)
        }
        let pks = dd.list("packages").filter { $0.s("start_time") != nil }.map { p -> PhoneWeekEntry in
            let t = UFTime.span(p.s("start_time"), p.s("end_time"))
            return PhoneWeekEntry(id: "p\(p.i("id") ?? 0)", kind: .package, value: p, start: t.start, end: t.end)
        }
        return (evs + pks).sorted { $0.start < $1.start }
    }

    /// Lernblöcke ohne Uhrzeit (eigene schmale Zeile über dem Raster)
    static func untimed(_ dd: JSONValue) -> [JSONValue] {
        dd.list("packages").filter { $0.s("start_time") == nil && !$0.list("tasks").isEmpty }
    }
}

struct PhoneWeekGrid: View {
    let d: PlanData
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    var body: some View {
        let days = d.days
        let (lo, hi) = PhoneWeekGeometry.range(days)
        let height = PhoneWeekGeometry.y(hi, lo: lo)
        let hasUntimed = days.contains { !PhoneWeekEntry.untimed($0).isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { g in
                let col = PhoneWeekGeometry.column(width: g.size.width, days: days.count)
                VStack(alignment: .leading, spacing: 0) {
                    heads(days, col: col)
                    if hasUntimed { untimedRow(days, col: col) }
                    grid(days, col: col, lo: lo, hi: hi, height: height)
                }
            }
            .frame(height: headHeight + (hasUntimed ? untimedHeight : 0) + height)
            legend.padding(.top, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneWeekGrid")
    }

    private let headHeight: CGFloat = 46
    private let untimedHeight: CGFloat = 30

    // MARK: Kopf

    private func heads(_ days: [JSONValue], col: CGFloat) -> some View {
        HStack(alignment: .top, spacing: PhoneWeekGeometry.gap) {
            Color.clear.frame(width: PhoneWeekGeometry.axis, height: headHeight)
            ForEach(Row.rows(days, key: "date")) { row in
                head(row.value).frame(width: col, height: headHeight)
            }
        }
    }

    private func head(_ dd: JSONValue) -> some View {
        let date = dd.s("date") ?? ""
        let today = date == UFFmt.todayISO()
        let day = Fmt.date(date).map { PlanData.cal.component(.day, from: $0) } ?? 0
        let name = ShellState.days[dd.i("weekday") ?? 0]
        return Button { router.go(.plan(view: "day", date: date, module: d.module.isEmpty ? nil : d.module)) } label: {
            VStack(spacing: 1) {
                Text(name).ufFont(10.5, 600).foregroundStyle(today ? UF.accentText : UF.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(day)").ufFont(14, 700).foregroundStyle(today ? UF.accentText : UF.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if UFDayExtras.hasAny(dd) {
                    Circle().fill(UFDayExtras.background(dd) == .clear ? UF.warn : UF.ok).frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(today ? UF.accentSoft : UFDayExtras.fill(dd, over: .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(UFKind.daysLong[dd.i("weekday") ?? 0]) \(day).")
        .accessibilityHint("Zeigt diesen Tag")
        .accessibilityIdentifier("phoneWeek.head.\(date)")
    }

    // MARK: Ohne Uhrzeit

    private func untimedRow(_ days: [JSONValue], col: CGFloat) -> some View {
        HStack(alignment: .center, spacing: PhoneWeekGeometry.gap) {
            // Zeitachse ist 26 pt schmal: nur ein Symbol statt "ganztags" (VoiceOver nennt es in jedem Eintrag)
            UFIcon("clock", size: 10).foregroundStyle(UF.muted)
                .frame(width: PhoneWeekGeometry.axis, height: untimedHeight)
                .accessibilityHidden(true)
            ForEach(Row.rows(days, key: "date")) { row in
                let list = PhoneWeekEntry.untimed(row.value)
                Group {
                    if let p = list.first {
                        Button { actions.openPackage(p.i("id") ?? 0) } label: {
                            Text(list.count > 1 ? "\(list.count) Pakete" : UFFmt.shortName(p.s("subject") ?? p.s("title")))
                                .ufFont(8.8, 600).foregroundStyle(UF.text).lineLimit(1).minimumScaleFactor(0.6)
                                .padding(.horizontal, 3).frame(maxWidth: .infinity, minHeight: 22)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.mix(PlanNames.studyColor(p), 0.14, UF.surface)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(list.count > 1
                            ? "\(list.count) Lernpakete ohne Uhrzeit am \(UFKind.daysLong[row.value.i("weekday") ?? 0])"
                            : "Lernpaket ohne Uhrzeit, \(UFFmt.shortName(p.s("subject") ?? p.s("title"))), \(UFKind.daysLong[row.value.i("weekday") ?? 0])")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: col, height: untimedHeight)
            }
        }
        .accessibilityIdentifier("phoneWeek.untimed")
    }

    // MARK: Raster

    private func grid(_ days: [JSONValue], col: CGFloat, lo: Int, hi: Int, height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: PhoneWeekGeometry.gap) {
            axis(lo: lo, hi: hi, height: height)
            ForEach(Row.rows(days, key: "date")) { row in
                column(row.value, col: col, lo: lo, hi: hi, height: height)
            }
        }
    }

    private func axis(lo: Int, hi: Int, height: CGFloat) -> some View {
        Color.clear
            .frame(width: PhoneWeekGeometry.axis, height: height)
            .overlay(alignment: .topTrailing) {
                ForEach(Array(stride(from: lo, through: hi, by: 60)), id: \.self) { m in
                    Text(String(format: "%02d", m / 60)).ufFont(9, 600).foregroundStyle(UF.muted).fixedSize()
                        .padding(.trailing, 3)
                        .offset(y: PhoneWeekGeometry.y(m, lo: lo) - 7)
                }
            }
            .accessibilityHidden(true)
    }

    private func column(_ dd: JSONValue, col: CGFloat, lo: Int, hi: Int, height: CGFloat) -> some View {
        let date = dd.s("date") ?? ""
        let today = date == UFFmt.todayISO()
        let entries = PhoneWeekEntry.timed(dd)
        let lanes = planLanes(entries.map { ($0.start, $0.end) })
        return ZStack(alignment: .topLeading) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                block(entry, day: dd, lane: lanes[i], col: col, lo: lo)
            }
            UFNowLine(date: date, lo: lo, hi: hi, width: col, y: { PhoneWeekGeometry.y($0, lo: lo) }).zIndex(3)
        }
        .frame(width: col, height: height, alignment: .topLeading)
        .background(hourLines(PhoneWeekGeometry.hour))
        .background(today ? Color.mix(UF.accentSoft, 0.4, UF.surface) : .clear)
        .background(UFDayExtras.fill(dd, over: .clear))
        .overlay(alignment: .leading) { Rectangle().fill(UF.line).frame(width: 1) }
        .accessibilityElement(children: .contain)
    }

    private func block(_ entry: PhoneWeekEntry, day: JSONValue, lane: PlanLane, col: CGFloat, lo: Int) -> some View {
        let f = PhoneWeekGeometry.block(start: entry.start, end: entry.end, lane: lane, width: col, lo: lo)
        let date = day.s("date") ?? ""
        let c = entry.color
        let isPackage = entry.kind == .package
        return Button {
            switch entry.kind {
            case .event: actions.openOccurrence(entry.value, date: date)
            case .package: actions.openPackage(entry.value.i("id") ?? 0)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if PhoneWeekGeometry.showsText(width: f.w, height: f.h) {
                    Text(PlanNames.tinyName(entry.title)).ufFont(8.8, 700, lh: 1.1).foregroundStyle(UF.text)
                        .lineLimit(f.h >= 46 ? 2 : 1).minimumScaleFactor(0.75)
                        .multilineTextAlignment(.leading)
                    if f.h >= 60 {
                        Text(UFTime.mh(entry.start)).ufFont(8, lh: 1.1).foregroundStyle(UF.text2).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 2).padding(.leading, 4).padding(.trailing, 2)
            .frame(width: f.w, height: f.h, alignment: .topLeading)
            .clipped()
            .background(Color.mix(c, isPackage ? 0.10 : 0.16, UF.surface))
            .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: 2.5) }
            .overlay {
                if isPackage {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(c.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                }
            }
            .overlay(alignment: .topTrailing) {
                if entry.done {
                    UFIcon("check", size: 8).foregroundStyle(UF.muted).padding(1.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(entry.done ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .offset(x: f.x, y: f.y)
        .zIndex(1)
        .accessibilityLabel(entry.accessibility(day: day))
        .accessibilityHint(isPackage ? "Öffnet das Lernpaket" : "Öffnet den Termin")
        .accessibilityIdentifier("phoneWeek.block.\(entry.id)")
    }

    private var legend: some View {
        UFFlexWrap(gap: 12, rowGap: 5) {
            item("Uni-Termin") {
                RoundedRectangle(cornerRadius: 3).fill(Color.mix(UF.accent, 0.16, UF.surface))
                    .overlay(alignment: .leading) { Rectangle().fill(UF.accent).frame(width: 2.5) }
            }
            item("Lernblock") {
                RoundedRectangle(cornerRadius: 3).fill(Color.mix(UF.info, 0.10, UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(UF.info, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])))
            }
            item("erledigt") {
                RoundedRectangle(cornerRadius: 3).fill(Color.mix(UF.info, 0.10, UF.surface)).opacity(0.45)
            }
        }
    }

    private func item<S: View>(_ text: String, @ViewBuilder swatch: () -> S) -> some View {
        HStack(spacing: 4) {
            swatch().frame(width: 11, height: 11)
            Text(text).fixedSize()
        }
        .accessibilityElement(children: .combine)
        .ufFont(11).foregroundStyle(UF.muted)
    }
}
