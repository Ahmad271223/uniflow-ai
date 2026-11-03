import SwiftUI

// Bausteine fuer die Gliederung der Einstellungen (Design 3.11.2026, docs/DESIGN-EINSTELLUNGEN-2026-11-03.md):
// Abschnittskopf ueber einer Gruppe von Karten, Einstellungszeile mit Titel und Erklaerung, Trennlinie zwischen Zeilen,
// abgesetzter Bereich fuer endgueltige Aktionen und ein Hinweis in der Farbe seines Zustands. Nur Farben und Schriften
// aus UF.*; Schriftgroessen skalieren mit Dynamic Type (ufFont).

/// Abschnitt der Einstellungen: Titel und ein Satz, darunter die Karten der Gruppe
struct SettingsSection<Content: View>: View {
    let title: String
    var sub: String?
    @ViewBuilder let content: Content

    init(_ title: String, sub: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.sub = sub
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // groesser als die Kartentitel (17.6), kleiner als der Seitentitel (30.4): drei klare Ebenen
                Text(title).ufFont(20.8, 700, em: -0.015).foregroundStyle(UF.text)
                    .accessibilityAddTraits(.isHeader)
                if let sub {
                    Text(sub).ufFont(13.12).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 2)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Eine Einstellung in einer Karte: Titel (mit Symbol), darunter das Bedienelement und eine kurze Erklaerung
struct SettingsRow<Control: View>: View {
    let title: String
    var icon: String?
    var note: String?
    @ViewBuilder let control: Control

    init(_ title: String, icon: String? = nil, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.icon = icon
        self.note = note
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon { UFIcon(icon, size: 16).foregroundStyle(UF.muted) }
                Text(title).ufFont(14.5, 600).foregroundStyle(UF.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            control
            if let note {
                Text(note).ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 1-px-Linie zwischen Zeilen einer Karte
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(UF.line).frame(height: 1).accessibilityHidden(true)
    }
}

/// Bezeichnung und Wert in einer Zeile (z. B. "Name", "E-Mail"); der Wert bricht um statt gekuerzt zu werden
struct SettingsValue: View {
    let label: String
    let value: String
    var muted = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                labelText.frame(width: 120, alignment: .leading)
                valueText.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) { labelText; valueText }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View { Text(label).ufFont(13.12).foregroundStyle(UF.muted) }
    private var valueText: some View {
        Text(value).ufFont(14.5, 500).foregroundStyle(muted ? UF.muted : UF.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Endgueltige Aktionen am Ende einer Karte, abgesetzt unter einer Linie: Folge in Worten, darunter die Knoepfe
struct SettingsDangerZone<Content: View>: View {
    var note: String?
    @ViewBuilder let content: Content

    init(note: String? = nil, @ViewBuilder content: () -> Content) {
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsDivider().padding(.bottom, 6)
            if let note {
                Text(note).ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hinweis oberhalb der Einstellungen in der Farbe seines Zustands (warn: Server nicht erreichbar, nicht aktualisiert)
struct SettingsNotice<Actions: View>: View {
    let title: String
    let text: String
    var tone: UFTone = .warn
    @ViewBuilder let actions: Actions

    init(_ title: String, text: String, tone: UFTone = .warn, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.text = text
        self.tone = tone
        self.actions = actions()
    }

    private var fg: Color { tone == .info ? UF.info : tone == .bad ? UF.bad : UF.warn }
    private var bg: Color { tone == .info ? UF.infoSoft : tone == .bad ? UF.badSoft : UF.warnSoft }

    var body: some View {
        HStack(alignment: .top, spacing: 11.2) {
            UFIcon(tone == .info ? "info" : "alert", size: 18).foregroundStyle(fg).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).ufFont(14.5, 650).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(text).ufFont(13.12).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                UFFlexWrap(gap: 9.6) { actions }.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14.4).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(fg.opacity(0.3), lineWidth: 1))
    }
}
