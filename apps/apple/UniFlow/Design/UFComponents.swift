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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let side: CGFloat = size == .small ? 28 : 34
        return configuration.label
            .font(.system(size: size == .small ? 13.12 : 14.5, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.vertical, iconOnly ? 0 : (size == .small ? 4.8 : 8))
            .padding(.horizontal, iconOnly ? 0 : (size == .small ? 9.6 : 13.6))
            .frame(width: iconOnly ? side : nil, height: iconOnly ? side : nil)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(background(pressed: pressed)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, padded ? 17.6 : 0)
            .padding(.horizontal, padded ? 19.2 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    @ViewBuilder var trailing: Trailing

    init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 9.6) {
            HStack(spacing: 7.2) {
                if let icon { UFIcon(icon, size: 18) }
                Text(title).font(UF.h2)
            }
            .foregroundStyle(UF.text)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.bottom, 12.8)
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

    init(_ text: String, tone: UFTone = .accent, icon: String? = nil) {
        self.text = text
        self.tone = tone
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon { UFIcon(icon, size: 12) }
            Text(text)
        }
        .font(.system(size: 11.52, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(tone.fg)
        .padding(.vertical, 1.6)
        .padding(.horizontal, 8)
        .background(Capsule().fill(tone.bg))
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
            .font(.system(size: 12.8, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? UF.accentText : UF.text2)
            .padding(.vertical, 4)
            .padding(.horizontal, 10.4)
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
        .font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 14.5, weight: .medium))
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
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(active ? UF.accentText : UF.text2)
                            .padding(.vertical, 9.6)
                            .padding(.horizontal, 13.6)
                            .overlay(alignment: .bottom) { Rectangle().fill(active ? UF.accent : .clear).frame(height: 2) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
        .padding(.bottom, 16)
    }
}

/// .progress (6 pt, Kapsel) und .progress.ok
struct UFProgress: View {
    let value: Double          // 0…1
    var ok = false
    var color: Color?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(UF.surface2)
                Capsule().fill(color ?? (ok ? UF.ok : UF.accent))
                    .frame(width: max(0, min(1, value)) * g.size.width)
                    .animation(.easeInOut(duration: 0.3), value: value)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Liste, Kennzahl, Leerzustand, Seitenkopf

/// .item – Zeile mit Icon, Titel, Unterzeile, Zubehoer rechts
struct UFItemRow<Leading: View, Trailing: View>: View {
    let title: String
    var sub: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(_ title: String, sub: String? = nil, @ViewBuilder leading: () -> Leading = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.sub = sub
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(UF.text).lineLimit(1)
                if let sub { Text(sub).font(.system(size: 12.8)).foregroundStyle(UF.muted).lineLimit(1) }
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
            Text(value).font(.system(size: 21.6, weight: .bold)).foregroundStyle(UF.text)
            Text(label).font(.system(size: 12.8)).foregroundStyle(UF.muted)
        }
    }
}

/// .card.empty / .empty – Icon in --line-strong, Text gedimmt, zentriert
struct UFEmpty<Actions: View>: View {
    let icon: String
    let text: String
    @ViewBuilder var actions: Actions

    init(icon: String, text: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            UFIcon(icon, size: 36).foregroundStyle(UF.lineStrong)
            Text(text).font(UF.body).foregroundStyle(UF.muted).multilineTextAlignment(.center)
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
            HStack(alignment: .bottom, spacing: 16) { titles; Spacer(minLength: 0); HStack(spacing: 8) { actions } }
            VStack(alignment: .leading, spacing: 12) { titles; HStack(spacing: 8) { actions } }
        }
        .padding(.bottom, 19.2)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2.4) {
            Text(title).font(UF.h1).foregroundStyle(UF.text)
            if let sub { Text(sub).font(UF.body).foregroundStyle(UF.muted) }
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
        .font(UF.body)
        .foregroundStyle(UF.text)
        .focused($focused)
        .padding(.vertical, 8)
        .padding(.horizontal, 11.2)
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
    @ViewBuilder let content: Content

    init(wide: Bool = false, @ViewBuilder content: () -> Content) {
        self.wide = wide
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.top, wide ? 12.8 : 22.4)
                .padding(.horizontal, wide ? 16 : 25.6)
                .padding(.bottom, wide ? 16 : 48)
                .frame(maxWidth: wide ? .infinity : 1480, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(UF.bg)
    }
}

// MARK: - Dialog (.modal/.modal-box) und Hinweis (.toast)

/// Inhalt eines Dialogs wie modal() in core.js: Titel (h3), Inhalt, Fusszeile rechtsbuendig.
struct UFDialog<Content: View, Foot: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var foot: Foot

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder foot: () -> Foot) {
        self.title = title
        self.content = content()
        self.foot = foot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(UF.h3).foregroundStyle(UF.text).padding(.bottom, 9.6)
            content
            HStack(spacing: 8) { Spacer(); foot }.padding(.top, 16)
        }
        .padding(.vertical, 20.8)
        .padding(.horizontal, 22.4)
        .frame(maxWidth: 620)
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
}

struct UFToastOverlay: ViewModifier {
    @ObservedObject var center: UFToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let m = center.message {
                Text(m)
                    .font(.system(size: 14.4))
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

/// .grid.cols-3 / .grid.cols-2: Spaltenzahl nach Fensterbreite wie im Web (<= 1100: 2, <= 820: 1)
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: effective),
                  alignment: .leading, spacing: spacing) { content }
    }
}
