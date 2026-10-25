import SwiftUI
import UniFlowCore

// Oberflaeche "Lösung teilen" (docs/LOESUNGEN-TEILEN.md): Dialog mit Vorschau ohne Original, eigene geteilte
// Loesungen, Vorschau einer empfangenen Loesung und der Hinweis vor dem privaten PDF-Export.

/// Feste Texte (auch fuer Tests).
enum SolutionTexts {
    static let ownNotesOnly = "Geteilt werden nur deine eigenen Notizen – keine Folien, keine Aufgabenstellungen, keine PDF. Teile nur, was du selbst erstellt hast."
    static let examRules = "Bewertete Abgaben (z. B. Hausübungen, Testate, Klausuren): Es gilt die Prüfungsordnung deiner Hochschule. Teile Lösungen dazu nur, wenn es ausdrücklich erlaubt ist."
    static let communityNotConnected = "Community-Dienst noch nicht verbunden"
    static let pdfExportPrivate = "Die exportierte PDF enthält das Originalmaterial deiner Hochschule (z. B. Folien und Aufgabenstellungen) zusammen mit deinen Notizen. Verwende sie nur privat, z. B. in der Dateien-App, und gib sie nicht weiter. Zum Teilen deiner Notizen gibt es „Lösung teilen …“."
}

// MARK: - Dialog "Lösung teilen"

struct SolutionShareSheet: View {
    @ObservedObject var store: DocumentStore
    let api: APIClient
    let close: () -> Void

    @State private var source: SolutionSource?
    /// alle teilbaren Seiten (fuer Vorschau und Auswahl)
    @State private var preview: SolutionContent?
    @State private var previewImages: [String: UIImage] = [:]
    @State private var selected: Set<String> = []
    @State private var assetPages = 0
    @State private var displayName = ""
    @State private var loadError: String?
    @State private var shareError: String?
    @State private var busy = false
    @State private var shareFile: ExportFile?
    @AppStorage("uniflow.solution.displayName") private var savedName = ""

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 860, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                UFGate(.community) { content }
            }
            .navigationTitle("Lösung teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", action: close) } }
        }
        .task { await load() }
        .sheet(item: $shareFile) { f in ActivityView(items: [f.url]) }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            notice
            if let loadError {
                UFCard { UFEmpty(icon: "alert", text: loadError, small: true) }
            } else if let preview {
                pagesCard(preview)
                nameCard
                if let shareError {
                    Text(shareError).ufFont(13.12, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                }
                actions
            } else {
                UFCard {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Notizen werden vorbereitet …").ufFont(14.5).foregroundStyle(UF.muted)
                    }
                }
            }
        }
    }

    private var notice: some View {
        UFCard {
            HStack(alignment: .top, spacing: 12) {
                UFIcon("info", size: 20).foregroundStyle(UF.accentText).padding(.top, 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text(SolutionTexts.ownNotesOnly).ufFont(14.5, 650).foregroundStyle(UF.text)
                    Text(SolutionTexts.examRules).ufFont(13.12).foregroundStyle(UF.text2)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pagesCard(_ preview: SolutionContent) -> some View {
        UFCard {
            UFCardHead("Vorschau ohne Original", icon: "layers", wrap: true) {
                UFButton("Alle", size: .small) { selected = Set(preview.pages.map(\.key)) }
                UFButton("Nur mit Notizen", size: .small) {
                    selected = Set(preview.pages.filter { !$0.objects.isEmpty }.map(\.key))
                }
            }
            Text("Wähle die Seiten, deren Notizen du teilen willst. So sieht der Empfänger deine Lösung – die Folien und Aufgaben hat er in seiner eigenen PDF.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(Array(preview.pages.enumerated()), id: \.element.key) { i, page in
                    SolutionPageTile(page: page, images: previewImages, title: tileTitle(page, position: i),
                                     selected: selected.contains(page.key)) {
                        if selected.contains(page.key) { selected.remove(page.key) } else { selected.insert(page.key) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(summary(preview)).ufFont(13.12, 600).foregroundStyle(UF.text2)
                let missing = missingImages(preview)
                if missing > 0 {
                    Label(missing == 1 ? "1 Bild ist nicht verfügbar und fehlt in der Lösung."
                                       : "\(missing) Bilder sind nicht verfügbar und fehlen in der Lösung.",
                          systemImage: "exclamationmark.triangle")
                        .ufFont(13.12).foregroundStyle(UF.warn)
                }
                if assetPages > 0 {
                    Text("Eingefügte Bild- und PDF-Seiten aus dem Browser werden nie geteilt (\(assetPages)).")
                        .ufFont(13.12).foregroundStyle(UF.muted)
                }
            }
            .padding(.top, 12)
        }
    }

    private var nameCard: some View {
        UFCard {
            Text("Anzeigename (optional)").ufFont(14.5, 600).foregroundStyle(UF.text).padding(.bottom, 6)
            UFTextInput("Leer lassen = anonym", text: $displayName)
            Text("Erscheint beim Empfänger als „Lösung von …“. Ohne Namen steht dort „Anonym“.")
                .ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 6)
        }
    }

    private var actions: some View {
        UFFlexWrap(gap: 10) {
            UFButton("Abbrechen", action: close)
            VStack(alignment: .leading, spacing: 4) {
                UFButton("In der Community veröffentlichen", icon: "users") {}
                    .disabled(true)
                Text(SolutionTexts.communityNotConnected).ufFont(12.8).foregroundStyle(UF.muted)
            }
            UFButton(busy ? "Wird erstellt …" : "Als Datei teilen", icon: "download", kind: .primary) { share() }
                .disabled(busy || selected.isEmpty)
        }
    }

    private func tileTitle(_ page: SolutionPage, position: Int) -> String {
        if let i = page.pdfIndex { return "PDF-Seite \(i)" }
        let t = PageTemplate.all.first { $0.id == page.template }?.name ?? "Leer"
        return "Eigene Seite (\(t))"
    }

    private func chosen(_ preview: SolutionContent) -> [SolutionPage] { preview.pages.filter { selected.contains($0.key) } }

    private func summary(_ preview: SolutionContent) -> String {
        let pages = chosen(preview)
        let objects = pages.reduce(0) { $0 + $1.objects.count }
        return "\(pages.count) von \(preview.pages.count) Seiten ausgewählt · \(objects) eigene Notizobjekte"
    }

    private func missingImages(_ preview: SolutionContent) -> Int {
        guard let source else { return 0 }
        return SolutionBuilder.imageSources(source.document, keys: chosen(preview).map(\.key)).filter { preview.images[$0] == nil }.count
    }

    private func load() async {
        guard preview == nil, Entitlements.shared.allows(.community) else { return }
        displayName = savedName
        do {
            let s = try await store.solutionSource(loadImage: ShareExport.serverImageLoader(api))
            let candidates = SolutionBuilder.candidates(s.document)
            assetPages = candidates.filter { !$0.shareable }.count
            let keys = candidates.filter(\.shareable).map(\.key)
            let all = try SolutionSharing.content(s, keys: keys, displayName: "")
            source = s
            previewImages = ForeignSolutionLayer.uiImages(all.images)
            preview = all
            selected = Set(SolutionBuilder.defaultSelection(s.document))
        } catch {
            loadError = (error as? SolutionError)?.description ?? "Die Lösung lässt sich nicht vorbereiten: \(error.localizedDescription)"
        }
    }

    private func share() {
        guard let source, !selected.isEmpty else { return }
        busy = true
        shareError = nil
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        savedName = name
        do {
            let content = try SolutionSharing.content(source, keys: Array(selected), displayName: name)
            let package = try SolutionSharing.package(content, originalPDF: source.originalPDF)
            let url = try SolutionSharing.writeFile(package, title: source.title)
            try SolutionSharing.library.recordShared(package, title: source.title)
            shareFile = ExportFile(url: url)
        } catch {
            shareError = (error as? SolutionError)?.description ?? "Teilen fehlgeschlagen: \(error.localizedDescription)"
        }
        busy = false
    }
}

/// Miniatur einer geteilten Seite (weiss, ohne Original) mit Auswahl.
struct SolutionPageTile: View {
    let page: SolutionPage
    let images: [String: UIImage]
    let title: String
    var selected: Bool?
    var toggle: (() -> Void)?
    @State private var image: UIImage?

    static let width: CGFloat = 132

    var body: some View {
        Button { toggle?() } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            Color.white.aspectRatio(CGFloat(page.displaySize.width / max(1, page.displaySize.height)), contentMode: .fit)
                        }
                    }
                    .frame(width: Self.width)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected == true ? UF.accent : UF.line,
                                                                            lineWidth: selected == true ? 2 : 1))
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(selected ? UF.accent : UF.muted)
                            .background(Circle().fill(Color.white).padding(2))
                            .padding(6)
                    }
                }
                Text(title).ufFont(12.8, 600).foregroundStyle(UF.text).lineLimit(1)
                Text(page.objects.isEmpty ? "keine Notizen" : "\(page.objects.count) Notizobjekte")
                    .ufFont(11.84).foregroundStyle(UF.muted)
            }
        }
        .buttonStyle(.plain)
        .disabled(toggle == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(page.objects.count) Notizobjekte")
        .accessibilityAddTraits(selected == true ? [.isSelected] : [])
        .task(id: page.key) {
            let page = self.page, images = self.images, width = Self.width
            let box = await Task.detached(priority: .utility) {
                ImageBox(image: SolutionPreview.image(page, images: images, width: width))
            }.value
            image = box.image
        }
    }

    private struct ImageBox: @unchecked Sendable { let image: UIImage }
}

// MARK: - Meine geteilten Loesungen

struct SharedSolutionsSheet: View {
    let close: () -> Void
    @State private var entries: [SolutionLibrary.SharedEntry] = []
    @State private var shareFile: ExportFile?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                VStack(alignment: .leading, spacing: 16) {
                    UFCard {
                        Text("Lösungen, die du als Datei geteilt hast. „Entfernen“ zieht sie hier zurück und löscht die Kopie auf diesem iPad. Ohne Community-Dienst kann UniFlow bereits weitergegebene Dateien nicht zurückholen.")
                            .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error { Text(error).ufFont(13.12, 600).foregroundStyle(UF.bad) }
                    UFCard(padded: false) {
                        if entries.isEmpty {
                            UFEmpty(icon: "users", text: "Du hast noch keine Lösung geteilt.", small: true)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(entries, id: \.solutionID) { e in
                                    row(e)
                                    if e.solutionID != entries.last?.solutionID { Divider().overlay(UF.line) }
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Meine geteilten Lösungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
        .onAppear { reload() }
        .sheet(item: $shareFile) { f in ActivityView(items: [f.url]) }
    }

    private func row(_ e: SolutionLibrary.SharedEntry) -> some View {
        let name = e.displayName.isEmpty ? "anonym" : "als \(e.displayName)"
        let pages = e.pageCount == 1 ? "1 Seite" : "\(e.pageCount) Seiten"
        return UFItemRow(e.title.isEmpty ? "Lösung" : e.title, sub: "\(pages) · \(ForeignSolutionLayer.date(e.createdAt)) · \(name)",
                         leading: { UFIcon("users", size: 18).foregroundStyle(UF.muted) },
                         trailing: {
                             HStack(spacing: 8) {
                                 UFButton("Erneut teilen", icon: "download", size: .small) { reshare(e) }
                                 UFButton("Entfernen", icon: "trash", kind: .danger, size: .small) { remove(e) }
                             }
                         })
    }

    private func reload() { entries = SolutionSharing.library.sharedEntries() }

    private func reshare(_ e: SolutionLibrary.SharedEntry) {
        do {
            let package = try SolutionPackage.decode(Data(contentsOf: SolutionSharing.library.sharedPackageURL(e.solutionID)))
            shareFile = ExportFile(url: try SolutionSharing.writeFile(package, title: e.title))
        } catch {
            self.error = (error as? SolutionError)?.description ?? error.localizedDescription
        }
    }

    private func remove(_ e: SolutionLibrary.SharedEntry) {
        do {
            // ohne Dienst gibt es nichts zurueckzuziehen ausser der eigenen Kopie
            try SolutionSharing.library.removeShared(e.solutionID)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Vorschau einer empfangenen Loesung

struct SolutionPreviewSheet: View {
    let layer: ForeignSolutionLayer
    let close: () -> Void

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 860, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                VStack(alignment: .leading, spacing: 16) {
                    UFCard {
                        Text("Nur die Notizen dieser Lösung, ohne Original. Im Dokument erscheinen sie über deiner eigenen PDF und lassen sich nicht bearbeiten.")
                            .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        if layer.blankPageCount > 0 {
                            Text("\(layer.blankPageCount) eigene Seite(n) der Lösung gibt es in deiner PDF nicht – sie sind nur hier zu sehen.")
                                .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 6)
                        }
                        if layer.missingImages > 0 {
                            Label("\(layer.missingImages) Bild(er) fehlen in dieser Lösung.", systemImage: "exclamationmark.triangle")
                                .ufFont(13.12).foregroundStyle(UF.warn).padding(.top, 6)
                        }
                    }
                    UFCard {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 14)], alignment: .leading, spacing: 14) {
                            ForEach(layer.pages, id: \.key) { page in
                                SolutionPageTile(page: page, images: layer.images,
                                                 title: page.pdfIndex.map { "PDF-Seite \($0)" } ?? "Eigene Seite")
                            }
                        }
                    }
                }
            }
            .navigationTitle(layer.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", action: close) } }
        }
    }
}

// MARK: - Gesperrt (Free)

/// Sperrkarte "Community" mit Weg zur Abo-Seite (UFGate/UFLockedCard).
struct SolutionLockedSheet: View {
    let close: () -> Void

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 640, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                UFGate(.community) {
                    UFCard { Text("Lösungen teilen und ansehen ist freigeschaltet.").ufFont(14.5).foregroundStyle(UF.text) }
                }
            }
            .navigationTitle("Lösungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen", action: close) } }
        }
    }
}

// MARK: - Hinweis vor dem PDF-Export

struct PDFExportNoticeDialog: View {
    let scope: ShareScope
    let export: () -> Void
    let cancel: () -> Void

    var body: some View {
        UFDialog("PDF exportieren – nur privat", icon: "download") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(SolutionTexts.pdfExportPrivate)
                Text(scope == .document ? "Umfang: ganzes Dokument mit Notizen." : "Umfang: aktuelle Seite mit Notizen.")
                    .foregroundStyle(UF.muted)
            }
            .ufFont(13.12).foregroundStyle(UF.text2)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen", action: cancel)
            UFButton("Exportieren", icon: "download", kind: .primary, action: export)
        }
    }
}
