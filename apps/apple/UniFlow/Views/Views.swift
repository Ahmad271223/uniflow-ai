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

    /// Design-Ueberarbeitung 03.11.2026: geladene Dateien zeigt die Ansicht gleich eingebettet (QuickLook in der App,
    /// wie die PDF im Editor) statt einer leeren Seite mit Knopf; darueber eine schmale Leiste mit Titel und dezentem
    /// "Öffnen in …" (Teilen-Blatt des Systems). Nicht geladen oder Fehler: die bisherige Meldung.
    var body: some View {
        Group {
            if let preview {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        UFIcon("file-text", size: 16).foregroundStyle(UF.muted)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(file.displayTitle).ufFont(14.5, 650, lh: 1.25).foregroundStyle(UF.text).lineLimit(1)
                            Text("Vorschau · nur ansehen").ufFont(12, lh: 1.3).foregroundStyle(UF.muted)
                        }
                        Spacer(minLength: 8)
                        ShareLink(item: preview) {
                            Label("Öffnen in …", systemImage: "square.and.arrow.up").ufFont(13.12, 500)
                        }
                        .buttonStyle(UFButtonStyle(kind: .normal, size: .small))
                        .accessibilityIdentifier("file.openIn")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(UF.surface)
                    .ufBorderBottom()
                    UFQuickLookView(url: preview)
                        .accessibilityIdentifier("file.preview")
                }
            } else if loading {
                ProgressView("Vorschau wird geladen …").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(file.displayTitle, systemImage: file.downloaded_at == nil ? "icloud.and.arrow.down" : "doc",
                                       description: Text(problem ?? Self.message(for: file)))
            }
        }
        .background(UF.bg)
        .task(id: file.id) { if file.downloaded_at != nil, preview == nil { await open() } }
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

/// QLPreviewController eingebettet (Word, PowerPoint, Excel, Bilder, Text …): eine Datei, ohne eigene Leiste
struct UFQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        c.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// MARK: - Bibliothek mit Dokument-Tabs

struct LibraryView: View {
    @EnvironmentObject private var session: Session
    /// Ziele des Logos (setzt AppShell); ohne sie (Tests, alte Fassung) kein Zurueck
    @Environment(\.ufLogoMenu) private var logoMenu
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
                    // 03.11.2026: hier gab es oben links kein Zurueck (nur die Seitenleiste)
                    ContentUnavailableView {
                        Label("Dokument wählen", systemImage: "doc.richtext")
                    } description: {
                        Text("Links ein Modul und ein Dokument auswählen.")
                    } actions: {
                        if let logoMenu {
                            Button("Zur Bibliothek") { logoMenu.go(.files()) }.buttonStyle(.borderedProminent)
                        }
                    }
                    .toolbar { ToolbarItem(placement: .topBarLeading) { UFLogoMenu() } }
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
                // Beim Oeffnen ueber eine Route griff `.detailOnly` aus onChange noch vor dem ersten Bild nicht: die
                // Dokumentliste lag hochkant ueber dem Dokument (und ueber der KI-Hilfe). Nach dem ersten Bild erneut.
                try? await Task.sleep(nanoseconds: 300_000_000)
                columns = .detailOnly
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
                // Farben aus UF.* wie die uebrige App (vorher Systemfarben); Schliessen mit groesserer Trefferflaeche
                ForEach(openTabs, id: \.self) { id in
                    let active = id == fileSelection
                    HStack(spacing: 2) {
                        Text(file(id)?.displayTitle ?? "Dokument").lineLimit(1).frame(maxWidth: 220)
                            .ufFont(12.8, active ? 600 : 500, lh: 1.25)
                        Button { close(id) } label: {
                            // 44 pt hoch; seitlich nur bis zur halben Luecke, damit der Titel (Tab waehlen) bleibt
                            UFIcon("x", size: 12).frame(width: 28, height: 28).contentShape(Rectangle())
                                .ufHitArea(slop: EdgeInsets(top: .infinity, leading: 2, bottom: .infinity, trailing: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Tab schließen")
                    }
                    .foregroundStyle(active ? UF.accentText : UF.text2)
                    .padding(.leading, 12).padding(.trailing, 4)
                    .background(active ? UF.accentSoft : UF.surface2, in: Capsule())
                    .onTapGesture { fileSelection = id }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .padding(.vertical, 2)                                      // Platz fuer die 44-pt-Flaeche in der Rollflaeche
        }
        .padding(.vertical, -2)
        .background(UF.surface)
        .ufBorderBottom()
    }

    private func close(_ id: String) {
        guard let i = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: i)
        if fileSelection == id { fileSelection = openTabs.isEmpty ? nil : openTabs[max(0, i - 1)] }
        // letzter Tab zu: zurueck in die Bibliothek statt auf eine leere Seite ohne Zurueck
        if openTabs.isEmpty, let logoMenu { logoMenu.go(.files()) }
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
