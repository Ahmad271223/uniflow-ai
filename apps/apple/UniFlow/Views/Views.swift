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
                Section {
                    NavigationLink { StudIPView() } label: { Label("Stud.IP ohne PC nutzen", systemImage: "graduationcap") }
                } footer: {
                    Text("Dateien direkt aus Stud.IP aufs iPad laden. Notizen, Kalender und Tests brauchen weiterhin den UniFlow-Server.")
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
    /// Dokument, das beim Oeffnen gleich angezeigt wird (Route #/doc/<id> aus Uebersicht/Suche)
    var openFile: String?

    init(openFile: String? = nil) { self.openFile = openFile }

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
        .task {
            await load()
            if let o = openFile { fileSelection = o }
        }
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
