import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore

// MARK: - Editor nur am iPad

/// Wo der Editor (Schreiben auf PDFs: Stift, Werkzeuge, Lasso, Schreiblupe, Notizbuecher, Uebung und Skript
/// nebeneinander) zur Verfuegung steht. Vorgabe des Inhabers 11.11.2026: auf dem iPhone kein Editor, Dokumente nur
/// ansehen (oeffnen, lesen, zoomen, suchen) – auf dem iPad geschriebene Notizen werden angezeigt. Eine Geraetefrage
/// (nicht nach Platz): ein iPad im schmalen Split View behaelt den Editor.
enum UFEditorAvailability {
    /// Tests: die iPhone-Fassung auf dem iPad-Simulator erzwingen bzw. abschalten (nil = nach Geraet)
    nonisolated(unsafe) static var forcedReaderOnlyForTesting: Bool?

    /// Leseansicht statt Editor (iPhone)
    static var readerOnly: Bool { forcedReaderOnlyForTesting ?? UFDevice.isPhone }

    /// Editor auf diesem Geraet (iPad und Mac ja, iPhone nein)
    static var available: Bool { !readerOnly }

    /// Satz fuer Stellen, an denen am iPad geschrieben wird
    static let writeOnIPad = "Schreiben auf Dokumenten geht in der iPad-App. Hier kannst du lesen, zoomen und suchen – deine Notizen vom iPad werden angezeigt."
    static let notebookOnIPad = "Notizbücher und Whiteboards legst du in der iPad-App an. Hier kannst du sie lesen."
}

// MARK: - Leseansicht

/// iPhone-Leseansicht eines PDFs oder Notizbuchs: Seiten mit den Notizen (Handschrift, Text, Formen, Bilder) aus dem
/// Notizmodell, Zoomen und Blaettern wie in PDFKit, Suche in PDF und Notizen, Seite waehlen, KI-Hilfe als Blatt. Nichts
/// davon schreibt: der `DocumentStore` wird nur gelesen und mit `closeAfterReading` freigegeben (kein Abgleich beim
/// Schliessen, kein Eintrag im Versionsverlauf). Notizen anderer Geraete kommen ueber den Abgleich des Stores herein
/// (Notizen-Abgleich mit StudiNow-Konto) und erscheinen ohne neues Oeffnen.
struct PhoneDocumentReader: View {
    let api: APIClient
    @StateObject private var store: DocumentStore
    @StateObject private var reader = ReaderController()
    /// Seite beim Oeffnen (1-basiert, PDF-Seite; "Weiterlernen" gibt die zuletzt gelesene mit), nil = erste
    let initialPDFPage: Int?
    /// Aufgabe des Lernplans, aus der das Dokument geoeffnet wurde: Knopf "Erledigt" wie am iPad
    let task: Int?
    @State private var taskDone = false
    @State private var showSearch = false
    @State private var showTutor = false
    @State private var goingToPage = false
    @State private var goToText = ""
    @State private var actionError: String?
    @State private var lastPageTask: Task<Void, Never>?
    @AppStorage("uniflow.phoneReader.hintSeen") private var hintSeen = false
    @EnvironmentObject private var router: UFRouter

    init(file: LibFile, api: APIClient, initialPDFPage: Int? = nil, task: Int? = nil) {
        self.api = api
        _store = StateObject(wrappedValue: DocumentStore(file: file, api: api))
        self.initialPDFPage = initialPDFPage
        self.task = task
    }

    static let hintText = UFEditorAvailability.writeOnIPad

    var body: some View {
        VStack(spacing: 0) {
            header
            if !hintSeen { hint }
            content
        }
        .background(UF.bg)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSearch) {
            SearchSheet(store: store, startAt: { reader.pageIndex }) { hit in
                if let sel = hit.selection { reader.show(sel) } else { reader.goToPage(hit.pageIndex) }
            }
            .ufHalfSheet()
        }
        .sheet(isPresented: $showTutor) {
            TutorPanel(fileID: store.file.id, fileName: store.file.displayTitle,
                       page: { store.entry(forPageIndex: reader.pageIndex)?.pdfIndex ?? (reader.pageIndex + 1) },
                       selection: { reader.selectionText },
                       open: { id, page in if id == store.file.id { reader.goToPDFPage(page, store: store) } },
                       close: { showTutor = false }, moduleID: store.file.module_id, inSheet: true)
                .ufHalfSheet()
        }
        .alert("Zu Seite", isPresented: $goingToPage) {
            TextField("Seite", text: $goToText).keyboardType(.numberPad)
            Button("Abbrechen", role: .cancel) {}
            Button("Öffnen") {
                if let n = Int(goToText), n >= 1 { reader.goToPage(min(n, reader.pageCount) - 1) }
            }
        } message: { Text("1 bis \(reader.pageCount)") }
        .alert("Hinweis", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .task {
            await store.load()
            // KI-Start "Im Dokument mit KI-Hilfe öffnen": die KI-Hilfe gleich offen (einmalig, nur fuer diese Datei)
            if router.takeTutorOpenRequest(for: store.file.id) { showTutor = true }
        }
        .onChange(of: store.layoutVersion) { _, _ in openAtStart() }
        .onChange(of: reader.pageIndex) { _, page in rememberPage(page) }
        .onAppear { store.setShown(true) }
        .onDisappear {
            store.setShown(false)
            lastPageTask?.cancel()
            Task { await store.closeAfterReading() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneReader")
    }

    // MARK: Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                UFBackButton(compact: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.file.displayTitle).ufFont(14.5, 650, lh: 1.25).foregroundStyle(UF.text).lineLimit(2)
                        .accessibilityIdentifier("phoneReader.title")
                    if let subject = store.file.subject, !subject.isEmpty {
                        Text(subject).ufFont(12, lh: 1.3).foregroundStyle(UF.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                pageLabel
                Spacer(minLength: 4)
                UFButton(nil, icon: "search", kind: .ghost, size: .small) { showSearch = true }
                    .disabled(store.layout == nil)
                    .accessibilityLabel("Suchen").accessibilityIdentifier("phoneReader.search")
                if task != nil {
                    UFButton(nil, icon: "check", kind: taskDone ? .primary : .ghost, size: .small) {
                        Task { await markTaskDone() }
                    }
                    .disabled(taskDone)
                    .accessibilityLabel(taskDone ? "Erledigt" : "Aufgabe als erledigt markieren")
                    .accessibilityIdentifier("phoneReader.done")
                }
                UFButton("KI-Hilfe", icon: "sparkles", kind: showTutor ? .primary : .normal, size: .small) { showTutor = true }
                    .disabled(store.layout == nil)
                    .accessibilityIdentifier("phoneReader.tutor")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(UF.surface)
        .ufBorderBottom()
    }

    @ViewBuilder private var pageLabel: some View {
        if reader.pageCount > 0 {
            Button { goToText = ""; goingToPage = true } label: {
                Text("Seite \(reader.pageIndex + 1) von \(reader.pageCount)")
                    .ufFont(12.8, 600).foregroundStyle(UF.text2).monospacedDigit()
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Seite \(reader.pageIndex + 1) von \(reader.pageCount)")
            .accessibilityHint("Andere Seite öffnen")
            .accessibilityIdentifier("phoneReader.page")
        }
    }

    private var hint: some View {
        HStack(alignment: .top, spacing: 10) {
            UFIcon("pen", size: 15).foregroundStyle(UF.accentText).padding(.top, 2)
            Text(Self.hintText).ufFont(12.8, lh: 1.4).foregroundStyle(UF.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { hintSeen = true } label: {
                UFIcon("x", size: 13).foregroundStyle(UF.muted).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hinweis ausblenden")
            .accessibilityIdentifier("phoneReader.hint.close")
        }
        .padding(.leading, 16).padding(.vertical, 4)
        .background(UF.accentSoft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneReader.hint")
    }

    // MARK: Inhalt

    @ViewBuilder private var content: some View {
        if let message = store.errorMessage {
            ContentUnavailableView("Dokument nicht geöffnet", systemImage: "doc.questionmark", description: Text(message))
        } else if store.layout != nil {
            ReaderPDFView(store: store, reader: reader)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("phoneReader.pdf")
        } else {
            ProgressView("Dokument wird geöffnet …").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Nach dem Laden (und nach einem neuen Seitenaufbau): Sprung zur gewuenschten bzw. zuletzt gelesenen Seite
    private func openAtStart() {
        guard !reader.positioned, store.layout != nil else { return }
        reader.positioned = true
        if let p = initialPDFPage { reader.goToPDFPage(p, store: store) }
    }

    /// zuletzt gelesene Seite merken (`last_page`, wie am iPad), entprellt
    private func rememberPage(_ index: Int) {
        guard !store.isOldVersion, store.layout != nil else { return }
        let page = store.entry(forPageIndex: index)?.pdfIndex ?? (index + 1)
        lastPageTask?.cancel()
        let id = store.file.id
        lastPageTask = Task { [api, router] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            router.resume.notePage(page, of: id)          // Weitermachen wie zuvor (ResumeState.swift)
            _ = try? await api.value("/api/files/\(id)/opened", method: "POST", body: ["last_page": .number(Double(page))])
        }
    }

    private func markTaskDone() async {
        guard let task else { return }
        do {
            _ = try await api.value("/api/tasks/\(task)/status", method: "POST", body: ["status": "erledigt"])
            taskDone = true
        } catch {
            actionError = "Aufgabe ließ sich nicht abhaken: \(error.localizedDescription)"
        }
    }
}

// MARK: - PDF-Anzeige ohne Schreiben

/// Zustand der Leseansicht (Seite, Seitenzahl, Auswahl) und Zugriff auf die PDF-Ansicht
@MainActor
final class ReaderController: ObservableObject {
    @Published var pageIndex = 0
    @Published var pageCount = 0
    /// schon an die Startseite gesprungen
    var positioned = false
    weak var pdfView: PDFView?

    var selectionText: String {
        pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func goToPage(_ index: Int) {
        guard let pdf = pdfView?.document, let page = pdf.page(at: max(0, min(index, pdf.pageCount - 1))) else { return }
        pdfView?.go(to: page)
    }

    /// PDF-Seite (1-basiert) in die angezeigte Seite umrechnen (eingefuegte Seiten verschieben die Zaehlung)
    func goToPDFPage(_ page: Int, store: DocumentStore) {
        guard let layout = store.layout else { return }
        let index = layout.entries.firstIndex { $0.pdfIndex == page } ?? (page - 1)
        goToPage(index)
    }

    func show(_ selection: PDFSelection) {
        pdfView?.highlightedSelections = [selection]
        pdfView?.go(to: selection)
    }
}

/// PDFKit-Ansicht mit einer Notizschicht je Seite (`PageInkView` wie im Editor, aber ohne Eingabe): Zoomen mit zwei
/// Fingern, Blaettern durch Wischen, Text markieren und kopieren. Die Zeichenflaeche nimmt keine Beruehrungen an.
struct ReaderPDFView: UIViewRepresentable {
    @ObservedObject var store: DocumentStore
    let reader: ReaderController

    func makeCoordinator() -> Coordinator { Coordinator(store: store, reader: reader) }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.autoScales = true
        v.backgroundColor = UIColor(UF.bg)
        v.pageShadowsEnabled = true
        v.pageOverlayViewProvider = context.coordinator
        context.coordinator.attach(v)
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        context.coordinator.show(layoutVersion: store.layoutVersion)
    }

    @MainActor
    final class Coordinator: NSObject, PDFPageOverlayViewProvider {
        let store: DocumentStore
        let reader: ReaderController
        private weak var pdfView: PDFView?
        private var shownVersion = -1
        private var live: [Int: PageInkView] = [:]
        private var observers: [NSObjectProtocol] = []

        init(store: DocumentStore, reader: ReaderController) {
            self.store = store
            self.reader = reader
        }

        func attach(_ v: PDFView) {
            pdfView = v
            reader.pdfView = v
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageChanged() }
            })
            observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: v, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scaleChanged() }
            })
            // Notizen anderer Geraete (Abgleich): betroffene Seiten neu laden
            store.onPagesChanged = { [weak self] keys in
                Task { @MainActor in self?.reload(keys: keys) }
            }
            show(layoutVersion: store.layoutVersion)
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func show(layoutVersion: Int) {
            guard let v = pdfView, let layout = store.layout, layoutVersion != shownVersion else { return }
            let keep = reader.pageIndex
            shownVersion = layoutVersion
            live = [:]
            v.document = layout.pdf
            reader.pageCount = layout.pdf.pageCount
            if keep > 0, let page = layout.pdf.page(at: min(keep, layout.pdf.pageCount - 1)) { v.go(to: page) }
            pageChanged()
        }

        private func pageChanged() {
            guard let v = pdfView, let doc = v.document, let page = v.currentPage else { return }
            reader.pageIndex = doc.index(for: page)
        }

        private var screenScale: CGFloat { pdfView?.window?.screen.scale ?? UIScreen.main.scale }

        private var renderScale: CGFloat {
            PDFEditorController.renderScale(screen: screenScale, zoom: pdfView?.scaleFactor ?? 1)
        }

        private func scaleChanged() {
            let s = renderScale
            for o in live.values { o.setRenderScale(s, screen: screenScale) }
        }

        // MARK: PDFPageOverlayViewProvider

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let doc = view.document, doc === store.layout?.pdf else { return nil }
            let index = doc.index(for: page)
            if let existing = live[index] { return existing }
            guard let key = store.layout?.key(at: index) else { return nil }
            let box = page.bounds(for: .cropBox).size
            let overlay = PageInkView(pageIndex: index, pageKey: key, generation: shownVersion,
                                      geometry: PageGeometry(boxSize: box, rotation: page.rotation))
            overlay.isUserInteractionEnabled = false
            overlay.canvas.isUserInteractionEnabled = false
            overlay.canvas.drawingGestureRecognizer.isEnabled = false
            overlay.setRenderScale(renderScale, screen: screenScale)
            live[index] = overlay
            load(overlay)
            return overlay
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let overlay = overlayView as? PageInkView else { return }
            overlay.loadTask?.cancel()
            if live[overlay.pageIndex] === overlay { live.removeValue(forKey: overlay.pageIndex) }
        }

        private func reload(keys: [String]) {
            for o in live.values where keys.contains(o.pageKey) { load(o) }
        }

        private func load(_ overlay: PageInkView) {
            overlay.loadTask?.cancel()
            overlay.loadTask = Task { @MainActor [weak self, weak overlay] in
                guard let self, let overlay else { return }
                let entry = self.store.entry(forKey: overlay.pageKey)
                let objects = await self.store.objects(forPageKey: overlay.pageKey)
                guard !Task.isCancelled else { return }
                overlay.objectsView.show(template: entry?.template, placeholder: nil, objects: objects, images: self.store.images)
                for o in objects where o["type"]?.string == "image" {
                    if let src = o["src"]?.string, self.store.images[src] == nil {
                        self.store.loadImage(src) { [weak self, weak overlay] in
                            guard let self, let overlay else { return }
                            overlay.objectsView.update(images: self.store.images)
                        }
                    }
                }
                let drawing = await self.store.drawing(forPageKey: overlay.pageKey)
                guard !Task.isCancelled else { return }
                overlay.isApplyingDrawing = true
                overlay.canvas.drawing = drawing
                overlay.isApplyingDrawing = false
                overlay.loaded = true
                overlay.loadTask = nil
            }
        }
    }
}
