import SwiftUI

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
                    Text("Am PC Start-iPad.cmd starten. Adresse und PIN stehen in der App unter Einstellungen → Zugang & Darstellung → Auf dem iPad benutzen.")
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

// MARK: - Bibliothek

struct LibraryView: View {
    @EnvironmentObject private var session: Session
    @State private var library: LibraryResponse?
    @State private var loadError: String?
    @State private var moduleSelection: String? = "all"
    @State private var fileSelection: String?
    @State private var query = ""
    @State private var columns: NavigationSplitViewVisibility = .all

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
            }
            .refreshable { await load() }
            .navigationTitle("Dokumente")
        } detail: {
            if let id = fileSelection, let f = library?.files.first(where: { $0.id == id }), let api = session.api {
                DocumentView(file: f, api: api).id(f.id)
            } else {
                ContentUnavailableView("Dokument wählen", systemImage: "doc.richtext", description: Text("Links ein Modul und ein Dokument auswählen."))
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .onChange(of: fileSelection) { _, new in if new != nil { columns = .detailOnly } }
        .task { await load() }
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
}

// MARK: - Dokument

struct DocumentView: View {
    @StateObject private var store: DocumentStore
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true

    init(file: LibFile, api: APIClient) {
        _store = StateObject(wrappedValue: DocumentStore(file: file, api: api))
    }

    var body: some View {
        Group {
            if let error = store.errorMessage {
                ContentUnavailableView("Dokument nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.pdf != nil {
                PDFEditorView(store: store, pencilOnly: pencilOnly).ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView("Lädt…")
            }
        }
        .navigationTitle(store.file.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(store.insertedPages > 0 ? "\(store.status) · \(store.insertedPages) eingefügte Seiten nur im Browser" : store.status)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { pencilOnly.toggle() } label: {
                    Label(pencilOnly ? "Nur Stift" : "Finger zeichnet", systemImage: pencilOnly ? "applepencil" : "hand.draw")
                }
            }
        }
        .task { await store.load() }
        .onDisappear { Task { await store.sync() } }
    }
}

struct PDFEditorView: UIViewControllerRepresentable {
    let store: DocumentStore
    let pencilOnly: Bool

    func makeUIViewController(context: Context) -> PDFEditorController {
        let vc = PDFEditorController(store: store)
        vc.pencilOnly = pencilOnly
        return vc
    }

    func updateUIViewController(_ vc: PDFEditorController, context: Context) {
        if vc.pencilOnly != pencilOnly { vc.pencilOnly = pencilOnly }
    }
}
