import Combine
import PencilKit
import SwiftUI
import UIKit
import UniFlowCore

// Feste Werkzeugleiste oben im Dokument (Auftrag des Inhabers 11.11.2026: "Mach das Apple-Pencil-Kit oben fest, das
// darf nicht schwebend sein").
//
// Apples `PKToolPicker` laesst sich nicht festsetzen: Die Header des SDK (iPhoneOS 27.2, PKToolPicker.h,
// PKResponderState.h) kennen weder Lage noch Andocken noch ein Verbot des Verschiebens; `frameObscuredInView:` liefert
// ausdruecklich `CGRectNull`, "wenn die Palette beweglich ist". Darum zeigt der Editor Apples Palette nicht mehr und
// fuehrt die Werkzeuge selbst: `EditorToolState` (ein Stand fuer beide Haelften der geteilten Ansicht, je Geraet
// gemerkt) und `EditorToolbar` (Leiste unter der Kopfzeile, volle Breite, immer an derselben Stelle).
//
// 12.11.2026 (Inhaber: "den Pencil-Kit-Strich kleiner und fest oben oder unten, man kann aussuchen, oder weiterhin
// schwebend, in Einstellung"): Leiste 44 statt 52 pt hoch, Lage in den Einstellungen waehlbar (`EditorToolbarPlacement`:
// oben fest, unten fest, schwebend = Apples Palette, `EditorFloatingPalette.swift`). Ohne Schreiben im Tarif steht sie
// mit Schloss da (`EditorLockedToolbar`) statt zu fehlen.

/// Sichtbarkeit der Leiste, vom Editor gemeldet (wie frueher die Palette: nur mit Schreiben, nicht beim Abpausen und in
/// der Praesentation); im Korrektur-Modus nur Stifte, Radierer, Lasso und Lineal
struct EditorToolbarMode: Equatable {
    var visible = false
    var inkOnly = false

    static let hidden = EditorToolbarMode()
}

/// Werkzeugwahl des Editors: Stift, Fineliner, Textmarker (je Farbe und Staerke), Radierer (Pixel oder Objekt), Lasso,
/// Lineal und unsere Objektwerkzeuge. Jede Aenderung geht ueber `changes` an die Editoren (beide Haelften der geteilten
/// Ansicht), die das Werkzeug ihrer Zeichenflaechen bzw. den Objektmodus setzen.
@MainActor
final class EditorToolState: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, fineliner, marker, eraser, lasso
        case select, text, sticky, shape, markup, area

        var id: String { rawValue }

        /// Werkzeuge der Zeichenflaeche (PencilKit) in der Reihenfolge der Leiste
        static let canvasTools: [Tool] = [.pen, .fineliner, .marker, .eraser, .lasso]
        /// Objektwerkzeuge in der Reihenfolge der Leiste ("Bereich an KI" vorn wie in der Palette, Wunsch des Inhabers)
        static let objectTools: [Tool] = [.area, .select, .text, .sticky, .shape, .markup]

        var isInk: Bool { self == .pen || self == .fineliner || self == .marker }
        /// wirkt auf der Zeichenflaeche (sonst Objektmodus)
        var drawsOnCanvas: Bool { isInk || self == .eraser || self == .lasso }
        /// Farbe waehlbar (Text und Form: eigene Farbe, anfangs die des Stifts)
        var hasColor: Bool { isInk || self == .text || self == .shape }
        /// Staerken waehlbar (Seitenpunkte; bei Seitenbreite auf dem iPad hochkant 1 Seitenpunkt = 1,38 Bildschirmpunkte).
        /// Jede Stufe liegt in den Grenzen von PencilKit (`validWidthRange`, `StiftStaerkeTests`): Stift ab 0,88,
        /// Fineliner 0,5 bis 4, Textmarker ab 7,5. Vorher (bis 14.11.2026) Stift ab 1, Fineliner 0,8 bis 6 (6 wurde
        /// still auf 4 begrenzt, gleich der Stufe davor), Textmarker ab 6 (still 7,5). Wunsch des Inhabers: duenner.
        var widths: [CGFloat] {
            switch self {
            case .pen: return [0.88, 2, 3.5, 6, 10]
            case .fineliner: return [0.5, 0.8, 1.5, 2.5, 4]
            case .marker: return [7.5, 10, 15, 22, 30]
            case .shape: return [1, 2, 4]
            default: return []
            }
        }

        var inkType: PKInkingTool.InkType? {
            switch self {
            case .pen: return .pen
            case .fineliner: return .monoline
            case .marker: return .marker
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .pen: return "Stift"
            case .fineliner: return "Fineliner"
            case .marker: return "Textmarker"
            case .eraser: return "Radierer"
            case .lasso: return "Lasso"
            case .select: return "Auswählen"
            case .text: return "Text"
            case .sticky: return "Haftnotiz"
            case .shape: return "Form"
            case .markup: return "Text markieren"
            case .area: return EditorPalette.areaTitle
            }
        }

        var icon: String {
            switch self {
            case .pen: return "pencil.tip"
            case .fineliner: return "pencil"
            case .marker: return "highlighter"
            case .eraser: return "eraser"
            case .lasso: return "lasso"
            case .select: return EditorPalette.selectTool.systemImage
            case .text: return "textformat"
            case .sticky: return "note.text"
            case .shape: return EditorPalette.shapeTool.systemImage
            case .markup: return "underline"
            case .area: return ObjectEditing.Tool.area.systemImage
            }
        }

        /// Kennung wie frueher der Eintrag in Apples Palette (gemerkte Farbuebernahme von Text und Form, `PaletteSync`)
        var paletteID: String? {
            switch self {
            case .select: return EditorPalette.selectID
            case .text: return EditorPalette.textID
            case .sticky: return EditorPalette.stickyID
            case .shape: return EditorPalette.shapeID
            case .markup: return EditorPalette.markupID
            case .area: return EditorPalette.areaID
            default: return nil
            }
        }

        /// Objektwerkzeug (Form und Auswaehlen nach ihrer gemerkten Art), nil fuer Werkzeuge der Zeichenflaeche
        var objectTool: ObjectEditing.Tool? {
            paletteID.flatMap { EditorPalette.objectTool(for: $0) }
        }

        /// Eintrag der Leiste zu einem Objektwerkzeug
        static func forObject(_ t: ObjectEditing.Tool) -> Tool {
            switch t {
            case .select, .lasso: return .select
            case .text: return .text
            case .sticky: return .sticky
            case .rect, .ellipse, .line, .arrow: return .shape
            case .markup: return .markup
            case .area: return .area
            }
        }
    }

    /// Radierer: Pixel (radiert, was er beruehrt) oder Objekt (ganze Striche)
    enum EraserKind: String, CaseIterable, Identifiable {
        case pixel, object
        var id: String { rawValue }
        var title: String { self == .pixel ? "Pixel" : "Objekt" }
        var pkType: PKEraserTool.EraserType { self == .pixel ? .bitmap : .vector }
    }

    struct Style: Codable, Equatable {
        var hex: String
        var width: CGFloat
        /// Deckkraft 0,1 ... 1 (Einstellungen je Stift, 14.11.2026); nil = deckend (aeltere Einstellungen)
        var opacity: CGFloat?

        var alpha: CGFloat { min(1, max(0.1, opacity ?? 1)) }
    }

    /// Eigener Stift (Einstellungen je Stift, 14.11.2026): Werkzeug mit Farbe, Staerke und Deckkraft, in der Leiste
    struct PenPreset: Codable, Equatable, Identifiable {
        var id: String
        var tool: String
        var style: Style

        var toolValue: Tool? { Tool(rawValue: tool).flatMap { $0.isInk ? $0 : nil } }
    }

    /// hoechstens so viele eigene Stifte
    static let presetLimit = 8

    /// Staerken, die der Schieber im Einstellungsblatt anbietet (innerhalb der Grenzen von PencilKit, `widthLimits`)
    static func sliderRange(_ t: Tool) -> ClosedRange<CGFloat> {
        let limits = widthLimits(t)
        switch t {
        case .pen: return limits.lowerBound...min(limits.upperBound, 14)
        case .marker: return limits.lowerBound...min(limits.upperBound, 40)
        default: return limits
        }
    }

    /// Grenzen von PencilKit fuer die Tinte des Werkzeugs (`validWidthRange`); ohne Tinte die Stufen
    static func widthLimits(_ t: Tool) -> ClosedRange<CGFloat> {
        // nach innen auf zwei Stellen (PencilKit meldet z. B. 0,8782 fuer den Stift; gezeigt und gespeichert wird 0,88)
        if let ink = t.inkType {
            let r = ink.validWidthRange
            return ((r.lowerBound * 100).rounded(.up) / 100)...((r.upperBound * 100).rounded(.down) / 100)
        }
        return (t.widths.min() ?? 0)...(t.widths.max() ?? 0)
    }

    /// Staerke in die Grenzen bringen (gespeicherte Werte, die PencilKit nicht kann: Fineliner 6 -> 4, Textmarker
    /// 6 -> 7,5), auf zwei Stellen gerundet
    static func clampedWidth(_ w: CGFloat, for t: Tool) -> CGFloat {
        guard t.inkType != nil else { return w }
        let r = widthLimits(t)
        return (min(max(w, r.lowerBound), r.upperBound) * 100).rounded() / 100
    }

    /// Feiner Schritt fuer "−"/"+": unter 2 pt 0,1, bis 6 pt 0,25, darueber 1
    static func widthStep(_ w: CGFloat) -> CGFloat { w < 2 ? 0.1 : (w < 6 ? 0.25 : 1) }

    /// Naechste Staerke fuer "−" (`up` false) bzw. "+": naechster Punkt auf dem Raster des Schritts, in den Grenzen
    /// des Schiebers (0,88 -> 0,9 -> 1,0 ...; 2 -> 2,25; 6 -> 7)
    static func steppedWidth(_ w: CGFloat, up: Bool, for t: Tool) -> CGFloat {
        let range = sliderRange(t)
        let step = widthStep(up ? w : w - 0.001)
        let grid = w / step
        let n = up ? (grid + 0.001).rounded(.down) + 1 : (grid - 0.001).rounded(.up) - 1
        let next = (n * step * 100).rounded() / 100
        return min(max(next, range.lowerBound), range.upperBound)
    }

    /// Was sich geaendert hat (die Editoren setzen danach das Werkzeug ihrer Zeichenflaechen)
    enum Change: Equatable { case tool, style, ruler }

    /// Farben der Leiste (dunkel fuer Stifte, hell fuer den Textmarker), weitere ueber den Farbwaehler
    static let inkColors: [(hex: String, name: String)] = [
        ("#1d2130", "Schwarz"), ("#2f7fd1", "Blau"), ("#e5322d", "Rot"), ("#2e9e5b", "Grün"), ("#f08c1f", "Orange"), ("#7a4fd6", "Lila"),
    ]
    static let markerColors: [(hex: String, name: String)] = [
        (PageObjectEdit.markerColors[0], "Gelb"), (PageObjectEdit.markerColors[1], "Grün"), (PageObjectEdit.markerColors[2], "Blau"),
        (PageObjectEdit.markerColors[3], "Pink"), ("#ffb35c", "Orange"),
    ]

    static func colors(for t: Tool) -> [(hex: String, name: String)] { t == .marker ? markerColors : inkColors }

    /// Menue "Werkzeuge" am Mac: Farben fuer Stift und Textmarker, Staerken in drei Stufen
    static let menuColors = inkColors + [markerColors[0]]
    static let widthSteps = ["Fein", "Mittel", "Dick"]

    static func defaultStyle(_ t: Tool) -> Style {
        switch t {
        case .pen: return Style(hex: "#1d2130", width: 2)
        case .fineliner: return Style(hex: "#2f7fd1", width: 1.5)
        case .marker: return Style(hex: PageObjectEdit.markerColors[0], width: 15)
        case .text: return Style(hex: "#1d2130", width: 0)
        case .shape: return Style(hex: "#e5322d", width: 2)
        default: return Style(hex: "#1d2130", width: 0)
        }
    }

    @Published private(set) var tool: Tool = .pen
    @Published private(set) var ruler = false
    @Published private(set) var eraserKind: EraserKind = .object
    @Published private(set) var styles: [String: Style] = [:]
    /// Eigene Stifte in der Reihenfolge der Leiste
    @Published private(set) var presets: [PenPreset] = []
    /// Doppeltippen/Druecken des Apple Pencil mit "Farbpalette" bzw. "Kontextpalette": Farbe und Staerke oeffnen
    @Published private(set) var attributesRequest = 0
    /// letzter Stift (Stift, Fineliner oder Textmarker): zurueck aus Objektwerkzeugen, "Fertig"
    private(set) var lastInk: Tool = .pen
    /// letzter Stift ohne Textmarker (Farbe und Staerke fuer Objekte, `PaletteSync.inkHex`)
    private(set) var lastPen: Tool = .pen
    /// letztes Werkzeug der Zeichenflaeche (gilt dort auch, solange ein Objektwerkzeug gewaehlt ist)
    private(set) var lastCanvasTool: Tool = .pen
    /// Werkzeug vor dem jetzigen (Apple Pencil: "Zum vorherigen Werkzeug wechseln", Radierer hin und zurueck)
    private(set) var previous: Tool?

    let changes = PassthroughSubject<Change, Never>()
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter key: Speichername je Geraet (Werkzeug, Farben, Staerken, Radierer); Tests nehmen einen eigenen
    init(defaults: UserDefaults = .standard, key: String = "uniflow.toolbar") {
        self.defaults = defaults
        self.key = key
        load()
    }

    // MARK: Werkzeug

    /// Werkzeug waehlen. Gleiches Werkzeug noch einmal meldet sich ebenso (Form- oder Auswahlart kann sich geaendert haben).
    func select(_ t: Tool) {
        if t != tool {
            previous = tool
            tool = t
        }
        if t.isInk { lastInk = t }
        if t == .pen || t == .fineliner { lastPen = t }
        if t.drawsOnCanvas { lastCanvasTool = t }
        save()
        changes.send(.tool)
    }

    /// Der Editor hat das Objektwerkzeug selbst gewechselt (nach dem Anlegen eines Textes, nach dem Lasso): die Leiste
    /// zeigt es, ohne dass die Editoren erneut reagieren
    func reflect(_ t: Tool) {
        guard t != tool else { return }
        previous = tool
        tool = t
    }

    /// Zurueck zum letzten Stift (aus Objektwerkzeugen, "Fertig")
    func selectLastInk() { select(lastInk) }

    /// Art der Form (Rechteck, Ellipse, Linie, Pfeil) waehlen; zugleich das Werkzeug Form
    func setShape(_ t: ObjectEditing.Tool) {
        guard EditorPalette.shapeChoices.contains(t) else { return }
        EditorPalette.shapeTool = t
        select(.shape)
    }

    /// Auswaehlen durch Antippen oder Lasso; zugleich das Werkzeug Auswaehlen
    func setSelectMode(_ t: ObjectEditing.Tool) {
        guard EditorPalette.selectChoices.contains(t) else { return }
        EditorPalette.selectTool = t
        select(.select)
    }

    func setEraser(_ k: EraserKind) {
        eraserKind = k
        select(.eraser)
    }

    func toggleRuler() { setRuler(!ruler) }

    func setRuler(_ on: Bool) {
        guard ruler != on else { return }
        ruler = on
        changes.send(.ruler)
    }

    // MARK: Farbe und Staerke

    func style(_ t: Tool) -> Style { styles[t.rawValue] ?? Self.defaultStyle(t) }

    /// Werkzeug, dessen Farbe und Staerke die Leiste gerade zeigt: das gewaehlte, sonst der letzte Stift
    var styledTool: Tool { tool.hasColor ? tool : lastInk }

    func setColor(_ hex: String, for t: Tool? = nil) {
        let t = t ?? styledTool
        guard t.hasColor else { return }
        var s = style(t)
        s.hex = hex
        setStyle(s, for: t)
    }

    func setWidth(_ w: CGFloat, for t: Tool? = nil) {
        let t = t ?? styledTool
        guard !t.widths.isEmpty else { return }
        var s = style(t)
        s.width = Self.clampedWidth(w, for: t)
        setStyle(s, for: t)
    }

    func setOpacity(_ o: CGFloat, for t: Tool) {
        guard t.isInk else { return }
        var s = style(t)
        s.opacity = min(1, max(0.1, (o * 100).rounded() / 100))
        setStyle(s, for: t)
    }

    /// "Zurücksetzen" im Einstellungsblatt: Farbe, Staerke und Deckkraft wie beim ersten Start
    func resetStyle(_ t: Tool) {
        styles[t.rawValue] = nil
        save()
        changes.send(.style)
    }

    // MARK: Eigene Stifte

    /// Den Stift, wie er gerade eingestellt ist, als eigenen Stift merken (gleiche gibt es nur einmal)
    @discardableResult
    func addPreset(from t: Tool) -> PenPreset? {
        guard t.isInk, presets.count < Self.presetLimit else { return nil }
        let s = style(t)
        if let same = presets.first(where: { $0.tool == t.rawValue && $0.style == s }) { return same }
        let p = PenPreset(id: UUID().uuidString, tool: t.rawValue, style: s)
        presets.append(p)
        save()
        return p
    }

    func removePreset(_ id: String) {
        presets.removeAll { $0.id == id }
        save()
    }

    /// Eigenen Stift nehmen: sein Werkzeug waehlen und dessen Farbe, Staerke und Deckkraft setzen
    func applyPreset(_ id: String) {
        guard let p = presets.first(where: { $0.id == id }), let t = p.toolValue else { return }
        var s = p.style
        s.width = Self.clampedWidth(s.width, for: t)
        setStyle(s, for: t, silently: true)
        select(t)
        changes.send(.style)
    }

    /// Ist der eigene Stift gerade eingestellt (Werkzeug gewaehlt, gleiche Farbe, Staerke, Deckkraft)?
    func isActive(_ p: PenPreset) -> Bool { tool.rawValue == p.tool && style(tool) == p.style }

    /// Stufe 0 (fein), 1 (mittel), 2 (dick) des gewaehlten Werkzeugs (Menue am Mac)
    func setWidthStep(_ step: Int) {
        let ws = styledTool.widths
        guard !ws.isEmpty else { return }
        let i = ws.count == 1 ? 0 : min(ws.count - 1, max(0, step) * (ws.count - 1) / 2)
        setWidth(ws[i])
    }

    /// - Parameter silently: ohne Meldung an die Editoren (der Editor uebernimmt selbst, z. B. die Stiftfarbe fuer Text)
    func setStyle(_ s: Style, for t: Tool, silently: Bool = false) {
        guard style(t) != s else { return }
        styles[t.rawValue] = s
        save()
        if !silently { changes.send(.style) }
    }

    /// Stift mit Farbe und Staerke (Staerke in den Grenzen von PencilKit)
    func inkingTool(_ t: Tool) -> PKInkingTool? {
        guard let type = t.inkType else { return nil }
        let s = style(t)
        let range = type.validWidthRange
        let w = min(max(s.width, range.lowerBound), range.upperBound)
        let color = (UIColor(hex: s.hex) ?? .black).withAlphaComponent(s.alpha)
        return PKInkingTool(type, color: color, width: w)
    }

    /// Werkzeug fuer die Zeichenflaechen: das gewaehlte, bei einem Objektwerkzeug das letzte der Zeichenflaeche (die
    /// nimmt dann ohnehin keine Eingabe an)
    var canvasTool: PKTool {
        let t = tool.drawsOnCanvas ? tool : lastCanvasTool
        switch t {
        case .eraser: return PKEraserTool(eraserKind.pkType)
        case .lasso: return PKLassoTool()
        default: return inkingTool(t) ?? PKInkingTool(.pen, color: .black)
        }
    }

    // MARK: Apple Pencil (Doppeltippen, Druecken)

    enum PencilAction: Equatable { case toggleEraser, togglePrevious, showAttributes, none }

    /// Bedeutung der Einstellung "Doppeltippen"/"Druecken" in den iPadOS-Einstellungen fuer die Leiste
    nonisolated static func pencilAction(_ preferred: UIPencilPreferredAction) -> PencilAction {
        switch preferred {
        case .switchEraser: return .toggleEraser
        case .switchPrevious: return .togglePrevious
        case .showColorPalette, .showInkAttributes: return .showAttributes
        default:
            if #available(iOS 17.5, *), preferred == .showContextualPalette { return .showAttributes }
            return .none
        }
    }

    /// - Parameter inkOnly: Korrektur-Modus (keine Objektwerkzeuge)
    func perform(_ a: PencilAction, inkOnly: Bool = false) {
        switch a {
        case .toggleEraser:
            if tool == .eraser {
                let back = previous.flatMap { $0 != .eraser && (!inkOnly || $0.drawsOnCanvas) ? $0 : nil } ?? lastInk
                select(back)
            } else {
                select(.eraser)
            }
        case .togglePrevious:
            guard let p = previous, !inkOnly || p.drawsOnCanvas else { return }
            select(p)
        case .showAttributes:
            attributesRequest += 1
        case .none:
            break
        }
    }

    // MARK: Gemerkt je Geraet

    private struct Saved: Codable {
        var tool: String
        var lastInk: String
        var lastPen: String?
        var eraser: String
        var styles: [String: Style]
        var presets: [PenPreset]?
    }

    private func load() {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        // Staerken, die PencilKit nicht kann (aeltere Stufen: Fineliner 6, Textmarker 6), auf die naechste gueltige
        var loaded = s.styles
        for (k, var v) in loaded {
            if let t = Tool(rawValue: k) { v.width = Self.clampedWidth(v.width, for: t) }
            loaded[k] = v
        }
        styles = loaded
        presets = (s.presets ?? []).filter { $0.toolValue != nil }.prefix(Self.presetLimit).map { var p = $0; p.style.width = Self.clampedWidth(p.style.width, for: p.toolValue!); return p }
        eraserKind = EraserKind(rawValue: s.eraser) ?? .object
        if let i = Tool(rawValue: s.lastInk), i.isInk { lastInk = i }
        if let p = s.lastPen.flatMap(Tool.init(rawValue:)), p == .pen || p == .fineliner { lastPen = p }
        // beim Oeffnen nie ein Objektwerkzeug (wie frueher die Palette): sonst der letzte Stift
        let t = Tool(rawValue: s.tool).flatMap { $0.drawsOnCanvas ? $0 : nil } ?? lastInk
        tool = t
        lastCanvasTool = t
    }

    private func save() {
        let s = Saved(tool: (tool.drawsOnCanvas ? tool : lastCanvasTool).rawValue, lastInk: lastInk.rawValue, lastPen: lastPen.rawValue,
                      eraser: eraserKind.rawValue, styles: styles, presets: presets)
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
}

// MARK: - Leiste

/// Feste Werkzeugleiste unter der Kopfzeile, volle Breite (`DocumentView`): links die Werkzeuge der Zeichenflaeche und
/// das Lineal, dann unsere Objektwerkzeuge, rechts Farbe/Staerke des gewaehlten Werkzeugs sowie Rueckgaengig und
/// Wiederholen. Nicht verschiebbar, kein Einklappen. Ein zweites Tippen auf das gewaehlte Werkzeug oeffnet seine
/// Einstellungen (wie in Apples Palette); bei schmalem Fenster laesst sich die Werkzeugreihe waagerecht schieben.
struct EditorToolbar: View {
    @ObservedObject var tools: EditorToolState
    let mode: EditorToolbarMode
    let undo: () -> Void
    let redo: () -> Void
    /// vor dem Waehlen eines Werkzeugs (Mac: die Maus schreibt danach)
    let onPick: (EditorToolState.Tool) -> Void
    /// "KI fragen" (nur mit verbundener KI, wie frueher am Rand von Apples Palette): KI-Hilfe mit markiertem Text
    let askAI: (() -> Void)?
    /// ohne KI und ohne Pro AI: "KI fragen" sichtbar mit Schloss (Auftrag des Inhabers 12.11.2026), Antippen oeffnet
    /// die Tarifwahl
    let askAILock: UFPlan?
    /// Leiste unten im Dokument ("Unten fest"): Trennlinie oben statt unten
    let atBottom: Bool
    /// in der einen Kopfzeile ("Oben fest", `EditorHeaderBar`, 12.11.2026): ohne eigene Flaeche und Linie, nur so breit
    /// wie noetig; passt sie nicht, ruecken die Objektwerkzeuge in einen Knopf, danach laesst sich die Reihe schieben
    let embedded: Bool
    @State private var attributesOpen = false
    @State private var optionsFor: EditorToolState.Tool?

    init(tools: EditorToolState, mode: EditorToolbarMode, undo: @escaping () -> Void, redo: @escaping () -> Void,
         onPick: @escaping (EditorToolState.Tool) -> Void = { _ in }, askAI: (() -> Void)? = nil, askAILock: UFPlan? = nil,
         atBottom: Bool = false, embedded: Bool = false) {
        self.tools = tools
        self.mode = mode
        self.undo = undo
        self.redo = redo
        self.onPick = onPick
        self.askAI = askAI
        self.askAILock = askAILock
        self.atBottom = atBottom
        self.embedded = embedded
    }

    /// Hoehe der Leiste (12.11.2026: "den Pencil-Kit-Strich kleiner", vorher 52 pt): so hoch wie die kleinste
    /// Trefferflaeche (44 pt), Symbole 16 pt
    static let height: CGFloat = 44
    /// Trefferflaeche je Knopf (Breite und Hoehe), Bedienungshilfen: mindestens 44 pt
    static let hitSide: CGFloat = 44

    var body: some View {
        HStack(spacing: 2) {
            if embedded {
                // so breit wie noetig: alle Werkzeuge, sonst Objektwerkzeuge in einem Knopf, sonst schieben (nie umbrechen)
                ViewThatFits(in: .horizontal) {
                    toolRow(collapsed: false).fixedSize()
                    toolRow(collapsed: true).fixedSize()
                    ScrollView(.horizontal, showsIndicators: false) { toolRow(collapsed: true) }
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                        .frame(minWidth: Self.hitSide * 2)              // mindestens zwei Stifte zu sehen
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) { toolRow(collapsed: false) }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            divider
            attributesButton
            divider
            if let askAI {
                Button(action: askAI) { icon("sparkles") }
                    .buttonStyle(EditorToolButtonStyle(selected: false))
                    .accessibilityLabel("KI fragen")
                    .accessibilityIdentifier("toolbar.askAI")
                    .help("KI fragen (markierter Text geht mit)")
            } else if let askAILock {
                UFLockedButton(plan: askAILock, title: "KI fragen", identifier: "toolbar.askAI.locked") {
                    Image(systemName: "sparkles").font(.system(size: 16, weight: .medium)).foregroundStyle(UF.text)
                }
                .frame(minHeight: Self.hitSide)
                .padding(.horizontal, 4)
            }
            Button(action: undo) { icon("arrow.uturn.backward") }
                .buttonStyle(EditorToolButtonStyle(selected: false))
                .accessibilityLabel("Rückgängig")
                .accessibilityIdentifier("toolbar.undo")
                .modifier(MacShortcut(key: "z", modifiers: .command))
            Button(action: redo) { icon("arrow.uturn.forward") }
                .buttonStyle(EditorToolButtonStyle(selected: false))
                .accessibilityLabel("Wiederholen")
                .accessibilityIdentifier("toolbar.redo")
                .modifier(MacShortcut(key: "z", modifiers: [.command, .shift]))
                .padding(.trailing, embedded ? 0 : 6)
        }
        .frame(height: Self.height)
        .modifier(EditorBarSurface(embedded: embedded, atBottom: atBottom))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Werkzeuge")
        .accessibilityIdentifier("editor.toolbar")
        .onChange(of: tools.attributesRequest) { _, _ in
            if tools.styledTool.hasColor || !tools.styledTool.widths.isEmpty { attributesOpen = true }
        }
    }

    private var divider: some View { UF.line.frame(width: 1, height: 22).padding(.horizontal, 3) }

    /// Werkzeuge der Zeichenflaeche, Lineal und (ausser im Korrektur-Modus) die Objektwerkzeuge, einzeln oder in einem Knopf
    private func toolRow(collapsed: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(EditorToolState.Tool.canvasTools) { toolButton($0) }
            PenPresetChips(tools: tools, onPick: onPick)                    // eigene Stifte (14.11.2026)
            rulerButton
            if !mode.inkOnly {
                divider
                if collapsed {
                    objectsMenu
                } else {
                    ForEach(EditorToolState.Tool.objectTools) { toolButton($0) }
                }
            }
        }
        .padding(.horizontal, embedded ? 2 : 6)
    }

    /// Schmale Kopfzeile: die seltener gebrauchten Objektwerkzeuge (Bereich an KI, Auswaehlen, Text, Haftnotiz, Form,
    /// Text markieren) in einem Knopf; er zeigt das gewaehlte bzw. zuletzt benutzte Objektwerkzeug
    private var objectsMenu: some View {
        let objectSelected = !tools.tool.drawsOnCanvas
        let shown = objectSelected ? tools.tool : EditorToolState.Tool.select
        return Menu {
            ForEach(EditorToolState.Tool.objectTools) { t in
                Button {
                    onPick(t)
                    tools.select(t)
                } label: {
                    Label(t.title, systemImage: tools.tool == t ? "checkmark" : t.icon)
                }
                .accessibilityIdentifier("toolbar.objects.\(t.rawValue)")
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: shown.icon).font(.system(size: 16, weight: .medium))
                    .frame(width: Self.hitSide, height: Self.hitSide)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .heavy)).offset(x: -7, y: -9)
            }
            .foregroundStyle(objectSelected ? UF.accentText : UF.text)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(objectSelected ? UF.accentSoft : .clear)
                .padding(.horizontal, 4).padding(.vertical, 6))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(objectSelected ? "Objektwerkzeuge: \(tools.tool.title)" : "Objektwerkzeuge")
        .accessibilityAddTraits(objectSelected ? .isSelected : [])
        .accessibilityIdentifier("toolbar.objects")
        .help("Objektwerkzeuge")
    }

    /// Symbol eines Knopfs: 16 pt, Flaeche 44 x 44 pt (die Markierung des gewaehlten Werkzeugs zeichnet der Stil kleiner)
    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .medium)).frame(width: Self.hitSide, height: Self.hitSide)
    }

    /// Werkzeug: Symbol, bei Stiften ein Farbpunkt darunter; zweites Tippen oeffnet seine Einstellungen
    private func toolButton(_ t: EditorToolState.Tool) -> some View {
        let selected = tools.tool == t
        return Button {
            if selected {
                if t.hasColor || !t.widths.isEmpty { attributesOpen = true } else if hasOptions(t) { optionsFor = t }
            } else {
                onPick(t)
                tools.select(t)
            }
        } label: {
            ZStack(alignment: .bottom) {
                icon(t.icon)
                if t.isInk {
                    Circle().fill(color(tools.style(t).hex)).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(UF.lineStrong, lineWidth: 0.5))
                        .offset(y: -4)
                }
            }
        }
        .buttonStyle(EditorToolButtonStyle(selected: selected))
        .ufPopover(isPresented: Binding(get: { optionsFor == t }, set: { if !$0 { optionsFor = nil } })) {
            EditorToolOptions(tools: tools, tool: t) { optionsFor = nil }.padding(16)
        }
        .contextMenu { if hasOptions(t) { optionMenu(t) } }
        .accessibilityLabel(t.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("toolbar.tool.\(t.rawValue)")
        .help(t.title)
    }

    private func hasOptions(_ t: EditorToolState.Tool) -> Bool { t == .eraser || t == .shape || t == .select }

    @ViewBuilder private func optionMenu(_ t: EditorToolState.Tool) -> some View {
        switch t {
        case .eraser:
            ForEach(EditorToolState.EraserKind.allCases) { k in Button(k.title) { tools.setEraser(k) } }
        case .shape:
            ForEach(EditorPalette.shapeChoices, id: \.self) { s in Button { tools.setShape(s) } label: { Label(s.label, systemImage: s.systemImage) } }
        case .select:
            ForEach(EditorPalette.selectChoices, id: \.self) { s in Button { tools.setSelectMode(s) } label: { Label(s.label, systemImage: s.systemImage) } }
        default:
            EmptyView()
        }
    }

    private var rulerButton: some View {
        Button { tools.toggleRuler() } label: { icon("ruler") }
            .buttonStyle(EditorToolButtonStyle(selected: tools.ruler))
            .accessibilityLabel("Lineal")
            .accessibilityValue(tools.ruler ? "an" : "aus")
            .accessibilityIdentifier("toolbar.ruler")
            .help("Lineal")
    }

    /// Farbe und Staerke des gewaehlten Werkzeugs (bzw. Radierer-, Form- und Auswahlart)
    private var attributesButton: some View {
        let t = tools.styledTool
        let s = tools.style(t)
        return Button {
            if t.hasColor || !t.widths.isEmpty { attributesOpen = true } else if hasOptions(tools.tool) { optionsFor = tools.tool }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color(s.hex)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(UF.lineStrong, lineWidth: 1))
                if !t.widths.isEmpty {
                    Capsule().fill(UF.text).frame(width: 16, height: min(8, max(1.5, s.width * (t == .marker ? 0.3 : 0.9))))
                }
            }
            .frame(minWidth: Self.hitSide, minHeight: Self.hitSide)
            .padding(.horizontal, 2)
        }
        .buttonStyle(EditorToolButtonStyle(selected: false))
        .ufPopover(isPresented: $attributesOpen) {
            EditorToolAttributes(tools: tools, tool: t)
        }
        .accessibilityLabel("Farbe und Stärke: \(t.title)")
        .accessibilityIdentifier("toolbar.attributes")
        .help("Farbe und Stärke")
    }

    private func color(_ hex: String) -> Color { Color(uiColor: UIColor(hex: hex) ?? .black) }
}

// MARK: - Lage und Schloss (12.11.2026)

/// Platz der Werkzeuge in `DocumentView` (eigener Typ, damit `documentChrome` flach bleibt, `ViewTypeDepthAppTests`):
/// oben bzw. unten die feste Leiste, wenn diese Lage gewaehlt ist. Ohne Schreiben im Tarif (Free, nach dem
/// Herabstufen) statt nichts die Leiste mit Schloss (`EditorLockedToolbar`), bei "Schwebend" oben ein schmaler Hinweis
/// mit Schloss (Apples Palette erscheint ohne Plus nicht). Auftrag des Inhabers 12.11.2026: gesperrt heisst sichtbar
/// mit Schloss.
struct EditorToolbarSlot: View {
    enum Edge { case top, bottom }

    let edge: Edge
    let placement: EditorToolbarPlacement
    /// Leiste mit Werkzeugen; nil, solange nicht geschrieben werden kann
    let toolbar: EditorToolbar?
    /// Schreiben im Tarif gesperrt: Tarif, der es freischaltet (nil = kein Schloss)
    let lockedPlan: UFPlan?
    /// "KI fragen" gesperrt (ohne KI, ohne Pro AI)
    let askAILock: UFPlan?

    var body: some View {
        switch (edge, placement) {
        case (.top, .top), (.bottom, .bottom):
            if let toolbar {
                toolbar
            } else if let lockedPlan {
                EditorLockedToolbar(plan: lockedPlan, askAILock: askAILock, atBottom: edge == .bottom)
            }
        case (.top, .floating):
            if toolbar == nil, let lockedPlan { EditorFloatingLockHint(plan: lockedPlan) }
        default:
            EmptyView()
        }
    }
}

/// Werkzeugleiste ohne Schreiben im Tarif: dieselben Werkzeuge gedimmt, Schloss "ab Plus" und "Schreiben mit Plus";
/// Antippen oeffnet die Tarifwahl mit Plus. Notizen bleiben lesbar und exportierbar (Herabstufen loescht nichts).
struct EditorLockedToolbar: View {
    let plan: UFPlan
    var askAILock: UFPlan?
    var atBottom = false
    /// in der einen Kopfzeile ("Oben fest"): ohne eigene Flaeche und Linie
    var embedded = false
    @State private var sheet: UFPlan?

    /// "Schreiben mit Plus"
    static func title(_ p: UFPlan) -> String { "Schreiben mit \(UFLock.short(p))" }

    var body: some View {
        HStack(spacing: 2) {
            Button { sheet = plan } label: {
                HStack(spacing: 8) {
                    // so viele Werkzeuge, wie in die Breite passen (schmale geteilte Ansicht: nur der Hinweis)
                    ViewThatFits(in: .horizontal) {
                        icons(EditorToolState.Tool.canvasTools + EditorToolState.Tool.objectTools)
                        icons(EditorToolState.Tool.canvasTools)
                        Color.clear.frame(width: 1, height: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(Self.title(plan)).ufFont(13.6, 600).foregroundStyle(UF.text).lineLimit(1).fixedSize()
                        UFLockMark(plan)
                    }
                    .padding(.trailing, 8)
                }
                .frame(minHeight: EditorToolbar.hitSide)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(UFLock.label(Self.title(plan), plan))
            .accessibilityLabel(Self.title(plan))
            .ufLockAccessibility(plan)
            .accessibilityIdentifier("editor.toolbar.locked")
            if let askAILock {
                UF.line.frame(width: 1, height: 22).padding(.horizontal, 3)
                UFLockedButton(plan: askAILock, title: "KI fragen", identifier: "toolbar.askAI.locked") {
                    Image(systemName: "sparkles").font(.system(size: 16, weight: .medium)).foregroundStyle(UF.text)
                }
                .frame(minHeight: EditorToolbar.hitSide)
                .padding(.trailing, 8)
            }
        }
        .padding(.leading, 6)
        .frame(height: EditorToolbar.height)
        .modifier(EditorBarSurface(embedded: embedded, atBottom: atBottom))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Werkzeuge")
        .accessibilityIdentifier("editor.toolbar")
        .ufPlanSheet($sheet)
    }

    private func icons(_ tools: [EditorToolState.Tool]) -> some View {
        HStack(spacing: 0) {
            ForEach(tools) { t in
                Image(systemName: t.icon).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(UF.muted)
                    .frame(width: EditorToolbar.hitSide, height: EditorToolbar.hitSide)
            }
        }
        .opacity(0.55)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// "Schwebend" ohne Schreiben im Tarif: statt Apples Palette ein schmaler Hinweis mit Schloss oben im Dokument
struct EditorFloatingLockHint: View {
    let plan: UFPlan
    @State private var sheet: UFPlan?

    var body: some View {
        Button { sheet = plan } label: {
            HStack(spacing: 8) {
                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 15, weight: .medium)).foregroundStyle(UF.muted)
                Text(EditorLockedToolbar.title(plan)).ufFont(13.6, 600).foregroundStyle(UF.text).lineLimit(1)
                UFLockMark(plan)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: EditorToolbar.hitSide)
            .background(Capsule().fill(UF.surface))
            .overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(EditorLockedToolbar.title(plan))
        .ufLockAccessibility(plan)
        .accessibilityIdentifier("editor.palette.locked")
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .ufPlanSheet($sheet)
    }
}

/// Flaeche der Leiste: eigene volle Breite mit Linie, in der Kopfzeile nichts davon (die Zeile hat beides)
private struct EditorBarSurface: ViewModifier {
    let embedded: Bool
    let atBottom: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .frame(maxWidth: .infinity)
                .background(UF.surface)
                .overlay(alignment: atBottom ? .top : .bottom) { UF.line.frame(height: 1) }
        }
    }
}

/// Tastenkuerzel nur am Mac (am iPad gehoert Cmd-Z dem Verlauf der Responder-Kette)

private struct MacShortcut: ViewModifier {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    @ViewBuilder func body(content: Content) -> some View {
        if PDFEditorController.isMac { content.keyboardShortcut(key, modifiers: modifiers) } else { content }
    }
}

/// Knopf der Leiste: gewaehlt in der Akzentfarbe der App (Markierung 36 x 32 pt in der 44-pt-Flaeche)
struct EditorToolButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? UF.accentText : UF.text)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(selected ? UF.accentSoft : (configuration.isPressed ? UF.surface2 : .clear))
                .padding(.horizontal, 4).padding(.vertical, 6))

            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// Farben (Auswahl und Farbwaehler) und Staerken eines Werkzeugs; bei Stiften "Einstellungen …" mit stufenloser
/// Staerke, Deckkraft, Glaettung und eigenen Stiften (`PenSettingsPanel`, im selben Feld statt eines zweiten Blatts)
struct EditorToolAttributes: View {
    @ObservedObject var tools: EditorToolState
    let tool: EditorToolState.Tool
    @State private var details = false

    var body: some View {
        if details, tool.isInk {
            PenSettingsPanel(tools: tools, tool: tools.styledTool.isInk ? tools.styledTool : tool) { details = false }
                .presentationCompactAdaptation(.popover)
        } else {
            quick
        }
    }

    private var quick: some View {
        let s = tools.style(tool)
        return VStack(alignment: .leading, spacing: 14) {
            Text(tool.title).ufFont(13.6, 650).foregroundStyle(UF.text)
            if tool.hasColor {
                HStack(spacing: 10) {
                    ForEach(EditorToolState.colors(for: tool), id: \.hex) { c in
                        Button { tools.setColor(c.hex, for: tool) } label: {
                            Circle().fill(Color(uiColor: UIColor(hex: c.hex) ?? .black)).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(PaletteSync.sameColor(c.hex, s.hex) ? UF.accent : UF.lineStrong,
                                                         lineWidth: PaletteSync.sameColor(c.hex, s.hex) ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.name)
                        .accessibilityAddTraits(PaletteSync.sameColor(c.hex, s.hex) ? .isSelected : [])
                        .accessibilityIdentifier("toolbar.color.\(c.hex)")
                    }
                    ColorPicker("Weitere Farbe", selection: Binding(
                        get: { Color(uiColor: UIColor(hex: s.hex) ?? .black) },
                        set: { tools.setColor(UIColor($0).uniflowRGBA.hex, for: tool) }), supportsOpacity: false)
                        .labelsHidden()
                        .accessibilityIdentifier("toolbar.colorPicker")
                }
            }
            if !tool.widths.isEmpty {
                HStack(spacing: 8) {
                    ForEach(tool.widths, id: \.self) { w in
                        Button { tools.setWidth(w, for: tool) } label: {
                            Capsule().fill(UF.text).frame(width: 26, height: Self.lineHeight(w, tool: tool))
                                .frame(width: 44, height: 36)
                                .background(RoundedRectangle(cornerRadius: UF.rSm).fill(abs(s.width - w) < 0.005 ? UF.accentSoft : UF.surface2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stärke \(tool.widths.firstIndex(of: w).map { $0 + 1 } ?? 0) von \(tool.widths.count)")
                        .accessibilityAddTraits(s.width == w ? .isSelected : [])
                        .accessibilityIdentifier("toolbar.width.\(tool.widths.firstIndex(of: w) ?? 0)")
                    }
                }
            }
            if tool == .shape || tool == .eraser || tool == .select {
                EditorToolOptions(tools: tools, tool: tool) {}
            }
            if tool.isInk {
                Button { details = true } label: {
                    HStack {
                        Text(PenSettingsText.open).ufFont(13.6, 600)
                        Spacer()
                        Text("\(PenSettingsText.width(s.width)) · \(Int((s.alpha * 100).rounded())) %").ufFont(12.8).foregroundStyle(UF.muted)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(UF.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(UF.accentText)
                .accessibilityIdentifier("toolbar.penSettings")
            }
        }
        .padding(16)
        .frame(minWidth: 260)
        .presentationCompactAdaptation(.popover)
    }

    /// Hoehe des Strichs in der Auswahl (Textmarker breiter gezeichnet, dafuer gedaempft)
    static func lineHeight(_ w: CGFloat, tool: EditorToolState.Tool) -> CGFloat {
        min(14, max(1.5, tool == .marker ? w * 0.45 : w * 1.1))
    }
}

/// Art des Radierers, der Form bzw. des Auswaehlens
struct EditorToolOptions: View {
    @ObservedObject var tools: EditorToolState
    let tool: EditorToolState.Tool
    let done: () -> Void

    var body: some View {
        Group {
            switch tool {
            case .eraser:
                Picker("Radierer", selection: Binding(get: { tools.eraserKind }, set: { tools.setEraser($0); done() })) {
                    ForEach(EditorToolState.EraserKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("toolbar.eraserKind")
            case .shape:
                Picker("Form", selection: Binding(get: { EditorPalette.shapeTool }, set: { tools.setShape($0); done() })) {
                    ForEach(EditorPalette.shapeChoices, id: \.self) { Image(systemName: $0.systemImage).accessibilityLabel($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("toolbar.shapeKind")
            case .select:
                Picker("Auswählen", selection: Binding(get: { EditorPalette.selectTool }, set: { tools.setSelectMode($0); done() })) {
                    ForEach(EditorPalette.selectChoices, id: \.self) { Image(systemName: $0.systemImage).accessibilityLabel($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("toolbar.selectKind")
            default:
                EmptyView()
            }
        }
        .frame(minWidth: 220)
        .presentationCompactAdaptation(.popover)
    }
}
