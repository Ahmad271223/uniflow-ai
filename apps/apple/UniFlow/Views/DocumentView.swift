import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import UniformTypeIdentifiers

// MARK: - Dokument

/// Verbindung zwischen SwiftUI-Leisten und dem UIKit-Editor.
@MainActor
final class EditorBridge: ObservableObject {
    weak var controller: PDFEditorController?
    @Published var zoomPercent = 100
    @Published var pageIndex = 0
    @Published var pageKey: String?

    func undo() { controller?.undo() }
    func redo() { controller?.redo() }
    func fitWidth() { controller?.fitWidth() }
}

/// Eine Werkzeugpalette und ein Rueckgaengig-Verlauf fuer beide Seiten der geteilten Ansicht.
@MainActor
final class ToolPickerHolder: ObservableObject {
    let picker = PKToolPicker()
    let undo = UndoManager()
}

/// Vorlagen fuer neue Seiten (gleiche Namen wie TEMPLATES im Web-Editor).
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
    /// Hinweis ueber dem Teilen-Menue (z. B. fehlende Bilder).
    var notice: String? = nil
}

/// Blaetter rund um "Lösung teilen".
enum SolutionSheet: Identifiable, Equatable {
    case share
    case shared
    /// Vorschau einer empfangenen Loesung (Loesungs-ID)
    case preview(String)
    /// Loesungen aus der Community zu dieser PDF (Fingerabdruck)
    case community(String)
    /// Free: Sperrkarte mit Weg zur Abo-Seite
    case locked

    var id: String {
        switch self {
        case .share: return "share"
        case .shared: return "shared"
        case .preview(let id): return "preview-" + id
        case .community(let fp): return "community-" + fp
        case .locked: return "locked"
        }
    }
}

/// Zweites Dokument der geteilten Ansicht (meist das Skript zur Uebung).
struct Companion: Identifiable, Equatable {
    let file: LibFile
    /// PDF-Seite (1-basiert, wie von /api/related geliefert), `nil` = Anfang.
    let pdfPage: Int?
    var id: String { file.id }
}

/// Vorschlag der Skriptsuche (`POST /api/related`), ohne KI-Aufruf.
struct ScriptSuggestion: Equatable {
    let fileID: String
    let title: String
    let page: Int
    let terms: [String]
    let forPage: Int
}

struct DocumentView: View {
    let api: APIClient
    @StateObject private var store: DocumentStore
    @StateObject private var bridge = EditorBridge()
    @StateObject private var tools = ToolPickerHolder()
    @AppStorage("uniflow.pencilOnly") private var pencilOnly = true
    @AppStorage("uniflow.hand") private var hand = "right"
    @AppStorage("uniflow.splitFraction") private var splitFraction = 0.42
    @State private var fullScreen = false
    @State private var showSidebar = false
    @State private var showSearch = false
    @State private var showInfo = false
    @State private var showTrash = false
    @State private var choosingCompanion = false
    @State private var addingText = false
    @State private var newText = ""
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var actionError: String?
    @State private var companion: Companion?
    @State private var suggestion: ScriptSuggestion?
    /// Skriptsuche gescheitert (Fehlerantwort, Server nicht erreichbar): Hinweis statt stillem Ausbleiben
    @State private var suggestionError: String?
    @State private var dismissedSuggestions: Set<Int> = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var suggestionCache: [Int: ScriptSuggestion?] = [:]
    /// PDF-Export (privat) wartet auf die Bestaetigung des Hinweises
    @State private var pendingExport: ShareScope?
    @State private var solutionSheet: SolutionSheet?
    @State private var importingSolution = false
    /// "Meine Notizen" sichtbar; ausgeblendet = nur ansehen
    @State private var ownNotesVisible = true
    /// passende empfangene Loesungen (nur Anzeige)
    @State private var foreignLayers: [ForeignSolutionLayer] = []
    /// passende, aber nicht lesbare Loesungen (im Ebenen-Menue entfernbar)
    @State private var foreignProblems: [SolutionLayerLoad.Problem] = []
    /// Treffer aus der Community zu dieser PDF (beim Oeffnen geholt, je Sitzung zwischengespeichert, nie blockierend)
    @State private var communityMatches: [CommunitySolutionSummary] = []
    @State private var communityFingerprint: String?
    @State private var communityBannerDismissed = false
    @ObservedObject private var entitlements = Entitlements.shared
    /// gesperrte Plus-Funktion, deren Sperrkarte gerade offen ist (Schreiben, geteilte Ansicht)
    @State private var lockedFeature: UFFeature?
    /// geoeffnete alte Fassung (S7, nur zum Ansehen)
    @State private var openedVersion: FileVersionInfo?
    /// alte Original-Fassung: nur ansehen (S7)
    let readOnly: Bool
    /// PDF-Seite beim Oeffnen (1-basiert, Treffer der Suche), nil = wie zuletzt
    let initialPDFPage: Int?
    /// Aufgabe des Lernplans, aus der das Dokument geoeffnet wurde: Knopf "Erledigt" wie im Web (views-doc.js)
    let task: Int?
    @State private var taskDone = false
    /// zuletzt gelesene Seite merken (`last_page`, wie onPage im Web), entprellt
    @State private var lastPageTask: Task<Void, Never>?

    init(file: LibFile, api: APIClient, readOnly: Bool = false, initialPDFPage: Int? = nil, task: Int? = nil) {
        self.api = api
        self.readOnly = readOnly
        self.initialPDFPage = initialPDFPage
        self.task = task
        _store = StateObject(wrappedValue: DocumentStore(file: file, api: api))
    }

    /// PDF-Seite (1-basiert) der angezeigten Seite, nil fuer eingefuegte Seiten
    private func pdfPage(at index: Int) -> Int? { store.entry(forPageIndex: index)?.pdfIndex }

    /// Seite gewechselt: nach 0,8 s Ruhe als zuletzt gelesene Seite speichern (POST /api/files/{id}/opened). Als
    /// PDF-Seite, so wie "Weiterlernen" sie wieder oeffnet (`initialPDFPage`)
    private func rememberPage(_ index: Int) {
        guard !readOnly, !store.isOldVersion, let page = pdfPage(at: index) else { return }
        lastPageTask?.cancel()
        let api = self.api, id = store.file.id
        lastPageTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            _ = try? await api.value("/api/files/\(id)/opened", method: "POST", body: ["last_page": .number(Double(page))])
        }
    }

    /// "Erledigt": Aufgabe abhaken (POST /api/tasks/{id}/status), danach zeigt der Knopf den Stand
    private func markTaskDone() async {
        guard let task else { return }
        do {
            _ = try await api.value("/api/tasks/\(task)/status", method: "POST", body: ["status": "erledigt"])
            taskDone = true
        } catch {
            actionError = "Aufgabe ließ sich nicht abhaken: \(error.localizedDescription)"
        }
    }

    /// Skript auf der Seite der freien Hand: Rechtshaender -> links.
    private var scriptLeft: Bool { hand != "left" }

    /// Schreiben mit dem Pencil, Seiten und Lesezeichen nur mit Plus; Free und nach dem Herabstufen nur ansehen
    /// (Notizen bleiben sichtbar und exportierbar, docs/AUFTRAG-APPSTORE-V1.md Abschnitt 4)
    private var canWrite: Bool { planAllowsWriting && !readOnly && !store.outdatedByNewVersion }

    /// Tarif mit Schreiben (sonst Schloss mit Weg zur Abo-Seite)
    private var planAllowsWriting: Bool { entitlements.notes.canEdit }

    private var isExercise: Bool {
        let f = store.file
        if ["uebung", "loesung", "klausur"].contains(f.doc_type ?? "") { return true }
        let text = (f.name + " " + (f.studip_folder ?? "")).lowercased()
        return ["übung", "uebung", "blatt", "aufgabe"].contains { text.contains($0) }
    }

    var body: some View {
        Group {
            if let error = store.errorMessage {
                ContentUnavailableView("Dokument nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.pdf != nil {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        if showSidebar {
                            PageSidebar(store: store, bridge: bridge).frame(width: 200)
                            Divider()
                        }
                        if let c = companion, scriptLeft {
                            companionPane(c).frame(width: geo.size.width * splitFraction)
                            splitHandle(width: geo.size.width)
                        }
                        primaryPane
                        if let c = companion, !scriptLeft {
                            splitHandle(width: geo.size.width)
                            companionPane(c).frame(width: geo.size.width * splitFraction)
                        }
                    }
                    .coordinateSpace(NamedCoordinateSpace.named("split"))
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
        .sheet(isPresented: $showTrash) { PageTrashSheet(bridge: bridge) }
        .onChange(of: ObjectIdentifier(api)) { _, _ in Task { await store.updateAPI(api) } }
        .sheet(isPresented: $choosingCompanion) {
            CompanionPicker(api: api, moduleID: store.file.module_id, excluding: store.file.id) { f in
                companion = Companion(file: f, pdfPage: nil)
            }
        }
        .sheet(item: $solutionSheet) { sheet in solutionSheetView(sheet) }
        .sheet(item: $lockedFeature) { f in UFLockedSheet(f) { lockedFeature = nil } }
        .fullScreenCover(item: $openedVersion) { v in
            NavigationStack {
                DocumentView(file: store.oldVersionFile(v), api: api, readOnly: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Schließen") { openedVersion = nil } }
                    }
            }
        }
        .fileImporter(isPresented: $importingSolution, allowedContentTypes: [Self.solutionType]) { result in
            importSolution(result)
        }
        .ufModal(isPresented: Binding(get: { pendingExport != nil }, set: { if !$0 { pendingExport = nil } })) {
            if let scope = pendingExport {
                PDFExportNoticeDialog(scope: scope, export: {
                    pendingExport = nil
                    share(scope)
                }, cancel: { pendingExport = nil })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .uniflowSolutionsChanged)) { _ in
            Task { await reloadSolutionLayers() }
        }
        .onChange(of: entitlements.plan) { _, _ in Task { await reloadSolutionLayers() } }
        .sheet(item: $exportFile) { f in
            VStack(spacing: 0) {
                if let notice = f.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                }
                ActivityView(items: [f.url])
            }
        }
        .alert("Text hinzufügen", isPresented: $addingText) {
            TextField("Text", text: $newText)
            Button("Hinzufügen") {
                let text = newText
                newText = ""
                // ausgeblendete eigene Notizen oder Free = nur ansehen (der Store weist es ebenfalls ab)
                if ownNotesVisible, canWrite, let key = bridge.pageKey { Task { await store.addText(text, pageKey: key) } }
            }
            Button("Abbrechen", role: .cancel) { newText = "" }
        } message: { Text("Erscheint oben links auf der aktuellen Seite und ist im Browser bearbeitbar.") }
        .alert("Hinweis", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .onChange(of: bridge.pageIndex) { _, page in
            scheduleSuggestion(page)
            rememberPage(page)
        }
        .task {
            await store.load()
            scheduleSuggestion(bridge.pageIndex)
            await reloadSolutionLayers()
            await loadCommunityMatches()
        }
        .onDisappear {
            suggestionTask?.cancel()
            Task { await store.pause() }       // Tabwechsel: weiter synchronisieren; endgueltig beendet beim Schliessen
        }
    }

    private var primaryPane: some View {
        PDFEditorView(store: store, bridge: bridge, pencilOnly: pencilOnly, layoutVersion: store.layoutVersion,
                      toolPicker: tools.picker, ownsToolPicker: true, undoManager: tools.undo, initialPDFPage: initialPDFPage,
                      foreignLayers: foreignLayers, ownNotesVisible: ownNotesVisible, canEdit: canWrite)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) { pageInfo }
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    versionBanner
                    communityBanner
                    suggestionBanner
                    // passende Opencast-Aufzeichnung nur bei sicherem Treffer (lokal: der Abgleich des iPads holt sie);
                    // nicht in der alten Fassung (S7, nur ansehen)
                    if api.isLocal, !readOnly, companion == nil, let pdf = store.pdf {
                        RecordingMatchBanner(fileID: store.file.id) { String((pdf.page(at: 0)?.string ?? "").prefix(1500)) }
                    }
                }
            }
    }

    /// Hinweis nach einer neuen Original-Fassung mit Notizen (S7): uebernommen, welche Seiten zu pruefen sind, Weg zur
    /// alten Fassung
    @ViewBuilder
    private var versionBanner: some View {
        if let v = store.versionNotice {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.clock")
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.noticeTitle).font(.caption).bold()
                    if let detail = v.noticeDetail { Text(detail).font(.caption).lineLimit(2) }
                }
                if v.available {
                    Button("Alte Fassung") { openedVersion = v }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button("OK") { Task { await store.dismissVersionNotice() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("versionNotice")
        }
    }

    private func companionPane(_ c: Companion) -> some View {
        CompanionView(file: c.file, api: api, pdfPage: c.pdfPage, toolPicker: tools.picker, undoManager: tools.undo,
                      pencilOnly: pencilOnly, canEdit: canWrite) {
            companion = nil
        }
        .id(c.id + "-" + String(c.pdfPage ?? -1))
    }

    private func splitHandle(width: CGFloat) -> some View {
        ZStack {
            Color(uiColor: .separator).frame(width: 1)
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 44)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: NamedCoordinateSpace.named("split")).onChanged { g in
            let x = g.location.x
            let f = scriptLeft ? x / max(width, 1) : (width - x) / max(width, 1)
            splitFraction = min(0.65, max(0.2, Double(f)))
        })
        .accessibilityLabel("Breite der geteilten Ansicht")
    }

    @ViewBuilder
    private var suggestionBanner: some View {
        if companion == nil, let suggestionError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                Text(suggestionError).font(.caption).lineLimit(2)
                Button { self.suggestionError = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Hinweis ausblenden")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 8)
        } else if companion == nil, let s = suggestion, s.forPage == bridge.pageIndex, !dismissedSuggestions.contains(s.forPage) {
            HStack(spacing: 10) {
                Image(systemName: "book")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Passende Skriptstelle").font(.caption).bold()
                    Text("\(s.title) · Seite \(s.page)").font(.caption).lineLimit(1)
                }
                Button("Daneben öffnen") {
                    if entitlements.allows(.splitView) {
                        companion = Companion(file: libFile(id: s.fileID, title: s.title), pdfPage: s.page)
                    } else {
                        lockedFeature = .splitView
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Button { dismissedSuggestions.insert(s.forPage) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Für diese Seite ausblenden")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 8)
            .help("Gemeinsame Begriffe: \(s.terms.joined(separator: ", "))")
        }
    }

    private func libFile(id: String, title: String) -> LibFile {
        LibFile(id: id, name: title + ".pdf", title: title, kind: "pdf", module_id: store.file.module_id, subject: store.file.subject,
                doc_type: "vorlesung", ai_title: title, sub_label: nil, downloaded_at: "unbekannt", has_notes: nil,
                page_count: nil, studip_folder: nil)
    }

    /// Skriptsuche hoechstens einmal je Seite und erst nach 2,5 s Ruhe (keine Anfrage bei jeder Stiftbewegung).
    private func scheduleSuggestion(_ page: Int) {
        suggestionTask?.cancel()
        guard isExercise, companion == nil else { return }
        if let cached = suggestionCache[page] { suggestion = cached; return }
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let pdfPage = store.entry(forPageIndex: page)?.pdfIndex else { return }
            do {
                let r = try await api.value("/api/related", method: "POST",
                                            body: .object(["file_id": .string(store.file.id), "page": .number(Double(pdfPage))]))
                let hit = r.list("results").first
                let s = hit.flatMap { h -> ScriptSuggestion? in
                    guard let id = h.s("file_id"), let p = h.i("page") else { return nil }
                    return ScriptSuggestion(fileID: id, title: h.s("title") ?? h.s("name") ?? "Skript", page: p,
                                            terms: h.list("terms").compactMap { $0.string }, forPage: page)
                }
                suggestionCache[page] = .some(s)
                if bridge.pageIndex == page { suggestion = s; suggestionError = nil }
            } catch {
                // Skriptsuche gescheitert: einmal sichtbar statt still (die naechste Seite versucht es wieder)
                guard !Task.isCancelled, bridge.pageIndex == page else { return }
                suggestionError = "Skriptsuche nicht möglich: \(error.localizedDescription)"
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { withAnimation { showSidebar.toggle() } } label: { Label("Seiten", systemImage: "sidebar.left") }
            Button { bridge.undo() } label: { Label("Rückgängig", systemImage: "arrow.uturn.backward") }
                .disabled(!canWrite)
            Button { bridge.redo() } label: { Label("Wiederholen", systemImage: "arrow.uturn.forward") }
                .disabled(!canWrite)
            if !planAllowsWriting && !readOnly {
                // Free: Schloss mit Weg zur Abo-Seite statt still nicht schreibender Stift
                Button { lockedFeature = .pencilWriting } label: { Label("Schreiben (Plus)", systemImage: "lock") }
                    .labelStyle(.titleAndIcon)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if task != nil, !readOnly {
                Button { Task { await markTaskDone() } } label: {
                    Label(taskDone ? "Erledigt ✓" : "Erledigt", systemImage: taskDone ? "checkmark.circle.fill" : "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(taskDone)
                .accessibilityIdentifier("doc.task.done")
            }
            StatusLabel(status: store.status)
            SyncIssueBadge(store: store)
            Button { showSearch = true } label: { Label("Suchen", systemImage: "magnifyingglass") }
            Button {
                if companion != nil { companion = nil }
                else if entitlements.allows(.splitView) { choosingCompanion = true }
                else { lockedFeature = .splitView }
            } label: {
                Label(companion == nil ? (entitlements.allows(.splitView) ? "Geteilt" : "Geteilt (Plus)") : "Teilung beenden",
                      systemImage: companion == nil && !entitlements.allows(.splitView) ? "lock" : "rectangle.split.2x1")
            }
            Button { pencilOnly.toggle() } label: {
                Label(pencilOnly ? "Nur Stift" : "Finger zeichnet", systemImage: pencilOnly ? "applepencil" : "hand.draw")
            }
            layersMenu
            Menu {
                // A) privat: Original-PDF mit Notizen (auch in Free), vorher Hinweis auf das Originalmaterial
                Section("PDF exportieren (nur privat)") {
                    Button { pendingExport = .document } label: { Label("Ganzes Dokument", systemImage: "doc.on.doc") }
                    Button { pendingExport = .page(bridge.pageIndex) } label: { Label("Diese Seite", systemImage: "doc") }
                }
                // B) nur eigene Notizen, ohne Original (Plus)
                Section("Nur eigene Notizen") {
                    Button { openSolutionSheet(.share) } label: {
                        Label(entitlements.allows(.community) ? "Lösung teilen …" : "Lösung teilen … (Plus)",
                              systemImage: entitlements.allows(.community) ? "person.2" : "lock")
                    }
                    Button { openSolutionSheet(.shared) } label: { Label("Meine geteilten Lösungen …", systemImage: "tray.full") }
                }
            } label: { Label(exporting ? "Exportiert…" : "Teilen", systemImage: "square.and.arrow.up") }
            .disabled(exporting || store.pdf == nil)
            Menu {
                if !planAllowsWriting && !readOnly {
                    // Free: schreibende Eintraege gesperrt, Schloss fuehrt zur Abo-Seite
                    Button { lockedFeature = .pencilWriting } label: {
                        Label("Schreiben, Seiten und Lesezeichen mit Plus", systemImage: "lock")
                    }
                    Divider()
                } else if !ownNotesVisible {
                    // nur ansehen: schreibende Eintraege sind gesperrt
                    Button { ownNotesVisible = true } label: {
                        Label("Meine Notizen einblenden, um zu bearbeiten", systemImage: "eye")
                    }
                    Divider()
                }
                // schreiben ins eigene Dokument: gesperrt, solange "Meine Notizen" ausgeblendet ist
                Group {
                    Button {
                        if let key = bridge.pageKey {
                            let title = "Seite \(bridge.pageIndex + 1)"
                            Task { await store.toggleBookmark(pageKey: key, title: title) }
                        }
                    } label: {
                        Label(store.isBookmarked(pageKey: bridge.pageKey) ? "Lesezeichen entfernen" : "Lesezeichen setzen", systemImage: "bookmark")
                    }
                    Menu {
                        ForEach(PaperTemplate.choices, id: \.id) { t in
                            // ueber den Editor: Groesse und Schluessel wie im Web, danach springt er zur neuen Seite
                            Button(t.name) { Task { await bridge.controller?.insertBlankPage(after: bridge.pageKey, template: t.id) } }
                        }
                    } label: { Label("Leere Seite danach", systemImage: "doc.badge.plus") }
                    Button(role: .destructive) {
                        Task {
                            if await bridge.controller?.trashPage(key: bridge.pageKey) != true {
                                actionError = "Diese Seite lässt sich nicht in den Papierkorb legen (letzte Seite oder noch nicht geladen)."
                            }
                        }
                    } label: { Label("Seite in den Papierkorb", systemImage: "trash") }
                    Button { showTrash = true } label: { Label("Papierkorb …", systemImage: "trash.slash") }
                    Button {
                        if let key = bridge.pageKey { Task { await store.rotatePage(key: key) } }
                    } label: { Label("Seite drehen", systemImage: "rotate.right") }
                    Button { addingText = true } label: { Label("Text hinzufügen", systemImage: "textformat") }
                }
                .disabled(!ownNotesVisible || !canWrite)
                Divider()
                Button {
                    if entitlements.allows(.community) { importingSolution = true } else { solutionSheet = .locked }
                } label: { Label("Lösung importieren …", systemImage: "square.and.arrow.down") }
                if !store.versions.isEmpty {
                    // S7: aufbewahrte alte Fassungen mit ihren Notizen (nur zum Ansehen)
                    Section("Alte Fassungen") {
                        ForEach(store.versions) { v in
                            Button { openedVersion = v } label: { Label(v.label, systemImage: "doc.badge.clock") }
                                .disabled(!v.available)
                        }
                    }
                }
                Button { showInfo = true } label: { Label("Dokumentinformation", systemImage: "info.circle") }
                Button { fullScreen = true } label: { Label("Vollbild", systemImage: "arrow.up.left.and.arrow.down.right") }
            } label: { Label("Mehr", systemImage: "ellipsis.circle") }
        }
    }

    // MARK: Loesungen (nur eigene Notizen teilen, fremde Loesungen ansehen)

    static var solutionType: UTType { UTType(SolutionPackage.typeIdentifier) ?? .data }

    /// "n Lösungen aus der Community zu diesem Blatt" (nur mit Plus und Treffern)
    @ViewBuilder private var communityBanner: some View {
        if !communityMatches.isEmpty, !communityBannerDismissed, entitlements.allows(.community), let fp = communityFingerprint {
            HStack(spacing: 10) {
                Image(systemName: "person.2")
                Text(CommunityTexts.matches(communityMatches.count)).font(.caption).bold().lineLimit(1)
                Button("Ansehen") { solutionSheet = .community(fp) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { communityBannerDismissed = true } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Hinweis ausblenden")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 8)
        }
    }

    /// Ebenen: eigene Notizen und passende empfangene Loesungen ein-/ausblenden.
    private var layersMenu: some View {
        Menu {
            Button { ownNotesVisible.toggle() } label: {
                Label("Meine Notizen", systemImage: ownNotesVisible ? "checkmark.circle.fill" : "circle")
            }
            if entitlements.allows(.community) {
                Section("Lösungen anderer") {
                    if foreignLayers.isEmpty && foreignProblems.isEmpty {
                        Text("Keine Lösungen zu dieser PDF")
                    }
                    ForEach(foreignProblems) { problem in
                        Menu {
                            Text(problem.message)
                            Button(role: .destructive) { removeProblem(problem) } label: { Label("Entfernen", systemImage: "trash") }
                        } label: {
                            Label("Nicht lesbar: \(problem.label)", systemImage: "exclamationmark.triangle")
                        }
                    }
                    ForEach(foreignLayers) { layer in
                        Menu {
                            Button { setVisible(layer, !layer.visible) } label: {
                                Label(layer.visible ? "Ausblenden" : "Einblenden", systemImage: layer.visible ? "eye.slash" : "eye")
                            }
                            Button { solutionSheet = .preview(layer.id) } label: {
                                Label("Vorschau ohne Original", systemImage: "rectangle.on.rectangle")
                            }
                            Button(role: .destructive) { removeLayer(layer) } label: { Label("Entfernen", systemImage: "trash") }
                        } label: {
                            Label(layer.label, systemImage: layer.visible ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    Button { importingSolution = true } label: { Label("Lösung importieren …", systemImage: "square.and.arrow.down") }
                }
                // nur mit CloudKit-Dienst im Build (sonst kein Platzhalter; die Einstellungen sagen, warum)
                if SolutionSharing.community.isConnected {
                    Section("Community") {
                        Button {
                            if let fp = communityFingerprint { solutionSheet = .community(fp) }
                        } label: {
                            Label(communityMatches.isEmpty ? "Community durchsuchen …" : CommunityTexts.matches(communityMatches.count) + " …",
                                  systemImage: "person.2")
                        }
                        .disabled(communityFingerprint == nil)
                    }
                }
            } else {
                Button { solutionSheet = .locked } label: { Label("Lösungen anderer ansehen (Plus)", systemImage: "lock") }
            }
        } label: { Label("Ebenen", systemImage: "square.3.layers.3d") }
        .disabled(store.pdf == nil)
    }

    private func openSolutionSheet(_ sheet: SolutionSheet) {
        solutionSheet = entitlements.allows(.community) ? sheet : .locked
    }

    @ViewBuilder
    private func solutionSheetView(_ sheet: SolutionSheet) -> some View {
        switch sheet {
        case .share:
            SolutionShareSheet(store: store, api: api) { solutionSheet = nil }
        case .shared:
            SharedSolutionsSheet { solutionSheet = nil }
        case .preview(let id):
            if let layer = foreignLayers.first(where: { $0.id == id }) {
                SolutionPreviewSheet(layer: layer) { solutionSheet = nil }
            }
        case .community(let fp):
            // "Laden und anzeigen" nimmt denselben Weg wie die Datei (fremde Ebene, eigene Notizen unveraendert)
            CommunitySolutionsSheet(fingerprint: fp, service: SolutionSharing.community,
                                    importer: { id in try await store.importFromCommunity(id, service: SolutionSharing.community) },
                                    onImported: { result in Task { await handleImport(result) } }) { solutionSheet = nil }
        case .locked:
            SolutionLockedSheet { solutionSheet = nil }
        }
    }

    /// Passende Loesungen neu laden (nur mit Plus). Passt eine nicht zur PDF, erscheint sie nicht; die Meldung kommt
    /// einmal je Sitzung als Hinweis, danach steht sie im Ebenen-Menue (mit "Entfernen").
    private func reloadSolutionLayers() async {
        guard entitlements.allows(.community), store.pdf != nil else {
            foreignLayers = []
            foreignProblems = []
            return
        }
        let result = await store.solutionLayers()
        foreignLayers = result.layers
        foreignProblems = result.problems
        let unseen = SolutionProblemNotices.unseen(result.problems)
        if !unseen.isEmpty, actionError == nil { actionError = unseen.map(\.text).joined(separator: "\n") }
    }

    /// Treffer aus der Community zu dieser PDF (nur mit Plus und Dienst im Build; Fehler bleiben still, die Liste
    /// zeigt sie beim Oeffnen des Blatts)
    private func loadCommunityMatches() async {
        guard entitlements.allows(.community), store.pdf != nil, !readOnly, let fp = await store.originalFingerprint() else { return }
        communityFingerprint = fp
        guard SolutionSharing.community.isConnected else { return }
        if let cached = CommunityMatches.shared.cached(fp) { communityMatches = cached }
        communityMatches = (try? await CommunityMatches.shared.load(fingerprint: fp, service: SolutionSharing.community)) ?? communityMatches
    }

    private func removeProblem(_ problem: SolutionLayerLoad.Problem) {
        do {
            try SolutionSharing.library.remove(problem.id)
            foreignProblems.removeAll { $0.id == problem.id }
        } catch {
            actionError = "Entfernen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func setVisible(_ layer: ForeignSolutionLayer, _ visible: Bool) {
        try? SolutionSharing.library.setVisible(layer.id, visible)
        if let i = foreignLayers.firstIndex(where: { $0.id == layer.id }) { foreignLayers[i].visible = visible }
    }

    private func removeLayer(_ layer: ForeignSolutionLayer) {
        do {
            try SolutionSharing.library.remove(layer.id)
            foreignLayers.removeAll { $0.id == layer.id }
        } catch {
            actionError = "Entfernen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func importSolution(_ result: Result<URL, Error>) {
        Task {
            do {
                await handleImport(try await store.importSolution(try result.get()))
            } catch {
                actionError = (error as? SolutionError)?.description ?? "Import fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    /// Ergebnis eines Imports (Datei oder Community): Ebenen neu laden bzw. erklaeren, warum nichts erscheint
    private func handleImport(_ result: SolutionImportResult) async {
        switch result {
        case .shown:
            await reloadSolutionLayers()
        case .otherPDF(let entry):
            let label = ForeignSolutionLayer.label(displayName: entry.displayName, createdAt: entry.createdAt)
            actionError = "\(label): \(SolutionError.fingerprintMismatch.description) Sie ist gespeichert und erscheint, sobald du die passende PDF öffnest."
        case .removedUnreadable(let entry, let error):
            let label = ForeignSolutionLayer.label(displayName: entry.displayName, createdAt: entry.createdAt)
            actionError = "\(label): \(SolutionSharing.unreadableImportMessage)\n(\(error.description))"
            await reloadSolutionLayers()
        }
    }

    /// PDF mit Notizen (Ganzes Dokument oder aktuelle Seite) erzeugen und das Teilen-Menue des Systems zeigen.
    private func share(_ scope: ShareScope) {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let payload = try await store.sharePayload(scope, loadImage: ShareExport.serverImageLoader(api))
                exportFile = ExportFile(url: try ShareExport.writeFile(payload), notice: payload.missingImagesNotice)
            } catch {
                actionError = "Teilen fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    private var pageInfo: some View {
        HStack(spacing: 10) {
            Text("Seite \(bridge.pageIndex + 1) / \(store.pdf?.pageCount ?? 0)")
            Divider().frame(height: 14)
            Button("\(bridge.zoomPercent) %") { bridge.fitWidth() }
                .accessibilityHint("Seite einpassen")
            if readOnly {
                Divider().frame(height: 14)
                Label("Alte Fassung – nur ansehen", systemImage: "doc.badge.clock").lineLimit(1)
            } else if store.outdatedByNewVersion {
                Divider().frame(height: 14)
                Label("Neue Fassung angekommen – Dokument neu öffnen", systemImage: "arrow.triangle.2.circlepath").lineLimit(1)
            } else if !planAllowsWriting {
                Divider().frame(height: 14)
                Button { lockedFeature = .pencilWriting } label: {
                    Label("Nur ansehen – Schreiben mit Plus", systemImage: "lock").lineLimit(1)
                }
                .accessibilityHint("Öffnet die Tarifwahl")
            } else if !ownNotesVisible {
                Divider().frame(height: 14)
                Label("Meine Notizen ausgeblendet – nur ansehen", systemImage: "eye.slash").lineLimit(1)
            }
            if foreignLayers.contains(where: \.visible) {
                Divider().frame(height: 14)
                Label("\(foreignLayers.filter(\.visible).count) Lösung(en) eingeblendet", systemImage: "square.3.layers.3d").lineLimit(1)
            }
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

/// Rechte bzw. linke Seite der geteilten Ansicht: eigenes Dokument, eigenes Scrollen und Zoomen,
/// keine eigene Werkzeugpalette (die Palette des Hauptdokuments gilt fuer beide).
struct CompanionView: View {
    let api: APIClient
    @StateObject private var store: DocumentStore
    @StateObject private var bridge = EditorBridge()
    let pdfPage: Int?
    let toolPicker: PKToolPicker
    let undoManager: UndoManager
    let pencilOnly: Bool
    let canEdit: Bool
    let onClose: () -> Void

    init(file: LibFile, api: APIClient, pdfPage: Int?, toolPicker: PKToolPicker, undoManager: UndoManager,
         pencilOnly: Bool, canEdit: Bool = true, onClose: @escaping () -> Void) {
        _store = StateObject(wrappedValue: DocumentStore(file: file, api: api))
        self.api = api
        self.pdfPage = pdfPage
        self.toolPicker = toolPicker
        self.undoManager = undoManager
        self.pencilOnly = pencilOnly
        self.canEdit = canEdit
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(store.file.displayTitle).font(.caption).bold().lineLimit(1)
                Spacer()
                StatusLabel(status: store.status)
                SyncIssueBadge(store: store)
                Text("S. \(bridge.pageIndex + 1)").font(.caption.monospacedDigit())
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Schließen")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            if let error = store.errorMessage {
                ContentUnavailableView("Nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if store.pdf != nil {
                PDFEditorView(store: store, bridge: bridge, pencilOnly: pencilOnly, layoutVersion: store.layoutVersion,
                              toolPicker: toolPicker, ownsToolPicker: false, undoManager: undoManager, initialPDFPage: pdfPage,
                              canEdit: canEdit)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task { await store.load() }
        .onDisappear { Task { await store.pause() } }
        .onChange(of: ObjectIdentifier(api)) { _, _ in Task { await store.updateAPI(api) } }
    }
}

/// Auswahl des zweiten Dokuments (Dokumente desselben Moduls zuerst).
struct CompanionPicker: View {
    let api: APIClient
    let moduleID: Int?
    let excluding: String
    let onPick: (LibFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [LibFile] = []
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(filtered) { f in
                Button {
                    onPick(f)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(f.displayTitle).lineLimit(2)
                        Text([f.subject, f.sub_label].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if let error { ContentUnavailableView("Nicht geladen", systemImage: "wifi.exclamationmark", description: Text(error)) } }
            .searchable(text: $query, prompt: "Skript suchen")
            .navigationTitle("Daneben öffnen")
            .toolbar { Button("Abbrechen") { dismiss() } }
            .task {
                do {
                    let lib = try await api.json("/api/library", as: LibraryResponse.self)
                    files = lib.files.filter { $0.isPDF && $0.id != excluding }
                        .sorted { ($0.module_id == moduleID ? 0 : 1, $0.displayTitle) < ($1.module_id == moduleID ? 0 : 1, $1.displayTitle) }
                } catch let e {
                    error = e.localizedDescription
                }
            }
        }
    }

    private var filtered: [LibFile] {
        let q = query.lowercased()
        return q.isEmpty ? files : files.filter { ($0.displayTitle + " " + $0.name).lowercased().contains(q) }
    }
}

/// Seitenuebersicht (Miniaturen mit Notizen) und Lesezeichen.
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
            ThumbnailStrip(store: store, bridge: bridge)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

/// Seitenminiaturen mit Handschrift, Text und Formen (gleiche Zeichenroutine wie der PDF-Export).
/// Eine Miniatur wird nur neu gezeichnet, wenn sich die Objekte ihrer Seite, ihre geladenen Bilder oder der
/// Seitenaufbau geaendert haben. Geprueft wird beim Erscheinen, beim Seitenwechsel, bei Statuswechseln und in einer
/// kurzen Schleife fuer die sichtbaren Zellen. Die Schleife ist noetig, weil der Speicherstatus offline (bzw. bei
/// localSaveFailed/conflictUnresolved) gleich bleibt, waehrend weitere Striche dazukommen.
struct ThumbnailStrip: View {
    @ObservedObject var store: DocumentStore
    @ObservedObject var bridge: EditorBridge
    @StateObject private var cache = ThumbnailCache()
    @Environment(\.displayScale) private var displayScale

    static let width: CGFloat = 140
    /// Abstand der Pruefschleife (Nanosekunden).
    static let pollInterval: UInt64 = 1_500_000_000

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array((store.layout?.entries ?? []).enumerated()), id: \.element.key) { i, entry in
                        Button { bridge.controller?.goToPage(i) } label: { cell(i, entry) }
                            .buttonStyle(.plain)
                            .id(entry.key)
                            .onAppear { cache.visible.insert(entry.key) }
                            .onDisappear { cache.visible.remove(entry.key) }
                            .task(id: "\(entry.key)|\(store.layoutVersion)") { await refresh(entry.key) }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: bridge.pageIndex) { old, i in
                if let key = store.layout?.key(at: i) { withAnimation { proxy.scrollTo(key, anchor: .center) } }
                // Seite verlassen: dort zuletzt geschrieben, daher sofort pruefen
                if let key = store.layout?.key(at: old) { Task { await refresh(key) } }
            }
        }
        .onChange(of: store.status) { _, _ in Task { await refreshVisible() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                guard !Task.isCancelled else { break }
                await refreshVisible()
            }
        }
    }

    private func refreshVisible() async {
        for key in cache.visible.sorted() { await refresh(key) }
    }

    /// Miniatur einer Seite pruefen (Index aus dem aktuellen Seitenaufbau, er verschiebt sich beim Einfuegen).
    private func refresh(_ key: String) async {
        guard let layout = store.layout, let i = layout.index(ofKey: key), let entry = layout.entry(at: i) else { return }
        let objects = await store.objects(forPageKey: key)
        guard let current = store.layout, current.entry(at: i) == entry, let page = current.pdf.page(at: i) else { return }
        await cache.refresh(key: key, page: page, entry: entry, objects: objects, images: store.images,
                            layoutVersion: store.layoutVersion, width: Self.width, scale: max(1, displayScale))
    }

    private func cell(_ i: Int, _ entry: DisplayLayout.Entry) -> some View {
        let current = i == bridge.pageIndex
        return VStack(spacing: 4) {
            Group {
                if let img = cache.images[entry.key] {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Color.white.aspectRatio(595.0 / 842.0, contentMode: .fit)
                }
            }
            .frame(width: Self.width)
            .overlay(Rectangle().strokeBorder(current ? Color.accentColor : Color(uiColor: .separator), lineWidth: current ? 2 : 1))
            Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(current ? Color.accentColor : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seite \(i + 1)")
        .accessibilityAddTraits(current ? [.isSelected] : [])
    }
}

/// Gezeichnete Miniaturen je Seitenschluessel mit Hash-Signatur des gezeichneten Stands.
/// Signatur und Zeichnen laufen ausserhalb des Hauptthreads (Stifteingabe hat Vorrang); nur das Ergebnis wird hier
/// gesetzt. Hoechstens `limit` Miniaturen bleiben im Speicher (zuletzt benutzte zuerst behalten).
@MainActor
final class ThumbnailCache: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    /// Sichtbare Zellen (Seitenschluessel); nicht veroeffentlicht, damit Scrollen keine Neuberechnung ausloest.
    var visible: Set<String> = []
    let limit: Int
    /// Anzahl gezeichneter Miniaturen (fuer Tests und Diagnose).
    private(set) var renderCount = 0
    private var signatures: [String: Int] = [:]
    private var recent: [String] = []                                            // aeltester zuerst

    init(limit: Int = 60) { self.limit = max(1, limit) }

    /// PDFPage-Kopie fuer das Zeichnen im Hintergrund (das Original gehoert dem Editor auf dem Hauptthread).
    private struct PageBox: @unchecked Sendable { let page: PDFPage }

    /// Signatur des gezeichneten Stands: Seitenaufbau, Seite, Objekte, Quellen der geladenen Bilder.
    nonisolated static func signature(layoutVersion: Int, entry: DisplayLayout.Entry, rotation: Int,
                                      objects: [JSONValue], loadedImages: [String]) -> Int {
        var h = Hasher()
        h.combine(layoutVersion)
        h.combine(entry.key); h.combine(entry.kind); h.combine(entry.template); h.combine(entry.pdfIndex)
        h.combine(rotation)
        h.combine(objects)
        h.combine(loadedImages)
        return h.finalize()
    }

    /// Zeichnet die Miniatur neu, wenn sich die Signatur geaendert hat. `true` = neu gezeichnet.
    @discardableResult
    func refresh(key: String, page: PDFPage, entry: DisplayLayout.Entry, objects: [JSONValue], images: [String: UIImage],
                 layoutVersion: Int, width: CGFloat, scale: CGFloat) async -> Bool {
        // nur Bilder dieser Seite (kleiner Uebergabewert, Signatur aendert sich nur bei eigenen Bildern)
        let srcs = Set(objects.compactMap { $0["type"]?.string == "image" ? $0["src"]?.string : nil })
        let own = images.filter { srcs.contains($0.key) }
        let rotation = page.rotation
        let sig = await Task.detached(priority: .utility) {
            Self.signature(layoutVersion: layoutVersion, entry: entry, rotation: rotation, objects: objects,
                           loadedImages: own.keys.sorted())
        }.value
        guard signatures[key] != sig else { touch(key); return false }
        signatures[key] = sig
        let box = PageBox(page: page.copy() as? PDFPage ?? page)
        let img = await Task.detached(priority: .utility) {
            PageRenderer.thumbnail(page: box.page, entry: entry, objects: objects, images: own, width: width, scale: scale)
        }.value
        guard signatures[key] == sig else { return false }                       // inzwischen neuerer Stand unterwegs
        self.images[key] = img
        renderCount += 1
        touch(key)
        evict()
        return true
    }

    private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }

    /// Aelteste Miniaturen verwerfen (samt Signatur, damit sie beim naechsten Erscheinen neu gezeichnet werden).
    private func evict() {
        while recent.count > limit {
            let old = recent.removeFirst()
            images[old] = nil
            signatures[old] = nil
        }
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

/// Papierkorb der Seiten (deletedPages wie im Web-Editor): neueste zuerst, Wiederherstellen an den frueheren Platz.
struct PageTrashSheet: View {
    @ObservedObject var bridge: EditorBridge
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [PageOrder.TrashedPage]?

    var body: some View {
        NavigationStack {
            List {
                if let pages {
                    if pages.isEmpty { ContentUnavailableView("Papierkorb ist leer", systemImage: "trash") }
                    ForEach(pages.reversed(), id: \.trashIndex) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(p))
                                Text(detail(p)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Wiederherstellen") {
                                Task {
                                    if await bridge.controller?.restorePage(key: p.key) == true { dismiss() } else { await reload() }
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Papierkorb")
            .toolbar { Button("Fertig") { dismiss() } }
            .task { await reload() }
        }
    }

    private func reload() async { pages = await bridge.controller?.trashedPages() ?? [] }

    private func title(_ p: PageOrder.TrashedPage) -> String {
        if p.type == "pdf", let i = p.pdfIndex { return "PDF-Seite \(i)" }
        if p.type == "blank" { return "Leere Seite (\(p.template.flatMap { PaperTemplate.names[$0] } ?? "Leer"))" }
        return "Eingefügte Seite"
    }

    private func detail(_ p: PageOrder.TrashedPage) -> String {
        var parts = ["früher an Stelle \(p.position + 1)"]
        if p.objectCount > 0 { parts.append("\(p.objectCount) Notizen") }
        if let d = p.deletedAt { parts.append(d.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
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

/// Grund, warum gerade nicht gespeichert wird (PIN, Zugriff, Serverfehler, offline) oder Hinweis auf
/// zusammengefuehrte Konflikte; Tippen zeigt "Erneut versuchen" bzw. "Verstanden".
struct SyncIssueBadge: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        if let issue = store.syncIssue {
            Menu {
                if case .konflikteZusammengefuehrt = issue {
                    Button("Verstanden") { Task { await store.acknowledgeSyncNotice() } }
                } else {
                    Button("Erneut versuchen") { Task { await store.retrySync() } }
                }
            } label: {
                Label(issue.label, systemImage: issue.needsUserAction ? "exclamationmark.triangle" : "info.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(issue.needsUserAction ? .red : .orange)
                    .lineLimit(1)
            }
            .accessibilityLabel(issue.label)
        }
    }
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
    var toolPicker: PKToolPicker?
    var ownsToolPicker = true
    var undoManager: UndoManager?
    var initialPDFPage: Int?
    /// fremde Loesungen (nur Anzeige) und Sichtbarkeit der eigenen Notizen
    var foreignLayers: [ForeignSolutionLayer] = []
    var ownNotesVisible = true
    /// Tarif erlaubt Schreiben (Plus); sonst nur ansehen
    var canEdit = true

    func makeUIViewController(context: Context) -> PDFEditorController {
        let vc = PDFEditorController(store: store, toolPicker: toolPicker, ownsToolPicker: ownsToolPicker,
                                     undoManager: undoManager, initialPDFPage: initialPDFPage)
        let bridge = self.bridge
        vc.pencilOnly = pencilOnly
        vc.foreignLayers = foreignLayers
        vc.ownNotesVisible = ownNotesVisible
        vc.canEdit = canEdit
        vc.onZoomChange = { [weak bridge] z in bridge?.zoomPercent = Int((z * 100).rounded()) }
        vc.onPageChange = { [weak bridge] i, key in
            bridge?.pageIndex = i
            bridge?.pageKey = key
        }
        bridge.controller = vc
        return vc
    }

    /// Wird bei jeder SwiftUI-Aktualisierung aufgerufen (z. B. Statuswechsel). Fasst die Canvas nicht an; baut die
    /// Anzeige nur neu auf, wenn sich die Seitenstruktur geaendert hat.
    func updateUIViewController(_ vc: PDFEditorController, context: Context) {
        if vc.pencilOnly != pencilOnly { vc.pencilOnly = pencilOnly }
        if vc.shownLayoutVersion != layoutVersion { vc.showLayout() }
        if vc.foreignSignature != PDFEditorController.signature(foreignLayers) { vc.foreignLayers = foreignLayers }
        if vc.ownNotesVisible != ownNotesVisible { vc.ownNotesVisible = ownNotesVisible }
        if vc.canEdit != canEdit { vc.canEdit = canEdit }
    }
}
