import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UniFlowCore

// Die Verbindung zum eigenen UniFlow-Server (ConnectView) liegt in Views/Settings/SettingsPage.swift unter "Entwicklung".

// MARK: - Datei ausserhalb des Editors

/// Datei, die sich nicht im PDF-Editor oeffnet: noch nicht geladen (verstaendliche Meldung statt "Not Found") oder
/// keine PDF (Word, PowerPoint, Bild …: Vorschau mit QuickLook, von dort "Öffnen in …" und Teilen; vorher "No Error").
struct FileOutsideEditorView: View {
    let file: LibFile
    let api: APIClient
    @State private var preview: URL?
    @State private var problem: String?
    @State private var loading = false

    /// Was angezeigt wird (testbar)
    static func message(for f: LibFile) -> String {
        f.downloaded_at == nil ? DocumentOpenText.notLoaded : DocumentOpenText.notPDF
    }

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(file.displayTitle, systemImage: file.downloaded_at == nil ? "icloud.and.arrow.down" : "doc",
                                   description: Text(problem ?? Self.message(for: file)))
            if file.downloaded_at != nil {
                Button { Task { await open() } } label: { Label("Vorschau und „Öffnen in …“", systemImage: "eye") }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
            }
        }
        .quickLookPreview($preview)
    }

    /// Inhalt in einen eigenen Ordner des Containers (`AppTemp`, Name bereinigt) und mit QuickLook zeigen
    private func open() async {
        loading = true
        defer { loading = false }
        do {
            let (data, http) = try await api.data("/api/files/\(file.id)/content")
            guard http.statusCode == 200 else { problem = DocumentOpenText.problem(status: http.statusCode); return }
            let url = try AppTemp.file("ansehen", name: file.name)
            try data.write(to: url, options: .atomic)
            preview = url
        } catch {
            problem = error.localizedDescription
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
    /// Dokument, das beim Oeffnen gleich angezeigt wird (Route #/doc/<id> aus Uebersicht/Suche)
    var openFile: String?
    /// PDF-Seite dieses Dokuments (1-basiert, Route #/doc/<id>?page=n aus der Suche nach Seitentext)
    var openPage: Int?
    /// Aufgabe des Lernplans, aus der das Dokument geoeffnet wurde ("Weiterlernen", "Öffnen" im Lernplan)
    var openTask: Int?
    /// Dokumente, die nicht in /api/library stehen (Papierkorb, abgewaehlter Kurs): einzeln geladen
    @State private var extra: [String: LibFile] = [:]
    /// gibt es nicht (mehr)
    @State private var missing: Set<String> = []

    init(openFile: String? = nil, openPage: Int? = nil, openTask: Int? = nil) {
        self.openFile = openFile
        self.openPage = openPage
        self.openTask = openTask
    }

    private var files: [LibFile] {
        let all = (library?.files ?? []).filter { $0.opensInEditor }
        let byModule: [LibFile]
        if let sel = moduleSelection, sel.hasPrefix("m"), let id = Int(sel.dropFirst()) {
            byModule = all.filter { $0.module_id == id }
        } else {
            byModule = all
        }
        let q = query.lowercased()
        return q.isEmpty ? byModule : byModule.filter { ($0.displayTitle + " " + ($0.subject ?? "") + " " + $0.name).lowercased().contains(q) }
    }

    private func file(_ id: String) -> LibFile? { library?.files.first { $0.id == id } ?? extra[id] }

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
            .navigationTitle("Studora")
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
                    if f.opensInEditor {
                        // Identitaet je Datenquelle: beim Wechsel lokal <-> Server entsteht der DocumentStore neu fuer
                        // die neue Quelle (updateAPI uebernimmt nur Verbindungen derselben Quelle)
                        DocumentView(file: f, api: api, initialPDFPage: f.id == openFile ? openPage : nil,
                                     task: f.id == openFile ? openTask : nil).id("\(api.namespace.id)/\(f.id)")
                    } else {
                        FileOutsideEditorView(file: f, api: api)
                    }
                } else if let id = fileSelection, missing.contains(id) {
                    ContentUnavailableView("Dokument nicht verfügbar", systemImage: "doc.questionmark", description: Text(DocumentOpenText.notFound))
                } else if fileSelection != nil, library != nil {
                    ProgressView()
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
            // wie viewDoc im Web: geoeffnet (Zuletzt, gilt als gesehen); Fehler sind egal
            let api = session.api
            Task { _ = try? await api?.value("/api/files/\(new)/opened", method: "POST", body: [:]) }
        }
        .task {
            await load()
            if let o = openFile {
                // nicht in der Bibliothek (Papierkorb, abgewaehlter Kurs, Aufgabe auf eine solche Datei): einzeln laden
                // statt "Dokument wählen" ohne Erklaerung
                if file(o) == nil { await loadSingle(o) }
                fileSelection = o
            }
        }
    }

    /// Ein Dokument ueber GET /api/files/{id}; gibt es das nicht, steht es in `missing`
    private func loadSingle(_ id: String) async {
        guard let api = session.api else { return }
        if let f = try? await api.json("/api/files/\(id)", as: LibFile.self) { extra[id] = f } else { missing.insert(id) }
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
