import SwiftUI

// Wiederverwendbare Bausteine 1:1 nach den Komponenten in app/static/style.css ("Komponenten").
// Masse: rem * 16 pt. Kommentare nennen jeweils die CSS-Klasse.

// MARK: - Schaltflaechen (.btn, .btn.primary/.ghost/.danger/.ok, .btn.sm, .btn.icon)

enum UFButtonKind { case normal, primary, ghost, danger, ok }
enum UFButtonSize { case regular, small }

struct UFButtonStyle: ButtonStyle {
    var kind: UFButtonKind = .normal
    var size: UFButtonSize = .regular
    /// quadratisch (.btn.icon: 34 pt, .btn.icon.sm: 28 pt)
    var iconOnly = false
    /// aktiver Bereichslink (.btn.ghost.active: --accent-soft / --accent-text)
    var activeFill = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let side: CGFloat = size == .small ? 28 : 34
        return configuration.label
            .font(.uf(size == .small ? 13.12 : 14.5, 500))
            .lineLimit(1)
            .foregroundStyle(activeFill ? UF.accentText : foreground)
            .padding(.vertical, iconOnly ? 0 : (size == .small ? 4.8 : 8) + ufB)          // .btn: padding + 1px Rand
            .padding(.horizontal, iconOnly ? 0 : (size == .small ? 9.6 : 13.6) + ufB)
            .frame(width: iconOnly ? side : nil, height: iconOnly ? side : nil)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(activeFill ? UF.accentSoft : background(pressed: pressed)))
            .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: UF.rSm))
            .offset(y: pressed ? 1 : 0)                                  // .btn:active { translateY(1px) }
            .opacity(isEnabled ? 1 : 0.55)                               // .btn:disabled
            .animation(UF.transition, value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .normal: return UF.text
        case .primary, .ok: return .white
        case .ghost: return UF.text2
        case .danger: return UF.bad
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .normal: return pressed ? UF.surface2 : UF.surface
        case .primary: return pressed ? UF.accentStrong : UF.accent
        case .ghost: return pressed ? UF.surface2 : .clear
        case .danger: return pressed ? UF.badSoft : UF.surface
        case .ok: return UF.ok
        }
    }

    private var border: Color {
        switch kind {
        case .normal: return UF.lineStrong
        case .primary: return UF.accent
        case .ghost: return .clear
        case .danger: return UF.bad.opacity(0.4)
        case .ok: return UF.ok
        }
    }
}

/// Schaltflaeche mit Icon und Text wie `${icon(name, 14)} Text` im Web.
struct UFButton: View {
    let title: String?
    var icon: String?
    var kind: UFButtonKind = .normal
    var size: UFButtonSize = .regular
    let action: () -> Void

    init(_ title: String? = nil, icon: String? = nil, kind: UFButtonKind = .normal, size: UFButtonSize = .regular,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7.2) {                                     // gap .45rem
                if let icon { UFIcon(icon, size: size == .small ? 14 : 16) }
                if let title { Text(title) }
            }
        }
        .buttonStyle(UFButtonStyle(kind: kind, size: size, iconOnly: title == nil))
        .accessibilityLabel(title ?? icon ?? "")
    }
}

// MARK: - Karte (.card, .card.flat, .card.pad-0, .card-head)

struct UFCard<Content: View>: View {
    var flat = false
    var padded = true
    @ViewBuilder let content: Content

    init(flat: Bool = false, padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.flat = flat
        self.padded = padded
        self.content = content()
    }

    @Environment(\.ufFillsCell) private var fillsCell

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content.environment(\.ufFillsCell, false) }
            .fixedSize(horizontal: false, vertical: true)                   // natuerliche Hoehe, Text nie gekuerzt
            .padding(.vertical, (padded ? 17.6 : 0) + ufB)                               // .card: padding + 1px Rand
            .padding(.horizontal, (padded ? 19.2 : 0) + ufB)
            .frame(maxWidth: .infinity, maxHeight: fillsCell ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
            .modifier(OptionalShadow(on: !flat))
    }
}

private struct OptionalShadow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.ufShadow(.sm) } else { content }
    }
}

/// Kopfzeile einer Karte: Titel (h2 mit Icon) links, Aktionen rechts, Abstand .8rem nach unten.
struct UFCardHead<Trailing: View>: View {
    let title: String
    var icon: String?
    /// .actions als umbrechende Zeile (flex-wrap, gap .5rem); Titel und Aktionen schrumpfen wie in CSS-Flexbox,
    /// wenn beide nicht nebeneinander passen (Titel bricht um, Knoepfe rutschen in die naechste Zeile)
    var wrap = false
    @ViewBuilder var trailing: Trailing

    init(_ title: String, icon: String? = nil, wrap: Bool = false, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.icon = icon
        self.wrap = wrap
        self.trailing = trailing()
    }

    private var heading: some View {
        HStack(spacing: 7.2) {
            if let icon { UFIcon(icon, size: 18) }
            Text(title).ufFont(17.6, 650, em: -0.01)
        }
        .foregroundStyle(UF.text)
    }

    var body: some View {
        Group {
            if wrap {
                // min-content des Titels: Icon + laengstes Wort
                let word = title.split(separator: " ").map { UFTypeface.width(String($0), 17.6, 650) - 0.176 * CGFloat($0.count) }.max() ?? 0
                UFShrinkRow(gap: 9.6, firstMin: ceil(word) + (icon == nil ? 0 : 25.2)) {
                    heading
                    UFFlexWrap(gap: 8) { trailing }
                }
            } else {
                HStack(spacing: 9.6) {
                    heading
                    Spacer(minLength: 0)
                    trailing
                }
            }
        }
        .padding(.bottom, 12.8)
    }
}

/// Zwei Flex-Elemente mit justify-content: space-between und align-items: center. Reicht der Platz nicht, schrumpfen
/// beide anteilig zu ihrer Grundbreite (flex-shrink 1), hoechstens bis zur Mindestbreite (min-content).
struct UFShrinkRow: Layout {
    var gap: CGFloat
    var firstMin: CGFloat

    private func widths(_ w: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let basis = subviews.map { ceil($0.sizeThatFits(.unspecified).width) }
        guard basis.count == 2 else { return basis.map { min($0, w) } }
        let mins = [firstMin, ceil(subviews[1].sizeThatFits(ProposedViewSize(width: UFFlexWrap.minContentProbe, height: nil)).width)]
        var out = basis
        var over = basis.reduce(0, +) + gap - w
        var open = [0, 1]
        while over > 0.01 && !open.isEmpty {
            let total = open.reduce(0) { $0 + basis[$1] }
            var next: [Int] = []
            var used: CGFloat = 0
            for k in open {
                let want = over * basis[k] / max(1, total)
                let cut = min(want, out[k] - mins[k])
                out[k] -= cut; used += cut
                if cut >= want - 0.01 { next.append(k) }
            }
            over -= used
            if next.count == open.count { break }
            open = next
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + gap
        let ws = widths(w, subviews)
        let h = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ws = widths(bounds.width, subviews)
        for (i, s) in subviews.enumerated() {
            let x = i == 0 ? bounds.minX : max(bounds.minX + ws[0] + gap, bounds.maxX - ws[i])
            s.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: ws[i], height: nil))
        }
    }
}

// MARK: - Abzeichen, Chip, Statuspille, Punkt

enum UFTone { case accent, ok, warn, bad, info, neutral }

extension UFTone {
    var fg: Color {
        switch self {
        case .accent: return UF.accentText
        case .ok: return UF.ok
        case .warn: return UF.warn
        case .bad: return UF.bad
        case .info: return UF.info
        case .neutral: return UF.text2
        }
    }
    var bg: Color {
        switch self {
        case .accent: return UF.accentSoft
        case .ok: return UF.okSoft
        case .warn: return UF.warnSoft
        case .bad: return UF.badSoft
        case .info: return UF.infoSoft
        case .neutral: return UF.surface2
        }
    }
}

/// .badge (+ .ok/.warn/.bad/.info/.neutral)
struct UFBadge: View {
    let text: String
    var tone: UFTone = .accent
    var icon: String?
    /// eigene Farbe wie .badge.kind: Schrift = Farbe, Flaeche = color-mix(Farbe 18 %, --surface)
    var tint: Color?

    init(_ text: String, tone: UFTone = .accent, icon: String? = nil, tint: Color? = nil) {
        self.text = text
        self.tone = tone
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon { UFIcon(icon, size: 12) }
            Text(text)
        }
        .ufFont(11.52, 600)
        .lineLimit(1)
        .foregroundStyle(tint ?? tone.fg)
        .padding(.vertical, 1.6)
        .padding(.horizontal, 8)
        .background(Capsule().fill(tint.map { Color.mix($0, 0.18, UF.surface) } ?? tone.bg))
    }
}

/// .chip / .chip.on
struct UFChip: View {
    let text: String
    var on = false
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.8) {
                if let icon { UFIcon(icon, size: 13) }
                Text(text)
            }
            .ufFont(12.8, on ? 600 : 400)
            .foregroundStyle(on ? UF.accentText : UF.text2)
            .padding(.vertical, 4 + ufB)
            .padding(.horizontal, 10.4 + ufB)
            .background(Capsule().fill(on ? UF.accentSoft : UF.surface))
            .overlay(Capsule().strokeBorder(on ? Color.clear : UF.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// .status-pill .st-<status> mit Icon und Text wie statusPill() in core.js (STATUS_ICON / STATUS_TXT)
struct UFStatusPill: View {
    let status: String

    static let labels: [String: String] = [
        "geplant": "Geplant", "in_bearbeitung": "In Bearbeitung", "erledigt": "Erledigt", "teilweise": "Teilweise erledigt",
        "nachholen": "Nachholen", "verschoben": "Verschoben", "uebersprungen": "Übersprungen", "frei": "Frei", "leer": "Nichts geplant",
    ]
    static let icons: [String: String] = [
        "geplant": "calendar", "in_bearbeitung": "play", "erledigt": "check", "teilweise": "clock", "nachholen": "alert",
        "verschoben": "move", "uebersprungen": "x", "frei": "sun", "leer": "circle",
    ]

    var tone: (fg: Color, bg: Color) {
        switch status {
        case "geplant": return (UF.info, UF.infoSoft)
        case "in_bearbeitung": return (UF.accentText, UF.accentSoft)
        case "erledigt": return (UF.ok, UF.okSoft)
        case "teilweise": return (UF.warn, UF.warnSoft)
        case "nachholen": return (UF.bad, UF.badSoft)
        default: return (UF.muted, UF.surface2)
        }
    }

    var body: some View {
        HStack(spacing: 4.8) {
            UFIcon(Self.icons[status] ?? "circle", size: 12)
            Text(Self.labels[status] ?? status)
        }
        .ufFont(12, 600)
        .lineLimit(1)
        .foregroundStyle(tone.fg)
        .padding(.vertical, 1.6)
        .padding(.horizontal, 8)
        .background(Capsule().fill(tone.bg))
    }
}

/// .sd – Statuspunkt im Kalender/Wochenstreifen (9 pt)
struct UFStatusDot: View {
    let status: String

    var body: some View {
        let c: Color = switch status {
        case "geplant": UF.info
        case "in_bearbeitung": UF.accent
        case "erledigt": UF.ok
        case "teilweise": UF.warn
        case "nachholen": UF.bad
        default: UF.lineStrong
        }
        Circle().fill(c).frame(width: 9, height: 9)
    }
}

/// .dot (10 pt, Modulfarbe)
struct UFDot: View {
    var color: Color = UF.accent
    var body: some View { Circle().fill(color).frame(width: 10, height: 10) }
}

// MARK: - Segment, Reiter, Fortschritt

/// .seg – Umschalter wie "Tag | 3 Tage | Woche"
struct UFSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let active = o.value == selection
                Button { withAnimation(UF.transition) { selection = o.value } } label: {
                    Text(o.label)
                        .ufFont(14.5, 500)
                        .fixedSize()
                        .foregroundStyle(active ? UF.text : UF.text2)
                        .padding(.vertical, 5.6)
                        .padding(.horizontal, 11.2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(active ? UF.surface : .clear))
                        .modifier(OptionalShadow(on: active))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
    }
}

/// .tabs – Reiter mit Unterstrich (Einstellungen, Moduldetails)
struct UFTabs<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3.2) {
                ForEach(options.indices, id: \.self) { i in
                    let o = options[i]
                    let active = o.value == selection
                    Button { selection = o.value } label: {
                        Text(o.label)
                            .font(.uf(14.5, 500))
                            .foregroundStyle(active ? UF.accentText : UF.text2)
                            .padding(.vertical, 9.6)
                            .padding(.bottom, 2)                                // border-bottom: 2px (transparent, aktiv --accent)
                            .padding(.horizontal, 13.6)
                            .overlay(alignment: .bottom) { Rectangle().fill(active ? UF.accent : .clear).frame(height: 2) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .ufBorderBottom()
        .padding(.bottom, 16)
    }
}

/// .progress (6 pt, Kapsel) und .progress.ok
struct UFProgress: View {
    let value: Double          // 0…1
    var ok = false
    var color: Color?
    /// .mod2 .progress: Spur in Modulfarbe 15 %, 7 pt hoch
    var track: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track ?? UF.surface2)
                Capsule().fill(color ?? (ok ? UF.ok : UF.accent))
                    .frame(width: max(0, min(1, value)) * g.size.width)
                    .animation(.easeInOut(duration: 0.3), value: value)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Liste, Kennzahl, Leerzustand, Seitenkopf

/// .item – Zeile mit Icon, Titel, Unterzeile, Zubehoer rechts
struct UFItemRow<Leading: View, Trailing: View>: View {
    let title: String
    var sub: String?
    /// `<a class="item">` im Web: Titel erbt die Linkfarbe --accent-text
    var link = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(_ title: String, sub: String? = nil, link: Bool = false, @ViewBuilder leading: () -> Leading = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.sub = sub
        self.link = link
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                Text(title).ufFont(14.5, 550).foregroundStyle(link ? UF.accentText : UF.text).lineLimit(1)
                if let sub { Text(sub).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 9.6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

/// .kpi – grosse Zahl mit Beschriftung
struct UFKPI: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2.4) {
            Text(value).ufFont(21.6, 700).foregroundStyle(UF.text)
            Text(label).ufFont(12.8).foregroundStyle(UF.muted)
        }
    }
}

/// .card.empty / .empty – Icon in --line-strong, Text gedimmt, zentriert
struct UFEmpty<Actions: View>: View {
    let icon: String
    let text: String
    /// .empty.small: Schrift .82rem, Icon 30 pt
    var small = false
    @ViewBuilder var actions: Actions

    init(icon: String, text: String, small: Bool = false, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.text = text
        self.small = small
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            UFIcon(icon, size: small ? 30 : 36).foregroundStyle(UF.lineStrong)
            Text(text).ufFont(small ? 13.12 : 14.5).foregroundStyle(UF.muted).multilineTextAlignment(.center)
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
    }
}

/// .page-head – h1 + Unterzeile links, Aktionen rechts (umbrechend)
struct UFPageHead<Actions: View>: View {
    let title: String
    var sub: String?
    @ViewBuilder var actions: Actions

    init(_ title: String, sub: String? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.sub = sub
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // flex-wrap: nebeneinander nur, wenn Titel und Knoepfe in voller Breite passen (Knoepfe brechen nie um)
            HStack(alignment: .bottom, spacing: 16) {
                titles.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                HStack(spacing: 8) { actions }.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 16) { titles; UFFlexWrap(gap: 8) { actions } }       // flex-wrap, gap 1rem
        }
        .padding(.bottom, 19.2)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2.4) {
            Text(title).ufFont(30.4, 700, em: -0.02).foregroundStyle(UF.text)
            if let sub { Text(sub).ufFont(14.5).foregroundStyle(UF.muted) }
        }
    }
}

// MARK: - Eingabefeld (.input)

/// Textfeld wie .input: Rahmen --line-strong, bei Fokus Rahmen --accent und 3-pt-Ring --accent-soft.
struct UFTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, secure: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
    }

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .ufFont(14.5)
        .foregroundStyle(UF.text)
        .focused($focused)
        .padding(.vertical, 8 + ufB)
        .padding(.horizontal, 11.2 + ufB)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(focused ? UF.accent : UF.lineStrong, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: UF.rSm + 1.5).stroke(focused ? UF.accentSoft : .clear, lineWidth: 3).padding(-1.5))
        .animation(UF.transition, value: focused)
    }
}

// MARK: - Seitenrahmen (.content)

/// Inhaltsbereich: Abstand 1.4rem 1.6rem 3rem, hoechstens 1480 pt breit, Hintergrund --bg
struct UFContent<Content: View>: View {
    var wide = false
    /// Inline-Stil der Ansicht (z. B. Lernkalender max-width:1600px; padding:1.3rem 1.5rem 3rem)
    var maxWidth: CGFloat?
    var insets: EdgeInsets?
    @ViewBuilder let content: Content

    init(wide: Bool = false, maxWidth: CGFloat? = nil, insets: EdgeInsets? = nil, @ViewBuilder content: () -> Content) {
        self.wide = wide
        self.maxWidth = maxWidth
        self.insets = insets
        self.content = content()
    }

    var body: some View {
        let pad = insets ?? (wide ? EdgeInsets(top: 12.8, leading: 16, bottom: 16, trailing: 16) : EdgeInsets(top: 22.4, leading: 25.6, bottom: 48, trailing: 25.6))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(pad)
                .frame(maxWidth: maxWidth ?? (wide ? .infinity : 1480), alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(UFDebugScroll.anchor)
        .background(UF.bg)
    }
}

/// Nur Debug-Builds: -UFScroll bottom zeigt das Seitenende (Bildvergleich ohne Wischgeste)
enum UFDebugScroll {
    static var anchor: UnitPoint? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "UFScroll") == "bottom" ? .bottom : nil
        #else
        return nil
        #endif
    }
}

// MARK: - Dialog (.modal/.modal-box) und Hinweis (.toast)

/// Inhalt eines Dialogs wie modal() in core.js: Titel (h3), Inhalt, Fusszeile rechtsbuendig.
struct UFDialog<Content: View, Foot: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder var content: Content
    @ViewBuilder var foot: Foot

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder foot: () -> Foot) {
        self.title = title
        self.icon = icon
        self.content = content()
        self.foot = foot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7.2) {                                     // .modal-box h3 (mit Icon wie ${icon(…, 18)})
                if let icon { UFIcon(icon, size: 18) }
                Text(title)
            }
            .ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text).padding(.bottom, 9.6)
            content
            if !(foot is EmptyView) { HStack(spacing: 8) { Spacer(); foot }.padding(.top, 16) }  // .modal-foot
        }
        .padding(.vertical, 20.8)
        .padding(.horizontal, 22.4)
        .frame(maxWidth: .infinity, alignment: .leading)           // .modal-box: width min(620px, 100%)
        .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface))
        .ufShadow(.lg)
    }
}

/// Kurzer Hinweis unten mittig wie toast() in core.js (Hintergrund --text, Schrift --bg).
@MainActor
final class UFToastCenter: ObservableObject {
    @Published private(set) var message: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, seconds: Double = 2.6) {
        message = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.message = nil }
        }
    }

    /// Benutzeraktion mit sichtbarem Fehler: fuehrt `body` aus und zeigt, wenn es scheitert, "<what> fehlgeschlagen:
    /// <Grund>". Ersetzt `try?` an Aktionen (Ordner anlegen, Aufgabe ueberspringen, Termin loeschen …), das den Fehler
    /// verschluckte und die Seite danach neu lud, als waere es gelungen. Liefert, ob es gelang; eine Erfolgsmeldung
    /// zeigt der Aufrufer nur dann.
    @discardableResult
    func attempt(_ what: String, _ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            return true
        } catch {
            show("\(what) fehlgeschlagen: \(error.localizedDescription)", seconds: 4)
            return false
        }
    }
}

struct UFToastOverlay: ViewModifier {
    @ObservedObject var center: UFToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let m = center.message {
                Text(m)
                    .ufFont(14.4)
                    .foregroundStyle(UF.bg)
                    .padding(.vertical, 8.8)
                    .padding(.horizontal, 16)
                    .background(Capsule().fill(UF.text))
                    .ufShadow(.lg)
                    .padding(.bottom, 19.2)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: center.message)
    }
}

// MARK: - Dialog-Ueberlagerung wie modal() in core.js (abgedunkelter Hintergrund, Karte mittig, Tipp daneben schliesst)

extension View {
    func ufModal<M: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> M) -> some View {
        overlay {
            if isPresented.wrappedValue {
                ZStack {
                    Color(red: 10 / 255, green: 12 / 255, blue: 24 / 255).opacity(0.45).ignoresSafeArea()
                        .onTapGesture { isPresented.wrappedValue = false }
                    ScrollView { content().padding(16) }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxWidth: 652)
                }
                .transition(.opacity)
                .zIndex(50)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isPresented.wrappedValue)
    }
}

// MARK: - Fensterbreite fuer die Rasterregeln der Web-App (@media max-width 1100/900/820)

private struct UFWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1180
}

extension EnvironmentValues {
    var ufWindowWidth: CGFloat {
        get { self[UFWindowWidthKey.self] }
        set { self[UFWindowWidthKey.self] = newValue }
    }
}

/// Zellen im Raster fuellen die Zeilenhoehe (CSS-Grid: align-items stretch); UFCard liest das.
private struct UFFillsCellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ufFillsCell: Bool {
        get { self[UFFillsCellKey.self] }
        set { self[UFFillsCellKey.self] = newValue }
    }
}

/// .grid.cols-3 / .grid.cols-2: Spaltenzahl nach Fensterbreite wie im Web (<= 1100: 2, <= 820: 1).
/// Alle Zellen einer Zeile werden so hoch wie die hoechste (CSS-Grid streckt Zellen).
struct UFGrid<Content: View>: View {
    var columns = 3
    var spacing: CGFloat = 16
    @Environment(\.ufWindowWidth) private var width
    @ViewBuilder let content: Content

    init(columns: Int = 3, spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.spacing = spacing
        self.content = content()
    }

    var effective: Int {
        if width <= 820 { return 1 }
        if width <= 1100 { return min(columns, 2) }
        return columns
    }

    var body: some View {
        UFGridLayout(columns: effective, spacing: spacing) { content }
            .environment(\.ufFillsCell, true)
    }
}

/// Gleich breite Spalten, Zeilenhoehe = hoechste Zelle der Zeile. Mit `minWidth` wie
/// repeat(auto-fill, minmax(minWidth, 1fr)): Spaltenzahl aus der verfuegbaren Breite.
struct UFGridLayout: Layout {
    var columns: Int = 1
    var spacing: CGFloat = 16
    var minWidth: CGFloat?

    private func count(_ w: CGFloat) -> Int {
        if let m = minWidth { return max(1, Int((w + spacing) / (m + spacing))) }
        return max(1, columns)
    }

    private func colWidth(_ w: CGFloat) -> CGFloat {
        let n = count(w)
        return max(0, (w - CGFloat(n - 1) * spacing) / CGFloat(n))
    }

    private func rowHeights(_ subviews: Subviews, width w: CGFloat) -> [CGFloat] {
        let n = count(w), col = colWidth(w)
        return stride(from: 0, to: subviews.count, by: n).map { start in
            subviews[start..<min(subviews.count, start + n)]
                .map { $0.sizeThatFits(ProposedViewSize(width: col, height: nil)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        let rows = rowHeights(subviews, width: w)
        return CGSize(width: w, height: rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = count(bounds.width), col = colWidth(bounds.width)
        let rows = rowHeights(subviews, width: bounds.width)
        var y = bounds.minY
        for (r, h) in rows.enumerated() {
            for c in 0..<n {
                let i = r * n + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (col + spacing), y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: col, height: h))
            }
            y += h + spacing
        }
    }
}
