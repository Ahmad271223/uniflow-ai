import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// Dateien von aussen (07.11.2026, docs: `ExternalFileImport`): der Dialog "In welches Modul?" nach "Teilen" ->
// StudiNow bzw. nach dem Ablegen einer ZIP, und das Drop-Ziel der Bibliothek fuer PDF und ZIP aus der Dateien-App.

/// Dialog fuer eine PDF oder ZIP von aussen: Titel aenderbar, Modul waehlen (wie bei Notizbuch und PDF-Import), danach
/// oeffnet sich das Dokument (ZIP als Ordner, PDF im Editor). Abbrechen entfernt die Kopie.
struct ExternalImportDialog: View {
    let staged: ExternalFileImport.Staged
    /// vorbelegtes Modul (Ablegen im Modulordner)
    var moduleID: Int? = nil
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var title = ""
    @State private var module = 0
    @State private var modules: [(value: Int, label: String)] = []
    @State private var busy = false

    var body: some View {
        UFDialog("\(staged.kind.label) importieren", icon: staged.kind == .zip ? "folder" : "file-text") {
            UFField("Datei") {
                Text("\(staged.name) · \(ExternalFileImport.megabytes(staged.bytes)) MB").ufFont(14.4).foregroundStyle(UF.text)
                    .accessibilityIdentifier("import.file")
            }
            UFField("Titel") { UFTextInput(text: $title) }
            UFField("In welches Modul?") {
                UFSelect(options: [(value: 0, label: "– keins (Eigene Dokumente) –")] + modules, selection: $module, fill: true)
            }
            Text(staged.kind == .zip
                 ? "Die ZIP-Datei öffnet sich danach als Ordner." + (UFEditorAvailability.available ? " PDFs daraus lassen sich mit dem Stift bearbeiten." : "")
                 : UFEditorAvailability.available ? "Die PDF öffnet sich danach im Editor." : "Die PDF öffnet sich danach zum Lesen.")
                .ufFont(12.8).foregroundStyle(UF.muted)
        } foot: {
            UFButton("Abbrechen") { ExternalFileImport.discard(staged); close() }
            UFButton("Importieren", kind: .primary) { Task { await create() } }.disabled(busy)
        }
        .task {
            if title.isEmpty { title = staged.title }
            module = moduleID ?? 0
            modules = Self.moduleOptions((try? await session.api?.value("/api/library")) ?? .null)
        }
    }

    /// Module der Bibliothek als Auswahl (wie NotebookDialog)
    static func moduleOptions(_ lib: JSONValue) -> [(value: Int, label: String)] {
        lib.list("modules").compactMap { m in m.i("id").map { (value: $0, label: m.s("name") ?? "") } }
    }

    private func create() async {
        guard let api = session.api, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let id = try await ExternalFileImport.create(staged, api: api, title: title, moduleID: module)
            close()
            toast.show("„\(title.isEmpty ? staged.title : title)“ importiert.")
            router.go(.doc(id))
        } catch {
            toast.show("Import fehlgeschlagen: \(ExternalFileImport.message(error))", seconds: 5)
        }
    }
}

/// Ablegen von PDF und ZIP aus der Dateien-App (Drag & Drop, Split View) in "Dokumente & Notizen": PDFs landen gleich im
/// offenen Modul bzw. Ordner (Bilanz wie beim Import ueber "Neu"), eine einzelne ZIP fragt nach dem Modul (vorbelegt mit
/// dem offenen) und oeffnet sich danach als Ordner; mehrere ZIPs landen gleich im offenen Modul.
struct LibraryDropTarget: ViewModifier {
    let moduleID: Int?
    let folderID: Int?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var targeted = false

    static let types: [UTType] = [.pdf, .zip]

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: UF.r)
                        .fill(UF.accentSoft.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                        .overlay(Text("PDF oder ZIP hier ablegen").ufFont(16, 600).foregroundStyle(UF.accentText))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: Self.types, isTargeted: $targeted) { providers in
                let wanted = providers.filter { p in Self.types.contains { p.hasItemConformingToTypeIdentifier($0.identifier) } }
                guard !wanted.isEmpty else { return false }
                Task { await receive(wanted) }
                return true
            }
    }

    /// Art des Anbieters (ZIP vor PDF: eine ZIP meldet nie PDF, eine PDF nie ZIP)
    static func kind(of provider: NSItemProvider) -> (ExternalFileImport.Kind, UTType)? {
        if provider.hasItemConformingToTypeIdentifier(UTType.zip.identifier) { return (.zip, .zip) }
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) { return (.pdf, .pdf) }
        return nil
    }

    /// Datei des Anbieters in den Container kopieren; die Adresse gilt nur innerhalb des Rueckrufs
    static func stage(_ provider: NSItemProvider) async throws -> ExternalFileImport.Staged {
        guard let found = kind(of: provider) else { throw ExternalFileImport.Failure.unsupported(provider.suggestedName ?? "Datei") }
        let (kind, type) = found
        let container = ActiveContainer.current?.layout.identifier
        let name = provider.suggestedName                                  // die Adresse heisst nur "Zip-Archiv.zip"
        return try await withCheckedThrowingContinuation { c in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { return c.resume(throwing: error ?? ExternalFileImport.Failure.unreadable) }
                c.resume(with: Result { try ExternalFileImport.stage(url, kind: kind, name: name, container: container) })
            }
        }
    }

    private func receive(_ providers: [NSItemProvider]) async {
        guard let api = session.api else { return }
        var staged: [ExternalFileImport.Staged] = []
        var failed: [String] = []
        for p in providers {
            do { staged.append(try await Self.stage(p)) } catch { failed.append("\(p.suggestedName ?? "Datei") (\(ExternalFileImport.message(error)))") }
        }
        // eine einzelne ZIP: nach dem Modul fragen und danach oeffnen
        if staged.count == 1, failed.isEmpty, let s = staged.first, s.kind == .zip {
            overlay.modal { ExternalImportDialog(staged: s, moduleID: moduleID) }
            return
        }
        var ok = 0
        var opened: String?
        for s in staged {
            do {
                let id = try await ExternalFileImport.create(s, api: api, moduleID: moduleID, folderID: folderID)
                ok += 1
                if s.kind == .zip && staged.count == 1 { opened = id }
            } catch {
                ExternalFileImport.discard(s)
                failed.append("\(s.name) (\(ExternalFileImport.message(error)))")
            }
        }
        toast.show(LibraryNewDialog.importSummary(ok: ok, failed: failed), seconds: failed.isEmpty ? 2.6 : 6)
        if let opened { router.go(.doc(opened)) } else if ok > 0 { router.reload() }
    }
}
