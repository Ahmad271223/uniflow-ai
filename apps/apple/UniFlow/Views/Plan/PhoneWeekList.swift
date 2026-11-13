import SwiftUI
import UniFlowCore

/// Woche auf dem iPhone hochkant (Befund des Inhabers am iPhone 11.11.2026: "Wochenansicht fehlt komplett, alles muss
/// lesbar sein"). Sieben Spalten passen nicht (Lernkalender: "Woche" fehlte, Stundenplan: Spalten abgeschnitten und
/// seitlich zu wischen). Statt des Rasters die Woche als Liste Montag–Sonntag: je Tag ein Kopf (Wochentag, Datum,
/// Hinweise), darunter die Termine und Lernbloecke nach Uhrzeit mit vollem Titel, Zeit und Raum. Tippen oeffnet den
/// Termin bzw. das Lernpaket wie im Raster. Nur iPhone (`PhoneWeekList.applies`); iPad und Mac behalten das Raster.
enum PhoneWeekList {
    /// iPhone und zu schmal fuer sieben Spalten (quer passt das Raster)
    static func applies(width: CGFloat) -> Bool { UFCompact.phoneLayouts && width > 0 && width < 560 }

    /// Ein Eintrag der Liste: Uni-Termin oder Lernblock, sortiert nach Beginn (ohne Uhrzeit ans Ende)
    struct Item: Identifiable {
        enum Kind { case event, package }
        let id: String
        let kind: Kind
        let value: JSONValue
        let start: Int
    }

    static func items(_ dd: JSONValue, packages: Bool) -> [Item] {
        let evs = dd.list("events").filter { $0.s("status") != "verschoben" }.enumerated().map { i, e in
            Item(id: "e\(i)-\(e.i("event_id") ?? 0)", kind: .event, value: e, start: UFTime.hm(e.s("start")))
        }
        let pks = packages ? dd.list("packages").filter { $0.s("start_time") != nil || !$0.list("tasks").isEmpty }.map { p in
            Item(id: "p\(p.i("id") ?? 0)", kind: .package, value: p, start: p.s("start_time").map { UFTime.hm($0) } ?? 24 * 60)
        } : []
        return (evs + pks).sorted { $0.start < $1.start }
    }

    /// "Montag, 9. November"
    static func dayTitle(_ dd: JSONValue) -> String {
        let f = Fmt.formatter("EEEE, d. MMMM")
        return Fmt.date(dd.s("date")).map { f.string(from: $0) } ?? (dd.s("date") ?? "")
    }
}

/// Liste einer Woche: Tage untereinander. `packages` = Lernkalender (Lernbloecke mit), sonst Stundenplan.
struct PhoneWeekListView: View {
    let days: [JSONValue]
    var packages = false
    /// Stundenplan: Samstag und Sonntag ohne Termine und Hinweise weglassen (wie das Raster bei wenig Platz)
    var hideEmptyWeekend = false
    let openEvent: (JSONValue, String) -> Void
    var openPackage: (JSONValue) -> Void = { _ in }
    var addPackage: ((String) -> Void)?

    var body: some View {
        let today = UFFmt.todayISO()
        let shown = days.filter { dd in
            !hideEmptyWeekend || (dd.i("weekday") ?? 0) < 5 || !PhoneWeekList.items(dd, packages: packages).isEmpty || UFDayExtras.hasAny(dd)
        }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Row.rows(shown, key: "date")) { row in
                day(row.value, today: row.value.s("date") == today)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneWeek")
    }

    private func day(_ dd: JSONValue, today: Bool) -> some View {
        let date = dd.s("date") ?? ""
        let items = PhoneWeekList.items(dd, packages: packages)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PhoneWeekList.dayTitle(dd)).ufFont(15.2, 700).foregroundStyle(today ? UF.accentText : UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if today { UFBadge("Heute", tone: .accent) }
                Spacer(minLength: 0)
                if let addPackage {
                    Button { addPackage(date) } label: {
                        UFIcon("plus", size: 16).foregroundStyle(UF.accentText).frame(width: 44, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Lernpaket am \(PhoneWeekList.dayTitle(dd)) hinzufügen")
                }
            }
            if UFDayExtras.hasAny(dd) { UFDayExtraChips(dd: dd, compact: false, stacked: false) }
            if items.isEmpty {
                Text(packages ? "Nichts geplant" : "Keine Termine").ufFont(13.12).foregroundStyle(UF.muted)
            }
            ForEach(items) { item in
                switch item.kind {
                case .event: eventRow(item.value, date: date)
                case .package: packageRow(item.value)
                }
            }
        }
        .padding(.vertical, 12 + ufB).padding(.horizontal, 12 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(today ? Color.mix(UF.accentSoft, 0.5, UF.surface) : UFDayExtras.fill(dd, over: UF.surface)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(today ? UF.accent.opacity(0.35) : UF.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func eventRow(_ e: JSONValue, date: String) -> some View {
        let st = e.s("status") ?? "teilnahme"
        let off = st != "teilnahme"
        let ec = Color(hex: e.s("color"))
        let kind = e.s("kind") ?? ""
        var line = "\(e.s("start") ?? "")–\(e.s("end") ?? "")"
        if let r = e.s("room"), !r.isEmpty { line += " · \(r)" }
        if off, let s = ["nicht_teilnahme": "nicht besucht", "ausfall": "fällt aus"][st] { line += " · \(s)" }
        return Button { openEvent(e, date) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(e.s("title") ?? "").ufFont(14.5, 650, lh: 1.25).foregroundStyle(UF.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .strikethrough(off)
                    Spacer(minLength: 0)
                    if let mark = UFCancel.label(e) { UFCancelMark(text: mark, size: 11.52, pill: true) }
                }
                Text(line).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                if let label = UFKind.label[kind] {
                    Text(label).ufFont(12.16, 600).foregroundStyle(ec)
                }
                if let topic = UFSessionTopic.text(e) {
                    Text("Thema: \(topic.replacingOccurrences(of: "\n", with: " "))").ufFont(12.16).foregroundStyle(UF.muted)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                if let src = UFCancel.source(e) {
                    Text("laut \(src)").ufFont(12.16).foregroundStyle(UF.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8).padding(.trailing, 10).padding(.leading, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.mix(ec, 0.10, UF.surface))
            .overlay(alignment: .leading) { Rectangle().fill(ec).frame(width: 4) }
            .overlay { if UFCancel.unsure(e) { RoundedRectangle(cornerRadius: 10).strokeBorder(UF.warn, lineWidth: 2) } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(st == "nicht_teilnahme" ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Termin öffnen")
    }

    private func packageRow(_ p: JSONValue) -> some View {
        let tasks = p.list("tasks")
        let done = tasks.filter { $0.s("status") == "erledigt" }.count
        let status = p.s("status") ?? "geplant"
        var line = p.s("start_time").map { "\($0)–\(p.s("end_time") ?? "") · " } ?? "ohne Uhrzeit · "
        line += UFFmt.min(p.n("planned_minutes"))
        if !tasks.isEmpty { line += " · \(done)/\(tasks.count) erledigt" }
        return Button { openPackage(p) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(UFFmt.shortName(p.s("subject") ?? p.s("title"))).ufFont(14.5, 650, lh: 1.25).foregroundStyle(UF.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .strikethrough(status == "erledigt")
                    Spacer(minLength: 0)
                    UFStatusPill(status: status)
                }
                if let t = p.s("title"), !t.isEmpty, t != p.s("subject") {
                    Text(t).ufFont(13.12).foregroundStyle(UF.text2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Text(line).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                Text("Lernblock").ufFont(12.16, 600).foregroundStyle(UF.info)
            }
            .padding(.vertical, 8).padding(.trailing, 10).padding(.leading, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.mix(UF.info, 0.08, UF.surface))
            .overlay(alignment: .leading) { Rectangle().fill(PlanNames.studyColor(p)).frame(width: 4) }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UF.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Lernpaket öffnen")
    }
}
