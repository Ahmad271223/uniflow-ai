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
    /// Datei inzwischen geladen ("Jetzt laden", `FileLoadPanel`): die Bibliothek liest sie neu
    var onLoaded: (() async -> Void)? = nil
    /// "Jetzt laden" hat die Datei geholt (fuer eine Datei, die sich nicht im Editor oeffnet: Vorschau)
    @State private var loadedHere = false
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
            } else if file.downloaded_at == nil, !loadedHere, problem == nil {
                // gelistet, aber nicht geladen: beim Oeffnen sofort laden statt "der naechste Abgleich" (07.11.2026)
                FileLoadPanel(file: file) {
                    loadedHere = true
                    await onLoaded?()
                    if preview == nil, file.kind != "pdf" { await open() }
                }
            } else if loadedHere, problem == nil {
                // geladen, die Bibliothek liest gerade neu und wechselt gleich in den Editor: bis dahin nichts zeigen
                // (vorher blitzte hier die Meldung "noch nicht auf diesem iPad" auf, Befund iPad 08.11.2026)
                UF.bg.ignoresSafeArea()
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

/// Reiter der geoeffneten Dokumente per Tastatur (Mac, iPad mit Tastatur): Ctrl-Tab bzw. Cmd-Option-Pfeil wechselt zum
/// naechsten bzw. vorherigen Reiter, nach dem letzten wieder zum ersten
enum DocumentTabs {
    static func neighbor(of current: String?, in tabs: [String], step: Int) -> String? {
        guard let first = tabs.first else { return nil }
        guard let current, let i = tabs.firstIndex(of: current) else { return first }
        guard tabs.count > 1 else { return nil }
        let n = tabs.count
        return tabs[((i + step) % n + n) % n]
    }
}

struct LibraryView: View {
    @EnvironmentObject private var session: Session
    /// Dialog "Wohin?" beim PDF-Import
    @EnvironmentObject private var overlay: UFOverlay
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
    /// wird gerade frisch nachgelesen (`ensureFresh`): bis dahin nichts zeigen
    @State private var checking: Set<String> = []
    /// Dokument ist zum Abpausen eingefroren: keine Reiter darueber (Papier darf nichts antippen)
    @State private var editorTracing = false

    init(openFile: String? = nil, openPage: Int? = nil, openTask: Int? = nil) {
        self.openFile = openFile
        self.openPage = openPage
        self.openTask = openTask
        // Mit Ziel-Dokument ist es vom ersten Bild an ausgewaehlt: bis seine Zeile aus der Datenbank da ist, bleibt die
        // Flaeche leer - vorher stand fuer einen Moment "Dokument wählen" (Befund iPad 08.11.2026, Build 24)
        _fileSelection = State(initialValue: openFile)
        _openTabs = State(initialValue: openFile.map { [$0] } ?? [])
        _columns = State(initialValue: openFile == nil ? .all : .detailOnly)
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

    /// Eintrag der Liste; ein einzeln frisch gelesener Eintrag (`extra`) gilt vor einem veralteten Listeneintrag,
    /// der die Datei noch als nicht geladen fuehrt
    private func file(_ id: String) -> LibFile? {
        let listed = library?.files.first { $0.id == id }
        // der einzeln gelesene Eintrag ist immer juenger als die Liste: er gilt, sobald er geladen ist
        if let fresh = extra[id], fresh.downloaded_at != nil || listed == nil { return fresh }
        return listed ?? extra[id]
    }

    /// Die Liste der Bibliothek kann veraltet sein: der Abgleich laedt Dateien, nachdem die Liste gelesen wurde.
    /// Fuehrt sie die Datei als nicht geladen, einmal frisch nachsehen, bevor die Datei-Ansicht "nicht geladen"
    /// erscheint (Befund iPad 08.11.2026: blitzte bei schon geladenen Dateien vor dem Dokument auf)
    private func ensureFresh(_ id: String) async {
        guard file(id)?.downloaded_at == nil else { checking.remove(id); return }
        checking.insert(id)
        await loadSingle(id)
        checking.remove(id)
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
            .navigationTitle("StudiNow")
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
            .background {
                Button("") { Task { await load() } }                  // Mac und Tastatur: Cmd-R wie Ziehen zum Aktualisieren
                    .keyboardShortcut("r", modifiers: .command).opacity(0).accessibilityHidden(true)
            }
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
                if !openTabs.isEmpty, !editorTracing { tabStrip }
                if let id = fileSelection, checking.contains(id) {
                    UF.bg
                } else if let id = fileSelection, let f = file(id), let api = session.api {
                    if f.opensInEditor {
                        // Identitaet je Datenquelle: beim Wechsel lokal <-> Server entsteht der DocumentStore neu fuer
                        // die neue Quelle (updateAPI uebernimmt nur Verbindungen derselben Quelle)
                        DocumentView(file: f, api: api, initialPDFPage: f.id == openFile ? openPage : nil,
                                     task: f.id == openFile ? openTask : nil).id("\(api.namespace.id)/\(f.id)")
                    } else if f.opensAsText {
                        // Word, PowerPoint, Audio: Text je Seite mit KI-Hilfe daneben statt nur der Vorschau (docs/DATEIARTEN.md)
                        TextDocumentView(file: f, api: api).id("\(api.namespace.id)/\(f.id)")
                            .toolbar { ToolbarItem(placement: .topBarLeading) { UFBackButton(style: .toolbar) } }
                    } else if f.downloaded_at != nil, ZipArchive.isZipName(f.name) {
                        // ZIP (z. B. Uebungsblatt aus Stud.IP/Moodle): als Ordner ansehen und bearbeiten (07.11.2026)
                        ZipFolderView(file: f, api: api).id("\(api.namespace.id)/\(f.id)")
                            .toolbar { ToolbarItem(placement: .topBarLeading) { UFBackButton(style: .toolbar) } }
                    } else {
                        FileOutsideEditorView(file: f, api: api, onLoaded: { await reloadAfterDownload(f.id) })
                            .toolbar { ToolbarItem(placement: .topBarLeading) { UFBackButton(style: .toolbar) } }
                    }
                } else if let id = fileSelection, missing.contains(id) {
                    ContentUnavailableView("Dokument nicht verfügbar", systemImage: "doc.questionmark", description: Text(DocumentOpenText.notFound))
                } else if fileSelection != nil {
                    UF.bg                                     // Eintrag kommt gerade (Einzelabruf): nichts zeigen
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
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            UFBackButton(style: .toolbar)                // schliesst das Dokument dorthin, wo es geoeffnet wurde
                            UFLogoMenu()
                        }
                    }
                }
            }
            .onPreferenceChange(EditorTracingKey.self) { editorTracing = $0 }
            .background { if openTabs.count > 1, !editorTracing { tabKeys } }
            // schmal klappt die Teilung zu einem Stapel mit System-Zurueck zusammen: genau ein Pfeil, unserer (06.11.2026)
            .navigationBarBackButtonHidden(true)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .onChange(of: fileSelection) { _, new in
            guard let new else { return }
            if !openTabs.contains(new) { openTabs.append(new) }
            columns = .detailOnly
            if file(new)?.downloaded_at == nil { checking.insert(new); Task { await ensureFresh(new) } }
            // wie viewDoc im Web: geoeffnet (Zuletzt, gilt als gesehen); Fehler sind egal
            let api = session.api
            Task { _ = try? await api?.value("/api/files/\(new)/opened", method: "POST", body: [:]) }
        }
        // nach jedem Abgleich die Liste neu lesen: Dateien, die der Abgleich geladen hat, gelten sofort als geladen
        .onReceive(NotificationCenter.default.publisher(for: .uniflowSyncFinished)) { _ in Task { await load() } }
        .task {
            guard let o = openFile else { await load(); return }
            // Oeffnen ueber die Kennung (08.11.2026): eine Zeile aus der lokalen Datenbank, dann sofort das Dokument -
            // ohne auf die ganze Dateiliste zu warten. Vorher lud erst die Liste (rund 1.000 Eintraege, neben einem
            // laufenden Abgleich), und solange stand "Dokument wählen" statt des angetippten Dokuments.
            await loadSingle(o)
            fileSelection = o
            columns = .detailOnly
            // wie viewDoc im Web: geoeffnet (Zuletzt, gilt als gesehen); onChange feuert fuer den Startwert nicht
            let api = session.api
            Task { _ = try? await api?.value("/api/files/\(o)/opened", method: "POST", body: [:]) }
            async let list: Void = load()                 // die Liste fuer Seitenleiste und Reiter im Hintergrund
            // Beim Oeffnen ueber eine Route griff `.detailOnly` noch vor dem ersten Bild nicht: die Dokumentliste lag
            // hochkant ueber dem Dokument (und ueber der KI-Hilfe). Nach dem ersten Bild erneut.
            try? await Task.sleep(nanoseconds: 300_000_000)
            columns = .detailOnly
            _ = await list
        }
    }

    /// "Jetzt laden" hat eine nicht geladene Datei geholt: Bibliothek und Einzeleintrag neu, dann oeffnet sie sich im
    /// Editor (PDF) bzw. in der passenden Ansicht
    private func reloadAfterDownload(_ id: String) async {
        await load()
        if extra[id] != nil { await loadSingle(id) }
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

    /// Mac und iPad mit Tastatur: naechster/vorheriger Reiter (Ctrl-Tab wie in Safari, Cmd-Option-Pfeil); auf dem iPad
    /// wechselt man durch Antippen des Reiters
    private var tabKeys: some View {
        ZStack {
            Button("") { switchTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("") { switchTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("") { switchTab(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("") { switchTab(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func switchTab(_ step: Int) {
        if let next = DocumentTabs.neighbor(of: fileSelection, in: openTabs, step: step) { fileSelection = next }
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

    /// PDF aus "Dateien": pruefen, dann "Wohin?" wie fuer Dateien von aussen (11.11.2026; vorher immer ohne Ordner).
    /// Nach dem Import oeffnet der Dialog das Dokument.
    private func importPDF(_ result: Result<URL, Error>) async {
        do {
            let staged = try await ExternalFileImport.stageDetached(try result.get(), kind: .pdf)
            ExternalImportInbox.receive([staged], overlay: overlay)
        } catch {
            importMessage = "Import fehlgeschlagen: \(ExternalFileImport.message(error))"
        }
    }
}
