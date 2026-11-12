import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// Dateien von aussen (07.11.2026, docs: `ExternalFileImport`): der Dialog "Wohin?" nach "Teilen" -> StudiNow, nach dem
// Ablegen und nach "Neu" -> "PDF importieren", und das Drop-Ziel der Bibliothek fuer PDF und ZIP aus der Dateien-App.
// Seit 11.11.2026 (Meldung des Inhabers) mit allen Orten der Bibliothek statt nur der Module, "Neuer Ordner …" und
// mehreren Dateien auf einmal (`ImportTargets.swift`).

/// Dateien eines Imports: mehrere geteilte Dateien kommen einzeln an (`onOpenURL` je Datei) und landen im selben
/// offenen Dialog
@MainActor
final class ExternalImportBatch: ObservableObject {
    @Published var files: [ExternalFileImport.Staged]
    /// Dialog geschlossen: neue Dateien oeffnen einen neuen Dialog
    var finished = false

    init(_ files: [ExternalFileImport.Staged]) { self.files = files }
}

/// Sammelt Dateien von aussen in einen Dialog: ist schon einer offen, kommt die Datei dazu, sonst oeffnet sich einer
@MainActor
enum ExternalImportInbox {
    private(set) static weak var open: ExternalImportBatch?

    /// Datei(en) in den offenen Dialog bzw. einen neuen; `preset`: vorgewaehltes Ziel eines neuen Dialogs
    static func receive(_ staged: [ExternalFileImport.Staged], overlay: UFOverlay, preset: ImportTarget? = nil) {
        guard !staged.isEmpty else { return }
        if let batch = open, !batch.finished {
            batch.files += staged
            return
        }
        let batch = ExternalImportBatch(staged)
        open = batch
        overlay.modal { ExternalImportDialog(batch: batch, preset: preset) }
    }

    /// Vorgewaehltes Ziel fuer "Teilen" -> StudiNow: der offene Ort der Bibliothek, sonst ohne Ordner
    static func preset(for route: UFRoute) -> ImportTarget {
        if case .files(let section, let path, _) = route, section == nil || section == "docs" { return ImportTarget.from(path: path) }
        return .loose
    }
}

/// Dialog fuer PDF und ZIP von aussen: Datei(en), Titel (bei einer Datei), "Wohin?" mit allen Orten der Bibliothek
/// (ohne Ordner, Modul, eigener Ordner auch als Unterordner, "Neuer Ordner …" mit Name und Ort). Eine Datei oeffnet sich
/// danach (ZIP als Ordner, PDF im Editor), mehrere zeigen den Zielordner. Abbrechen entfernt die Kopien.
struct ExternalImportDialog: View {
    @ObservedObject var batch: ExternalImportBatch
    /// vorgewaehltes Ziel (Ablegen bzw. "Neu" im offenen Ordner)
    var preset: ImportTarget?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var title = ""
    @State private var target: ImportTarget = .loose
    @State private var lib: JSONValue = .null
    @State private var newName = "Neuer Ordner"
    @State private var newParent: ImportTarget = .loose
    @State private var busy = false

    init(batch: ExternalImportBatch, preset: ImportTarget? = nil) {
        self.batch = batch
        self.preset = preset
    }

    /// eine Datei; `moduleID`: vorgewaehltes Modul (wie vorher)
    init(staged: ExternalFileImport.Staged, moduleID: Int? = nil) {
        self.init(batch: ExternalImportBatch([staged]), preset: moduleID.map(ImportTarget.module))
    }

    private var files: [ExternalFileImport.Staged] { batch.files }
    private var single: ExternalFileImport.Staged? { files.count == 1 ? files.first : nil }
    private var heading: String {
        if let single { return "\(single.kind.label) importieren" }
        return "\(files.count) Dateien importieren"
    }
    private var canImport: Bool {
        !busy && !files.isEmpty && (target != .newFolder || !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        UFDialog(heading, icon: single?.kind == .zip ? "folder" : single?.kind == .image ? "image" : "file-text") {
            UFField(files.count == 1 ? "Datei" : "Dateien") {
                VStack(alignment: .leading, spacing: 3.2) {
                    ForEach(files.indices, id: \.self) { i in
                        Text("\(files[i].name) · \(ExternalFileImport.megabytes(files[i].bytes)) MB").ufFont(14.4).foregroundStyle(UF.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityIdentifier("import.file")
            }
            if single != nil { UFField("Titel") { UFTextInput(text: $title) } }
            UFField("Wohin?") {
                UFSelect(options: ImportPlaces.options(lib), selection: $target, fill: true)
                    .accessibilityIdentifier("import.target")
            }
            if target == .newFolder {
                UFField("Name des neuen Ordners") { UFTextInput(text: $newName) }
                UFField("Anlegen in") {
                    UFSelect(options: ImportPlaces.parents(lib), selection: $newParent, fill: true)
                        .accessibilityIdentifier("import.newFolderParent")
                }
            }
            Text(hint).ufFont(12.8).foregroundStyle(UF.muted)
        } foot: {
            UFButton("Abbrechen") { batch.finished = true; batch.files.forEach(ExternalFileImport.discard); close() }
            UFButton("Importieren", kind: .primary) { Task { await create() } }.disabled(!canImport)
        }
        .task {
            if title.isEmpty, let single { title = single.title }
            lib = (try? await session.api?.value("/api/library")) ?? .null
            let wanted = preset ?? .loose
            target = ImportPlaces.contains(wanted, in: lib) ? wanted : .loose
            if target != .newFolder { newParent = target }
        }
        // geschlossen (Abbrechen, Importieren, Tippen daneben): neue Dateien bekommen einen neuen Dialog (liegen
        // gebliebene Kopien raeumt `AppTemp` spaetestens beim naechsten Start)
        .onDisappear { batch.finished = true }
    }

    private var hint: String {
        if files.count > 1 { return "Alle Dateien landen am selben Ort." }
        switch single?.kind {
        case .zip?: return "Die ZIP-Datei öffnet sich danach als Ordner. PDFs daraus lassen sich mit dem Stift bearbeiten."
        case .image?: return "Das Bild wird als PDF-Seite angelegt und öffnet sich danach im Editor."
        default: return "Die PDF öffnet sich danach im Editor."
        }
    }

    /// Ergebnis eines Imports: angelegte Dokumente, gescheiterte Dateien (Name und Grund), Ziel und sein Pfad
    struct Outcome {
        var created: [(staged: ExternalFileImport.Staged, id: String)] = []
        var failed: [String] = []
        var target: ImportTarget
        var path: String?
    }

    /// Import ohne Ansicht (testbar): bei "Neuer Ordner …" erst den Ordner anlegen (scheitert das, wird nichts
    /// importiert und die Kopien bleiben fuer einen zweiten Versuch), dann jede Datei als eigenes Dokument am Ziel;
    /// eine gescheiterte Datei aendert an den anderen nichts
    static func perform(_ files: [ExternalFileImport.Staged], api: APIClient, target: ImportTarget, title: String? = nil,
                        newFolder: (name: String, parent: ImportTarget)? = nil, lib: JSONValue) async throws -> Outcome {
        var resolved = target
        var path = ImportPlaces.path(target, in: lib)
        if target == .newFolder {
            let n = newFolder ?? (name: "Neuer Ordner", parent: .loose)
            let row = try await api.value("/api/folders", method: "POST", body: ImportPlaces.newFolderBody(name: n.name, parent: n.parent, in: lib))
            guard let id = row.i("id") else { throw APIError(status: 502, message: "keine ID", text: "Der Ordner ließ sich nicht anlegen.") }
            resolved = .folder(id)
            path = ImportPlaces.path(newFolder: id, under: n.parent, in: lib)
        }
        var out = Outcome(target: resolved, path: path)
        let (moduleID, folderID) = resolved.fields
        for s in files {
            do {
                let id = try await ExternalFileImport.create(s, api: api, title: files.count == 1 ? title : nil, moduleID: moduleID, folderID: folderID)
                out.created.append((s, id))
            } catch {
                ExternalFileImport.discard(s)
                out.failed.append("\(s.name) (\(ExternalFileImport.message(error)))")
            }
        }
        return out
    }

    private func create() async {
        guard let api = session.api, canImport else { return }
        busy = true
        defer { busy = false }
        batch.finished = true                          // was waehrenddessen ankommt, bekommt einen eigenen Dialog
        let list = files
        let place = target == .newFolder ? newName.trimmingCharacters(in: .whitespacesAndNewlines) : ImportPlaces.label(target, in: lib)
        do {
            let out = try await Self.perform(list, api: api, target: target, title: title, newFolder: (newName, newParent), lib: lib)
            batch.finished = true
            close()
            let suffix = out.target == .loose ? "" : " in „\(place)“"
            if list.count == 1, let first = out.created.first {
                toast.show("„\(title.isEmpty ? first.staged.title : title)“ importiert\(suffix).")
                router.go(.doc(first.id))
            } else {
                toast.show(LibraryNewDialog.importSummary(ok: out.created.count, failed: out.failed) + suffix, seconds: out.failed.isEmpty ? 2.6 : 6)
                if !out.created.isEmpty { router.go(.files(path: out.path)); router.reload() }
            }
        } catch {
            batch.finished = false                     // Dialog bleibt offen (z. B. Ordner nicht angelegt)
            toast.show("Import fehlgeschlagen: \(ExternalFileImport.message(error))", seconds: 5)
        }
    }
}

/// Ablegen von PDF, ZIP und Bildern aus der Dateien-App, aus Fotos bzw. dem Finder (Drag & Drop, Split View) in
/// "Dokumente & Notizen": alle abgelegten Dateien kommen in den Dialog "Wohin?", vorgewaehlt mit dem offenen Modul bzw.
/// Ordner (vorher landeten PDFs ohne Frage dort, eine einzelne ZIP fragte nur nach dem Modul; Bilder gingen bis
/// 12.11.2026 gar nicht).
struct LibraryDropTarget: ViewModifier {
    let moduleID: Int?
    let folderID: Int?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @State private var targeted = false

    static let types: [UTType] = [.pdf, .zip, .image]

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: UF.r)
                        .fill(UF.accentSoft.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                        .overlay(Text("PDF, ZIP oder Bild hier ablegen").ufFont(16, 600).foregroundStyle(UF.accentText))
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

    /// Art des Anbieters (ZIP vor PDF: eine ZIP meldet nie PDF, eine PDF nie ZIP; Bild zuletzt)
    static func kind(of provider: NSItemProvider) -> (ExternalFileImport.Kind, UTType)? {
        if provider.hasItemConformingToTypeIdentifier(UTType.zip.identifier) { return (.zip, .zip) }
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) { return (.pdf, .pdf) }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return (.image, .image) }
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

    /// Ziel zum offenen Ort: Ordner vor Modul
    static func target(moduleID: Int?, folderID: Int?) -> ImportTarget {
        if let folderID { return .folder(folderID) }
        if let moduleID { return .module(moduleID) }
        return .loose
    }

    private func receive(_ providers: [NSItemProvider]) async {
        guard session.api != nil else { return }
        var staged: [ExternalFileImport.Staged] = []
        var failed: [String] = []
        for p in providers {
            do { staged.append(try await Self.stage(p)) } catch { failed.append("\(p.suggestedName ?? "Datei") (\(ExternalFileImport.message(error)))") }
        }
        if !failed.isEmpty { toast.show(LibraryNewDialog.importSummary(ok: 0, failed: failed), seconds: 6) }
        ExternalImportInbox.receive(staged, overlay: overlay, preset: Self.target(moduleID: moduleID, folderID: folderID))
    }
}
