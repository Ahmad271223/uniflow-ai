import SwiftUI
import UIKit

// Weitere Bausteine 1:1 nach app/static/style.css und core.js: color-mix, Schraffur, flex-wrap mit .spacer,
// .seg.pill, <select class="input">, .ring, .donut, modal()/drawer()/confirm()/prompt().

// MARK: - color-mix(in srgb, a p%, b)

extension Color {
    /// color-mix(in srgb, a p%, b) – folgt hell/dunkel, weil beide Farben je Erscheinungsbild aufgeloest werden
    static func mix(_ a: Color, _ p: Double, _ b: Color) -> Color {
        Color(UIColor { trait in
            var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            UIColor(a).resolvedColor(with: trait).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            UIColor(b).resolvedColor(with: trait).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let q = CGFloat(p)
            return UIColor(red: r1 * q + r2 * (1 - q), green: g1 * q + g2 * (1 - q), blue: b1 * q + b2 * (1 - q), alpha: a1 * q + a2 * (1 - q))
        })
    }
}

// MARK: - Schraffur (repeating-linear-gradient)

/// repeating-linear-gradient(135deg, transparent 0 6px, Farbe 6px 8px): Streifen "/" (135deg) bzw. "\" (45deg)
struct UFHatch: View {
    var color: Color
    var period: CGFloat = 8
    var stripe: CGFloat = 2
    var deg135 = true

    var body: some View {
        Canvas { ctx, size in
            let step = period * sqrt(2)                 // Abstand senkrecht zu den Streifen = period
            let w = stripe * sqrt(2)
            var path = Path()
            var c: CGFloat = 0
            while c < size.width + size.height + step {
                if deg135 {                              // Linien x + y = c
                    path.move(to: CGPoint(x: c, y: 0)); path.addLine(to: CGPoint(x: c - size.height, y: size.height))
                } else {                                 // Linien x - y = c - h
                    path.move(to: CGPoint(x: c - size.height, y: 0)); path.addLine(to: CGPoint(x: c, y: size.height))
                }
                c += step
            }
            ctx.stroke(path, with: .color(color), lineWidth: w / sqrt(2))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - flex-wrap mit .spacer

private struct UFFlexSpacerKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

/// <span class="spacer"> in einer umbrechenden Zeile: Breite 0, nimmt den Rest der Zeile (hoechstens `max`)
struct UFFlexSpacer: View {
    var max: CGFloat = .infinity
    var body: some View { Color.clear.frame(width: 0, height: 0).layoutValue(key: UFFlexSpacerKey.self, value: max) }
}

/// display:flex; flex-wrap:wrap; align-items:center; gap – Elemente in Zeilen, Platzhalter teilen den Rest
struct UFFlexWrap: Layout {
    enum Justify { case start, between, end, center }
    var gap: CGFloat = 9.6
    var rowGap: CGFloat?
    var justify: Justify = .start

    private struct Item { let index: Int; let width: CGFloat; let height: CGFloat; let spacerMax: CGFloat? }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[Item]] {
        var out: [[Item]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let sp = s[UFFlexSpacerKey.self]
            let size = sp != nil ? .zero : s.sizeThatFits(.unspecified)
            let w = min(sp != nil ? 0 : ceil(size.width) + 0.5, width)      // aufrunden: Text wird sonst gekuerzt
            let need = out[out.count - 1].isEmpty ? w : x + gap + w
            if !out[out.count - 1].isEmpty && need > width + 0.5 && sp == nil {
                out.append([]); x = 0
            }
            x = out[out.count - 1].isEmpty ? w : x + gap + w
            out[out.count - 1].append(Item(index: i, width: w, height: size.height, spacerMax: sp))
        }
        return out.filter { !$0.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + gap }
        let ls = lines(subviews, width: width)
        let h = ls.map { l in l.map(\.height).max() ?? 0 }.reduce(0, +) + CGFloat(max(0, ls.count - 1)) * (rowGap ?? gap)
        return CGSize(width: proposal.width ?? width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let lh = line.map(\.height).max() ?? 0
            var widths = line.map(\.width)
            var free = bounds.width - widths.reduce(0, +) - gap * CGFloat(line.count - 1)
            // freien Platz auf die Platzhalter verteilen (jeweils hoechstens max)
            var open = line.indices.filter { line[$0].spacerMax != nil }
            while free > 0.5 && !open.isEmpty {
                let share = free / CGFloat(open.count)
                var next: [Int] = []
                for k in open {
                    let room = (line[k].spacerMax ?? 0) - widths[k]
                    let add = min(share, room)
                    widths[k] += add; free -= add
                    if room > share { next.append(k) }
                }
                open = next
            }
            free = max(0, free)
            var x = bounds.minX
            var spacing = gap
            switch justify {
            case .start: break
            case .end: x += free
            case .center: x += free / 2
            case .between: if line.count > 1 { spacing += free / CGFloat(line.count - 1) }
            }
            for (k, item) in line.enumerated() {
                subviews[item.index].place(at: CGPoint(x: x, y: y + lh / 2), anchor: .leading,
                                           proposal: ProposedViewSize(width: widths[k], height: item.height))
                x += widths[k] + spacing
            }
            y += lh + (rowGap ?? gap)
        }
    }
}

// MARK: - .seg.pill

/// .seg.pill: Flaeche --surface-2, 4 pt Rand, Radius 10; Knopf .4rem .9rem, Radius 8; aktiv --accent mit weisser Schrift
struct UFSegPill<Value: Hashable>: View {
    let options: [(value: Value, label: String, icon: String?)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let active = o.value == selection
                Button { onSelect(o.value) } label: {
                    HStack(spacing: 4.8) {
                        if let ic = o.icon { UFIcon(ic, size: 14) }
                        Text(o.label)
                    }
                    .ufFont(14.5, 500)
                    .fixedSize()                                     // white-space: nowrap, Segmente kuerzen nie
                    .foregroundStyle(active ? .white : UF.text2)
                    .padding(.vertical, 6.4)
                    .padding(.horizontal, 14.4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(active ? UF.accent : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(UF.surface2))
    }
}

// MARK: - <select class="input">

/// Auswahlfeld wie <select class="input"> in Safari auf dem iPad: Rahmen --line-strong, Doppelpfeil rechts,
/// Breite nach der laengsten Option (width:auto), ausser `fill` ist gesetzt.
struct UFSelect<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var fill = false
    var small = false

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].label).tag(options[i].value) }
            }
        } label: {
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    // unsichtbar: alle Optionen bestimmen die Breite wie im Browser
                    if !fill { ForEach(options.indices, id: \.self) { i in Text(options[i].label).hidden() } }
                    Text(current).foregroundStyle(UF.text).lineLimit(1)
                }
                .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: small ? 10 : 12, weight: .semibold)).foregroundStyle(UF.text)
            }
            .font(.uf(small ? 12.8 : 14.5))
            .padding(.vertical, (small ? 3.2 : 8) + ufB)
            .padding(.horizontal, (small ? 4.8 : 11.2) + ufB)
            .background(RoundedRectangle(cornerRadius: small ? 6 : UF.rSm).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: small ? 6 : UF.rSm).strokeBorder(small ? UF.line : UF.lineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var current: String { options.first { $0.value == selection }?.label ?? "" }
}

// MARK: - .ring, .donut

/// .ring: 18 pt, conic-gradient(Farbe p%, --line), Loch 11 pt in der Flaeche dahinter
struct UFRing: View {
    let percent: Double
    var color: Color = UF.ok
    var hole: Color = UF.surface

    var body: some View {
        ZStack {
            Circle().fill(UF.line)
            UFPieSlice(start: 0, end: max(0, min(100, percent)) / 100).fill(color)
            Circle().fill(hole).frame(width: 11, height: 11)
        }
        .frame(width: 18, height: 18)
    }
}

/// Kreissektor von `start` bis `end` (0…1), beginnend oben im Uhrzeigersinn wie conic-gradient
struct UFPieSlice: Shape {
    var start: Double
    var end: Double

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard end > start else { return p }
        let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: c)
        p.addArc(center: c, radius: min(r.width, r.height) / 2, startAngle: .degrees(start * 360 - 90),
                 endAngle: .degrees(end * 360 - 90), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// donut() aus views-plan.js: 104 pt Ring, innen 76 pt mit Zahl und Beschriftung, Legende rechts
struct UFDonut: View {
    struct Segment { let label: String; let n: Int; let color: Color }
    let segments: [Segment]
    let big: String
    let small: String

    var body: some View {
        let total = segments.reduce(0) { $0 + $1.n }
        HStack(spacing: 16) {
            ZStack {
                if total == 0 {
                    Circle().fill(UF.line)
                } else {
                    ForEach(segments.indices, id: \.self) { i in
                        let a = Double(segments[..<i].reduce(0) { $0 + $1.n }) / Double(total)
                        let b = a + Double(segments[i].n) / Double(total)
                        UFPieSlice(start: a, end: b).fill(segments[i].color)
                    }
                }
                Circle().fill(UF.surface).frame(width: 76, height: 76)
                VStack(spacing: 0) {
                    Text(big).font(.uf(15.68, 700)).foregroundStyle(UF.text)
                    Text(small).font(.uf(11.2)).foregroundStyle(UF.muted)
                }
                .multilineTextAlignment(.center)
            }
            .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 6.4) {
                ForEach(segments.indices, id: \.self) { i in
                    HStack(spacing: 7.2) {
                        Circle().fill(segments[i].color).frame(width: 9, height: 9)
                        Text(segments[i].label).foregroundStyle(UF.text)
                        Spacer(minLength: 4)
                        Text("\(segments[i].n)").font(.uf(12.8, 700)).foregroundStyle(UF.text)
                    }
                    .ufFont(12.8)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - modal(), drawer(), confirm(), prompt() aus core.js

/// Gemeinsame Ebenen wie #overlay im Web: ein rechter Drawer (immer nur einer), darueber Dialoge (gestapelt),
/// darueber die Rueckfragen von confirm()/prompt() als Systemdialog (wie im Safari auf dem iPad).
@MainActor
final class UFOverlay: ObservableObject {
    struct Layer: Identifiable {
        let id = UUID()
        let wide: Bool
        let content: AnyView
    }

    enum Ask: Identifiable {
        case confirm(String, CheckedContinuation<Bool, Never>)
        case prompt(String, String, CheckedContinuation<String?, Never>)
        var id: String {
            switch self {
            case .confirm(let t, _): return "c" + t
            case .prompt(let t, _, _): return "p" + t
            }
        }
    }

    @Published private(set) var modals: [Layer] = []
    @Published private(set) var drawer: Layer?
    @Published var ask: Ask?

    /// modal(html, { wide }): Dialog oeffnen; der Inhalt schliesst sich ueber @Environment(\.ufClose)
    @discardableResult
    func modal<V: View>(wide: Bool = false, @ViewBuilder _ content: () -> V) -> UUID {
        let l = Layer(wide: wide, content: AnyView(content()))
        modals.append(l)
        return l.id
    }

    func close(_ id: UUID) { modals.removeAll { $0.id == id } }

    /// drawer(html): vorhandenen Drawer ersetzen (closeDrawer() + neu)
    func openDrawer<V: View>(@ViewBuilder _ content: () -> V) {
        drawer = Layer(wide: false, content: AnyView(content()))
    }

    func closeDrawer() { drawer = nil }

    /// route() schliesst Dialoge und Drawer nicht; ein Seitenwechsel ueber die Navigation entfernt im Web das
    /// Overlay ebenfalls nicht. Fuer harte Wechsel (z. B. Dokument oeffnen) alles schliessen:
    func closeAll() { modals.removeAll(); drawer = nil }

    /// window.confirm: Systemdialog mit Abbrechen / OK
    func confirm(_ text: String) async -> Bool {
        await withCheckedContinuation { c in ask = .confirm(text, c) }
    }

    /// window.prompt: Systemdialog mit Eingabefeld; nil = Abbrechen
    func prompt(_ text: String, value: String = "") async -> String? {
        await withCheckedContinuation { c in ask = .prompt(text, value, c) }
    }
}

private struct UFCloseKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// schliesst den Dialog bzw. Drawer, in dem die Ansicht liegt ([data-close])
    var ufClose: () -> Void {
        get { self[UFCloseKey.self] }
        set { self[UFCloseKey.self] = newValue }
    }
}

/// Dialoge und Rueckfragen ueber der ganzen App (z-index 50 im Web)
struct UFModalHost: ViewModifier {
    @ObservedObject var overlay: UFOverlay
    @State private var promptText = ""

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    ForEach(overlay.modals) { l in
                        ZStack {
                            Color(red: 10 / 255, green: 12 / 255, blue: 24 / 255).opacity(0.45).ignoresSafeArea()
                                .onTapGesture { overlay.close(l.id) }               // Klick auf die Abdunkelung schliesst
                            ScrollView {
                                l.content
                                    .frame(maxWidth: l.wide ? 900 : 620)
                                    .environment(\.ufClose, { overlay.close(l.id) })
                                    .padding(16)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(maxWidth: l.wide ? 932 : 652)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: overlay.modals.map(\.id))
            }
            .alert(alertTitle, isPresented: Binding(get: { overlay.ask != nil }, set: { if !$0 { finish(nil) } })) {
                if case .prompt = overlay.ask {
                    TextField("", text: $promptText)
                    Button("Abbrechen", role: .cancel) { finish(nil) }
                    Button("OK") { finish(promptText) }
                } else {
                    Button("Abbrechen", role: .cancel) { finish(false) }
                    Button("OK") { finish(true) }
                }
            }
            .onChange(of: overlay.ask?.id) { _, _ in
                if case .prompt(_, let v, _) = overlay.ask { promptText = v }
            }
    }

    private var alertTitle: String {
        switch overlay.ask {
        case .confirm(let t, _): return t
        case .prompt(let t, _, _): return t
        case nil: return ""
        }
    }

    private func finish(_ value: Any?) {
        guard let a = overlay.ask else { return }
        overlay.ask = nil
        switch a {
        case .confirm(_, let c): c.resume(returning: (value as? Bool) ?? false)
        case .prompt(_, _, let c): c.resume(returning: value as? String)
        }
    }
}

/// Drawer rechts ueber der Hauptspalte: Breite min(440, 100 %), Rand links, Schatten; Abdunkelung rgba(0,0,0,.35)
/// liegt im Web unter der Seitenleiste (z-index 19 < 20) und wird deshalb an die Hauptspalte gehaengt.
struct UFDrawerHost: ViewModifier {
    @ObservedObject var overlay: UFOverlay

    func body(content: Content) -> some View {
        content.overlay {
            if let d = overlay.drawer {
                GeometryReader { g in
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.35).ignoresSafeArea()
                            .onTapGesture { overlay.closeDrawer() }
                        d.content
                            .environment(\.ufClose, { overlay.closeDrawer() })
                            .frame(width: min(440, g.size.width))
                            .frame(maxHeight: .infinity)
                            .background(UF.surface.ignoresSafeArea())
                            .overlay(alignment: .leading) { Rectangle().fill(UF.line).frame(width: 1).ignoresSafeArea() }
                            .ufShadow(.lg)
                            .id(d.id)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: overlay.drawer?.id)
    }
}

/// Aufbau eines Drawers: .drawer-head (Rand unten), .drawer-body (scrollt), .drawer-foot (Rand oben)
struct UFDrawerFrame<Head: View, Body: View, Foot: View>: View {
    @ViewBuilder var head: Head
    @ViewBuilder var content: Body
    @ViewBuilder var foot: Foot

    init(@ViewBuilder head: () -> Head, @ViewBuilder content: () -> Body, @ViewBuilder foot: () -> Foot) {
        self.head = head()
        self.content = content()
        self.foot = foot()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9.6) { head }
                .padding(.vertical, 14.4).padding(.horizontal, 17.6)
                .ufBorderBottom()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.vertical, 16).padding(.horizontal, 17.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            UFFlexWrap(gap: 8) { foot }
                .padding(.vertical, 12.8).padding(.horizontal, 17.6)
                .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
        }
    }
}

// MARK: - Neu laden wie state.route()

extension View {
    /// Ansicht neu laden, wenn die Route neu gerendert wird (state.route()) oder ein Sync fertig ist
    func ufReload(_ action: @escaping () async -> Void) -> some View {
        modifier(UFReloadModifier(action: action))
    }
}

private struct UFReloadModifier: ViewModifier {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    let action: () async -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: router.reloadToken) { _, _ in Task { await action() } }
            .onChange(of: shell.reloadToken) { _, _ in Task { await action() } }
    }
}

// MARK: - Abzeichen aus core.js

/// diffBadge(d): "Stufe N" – ok bei <= 2, bad bei >= 4, sonst warn
struct UFDiffBadge: View {
    let level: Int?
    var body: some View {
        if let d = level, d > 0 { UFBadge("Stufe \(d)", tone: d <= 2 ? .ok : d >= 4 ? .bad : .warn) }
    }
}

/// typeBadge(t): neutrale Badge mit Dokumenttyp
struct UFTypeBadge: View {
    let type: String?
    var body: some View {
        if let t = type, !t.isEmpty { UFBadge(ShellState.typeText[t] ?? t, tone: .neutral) }
    }
}

extension UFFmt {
    /// initial(): "Mathematik für …" -> "MF", sonst die ersten zwei Zeichen gross
    static func initial(_ s: String?) -> String {
        var t = s ?? "?"
        if t.isEmpty { t = "?" }
        if let r = t.range(of: #"^(Mathematik|Grundlagen|Einführung|Elektrotechnische|Datenstrukturen|Signale|Programmieren)\s*"#,
                           options: [.regularExpression, .caseInsensitive]) {
            t = String(t[r].prefix(1)) + t[r.upperBound...]
        }
        return String(t.prefix(2)).uppercased()
    }
}

// MARK: - Formularfelder wie <input class="input"> in Safari auf dem iPad

/// Rahmen eines Eingabefelds (.input): padding .5rem .7rem, Radius 8, Rand --line-strong, Fokusring --accent-soft
struct UFInputBox<Content: View>: View {
    var focused = false
    /// kleines Feld wie .imp-table input (.2rem .3rem, Radius 6, Rand --line, .8rem)
    var small = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .ufFont(small ? 12.8 : 14.5)
            .foregroundStyle(UF.text)
            .padding(.vertical, (small ? 3.2 : 8) + ufB)
            .padding(.horizontal, (small ? 4.8 : 11.2) + ufB)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: small ? 6 : UF.rSm).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: small ? 6 : UF.rSm).strokeBorder(focused ? UF.accent : (small ? UF.line : UF.lineStrong), lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: UF.rSm + 1.5).stroke(focused && !small ? UF.accentSoft : .clear, lineWidth: 3).padding(-1.5))
    }
}

/// <input type="date">: zeigt TT.MM.JJJJ wie Safari, Tippen oeffnet den Kalender. Wert als ISO-Datum ("" = leer).
struct UFDateField: View {
    @Binding var iso: String
    var allowEmpty = false
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            UFInputBox(focused: open) {
                Text(iso.isEmpty ? "TT.MM.JJJJ" : UFFmt.date(iso)).foregroundStyle(iso.isEmpty ? UF.muted : UF.text)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open) {
            VStack(alignment: .trailing, spacing: 8) {
                DatePicker("", selection: Binding(get: { Fmt.date(iso) ?? Date() }, set: { iso = Fmt.isoDay($0) }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "de_DE"))
                    .frame(width: 320)
                HStack {
                    if allowEmpty { Button("Löschen") { iso = ""; open = false } }
                    Spacer()
                    Button("Fertig") { open = false }.bold()
                }
            }
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// <input type="time">: zeigt HH:MM, Tippen oeffnet die Zeitauswahl (24 h). Wert "HH:MM" ("" = leer).
struct UFTimeField: View {
    @Binding var hm: String
    var allowEmpty = false
    var small = false
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            UFInputBox(focused: open, small: small) {
                Text(hm.isEmpty ? "--:--" : hm).foregroundStyle(hm.isEmpty ? UF.muted : UF.text).monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open) {
            VStack(alignment: .trailing, spacing: 8) {
                DatePicker("", selection: Binding(get: { Self.date(hm) }, set: { hm = Self.text($0) }), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "de_DE"))
                    .frame(width: 220)
                HStack {
                    if allowEmpty { Button("Löschen") { hm = ""; open = false } }
                    Spacer()
                    Button("Fertig") { if hm.isEmpty { hm = Self.text(Self.date("")) }; open = false }.bold()
                }
            }
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }

    static func date(_ s: String) -> Date {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    static func text(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// <input type="number">: Ziffernfeld mit Rahmen wie .input
struct UFNumberField: View {
    @Binding var value: Int
    var placeholder = ""
    @FocusState private var focused: Bool

    var body: some View {
        UFInputBox(focused: focused) {
            TextField(placeholder, value: $value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .focused($focused)
        }
    }
}

/// <input class="input"> fuer Text (ohne Beschriftung), z. B. in Dialogen
struct UFTextInput: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    init(_ placeholder: String = "", text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        UFInputBox(focused: focused) {
            TextField(placeholder, text: $text).focused($focused)
        }
    }
}

/// <textarea class="input">
struct UFTextArea: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 120
    @FocusState private var focused: Bool

    var body: some View {
        UFInputBox(focused: focused) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(5...)
                .focused($focused)
                .frame(minHeight: minHeight, alignment: .topLeading)
        }
    }
}

/// Radioknopf wie <input type="radio"> mit Beschriftung
struct UFRadio: View {
    let on: Bool
    var body: some View {
        Image(systemName: on ? "largecircle.fill.circle" : "circle")
            .font(.uf(16))
            .foregroundStyle(on ? UF.accent : UF.muted)
    }
}

/// Reicht die Schliessen-Funktion des umgebenden Dialogs an Ansichten mit onClose-Parameter weiter
struct UFWithClose<V: View>: View {
    @Environment(\.ufClose) private var close
    let make: (@escaping () -> Void) -> V
    var body: some View { make(close) }
}
