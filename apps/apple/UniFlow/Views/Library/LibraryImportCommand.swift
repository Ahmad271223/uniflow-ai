import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// Ablage -> "Importieren …" (Mac und iPad mit Tastatur, 12.11.2026): vorher gab es in der Menueleiste keinen Import,
// nur Ziehen aus dem Finder und "Neu" -> "PDF importieren" in der Bibliothek. Die Dateiauswahl (PDF, ZIP, Bilder,
// mehrere) endet im selben Dialog "Wohin?" wie alle anderen Wege, vorgewaehlt der offene Ort der Bibliothek.

/// Import des vorderen Fensters (je Fenster eigene Dateiauswahl und eigener Dialog)
struct LibraryImportAction {
    let run: () -> Void
}

private struct LibraryImportKey: FocusedValueKey {
    typealias Value = LibraryImportAction
}

extension FocusedValues {
    var libraryImport: LibraryImportAction? {
        get { self[LibraryImportKey.self] }
        set { self[LibraryImportKey.self] = newValue }
    }
}

/// Menuepunkt "Importieren …" unter "Neu" im Menue "Ablage"; ausgegraut ohne Konto und Hochschule
struct LibraryImportCommands: Commands {
    @FocusedValue(\.libraryImport) private var action

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Importieren …") { action?.run() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(action == nil)
        }
    }
}

/// Dateiauswahl des Fensters fuer "Importieren …"; danach "Wohin?" mit dem offenen Ort
struct LibraryImportHost: ViewModifier {
    let router: UFRouter
    let overlay: UFOverlay
    let toast: UFToastCenter
    /// Konto und Hochschule gewaehlt (sonst gibt es keine Bibliothek)
    let enabled: Bool
    @State private var picking = false

    static let types: [UTType] = [.pdf, .zip, .image]

    /// Art einer gewaehlten Datei: PDF und ZIP nach der Endung, sonst Bild, wenn die Endung ein Bildtyp ist
    static func kind(of url: URL) -> ExternalFileImport.Kind? {
        if let k = ExternalFileImport.kind(of: url) { return k }
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()), t.conforms(to: .image) else { return nil }
        return .image
    }

    func body(content: Content) -> some View {
        content
            // eigener Ort fuer die Dateiauswahl (wie DocumentView: zwei an derselben Ansicht gingen verloren)
            .background {
                Color.clear.fileImporter(isPresented: $picking, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
                    guard case .success(let urls) = result else { return }
                    Task { await stage(urls) }
                }
            }
            .focusedSceneValue(\.libraryImport, enabled ? LibraryImportAction { picking = true } : nil)
    }

    private func stage(_ urls: [URL]) async {
        var staged: [ExternalFileImport.Staged] = []
        var failed: [String] = []
        for url in urls {
            do {
                guard let kind = Self.kind(of: url) else { throw ExternalFileImport.Failure.unsupported(url.lastPathComponent) }
                staged.append(try await ExternalFileImport.stageDetached(url, kind: kind))
            } catch {
                failed.append("\(url.lastPathComponent) (\(ExternalFileImport.message(error)))")
            }
        }
        if !failed.isEmpty { toast.show(LibraryNewDialog.importSummary(ok: 0, failed: failed), seconds: 6) }
        ExternalImportInbox.receive(staged, overlay: overlay, preset: ExternalImportInbox.preset(for: router.route))
    }
}
