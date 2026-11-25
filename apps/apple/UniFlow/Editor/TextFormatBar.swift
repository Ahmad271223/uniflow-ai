import SwiftUI
import UIKit
import UniFlowCore

/// Leiste "Text" unten im Dokument (Auftrag 25.11.2026, "sehr Word-ähnlich"): fett, kursiv, unterstrichen,
/// durchgestrichen, markieren, Schriftfarbe, Schriftart, Schriftgroesse, Ausrichtung, Aufzaehlung und Nummerierung.
/// Wirkt beim Tippen auf den markierten Text (ohne Markierung auf das, was als Naechstes getippt wird), sonst auf die
/// gewaehlten Bloecke als Ganzes. Zeigt den Stand der Auswahl (`TextFormat`).
struct TextFormatBar: View {
    let format: TextFormat
    /// Bloecke sind gewaehlt (nicht beim Tippen): Papierkorb zeigen
    let canDelete: Bool
    /// Objekte des Editors, in dem gearbeitet wird
    let objects: () -> ObjectEditing?

    static let side: CGFloat = 40
    static let height: CGFloat = 46

    static let markNames = ["Gelb", "Grün", "Blau", "Pink", "Orange"]
    static let colorNames = ["Schwarz", "Blau", "Rot", "Grün", "Orange", "Lila"]
    static let alignments: [(id: String, title: String, icon: String)] = [
        ("left", "Linksbündig", "text.alignleft"), ("center", "Zentriert", "text.aligncenter"), ("right", "Rechtsbündig", "text.alignright"),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(height: Self.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text formatieren")
        .accessibilityIdentifier("textformat.bar")
    }

    private var row: some View {
        HStack(spacing: 0) {
            toggle("bold", "Fett", format.style.bold, id: "bold") { .bold(!format.style.bold) }
                .keyboardShortcut("b", modifiers: .command)
            toggle("italic", "Kursiv", format.style.italic, id: "italic") { .italic(!format.style.italic) }
                .keyboardShortcut("i", modifiers: .command)
            toggle("underline", "Unterstrichen", format.style.underline, id: "underline") { .underline(!format.style.underline) }
                .keyboardShortcut("u", modifiers: .command)
            toggle("strikethrough", "Durchgestrichen", format.style.strike, id: "strike") { .strike(!format.style.strike) }
            divider
            markMenu
            colorMenu
            divider
            fontMenu
            sizeMenu
            step("textformat.size.smaller", "Schrift kleiner", id: "smaller") { .sizeDelta(-2) }
            step("textformat.size.larger", "Schrift größer", id: "larger") { .sizeDelta(2) }
            divider
            alignMenu
            Button { objects()?.toggleList(.bullet) } label: { icon("list.bullet") }
                .buttonStyle(EditorToolButtonStyle(selected: false))
                .accessibilityLabel("Aufzählung")
                .accessibilityIdentifier("textformat.bullets")
            Button { objects()?.toggleList(.number) } label: { icon("list.number") }
                .buttonStyle(EditorToolButtonStyle(selected: false))
                .accessibilityLabel("Nummerierung")
                .accessibilityIdentifier("textformat.numbers")
            if canDelete {
                divider
                Button(role: .destructive) { objects()?.deleteSelection() } label: { icon("trash") }
                    .buttonStyle(EditorToolButtonStyle(selected: false))
                    .accessibilityLabel("Auswahl löschen")
                    .accessibilityIdentifier("objects.delete")
            }
        }
        .padding(.horizontal, 6)
    }

    private var divider: some View { UF.line.frame(width: 1, height: 22).padding(.horizontal, 3) }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .medium)).frame(width: Self.side, height: Self.height)
    }

    private func toggle(_ symbol: String, _ title: String, _ on: Bool, id: String, _ change: @escaping () -> TextBlock.Change) -> some View {
        Button { objects()?.format(change()) } label: { icon(symbol) }
            .buttonStyle(EditorToolButtonStyle(selected: on))
            .accessibilityLabel(title)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("textformat.\(id)")
            .help(title)
    }

    private func step(_ symbol: String, _ title: String, id: String, _ change: @escaping () -> TextBlock.Change) -> some View {
        Button { objects()?.format(change()) } label: { icon(symbol) }
            .buttonStyle(EditorToolButtonStyle(selected: false))
            .accessibilityLabel(title)
            .accessibilityIdentifier("textformat.\(id)")
            .help(title)
    }

    /// Markieren wie mit dem Textmarker (hinter dem Text)
    private var markMenu: some View {
        Menu {
            ForEach(Array(TextBlock.markColors.enumerated()), id: \.offset) { i, hex in
                Button { objects()?.format(.mark(hex)) } label: {
                    Label { Text(Self.markNames.indices.contains(i) ? Self.markNames[i] : hex) } icon: { Self.dot(hex) }
                }
            }
            Button { objects()?.format(.mark("")) } label: { Label("Nicht markiert", systemImage: "xmark") }
        } label: {
            ZStack(alignment: .bottom) {
                icon("highlighter")
                Capsule().fill(format.style.mark.isEmpty ? Color.clear : color(format.style.mark)).frame(width: 18, height: 4).offset(y: -8)
            }
            .foregroundStyle(UF.text)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Markieren")
        .accessibilityIdentifier("textformat.mark")
        .help("Markieren")
    }

    private var colorMenu: some View {
        Menu {
            ForEach(Array(TextBlock.textColors.enumerated()), id: \.offset) { i, hex in
                Button { objects()?.format(.fill(hex)) } label: {
                    Label { Text(Self.colorNames.indices.contains(i) ? Self.colorNames[i] : hex) } icon: { Self.dot(hex) }
                }
            }
        } label: {
            ZStack(alignment: .bottom) {
                icon("character")
                Capsule().fill(color(format.style.fill)).frame(width: 18, height: 4).offset(y: -8)
            }
            .foregroundStyle(UF.text)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Schriftfarbe")
        .accessibilityIdentifier("textformat.color")
        .help("Schriftfarbe")
    }

    private var fontMenu: some View {
        Menu {
            ForEach(TextBlock.fonts, id: \.family) { f in
                Button { objects()?.format(.fontFamily(f.family)) } label: {
                    if f.family == format.style.fontFamily { Label(f.title, systemImage: "checkmark") } else { Text(f.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(Self.fontTitle(format.style.fontFamily)).ufFont(13.6, 600).lineLimit(1).frame(width: 104, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(UF.text)
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Schriftart: \(Self.fontTitle(format.style.fontFamily))")
        .accessibilityIdentifier("textformat.font")
        .help("Schriftart")
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(TextBlock.sizes, id: \.self) { s in
                Button { objects()?.format(.fontSize(s)) } label: {
                    if s == format.style.fontSize { Label(Self.sizeTitle(s), systemImage: "checkmark") } else { Text(Self.sizeTitle(s)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(Self.sizeTitle(format.style.fontSize)).ufFont(13.6, 600).monospacedDigit().lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(UF.text)
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Schriftgröße: \(Self.sizeTitle(format.style.fontSize))")
        .accessibilityIdentifier("textformat.size")
        .help("Schriftgröße")
    }

    private var alignMenu: some View {
        let current = Self.alignments.first { $0.id == format.align } ?? Self.alignments[0]
        return Menu {
            ForEach(Self.alignments, id: \.id) { a in
                Button { objects()?.setAlignment(a.id) } label: { Label(a.title, systemImage: a.icon) }
            }
        } label: {
            icon(current.icon).foregroundStyle(UF.text).contentShape(Rectangle())
        }
        .accessibilityLabel("Ausrichtung: \(current.title)")
        .accessibilityIdentifier("textformat.align")
        .help("Ausrichtung")
    }

    static func fontTitle(_ family: String) -> String { TextBlock.fonts.first { $0.family == family }?.title ?? family }

    /// "16" bzw. "16,5"
    static func sizeTitle(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size).replacingOccurrences(of: ".", with: ",")
    }

    private func color(_ hex: String) -> Color { Color(uiColor: UIColor(hex: hex) ?? .black) }

    /// Farbpunkt fuer Menues (Menues faerben Symbole sonst einheitlich ein)
    static func dot(_ hex: String) -> Image {
        let size = CGSize(width: 18, height: 18)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            (UIColor(hex: hex) ?? .black).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            UIColor.black.withAlphaComponent(0.15).setStroke()
            ctx.cgContext.strokeEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
    }
}

/// Leiste "Text" ohne Pro AI (Auftrag des Inhabers 25.11.2026: "das alles ab Pro AI"; gesperrt heisst sichtbar mit
/// Schloss, 12.11.2026): dieselben Zeichen gedimmt, Antippen oeffnet die Tarifwahl mit Pro AI.
struct TextFormatLockedBar: View {
    let plan: UFPlan

    static let symbols = ["bold", "italic", "underline", "highlighter", "textformat.size", "list.bullet"]

    var body: some View {
        UFLockedButton(plan: plan, title: UFRichNotes.title, identifier: "textformat.locked") {
            HStack(spacing: 10) {
                ForEach(Self.symbols, id: \.self) { Image(systemName: $0).font(.system(size: 15, weight: .medium)) }
                Text(UFRichNotes.title).ufFont(13.6, 600).lineLimit(1).fixedSize()
            }
            .foregroundStyle(UF.text)
        }
        .padding(.horizontal, 12)
        .frame(height: TextFormatBar.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4)
    }
}
