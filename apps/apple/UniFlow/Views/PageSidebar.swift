import PDFKit
import SwiftUI
import UniFlowCore

/// Seitenuebersicht (Miniaturen mit Notizen) und Lesezeichen (Plan EDITOR-GOODNOTES-PLAN, Schritt E):
/// - "+"-Kachel nach der letzten Miniatur: Antippen haengt eine leere Seite wie die letzte an (gleiche Vorlage und
///   Groesse), langes Druecken bietet die Vorlagen an.
/// - Kontextmenue je Miniatur (langes Druecken): Leere Seite davor/danach, Seite drehen, Lesezeichen, "Zur Gliederung"
///   (nur wenn das Dokument schon eine Gliederung hat), Papierkorb. Einfuegen und Papierkorb gehen in den gemeinsamen
///   Rueckgaengig-Verlauf (Palette).
/// - Nur ansehen (`canEdit` aus): keine Kachel, kein Menue.
struct PageSidebar: View {
    @ObservedObject var store: DocumentStore
    @ObservedObject var bridge: EditorBridge
    /// Vorlesungs-Seitenmarker des Dokuments (Kennzeichen "bis hier" an der Miniatur)
    var markers: LectureMarkers?
    /// Schreiben erlaubt (Tarif, eigene Notizen eingeblendet, keine alte Fassung)
    var canEdit = true

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
            ThumbnailStrip(store: store, bridge: bridge, markers: markers, canEdit: canEdit)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

/// Aktionen des Kontextmenues und der "+"-Kachel (reine Entscheidungen ohne Ansicht, fuer Tests)
enum PageSidebarActions {
    /// Vorlage fuer die Seite, die "+" anhaengt: wie die letzte Seite (Leerseite mit Vorlage), sonst leer
    static func appendTemplate(lastEntry: DisplayLayout.Entry?) -> String {
        guard let e = lastEntry, e.kind == "blank", let t = e.template, PaperTemplate.isKnown(t) else { return "blank" }
        return t
    }

    /// Eintraege des Kontextmenues in dieser Reihenfolge (Gliederung nur, wenn es schon eine gibt; Papierkorb nicht
    /// fuer die letzte verbliebene Seite)
    enum Item: Equatable { case insertBefore, insertAfter, rotate, bookmark, outline, trash }

    static func items(hasOutline: Bool, pageCount: Int) -> [Item] {
        var out: [Item] = [.insertBefore, .insertAfter, .rotate, .bookmark]
        if hasOutline { out.append(.outline) }
        if pageCount > 1 { out.append(.trash) }
        return out
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
    var markers: LectureMarkers?
    var canEdit = true
    @StateObject private var cache = ThumbnailCache()
    @Environment(\.displayScale) private var displayScale
    /// Das Dokument hat eine Gliederung ("Zur Gliederung" im Menue)
    @State private var hasOutline = false
    /// "Zur Gliederung": Titel abfragen (Seite, fuer die gefragt wird)
    @State private var outlineKey: String?
    @State private var outlineTitle = ""
    @State private var notice: String?

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
                            .contextMenu { if canEdit { pageMenu(i, entry) } }
                            .onAppear { cache.visible.insert(entry.key) }
                            .onDisappear { cache.visible.remove(entry.key) }
                            .task(id: "\(entry.key)|\(store.layoutVersion)") { await refresh(entry.key) }
                    }
                    if canEdit, store.layout != nil { addTile }
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
        .task(id: store.layoutVersion) { hasOutline = !(await bridge.controller?.outlineEntries() ?? []).isEmpty }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            cache.releaseHidden()                                   // Speicherdruck: nur sichtbare Miniaturen behalten
        }
        .alert("Zur Gliederung hinzufügen", isPresented: Binding(get: { outlineKey != nil }, set: { if !$0 { outlineKey = nil } })) {
            TextField("Titel", text: $outlineTitle)
            Button("Hinzufügen") {
                if let key = outlineKey {
                    let title = outlineTitle
                    Task { await bridge.controller?.addOutline(title: title, key: key); hasOutline = true }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Erscheint unter „Gliederung“ und im Browser in der Seitenleiste.") }
        .alert("Hinweis", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(notice ?? "") }
    }

    // MARK: "+"-Kachel

    /// Leere Seite wie die letzte anhaengen; langes Druecken: Vorlage waehlen
    private var addTile: some View {
        Button { append(PageSidebarActions.appendTemplate(lastEntry: store.layout?.entries.last)) } label: {
            VStack(spacing: 4) {
                ZStack {
                    Color(uiColor: .systemBackground).opacity(0.6)
                    Image(systemName: "plus").font(.title2.weight(.medium)).foregroundStyle(Color.accentColor)
                }
                .frame(width: Self.width, height: Self.width * 0.55)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Seite anhängen").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Section("Vorlage") {
                ForEach(PaperTemplate.choices, id: \.id) { t in Button(t.name) { append(t.id) } }
            }
        }
        .accessibilityLabel("Seite anhängen")
        .accessibilityHint("Leere Seite wie die letzte; gedrückt halten für Vorlagen")
        .accessibilityIdentifier("sidebar.addPage")
    }

    private func append(_ template: String) {
        Task {
            if await bridge.controller?.appendBlankPage(template: template) == nil {
                notice = "Die Seite ließ sich nicht anhängen (nur ansehen oder noch nicht geladen)."
            }
        }
    }

    // MARK: Kontextmenue je Miniatur

    @ViewBuilder private func pageMenu(_ i: Int, _ entry: DisplayLayout.Entry) -> some View {
        let key = entry.key
        let items = PageSidebarActions.items(hasOutline: hasOutline, pageCount: store.layout?.entries.count ?? 0)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .insertBefore:
                Menu {
                    ForEach(PaperTemplate.choices, id: \.id) { t in
                        Button(t.name) { Task { await bridge.controller?.insertBlankPage(before: key, template: t.id) } }
                    }
                } label: { Label("Leere Seite davor", systemImage: "arrow.up.doc") }
            case .insertAfter:
                Menu {
                    ForEach(PaperTemplate.choices, id: \.id) { t in
                        Button(t.name) { Task { await bridge.controller?.insertBlankPage(after: key, template: t.id) } }
                    }
                } label: { Label("Leere Seite danach", systemImage: "doc.badge.plus") }
            case .rotate:
                Button { Task { await store.rotatePage(key: key) } } label: { Label("Seite drehen", systemImage: "rotate.right") }
            case .bookmark:
                Button {
                    Task { await store.toggleBookmark(pageKey: key, title: "Seite \(i + 1)") }
                } label: {
                    Label(store.isBookmarked(pageKey: key) ? "Lesezeichen entfernen" : "Lesezeichen setzen", systemImage: "bookmark")
                }
            case .outline:
                Button { outlineTitle = "Seite \(i + 1)"; outlineKey = key } label: {
                    Label("Zur Gliederung", systemImage: "list.bullet.indent")
                }
            case .trash:
                Button(role: .destructive) {
                    Task {
                        if await bridge.controller?.trashPage(key: key, undoable: true) != true {
                            notice = "Diese Seite lässt sich nicht in den Papierkorb legen (letzte Seite oder noch nicht geladen)."
                        }
                    }
                } label: { Label("Seite in den Papierkorb", systemImage: "trash") }
            }
        }
    }

    // MARK: Miniaturen

    private func refreshVisible() async {
        for key in cache.visible.sorted() { await refresh(key) }
    }

    /// Miniatur einer Seite pruefen (Index aus dem aktuellen Seitenaufbau, er verschiebt sich beim Einfuegen).
    private func refresh(_ key: String) async {
        guard let layout = store.layout, let i = layout.index(ofKey: key), let entry = layout.entry(at: i) else { return }
        let objects = await store.objects(forPageKey: key)
        guard let current = store.layout, current.entry(at: i) == entry, let page = current.pdf.page(at: i) else { return }
        // nur die Form der angezeigten Seite; gezeichnet wird aus der eigenen PDF-Instanz (`OffscreenPDF`)
        await cache.refresh(key: key, shape: OffscreenPDF.Shape(page: page, entry: entry), entry: entry, objects: objects,
                            images: store.images, source: store.offscreenPDF, layoutVersion: store.layoutVersion,
                            width: Self.width, scale: max(1, displayScale))
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
            .overlay(alignment: .bottom) { if let lm = lectureMark(entry) { MarkerTag(review: LectureMarkers.reviewFlag(lm)) } }
            .overlay(alignment: .topTrailing) {
                if store.isBookmarked(pageKey: entry.key) {
                    Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Color.accentColor).padding(4)
                }
            }
            Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(current ? Color.accentColor : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seite \(i + 1)" + (lectureMark(entry).map { LectureMarkers.reviewFlag($0) ? ", Vorlesung bis hier, bitte prüfen" : ", Vorlesung bis hier" } ?? ""))
        .accessibilityAddTraits(current ? [.isSelected] : [])
    }
}

extension ThumbnailStrip {
    /// Marker, der auf dieser Originalseite endet (eingefuegte Seiten tragen keinen)
    func lectureMark(_ entry: DisplayLayout.Entry) -> JSONValue? {
        entry.kind == "pdf" ? markers?.mark(pdfPage: entry.pdfIndex) : nil
    }
}

/// .ed-thumb-lm: Band "bis hier" am unteren Rand der Miniatur (Warnfarbe, wenn der Marker zu pruefen ist)
struct MarkerTag: View {
    let review: Bool
    var body: some View {
        Label("bis hier", systemImage: "flag.fill")
            .font(.system(size: 10, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 1)
            .background(review ? UF.warn : UF.accent)
    }
}
