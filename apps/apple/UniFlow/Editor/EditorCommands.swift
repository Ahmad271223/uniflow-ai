import PencilKit
import SwiftUI
import UIKit
import UniFlowCore

// Menueleiste, Werkzeug-Tasten, Sichern und Drucken (10.11.2026, docs/EDITOR-VERBESSERUNGEN-2026-11-10.md).
// Die Befehle stehen in der Menueleiste des Mac und, ab iPadOS 26, des iPads mit Tastatur; die Uebersicht beim Halten
// von Cmd zeigt sie ebenso. Sie wirken auf das Dokument des vorderen Fensters (`focusedSceneObject` in DocumentView).

/// Werkzeuge, die sich ueber Menue und Tastatur waehlen lassen
enum EditorTool: String, CaseIterable, Identifiable {
    case pen, marker, eraser, lasso, text, sticky, shape, select

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "Stift"
        case .marker: return "Textmarker"
        case .eraser: return "Radierer"
        case .lasso: return "Lasso"
        case .text: return "Text"
        case .sticky: return "Haftnotiz"
        case .shape: return "Form"
        case .select: return "Objekte auswählen"
        }
    }

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        case .sticky: return "note.text"
        case .shape: return "square.on.circle"
        case .select: return "rectangle.and.hand.point.up.left"
        }
    }

    /// Cmd + Ziffer (Cmd-1 Stift … Cmd-8 Auswaehlen)
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }

    /// Werkzeug von Apple (schreibt auf der Zeichenflaeche)
    var isInk: Bool { [.pen, .marker, .eraser, .lasso].contains(self) }

    /// Kennung des Eintrags von Apple in der Palette (ab iPadOS 18)
    var appleItemID: String? {
        switch self {
        case .pen: return "com.apple.ink.pen"
        case .marker: return "com.apple.ink.marker"
        case .eraser: return "com.apple.tool.eraser"
        case .lasso: return "com.apple.tool.lasso"
        default: return nil
        }
    }

    /// Objektwerkzeug (Text, Haftnotiz, Form, Auswaehlen)
    var objectTool: ObjectEditing.Tool? {
        switch self {
        case .text: return .text
        case .sticky: return .sticky
        case .shape: return EditorPalette.shapeTool
        case .select: return .select
        default: return nil
        }
    }
}

extension PDFEditorController {
    /// Werkzeug aus Menue oder Tastatur waehlen: ab iPadOS 18 ueber die Palette (sie zeigt die Wahl), sonst direkt.
    /// Nur, wenn geschrieben werden darf; im Korrektur-Modus nur Werkzeuge von Apple.
    func choose(_ tool: EditorTool) {
        guard writable || (correction != nil && tool.isInk) else { return }
        if correction != nil, !tool.isInk { return }
        if #available(iOS 18.0, *), toolsInPalette {
            let id: String?
            if let apple = tool.appleItemID {
                id = toolPicker.toolItems.first { $0.identifier == apple }?.identifier
                    ?? toolPicker.toolItems.first { item in
                        guard let ink = item as? PKToolPickerInkingItem else { return false }
                        return tool == .marker ? ink.inkingTool.inkType == .marker : (tool == .pen && ink.inkingTool.inkType == .pen)
                    }?.identifier
            } else if let object = tool.objectTool {
                if tool == .select { EditorPalette.selectTool = .select }
                id = EditorPalette.identifier(for: object)
            } else {
                id = nil
            }
            guard let id, toolPicker.toolItems.contains(where: { $0.identifier == id }) else { return }
            toolPicker.selectedToolItemIdentifier = id
            paletteSelectionChanged()
            return
        }
        // iPadOS 17: Werkzeug von Apple direkt, Objekte ueber den Objektmodus
        if let object = tool.objectTool {
            if !objects.isActive { setObjectMode(true) }
            setObjectTool(object)
            return
        }
        if objects.isActive { setObjectMode(false) }
        let color = UIColor(hex: paletteSync.inkHex) ?? .black
        switch tool {
        case .pen: toolPicker.selectedTool = PKInkingTool(.pen, color: color)
        case .marker: toolPicker.selectedTool = PKInkingTool(.marker, color: .systemYellow)
        case .eraser: toolPicker.selectedTool = PKEraserTool(.vector)
        case .lasso: toolPicker.selectedTool = PKLassoTool()
        default: break
        }
        paletteSelectionChanged()
    }

    /// Name des gewaehlten Werkzeugs (fuer Tests und Hinweise)
    var chosenTool: EditorTool? {
        if objects.isActive {
            switch objects.tool {
            case .text: return .text
            case .sticky: return .sticky
            case .rect, .ellipse, .line, .arrow: return .shape
            case .select, .lasso: return .select
            default: return nil
            }
        }
        switch toolPicker.selectedTool {
        case let ink as PKInkingTool: return ink.inkType == .marker ? .marker : .pen
        case is PKEraserTool: return .eraser
        case is PKLassoTool: return .lasso
        default: return nil
        }
    }
}

// MARK: - Farbe und Staerke am Mac

/// Mac: Apples Werkzeugpalette erscheint dort nicht (gemessen 11.11.2026, macOS 26.6, "Designed for iPad"). Farbe und
/// Staerke fuer Stift und Textmarker kommen deshalb aus dem Menue "Werkzeuge".
struct MacInkStyle: Equatable {
    var color: UIColor?
    var width: CGFloat?

    var isSet: Bool { color != nil || width != nil }

    /// Stift bzw. Textmarker mit dieser Farbe/Staerke (Radierer und Lasso bleiben)
    func apply(to tool: PKTool) -> PKTool {
        guard isSet, let ink = tool as? PKInkingTool else { return tool }
        let base = ink.inkType == .marker ? (color ?? ink.color).withAlphaComponent(1) : (color ?? ink.color)
        let w = width.map { ink.inkType == .marker ? $0 * 4 : $0 } ?? ink.width
        return PKInkingTool(ink.inkType, color: base, width: w)
    }

    static let colors: [(title: String, color: UIColor)] = [
        ("Schwarz", .black), ("Blau", UIColor(red: 0.12, green: 0.35, blue: 0.85, alpha: 1)),
        ("Rot", UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1)), ("Grün", UIColor(red: 0.1, green: 0.55, blue: 0.25, alpha: 1)),
        ("Orange", UIColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1)), ("Gelb", UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)),
    ]
    static let widths: [(title: String, width: CGFloat)] = [("Fein", 1.5), ("Mittel", 3), ("Dick", 6)]
}

// MARK: - Menueleiste

/// Menues "Dokument" und "Werkzeuge" sowie "Sichern" und "Drucken" im Menue "Ablage". Ohne offenes Dokument sind sie
/// ausgegraut.
struct EditorCommands: Commands {
    @FocusedObject private var bridge: EditorBridge?

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Als PDF sichern …") { bridge?.request(.save) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(bridge == nil)
            Button("Teilen …") { bridge?.request(.share) }
                .disabled(bridge == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Drucken …") { bridge?.request(.print) }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(bridge == nil)
        }
        CommandMenu("Dokument") {
            Group {
                Button("Suchen …") { bridge?.request(.search) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Gehe zu Seite …") { bridge?.request(.goToPage) }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                Divider()
                Button("Erste Seite") { bridge?.controller?.perform(.first) }
                Button("Letzte Seite") { bridge?.controller?.perform(.last) }
                Divider()
                Button("Seitenbreite") { bridge?.fitWidth() }
                Divider()
                Button("Bild aus Fotos einfügen …") { bridge?.request(.photo) }
                Button("Bild aus Dateien einfügen …") { bridge?.request(.imageFile) }
                Button("Schreiblupe") { bridge?.request(.magnifier) }
                    .keyboardShortcut("y", modifiers: [.command, .option])
                Divider()
                Button("Präsentieren") { bridge?.request(.present) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("In neuem Fenster öffnen") { bridge?.request(.newWindow) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            .disabled(bridge == nil)
        }
        CommandMenu("Werkzeuge") {
            Group {
                ForEach(EditorTool.allCases) { tool in
                    Button { bridge?.choose(tool) } label: { Label(tool.title, systemImage: tool.icon) }
                        .keyboardShortcut(tool.shortcut, modifiers: .command)
                }
                Divider()
                Button("Objekte fertig") { bridge?.finishObjectTools() }
                if PDFEditorController.isMac {
                    Divider()
                    Menu("Farbe") {
                        ForEach(MacInkStyle.colors, id: \.title) { c in
                            Button(c.title) { bridge?.controller?.macInkStyle.color = c.color }
                        }
                    }
                    Menu("Strichstärke") {
                        ForEach(MacInkStyle.widths, id: \.title) { w in
                            Button(w.title) { bridge?.controller?.macInkStyle.width = w.width }
                        }
                    }
                }
            }
            .disabled(bridge == nil)
        }
    }
}

// MARK: - Sichern und Drucken

/// Ordner waehlen und die PDF dorthin kopieren (iPad: Dateien, Mac: Fenster "Sichern")
struct ExportToFolderView: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done() }
    }
}

/// Drucken der exportierten PDF (Druckdialog des Systems, am Mac der Mac-Druckdialog)
@MainActor
enum PDFPrinting {
    static func printInfo(title: String) -> UIPrintInfo {
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = title
        return info
    }

    static func print(_ url: URL, title: String, done: @escaping (String?) -> Void = { _ in }) {
        let controller = UIPrintInteractionController.shared
        guard UIPrintInteractionController.canPrint(url) else { done("Die PDF lässt sich nicht drucken."); return }
        controller.printInfo = printInfo(title: title)
        controller.printingItem = url
        controller.present(animated: true) { _, _, error in done(error?.localizedDescription) }
    }
}
