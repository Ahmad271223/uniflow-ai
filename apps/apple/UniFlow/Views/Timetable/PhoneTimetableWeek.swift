import SwiftUI
import UniFlowCore

/// Stundenplan am iPhone hochkant, Ansicht "Woche" (Auftrag des Inhabers 23.11.2026: „Stundenplan der gesamten Woche
/// sehen … und einzelne Tage wie aktuell“, dann: „muss man immer sehen, welches Fach“ und „viel schöner“).
///
/// Ruhig statt gedraengt: Montag–Freitag (Wochenende nur mit Terminen), luftige Stunden, je Termin ein weicher Block in
/// der Kursfarbe mit dem ausgeschriebenen Fach (ohne „– Vorlesung“, die Art steht klein darunter), Uhrzeit und Raum,
/// soweit Platz ist. Ueberschneiden sich Termine, gibt es keine schmalen Streifen: ein gemeinsamer Block nennt jedes
/// Fach in einer eigenen Zeile mit Farbpunkt; Antippen zeigt den Tag in der Tagesliste. Heute: Datum im Kreis.
/// Der Lernkalender behaelt sein Raster (`PhoneWeekGrid`).
struct PhoneTimetableWeek: View {
    let days: [JSONValue]
    let openEvent: (JSONValue, String) -> Void
    let openDay: (String) -> Void

    static let axis: CGFloat = 22
    static let gap: CGFloat = 4
    static let hour: CGFloat = 58
    private let headHeight: CGFloat = 54

    /// Ein Block der Spalte: ein Termin oder mehrere, die sich ueberschneiden
    struct Block: Identifiable {
        let id: String
        let events: [JSONValue]
        let start: Int
        let end: Int
    }

    /// Termine eines Tages zu Bloecken: was sich ueberschneidet, kommt in einen gemeinsamen Block
    static func blocks(_ dd: JSONValue) -> [Block] {
        let evs = dd.list("events").filter { $0.s("status") != "verschoben" }
            .map { e -> (JSONValue, Int, Int) in let t = UFTime.span(e.s("start"), e.s("end")); return (e, t.start, t.end) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 > $1.2 }
        var out: [Block] = []
        var group: [(JSONValue, Int, Int)] = []
        var groupEnd = -1
        func flush() {
            guard let first = group.first else { return }
            out.append(Block(id: "\(dd.s("date") ?? "")-\(first.1)-\(out.count)", events: group.map(\.0),
                             start: first.1, end: group.map(\.2).max() ?? first.2))
            group = []
        }
        for item in evs {
            if !group.isEmpty && item.1 >= groupEnd { flush() }
            group.append(item)
            groupEnd = max(groupEnd, item.2)
            if group.count == 1 { groupEnd = item.2 }
        }
        flush()
        return out
    }

    /// „Grundlagen der Informatik – Vorlesung“ -> „Grundlagen der Informatik“ (die Art steht darunter)
    static func subject(_ e: JSONValue) -> String {
        var t = e.s("title") ?? e.s("module_name") ?? "Termin"
        for sep in [" – ", " - "] {
            if let r = t.range(of: sep, options: .backwards) {
                let tail = t[r.upperBound...].lowercased()
                if ["vorlesung", "übung", "uebung", "tutorium", "seminar", "praktikum", "labor", "kolloquium", "gruppenübung"]
                    .contains(where: { tail.hasPrefix($0) }) { t = String(t[..<r.lowerBound]) }
            }
        }
        return UFFmt.shortName(t)
    }

    /// Kurzform der Art fuer schmale Bloecke (VL, Ü, Tut, Sem …); unbekannt: nil
    static func kindShort(_ kind: String?) -> String? {
        switch kind ?? "" {
        case "vorlesung": return "VL"
        case "uebung", "gruppenuebung", "hoersaaluebung": return "Ü"
        case "tutorium": return "Tut"
        case "seminar": return "Sem"
        case "praktikum", "labor": return "Prakt"
        default: return nil
        }
    }

    /// Weiche Trennstellen (U+00AD) in langen Woertern, damit schmale Bloecke an Silben umbrechen ("Bil-dungs-
    /// for-schung") statt mitten im Wort ("Einführun|g"). Faustregel des Deutschen: zwischen zwei Mitlauten vor einem
    /// Selbstlaut trennen, ein einzelner Mitlaut zwischen Selbstlauten geht in die neue Silbe; "ch", "ck", "sch",
    /// "ph", "qu" bleiben zusammen; mindestens drei Buchstaben vorn und hinten. Wird nur gebraucht, wenn das Wort
    /// nicht in die Zeile passt; dann steht am Zeilenende ein Trennstrich.
    /// Nur Woerter, die in `width` nicht passen (gemessen mit der Schrift der App), bekommen Trennstellen; was passt,
    /// bleibt ganz ("Grundlagen" statt "Grundla-gen")
    /// Schriftgroesse fuer einen Namen: die groesste zwischen `minSize` und `maxSize` (halbe Punkte), bei der jedes Wort
    /// ganz in die Zeile passt; passt eines auch bei `minSize` nicht, bekommt es Trennstellen. Gleiche Groesse fuer
    /// alle Zeilen eines Blocks, nie gequetscht.
    static func fitted(_ text: String, width: CGFloat, maxSize: CGFloat, minSize: CGFloat, weight: CGFloat) -> (text: String, size: CGFloat) {
        let words = text.split(separator: " ").map(String.init)
        var size = maxSize
        while size > minSize {
            let font = UFTypeface.font(size, weight)
            if words.allSatisfy({ ($0 as NSString).size(withAttributes: [.font: font]).width <= width }) { return (text, size) }
            size -= 0.5
        }
        return (hyphenated(text, width: width, size: minSize, weight: weight), minSize)
    }

    static func hyphenated(_ text: String, width: CGFloat, size: CGFloat, weight: CGFloat) -> String {
        let font = UFTypeface.font(size, weight)
        return text.split(separator: " ", omittingEmptySubsequences: false).map { part -> String in
            let w = String(part)
            let fits = (w as NSString).size(withAttributes: [.font: font]).width <= width
            return fits ? w : hyphenateWord(w)
        }.joined(separator: " ")
    }

    static func hyphenateWord(_ w: String) -> String {
        let c = Array(w)
        guard c.count >= 8 else { return w }
        let vowels = Set("aeiouäöüyAEIOUÄÖÜY")
        func v(_ i: Int) -> Bool { i >= 0 && i < c.count && vowels.contains(c[i]) }
        func letter(_ i: Int) -> Bool { i >= 0 && i < c.count && c[i].isLetter }
        let glued: Set<String> = ["ch", "ck", "ph", "qu", "th", "sc"]
        var cuts = Set<Int>()
        var i = 3
        while i <= c.count - 3 {
            guard letter(i - 1), letter(i) else { i += 1; continue }
            let pair = String(c[i - 1...i]).lowercased()
            // V C V: vor dem Mitlaut trennen (Ü-bung, Fü-rung)
            if v(i - 1), !v(i), v(i + 1) { cuts.insert(i) }
            // V C C V: zwischen den Mitlauten (Bil-dung), ausser bei festen Paaren und "sch"
            else if !v(i - 1), !v(i), v(i + 1), v(i - 2), !glued.contains(pair) {
                let sch = i >= 2 && String(c[i - 2...i]).lowercased() == "sch"
                if !sch { cuts.insert(i) }
            }
            i += 1
        }
        // nicht zwei Trennstellen direkt hintereinander, nicht zu nah am Ende
        var out = "", last = -10
        for (k, ch) in c.enumerated() {
            if cuts.contains(k), k - last >= 2, c.count - k >= 3 { out.append("\u{00AD}"); last = k }
            out.append(ch)
        }
        return out
    }

    static func shown(_ days: [JSONValue]) -> [JSONValue] {
        days.filter { dd in (dd.i("weekday") ?? 0) < 5 || !blocks(dd).isEmpty || UFDayExtras.hasAny(dd) }
    }

    var body: some View {
        let shown = Self.shown(days)
        let (lo, hi) = PhoneWeekGeometry.range(shown)
        let height = CGFloat(hi - lo) / 60 * Self.hour
        GeometryReader { g in
            let n = CGFloat(max(1, shown.count))
            let col = max(0, (g.size.width - Self.axis - Self.gap * (n - 1)) / n)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Self.gap) {
                    Color.clear.frame(width: Self.axis)
                    ForEach(Row.rows(shown, key: "date")) { row in head(row.value).frame(width: col, height: headHeight) }
                }
                HStack(alignment: .top, spacing: Self.gap) {
                    axis(lo: lo, hi: hi, height: height)
                    ForEach(Row.rows(shown, key: "date")) { row in
                        column(row.value, col: col, lo: lo, hi: hi, height: height)
                    }
                }
                .background(alignment: .topLeading) { hourLines(lo: lo, hi: hi).padding(.leading, Self.axis) }
            }
        }
        .frame(height: headHeight + 6 + height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timetable.week")
    }

    // MARK: Kopf

    private func head(_ dd: JSONValue) -> some View {
        let date = dd.s("date") ?? ""
        let today = date == UFFmt.todayISO()
        let day = Fmt.date(date).map { PlanData.cal.component(.day, from: $0) } ?? 0
        return Button { openDay(date) } label: {
            VStack(spacing: 4) {
                Text(ShellState.days[dd.i("weekday") ?? 0].uppercased())
                    .ufFont(10.5, 600, em: 0.04).foregroundStyle(today ? UF.accentText : UF.muted)
                Text("\(day)").ufFont(16, today ? 700 : 600)
                    .foregroundStyle(today ? Color.white : UF.text)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(today ? UF.accentFill : .clear))
                Circle().fill(UFDayExtras.hasAny(dd) ? UF.warn : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(UFKind.daysLong[dd.i("weekday") ?? 0]) \(day).")
        .accessibilityHint("Zeigt diesen Tag in der Tagesliste")
        .accessibilityIdentifier("timetable.week.head.\(date)")
    }

    // MARK: Raster

    private func axis(lo: Int, hi: Int, height: CGFloat) -> some View {
        Color.clear
            .frame(width: Self.axis, height: height)
            .overlay(alignment: .topLeading) {
                ForEach(Array(stride(from: lo, to: hi, by: 60)), id: \.self) { m in
                    Text("\(m / 60)").ufFont(10, 500).foregroundStyle(UF.muted).monospacedDigit()
                        .frame(width: Self.axis - 4, alignment: .trailing)
                        .offset(y: CGFloat(m - lo) / 60 * Self.hour - 6)
                }
            }
            .accessibilityHidden(true)
    }

    private func hourLines(lo: Int, hi: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(stride(from: lo, to: hi, by: 60)), id: \.self) { _ in
                VStack(spacing: 0) {
                    Rectangle().fill(UF.line.opacity(0.7)).frame(height: 1)
                    Spacer(minLength: 0)
                }
                .frame(height: Self.hour)
            }
        }
        .accessibilityHidden(true)
    }

    private func column(_ dd: JSONValue, col: CGFloat, lo: Int, hi: Int, height: CGFloat) -> some View {
        let date = dd.s("date") ?? ""
        let today = date == UFFmt.todayISO()
        return ZStack(alignment: .topLeading) {
            ForEach(Self.blocks(dd)) { b in
                let top = CGFloat(b.start - lo) / 60 * Self.hour
                let h = max(22, CGFloat(b.end - b.start) / 60 * Self.hour - 2)
                block(b, date: date, width: col, height: h)
                    .offset(y: top + 1)
            }
            UFNowLine(date: date, lo: lo, hi: hi, width: col, y: { CGFloat($0 - lo) / 60 * Self.hour }).zIndex(3)
        }
        .frame(width: col, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(today ? UF.accentSoft.opacity(0.45) : UFDayExtras.fill(dd, over: .clear)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func block(_ b: Block, date: String, width: CGFloat, height: CGFloat) -> some View {
        if b.events.count == 1, let e = b.events.first {
            single(e, date: date, width: width, height: height)
        } else {
            group(b, date: date, width: width, height: height)
        }
    }

    /// Ein Termin: Fach ausgeschrieben, darunter Art, Uhrzeit und Raum, soweit der Block hoch genug ist
    private func single(_ e: JSONValue, date: String, width: CGFloat, height: CGFloat) -> some View {
        let c = Color(hex: e.s("color"))
        let off = (e.s("status") ?? "teilnahme") != "teilnahme"
        let name = Self.fitted(Self.subject(e), width: width - 12, maxSize: 10.5, minSize: 9.5, weight: 650)
        let room = max(1, min(Int((height - 8) / 13), height >= 70 ? 3 : 2))
        return Button { openEvent(e, date) } label: {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(name.text).ufFont(name.size, 650, lh: 1.15).foregroundStyle(UF.text)
                    .lineLimit(room)
                    .multilineTextAlignment(.leading).strikethrough(off)
                if height >= 56 {
                    Text([e.s("start"), Self.kindShort(e.s("kind"))].compactMap { $0 }.joined(separator: " · "))
                        .ufFont(9, 600).foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.8)
                }
                if height >= 78, let r = e.s("room"), !r.isEmpty {
                    Text(r).ufFont(9).foregroundStyle(UF.muted).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 5)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.mix(c, 0.17, UF.surface)))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(c).frame(width: 3).padding(.vertical, 4).padding(.leading, 2)
            }
            .opacity(off ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility([e], date: date))
        .accessibilityHint("Öffnet den Termin")
    }

    /// Mehrere Termine zur selben Zeit: ein Block, jedes Fach eine Zeile mit Farbpunkt; Antippen zeigt den Tag
    private func group(_ b: Block, date: String, width: CGFloat, height: CGFloat) -> some View {
        let rows = max(1, Int((height - 22) / 12))
        let shown = Array(b.events.prefix(rows))
        // je Fach zwei Zeilen, wenn genug Hoehe fuer alle ist
        let perName = rows >= shown.count * 2 ? 2 : 1
        let more = b.events.count - shown.count
        return Button { openDay(date) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(b.events.count) Termine").ufFont(9, 700).foregroundStyle(UF.muted).textCase(.uppercase)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Circle().fill(Color(hex: e.s("color"))).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                        let name = Self.hyphenated(Self.subject(e), width: width - 22, size: 9, weight: 600)
                        // eine Schriftgroesse fuer alle Zeilen (gleichmaessig), zu lang: mit "…"
                        Text(name).ufFont(9, 600, lh: 1.1).foregroundStyle(UF.text)
                            .lineLimit(perName).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if more > 0 { Text("+ \(more)").ufFont(9, 600).foregroundStyle(UF.muted) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 7).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UF.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility(b.events, date: date))
        .accessibilityHint("Zeigt den Tag mit allen Terminen")
    }

    /// „Grundlagen der Informatik, Vorlesung, 10:00 bis 12:00, Hörsaal A“ (mehrere: nacheinander)
    private func accessibility(_ evs: [JSONValue], date: String) -> String {
        evs.map { e in
            [e.s("title"), UFKind.label[e.s("kind") ?? ""], "\(e.s("start") ?? "") bis \(e.s("end") ?? "")", e.s("room")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }.joined(separator: "; ")
    }
}
