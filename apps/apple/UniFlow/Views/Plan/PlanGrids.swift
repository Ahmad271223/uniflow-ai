import SwiftUI
import UniFlowCore

// Raster des Lernkalenders 1:1 nach views-plan.js: weekGrid (Woche/3 Tage), Monat, dayTimeline, Seitenspalte
// (weekSide/daySide mit donut und miniCal) und pkgBox.

// MARK: - Kurznamen fuer enge Bloecke (TINY / tinyName)

enum PlanNames {
    private static let tiny: [(String, String)] = [
        (#"^(Mathematik für die Ingenieurwissenschaften III.*|.*Numerik.*)$"#, "Numerik"),
        (#"^Mathematik( für die Ingenieurwissenschaften)? I\b.*$"#, "Mathe I"),
        (#"^Elektrotechni.*$"#, "ET"), (#"^Signale und Systeme.*$"#, "SigSys"),
        (#"^Datenstrukturen (und|&) Algorithmen.*$"#, "DSA"), (#"^Programmieren I\b.*$"#, "Prog I"),
        (#"^Einführung in die Informatik.*$"#, "Info"), (#"^(Grundlagen digitaler Systeme.*|Digitale Systeme.*)$"#, "DigiSys"),
    ]

    static func tinyName(_ s: String?) -> String {
        var t = (s ?? "").trimmingCharacters(in: .whitespaces), pre = ""
        for p in ["Übung zu ", "Übung: ", "Gruppenübung: ", "Hörsaalübung: ", "Tutorium: "] where t.hasPrefix(p) {
            pre = "Ü "; t = String(t.dropFirst(p.count)); break
        }
        // JS-RegExp ohne Anker trifft auch mitten im Text; wie im Web: erster Treffer ersetzt den ganzen Namen
        for (re, r) in tiny {
            let unanchored = re.replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "$", with: "")
            if t.range(of: unanchored, options: [.regularExpression, .caseInsensitive]) != nil { t = r; break }
        }
        return pre + t
    }
}

// MARK: - Spuren fuer gleichzeitige Termine (lanes)

struct PlanLane { var lane = 0; var n = 1 }

func planLanes(_ items: [(s: Int, e: Int)]) -> [PlanLane] {
    var res = Array(repeating: PlanLane(), count: items.count)
    let sorted = items.enumerated().sorted { a, b in a.element.s != b.element.s ? a.element.s < b.element.s : a.element.e > b.element.e }
    var cluster: [Int] = [], clusterEnd = -1, laneEnds: [Int] = []
    func flush() {
        let n = max(1, laneEnds.count)
        for i in cluster { res[i].n = n }
        cluster = []; laneEnds = []
    }
    for (i, it) in sorted {
        if !cluster.isEmpty && it.s >= clusterEnd { flush() }
        var lane = laneEnds.firstIndex { $0 <= it.s } ?? -1
        if lane < 0 { lane = laneEnds.count; laneEnds.append(it.e) } else { laneEnds[lane] = it.e }
        res[i] = PlanLane(lane: lane, n: 1)
        cluster.append(i)
        clusterEnd = max(clusterEnd, it.e)
    }
    flush()
    return res
}

// MARK: - Wochenraster (weekGrid)

struct PlanWeekGrid: View {
    let d: PlanData
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufWindowWidth) private var windowWidth
    @State private var dropTarget: String?

    private let H: CGFloat = 60
    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    var body: some View {
        let days = d.days
        let (lo, hi) = range(days)
        let compact = days.count >= 7 && windowWidth < 1500
        // ohne Uhrzeit, aber mit Aufgaben: ein leeres Paket (alle Aufgaben verschoben) braucht keine Uhrzeit
        let unslotted = days.flatMap { dd in dd.list("packages").filter { $0.s("start_time") == nil && !$0.list("tasks").isEmpty }.map { (dd.s("date") ?? "", $0) } }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Color.clear.frame(width: 44, height: 1)
                ForEach(Row.rows(days, key: "date")) { row in
                    dayHead(row.value, compact: compact).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 9.6)
            HStack(alignment: .top, spacing: 6) {
                axis(lo: lo, hi: hi).frame(width: 44)
                ForEach(Row.rows(days, key: "date")) { row in
                    column(row.value, lo: lo, hi: hi, compact: compact).frame(maxWidth: .infinity)
                }
            }
            legend.padding(.top, 11.2)
            if !unslotted.isEmpty { unslottedCard(unslotted) }
        }
    }

    private func px(_ m: Int, _ lo: Int) -> CGFloat { CGFloat(m - lo) / 60 * H }

    private func range(_ days: [JSONValue]) -> (Int, Int) {
        var starts = [8 * 60], ends = [19 * 60]
        for dd in days {
            for e in dd.list("events") { starts.append(UFTime.hm(e.s("start"))); ends.append(UFTime.hm(e.s("end"))) }
            for p in dd.list("packages") where p.s("start_time") != nil { starts.append(UFTime.hm(p.s("start_time"))); ends.append(UFTime.hm(p.s("end_time"))) }
        }
        let lo = starts.min() ?? 480, hi = ends.max() ?? 1140
        return (lo / 60 * 60, Int((Double(hi) / 60).rounded(.up)) * 60)
    }

    /// .cal2-dh: Wochentag, Datum, Ring nach Status und Minuten
    private func dayHead(_ dd: JSONValue, compact: Bool) -> some View {
        let date = dd.s("date") ?? ""
        let today = date == UFFmt.todayISO()
        let total = dd.i("tasks_total") ?? 0, done = dd.i("tasks_done") ?? 0
        let st = dd.s("status") ?? ""
        let col: Color = st == "nachholen" ? UF.bad : st == "erledigt" ? UF.ok : st == "teilweise" ? UF.warn : UF.accent
        let mins = dd.i("minutes") ?? 0
        let txt = st == "frei" ? "Frei" : mins > 0 ? UFFmt.min(mins) : (compact ? "–" : "Nichts geplant")
        let dt = Fmt.date(date) ?? Date()
        let c = PlanData.cal.dateComponents([.day, .month], from: dt)
        return Button { router.go(.plan(view: "day", date: date, module: d.module.isEmpty ? nil : d.module)) } label: {
            VStack(spacing: 0) {
                Text(ShellState.days[dd.i("weekday") ?? 0]).ufFont(12.48).foregroundStyle(today ? UF.accentText : UF.muted)
                Text("\(c.day ?? 0).\(c.month ?? 0).").ufFont(16, 700).foregroundStyle(today ? UF.accentText : UF.text)
                HStack(spacing: 5.6) {
                    if total > 0 { UFRing(percent: Double(100 * done) / Double(total), color: col, hole: today ? UF.accentSoft : UF.surface) }
                    Text(txt).lineLimit(1)
                }
                .ufFont(11.52).foregroundStyle(today ? UF.accentText : UF.muted)
                .padding(.top, 3.2)
            }
            .padding(.vertical, 8 + ufB).padding(.horizontal, 4.8 + ufB)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(today ? UF.accentSoft : UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(today ? .clear : UF.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// .cal2-axis: Beschriftung absolut auf der Stundenlinie zentriert (translateY(-50%)), aendert die Hoehe nicht
    private func axis(lo: Int, hi: Int) -> some View {
        Color.clear
            .frame(height: px(hi, lo))
            .overlay(alignment: .topTrailing) {
                ForEach(Array(stride(from: lo, through: hi, by: 60)), id: \.self) { m in
                    Text(UFTime.mh(m)).ufFont(11.52).foregroundStyle(UF.muted).fixedSize()
                        .padding(.trailing, 6)
                        .offset(y: px(m, lo) - 11.52 * 1.5 / 2)
                }
            }
    }

    /// .cal2-col mit freien Fenstern, Terminen, Lernbloecken, Jetzt-Linie und "+" (nur heute)
    private func column(_ dd: JSONValue, lo: Int, hi: Int, compact: Bool) -> some View {
        let date = dd.s("date") ?? ""
        let today = date == UFFmt.todayISO()
        let evs = dd.list("events").filter { $0.s("status") != "verschoben" }
        let pks = dd.list("packages").filter { $0.s("start_time") != nil }
        let L = planLanes(evs.map { (UFTime.hm($0.s("start")), UFTime.hm($0.s("end"))) } + pks.map { (UFTime.hm($0.s("start_time")), UFTime.hm($0.s("end_time"))) })
        let free = (d.free[date] ?? []).filter { ($0.i("end") ?? 0) > lo && ($0.i("start") ?? 0) < hi }
        let now = PlanData.cal.dateComponents([.hour, .minute], from: Date())
        let nowM = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let height = px(hi, lo)
        return GeometryReader { g in
            let W = g.size.width
            ZStack(alignment: .topLeading) {
                ForEach(free.indices, id: \.self) { i in
                    let w = free[i]
                    let top = px(max(lo, w.i("start") ?? 0), lo), bottom = px(min(hi, w.i("end") ?? 0), lo)
                    UFHatch(color: UF.ok.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(width: max(0, W - 4), height: max(0, bottom - top))
                        .offset(x: 2, y: top)
                }
                ForEach(evs.indices, id: \.self) { i in
                    PlanEventBlock(e: evs[i], lane: L[i], W: W, px: { px($0, lo) }, compact: compact) {
                        actions.openEvent(evs[i].i("event_id") ?? 0, date: date)
                    }
                }
                ForEach(pks.indices, id: \.self) { i in
                    PlanPackageBlock(p: pks[i], lane: L[evs.count + i], W: W, px: { px($0, lo) }, compact: compact,
                                     open: { actions.openPackage(pks[i].i("id") ?? 0) },
                                     toggle: { Task { await actions.togglePackageDone(pks[i].i("id") ?? 0) } })
                }
                if today && nowM >= lo && nowM <= hi {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(UF.accent).frame(height: 2)
                        Circle().fill(UF.accent).frame(width: 8, height: 8).offset(x: -4)
                    }
                    .frame(width: W)
                    .offset(y: px(nowM, lo) - 1)
                    .allowsHitTesting(false)
                    .zIndex(3)
                }
                if today {
                    Button { actions.addPackage(date: date) } label: {
                        Circle().fill(UF.accent).frame(width: 34, height: 34)
                            .overlay(UFIcon("plus", size: 16).foregroundStyle(.white))
                            .ufShadow(.md)
                    }
                    .buttonStyle(.plain)
                    .help("Lernpaket hinzufügen")
                    .offset(x: W / 2 - 17, y: height - 8 - 34)
                    .zIndex(2)
                }
            }
            .frame(width: W, height: height, alignment: .topLeading)
        }
        .frame(height: height)
        .background(hourLines(H))
        .background(RoundedRectangle(cornerRadius: 4).fill(dropTarget == date ? UF.accentSoft : today ? Color.mix(UF.accentSoft, 0.4, UF.surface) : .clear))
        .overlay(alignment: .leading) { Rectangle().fill(UF.line).frame(width: 1) }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap({ Int($0.replacingOccurrences(of: "pkg:", with: "")) }) else { return false }
            Task {
                do {
                    _ = try await session.api?.value("/api/packages/\(id)", method: "PATCH", body: ["date": .string(date)])
                    toast.show("Verschoben")
                    router.reload()
                } catch { toast.show(error.localizedDescription) }
            }
            return true
        } isTargeted: { on in dropTarget = on ? date : (dropTarget == date ? nil : dropTarget) }
    }

    private var legend: some View {
        UFFlexWrap(gap: 17.6, rowGap: 6.4) {
            legendItem("Uni-Termin") {
                RoundedRectangle(cornerRadius: 3).fill(Color.mix(UF.accent, 0.25, UF.surface))
                    .overlay(alignment: .leading) { Rectangle().fill(UF.accent).frame(width: 3) }
            }
            legendItem("Lernblock") {
                RoundedRectangle(cornerRadius: 3).fill(Color.mix(UF.info, 0.08, UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(UF.info, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])))
                    .overlay(alignment: .leading) { Rectangle().fill(UF.info).frame(width: 3) }
            }
            legendItem("Freie Zeit") {
                UFHatch(color: UF.ok.opacity(0.4), period: 4, stripe: 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(UF.line, lineWidth: 1))
            }
            legendItem("nicht besucht") {
                RoundedRectangle(cornerRadius: 3).fill(UF.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(UF.lineStrong, lineWidth: 1)).opacity(0.6)
            }
        }
    }

    private func legendItem<S: View>(_ text: String, @ViewBuilder swatch: () -> S) -> some View {
        HStack(spacing: 4.8) {
            swatch().frame(width: 14, height: 10).clipShape(RoundedRectangle(cornerRadius: 3))
            Text(text)
        }
        .ufFont(12).foregroundStyle(UF.muted)
    }

    private func unslottedCard(_ list: [(String, JSONValue)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(list.count) Lernpaket\(list.count > 1 ? "e" : "") ohne Uhrzeit").ufFont(13.12, 700).foregroundStyle(UF.text)
                Spacer()
                UFButton("Uhrzeiten vergeben", size: .small) {
                    // die Tage dieser Pakete, nur Pakete ohne Uhrzeit (ohne Tage legte das Backend nur Tage mit
                    // Konflikten neu, also nichts; von Hand gesetzte Uhrzeiten bleiben)
                    let dates = Set(list.map(\.0)).sorted().map(JSONValue.string)
                    Task {
                        _ = try? await session.api?.value("/api/timetable/reslot", method: "POST", body: ["dates": .array(dates), "only_unset": true])
                        toast.show("Uhrzeiten vergeben")
                        router.reload()
                    }
                }
            }
            UFFlexWrap(gap: 9.6) {
                ForEach(list.indices, id: \.self) { i in
                    let (date, p) = list[i]
                    PlanPkgBox(p: p, sub: "\(UFFmt.short(date)) · \(p.s("title") ?? "") · \(UFFmt.min(p.n("planned_minutes")))") {
                        actions.openPackage(p.i("id") ?? 0)
                    }
                    .frame(minWidth: 200)
                }
            }
        }
        .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
        .padding(.top, 14.4)
    }
}

/// background-image: linear-gradient(var(--line) 1px, transparent 1px); background-size: 100% <h>
func hourLines(_ h: CGFloat) -> some View {
    Canvas { ctx, size in
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(UF.line))
            y += h
        }
    }
    .allowsHitTesting(false)
}

/// Position wie posStyle(): top, Hoehe (min 30, 3 pt Luft), Spuren nebeneinander
private func planBlockFrame(s: Int, e: Int, lane: PlanLane, W: CGFloat, px: (Int) -> CGFloat, minH: CGFloat = 30) -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
    let top = px(s), h = max(minH, px(e) - top - 3)
    let n = CGFloat(lane.n), k = CGFloat(lane.lane)
    let w = (W - 6) / n - (lane.n > 1 ? 2 : 0)
    return (k * (W - 6) / n + 3, top, max(0, w), h)
}

/// .cal2-ev (Uni-Termin)
struct PlanEventBlock: View {
    let e: JSONValue
    let lane: PlanLane
    let W: CGFloat
    let px: (Int) -> CGFloat
    let compact: Bool
    let open: () -> Void

    var body: some View {
        let f = planBlockFrame(s: UFTime.hm(e.s("start")), e: UFTime.hm(e.s("end")), lane: lane, W: W, px: px)
        let off = e.s("status") != "teilnahme"
        let ec = Color(hex: e.s("color"))
        let name = compact || lane.n > 1 ? PlanNames.tinyName(e.s("title")) : UFFmt.shortName(e.s("title"))
        let narrow = lane.n >= 3 || (compact && lane.n >= 2)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(e.s("start") ?? "")\(compact ? "" : " – \(e.s("end") ?? "")")").ufFont(10.88, lh: 1.25).foregroundStyle(UF.text2)
                    .lineLimit(narrow ? 1 : nil).truncationMode(.tail)
                Text(name).ufFont(12.16, 700, lh: 1.25).foregroundStyle(UF.text).lineLimit(narrow ? 1 : 2).padding(.vertical, 1.6)
                if f.h > 54 && !narrow {
                    Text((e.s("room").flatMap { $0.isEmpty ? nil : $0 } ?? UFKind.label[e.s("kind") ?? ""] ?? "").components(separatedBy: ":").first ?? "")
                        .ufFont(10.88, lh: 1.25).foregroundStyle(UF.muted).lineLimit(1)
                }
            }
            .strikethrough(off)
            .padding(.vertical, narrow ? 4.8 : 5.6).padding(.trailing, narrow ? 4.8 : 8).padding(.leading, (narrow ? 4.8 : 8) + 3)
            .frame(width: f.w, height: f.h, alignment: .topLeading)
            .background(Color.mix(ec, 0.13, UF.surface))
            .overlay(alignment: .leading) { Rectangle().fill(ec).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(off ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .offset(x: f.x, y: f.y)
        .zIndex(1)
        .help("\(e.s("title") ?? "") \(e.s("start") ?? "")–\(e.s("end") ?? "")\(e.s("room").map { " · \($0)" } ?? "")")
    }
}

/// .cal2-ev.study (Lernblock): gestrichelt in --info, Buch-Icon, Fuss mit Status und Erledigt-Kaestchen
struct PlanPackageBlock: View {
    let p: JSONValue
    let lane: PlanLane
    let W: CGFloat
    let px: (Int) -> CGFloat
    let compact: Bool
    let open: () -> Void
    let toggle: () -> Void

    var body: some View {
        let f = planBlockFrame(s: UFTime.hm(p.s("start_time")), e: UFTime.hm(p.s("end_time")), lane: lane, W: W, px: px)
        let status = p.s("status") ?? "geplant"
        let tasks = p.list("tasks")
        let done = tasks.filter { $0.s("status") == "erledigt" }.count
        let name = compact || lane.n > 1 ? PlanNames.tinyName(p.s("subject")) : UFFmt.shortName(p.s("subject"))
        let narrow = lane.n >= 3 || (compact && lane.n >= 2)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if !narrow { UFIcon("book", size: 11) }                     // .narrow .t .ic { display: none }
                Text("\(p.s("start_time") ?? "")\(compact ? "" : " – \(p.s("end_time") ?? "")")").lineLimit(narrow ? 1 : nil)
            }
            .ufFont(10.88, lh: 1.25).foregroundStyle(UF.text2)
            Text(name).ufFont(12.16, 700, lh: 1.25).foregroundStyle(UF.text).lineLimit(narrow ? 1 : 2).padding(.vertical, 1.6)
            if f.h > 54 && !narrow { Text(p.s("title") ?? "").ufFont(10.88, lh: 1.25).foregroundStyle(UF.muted).lineLimit(1) }
            if f.h > 88 && !compact {
                HStack(spacing: 4.8) {
                    UFStatusPill(status: status).scaleEffect(0.88, anchor: .leading)
                    Spacer(minLength: 0)
                    Button(action: toggle) {
                        RoundedRectangle(cornerRadius: 4).fill(status == "erledigt" ? UF.ok : UF.surface)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(status == "erledigt" ? UF.ok : UF.lineStrong, lineWidth: 1.5))
                            .overlay { if status == "erledigt" { UFIcon("check", size: 11).foregroundStyle(.white) } }
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("\(done)/\(tasks.count) erledigt")
                }
                .padding(.top, 4.8)
            }
        }
        .padding(.vertical, (narrow ? 4.8 : 5.6) + ufB).padding(.trailing, (narrow ? 4.8 : 8) + ufB).padding(.leading, (narrow ? 4.8 : 8) + 3)
        .frame(width: f.w, height: f.h, alignment: .topLeading)
        .background(Color.mix(UF.info, 0.07, UF.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UF.info.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .overlay(alignment: .leading) { Rectangle().fill(UF.info).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(status == "erledigt" ? 0.75 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: open)
        .draggable("pkg:\(p.i("id") ?? 0)")
        .offset(x: f.x, y: f.y)
        .zIndex(1)
        .help("Lernblock · \(p.s("subject") ?? ""): \(p.s("title") ?? "")")
    }
}

/// pkgBox(p) / .pkg: Farbbalken links, Fach, Untertitel, Zeit + Status, Aufgaben-Kacheln (V, Ü, T, W, L)
struct PlanPkgBox: View {
    let p: JSONValue
    /// eigene Unterzeile (Woche: "Datum · Titel · Minuten") statt Titel/Zeit/Status/Kacheln
    var sub: String?
    let open: () -> Void

    var body: some View {
        let status = p.s("status") ?? "geplant"
        let pc = Color(hex: p.s("color"))
        VStack(alignment: .leading, spacing: 0) {
            Text(UFFmt.shortName(p.s("subject") ?? p.s("title"))).ufFont(12.8, 600, lh: 1.25).strikethrough(status == "erledigt")
                .foregroundStyle(UF.text).lineLimit(2)
            if let sub {
                Text(sub).ufFont(11.52).foregroundStyle(UF.muted).padding(.top, 3.2)
            } else {
                if let t = p.s("title"), t != p.s("subject"), !t.isEmpty { Text(t).ufFont(11.52).foregroundStyle(UF.muted).padding(.top, 3.2) }
                HStack(spacing: 6.4) {
                    Text("\(p.s("start_time").map { "\($0)–\(p.s("end_time") ?? "") · " } ?? "")\(UFFmt.min(p.n("planned_minutes")))")
                    UFStatusPill(status: status)
                }
                .ufFont(11.52).foregroundStyle(UF.muted).padding(.top, 3.2)
                HStack(spacing: 4) {
                    ForEach(Row.rows(p.list("tasks"))) { row in
                        let t = row.value
                        let st = t.s("status")
                        Text(["vorlesung": "V", "uebung": "Ü", "test": "T", "wiederholung": "W", "frei": "L"][t.s("type") ?? ""] ?? "•")
                            .font(.uf(11.2, 700))
                            .foregroundStyle(st == "erledigt" || st == "nachholen" ? .white : UF.text2)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 5).fill(st == "erledigt" ? UF.ok : st == "nachholen" ? UF.bad : UF.surface))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(st == "erledigt" ? UF.ok : st == "nachholen" ? UF.bad : UF.line, lineWidth: 1))
                            .help(t.s("title") ?? "")
                    }
                }
                .padding(.top, 5.6)
            }
        }
        .padding(.vertical, 8).padding(.trailing, 9.6).padding(.leading, 9.6 + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status == "nachholen" ? UF.badSoft : status == "teilweise" ? UF.warnSoft : UF.surface2)
        .overlay(alignment: .leading) { Rectangle().fill(status == "nachholen" ? UF.bad : pc).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: UF.rSm))
        .opacity(status == "erledigt" ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .draggable("pkg:\(p.i("id") ?? 0)")
    }
}

// MARK: - Monat

struct PlanMonthGrid: View {
    let d: PlanData
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let days = d.days
        let month = PlanData.cal.component(.month, from: d.date)
        let t = UFFmt.todayISO()
        UFGridLayout(columns: 7, spacing: 6.4) {
            ForEach(ShellState.days, id: \.self) { x in
                Text(x).ufFont(12, 600).foregroundStyle(UF.muted).frame(maxWidth: .infinity).padding(3.2)
            }
            ForEach(Row.rows(days, key: "date")) { row in
                let dd = row.value
                let date = dd.s("date") ?? ""
                let dt = Fmt.date(date) ?? Date()
                let other = PlanData.cal.component(.month, from: dt) != month
                Button { router.go(.plan(view: "day", date: date, module: d.module.isEmpty ? nil : d.module)) } label: {
                    VStack(alignment: .leading, spacing: 3.2) {
                        HStack(spacing: 4.8) {
                            // <span class="sd"> hat im Monatsraster keine Groesse (nur .cal-day .dh .sd) -> unsichtbar, Abstand bleibt
                            Color.clear.frame(width: 0, height: 1)
                            Text("\(PlanData.cal.component(.day, from: dt))")
                        }
                        .ufFont(12.16, 600).foregroundStyle(UF.text)
                        VStack(spacing: 2) {
                            ForEach(Row.rows(dd.list("packages"))) { p in
                                Capsule().fill(Color(hex: p.value.s("color"))).frame(height: 4).help(p.value.s("subject") ?? "")
                            }
                        }
                        if let m = dd.i("minutes"), m > 0 { Text(UFFmt.min(m)).ufFont(11.84).foregroundStyle(UF.muted) }
                    }
                    .padding(.vertical, 5.6 + ufB).padding(.horizontal, 7.2 + ufB)
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(date == t ? UF.accent : UF.line, lineWidth: 1))
                    .opacity(other ? 0.45 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .environment(\.ufFillsCell, false)
    }
}

// MARK: - Tagesansicht als Zeitleiste (dayTimeline)

struct PlanDayTimeline: View {
    let d: PlanData
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    private let HH: CGFloat = 72
    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    var body: some View {
        let dateStr = Fmt.isoDay(d.date)
        let dt = d.dayTT ?? .null
        let dd = d.days.first ?? .null
        let evs = dt.list("events").filter { $0.s("status") != "verschoben" && (d.moduleFilter == nil || $0.i("module_id") == d.moduleFilter) }
        let pks = dd.list("packages").filter { $0.s("start_time") != nil }
        let lo = max(0, ([7 * 60] + evs.map { UFTime.hm($0.s("start")) } + pks.map { UFTime.hm($0.s("start_time")) }).min() ?? 420)
        let hi = min(24 * 60, ([20 * 60] + evs.map { UFTime.hm($0.s("end")) } + pks.map { UFTime.hm($0.s("end_time")) }).max() ?? 1200)
        let px: (Int) -> CGFloat = { CGFloat($0 - lo) / 60 * HH }
        let unslotted = dd.list("packages").filter { $0.s("start_time") == nil && !$0.list("tasks").isEmpty }
        let now = PlanData.cal.dateComponents([.hour, .minute], from: Date())
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { g in
                let W = g.size.width
                ZStack(alignment: .topLeading) {
                    // Achse 52 pt, Stundenlinien ab 60 pt
                    ForEach(Array(stride(from: lo, through: hi, by: 60)), id: \.self) { m in
                        Text(UFTime.mh(m)).ufFont(11.52).foregroundStyle(UF.muted).fixedSize()
                            .frame(width: 46, alignment: .trailing)
                            .offset(y: px(m) - 11.52 * 1.5 / 2)
                    }
                    hourLines(HH).frame(width: max(0, W - 68), height: px(hi)).offset(x: 60)
                    ForEach(dt.list("free").indices, id: \.self) { i in
                        let w = dt.list("free")[i]
                        UFHatch(color: UF.ok.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(width: max(0, W - 68), height: max(0, px(w.i("end") ?? 0) - px(w.i("start") ?? 0)))
                            .offset(x: 60, y: px(w.i("start") ?? 0))
                            .help("Frei: \(w.s("start_hm") ?? "")–\(w.s("end_hm") ?? "")")
                    }
                    ForEach(evs.indices, id: \.self) { i in eventRow(evs[i], W: W, px: px, date: dateStr) }
                    ForEach(pks.indices, id: \.self) { i in packageRow(pks[i], W: W, px: px) }
                    ForEach(dt.list("blocked").indices, id: \.self) { i in
                        let b = dt.list("blocked")[i]
                        let top = px(UFTime.hm(b.s("start"))), h = px(UFTime.hm(b.s("end"))) - top
                        Text(b.s("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Sperrzeit").ufFont(10.56).foregroundStyle(UF.muted)
                            .padding(.vertical, 1.6).padding(.horizontal, 4.8)
                            .frame(width: max(0, W - 62), height: max(0, h), alignment: .topLeading)
                            .background(UFHatch(color: Color(white: 120 / 255).opacity(0.18), period: 7, stripe: 2, deg135: false))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .offset(x: 60, y: top)
                    }
                    if dateStr == UFFmt.todayISO() {
                        let nowM = (now.hour ?? 0) * 60 + (now.minute ?? 0)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(UF.accent).frame(height: 2)
                            Circle().fill(UF.accent).frame(width: 8, height: 8).offset(x: -4)
                        }
                        .frame(width: max(0, W - 60))
                        .offset(x: 60, y: px(nowM) - 1)
                        .allowsHitTesting(false)
                        .zIndex(3)
                    }
                }
            }
            .frame(height: px(hi) + 20)
            if !unslotted.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(unslotted.count) Lernpaket\(unslotted.count > 1 ? "e" : "") ohne Uhrzeit").ufFont(13.12, 700).foregroundStyle(UF.text)
                        Spacer()
                        UFButton("Uhrzeiten vergeben", size: .small) {
                            Task {
                                // nur Pakete ohne Uhrzeit: von Hand gesetzte Uhrzeiten bleiben
                                _ = try? await session.api?.value("/api/timetable/reslot", method: "POST", body: ["dates": [.string(dateStr)], "only_unset": true])
                                router.reload()
                            }
                        }
                    }
                    UFFlexWrap(gap: 9.6) {
                        ForEach(Row.rows(unslotted)) { row in PlanPkgBox(p: row.value) { actions.openPackage(row.value.i("id") ?? 0) } }
                    }
                }
                .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
                .padding(.top, 9.6)
            }
        }
    }

    /// .day2-ev (Uni-Termin)
    private func eventRow(_ e: JSONValue, W: CGFloat, px: (Int) -> CGFloat, date: String) -> some View {
        let top = px(UFTime.hm(e.s("start"))), h = max(58, px(UFTime.hm(e.s("end"))) - top - 6)
        let off = e.s("status") != "teilnahme"
        let ec = Color(hex: e.s("color"))
        let kind = e.s("kind") ?? ""
        var line = "\(e.s("start") ?? "") – \(e.s("end") ?? "")"
        if let r = e.s("room"), !r.isEmpty { line += " · \(r)" }
        if off { line += " · \(["nicht_teilnahme": "nicht besucht", "ausfall": "fällt aus"][e.s("status") ?? ""] ?? "")" }
        return Button { actions.openEvent(e.i("event_id") ?? 0, date: date) } label: {
            HStack(spacing: 12.8) {
                RoundedRectangle(cornerRadius: 10).fill(Color.mix(ec, 0.18, UF.surface)).frame(width: 38, height: 38)
                    .overlay(UFIcon(UFKind.icon[kind] ?? "calendar", size: 18).foregroundStyle(ec))
                VStack(alignment: .leading, spacing: 0) {
                    Text(UFFmt.shortName(e.s("title"))).ufFont(15.68, 700).foregroundStyle(UF.text).lineLimit(1)
                    Text(line).ufFont(13.12).foregroundStyle(UF.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6.4) {                                     // .bd { flex: none }
                    UFBadge(UFKind.label[kind] ?? kind, tint: ec)
                    if let m = e.s("module_name") { UFBadge(UFFmt.shortName(m), tone: .neutral) }
                }
                .fixedSize()
            }
            .strikethrough(off)
            .padding(.vertical, 8.8).padding(.trailing, 14.4).padding(.leading, 14.4 + 4)
            .frame(width: max(0, W - 68), height: h)
            .background(Color.mix(ec, 0.10, UF.surface))
            .overlay(alignment: .leading) { Rectangle().fill(ec).frame(width: 4) }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(off ? 0.5 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .offset(x: 60, y: top)
    }

    /// .day2-ev.study (Lernpaket)
    private func packageRow(_ p: JSONValue, W: CGFloat, px: (Int) -> CGFloat) -> some View {
        let top = px(UFTime.hm(p.s("start_time"))), h = max(58, px(UFTime.hm(p.s("end_time"))) - top - 6)
        let tasks = p.list("tasks")
        let done = tasks.filter { $0.s("status") == "erledigt" }.count
        return HStack(spacing: 12.8) {
            RoundedRectangle(cornerRadius: 10).fill(UF.infoSoft).frame(width: 38, height: 38)
                .overlay(UFIcon("book", size: 18).foregroundStyle(UF.info))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(UFFmt.shortName(p.s("subject"))) – \(p.s("title") ?? "")").ufFont(15.68, 700).foregroundStyle(UF.text).lineLimit(1)
                Text("\(p.s("start_time") ?? "") – \(p.s("end_time") ?? "") · \(UFFmt.min(p.n("planned_minutes"))) · \(done)/\(tasks.count) erledigt")
                    .ufFont(13.12).foregroundStyle(UF.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6.4) {
                UFBadge("Lernpaket", tone: .info)
                UFStatusPill(status: p.s("status") ?? "geplant")
            }
            .fixedSize()
        }
        .padding(.vertical, 8.8).padding(.trailing, 14.4).padding(.leading, 14.4 + 4)
        .frame(width: max(0, W - 68), height: h)
        .background(Color.mix(UF.info, 0.08, UF.surface))
        .overlay(alignment: .leading) { Rectangle().fill(UF.info).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { actions.openPackage(p.i("id") ?? 0) }
        .draggable("pkg:\(p.i("id") ?? 0)")
        .offset(x: 60, y: top)
    }
}

// MARK: - Seitenspalte

struct PlanSide: View {
    let d: PlanData
    let backlog: [JSONValue]
    /// <= 1100 pt: Karten nebeneinander (flex 1 1 260px)
    var wrap = false
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    var body: some View {
        if wrap {
            UFGridLayout(columns: 2, spacing: 14.4) { cards }.environment(\.ufFillsCell, false)
        } else {
            VStack(alignment: .leading, spacing: 14.4) { cards }
        }
    }

    @ViewBuilder private var cards: some View {
        if d.view == "day" {
            PlanMiniCal(d: d, selected: Fmt.isoDay(d.date))
            daySummary
            dayTasks
            dayFree
        } else {
            progress
            notDone
            quickAdd
            PlanMiniCal(d: d, selected: PlanView.state.date)
        }
    }

    // Woche

    private var progress: some View {
        let days = d.days
        let done = days.reduce(0) { $0 + ($1.i("tasks_done") ?? 0) }, total = days.reduce(0) { $0 + ($1.i("tasks_total") ?? 0) }
        let late = days.flatMap { $0.list("packages").flatMap { $0.list("tasks").filter { $0.s("status") == "nachholen" } } }.count
        let planned = max(0, total - done - late)
        let uni = days.reduce(0) { $0 + $1.list("events").filter { $0.s("status") == "teilnahme" }.count }
        var segs = [UFDonut.Segment(label: "Erledigt", n: done, color: UF.ok), .init(label: "Geplant", n: planned, color: UF.info),
                    .init(label: "Nachholen", n: late, color: UF.bad)]
        if uni > 0 { segs.append(.init(label: "Uni-Termine", n: uni, color: UF.lineStrong)) }
        return PlanSideCard("Mein Fortschritt") { UFDonut(segments: segs, big: "\(done) / \(total)", small: "Aufgaben") }
    }

    private var notDone: some View {
        PlanSideCard("Nicht erledigt", trailing: { UFBadge("\(backlog.count)", tone: backlog.isEmpty ? .neutral : .bad) }) {
            if backlog.isEmpty {
                Text("Alles erledigt – nichts nachzuholen.").ufFont(13.12).foregroundStyle(UF.muted)
            } else {
                VStack(spacing: 8) {
                    ForEach(Row.rows(Array(backlog.prefix(4)))) { row in
                        let x = row.value
                        Button { actions.openPackage(x.i("package_id") ?? 0) } label: {
                            HStack(spacing: 9.6) {
                                Circle().fill(UF.badSoft).frame(width: 24, height: 24).overlay(UFIcon("alert", size: 13).foregroundStyle(UF.bad))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(UFFmt.shortName(x.s("subject"))).ufFont(13.76, 700).foregroundStyle(UF.text).lineLimit(1)
                                    Text(x.s("title") ?? "").ufFont(11.84).foregroundStyle(UF.muted).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                UFIcon("chevron-right", size: 16).foregroundStyle(UF.text)
                            }
                            .padding(.vertical, 8.8 + ufB).padding(.horizontal, 9.6 + ufB)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UF.line, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var quickAdd: some View {
        PlanSideCard("Schnell hinzufügen") {
            UFGridLayout(columns: 2, spacing: 8) {
                quick("Lernpaket", icon: "book") { actions.addPackage(date: Fmt.isoDay(d.date)) }
                quick("Freie Zeit", icon: "calendar") { actions.availability() }
                // Tests (KI) nur am eigenen Server
                if session.api?.isLocal == false { quick("Testtermin", icon: "exam") { router.go(.exams) } }
                quick("Persönlich", icon: "user") {
                    actions.eventDialog(nil, preset: ["date_from": .string(Fmt.isoDay(d.date)), "kind": "persoenlich"])
                }
            }
            .environment(\.ufFillsCell, false)
        }
    }

    private func quick(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7.2) { UFIcon(icon, size: 15); Text(text) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1.6)
        }
        .buttonStyle(UFButtonStyle())
    }

    // Tag

    private var dayTT: JSONValue { d.dayTT ?? .null }
    private var dayTaskList: [(JSONValue, JSONValue)] {
        (d.days.first ?? .null).list("packages").flatMap { p in p.list("tasks").map { (p, $0) } }
    }

    private var daySummary: some View {
        let evs = dayTT.list("events").filter { $0.s("status") == "teilnahme" }
        let lect = evs.filter { $0.s("kind") == "vorlesung" }.count
        let ex = evs.filter { $0.s("kind") != "vorlesung" && $0.s("kind") != "persoenlich" }.count
        let tasks = dayTaskList
        let tests = tasks.filter { $0.1.s("type") == "test" }.count
        let done = tasks.filter { $0.1.s("status") == "erledigt" }.count
        return PlanSideCard("Tagesübersicht") {
            UFDonut(segments: [.init(label: "Vorlesungen", n: lect, color: UF.accent), .init(label: "Übungen", n: ex, color: UF.ok),
                               .init(label: "Tests", n: tests, color: UF.bad), .init(label: "Freie Zeit", n: dayTT.list("free").count, color: UF.lineStrong)],
                    big: "\(done) / \(tasks.count)", small: "Aufgaben")
        }
    }

    private var dayTasks: some View {
        let tasks = dayTaskList
        return PlanSideCard("Heutige Aufgaben", trailing: {
            Button { actions.addPackage(date: Fmt.isoDay(d.date)) } label: { HStack(spacing: 7.2) { UFIcon("plus", size: 14); Text("Hinzufügen") } }
                .buttonStyle(UFButtonStyle(kind: .ghost, size: .small))
                .foregroundStyle(UF.accentText)
        }) {
            if tasks.isEmpty {
                Text("Für diesen Tag ist nichts geplant.").ufFont(13.12).foregroundStyle(UF.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(tasks.indices, id: \.self) { i in
                        let (p, t) = tasks[i]
                        let on = t.s("status") == "erledigt"
                        HStack(alignment: .top, spacing: 9.6) {
                            Button {
                                Task {
                                    _ = try? await session.api?.value("/api/tasks/\(t.i("id") ?? 0)/status", method: "POST", body: ["status": .string(on ? "geplant" : "erledigt")])
                                    toast.show(on ? "Wieder offen" : "Erledigt ✓")
                                    router.reload()
                                }
                            } label: {
                                Circle().fill(on ? UF.accent : .clear)
                                    .overlay(Circle().strokeBorder(on ? UF.accent : UF.lineStrong, lineWidth: 2))
                                    .overlay { if on { UFIcon("check", size: 13).foregroundStyle(.white) } }
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 1.6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(UFFmt.shortName(p.s("subject"))) – \(t.s("title") ?? "")").ufFont(13.76, 550).strikethrough(on)
                                    .foregroundStyle(on ? UF.muted : UF.text)
                                Text("\(t.s("start_time").map { "\($0) – \(t.s("end_time") ?? "") · " } ?? "")\(ShellState.typeText[t.s("type") ?? ""] ?? "") · \(t.i("est_minutes") ?? 0) min")
                                    .ufFont(11.84).foregroundStyle(UF.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let f = t.s("file_id") {
                                UFButton(icon: "book", kind: .ghost, size: .small) { router.go(.doc(f, task: t.i("id"))) }.help("Öffnen")
                            }
                        }
                        .padding(.vertical, 7.2)
                        .ufBorderBottom(i < tasks.count - 1)
                    }
                }
            }
        }
    }

    private var dayFree: some View {
        let free = dayTT.list("free")
        return PlanSideCard("Freie Zeit", icon: "clock") {
            if free.isEmpty {
                Text("Keine freien Fenster (Lernzeit \(dayTT.s("learn_start") ?? "")–\(dayTT.s("learn_end") ?? "")).").ufFont(13.12).foregroundStyle(UF.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(free.indices, id: \.self) { i in
                        let w = free[i]
                        HStack {
                            (Text("\(w.s("start_hm") ?? "") – \(w.s("end_hm") ?? "")").bold() + Text("   \(UFFmt.min(w.i("minutes") ?? 0))\(w["campus"]?.bool == true ? " · Campus" : "")"))
                                .ufFont(13.12).foregroundStyle(UF.text)
                            Spacer()
                            Button { actions.useFreeWindow(date: Fmt.isoDay(d.date), start: w.i("start") ?? 0, end: w.i("end") ?? 0) } label: {
                                HStack(spacing: 4.8) { UFIcon("plus", size: 13); Text("Lernzeit planen") }
                            }
                            .buttonStyle(UFButtonStyle(size: .small))
                            .foregroundStyle(UF.accentText)
                        }
                        .padding(.vertical, 5.6)
                        .ufBorderBottom()
                    }
                }
            }
        }
    }
}

/// .side-card: Radius 16, padding 1rem 1.1rem; h2 1rem mit Abstand .75rem, Inhalt rechts (Badge/Knopf)
struct PlanSideCard<Trailing: View, Content: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6.4) {
                HStack(spacing: 6.4) {
                    if let icon { UFIcon(icon, size: 16) }
                    Text(title)
                }
                .ufFont(16, 650, em: -0.01).foregroundStyle(UF.text)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.bottom, 12)
            content
        }
        .padding(.vertical, 16 + ufB).padding(.horizontal, 17.6 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.sm)
    }
}

/// miniCal(d, monthCal, selected): Monat mit ‹ ›, 42 Tage, bis zu 3 Farbpunkte
struct PlanMiniCal: View {
    let d: PlanData
    let selected: String
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let c = PlanData.cal
        let first = c.date(from: c.dateComponents([.year, .month], from: d.date)) ?? d.date
        let start = PlanData.monday(first)
        let month = c.component(.month, from: d.date)
        var byDate: [String: JSONValue] = [:]
        for x in d.monthCal.list("days") { if let k = x.s("date") { byDate[k] = x } }
        let t = UFFmt.todayISO()
        let f = Fmt.formatter("LLLL y")
        let pm = Fmt.isoDay(c.date(byAdding: .month, value: -1, to: first) ?? first), nm = Fmt.isoDay(c.date(byAdding: .month, value: 1, to: first) ?? first)
        return PlanSideCard(f.string(from: d.date), trailing: {
            HStack(spacing: 3.2) {
                UFButton(icon: "chevron-left", kind: .ghost, size: .small) { router.go(.plan(view: PlanView.state.view, date: pm)) }
                UFButton(icon: "chevron-right", kind: .ghost, size: .small) { router.go(.plan(view: PlanView.state.view, date: nm)) }
            }
        }) {
            VStack(spacing: 3.2) {
                HStack(spacing: 0) {
                    ForEach(ShellState.days, id: \.self) { x in Text(x).ufFont(10.88).foregroundStyle(UF.muted).frame(maxWidth: .infinity) }
                }
                UFGridLayout(columns: 7, spacing: 2) {
                    ForEach(0..<42, id: \.self) { i in
                        let dt = PlanData.add(start, i)
                        let k = Fmt.isoDay(dt)
                        let other = c.component(.month, from: dt) != month
                        let isToday = k == t, sel = !isToday && k == selected
                        var colors: [String] = []
                        let _ = (byDate[k]?.list("packages") ?? []).forEach { p in
                            let col = p.s("color") ?? "accent"
                            if !colors.contains(col) && colors.count < 3 { colors.append(col) }
                        }
                        Button { router.go(.plan(view: "day", date: k)) } label: {
                            VStack(spacing: 2) {
                                Text("\(c.component(.day, from: dt))").font(.uf(12.48, isToday ? 700 : 400))
                                    .foregroundStyle(isToday ? .white : sel ? UF.accentText : other ? UF.lineStrong : UF.text)
                                HStack(spacing: 2) {
                                    ForEach(colors, id: \.self) { col in
                                        Circle().fill(isToday ? .white : (col == "accent" ? UF.accent : Color(hex: col))).frame(width: 4, height: 4)
                                    }
                                }
                                .frame(height: 4)
                            }
                            .padding(.top, 4).padding(.bottom, 2.4)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(isToday ? UF.accent : sel ? UF.accentSoft : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .environment(\.ufFillsCell, false)
            }
        }
    }
}
