import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// MARK: - Verbindung

struct ConnectView: View {
    @EnvironmentObject private var session: Session
    @State private var url = ""
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.0.10:8765", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("PIN (6 Ziffern)", text: $pin).keyboardType(.numberPad)
                } header: {
                    Text("UniFlow-Server")
                } footer: {
                    Text("Am PC Start-iPad.cmd starten. Adresse und PIN stehen in der App unter Einstellungen → Zugang & Darstellung → Auf dem iPad benutzen. Zu Hause funktioniert auch der Rechnername, z. B. http://amo.fritz.box:8765.")
                }
                if let error = session.lastError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await session.connect(urlString: url, pin: pin) }
                    } label: {
                        HStack { Spacer(); if session.connecting { ProgressView() } else { Text("Verbinden").bold() }; Spacer() }
                    }
                    .disabled(url.isEmpty || pin.isEmpty || session.connecting)
                }
            }
            .navigationTitle("UniFlow")
            .onAppear { if url.isEmpty { url = session.savedURL } }
        }
    }
}

// MARK: - Bibliothek mit Dokument-Tabs

struct LibraryView: View {
    @EnvironmentObject private var session: Session
    @State private var library: LibraryResponse?
    @State private var loadError: String?
    @State private var moduleSelection: String? = "all"
    @State private var fileSelection: String?
    @State private var openTabs: [String] = []
    @State private var query = ""
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var importing = false
    @State private var importMessage: String?

    private var files: [LibFile] {
        let all = (library?.files ?? []).filter { $0.isPDF }
        let byModule: [LibFile]
        if let sel = moduleSelection, sel.hasPrefix("m"), let id = Int(sel.dropFirst()) {
            byModule = all.filter { $0.module_id == id }
        } else {
            byModule = all
        }
        let q = query.lowercased()
        return q.isEmpty ? byModule : byModule.filter { ($0.displayTitle + " " + ($0.subject ?? "") + " " + $0.name).lowercased().contains(q) }
    }

    private func file(_ id: String) -> LibFile? { library?.files.first { $0.id == id } }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $moduleSelection) {
                Label("Alle Dokumente", systemImage: "tray.full").tag("all" as String?)
                Section("Module") {
                    ForEach(library?.modules ?? []) { m in
                        Label(m.name, systemImage: "book.closed").tag("m\(m.id)" as String?)
                    }
                }
            }
            .navigationTitle("UniFlow")
            .toolbar { Button("Trennen", role: .destructive) { session.disconnect() } }
        } content: {
            List(files, selection: $fileSelection) { f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.displayTitle).lineLimit(2)
                    Text([f.subject, f.sub_label].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Dokumente suchen")
            .overlay {
                if library == nil && loadError == nil { ProgressView() }
                if let loadError { ContentUnavailableView("Bibliothek nicht geladen", systemImage: "wifi.exclamationmark", description: Text(loadError)) }
                if library != nil && loadError == nil && files.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .refreshable { await load() }
            .navigationTitle("Dokumente")
            .toolbar {
                Button { importing = true } label: { Label("PDF importieren", systemImage: "square.and.arrow.down") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                Task { await importPDF(result) }
            }
            .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importMessage ?? "") }
        } detail: {
            VStack(spacing: 0) {
                if !openTabs.isEmpty { tabStrip }
                if let id = fileSelection, let f = file(id), let api = session.api {
                    DocumentView(file: f, api: api).id(f.id)
                } else {
                    ContentUnavailableView("Dokument wählen", systemImage: "doc.richtext", description: Text("Links ein Modul und ein Dokument auswählen."))
                }
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .onChange(of: fileSelection) { _, new in
            guard let new else { return }
            if !openTabs.contains(new) { openTabs.append(new) }
            columns = .detailOnly
        }
        .task { await load() }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(openTabs, id: \.self) { id in
                    HStack(spacing: 6) {
                        Text(file(id)?.displayTitle ?? "Dokument").lineLimit(1).frame(maxWidth: 220)
                        Button { close(id) } label: { Image(systemName: "xmark").font(.caption2) }
                            .accessibilityLabel("Tab schließen")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(id == fileSelection ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
                    .onTapGesture { fileSelection = id }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func close(_ id: String) {
        guard let i = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: i)
        if fileSelection == id { fileSelection = openTabs.isEmpty ? nil : openTabs[max(0, i - 1)] }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            library = try await api.json("/api/library", as: LibraryResponse.self)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func importPDF(_ result: Result<URL, Error>) async {
        guard let api = session.api else { return }
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.starts(with: Array("%PDF".utf8)) else { importMessage = "Die Datei ist keine PDF."; return }
            let title = url.deletingPathExtension().lastPathComponent
            let created = try await api.upload("/api/notebooks", fields: ["kind": "pdf", "title": title],
                                               fileField: "upload", fileName: url.lastPathComponent, mimeType: "application/pdf", data: data)
            await load()
            if let id = created["id"]?.string { fileSelection = id }
            importMessage = "„\(title)“ wurde importiert."
        } catch {
            importMessage = "Import fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

// MARK: - Dokument

/// Verbindung zwischen SwiftUI-Leisten und dem UIKit-Editor.
@MainActor
final class EditorBridge: ObservableObject {
    weak var controller: PDFEditorController?
    @Published var zoomPercent = 100
    @Published var pageIndex = 0

    func undo() { controller?.undo() }
    func redo() { controller?.redo() }
    func fitWidth() { controller?.fitWidth() }
}

/// Vorlagen fuer neue Seiten (gleiche Namen wie TEMPLATES im Web-Editor).
struct PageTemplate: Identifiable {
    let id: String
    let name: String
    static let all = [
        PageTemplate(id: "blank", name: "Leer"), PageTemplate(id: "lined", name: "Liniert"),
        PageTemplate(id: "grid", name: "Kariert"), PageTemplate(id: "dotted", name: "Gepunktet"),
        PageTemplate(id: "mm", name: "Millimeter"), PageTemplate(id: "cornell", name: "Cornell"),
    ]
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct DocumentView: View {
    @StateObject private var store: DocumentStore
    @StateObject private var bridge = EditorBridge()
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true
    @State private var fullScreen = false
    @State private var showSidebar = false
    @State private var showSearch = false
    @State private var showInfo = false
    @State private var addingText = false
    @State private var newText = ""
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var actionError: String?

    init(file: LibFile, api: APIClient) {
        _store = StateObject(wrappedValue: DocumentStore(file: file, api: api))
    }

    var body: some View {
        Group {
            if let error = store.errorMessage {
                ContentUnavailableView("Dokument nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.pdf != nil {
                HStack(spacing: 0) {
                    if showSidebar {
                        PageSidebar(store: store, bridge: bridge).frame(width: 200)
                        Divider()
                    }
                    PDFEditorView(store: store, bridge: bridge, pencilOnly: pencilOnly, layoutVersion: store.layoutVersion)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) { pageInfo }
                }
            } else {
                ProgressView("Lädt…")
            }
        }
        .navigationTitle(store.file.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar)
        .toolbar { toolbar }
        .overlay(alignment: .topTrailing) {
            if fullScreen {
                Button { fullScreen = false } label: { Label("Vollbild beenden", systemImage: "xmark").padding(10) }
                    .buttonStyle(.borderedProminent).padding()
            }
        }
        .sheet(isPresented: $showSearch) { SearchSheet(store: store, bridge: bridge) }
        .sheet(isPresented: $showInfo) { InfoSheet(store: store) }
        .sheet(item: $exportFile) { f in ActivityView(items: [f.url]) }
        .alert("Text hinzufügen", isPresented: $addingText) {
            TextField("Text", text: $newText)
            Button("Hinzufügen") {
                let text = newText
                newText = ""
                Task { await store.addText(text, pageIndex: bridge.pageIndex) }
            }
            Button("Abbrechen", role: .cancel) { newText = "" }
        } message: { Text("Erscheint oben links auf der aktuellen Seite und ist im Browser bearbeitbar.") }
        .alert("Hinweis", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .task { await store.load() }
        .onDisappear { Task { await store.close() } }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { withAnimation { showSidebar.toggle() } } label: { Label("Seiten", systemImage: "sidebar.left") }
            Button { bridge.undo() } label: { Label("Rückgängig", systemImage: "arrow.uturn.backward") }
            Button { bridge.redo() } label: { Label("Wiederholen", systemImage: "arrow.uturn.forward") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            StatusLabel(status: store.status)
            Button { showSearch = true } label: { Label("Suchen", systemImage: "magnifyingglass") }
            Button { pencilOnly.toggle() } label: {
                Label(pencilOnly ? "Nur Stift" : "Finger zeichnet", systemImage: pencilOnly ? "applepencil" : "hand.draw")
            }
            Menu {
                Button {
                    Task { await store.toggleBookmark(pageIndex: bridge.pageIndex) }
                } label: {
                    Label(store.isBookmarked(pageIndex: bridge.pageIndex) ? "Lesezeichen entfernen" : "Lesezeichen setzen", systemImage: "bookmark")
                }
                Menu {
                    ForEach(PageTemplate.all) { t in
                        Button(t.name) { Task { await store.addBlankPage(after: bridge.pageIndex, template: t.id) } }
                    }
                } label: { Label("Leere Seite danach", systemImage: "doc.badge.plus") }
                Button { Task { await store.rotatePage(bridge.pageIndex) } } label: { Label("Seite drehen", systemImage: "rotate.right") }
                Button { addingText = true } label: { Label("Text hinzufügen", systemImage: "textformat") }
                Divider()
                Button {
                    exporting = true
                    Task {
                        defer { exporting = false }
                        do { exportFile = ExportFile(url: try await store.exportPDF()) } catch { actionError = "Export fehlgeschlagen: \(error.localizedDescription)" }
                    }
                } label: { Label(exporting ? "Exportiert…" : "Als PDF mit Notizen teilen", systemImage: "square.and.arrow.up") }
                .disabled(exporting)
                Button { showInfo = true } label: { Label("Dokumentinformation", systemImage: "info.circle") }
                Button { fullScreen = true } label: { Label("Vollbild", systemImage: "arrow.up.left.and.arrow.down.right") }
            } label: { Label("Mehr", systemImage: "ellipsis.circle") }
        }
    }

    private var pageInfo: some View {
        HStack(spacing: 10) {
            Text("Seite \(bridge.pageIndex + 1) / \(store.pdf?.pageCount ?? 0)")
            Divider().frame(height: 14)
            Button("\(bridge.zoomPercent) %") { bridge.fitWidth() }
                .accessibilityHint("Seite einpassen")
            if let notice = store.notice {
                Divider().frame(height: 14)
                Text(notice).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }
}

/// Seitenuebersicht (Miniaturen von PDFKit) und Lesezeichen.
struct PageSidebar: View {
    @ObservedObject var store: DocumentStore
    @ObservedObject var bridge: EditorBridge

    var body: some View {
        VStack(spacing: 0) {
            if !store.bookmarks.isEmpty {
                List {
                    Section("Lesezeichen") {
                        ForEach(store.bookmarks) { b in
                            Button(b.title) {
                                if let i = store.layout?.index(ofKey: b.key) { bridge.controller?.goToPage(i) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 180)
                Divider()
            }
            ThumbnailStrip(bridge: bridge)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

struct ThumbnailStrip: UIViewRepresentable {
    let bridge: EditorBridge

    func makeUIView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.layoutMode = .vertical
        v.thumbnailSize = CGSize(width: 140, height: 190)
        v.backgroundColor = .secondarySystemBackground
        v.pdfView = bridge.controller?.pdfView
        return v
    }

    func updateUIView(_ v: PDFThumbnailView, context: Context) {
        if v.pdfView == nil { v.pdfView = bridge.controller?.pdfView }
    }
}

struct SearchSheet: View {
    @ObservedObject var store: DocumentStore
    let bridge: EditorBridge
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        NavigationStack {
            List(hits) { hit in
                Button {
                    bridge.controller?.show(hit.selection)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Seite \(hit.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                        Text(hit.snippet).lineLimit(2)
                    }
                }
            }
            .overlay {
                if query.count >= 2 && hits.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Im PDF suchen")
            .onChange(of: query) { _, q in hits = store.search(q) }
            .navigationTitle("Suchen")
            .toolbar { Button("Fertig") { dismiss() } }
        }
    }
}

struct InfoSheet: View {
    @ObservedObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var info: DocumentInfo?

    var body: some View {
        NavigationStack {
            List {
                if let i = info {
                    Section("Dokument") {
                        LabeledContent("Titel", value: i.title)
                        LabeledContent("Datei", value: i.fileName)
                        if let s = i.subject { LabeledContent("Veranstaltung", value: s) }
                        if let f = i.folder { LabeledContent("Stud.IP-Ordner", value: f) }
                    }
                    Section("Seiten") {
                        LabeledContent("Angezeigt", value: "\(i.displayPages)")
                        LabeledContent("Im PDF", value: "\(i.pdfPages)")
                        LabeledContent("Eingefügt (Browser/iPad)", value: "\(i.insertedPages)")
                        if !i.removedPDFPages.isEmpty {
                            LabeledContent("Im Browser entfernt", value: i.removedPDFPages.map(String.init).joined(separator: ", "))
                        }
                        LabeledContent("Lesezeichen", value: "\(i.bookmarks)")
                    }
                    Section("Speichern") {
                        LabeledContent("Status", value: i.status)
                        LabeledContent("Ungesendete Seiten", value: "\(i.unsentPages)")
                        LabeledContent("Serverversion", value: "\(i.serverVersion)")
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Dokumentinformation")
            .toolbar { Button("Fertig") { dismiss() } }
            .task { info = await store.info() }
        }
    }
}

/// Teilen-Dialog des Systems (z. B. exportierte PDF in Dateien sichern).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct StatusLabel: View {
    let status: SyncStatus

    var body: some View {
        Label(status.label, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(color)
            .accessibilityLabel(status.label)
    }

    private var icon: String {
        switch status {
        case .saved: return "checkmark.icloud"
        case .uploading, .loading: return "arrow.triangle.2.circlepath.icloud"
        case .pending: return "internaldrive"
        case .offline: return "icloud.slash"
        case .localSaveFailed, .conflictUnresolved: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status {
        case .localSaveFailed, .conflictUnresolved: return .red
        case .offline: return .orange
        default: return .secondary
        }
    }
}

struct PDFEditorView: UIViewControllerRepresentable {
    let store: DocumentStore
    let bridge: EditorBridge
    let pencilOnly: Bool
    let layoutVersion: Int

    func makeUIViewController(context: Context) -> PDFEditorController {
        let vc = PDFEditorController(store: store)
        let bridge = self.bridge
        vc.pencilOnly = pencilOnly
        vc.onZoomChange = { [weak bridge] z in bridge?.zoomPercent = Int((z * 100).rounded()) }
        vc.onPageChange = { [weak bridge] i in bridge?.pageIndex = i }
        bridge.controller = vc
        return vc
    }

    /// Wird bei jeder SwiftUI-Aktualisierung aufgerufen (z. B. Statuswechsel). Fasst die Canvas nicht an; baut die
    /// Anzeige nur neu auf, wenn sich die Seitenstruktur geaendert hat.
    func updateUIViewController(_ vc: PDFEditorController, context: Context) {
        if vc.pencilOnly != pencilOnly { vc.pencilOnly = pencilOnly }
        if vc.shownLayoutVersion != layoutVersion { vc.showLayout() }
    }
}
