import SwiftUI
import UniFlowCore

// Kompakte Fassung der Lernbereiche (iPhone, iPad im schmalen Split View; docs/IPHONE-2026-11-04.md): KI-Start,
// Karteikarten, Tests & Wiederholung, Bibliothek und Community. Entschieden wird nach Platz
// (`horizontalSizeClass == .compact`), nie nach Geraet; die breite Fassung (iPad) bleibt unveraendert. Hier liegen nur
// die gemeinsamen Bausteine: Dialoge als Blatt von unten, eine waagerecht scrollende Reihe, die untere Leiste ueber
// der Tastatur und die schmale Brotkrumen-Zeile.

enum UFCompactLearn {
    /// Seitenrand schmal (16 pt wie die Systemlisten)
    static let gutter: CGFloat = 16

    /// kompakt = schmale Fassung: schmale Breite oder laut Huelle kompakt (`\.ufCompact`, auch iPhone quer)
    static func isCompact(_ sizeClass: UserInterfaceSizeClass?, shell: Bool = false) -> Bool { sizeClass == .compact || shell }

    /// Hoehe der grossen Lernkarte schmal: die sichtbare Hoehe ohne Kopf, Fortschritt, Hinweis und Knoepfe
    /// (`reserved`), mindestens 240 pt; ohne Messung (Hoehe 0) die Grundhoehe. Grosse Schrift: Karte nicht ueber
    /// 60 % der Hoehe, damit die Knoepfe ohne Scrollen bleiben.
    static func cardHeight(viewport: CGSize, reserved: CGFloat, typeSize: DynamicTypeSize) -> CGFloat {
        guard viewport.height > 0 else { return FlashcardCardLayout.baseMinHeight }
        var h = viewport.height - reserved
        if typeSize.isAccessibilitySize { h = min(h, viewport.height * 0.45) }
        return max(240, h.rounded())
    }

    /// Aufgabe n (0-basiert) im Testlauf schmal: innerhalb der Grenzen
    static func clampIndex(_ i: Int, count: Int) -> Int { count <= 0 ? 0 : min(max(0, i), count - 1) }

    /// Brotkrumen schmal: nur die letzte Ebene als Titel und die vorletzte als "zurueck"; nil ohne Elternebene
    static func parent<T>(_ crumbs: [T]) -> T? { crumbs.count >= 2 ? crumbs[crumbs.count - 2] : nil }
}

// MARK: - Dialoge als Blatt von unten

/// Blaetter einer Seite der Lernbereiche: schmal oeffnen Dialoge (`UFDialog`-Inhalte) als Blatt von unten
/// (`.presentationDetents([.medium, .large])`) statt mittig ueber der App. Ein Dialog, der im Blatt selbst einen
/// weiteren Dialog oeffnet, zeigt ihn im Blatt (eigene `UFOverlay`), damit er nicht unter dem Blatt verschwindet.
@MainActor
final class UFLearnSheets: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        /// nur gross (Gespraech, Test-Optionen mit Tastatur) oder mittel und gross
        let large: Bool
        /// Inhalt scrollt selbst (Gespraech mit Feld unten): kein ScrollView drumherum
        let scrolls: Bool
        let content: AnyView
    }

    @Published var item: Item?

    func present<V: View>(large: Bool = false, scrolls: Bool = false, @ViewBuilder _ content: () -> V) {
        item = Item(large: large, scrolls: scrolls, content: AnyView(content()))
    }

    func dismiss() { item = nil }
}

private struct UFLearnSheetsKey: EnvironmentKey {
    static let defaultValue: UFLearnSheets? = nil
}

extension EnvironmentValues {
    /// Blaetter der Seite; nil = breit (Dialoge mittig wie bisher) oder kein Wirt
    var ufLearnSheets: UFLearnSheets? {
        get { self[UFLearnSheetsKey.self] }
        set { self[UFLearnSheetsKey.self] = newValue }
    }
}

extension UFOverlay {
    /// Dialog eines Lernbereichs: mit `sheets` (schmal) als Blatt von unten, sonst mittig wie `modal`
    func learnModal<V: View>(_ sheets: UFLearnSheets?, wide: Bool = false, large: Bool = false, scrolls: Bool = false,
                             @ViewBuilder _ content: () -> V) {
        if let sheets {
            sheets.present(large: large, scrolls: scrolls, content)
        } else {
            modal(wide: wide, content)
        }
    }
}

/// Wirt der Blaetter an der Wurzel einer Seite. Die Seite haelt die Blaetter selbst (`@StateObject`, ihre eigenen
/// Eigenschaften sehen die Umgebung darunter nicht) und oeffnet schmal ueber `overlay.learnModal(sheets, …)`; Ansichten
/// darunter lesen `ufLearnSheets` (schmal die Blaetter, breit nil).
struct UFLearnSheetHost: ViewModifier {
    @ObservedObject var sheets: UFLearnSheets
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.ufCompact) private var shellCompact

    func body(content: Content) -> some View {
        let compact = UFCompactLearn.isCompact(sizeClass, shell: shellCompact)
        content
            .environment(\.ufLearnSheets, compact ? sheets : nil)
            .environment(\.ufLearnCompact, compact)
            .sheet(item: $sheets.item) { item in
                UFLearnSheetFrame(item: item, sheets: sheets) { sheets.dismiss() }
            }
    }
}

extension View {
    /// Dialoge dieser Seite schmal als Blatt von unten (`UFLearnSheetHost`)
    func ufLearnSheetHost(_ sheets: UFLearnSheets) -> some View { modifier(UFLearnSheetHost(sheets: sheets)) }
}

/// Rahmen eines Blatts: Ziehgriff, eigene Dialog-Ebene, `ufClose` schliesst das Blatt. Ein Dialog, der sich schliesst
/// und einen naechsten oeffnet ("Neu" -> "Notizbuch"), oeffnet ihn ueber `ufLearnSheets` als neues Blatt; andere
/// Dialoge aus dem Blatt heraus erscheinen im Blatt (eigene `UFOverlay`).
struct UFLearnSheetFrame: View {
    let item: UFLearnSheets.Item
    let sheets: UFLearnSheets
    let close: () -> Void
    @StateObject private var inner = UFOverlay()
    /// Schliessen wartet auf eine Rueckfrage (Umbenennen, Loeschen), die der Dialog nach `close()` stellt
    @State private var closeAfterAsk = false

    var body: some View {
        Group {
            if item.scrolls {
                item.content
            } else {
                ScrollView {
                    item.content.padding(.top, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.ufClose, closeSheet)
        .environment(\.ufInSheet, true)
        .environment(\.ufLearnSheets, sheets)
        .environment(\.ufLearnCompact, true)
        .environmentObject(inner)
        .modifier(UFModalHost(overlay: inner))
        .background(UF.surface.ignoresSafeArea())
        .ufSheetPresentation(wide: item.large)
        .accessibilityIdentifier("learn.sheet")
        .onChange(of: inner.ask == nil) { _, idle in
            if idle, closeAfterAsk {
                closeAfterAsk = false
                if sheets.item?.id == item.id { close() }
            }
        }
    }

    /// `ufClose` im Blatt: Dialoge schliessen sich oft zuerst und fragen dann (`overlay.prompt`/`confirm`); die
    /// Rueckfrage haengt am Blatt und ginge mit ihm verloren. Darum kurz warten: steht dann eine Rueckfrage, schliesst
    /// das Blatt erst nach ihr; hat der Dialog inzwischen ein neues Blatt geoeffnet, bleibt dieses.
    private func closeSheet() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if inner.ask != nil {
                closeAfterAsk = true
            } else if sheets.item?.id == item.id {
                close()
            }
        }
    }
}

private struct UFInSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Inhalt steht in einem Blatt von unten (kein eigener Kartenrahmen, volle Hoehe)
    var ufInSheet: Bool {
        get { self[UFInSheetKey.self] }
        set { self[UFInSheetKey.self] = newValue }
    }
}

// MARK: - Schmal auch in Blaettern

private struct UFLearnCompactKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Schmale Fassung der Seite, die ein Blatt geoeffnet hat. Ein Blatt hat eigene Merkmale (auf dem iPad kann es
    /// schmal sein, obwohl die Seite breit ist); die Seiten der Lernbereiche geben ihre Fassung darum weiter, nil =
    /// nicht gesetzt (dann gilt `horizontalSizeClass` der Ansicht selbst)
    var ufLearnCompact: Bool? {
        get { self[UFLearnCompactKey.self] }
        set { self[UFLearnCompactKey.self] = newValue }
    }
}

extension UFCompactLearn {
    /// Fassung einer Ansicht, die auch in einem Blatt stehen kann: die weitergegebene der Seite, sonst die eigene
    static func isCompact(_ sizeClass: UserInterfaceSizeClass?, shell: Bool = false, inherited: Bool?) -> Bool {
        inherited ?? isCompact(sizeClass, shell: shell)
    }

    /// Fassung einer Ansicht, die (fast) immer in einem Blatt steht: die weitergegebene der Seite, sonst die der Huelle
    /// (`\.ufCompact` reicht in Blaetter hinein). Die Groessenklasse des Blatts selbst zaehlt nicht: ein Blatt auf
    /// dem iPad ist schmal, die Seite darunter aber breit, und das iPad soll sich nicht aendern.
    static func inSheet(shell: Bool, inherited: Bool?) -> Bool { inherited ?? shell }
}

// MARK: - Bausteine

/// Waagerecht scrollende Reihe (Aktions-Pillen, Filter): Inhalt in voller Breite, Rand innen 16 pt, damit die erste
/// und letzte Pille buendig mit der Seite stehen und der Rest sichtbar angeschnitten weiterlaeuft
struct UFCompactScrollRow<Content: View>: View {
    var spacing: CGFloat = 8
    var inset: CGFloat = UFCompactLearn.gutter
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) { content }
                .padding(.horizontal, inset)
                .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.horizontal, -inset)
    }
}

/// Untere Leiste schmal (Weiter/Zurueck, Eingabefeld): liegt ueber Tab-Leiste bzw. Tastatur, Flaeche der Seite mit
/// Trennlinie oben
struct UFCompactBottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, UFCompactLearn.gutter)
            .padding(.top, 10).padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            // Flaeche auch unter dem Home-Balken: ein ScrollView darueber reicht bis an den Rand, sonst schiene sein
            // Inhalt unter der Leiste durch
            .background(alignment: .top) { Rectangle().fill(UF.bg).padding(.bottom, -60).ignoresSafeArea(edges: .bottom) }
            .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
    }
}

/// Brotkrumen schmal: "‹ Eltern" als Knopf, darunter der Titel der aktuellen Ebene (ganze Pfade brechen auf dem
/// iPhone in drei Zeilen um)
struct UFCompactCrumb: View {
    let parent: String?
    let title: String
    var detail: String?
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let parent {
                Button(action: back) {
                    HStack(spacing: 4) {
                        UFIcon("chevron-left", size: 14)
                        Text(parent).lineLimit(1)
                    }
                    .ufFont(14.4, 500).foregroundStyle(UF.accentText)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                    .ufHitArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zurück zu \(parent)")
                .accessibilityIdentifier("library.crumb.back")
            }
            Text(title).ufFont(20.8, 700, lh: 1.25).foregroundStyle(UF.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail, !detail.isEmpty {
                Text(detail).ufFont(13.12).foregroundStyle(UF.muted).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.crumb")
    }
}

/// Zeile eines Aktionsblatts (Menue "…" schmal): Symbol, Titel, 52 pt hoch
struct UFSheetActionRow: View {
    let title: String
    let icon: String
    var danger = false
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                UFIcon(icon, size: 18).frame(width: 24)
                Text(title).ufFont(16, 500)
                Spacer(minLength: 0)
            }
            .foregroundStyle(danger ? UF.badText : UF.text)
            .padding(.horizontal, UFCompactLearn.gutter)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title)
    }
}

/// Knopf in voller Breite fuer die untere Leiste schmal (Weiter, Abgeben): wie `UFButton`, Flaeche ueber die ganze
/// zugeteilte Breite, mindestens 48 pt hoch (Daumen)
struct UFWideButton: View {
    let title: String
    var icon: String?
    var kind: UFButtonKind = .normal
    let action: () -> Void

    init(_ title: String, icon: String? = nil, kind: UFButtonKind = .normal, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7.2) {
                if let icon { UFIcon(icon, size: 16) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(UFButtonStyle(kind: kind, size: .regular))
        .accessibilityLabel(title)
    }
}

/// Eingabefeld der unteren Leiste schmal (Antworten, Kommentare): eine Zeile, waechst bis fuenf, Flaeche --surface-2
/// wie das Feld der KI-Hilfe; die Beschriftung ist der Platzhalter
struct UFCompactComposerField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...5)
            .ufFont(14.5)
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UF.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
            .accessibilityLabel(placeholder)
    }
}
