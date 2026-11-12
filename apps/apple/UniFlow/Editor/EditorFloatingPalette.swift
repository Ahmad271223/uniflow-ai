import PencilKit
import UIKit
import UniFlowCore

// Lage der Werkzeuge im Dokument (Auftrag des Inhabers 12.11.2026): "mach wie gesagt den Pencil-Kit-Strich kleiner und
// fest oben oder unten, man kann aussuchen, oder weiterhin schwebend, in Einstellung".
//
// - Oben fest (Vorgabe) und Unten fest: unsere Leiste `EditorToolbar` (seit 11.11.2026), kompakt.
// - Schwebend: Apples Werkzeugpalette (`PKToolPicker`) wie bis 11.11.2026, mit unseren Objektwerkzeugen als eigene
//   Eintraege ab iPadOS 18 und "KI fragen" am Rand. Die Palette ist nur eine andere Ansicht derselben Werkzeuge: sie
//   meldet jede Wahl an `EditorToolState`, von dort gehen Werkzeug, Farbe und Objektmodus wie bei der festen Leiste an
//   die Editoren (Rueckgaengig, Lineal, Apple Pencil, geteilte Ansicht bleiben gleich). Am Mac gibt es Apples Palette
//   nicht; dort gilt "Schwebend" wie "Oben fest" und wird nicht angeboten.
//
// Die Wahl gilt je Geraet (UserDefaults `uniflow.toolbarPlacement`) und wirkt sofort im offenen Dokument.

enum EditorToolbarPlacement: String, CaseIterable, Identifiable {
    case top, bottom, floating

    var id: String { rawValue }

    static let key = "uniflow.toolbarPlacement"
    static let standard: EditorToolbarPlacement = .top

    var title: String {
        switch self {
        case .top: return "Oben fest"
        case .bottom: return "Unten fest"
        case .floating: return "Schwebend"
        }
    }

    var detail: String {
        switch self {
        case .top: return "Eine Zeile ganz oben mit Reitern und Werkzeugen, darunter nur das Dokument"
        case .bottom: return "Leiste am unteren Rand, nah an der Schreibhand"
        case .floating: return "Apples Werkzeugpalette, frei verschiebbar"
        }
    }

    var icon: String {
        switch self {
        case .top: return "rectangle.topthird.inset.filled"
        case .bottom: return "rectangle.bottomthird.inset.filled"
        case .floating: return "pencil.tip.crop.circle"
        }
    }

    /// Angebotene Wahl: am Mac ohne "Schwebend" (Apples Palette erscheint dort nicht)
    static func choices(isMac: Bool) -> [EditorToolbarPlacement] { isMac ? [.top, .bottom] : allCases }

    /// Gespeicherter Wert, am Mac "Schwebend" als "Oben fest"; Unbekanntes als Vorgabe
    static func resolve(_ raw: String?, isMac: Bool) -> EditorToolbarPlacement {
        let p = raw.flatMap(EditorToolbarPlacement.init(rawValue:)) ?? standard
        return isMac && p == .floating ? .top : p
    }

    @MainActor
    static func current(_ d: UserDefaults = .standard) -> EditorToolbarPlacement {
        resolve(d.string(forKey: key), isMac: PDFEditorController.isMac)
    }
}

/// Apples schwebende Werkzeugpalette als zweite Ansicht von `EditorToolState` ("Schwebend").
@MainActor
final class EditorFloatingPalette: NSObject, PKToolPickerObserver {
    let picker: PKToolPicker
    private let tools: EditorToolState
    /// Wahl wird gerade von uns gesetzt (keine Rueckmeldung an uns selbst)
    private var applying = false
    /// Werkzeug genau so, wie es in der Palette steht (Apples weitere Stifte wie Bleistift oder Fueller, Staerke des
    /// Radierers); nil, wenn die Wahl von der Leiste bzw. Tastatur kam
    private(set) var appleTool: PKTool?
    /// "KI fragen" am Rand der Palette (ab iPadOS 18, nur mit verbundener KI)
    var onAskAI: (() -> Void)?
    /// Palette verschwand (z. B. Fokus weg): der Editor holt sie mit dem passenden Ereignis zurueck
    var onHidden: (() -> Void)?
    /// Erstantwortgeber, fuer die die Palette gerade gezeigt wird
    private var responders: [ObjectIdentifier: WeakResponder] = [:]

    private final class WeakResponder { weak var value: UIResponder?; init(_ r: UIResponder) { value = r } }

    init(tools: EditorToolState) {
        self.tools = tools
        picker = Self.makePicker()
        super.init()
        picker.addObserver(self)
        picker.colorUserInterfaceStyle = .light            // Farben wie auf dem hellen Papier
        reflect()
    }

    /// Eigene Eintraege moeglich (iPadOS 18)
    static var supportsCustomItems: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// Palette mit Apples Werkzeugen und, ab iPadOS 18, unseren Objektwerkzeugen; ohne Apples Schalter "Mit dem Finger
    /// zeichnen" (unser Schalter "Nur Stift" gilt, `EditorPalette`)
    static func makePicker() -> PKToolPicker {
        let picker: PKToolPicker
        if #available(iOS 18.0, *) {
            picker = PKToolPicker(toolItems: orderedItems(apple: PKToolPicker().toolItems, ours: customItems()))
        } else {
            picker = PKToolPicker()
        }
        picker.showsDrawingPolicyControls = false
        return picker
    }

    // MARK: Sichtbarkeit

    /// Palette fuer den Anker (und die Zeichenflaechen, die beim Schreiben den Fokus nehmen) zeigen bzw. verbergen
    func setVisible(_ visible: Bool, for responders: [UIResponder]) {
        for r in responders {
            picker.setVisible(visible, forFirstResponder: r)
            if visible { self.responders[ObjectIdentifier(r)] = WeakResponder(r) }
        }
        if !visible {
            for r in self.responders.values.compactMap(\.value) { picker.setVisible(false, forFirstResponder: r) }
            self.responders = [:]
        }
    }

    var isVisible: Bool { picker.isVisible }

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        if !toolPicker.isVisible { onHidden?() }
    }

    // MARK: "KI fragen" (ab iPadOS 18)

    static let accessoryTitle = "KI fragen"

    func updateAccessory(aiAvailable: Bool) {
        guard #available(iOS 18.0, *) else { return }
        guard aiAvailable else { picker.accessoryItem = nil; return }
        if picker.accessoryItem == nil {
            let item = UIBarButtonItem(title: Self.accessoryTitle, image: UIImage(systemName: "sparkles"),
                                       primaryAction: UIAction { [weak self] _ in self?.onAskAI?() })
            item.accessibilityLabel = Self.accessoryTitle
            item.accessibilityIdentifier = "palette.askAI"
            picker.accessoryItem = item
        }
    }

    // MARK: Leiste -> Palette

    /// Eintrag der Palette zum Werkzeug der Leiste
    static func identifier(for t: EditorToolState.Tool) -> String {
        switch t {
        case .pen: return "com.apple.ink.pen"
        case .fineliner: return "com.apple.ink.monoline"
        case .marker: return "com.apple.ink.marker"
        case .eraser: return "com.apple.tool.eraser"
        case .lasso: return "com.apple.tool.lasso"
        default: return t.paletteID ?? "com.apple.ink.pen"
        }
    }

    /// Wahl der Leiste (Tastatur, Apple Pencil, "Fertig") in der Palette zeigen
    func reflect() {
        applying = true
        defer { applying = false }
        appleTool = nil
        if picker.isRulerActive != tools.ruler { picker.isRulerActive = tools.ruler }
        guard #available(iOS 18.0, *) else { return }
        let id = Self.identifier(for: tools.tool)
        if picker.selectedToolItemIdentifier != id, picker.toolItems.contains(where: { $0.identifier == id }) {
            picker.selectedToolItemIdentifier = id
        }
    }

    // MARK: Palette -> Leiste

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) { selectionChanged() }

    @available(iOS 18.0, *)
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) { selectionChanged() }

    func toolPickerIsRulerActiveDidChange(_ toolPicker: PKToolPicker) {
        guard !applying else { return }
        tools.setRuler(toolPicker.isRulerActive)
    }

    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {}

    /// Werkzeug der Leiste zu Apples Werkzeug (Stift, Fineliner, Textmarker; Apples weitere Stifte als Stift)
    static func tool(for ink: PKInkingTool.InkType) -> EditorToolState.Tool {
        switch ink {
        case .monoline: return .fineliner
        case .marker: return .marker
        default: return .pen
        }
    }

    /// Wahl in der Palette an die Leiste: Werkzeug, Farbe und Staerke (still, das Werkzeug selbst meldet sich)
    func selectionChanged() {
        guard !applying else { return }
        if #available(iOS 18.0, *), let custom = picker.selectedToolItem as? PKToolPickerCustomItem,
           let t = EditorToolState.Tool.allCases.first(where: { $0.paletteID == custom.identifier }) {
            appleTool = nil
            if t == .text || t == .shape {
                var s = tools.style(t)
                s.hex = custom.color.uniflowRGBA.hex
                if t == .shape, custom.width > 0 { s.width = custom.width }
                tools.setStyle(s, for: t, silently: true)
            }
            choose(t)
            return
        }
        let selected = picker.selectedTool
        switch selected {
        case let ink as PKInkingTool:
            let t = Self.tool(for: ink.inkType)
            tools.setStyle(EditorToolState.Style(hex: ink.color.uniflowRGBA.hex, width: ink.width), for: t, silently: true)
            appleTool = ink
            choose(t)
        case let eraser as PKEraserTool:
            appleTool = eraser
            applying = true
            tools.setEraser(eraser.eraserType == .bitmap ? .pixel : .object)
            applying = false
        case is PKLassoTool:
            appleTool = nil
            choose(.lasso)
        default:
            break
        }
    }

    private func choose(_ t: EditorToolState.Tool) {
        applying = true
        tools.select(t)
        applying = false
    }

    /// Wahl kam aus der Palette selbst (der Editor spiegelt sie dann nicht zurueck)
    var isApplying: Bool { applying }

    // MARK: Eigene Eintraege (ab iPadOS 18)

    /// Apples Werkzeuge vor unseren Eintraegen (die fuenf, die man beim Schreiben staendig braucht)
    static let appleFirstIDs = ["com.apple.ink.pen", "com.apple.ink.monoline", "com.apple.ink.marker", "com.apple.tool.eraser",
                                "com.apple.tool.lasso"]

    /// Reihenfolge: Apples fuenf Hauptwerkzeuge, unsere Eintraege, dann Lineal und Apples weitere Stifte (Geraetetest
    /// 03.11.2026: ganz am Ende fand sie niemand)
    @available(iOS 18.0, *)
    static func orderedItems(apple: [PKToolPickerItem], ours: [PKToolPickerItem]) -> [PKToolPickerItem] {
        let first = apple.filter { appleFirstIDs.contains($0.identifier) }
        let rest = apple.filter { !appleFirstIDs.contains($0.identifier) }
        return first + ours + rest
    }

    @available(iOS 18.0, *)
    static func customItems() -> [PKToolPickerCustomItem] {
        func item(_ t: EditorToolState.Tool, color: UIColor? = nil, widths: [CGFloat] = []) -> PKToolPickerCustomItem? {
            guard let id = t.paletteID else { return nil }
            var c = PKToolPickerCustomItem.Configuration(identifier: id, name: t.title)
            c.imageProvider = { it in
                toolImage(symbol: t.icon, color: color == nil ? nil : it.color, name: t.title, badge: t == .area ? "sparkles" : nil)
            }
            if let color {
                c.allowsColorSelection = true
                c.defaultColor = color
            }
            if widths.count > 1 {
                c.defaultWidth = widths[widths.count / 2]
                c.widthVariants = Dictionary(uniqueKeysWithValues: widths.map { ($0, widthImage($0)) })
                c.toolAttributeControls = [.width]
            } else {
                c.toolAttributeControls = []
            }
            return PKToolPickerCustomItem(configuration: c)
        }
        let all: [EditorToolState.Tool: PKToolPickerCustomItem?] = [
            .shape: item(.shape, color: UIColor(hex: "#e5322d"), widths: EditorToolState.Tool.shape.widths),
            .text: item(.text, color: UIColor(hex: "#1d2130")),
            .sticky: item(.sticky),
            .select: item(.select),
            .markup: item(.markup),
            .area: item(.area),
        ]
        // Reihenfolge wie die Leiste: "Bereich an KI" vorn (Wunsch des Inhabers)
        return EditorToolState.Tool.objectTools.compactMap { all[$0] ?? nil }
    }

    /// Bild eines Eintrags: wie ein Stift der Palette (PencilKit zeigt den oberen Teil), Symbol oben, bei Werkzeugen mit
    /// Farbe in dieser Farbe
    static func toolImage(symbol: String, color: UIColor?, name: String, badge: String? = nil) -> UIImage {
        let size = CGSize(width: 44, height: 150)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            let body = UIBezierPath(roundedRect: CGRect(x: 8, y: 6, width: 28, height: 160), cornerRadius: 9)
            UIColor(white: 0.97, alpha: 1).setFill()
            body.fill()
            UIColor(white: 0.6, alpha: 1).setStroke()
            body.lineWidth = 1.2
            body.stroke()
            let cfg = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
            if let s = UIImage(systemName: symbol, withConfiguration: cfg)?
                .withTintColor(color ?? UIColor(white: 0.2, alpha: 1), renderingMode: .alwaysOriginal) {
                s.draw(in: CGRect(x: (size.width - s.size.width) / 2, y: 18, width: s.size.width, height: s.size.height))
            }
            if let badge, let b = UIImage(systemName: badge, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))?
                .withTintColor(.systemPurple, renderingMode: .alwaysOriginal) {
                b.draw(in: CGRect(x: size.width - 12 - b.size.width / 2, y: 38, width: b.size.width, height: b.size.height))
            }
        }
        img.accessibilityLabel = name
        return img
    }

    static func widthImage(_ w: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 6, y: 16))
            p.addLine(to: CGPoint(x: 26, y: 16))
            p.lineWidth = w * 1.5
            p.lineCapStyle = .round
            UIColor.label.setStroke()
            p.stroke()
        }
    }
}
