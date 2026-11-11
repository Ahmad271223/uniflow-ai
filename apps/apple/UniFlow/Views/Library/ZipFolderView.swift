import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// ZIP-Dateien in StudiNow (Wunsch des Inhabers 07.11.2026): Uebungs-ZIPs aus Stud.IP/Moodle als Ordner ansehen und
// bearbeiten. Der Inhalt wird einmal sicher entpackt (`ZipWorkspace`, Zip-Slip und ZIP-Bomben abgewehrt) und bleibt im
// Container des Kontos; jede Aenderung liegt sofort dort. PDFs daraus oeffnen sich im Editor mit Stift: beim ersten
// Oeffnen wird die PDF als eigenes Dokument (im Modul der ZIP) importiert, die Notizen liegen dort wie bei jedem
// Dokument und kommen beim Packen als "PDF mit Notizen" in die neue ZIP. Bilder, Office, Text: Vorschau; Text auch
// aendern; alles andere ueber "Öffnen in …".

/// Arbeitsstand einer ZIP-Datei der Bibliothek
@MainActor
final class ZipFolderModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed(String) }

    let file: LibFile
    let api: APIClient
    let workspace: ZipWorkspace
    @Published private(set) var phase: Phase = .loading
    /// angezeigter Ordner (relativer Pfad, "" = oberste Ebene)
    @Published private(set) var dir = ""
    @Published private(set) var items: [ZipWorkspace.Item] = []
    /// Hinweis ueber der Liste (ausgelassene Eintraege)
    @Published private(set) var notice: String?
    /// neue Fassung der ZIP in der Bibliothek, waehrend hier schon geaendert wurde
    @Published private(set) var newerSource: Data?
    @Published private(set) var changed = false
    @Published private(set) var totals = (files: 0, bytes: 0)
    @Published var busy: String?
    @Published var error: String?

    init(file: LibFile, api: APIClient, root: URL? = nil) {
        self.file = file
        self.api = api
        workspace = ZipWorkspace(root: root ?? Self.root(fileID: file.id, namespace: api.namespace))
    }

    /// `<Container>/zip/<Datenquelle>/<Datei>`: bleibt nach dem Schliessen, verschwindet mit dem Container
    nonisolated static func root(fileID: String, namespace: DataSourceNamespace, base: URL = AppPaths.support) -> URL {
        base.appendingPathComponent("zip", isDirectory: true)
            .appendingPathComponent(namespace.id, isDirectory: true)
            .appendingPathComponent(StudIPImport.safeFileName(fileID), isDirectory: true)
    }

    // MARK: Laden

    func load() async {
        phase = .loading
        do {
            let (data, http) = try await api.data("/api/files/\(file.id)/content")
            guard http.statusCode == 200 else { phase = .failed(DocumentOpenText.problem(status: http.statusCode)); return }
            try await prepare(data, force: false)
        } catch {
            // ohne Quelle (z. B. Datei gerade nicht lesbar): ein schon entpackter Stand reicht zum Arbeiten
            if workspace.meta != nil, (try? workspace.url("")) != nil {
                refresh()
                phase = .ready
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func prepare(_ data: Data, force: Bool) async throws {
        let ws = workspace, name = file.name
        let result = try await Task.detached(priority: .userInitiated) { try ws.prepare(source: data, name: name, force: force) }.value
        switch result {
        case .extracted(let s):
            let skipped = s.unsafe.count + s.unreadable.count
            notice = skipped == 0 ? nil : Self.skippedNotice(unsafe: s.unsafe.count, unreadable: s.unreadable.count)
            newerSource = nil
        case .kept:
            newerSource = nil
        case .keptWithNewerSource:
            newerSource = data
        }
        dir = ""
        refresh()
        phase = .ready
    }

    nonisolated static func skippedNotice(unsafe: Int, unreadable: Int) -> String {
        var parts: [String] = []
        if unsafe > 0 { parts.append(unsafe == 1 ? "1 Eintrag mit unsicherem Pfad" : "\(unsafe) Einträge mit unsicherem Pfad") }
        if unreadable > 0 { parts.append(unreadable == 1 ? "1 Eintrag nicht lesbar" : "\(unreadable) Einträge nicht lesbar") }
        return parts.joined(separator: " und ") + " – nicht entpackt."
    }

    /// Neue Fassung aus der Bibliothek entpacken (eigene Aenderungen gehen verloren) bzw. Original wiederherstellen
    func reset() async {
        busy = "Wird entpackt …"
        defer { busy = nil }
        do {
            if let newerSource {
                try await prepare(newerSource, force: true)
            } else {
                let (data, http) = try await api.data("/api/files/\(file.id)/content")
                guard http.statusCode == 200 else { throw APIError(status: http.statusCode, message: "", text: DocumentOpenText.problem(status: http.statusCode)) }
                try await prepare(data, force: true)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() {
        items = (try? workspace.list(dir)) ?? []
        changed = workspace.meta?.changed ?? false
        totals = workspace.totals()
    }

    // MARK: Navigation

    func open(folder path: String) {
        dir = path
        refresh()
    }

    /// Ordnerkette fuer die Brotkrumen: ("", ZIP-Name), ("A", "A"), ("A/B", "B")
    var breadcrumbs: [(path: String, name: String)] {
        var out: [(String, String)] = [("", file.displayTitle)]
        var acc = ""
        for part in dir.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            out.append((acc, String(part)))
        }
        return out
    }

    func up() {
        guard !dir.isEmpty else { return }
        open(folder: (dir as NSString).deletingLastPathComponent)
    }

    // MARK: Bearbeiten

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { self.error = error.localizedDescription }
        refresh()
    }

    func rename(_ item: ZipWorkspace.Item, to name: String) { run { try workspace.rename(item.path, to: name) } }
    func delete(_ item: ZipWorkspace.Item) { run { try workspace.delete(item.path) } }
    func makeFolder(_ name: String) { run { try workspace.makeFolder(named: name, in: dir) } }
    func saveText(_ text: String, to path: String) { run { try workspace.write(Data(text.utf8), to: path) } }

    /// Dateien aus "Dateien" in den angezeigten Ordner kopieren
    func add(_ urls: [URL]) {
        run {
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                try workspace.add(fileAt: u, into: dir)
            }
        }
    }

    /// Inhalt einer Datei durch eine andere ersetzen (Name bleibt)
    func replace(_ item: ZipWorkspace.Item, with url: URL) {
        run {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            try workspace.write(try Data(contentsOf: url), to: item.path)
        }
    }

    func url(_ item: ZipWorkspace.Item) -> URL? { try? workspace.url(item.path) }
    func hasNotesLink(_ item: ZipWorkspace.Item) -> Bool { item.ext == "pdf" && workspace.meta?.links[item.path] != nil }

    // MARK: PDF mit Stift

    /// Dokument der Bibliothek zur PDF im ZIP: das verknuepfte, sonst jetzt importieren (Modul der ZIP-Datei)
    func editorDocument(for item: ZipWorkspace.Item) async -> LibFile? {
        busy = "PDF wird geöffnet …"
        defer { busy = nil }
        if let link = workspace.link(for: item.path),
           let f = try? await api.json("/api/files/\(link.fileID)", as: LibFile.self), f.isPDF || f.kind == "pdf" {
            return f
        }
        do {
            let url = try workspace.url(item.path)
            let data = try Data(contentsOf: url)
            guard data.starts(with: Array("%PDF".utf8)) else { throw ZipFolderError.notPDF }
            let stem = (item.name as NSString).deletingPathExtension
            var fields = ["kind": "pdf", "title": "\(stem) (\((file.name as NSString).deletingPathExtension))"]
            if let m = file.module_id { fields["module_id"] = "\(m)" }
            let created = try await api.upload("/api/notebooks", fields: fields, fileField: "upload", fileName: item.name,
                                               mimeType: "application/pdf", data: data)
            guard let id = created["id"]?.string else { throw ZipFolderError.importFailed }
            try workspace.setLink(id, for: item.path)
            refresh()
            return try await api.json("/api/files/\(id)", as: LibFile.self)
        } catch {
            self.error = "PDF lässt sich nicht öffnen: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Packen

    /// Neue ZIP-Datei im Teilen-Ordner; PDFs mit Notizen kommen als "PDF mit Notizen" hinein (`withNotes`)
    func export(withNotes: Bool) async -> URL? {
        busy = "ZIP wird gepackt …"
        defer { busy = nil }
        do {
            var replacing: [String: Data] = [:]
            var failedNotes = 0
            if withNotes {
                for (path, _) in workspace.meta?.links ?? [:] {
                    guard let link = workspace.link(for: path) else { continue }
                    if let pdf = await annotatedPDF(fileID: link.fileID) { replacing[path] = pdf } else { failedNotes += 1 }
                }
            }
            let ws = workspace
            let data = try await Task.detached(priority: .userInitiated) { try ws.pack(replacing: replacing) }.value
            let name = Self.exportName(file.name)
            let url = try AppTemp.file("zip", name: name)
            try data.write(to: url, options: .atomic)
            if failedNotes > 0 {
                error = failedNotes == 1 ? "Bei einer PDF ließen sich die Notizen nicht einfügen; sie liegt ohne Notizen in der ZIP."
                    : "Bei \(failedNotes) PDFs ließen sich die Notizen nicht einfügen; sie liegen ohne Notizen in der ZIP."
            }
            return url
        } catch {
            self.error = "Packen fehlgeschlagen: \(error.localizedDescription)"
            return nil
        }
    }

    /// "Blatt 3.zip" bleibt der Name (Abgabe erwartet oft genau ihn); ohne Endung kommt ".zip" dazu
    nonisolated static func exportName(_ name: String) -> String {
        ZipArchive.isZipName(name) ? name : name + ".zip"
    }

    /// PDF mit Notizen eines Dokuments; nil ohne Notizen-Export (dann bleibt das Original)
    private func annotatedPDF(fileID: String) async -> Data? {
        guard let f = try? await api.json("/api/files/\(fileID)", as: LibFile.self) else { return nil }
        let store: DocumentStore
        var temp: DocumentStore?
        if let shown = OpenDocuments.shared.openStore(fileID: fileID, namespace: api.namespace), shown.pdf != nil {
            store = shown
        } else {
            let t = DocumentStore(file: f, api: api)
            t.setShown(false)
            await t.load()
            temp = t
            store = t
        }
        defer { if let temp { Task { await temp.closeAfterReading() } } }
        guard store.errorMessage == nil, store.pdf != nil else { return nil }
        let options = NotesExport.Options(includeSideNotes: false, fileStem: (f.name as NSString).deletingPathExtension, folder: "zip-notizen")
        guard let result = try? await NotesExport.pdf(for: store, api: api, options: options) else { return nil }
        return try? Data(contentsOf: result.url)
    }
}

enum ZipFolderError: LocalizedError {
    case notPDF, importFailed
    var errorDescription: String? {
        switch self {
        case .notPDF: return "Die Datei ist keine gültige PDF."
        case .importFailed: return "Import fehlgeschlagen."
        }
    }
}

/// Wie sich eine Datei aus dem ZIP oeffnet
enum ZipOpenKind: Equatable {
    case folder, pdf, text, preview

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yml", "yaml", "ini", "cfg", "conf", "log", "tex", "bib", "sty",
        "py", "java", "kt", "c", "h", "cpp", "hpp", "cc", "cs", "js", "ts", "html", "htm", "css", "swift", "m", "r", "sql",
        "sh", "bat", "ps1", "rb", "go", "rs", "php", "pl", "lua", "hs", "scala", "asm", "s", "vhd", "vhdl", "v", "ipynb", "gitignore",
    ]
    /// groessere Textdateien nur ansehen (TextEditor wird traege)
    static let maxTextBytes = 2 << 20

    static func of(_ item: ZipWorkspace.Item) -> ZipOpenKind {
        if item.isDirectory { return .folder }
        if item.ext == "pdf" { return .pdf }
        if textExtensions.contains(item.ext) && item.size <= maxTextBytes { return .text }
        return .preview
    }

    static func icon(_ item: ZipWorkspace.Item) -> String {
        if item.isDirectory { return "folder.fill" }
        switch item.ext {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp", "svg": return "photo"
        case "zip", "rar", "7z", "gz", "tar": return "doc.zipper"
        case "doc", "docx", "odt", "rtf": return "doc.text"
        case "ppt", "pptx", "key", "odp": return "rectangle.on.rectangle"
        case "xls", "xlsx", "numbers", "ods", "csv": return "tablecells"
        case "mp3", "m4a", "wav": return "waveform"
        case "mp4", "mov", "m4v": return "film"
        default: return textExtensions.contains(item.ext) ? "chevron.left.forwardslash.chevron.right" : "doc"
        }
    }
}

// MARK: - Ansicht

struct ZipFolderView: View {
    @StateObject private var model: ZipFolderModel
    @State private var editing: LibFile?
    @State private var previewing: ZipWorkspace.Item?
    @State private var textEditing: ZipWorkspace.Item?
    @State private var renaming: ZipWorkspace.Item?
    @State private var newName = ""
    @State private var askingFolder = false
    @State private var deleting: ZipWorkspace.Item?
    @State private var importing = false
    @State private var replacing: ZipWorkspace.Item?
    @State private var exported: ExportFile?
    @State private var confirmReset = false

    init(file: LibFile, api: APIClient) {
        _model = StateObject(wrappedValue: ZipFolderModel(file: file, api: api))
    }

    /// fuer Tests und Vorschauen: eigener Arbeitsordner
    init(model: ZipFolderModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("ZIP wird entpackt …").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failure(message)
            case .ready:
                VStack(spacing: 0) {
                    header
                    banners
                    list
                }
            }
        }
        .background(UF.bg)
        .task(id: model.file.id) { if model.phase == .loading { await model.load() } }
        .overlay {
            if let busy = model.busy {
                ProgressView(busy).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .alert("ZIP", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
        .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Abbrechen", role: .cancel) {}
            Button("Umbenennen") { if let r = renaming { model.rename(r, to: newName) } }
        }
        .alert("Neuer Ordner", isPresented: $askingFolder) {
            TextField("Name", text: $newName).autocorrectionDisabled()
            Button("Abbrechen", role: .cancel) {}
            Button("Anlegen") { model.makeFolder(newName) }
        }
        .confirmationDialog(deleting.map { "„\($0.name)“ löschen?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { if let d = deleting { model.delete(d) } }
        } message: { Text("Nur in dieser ZIP-Ansicht; die Datei in Stud.IP bleibt unverändert.") }
        .confirmationDialog(model.newerSource != nil ? "Neue Fassung entpacken?" : "Original wiederherstellen?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button(model.newerSource != nil ? "Neue Fassung entpacken" : "Wiederherstellen", role: .destructive) { Task { await model.reset() } }
        } message: { Text("Deine Änderungen in dieser ZIP gehen verloren. Notizen in geöffneten PDFs bleiben als eigene Dokumente in der Bibliothek.") }
        // ein fileImporter fuer beides (zwei an derselben Ansicht: SwiftUI zeigt nur einen)
        .fileImporter(isPresented: Binding(get: { importing || replacing != nil }, set: { if !$0 { importing = false; replacing = nil } }),
                      allowedContentTypes: [.item], allowsMultipleSelection: replacing == nil) { result in
            if case .success(let urls) = result {
                if let r = replacing { if let u = urls.first { model.replace(r, with: u) } } else { model.add(urls) }
            }
            importing = false
            replacing = nil
        }
        .fullScreenCover(item: $editing, onDismiss: { model.refresh() }) { f in
            NavigationStack {
                if UFEditorAvailability.readerOnly {
                    PhoneDocumentReader(file: f, api: model.api)
                        .environment(\.ufBack, { editing = nil })
                } else {
                    DocumentView(file: f, api: model.api, onBack: { editing = nil })
                }
            }
        }
        .sheet(item: $previewing) { item in
            if let url = model.url(item) { ZipPreviewSheet(name: item.name, url: url) }
        }
        .sheet(item: $textEditing) { item in
            if let url = model.url(item) {
                ZipTextEditorSheet(name: item.name, url: url) { model.saveText($0, to: item.path) }
            }
        }
        .sheet(item: $exported) { f in ActivityView(items: [f.url]) }
    }

    // MARK: Teile

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label(model.file.displayTitle, systemImage: "doc.zipper")
        } description: {
            Text(message)
        } actions: {
            Button("Erneut versuchen") { Task { await model.load() } }.buttonStyle(.bordered)
        }
        .accessibilityIdentifier("zip.failed")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.zipper").font(.system(size: 18)).foregroundStyle(UF.accent)
            VStack(alignment: .leading, spacing: 1) {
                breadcrumbBar
                Text(summaryLine).ufFont(12, lh: 1.3).foregroundStyle(UF.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Button { importing = true } label: { Label("Dateien hinzufügen …", systemImage: "doc.badge.plus") }
                Button { newName = "Neuer Ordner"; askingFolder = true } label: { Label("Neuer Ordner", systemImage: "folder.badge.plus") }
            } label: {
                Label("Hinzufügen", systemImage: "plus").ufFont(13.12, 500)
            }
            .buttonStyle(UFButtonStyle(kind: .normal, size: .small))
            .accessibilityIdentifier("zip.add")
            Menu {
                Button { Task { if let u = await model.export(withNotes: true) { exported = ExportFile(url: u) } } } label: {
                    Label("ZIP mit Notizen in PDFs", systemImage: "pencil.and.outline")
                }
                Button { Task { if let u = await model.export(withNotes: false) { exported = ExportFile(url: u) } } } label: {
                    Label("ZIP ohne Notizen", systemImage: "doc.zipper")
                }
                Divider()
                Button(role: .destructive) { confirmReset = true } label: {
                    Label(model.newerSource != nil ? "Neue Fassung entpacken" : "Original wiederherstellen", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.changed && model.newerSource == nil)
            } label: {
                Label("Als ZIP teilen", systemImage: "square.and.arrow.up").ufFont(13.12, 500)
            }
            .buttonStyle(UFButtonStyle(kind: .primary, size: .small))
            .accessibilityIdentifier("zip.export")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(UF.surface)
        .ufBorderBottom()
    }

    private var summaryLine: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(model.totals.bytes), countStyle: .file)
        let files = model.totals.files == 1 ? "1 Datei" : "\(model.totals.files) Dateien"
        return "ZIP · \(files) · \(size)" + (model.changed ? UFDevice.adapt(" · geändert, auf diesem iPad gespeichert") : "")
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { i, crumb in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(UF.muted) }
                    let last = i == model.breadcrumbs.count - 1
                    Button { model.open(folder: crumb.path) } label: {
                        Text(crumb.name).ufFont(14.5, last ? 650 : 500, lh: 1.25)
                            .foregroundStyle(last ? UF.text : UF.accentText).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(last)
                }
            }
        }
        .accessibilityIdentifier("zip.breadcrumbs")
    }

    @ViewBuilder private var banners: some View {
        if model.newerSource != nil {
            banner("In der Bibliothek liegt eine neue Fassung dieser ZIP. Du arbeitest weiter mit deinem geänderten Stand.",
                   action: "Neue Fassung entpacken") { confirmReset = true }
        }
        if let n = model.notice { banner(n, action: nil) {} }
    }

    private func banner(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(UF.warn)
            Text(text).ufFont(13, lh: 1.35).foregroundStyle(UF.text2)
            Spacer(minLength: 6)
            if let action { Button(action, action: perform).buttonStyle(UFButtonStyle(kind: .normal, size: .small)) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(UF.surface2)
    }

    private var list: some View {
        List {
            if !model.dir.isEmpty {
                Button { model.up() } label: {
                    Label("Übergeordneter Ordner", systemImage: "arrow.turn.left.up").ufFont(14.5, 500).foregroundStyle(UF.accentText)
                }
                .accessibilityIdentifier("zip.up")
            }
            ForEach(model.items) { item in
                row(item)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.items.isEmpty {
                ContentUnavailableView("Leerer Ordner", systemImage: "folder", description: Text("Mit „Hinzufügen“ legst du Dateien hinein."))
            }
        }
        .accessibilityIdentifier("zip.list")
    }

    private func row(_ item: ZipWorkspace.Item) -> some View {
        Button { open(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: ZipOpenKind.icon(item))
                    .font(.system(size: 20))
                    .foregroundStyle(item.isDirectory ? UF.accent : UF.text2)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).ufFont(14.5, 550, lh: 1.3).foregroundStyle(UF.text).lineLimit(2)
                    Text(detail(item)).ufFont(12, lh: 1.3).foregroundStyle(UF.muted)
                }
                Spacer(minLength: 6)
                if model.hasNotesLink(item) {
                    Label("Notizen", systemImage: "pencil.tip").labelStyle(.titleAndIcon).ufFont(11.5, 550)
                        .foregroundStyle(UF.accentText).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(UF.accentSoft, in: Capsule())
                }
                if item.isDirectory { Image(systemName: "chevron.right").foregroundStyle(UF.muted) }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(UF.surface)
        .accessibilityIdentifier("zip.item.\(item.name)")
        .contextMenu { menu(item) }
        .swipeActions {
            Button(role: .destructive) { deleting = item } label: { Label("Löschen", systemImage: "trash") }
            Button { newName = item.name; renaming = item } label: { Label("Umbenennen", systemImage: "pencil") }.tint(UF.accent)
        }
    }

    @ViewBuilder private func menu(_ item: ZipWorkspace.Item) -> some View {
        if ZipOpenKind.of(item) == .pdf {
            // iPhone ohne Editor: die PDF oeffnet in der Leseansicht (Vorgabe 11.11.2026)
            Button { open(item) } label: {
                UFEditorAvailability.available ? Label("Mit Stift öffnen", systemImage: "pencil.tip.crop.circle")
                    : Label("Öffnen", systemImage: "doc.text.magnifyingglass")
            }
            Button { previewing = item } label: { Label("Nur ansehen", systemImage: "eye") }
        } else if ZipOpenKind.of(item) == .text {
            if UFEditorAvailability.available {
                Button { textEditing = item } label: { Label("Bearbeiten", systemImage: "square.and.pencil") }
            }
            Button { previewing = item } label: { Label("Ansehen", systemImage: "eye") }
        }
        Button { newName = item.name; renaming = item } label: { Label("Umbenennen", systemImage: "pencil") }
        if !item.isDirectory {
            Button { replacing = item } label: { Label("Ersetzen …", systemImage: "arrow.triangle.2.circlepath") }
            if let url = model.url(item) {
                ShareLink(item: url) { Label("Öffnen in …", systemImage: "square.and.arrow.up") }
            }
        }
        Button(role: .destructive) { deleting = item } label: { Label("Löschen", systemImage: "trash") }
    }

    private func detail(_ item: ZipWorkspace.Item) -> String {
        if item.isDirectory { return item.childCount == 1 ? "1 Objekt" : "\(item.childCount) Objekte" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        return "\(size) · \(item.modified.formatted(date: .abbreviated, time: .shortened))"
    }

    private func open(_ item: ZipWorkspace.Item) {
        switch ZipOpenKind.of(item) {
        case .folder: model.open(folder: item.path)
        case .pdf: Task { if let f = await model.editorDocument(for: item) { editing = f } }
        case .text: if UFEditorAvailability.available { textEditing = item } else { previewing = item }
        case .preview: previewing = item
        }
    }
}

/// Bild, Office, Text … aus dem ZIP: QuickLook mit "Öffnen in …"
struct ZipPreviewSheet: View {
    let name: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            UFQuickLookView(url: url)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) { Label("Öffnen in …", systemImage: "square.and.arrow.up") }
                    }
                }
        }
    }
}

/// Textdatei aus dem ZIP aendern (Quelltext, Markdown, CSV …)
struct ZipTextEditorSheet: View {
    let name: String
    let url: URL
    let save: (String) -> Void
    @State private var text = ""
    @State private var original = ""
    @State private var unreadable = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if unreadable {
                    ContentUnavailableView("Kein lesbarer Text", systemImage: "doc.questionmark",
                                           description: Text("Die Datei ist nicht als UTF-8- oder Latin-1-Text lesbar."))
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 8)
                        .accessibilityIdentifier("zip.textEditor")
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save(text); dismiss() }.disabled(unreadable || text == original)
                }
            }
        }
        .task {
            guard let d = try? Data(contentsOf: url) else { unreadable = true; return }
            if let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) {
                text = s
                original = s
            } else {
                unreadable = true
            }
        }
    }
}
