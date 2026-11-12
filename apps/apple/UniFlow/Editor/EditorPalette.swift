import PencilKit
import UIKit
import UniFlowCore

/// Werkzeuge des Editors: frueher Apples Werkzeugpalette (`PKToolPicker`, Plan EDITOR-GOODNOTES-PLAN, 03.11.2026), seit
/// 11.11.2026 die feste Leiste oben im Dokument (`EditorToolbar.swift`, Auftrag "nicht schwebend"). Hier bleibt, was
/// beide brauchen:
/// - Kennungen und Zuordnung unserer Objektwerkzeuge (Objekte auswaehlen durch Antippen oder Lasso, Text, Haftnotiz,
///   Form: Rechteck, Ellipse, Linie, Pfeil, Text markieren, "Bereich an KI"); die gewaehlte Form- und Auswahlart ist
///   gemerkt.
/// - "Nur Stift / Finger zeichnet" bleibt unser Schalter in der Kopfzeile (Standard: nur der Stift schreibt, der Finger
///   blaettert). Die iPadOS-Einstellung `UIPencilInteraction.prefersPencilOnlyDrawing` kann eine App nur lesen; mit der
///   Eingabeart `.default` schrieb der Finger am Geraet, Blaettern ging nicht mehr (Geraetetest 03.11.2026).
/// - Objekte uebernehmen Farbe und Staerke der Stifte; "Text markieren" die Farbe des Textmarkers (`PaletteSync`).
/// - Der Fokus kehrt nach Blaettern, Textfeldern und Blaettern zum Editor zurueck (`Blocker`), damit Tastenbefehle und
///   Rueckgaengig ueber die Responder-Kette wirken.
enum EditorPalette {
    static let selectID = "de.studinow.palette.select"
    static let textID = "de.studinow.palette.text"
    static let stickyID = "de.studinow.palette.sticky"
    static let shapeID = "de.studinow.palette.shape"
    static let markupID = "de.studinow.palette.markup"
    /// "Bereich an KI" (05.11.2026): Ausschnitt einkreisen, er geht als Bild in die KI-Hilfe
    static let areaID = "de.studinow.palette.area"
    /// Reihenfolge der Objektwerkzeuge: "Bereich an KI" vorn (Wunsch des Inhabers), dann Form und Text (am haeufigsten),
    /// Haftnotiz, Auswaehlen, Text markieren
    static let customIDs = [areaID, shapeID, textID, stickyID, selectID, markupID]

    static let areaTitle = "Bereich an KI"

    /// Zustand der Werkzeuge fuer Protokolle (Geraete-Probe `EditorDeviceProbeTests`, Startargument `-UFPaletteProbe 1`)
    @MainActor
    static func describe(editor: PDFEditorController) -> [String] {
        var lines: [String] = []
        let t = editor.tools
        lines.append("Leiste: Werkzeug \(t.tool.rawValue), Lineal \(t.ruler), Radierer \(t.eraserKind.rawValue), letzter Stift \(t.lastInk.rawValue), sichtbar \(editor.toolbarMode.visible), nur Tinte \(editor.toolbarMode.inkOnly)")
        lines.append("prefersPencilOnlyDrawing (iPadOS-Einstellung): \(UIPencilInteraction.prefersPencilOnlyDrawing), Doppeltippen \(UIPencilInteraction.preferredTapAction.rawValue)")
        lines.append("editor: pencilOnly \(editor.pencilOnly), drawingPolicy \(editor.drawingPolicy.rawValue) (0 default, 1 anyInput, 2 pencilOnly), writable \(editor.writable), pickerAllowed \(editor.pickerAllowed), objectMode \(editor.objects.isActive) \(editor.objects.tool.rawValue), blocker \(editor.paletteBlocker)")
        let canvases = editor.allOverlays.map { "p\($0.pageIndex): policy \($0.canvas.drawingPolicy.rawValue), input \($0.canvas.isUserInteractionEnabled), tool \(type(of: $0.canvas.tool)), ruler \($0.canvas.isRulerActive)" }
        lines.append("canvas: " + canvases.joined(separator: " | "))
        if let scene = editor.view.window?.windowScene {
            lines.append("windows: " + scene.windows.map { "\(type(of: $0)) hidden=\($0.isHidden) level=\($0.windowLevel.rawValue)" }.joined(separator: ", "))
        }
        return lines
    }

    // MARK: Optionen der eigenen Eintraege (Form: Art, Auswaehlen: Antippen oder Lasso)

    static let shapeKey = "uniflow.palette.shape"
    static let selectKey = "uniflow.palette.select"
    static let shapeChoices: [ObjectEditing.Tool] = [.rect, .ellipse, .line, .arrow]
    static let selectChoices: [ObjectEditing.Tool] = [.select, .lasso]

    static var shapeTool: ObjectEditing.Tool {
        get { UserDefaults.standard.string(forKey: shapeKey).flatMap(ObjectEditing.Tool.init(rawValue:)).flatMap { shapeChoices.contains($0) ? $0 : nil } ?? .rect }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: shapeKey) }
    }

    static var selectTool: ObjectEditing.Tool {
        get { UserDefaults.standard.string(forKey: selectKey).flatMap(ObjectEditing.Tool.init(rawValue:)).flatMap { selectChoices.contains($0) ? $0 : nil } ?? .select }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectKey) }
    }

    /// Objektwerkzeug zu einem eigenen Eintrag der Palette (nil: Apples Werkzeug)
    static func objectTool(for identifier: String, shape: ObjectEditing.Tool = shapeTool,
                           select: ObjectEditing.Tool = selectTool) -> ObjectEditing.Tool? {
        switch identifier {
        case selectID: return select
        case textID: return .text
        case stickyID: return .sticky
        case shapeID: return shape
        case markupID: return .markup
        case areaID: return .area
        default: return nil
        }
    }

    /// Eintrag der Palette zu einem Objektwerkzeug
    static func identifier(for tool: ObjectEditing.Tool) -> String {
        switch tool {
        case .select, .lasso: return selectID
        case .text: return textID
        case .sticky: return stickyID
        case .rect, .ellipse, .line, .arrow: return shapeID
        case .markup: return markupID
        case .area: return areaID
        }
    }

    // MARK: Fokus zurueck zum Editor

    /// Was den Fokus gerade beim Element halten darf (frueher: die Palette verdeckt halten); `none`: er kann sofort zurueck
    enum Blocker: Equatable {
        case none
        /// nicht gewuenscht (nur ansehen, nicht im Fenster, andere Haelfte der geteilten Ansicht)
        case notWanted
        /// "Text markieren": die PDF-Ansicht braucht den Fokus fuer die Textauswahl
        case markup
        /// PDF-Text ist ausgewaehlt (Finger gedrueckt halten; der Text geht an die KI-Hilfe mit): PDFKit haelt den
        /// Fokus, sonst verschwaende die Auswahl; zurueck mit `PDFViewSelectionChanged` ohne Auswahl
        case pdfSelection
        /// Textfeld mit Tastatur (KI-Hilfe, Suche, Textobjekt); zurueck nach `keyboardDidHide`/`textDidEndEditing`
        case textInput
        /// Blatt oder Hinweis ueber dem Editor; zurueck, sobald es den Bildschirm verlassen hat
        case presentation
        /// Menue oder Popover in einem eigenen Fenster; zurueck nach `UIWindow.didBecomeHidden`
        case otherWindow
    }

    static func blocker(wanted: Bool, inWindow: Bool, markup: Bool, pdfSelection: Bool = false, textInput: Bool,
                        presenting: Bool, otherWindow: Bool) -> Blocker {
        if !wanted || !inWindow { return .notWanted }
        if markup { return .markup }
        if pdfSelection { return .pdfSelection }
        if textInput { return .textInput }
        if presenting { return .presentation }
        if otherWindow { return .otherWindow }
        return .none
    }
}

/// Merkt sich, was die Leiste eingestellt hat: letzte Stiftfarbe und -staerke, Farbe des Textmarkers. Objekte nehmen
/// diese Werte; Text und Form uebernehmen beim Wechsel vom Stift dessen Farbe, solange man dort keine eigene Farbe
/// gewaehlt hat.
final class PaletteSync {
    private(set) var inkHex = "#1d2130"
    private(set) var inkWidth = 2.0
    private(set) var markerHex = PageObjectEdit.markerColors[0]
    /// zuletzt benutzter Stift der Palette (fuer den Rueckweg aus den Objektwerkzeugen)
    private(set) var lastInkItemID: String?
    private let defaults: UserDefaults
    private static let syncedKey = "uniflow.palette.syncedColors"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Werkzeug der Palette: Stift oder Textmarker
    func note(_ tool: PKInkingTool, itemID: String? = nil) {
        let hex = tool.color.uniflowRGBA.hex
        if tool.inkType == .marker {
            markerHex = hex
        } else {
            inkHex = hex
            inkWidth = Double(tool.width)
            if let itemID { lastInkItemID = itemID }
        }
    }

    /// Strichstaerke fuer Formen ohne eigene Staerke (iPadOS 17): Stiftstaerke, begrenzt wie im Web
    var shapeWidth: Double { min(12, max(1, (inkWidth * 2).rounded() / 2)) }

    /// Neue Farbe fuer einen eigenen Eintrag beim Auswaehlen: die Stiftfarbe, solange der Eintrag noch die zuletzt
    /// uebernommene Farbe traegt. Hat man dort selbst eine gewaehlt, bleibt sie (nil).
    func adoptInkColor(item id: String, current hex: String) -> String? {
        var synced = defaults.dictionary(forKey: Self.syncedKey) as? [String: String] ?? [:]
        if let last = synced[id], !Self.sameColor(last, hex) { return nil }    // eigene Farbe in der Palette gewaehlt
        synced[id] = inkHex
        defaults.set(synced, forKey: Self.syncedKey)
        return Self.sameColor(hex, inkHex) ? nil : inkHex
    }

    /// Gleiche Farbe bis auf Rundung (PencilKit rechnet Farben in einen erweiterten Farbraum um)
    static func sameColor(_ a: String, _ b: String) -> Bool {
        guard let x = UInt32(a.dropFirst(), radix: 16), let y = UInt32(b.dropFirst(), radix: 16) else { return a == b }
        return [16, 8, 0].allSatisfy { abs(Int((x >> $0) & 0xff) - Int((y >> $0) & 0xff)) <= 2 }
    }

    /// Farbe fuer "Text markieren": Markieren in der Farbe des Textmarkers; Unter- und Durchstreichen ebenso, ausser bei
    /// hellen Farben (dort Rot wie im Web, `PageObjectEdit.markup`)
    func markupColor(_ kind: PageObjectEdit.Markup) -> String {
        guard kind != .highlight, Self.luminance(markerHex) > 0.6 else { return markerHex }
        return PageObjectEdit.markerColors[0]                       // wird in `PageObjectEdit.markup` zu Rot
    }

    static func luminance(_ hex: String) -> Double {
        guard let c = UIColor(hex: hex) else { return 0 }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(0.2126 * r + 0.7152 * g + 0.0722 * b)
    }
}

/// Unsichtbare Markierung in einem Blatt: meldet, wenn das Blatt den Bildschirm verlassen hat (der Fokus kommt dann
/// zum Editor zurueck, ohne in Abstaenden nachzusehen)
final class WindowExitSentinel: UIView {
    var onLeave: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil, let leave = onLeave else { return }
        onLeave = nil
        DispatchQueue.main.async { leave() }
    }
}
