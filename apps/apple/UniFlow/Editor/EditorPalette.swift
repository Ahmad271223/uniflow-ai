import PencilKit
import UIKit
import UniFlowCore

/// Apples Werkzeugpalette (`PKToolPicker`) als einziger Ort fuer alle Werkzeuge (Plan EDITOR-GOODNOTES-PLAN, 03.11.2026).
///
/// - Ab iPadOS 18 stehen unsere Objektwerkzeuge als eigene Eintraege in der Palette (`PKToolPickerCustomItem`): Objekte
///   auswaehlen (Antippen oder Lasso), Text, Haftnotiz, Form (Rechteck, Ellipse, Linie, Pfeil) und Text markieren.
///   Die Palette zeigt nur so viele Werkzeuge, wie in ihre Breite passen (iPad hochkant: sieben), der Rest erst nach
///   waagerechtem Wischen. Darum stehen unsere Eintraege direkt hinter Stift, Fineliner, Textmarker, Radierer und
///   Lasso, vor Lineal und Apples fuenf weiteren Stiften (Geraetetest 03.11.2026: ganz am Ende fand sie niemand; im
///   Simulator nachgestellt, `EditorDeviceProbeTests` zeigt das Bild der Palette). Wer einen davon waehlt, ist im
///   Objektmodus; ein Stift, Radierer oder Lasso von Apple beendet ihn. Unter iPadOS 17, oder wenn die Palette die
///   Eintraege nicht traegt (`hasCustomItems`), bleibt die bisherige Objektleiste mit dem Schalter "Tinte/Objekte".
/// - "Nur Stift / Finger zeichnet" bleibt unser Schalter in der Leiste (Standard: nur der Stift schreibt, der Finger
///   blaettert). Der Schalter der Palette ("Mit dem Finger zeichnen") ist ausgeblendet: Er schreibt die iPadOS-
///   Einstellung `UIPencilInteraction.prefersPencilOnlyDrawing`, die eine App nur lesen kann, und wirkt nur bei der
///   Eingabeart `.default`. Mit `.default` schrieb der Finger am Geraet (Einstellung dort aus), Blaettern ging nicht mehr
///   (Geraetetest 03.11.2026). Zwei Schalter mit verschiedener Bedeutung waeren verwirrend, darum nur unserer.
/// - Objekte uebernehmen Farbe und Staerke aus der Palette; "Text markieren" die Farbe des Textmarkers (`PaletteSync`).
enum EditorPalette {
    static let selectID = "de.studinow.palette.select"
    static let textID = "de.studinow.palette.text"
    static let stickyID = "de.studinow.palette.sticky"
    static let shapeID = "de.studinow.palette.shape"
    static let markupID = "de.studinow.palette.markup"
    /// Reihenfolge in der Palette: Form und Text zuerst (am haeufigsten), dann Haftnotiz, Auswaehlen, Text markieren
    static let customIDs = [shapeID, textID, stickyID, selectID, markupID]

    /// Eigene Eintraege in der Palette moeglich (iPadOS 18)
    static var supportsCustomItems: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// Diese Palette traegt unsere Eintraege wirklich (sonst Objektleiste und "Tinte/Objekte" wie unter iPadOS 17)
    static func hasCustomItems(_ picker: PKToolPicker) -> Bool {
        guard #available(iOS 18.0, *) else { return false }
        let ids = Set(picker.toolItems.map(\.identifier))
        return customIDs.allSatisfy(ids.contains)
    }

    /// Apples Werkzeuge vor unseren Eintraegen (die fuenf, die man beim Schreiben staendig braucht)
    static let appleFirstIDs = ["com.apple.ink.pen", "com.apple.ink.monoline", "com.apple.ink.marker", "com.apple.tool.eraser",
                                "com.apple.tool.lasso"]

    /// Reihenfolge: Apples fuenf Hauptwerkzeuge, unsere Eintraege, dann Lineal und Apples weitere Stifte (alle bleiben)
    @available(iOS 18.0, *)
    static func orderedItems(apple: [PKToolPickerItem], ours: [PKToolPickerItem]) -> [PKToolPickerItem] {
        let first = apple.filter { appleFirstIDs.contains($0.identifier) }
        let rest = apple.filter { !appleFirstIDs.contains($0.identifier) }
        return first + ours + rest
    }

    /// Palette mit Apples Werkzeugen und, ab iPadOS 18, unseren Objektwerkzeugen; ohne den Schalter der Palette fuer
    /// das Zeichnen mit dem Finger (siehe oben)
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

    /// Zustand der Palette fuer Protokolle (Geraete-Probe `EditorDeviceProbeTests`, Startargument `-UFPaletteProbe 1`)
    @MainActor
    static func describe(_ picker: PKToolPicker, editor: PDFEditorController?) -> [String] {
        var lines: [String] = []
        if #available(iOS 18.0, *) {
            lines.append("toolItems (\(picker.toolItems.count)): " + picker.toolItems.map { "\(type(of: $0)):\($0.identifier)" }.joined(separator: ", "))
            lines.append("selected: \(picker.selectedToolItemIdentifier)")
            lines.append("hasCustomItems: \(hasCustomItems(picker))")
        } else {
            lines.append("iOS < 18: keine eigenen Eintraege, selectedTool \(picker.selectedTool)")
        }
        lines.append("isVisible: \(picker.isVisible), showsDrawingPolicyControls: \(picker.showsDrawingPolicyControls), stateAutosaveName: \(picker.stateAutosaveName ?? "nil")")
        lines.append("prefersPencilOnlyDrawing (iPadOS-Einstellung): \(UIPencilInteraction.prefersPencilOnlyDrawing)")
        if let editor {
            lines.append("editor: pencilOnly \(editor.pencilOnly), drawingPolicy \(editor.drawingPolicy.rawValue) (0 default, 1 anyInput, 2 pencilOnly), writable \(editor.writable), pickerAllowed \(editor.pickerAllowed), objectMode \(editor.objects.isActive) \(editor.objects.tool.rawValue), blocker \(editor.paletteBlocker)")
            let canvases = editor.allOverlays.map { "p\($0.pageIndex): policy \($0.canvas.drawingPolicy.rawValue), input \($0.canvas.isUserInteractionEnabled), tool \(type(of: $0.canvas.tool))" }
            lines.append("canvas: " + canvases.joined(separator: " | "))
            if let scene = editor.view.window?.windowScene {
                lines.append("windows: " + scene.windows.map { "\(type(of: $0)) hidden=\($0.isHidden) level=\($0.windowLevel.rawValue)" }.joined(separator: ", "))
            }
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
        }
    }

    /// Eine Option der Palette hat sich geaendert (Formart, Auswahlart): der Editor setzt das Werkzeug neu
    static let optionChanged = Notification.Name("uniflow.palette.optionChanged")

    @available(iOS 18.0, *)
    static func customItems() -> [PKToolPickerCustomItem] {
        func item(_ id: String, _ name: String, color: UIColor? = nil, widths: [CGFloat] = [],
                  options: (() -> UIViewController)? = nil) -> PKToolPickerCustomItem {
            var c = PKToolPickerCustomItem.Configuration(identifier: id, name: name)
            c.imageProvider = { it in toolImage(symbol: symbol(for: it.identifier), color: color == nil ? nil : it.color, name: name) }
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
            if let options { c.viewControllerProvider = { _ in options() } }
            return PKToolPickerCustomItem(configuration: c)
        }
        let all: [String: PKToolPickerCustomItem] = [
            shapeID: item(shapeID, "Form", color: UIColor(hex: "#e5322d"), widths: [1, 2, 4],
                          options: { PaletteOptionsController(title: "Form", key: shapeKey, choices: shapeChoices) }),
            textID: item(textID, "Text", color: UIColor(hex: "#1d2130")),
            stickyID: item(stickyID, "Haftnotiz"),
            selectID: item(selectID, "Objekte auswählen", options: { PaletteOptionsController(title: "Auswählen", key: selectKey, choices: selectChoices) }),
            markupID: item(markupID, "Text markieren"),
        ]
        return customIDs.compactMap { all[$0] }
    }

    static func symbol(for identifier: String) -> String {
        switch identifier {
        case selectID: return selectTool.systemImage
        case textID: return "textformat"
        case stickyID: return "note.text"
        case shapeID: return shapeTool.systemImage
        default: return "highlighter"
        }
    }

    /// Bild eines Eintrags: Werkzeug wie ein Stift in der Palette (mindestens 150 pt hoch, PencilKit zeigt den oberen
    /// Teil), heller Koerper mit Kontur wie Apples Stifte, Symbol oben, bei Werkzeugen mit Farbe in dieser Farbe
    /// (im Simulator geprueft: so gezeichnet erscheint der Eintrag wie Apples Werkzeuge)
    static func toolImage(symbol: String, color: UIColor?, name: String) -> UIImage {
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

    // MARK: Palette wieder zeigen

    /// Was die Palette gerade verdeckt halten darf; `none`: sie kann sofort zurueck
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

/// Merkt sich, was die Palette eingestellt hat: letzte Stiftfarbe und -staerke, Farbe des Textmarkers. Objekte nehmen
/// diese Werte; die eigenen Eintraege (Text, Form) uebernehmen beim Wechsel vom Stift dessen Farbe, solange man dort
/// keine eigene Farbe gewaehlt hat.
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

/// Optionen eines eigenen Eintrags im Popover der Palette (Formart, Auswahlart)
final class PaletteOptionsController: UIViewController {
    private let key: String
    private let choices: [ObjectEditing.Tool]

    init(title: String, key: String, choices: [ObjectEditing.Tool]) {
        self.key = key
        self.choices = choices
        super.init(nibName: nil, bundle: nil)
        self.title = title
        preferredContentSize = CGSize(width: 280, height: 56)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let seg = UISegmentedControl(items: choices.map { t -> Any in
            let img = UIImage(systemName: t.systemImage) ?? UIImage()
            img.accessibilityLabel = t.label
            return img
        })
        let current = UserDefaults.standard.string(forKey: key)
        seg.selectedSegmentIndex = choices.firstIndex { $0.rawValue == current } ?? 0
        seg.accessibilityLabel = title
        seg.addAction(UIAction { [weak self, weak seg] _ in
            guard let self, let seg else { return }
            UserDefaults.standard.set(self.choices[seg.selectedSegmentIndex].rawValue, forKey: self.key)
            NotificationCenter.default.post(name: EditorPalette.optionChanged, object: nil)
        }, for: .valueChanged)
        seg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(seg)
        NSLayoutConstraint.activate([
            seg.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            seg.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            seg.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

/// Unsichtbare Markierung in einem Blatt: meldet, wenn das Blatt den Bildschirm verlassen hat (die Palette kommt dann
/// zurueck, ohne in Abstaenden nachzusehen)
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
