import Foundation
import PDFKit
import UIKit
import UniFlowCore

extension Notification.Name {
    /// Empfangene Loesungen haben sich geaendert (Import ueber "Öffnen in", Entfernen). Offene Dokumente laden ihre
    /// Ebenen neu.
    static let uniflowSolutionsChanged = Notification.Name("uniflow.solutionsChanged")
}

/// Was der Dialog "Lösung teilen" braucht: das eigene Notizmodell (nur gelesen), die unveraenderten Bytes der
/// Original-PDF (nur fuer Fingerabdruck und Schluessel, sie gelangen nie ins Paket), Groesse und Drehung der
/// PDF-Seiten und die eigenen Bilder (schon als PNG/JPEG zum Einbetten). Ohne PDFKit- und UIKit-Objekte, damit
/// Erzeugen und Versiegeln abseits des Hauptthreads laufen koennen.
struct SolutionSource: Sendable {
    let document: AnnotationDocument
    let originalPDF: Data
    let pdfPageCount: Int
    /// 1-basierter PDF-Seitenindex -> Groesse ohne Drehung und eigene Drehung
    let pageInfos: [Int: SolutionBuilder.PDFPageInfo]
    let fingerprint: String
    /// eigene Bilder nach `src`, eingebettet (zu grosse verkleinert)
    let images: [String: SolutionImage]
    let title: String

    init(document: AnnotationDocument, originalPDF: Data, pdfPageCount: Int, pageInfos: [Int: SolutionBuilder.PDFPageInfo],
         fingerprint: String, images: [String: SolutionImage], title: String) {
        self.document = document
        self.originalPDF = originalPDF
        self.pdfPageCount = pdfPageCount
        self.pageInfos = pageInfos
        self.fingerprint = fingerprint
        self.images = images
        self.title = title
    }

    /// Aus einer geladenen PDF und eigenen Bildern (Tests und einfache Aufrufer; bettet sofort ein).
    init(document: AnnotationDocument, originalPDF: Data, pdf: PDFDocument, fingerprint: String, images: [String: UIImage],
         title: String) {
        self.init(document: document, originalPDF: originalPDF, pdfPageCount: pdf.pageCount,
                  pageInfos: SolutionSharing.pageInfos(pdf), fingerprint: fingerprint,
                  images: SolutionSharing.embed(images), title: title)
    }
}

/// Was der Dialog "Lösung teilen" zur Auswahl zeigt. Die Vorschau ist kein Teilen: sie enthaelt auch Seiten ohne
/// Notizen, damit der Dialog nennt, warum etwas fehlt (ausgelassene Seite mit Grund, eingefuegte Seiten aus dem
/// Browser, keine eigenen Notizen). Das Paket selbst entsteht nur mit eigenen Notizen (`SolutionSharing.content`).
struct SolutionShareDraft: Sendable {
    /// alle teilbaren Seiten ohne die ausgelassenen (auch ohne Notizen); `nil`, wenn keine Seite bleibt
    let content: SolutionContent?
    /// Vorauswahl: Seiten mit eigenen Notizen, ohne ausgelassene
    let selection: Set<String>
    /// eingefuegte Bild- und PDF-Seiten aus dem Browser (werden nie geteilt)
    let assetPages: Int
    /// Seiten, deren Objekte die Pruefungen nicht bestehen (mit Grund); sie fehlen in `content`
    let problems: [SolutionBuilder.PageProblem]
    /// Irgendeine Seite des Dokuments hat eigene Notizobjekte (auch eine ausgelassene oder eingefuegte).
    let hasAnyOwnNotes: Bool

    static func problemText(_ problem: SolutionBuilder.PageProblem) -> String {
        "\(problem.label) lässt sich nicht teilen: \(problem.error.description)"
    }

    static func assetText(_ count: Int) -> String {
        "Eingefügte Bild- und PDF-Seiten aus dem Browser werden nie geteilt (\(count))."
    }

    /// Meldung statt der Vorschau, wenn keine Seite teilbar ist: alle Gruende (ausgelassene und eingefuegte Seiten).
    var unavailable: String? {
        guard content == nil else { return nil }
        let lines = problems.map(Self.problemText) + (assetPages > 0 ? [Self.assetText(assetPages)] : [])
        return lines.isEmpty ? SolutionError.nothingSelected.description : lines.joined(separator: "\n")
    }

    /// Gewaehlte Seiten in Anzeigereihenfolge.
    func chosen(_ selected: Set<String>) -> [SolutionPage] { content?.pages.filter { selected.contains($0.key) } ?? [] }

    /// Teilen ist moeglich: mindestens eine gewaehlte Seite hat eigene Notizobjekte.
    func canShare(_ selected: Set<String>) -> Bool { chosen(selected).contains { !$0.objects.isEmpty } }

    /// Hinweis "keine eigenen Notizen": gewaehlte Seiten ohne Notizen oder ein Dokument ganz ohne eigene Notizen.
    /// Liegen Notizen nur auf ausgelassenen oder eingefuegten Seiten, nennt der Dialog stattdessen diese Gruende.
    func showsNoOwnNotes(_ selected: Set<String>) -> Bool {
        guard content != nil, !canShare(selected) else { return false }
        return !selected.isEmpty || !hasAnyOwnNotes
    }
}

/// Ergebnis beim Laden der passenden Loesungen fuer ein Dokument.
struct SolutionLayerLoad {
    /// Loesung, die nicht angezeigt wird (nichts davon erscheint, auch nicht teilweise).
    struct Problem: Identifiable, Equatable {
        /// Loesungs-ID (zum Entfernen im Ebenen-Menue)
        let id: String
        /// "Lösung von … (Datum)"
        let label: String
        let message: String

        var text: String { "\(label): \(message)" }
    }

    var layers: [ForeignSolutionLayer] = []
    var problems: [Problem] = []
}

/// Ergebnis von "Lösung importieren …" im offenen Dokument.
enum SolutionImportResult {
    /// passt zu dieser PDF und laesst sich anzeigen
    case shown(SolutionLibrary.Entry)
    /// gehoert zu einer anderen PDF; gespeichert, erscheint beim passenden Dokument
    case otherPDF(SolutionLibrary.Entry)
    /// Fingerabdruck passt, Inhalt laesst sich aber nicht oeffnen: sofort wieder entfernt
    case removedUnreadable(SolutionLibrary.Entry, SolutionError)
}

/// Teilen und Ansehen von Loesungen ohne Server (docs/LOESUNGEN-TEILEN.md).
enum SolutionSharing {
    static let cipher = CryptoKitSolutionCipher()
    /// Ablage auf diesem Geraet im aktiven Container (<Container>/solutions/, je Apple-Nutzer und Hochschule)
    static var library: SolutionLibrary {
        ActiveContainer.current?.solutions ?? SolutionLibrary(root: ContainerPaths.none.appendingPathComponent("solutions", isDirectory: true))
    }
    /// Online-Community: noch kein Dienst (wirft "nicht verbunden", sendet nichts)
    static let community: CommunityService = NotConnectedCommunityService()

    /// Meldung "Die Datei passt nicht zu dieser PDF oder wurde verändert" (Import mit passendem Fingerabdruck, der
    /// sich nicht oeffnen laesst).
    static let unreadableImportMessage = "Die Datei passt nicht zu dieser PDF oder wurde verändert. Sie wurde nicht übernommen."

    // MARK: Teilen

    /// Groesse ohne Drehung und eigene Drehung der PDF-Seiten (1-basiert).
    static func pageInfos(_ pdf: PDFDocument) -> [Int: SolutionBuilder.PDFPageInfo] {
        var infos: [Int: SolutionBuilder.PDFPageInfo] = [:]
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox).size
            infos[i + 1] = SolutionBuilder.PDFPageInfo(width: Double(box.width), height: Double(box.height), rotation: page.rotation)
        }
        return infos
    }

    /// Eigene Bilder als PNG zum Einbetten. Bilder ueber den Grenzen fuer Pixelmasse werden verkleinert (sonst
    /// koennte der Empfaenger die Loesung nicht oeffnen); Lage und Groesse auf der Seite stehen im Objekt und
    /// bleiben gleich.
    static func embed(_ images: [String: UIImage]) -> [String: SolutionImage] {
        images.compactMapValues { img in
            let fitted = fitted(img)
            return fitted.pngData().map { SolutionImage(mime: "image/png", data: $0) }
        }
    }

    static func fitted(_ image: UIImage) -> UIImage {
        let w = Int((image.size.width * image.scale).rounded()), h = Int((image.size.height * image.scale).rounded())
        guard w > 0, h > 0, !ForeignSolutionLayer.fitsLimits(width: w, height: h) else { return image }
        let side = Double(SolutionLimits.maxImageSide)
        let f = min(1, side / Double(w), side / Double(h), (Double(SolutionLimits.maxImagePixels) / Double(w * h)).squareRoot())
        let size = CGSize(width: max(1, (Double(w) * f).rounded(.down)), height: max(1, (Double(h) * f).rounded(.down)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Inhalt fuer die gewaehlten Seiten (reines Notizmodell, laeuft auf jedem Thread). `requireOwnNotes: false`
    /// nur fuer die Vorschau (`draft`), geteilt wird nie ein Inhalt ohne eigene Notizen.
    static func content(_ source: SolutionSource, keys: [String], displayName: String, solutionID: UUID = UUID(),
                        createdAt: Date = Date(), requireOwnNotes: Bool = true) throws -> SolutionContent {
        let srcs = Set(SolutionBuilder.imageSources(source.document, keys: keys))
        let infos = source.pageInfos
        return try SolutionBuilder.build(document: source.document, selectedKeys: keys, pdfPageCount: source.pdfPageCount,
                                         pdfPage: { infos[$0] }, images: source.images.filter { srcs.contains($0.key) },
                                         fingerprint: source.fingerprint, title: source.title, displayName: displayName,
                                         solutionID: solutionID, createdAt: createdAt, requireOwnNotes: requireOwnNotes)
    }

    /// Auswahl fuer den Dialog: alle teilbaren Seiten als Vorschau (auch ohne Notizen); Seiten mit Objekten, die
    /// die Pruefungen nicht bestehen, werden genannt und ausgelassen (statt alles zu sperren).
    static func draft(_ source: SolutionSource) throws -> SolutionShareDraft {
        let doc = source.document
        let candidates = SolutionBuilder.candidates(doc)
        let problems = SolutionBuilder.pageProblems(doc, keys: candidates.filter(\.shareable).map(\.key))
        let blocked = Set(problems.map(\.key))
        let keys = candidates.filter { $0.shareable && !blocked.contains($0.key) }.map(\.key)
        let content = keys.isEmpty ? nil : try SolutionSharing.content(source, keys: keys, displayName: "", requireOwnNotes: false)
        return SolutionShareDraft(content: content, selection: Set(SolutionBuilder.defaultSelection(doc)).subtracting(blocked),
                                  assetPages: candidates.filter { !$0.shareable }.count, problems: problems,
                                  hasAnyOwnNotes: candidates.contains { $0.objectCount > 0 })
    }

    /// Verschluesseltes Paket (Schluessel aus den Bytes der Original-PDF).
    static func package(_ content: SolutionContent, originalPDF: Data) throws -> SolutionPackage {
        try SolutionPackage.seal(content, originalPDF: originalPDF, cipher: cipher)
    }

    /// Schreibt das Paket als `Titel – Lösung.uniflowsolution` in einen eigenen temporaeren Ordner (Teilen-Menue).
    static func writeFile(_ package: SolutionPackage, title: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("solution-share", isDirectory: true)
        try? fm.removeItem(at: root)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(PDFExporter.fileName(title, suffix: " – Lösung." + SolutionPackage.fileExtension))
        try package.encoded().write(to: url, options: .atomic)
        return url
    }

    /// Erzeugen, Versiegeln, Datei schreiben und unter "Meine geteilten Lösungen" merken, abseits des Hauptthreads
    /// (HKDF ueber die ganze PDF, Verschluesselung).
    static func shareFile(_ source: SolutionSource, keys: [String], displayName: String,
                          library: SolutionLibrary = library) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let built = try SolutionSharing.content(source, keys: keys, displayName: displayName)
            let sealed = try SolutionSharing.package(built, originalPDF: source.originalPDF)
            let url = try SolutionSharing.writeFile(sealed, title: source.title)
            try library.recordShared(sealed, title: source.title)
            return url
        }.value
    }

    // MARK: Ansehen

    /// Ebene aus einem geoeffneten Inhalt. Prueft, dass jede PDF-Seite zur eigenen PDF passt (Seitenzahl und Groesse)
    /// und dass die Bilder in den Grenzen liegen; sonst wird die ganze Ebene abgewiesen, nie ein Teil davon gezeigt.
    static func layer(_ content: SolutionContent, visible: Bool, pdf: PDFDocument) throws -> ForeignSolutionLayer {
        guard content.pdfPageCount == pdf.pageCount else { throw SolutionError.fingerprintMismatch }
        for p in content.pages where p.kind == .pdf {
            guard let i = p.pdfIndex, let page = pdf.page(at: i - 1) else { throw SolutionError.fingerprintMismatch }
            let box = page.bounds(for: .cropBox).size
            guard abs(Double(box.width) - p.width) < 0.5, abs(Double(box.height) - p.height) < 0.5,
                  SolutionGeometry.normalized(page.rotation + p.extraRotation) == p.rotation else {
                throw SolutionError.invalidContent("Seite \(i) passt nicht zur PDF")
            }
        }
        return ForeignSolutionLayer(id: content.solutionID, displayName: content.displayName, createdAt: content.createdAt,
                                    visible: visible, pages: content.pages, images: try ForeignSolutionLayer.uiImages(content.images),
                                    missingImages: content.missingImages.count)
    }

    /// Alle empfangenen Loesungen zum Fingerabdruck entschluesseln (nur Arbeitsspeicher). Ohne PDFKit und UIKit,
    /// laeuft daher abseits des Hauptthreads.
    static func openAll(library: SolutionLibrary, originalPDF: Data, fingerprint: String,
                        cipher: SolutionCipher) -> [(entry: SolutionLibrary.Entry, result: Result<SolutionContent, Error>)] {
        library.entries(fingerprint: fingerprint).map { entry in
            (entry, Result { try library.package(entry.solutionID).open(originalPDF: originalPDF, cipher: cipher) })
        }
    }

    /// Geoeffnete Inhalte als Ebenen (Seitenpruefung gegen die eigene PDF, Bildmasse).
    static func layers(_ opened: [(entry: SolutionLibrary.Entry, result: Result<SolutionContent, Error>)],
                       pdf: PDFDocument) -> SolutionLayerLoad {
        var out = SolutionLayerLoad()
        for (entry, result) in opened {
            let label = ForeignSolutionLayer.label(displayName: entry.displayName, createdAt: entry.createdAt)
            do {
                out.layers.append(try layer(try result.get(), visible: entry.visible, pdf: pdf))
            } catch {
                out.problems.append(.init(id: entry.solutionID, label: label, message: message(error)))
            }
        }
        return out
    }

    /// Alle empfangenen Loesungen zum Fingerabdruck dieser PDF oeffnen (synchron; die App nimmt
    /// `DocumentStore.solutionLayers`, das abseits des Hauptthreads entschluesselt). Das eigene Notizmodell wird
    /// dabei nicht beruehrt.
    static func loadLayers(library: SolutionLibrary = library, originalPDF: Data, fingerprint: String, pdf: PDFDocument,
                           cipher: SolutionCipher = cipher) -> SolutionLayerLoad {
        layers(openAll(library: library, originalPDF: originalPDF, fingerprint: fingerprint, cipher: cipher), pdf: pdf)
    }

    static func message(_ error: Error) -> String {
        (error as? SolutionError)?.description ?? error.localizedDescription
    }

    /// Datei *.uniflowsolution uebernehmen (Teilen-Menue, Dateien-App, AirDrop): Kopf pruefen, verschluesselt ablegen.
    /// `notify: false`, wenn der Aufrufer selbst noch prueft und danach meldet.
    @discardableResult
    static func importFile(_ url: URL, into library: SolutionLibrary = library, notify: Bool = true) throws -> SolutionLibrary.Entry {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SolutionLimits.maxPackageBytes else { throw SolutionError.tooLarge }
        let entry = try library.importPackage(try Data(contentsOf: url))
        if notify { NotificationCenter.default.post(name: .uniflowSolutionsChanged, object: nil) }
        return entry
    }

    /// "Lösung importieren …" im offenen Dokument: ablegen und, wenn der Fingerabdruck zu dieser PDF passt, sofort
    /// oeffnen. Laesst sie sich trotz passendem Fingerabdruck nicht oeffnen (manipuliertes Chiffrat, mit einer anderen
    /// PDF versiegelt), wird sie gleich wieder entfernt, damit keine dauerhafte, nicht entfernbare Meldung bleibt.
    @MainActor
    static func importChecked(_ url: URL, into library: SolutionLibrary = library, originalPDF: Data, fingerprint: String,
                              pdf: PDFDocument, cipher: SolutionCipher = cipher) async throws -> SolutionImportResult {
        let entry = try importFile(url, into: library, notify: false)
        defer { NotificationCenter.default.post(name: .uniflowSolutionsChanged, object: nil) }
        guard entry.fingerprint == fingerprint else { return .otherPDF(entry) }
        let opened = await Task.detached(priority: .userInitiated) {
            Result { try library.package(entry.solutionID).open(originalPDF: originalPDF, cipher: cipher) }
        }.value
        do {
            _ = try layer(try opened.get(), visible: entry.visible, pdf: pdf)
            return .shown(entry)
        } catch {
            try? library.remove(entry.solutionID)
            return .removedUnreadable(entry, (error as? SolutionError) ?? .decryptionFailed)
        }
    }

    static func isSolutionFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == SolutionPackage.fileExtension
    }
}

/// Meldungen zu nicht lesbaren Loesungen nur einmal je Sitzung (App-Start) als Hinweis zeigen; danach stehen sie nur
/// noch im Ebenen-Menue unter "Nicht lesbare Lösungen".
@MainActor
enum SolutionProblemNotices {
    private static var shown: Set<String> = []

    /// Noch nicht gemeldete Probleme (und merkt sie als gemeldet).
    static func unseen(_ problems: [SolutionLayerLoad.Problem]) -> [SolutionLayerLoad.Problem] {
        problems.filter { shown.insert($0.id + "|" + $0.message).inserted }
    }

    static func resetForTesting() { shown = [] }
}

extension DocumentStore {
    /// Quelle fuer den Dialog "Lösung teilen". Ausstehende Striche werden vorher verarbeitet (der letzte Strich ist
    /// dabei), das Notizmodell wird nur gelesen. Bilder der Seiten, die in dieser Sitzung noch nicht angezeigt
    /// wurden, werden mit `loadImage` nachgeladen (Zeitlimit); was fehlt, zaehlt das Paket als fehlend. Das
    /// Einbetten (PNG) laeuft abseits des Hauptthreads.
    func solutionSource(loadImage: ShareExport.ImageLoader?) async throws -> SolutionSource {
        guard let pdf = originalPDF else { throw ShareExportError.notLoaded }
        let doc = await pageStructureDocument()
        let data = try originalPDFData()
        guard let fp = await originalFingerprint() else { throw ShareExportError.notLoaded }
        let keys = SolutionBuilder.candidates(doc).filter(\.shareable).map(\.key)
        let loaded = await ShareExport.completeImages(images, sources: SolutionBuilder.imageSources(doc, keys: keys), load: loadImage)
        let own = loaded.images
        let embedded = await Task.detached(priority: .userInitiated) { SolutionSharing.embed(own) }.value
        return SolutionSource(document: doc, originalPDF: data, pdfPageCount: pdf.pageCount,
                              pageInfos: SolutionSharing.pageInfos(pdf), fingerprint: fp, images: embedded,
                              title: ShareExport.cleanTitle(file.displayTitle))
    }

    /// Passende empfangene Loesungen dieses Dokuments. Lesen und Entschluesseln (HKDF ueber die ganze PDF) laufen
    /// abseits des Hauptthreads, die Seitenpruefung danach hier.
    func solutionLayers(library: SolutionLibrary = SolutionSharing.library) async -> SolutionLayerLoad {
        guard let pdf = originalPDF, let fp = await originalFingerprint(), let data = try? originalPDFData() else {
            return SolutionLayerLoad()
        }
        let cipher = SolutionSharing.cipher
        let opened = await Task.detached(priority: .userInitiated) {
            SolutionSharing.openAll(library: library, originalPDF: data, fingerprint: fp, cipher: cipher)
        }.value
        return SolutionSharing.layers(opened, pdf: pdf)
    }

    /// "Lösung importieren …" in diesem Dokument (siehe `SolutionSharing.importChecked`).
    func importSolution(_ url: URL, library: SolutionLibrary = SolutionSharing.library) async throws -> SolutionImportResult {
        guard let pdf = originalPDF, let fp = await originalFingerprint() else {
            return .otherPDF(try SolutionSharing.importFile(url, into: library))
        }
        return try await SolutionSharing.importChecked(url, into: library, originalPDF: try originalPDFData(), fingerprint: fp, pdf: pdf)
    }
}
