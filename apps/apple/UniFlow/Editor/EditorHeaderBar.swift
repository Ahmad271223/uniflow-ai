import SwiftUI

// Eine Kopfzeile fuer "Oben fest" (Auftrag des Inhabers 12.11.2026: "Die Palette mehr nach oben, ich will maximale
// Schreibflaeche. Und Dateien oben ansammeln (wie Reiter)").
//
// Vorher lagen ueber der PDF drei Streifen: die Navigationsleiste (Zurueck, Titel, elf Knoepfe), die Reiter der
// Bibliothek und darunter die Werkzeugleiste, zusammen 139 pt. Jetzt ist es eine Zeile, so hoch wie eine Trefferflaeche
// (44 pt): links Zurueck und die Reiter der offenen Dokumente, in der Mitte die Werkzeuge mit Farbe/Staerke und
// Rueckgaengig, rechts Seiten, KI, Daneben, Teilen, Mehr und "Leiste ausblenden". Darunter ist nur noch das Dokument.
//
// Wird es schmal (hochkant, geteilte Ansicht), bricht nichts um: die Objektwerkzeuge ruecken in einen Knopf mit Liste,
// die Werkzeugreihe laesst sich waagerecht schieben, Seiten/Daneben/Teilen wandern ins Menue "Mehr", die Reiter werden
// zuletzt ein Knopf mit Liste. Eigene kleine Typen (nicht in `DocumentView.body` geschachtelt, `ViewTypeDepthAppTests`).

/// Was bei einer Breite in die Zeile passt (rein, `EditorHeaderTests`)
struct EditorHeaderLayout: Equatable {
    let width: CGFloat

    /// Hoehe der Zeile: eine Trefferflaeche (wie die Werkzeugleiste)
    static let height: CGFloat = EditorToolbar.height

    /// Seiten, Daneben, Teilen und "Leiste ausblenden" stehen im Menue "Mehr" (hochkant auf dem 11-Zoll-iPad, geteilte
    /// Ansicht)
    var compactActions: Bool { width < 900 }
    /// Reiter nur als ein Knopf mit Liste (sehr schmal, z. B. ein Drittel in der geteilten Ansicht)
    var tabsAsMenu: Bool { width < 560 }
    /// hoechste Breite der Reiter; den Rest bekommen die Werkzeuge
    var tabMaxWidth: CGFloat { (width * (compactActions ? 0.2 : 0.34)).rounded() }
    /// sehr schmal: Stand nur bei Problemen, KI als Symbol mit Schloss statt mit Schild, damit die Stifte Platz haben
    var narrow: Bool { tabsAsMenu }
}

/// Die eine Kopfzeile: links (Zurueck, Reiter), Werkzeuge, rechts die Knoepfe des Dokuments. Inhalte kommen fertig als
/// `AnyView` aus `DocumentView` (deren Zustand), die Zeile ordnet sie nur an.
struct EditorHeaderBar: View {
    let leading: (EditorHeaderLayout) -> AnyView
    let tools: AnyView?
    let actions: (EditorHeaderLayout) -> AnyView

    var body: some View {
        GeometryReader { geo in
            let layout = EditorHeaderLayout(width: geo.size.width)
            HStack(spacing: 0) {
                leading(layout)
                if let tools {
                    UF.line.frame(width: 1, height: 22).padding(.horizontal, 3)
                    tools
                }
                Spacer(minLength: 4)
                actions(layout)
            }
            .frame(width: geo.size.width, height: EditorHeaderLayout.height)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.header")
        }
        .frame(height: EditorHeaderLayout.height)
        .background(UF.surface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { UF.line.frame(height: 1) }
    }
}

/// Knopf der Kopfzeile: Symbol 17 pt, Trefferflaeche 44 x 44 pt, gewaehlt in der Akzentfarbe (wie die Werkzeuge)
struct EditorHeaderButton: View {
    let title: String
    let icon: String
    var selected = false
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
                .frame(width: EditorToolbar.hitSide, height: EditorToolbar.hitSide)
        }
        .buttonStyle(EditorToolButtonStyle(selected: selected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier ?? "header." + title)
        .help(title)
    }
}

/// Aussehen eines Menue-Knopfs der Kopfzeile (Teilen, Mehr): wie `EditorHeaderButton`
struct EditorHeaderMenuLabel: View {
    let icon: String

    var body: some View {
        Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(UF.text)
            .frame(width: EditorToolbar.hitSide, height: EditorToolbar.hitSide)
            .contentShape(Rectangle())
    }
}

/// Vollbild-Schreiben: die Kopfzeile ist aus, oben in der Mitte ein kleiner Griff holt sie zurueck
struct EditorHeaderRestoreHandle: View {
    let action: () -> Void

    static let title = "Leiste einblenden"

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.compact.down").font(.system(size: 15, weight: .bold)).foregroundStyle(UF.text2)
                .frame(width: 46, height: 22)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
                .frame(width: 64, height: EditorToolbar.hitSide, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(0.85)
        .accessibilityLabel(Self.title)
        .accessibilityIdentifier("editor.header.show")
        .help(Self.title)
    }
}

/// Die Kopfzeile des Dokuments zeigt die Reiter selbst: die Bibliothek blendet ihren Reiterstreifen dann aus
struct EditorOwnsTabsKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// MARK: - Reiter

/// Reiter der zuletzt geoeffneten Dokumente (hoechstens `DocumentTabList.limit`, 15): in der Kopfzeile (`.header`, so
/// breit wie die Reiter, hoechstens `maxWidth`, darueber waagerecht wischbar) oder als flacher Streifen ueber Dokumenten
/// ohne Kopfzeile ("Unten fest", "Schwebend", Text- und ZIP-Ansicht; `.row`). Nie eine zweite Zeile (maximale
/// Schreibflaeche, Inhaber 12./13.11.2026). Aktiver Reiter in der Akzentfarbe und beim Erscheinen in Sicht geschoben,
/// Antippen wechselt sofort, "×" nimmt ihn aus der Leiste, lange druecken bzw. Rechtsklick: Schliessen, Andere
/// schliessen, In neuem Fenster oeffnen. Sehr schmal (`asMenu`) ein Knopf mit Liste.
struct DocumentTabStrip: View {
    enum Style { case header, row }

    @ObservedObject var tabs: DocumentTabList
    let currentID: String
    let currentTitle: String
    var style: Style = .header
    var maxWidth: CGFloat = .infinity
    var asMenu = false
    /// Reiter bedienbar; aus (alte Fassung, Dokument aus einem ZIP): nur der Titel
    var enabled = true
    @EnvironmentObject private var router: UFRouter
    /// Breite aller Reiter (gemessen): so breit wird die Leiste, hoechstens `maxWidth`, der Rest ist zu wischen
    @State private var fullWidth: CGFloat = 0

    /// Titel gekuerzt (gewaehlter Reiter etwas laenger): eine Zeile, nie umbrechen
    static func shortTitle(_ title: String, active: Bool, short: Bool = false) -> String {
        shortTitle(title, limit: short ? (active ? 18 : 9) : (active ? 26 : 18))
    }

    /// Breite der Leiste in der Kopfzeile: so breit wie alle Reiter, hoechstens `max`; noch nicht gemessen ein Stueck
    /// (der aktive Reiter passt fast immer)
    static func stripWidth(content: CGFloat, max: CGFloat) -> CGFloat {
        content > 0 ? min(content, max) : min(max, 160)
    }

    /// Ab dieser Breite ist die Leiste zu wischen (nicht alle Reiter sichtbar)
    static func scrolls(content: CGFloat, max: CGFloat) -> Bool { content > max + 0.5 }

    static func shortTitle(_ title: String, limit: Int) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        return String(t.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Reiter in der Reihenfolge der Liste; fehlt das gezeigte Dokument darin (Reiter aus), steht es allein da. Nur die
    /// Liste des offenen Containers (`visibleEntries`): nie Reiter eines anderen Kontos.
    private var items: [DocumentTabEntry] {
        let list = enabled ? tabs.visibleEntries : []
        if list.contains(where: { $0.id == currentID }) { return list }
        return list + [DocumentTabEntry(id: currentID, title: currentTitle, used: 0)]
    }

    private func closable(_ id: String) -> Bool { enabled && tabs.visibleEntries.contains { $0.id == id } }

    var body: some View {
        Group {
            if asMenu {
                menu
            } else if style == .row {
                strip.padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UF.surface)
                    .ufBorderBottom()
            } else {
                strip
                    .frame(width: Self.stripWidth(content: fullWidth, max: maxWidth))
                    .mask { edgeFade(Self.scrolls(content: fullWidth, max: maxWidth)) }
                    .background {
                        // Breite messen (unsichtbar, nicht bedienbar)
                        row.fixedSize()
                            .background(GeometryReader { g in Color.clear.preference(key: TabStripWidthKey.self, value: g.size.width) })
                            .onPreferenceChange(TabStripWidthKey.self) { fullWidth = $0 }
                            .hidden()
                            .accessibilityHidden(true)
                    }
            }
        }
        .onAppear { tabs.refresh() }
    }

    /// Zu wischen: an den Raendern sanft ausblenden, damit man sieht, dass es weitergeht
    @ViewBuilder private func edgeFade(_ on: Bool) -> some View {
        if on {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
            }
        } else {
            Color.black
        }
    }

    /// alle Reiter nebeneinander (nur zum Messen)
    private var row: some View {
        HStack(spacing: 4) { ForEach(items) { tab($0) } }.padding(.horizontal, 2)
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items) { tab($0).id($0.id) }
                }
                .padding(.horizontal, 2)
                .frame(height: EditorToolbar.hitSide)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Zuletzt geöffnete Dokumente")
                .accessibilityIdentifier("doc.tabs")
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onAppear { proxy.scrollTo(currentID) }
            .onChange(of: currentID) { _, id in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
        }
        .frame(height: EditorToolbar.hitSide)
    }

    private func tab(_ e: DocumentTabEntry) -> some View {
        let active = e.id == currentID
        let canClose = closable(e.id)
        return HStack(spacing: 0) {
            Button { if !active, enabled { tabs.select(e.id, router: router) } } label: {
                HStack(spacing: 5) {
                    if active { Circle().fill(UF.accent).frame(width: 6, height: 6) }
                    Text(Self.shortTitle(e.title, active: active)).lineLimit(1).fixedSize()
                        .ufFont(12.8, active ? 650 : 500, lh: 1.2)
                }
                .padding(.leading, 10).padding(.trailing, canClose ? 2 : 10)
                .frame(height: EditorToolbar.hitSide)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(e.title)
            .accessibilityAddTraits(active ? [.isSelected] : [])
            .accessibilityHint(active ? "" : "Zu diesem Dokument wechseln")
            .accessibilityIdentifier("doc.tab.\(e.id)")
            if canClose {
                Button { tabs.close(e.id, router: router) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(active ? UF.accent.opacity(0.12) : Color.clear))
                        .frame(width: 28, height: EditorToolbar.hitSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reiter schließen: \(e.title)")
                .accessibilityIdentifier("doc.tab.close.\(e.id)")
                .padding(.trailing, 2)
            }
        }
        .foregroundStyle(active ? UF.accentText : UF.text2)
        .background(RoundedRectangle(cornerRadius: 9).fill(active ? UF.accentSoft : UF.surface2).padding(.vertical, 6))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? UF.accent.opacity(0.3) : UF.line, lineWidth: 1).padding(.vertical, 6))
        .help(e.title)
        .contextMenu { if canClose { contextItems(e) } }
    }

    @ViewBuilder private func contextItems(_ e: DocumentTabEntry) -> some View {
        Button { tabs.close(e.id, router: router) } label: { Label("Schließen", systemImage: "xmark") }
        Button { tabs.closeOthers(keeping: e.id, router: router) } label: { Label("Andere schließen", systemImage: "xmark.square") }
            .disabled(tabs.visibleEntries.count < 2)
        if DocumentWindows.supported {
            Button { tabs.openInNewWindow(e.id, router: router) } label: { Label("In neuem Fenster öffnen", systemImage: "macwindow.badge.plus") }
        }
    }

    /// Sehr schmal: ein Knopf mit dem gekuerzten Titel und der Zahl der Reiter, die Liste wechselt
    private var menu: some View {
        Menu {
            ForEach(items) { e in
                Button { if e.id != currentID { tabs.select(e.id, router: router) } } label: {
                    if e.id == currentID { Label(e.title, systemImage: "checkmark") } else { Text(e.title) }
                }
            }
            if closable(currentID) {
                Divider()
                Button(role: .destructive) { tabs.close(currentID, router: router) } label: { Label("Reiter schließen", systemImage: "xmark") }
            }
        } label: {
            HStack(spacing: 5) {
                Text(Self.shortTitle(currentTitle, limit: 12)).lineLimit(1).fixedSize()
                    .ufFont(12.8, 650, lh: 1.2)
                if items.count > 1 {
                    Text("\(items.count)").ufFont(11, 700, lh: 1).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(UF.accent.opacity(0.16)))
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(UF.accentText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(UF.accentSoft))
            .frame(height: EditorToolbar.hitSide)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Offene Dokumente: \(currentTitle)")
        .accessibilityIdentifier("doc.tabs.menu")
    }
}

private struct TabStripWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Mac und iPad mit Tastatur: Ctrl-Tab bzw. Cmd-Umschalt-] zum naechsten, Ctrl-Umschalt-Tab bzw. Cmd-Umschalt-[ zum
/// vorigen Reiter (wie Safari), dazu Cmd-Option-Pfeil; nach dem letzten wieder der erste
struct DocumentTabKeys: View {
    @ObservedObject var tabs: DocumentTabList
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        if tabs.entries.count > 1 {
            ZStack {
                Button("") { go(1) }.keyboardShortcut(.tab, modifiers: .control)
                Button("") { go(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("") { go(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("") { go(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("") { go(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("") { go(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func go(_ step: Int) {
        if let next = tabs.neighbor(step: step) { tabs.select(next, router: router) }
    }
}
