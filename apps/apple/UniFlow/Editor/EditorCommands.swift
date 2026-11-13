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

    /// Werkzeug der Zeichenflaeche (PencilKit)
    var isInk: Bool { [.pen, .marker, .eraser, .lasso].contains(self) }

    /// Eintrag der festen Leiste
    var barTool: EditorToolState.Tool {
        switch self {
        case .pen: return .pen
        case .marker: return .marker
        case .eraser: return .eraser
        case .lasso: return .lasso
        case .text: return .text
        case .sticky: return .sticky
        case .shape: return .shape
        case .select: return .select
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
    /// Werkzeug aus Menue oder Tastatur ueber die feste Leiste (sie zeigt die Wahl). Nur, wenn geschrieben werden darf;
    /// im Korrektur-Modus nur Werkzeuge der Zeichenflaeche.
    func choose(_ tool: EditorTool) {
        guard writable || (correction != nil && tool.isInk) else { return }
        if correction != nil, !tool.isInk { return }
        if tool == .select { EditorPalette.selectTool = .select }
        tools.select(tool.barTool)
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
        switch tools.tool {
        case .pen, .fineliner: return .pen
        case .marker: return .marker
        case .eraser: return .eraser
        case .lasso: return .lasso
        default: return nil
        }
    }
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
                Divider()
                Button("Lineal") { bridge?.controller?.tools.toggleRuler() }
                if PDFEditorController.isMac {
                    // dieselben Farben und Staerken wie in der festen Leiste (fuer das gewaehlte Werkzeug)
                    Menu("Farbe") {
                        ForEach(EditorToolState.menuColors, id: \.hex) { c in
                            Button(c.name) { bridge?.controller?.tools.setColor(c.hex) }
                        }
                    }
                    Menu("Strichstärke") {
                        ForEach(Array(EditorToolState.widthSteps.enumerated()), id: \.offset) { i, name in
                            Button(name) { bridge?.controller?.tools.setWidthStep(i) }
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
