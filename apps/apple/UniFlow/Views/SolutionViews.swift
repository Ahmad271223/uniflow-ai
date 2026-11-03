import PDFKit
import SwiftUI
import UniFlowCore

// Oberflaeche "Lösung teilen" (docs/LOESUNGEN-TEILEN.md): Dialog mit Vorschau ohne Original (als Datei teilen oder in
// der Community veroeffentlichen), eigene geteilte Loesungen (mit Zurueckziehen), Vorschau einer empfangenen Loesung
// und der Hinweis vor dem privaten PDF-Export.

/// Feste Texte (auch fuer Tests).
enum SolutionTexts {
    static let ownNotesOnly = "Geteilt werden nur deine eigenen Notizen – keine Folien, keine Aufgabenstellungen, keine PDF. Teile nur, was du selbst erstellt hast."
    static let examRules = "Bewertete Abgaben (z. B. Hausübungen, Testate, Klausuren): Es gilt die Prüfungsordnung deiner Hochschule. Teile Lösungen dazu nur, wenn es ausdrücklich erlaubt ist."
    static let communityConfirmTitle = "In der Community veröffentlichen"
    /// Erneut teilen zu derselben PDF in derselben Community (03.11.2026): eine Loesung je PDF, sonst aktualisieren
    static let updateTitle = "Lösung aktualisieren"
    static let updateQuestion = CommunityServiceError.updateQuestion
    static let updateExplain = "Deine neuen Seiten kommen zur bisherigen Lösung dazu; Seiten, die schon darin sind, werden durch die neue Fassung ersetzt. Likes und Kommentare bleiben erhalten."

    /// Was ausser den Notizen im Paket steht (Pruefbericht 409): Titel und Zeitpunkt, dazu das Pseudonym
    static func sentAlong(title: String) -> String {
        "Mit der Lösung gehen außerdem der Titel „\(title)“ und der Zeitpunkt des Teilens mit."
    }

    /// Hinweis auf fehlende Bilder (Dialog und Bestaetigung vor dem Veroeffentlichen, Pruefbericht 407)
    static func missingImages(_ n: Int) -> String {
        n == 1 ? "1 Bild ist nicht verfügbar und fehlt in der Lösung." : "\(n) Bilder sind nicht verfügbar und fehlen in der Lösung."
    }
    static let pdfExportPrivate = "Die exportierte PDF enthält das Originalmaterial deiner Hochschule (z. B. Folien und Aufgabenstellungen) zusammen mit deinen Notizen. Verwende sie nur privat, z. B. in der Dateien-App, und gib sie nicht weiter. Zum Teilen deiner Notizen gibt es „Lösung teilen …“."
}

// MARK: - Dialog "Lösung teilen"

struct SolutionShareSheet: View {
    @ObservedObject var store: DocumentStore
    let api: APIClient
    /// Notizblatt neben der Folie (geteilte Ansicht): seine Seiten gehen als eigene Seiten mit
    var notebook: DocumentStore?
    let close: () -> Void

    @State private var source: SolutionSource?
    /// alle teilbaren Seiten (fuer Vorschau und Auswahl), ausgelassene Seiten mit Grund, eingefuegte Seiten
    @State private var draft: SolutionShareDraft?
    @State private var previewImages: [String: UIImage] = [:]
    @State private var selected: Set<String> = []
    @State private var displayName = ""
    @State private var loadError: String?
    @State private var shareError: String?
    @State private var busy = false
    @State private var shareFile: ExportFile?
    // Community: Sichtbarkeit, Lerngruppen, Kurs-Schluessel und Lehrwoche der Datei, Bestaetigung, Ergebnis
    @State private var spaces: [CommunitySpace] = []
    @State private var spaceKey = ""
    @State private var courseKey: String?
    @State private var week = 0
    @State private var confirmingPublish = false
    @State private var publishing = false
    @State private var published: CommunityPublication?
    /// eigene Loesung zu dieser PDF in der gewaehlten Community: Frage "Aktualisieren?"
    @State private var updateID: String?
    @State private var updated = false

    /// Dienst des aktiven Containers (Tests geben einen eigenen mit)
    var community: CommunityService = SolutionSharing.community

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 860, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                UFGate(.shareSolutions) { content }
            }
            .navigationTitle("Lösung teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", action: close) } }
        }
        .task { await load() }
        .sheet(item: $shareFile) { f in ActivityView(items: [f.url]) }
        .ufModal(isPresented: $confirmingPublish) { publishDialog }
        .ufModal(isPresented: Binding(get: { updateID != nil }, set: { if !$0 { updateID = nil } })) { updateDialog }
    }

    /// Der Knopf "In der Community veroeffentlichen" ist nur ab Plus zu sehen (die ganze Seite steht hinter
    /// `UFGate(.shareSolutions)`) und nur mit Dienst im Build benutzbar.
    static func showsCommunityPublish(plan: UFPlan) -> Bool { UFFeatureMatrix.access(.shareSolutions, plan: plan).isAllowed }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            notice
            if let loadError {
                UFCard { UFEmpty(icon: "alert", text: loadError, small: true) }
            } else if let published {
                publishedCard(published)
            } else if let draft, let preview = draft.content {
                pagesCard(preview, draft: draft)
                nameCard
                communityCard
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

    private func pagesCard(_ preview: SolutionContent, draft: SolutionShareDraft) -> some View {
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
                if draft.showsNoOwnNotes(selected) {
                    // nie ein leeres Paket: Teilen bleibt gesperrt, bis eine Seite mit Notizen gewaehlt ist
                    Label(SolutionError.noOwnNotes.description, systemImage: "exclamationmark.triangle")
                        .ufFont(13.12).foregroundStyle(UF.warn).fixedSize(horizontal: false, vertical: true)
                }
                let missing = missingImages(preview)
                if missing > 0 {
                    Label(SolutionTexts.missingImages(missing), systemImage: "exclamationmark.triangle")
                        .ufFont(13.12).foregroundStyle(UF.warn)
                }
                if draft.assetPages > 0 {
                    Text(SolutionShareDraft.assetText(draft.assetPages))
                        .ufFont(13.12).foregroundStyle(UF.muted)
                }
                ForEach(draft.problems, id: \.key) { problem in
                    Label(SolutionShareDraft.problemText(problem), systemImage: "exclamationmark.triangle")
                        .ufFont(13.12).foregroundStyle(UF.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
        }
    }

    private var nameCard: some View {
        UFCard {
            Text("Pseudonym (optional)").ufFont(14.5, 600).foregroundStyle(UF.text).padding(.bottom, 6)
            UFTextInput("Leer lassen = anonym", text: $displayName)
            Text("Erscheint beim Empfänger als „Lösung von …“. Ohne Namen steht dort „Anonym“. Wird je Konto und Hochschule gemerkt; nie dein echter Name.")
                .ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 6)
            if let source {
                Text(SolutionTexts.sentAlong(title: source.title)).ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
    }

    /// Sichtbarkeit in der Community (Modul / Lerngruppe / anonym) mit Urheberrechts-Hinweis
    private var communityCard: some View {
        UFCard {
            UFCardHead("In der Community", icon: "users") {
                CommunityTexts.badge(community)
            }
            if community.isConnected {
                if spaces.isEmpty {
                    Text(CommunityTexts.noCommunity).ufFont(13.12).foregroundStyle(UF.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    UFSelect(options: spaces.map { ($0.key, $0.name) }, selection: $spaceKey)
                    Text(CommunityTexts.visibilityMembers).ufFont(13.12).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
                Text(CommunityTexts.copyright).ufFont(13.12).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } else {
                Text(CommunityTexts.unavailable).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func publishedCard(_ p: CommunityPublication) -> some View {
        UFCard {
            UFCardHead(updated ? "Aktualisiert" : "Veröffentlicht", icon: "check")
            Text(updated ? "Deine Lösung ist aktualisiert: die neuen Seiten sind dazugekommen, Likes und Kommentare sind geblieben. \(CommunityTexts.visibilityMembers)"
                         : "Deine Lösung ist in der Community – \(CommunityTexts.publishedAt(SolutionPackage.timestamp(p.publishedAt))). \(CommunityTexts.visibilityMembers)")
                .ufFont(14.5).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
            Text("Zurückziehen kannst du sie jederzeit unter „Meine geteilten Lösungen“.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 6)
            UFButton("Fertig", kind: .primary, action: close).padding(.top, 12)
        }
    }

    private var canPublish: Bool {
        guard community.isConnected, !busy, !publishing, draft?.canShare(selected) == true else { return false }
        return space != nil
    }

    private var space: CommunitySpace? { spaces.first { $0.key == spaceKey } }

    private var actions: some View {
        UFFlexWrap(gap: 10) {
            UFButton("Abbrechen", action: close)
            VStack(alignment: .leading, spacing: 4) {
                UFButton(publishing ? "Wird veröffentlicht …" : "In der Community veröffentlichen", icon: "users") { confirmingPublish = true }
                    .disabled(!canPublish)
                if !community.isConnected {
                    Text(CommunityTexts.unavailable).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            UFButton(busy ? "Wird erstellt …" : "Als Datei teilen", icon: "download", kind: .primary) { share() }
                .disabled(busy || publishing || !(draft?.canShare(selected) ?? false))
        }
    }

    /// Bestaetigung vor dem Veroeffentlichen: nur eigene Notizen, Sichtbarkeit, Pseudonym
    private var publishDialog: some View {
        let name = CommunityRules.effectiveDisplayName(displayName, visibility: .module)
        return UFDialog(SolutionTexts.communityConfirmTitle, icon: "users") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(CommunityTexts.copyright)
                Text(SolutionTexts.examRules)
                // unvollstaendiger Inhalt steht auch in der Bestaetigung, nicht nur im Dialog darunter
                if let preview = draft?.content, missingImages(preview) > 0 {
                    Label(SolutionTexts.missingImages(missingImages(preview)), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(UF.warn)
                }
                Text("Community: \(space?.name ?? "") · \(name.isEmpty ? "anonym" : "als „\(name)“")")
                    .foregroundStyle(UF.text)
                Text(CommunityTexts.privacy(community)).foregroundStyle(UF.muted)
            }
            .ufFont(13.12).foregroundStyle(UF.text2)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { confirmingPublish = false }
            UFButton("Veröffentlichen", icon: "users", kind: .primary) {
                confirmingPublish = false
                publish()
            }
        }
    }

    /// Frage, wenn es zu dieser PDF in dieser Community schon eine eigene Loesung gibt
    private var updateDialog: some View {
        UFDialog(SolutionTexts.updateTitle, icon: "users") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(SolutionTexts.updateQuestion).foregroundStyle(UF.text)
                Text(SolutionTexts.updateExplain)
            }
            .ufFont(13.12).foregroundStyle(UF.text2)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton("Abbrechen") { updateID = nil }
            UFButton("Aktualisieren", icon: "users", kind: .primary) {
                let id = updateID
                updateID = nil
                if let id { update(id) }
            }
        }
    }

    private func tileTitle(_ page: SolutionPage, position: Int) -> String {
        if let i = page.pdfIndex { return "PDF-Seite \(i)" }
        let t = page.template.flatMap { PaperTemplate.names[$0] } ?? "Leer"
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

    /// Die Vorschau ist kein Teilen: Seiten ohne Notizen stehen darin, die Gruende fuer fehlende Notizen
    /// (ausgelassene oder eingefuegte Seiten) nennt die Seitenkarte. Ob geteilt werden kann, entscheidet die Auswahl.
    private func load() async {
        guard draft == nil, Entitlements.shared.allows(.shareSolutions) else { return }
        displayName = SolutionDisplayName.load()
        spaces = ((try? await community.communities()) ?? []).filter(\.joined)
        // Vorauswahl: die Community des Kurses dieser Datei
        if let host = ActiveContainer.current?.host, let uni = ActiveContainer.current?.key.university,
           let key = await CommunityCourses.courseKey(fileID: store.file.id, host: host, university: uni.rawValue) {
            courseKey = key
            week = await CommunityCourses.week(fileID: store.file.id, moduleID: store.file.module_id, api: api)
        }
        spaceKey = spaces.first { $0.key == courseKey }?.key ?? spaces.first?.key ?? ""
        do {
            var s = try await store.solutionSource(loadImage: ShareExport.serverImageLoader(api))
            // nur ein Notizblatt desselben Moduls (z. B. "Leeres Blatt" daneben), nie ein fremdes Notizbuch
            if let notebook, notebook.file.isNotebook, notebook.file.module_id == store.file.module_id {
                let part = await notebook.notebookPart(loadImage: ShareExport.serverImageLoader(api))
                s = s.appendingNotebook(part.document, images: part.images)
            }
            let prepared = try await Task.detached(priority: .userInitiated) { try SolutionSharing.draft(s) }.value
            guard let all = prepared.content else {
                loadError = prepared.unavailable
                return
            }
            source = s
            previewImages = try ForeignSolutionLayer.uiImages(all.images)
            draft = prepared
            // Seiten des Notizblatts nicht vorauswaehlen: mitteilen nur, wenn man sie selbst ankreuzt
            selected = prepared.selection.filter { !SolutionBuilder.isNotebookKey($0) }
        } catch {
            loadError = (error as? SolutionError)?.description ?? "Die Lösung lässt sich nicht vorbereiten: \(error.localizedDescription)"
        }
    }

    /// Inhalt, Siegel und Datei entstehen abseits des Hauptthreads ("Wird erstellt …" bleibt so sichtbar).
    private func share() {
        guard let source, draft?.canShare(selected) == true, !busy else { return }
        busy = true
        shareError = nil
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        SolutionDisplayName.save(name)
        let keys = Array(selected)
        Task {
            do {
                shareFile = ExportFile(url: try await SolutionSharing.shareFile(source, keys: keys, displayName: name))
            } catch {
                shareError = (error as? SolutionError)?.description ?? "Teilen fehlgeschlagen: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func publishOptions(_ space: CommunitySpace, title: String) -> CommunityPublishOptions {
        let group = space.kind == .group
        return CommunityPublishOptions(visibility: group ? .studyGroup : .module, courseKey: space.key, groupKey: group ? space.key : nil,
                                       title: title, week: week, communityKey: space.key)
    }

    /// Inhalt und Siegel wie beim Teilen als Datei, dann zum Dienst (Kopie unter "Meine geteilten Lösungen"). Gibt es
    /// zu dieser PDF in dieser Community schon eine eigene Loesung, kommt stattdessen die Frage "Aktualisieren?".
    private func publish() {
        guard let source, canPublish, let space else { return }
        publishing = true
        shareError = nil
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        SolutionDisplayName.save(name)
        let keys = Array(selected)
        let options = publishOptions(space, title: source.title)
        let service = community
        Task {
            do {
                switch try await SolutionSharing.publishOrAskUpdate(source, keys: keys, displayName: CommunityRules.effectiveDisplayName(name, visibility: .module),
                                                                    options: options, space: space, service: service) {
                case .published(let p):
                    published = p
                    await CommunityMatches.shared.invalidate()
                case .askUpdate(let id):
                    updateID = id
                }
            } catch {
                shareError = CommunityTexts.message(error)
            }
            publishing = false
        }
    }

    /// "Aktualisieren": bisherige Loesung laden, mit der neuen Auswahl zusammenfuehren und das Paket ersetzen
    private func update(_ existingID: String) {
        guard let source, let space, !publishing else { return }
        publishing = true
        shareError = nil
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = Array(selected)
        let options = publishOptions(space, title: source.title)
        let service = community
        Task {
            do {
                published = try await SolutionSharing.updateInCommunity(source, keys: keys, displayName: CommunityRules.effectiveDisplayName(name, visibility: .module),
                                                                        options: options, space: space, existingID: existingID, service: service)
                updated = true
                await CommunityMatches.shared.invalidate()
            } catch {
                shareError = CommunityTexts.message(error)
            }
            publishing = false
        }
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
    @State private var withdrawing: SolutionLibrary.SharedEntry?
    @State private var busyID: String?

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 760, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                VStack(alignment: .leading, spacing: 16) {
                    UFCard {
                        Text("Lösungen, die du als Datei geteilt oder in der Community veröffentlicht hast. „Zurückziehen“ entfernt eine Veröffentlichung aus der Community; „Entfernen“ löscht die Kopie auf diesem iPad. Bereits weitergegebene Dateien und schon geladene Lösungen kann Studora nicht zurückholen.")
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
        .ufModal(isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } })) {
            if let e = withdrawing {
                UFDialog("Lösung zurückziehen", icon: "trash") {
                    Text("Die Lösung verschwindet aus der Community und das Paket wird beim Dienst gelöscht. Die Kopie auf diesem iPad bleibt; wer sie schon geladen hat, behält sie.")
                        .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                } foot: {
                    UFButton("Abbrechen") { withdrawing = nil }
                    UFButton("Zurückziehen", kind: .danger) { withdrawing = nil; withdraw(e) }
                }
            }
        }
    }

    /// Zustand einer Zeile: "veröffentlicht am …" oder "als Datei geteilt"
    static func status(_ e: SolutionLibrary.SharedEntry) -> String {
        e.publishedAt.map(CommunityTexts.publishedAt) ?? "als Datei geteilt"
    }

    private func row(_ e: SolutionLibrary.SharedEntry) -> some View {
        let name = e.displayName.isEmpty ? "anonym" : "als \(e.displayName)"
        let pages = e.pageCount == 1 ? "1 Seite" : "\(e.pageCount) Seiten"
        return UFItemRow(e.title.isEmpty ? "Lösung" : e.title, sub: "\(pages) · \(ForeignSolutionLayer.date(e.createdAt)) · \(name) · \(Self.status(e))",
                         leading: { UFIcon("users", size: 18).foregroundStyle(e.publishedAt == nil ? UF.muted : UF.accentText) },
                         trailing: {
                             HStack(spacing: 8) {
                                 if e.publishedAt != nil {
                                     UFButton(busyID == e.solutionID ? "Wird zurückgezogen …" : "Zurückziehen", icon: "x", size: .small) { withdrawing = e }
                                         .disabled(busyID != nil)
                                 }
                                 UFButton("Erneut teilen", icon: "download", size: .small) { reshare(e) }
                                 UFButton("Entfernen", icon: "trash", kind: .danger, size: .small) { remove(e) }
                                     .disabled(e.publishedAt != nil)        // erst zurueckziehen, dann die Kopie loeschen
                             }
                         })
    }

    private func reload() { entries = SolutionSharing.library.sharedEntries() }

    private func withdraw(_ e: SolutionLibrary.SharedEntry) {
        busyID = e.solutionID
        error = nil
        Task {
            defer { busyID = nil }
            do {
                try await SolutionSharing.withdrawFromCommunity(e.solutionID, service: SolutionSharing.community)
                reload()
            } catch {
                self.error = CommunityTexts.message(error)
            }
        }
    }

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
            // nur die eigene Kopie; eine Veroeffentlichung bleibt, bis sie zurueckgezogen wird
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

/// Sperrkarte einer Community-Funktion (Teilen ab Plus, Lesen wenn die Community fehlt) mit Weg zur Abo-Seite
/// (UFGate/UFLockedCard).
struct SolutionLockedSheet: View {
    var feature: UFFeature = .shareSolutions
    let close: () -> Void

    var body: some View {
        NavigationStack {
            UFContent(maxWidth: 640, insets: EdgeInsets(top: 16, leading: 20, bottom: 32, trailing: 20)) {
                UFGate(feature) {
                    UFCard { Text("„\(feature.title)“ ist freigeschaltet.").ufFont(14.5).foregroundStyle(UF.text) }
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

// MARK: - Loesung daneben ansehen

/// Eine fremde Loesung in der geteilten Ansicht neben dem eigenen Dokument: nur ansehen (nicht ueber die eigene Seite
/// gelegt), je Seite die eigene PDF-Seite darunter, eigene Seiten der Loesung auf ihrer Vorlage. Bilder werden je Seite
/// in der Breite der Spalte gezeichnet, also scharf.
struct SolutionSidePane: View {
    let layer: ForeignSolutionLayer
    let pdf: PDFDocument?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(UF.accent)
                Text(layer.label).font(.caption).bold().lineLimit(1)
                Spacer()
                Text("nur ansehen").font(.caption).foregroundStyle(.secondary)
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Schließen")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(layer.pages, id: \.key) { page in
                            SolutionSidePage(page: page, images: layer.images,
                                             pdfPage: page.pdfIndex.flatMap { pdf?.page(at: $0 - 1) },
                                             width: max(200, geo.size.width - 24))
                        }
                    }
                    .padding(12)
                }
            }
            .background(Color(uiColor: .secondarySystemBackground))
        }
    }
}

private struct SolutionSidePage: View {
    let page: SolutionPage
    let images: [String: UIImage]
    let pdfPage: PDFPage?
    let width: CGFloat
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .overlay(Rectangle().stroke(UF.line))
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                } else {
                    ProgressView().frame(height: width * 1.3)
                }
            }
            Text(page.pdfIndex.map { "PDF-Seite \($0)" } ?? "Eigene Seite der Lösung").font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: "\(page.key)-\(Int(width))") {
            let p = page, imgs = images, pp = pdfPage, w = width
            let scale = UIScreen.main.scale
            image = await Task.detached(priority: .userInitiated) {
                Box(SolutionPreview.image(p, images: imgs, width: w, scale: scale, pdfPage: pp))
            }.value.image
        }
    }

    private struct Box: @unchecked Sendable {
        let image: UIImage
        init(_ i: UIImage) { image = i }
    }
}
