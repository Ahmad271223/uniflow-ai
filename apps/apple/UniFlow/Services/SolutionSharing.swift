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
/// Original-PDF (nur fuer Fingerabdruck und Schluessel, sie gelangen nie ins Paket) und die eigenen Bilder.
struct SolutionSource {
    let document: AnnotationDocument
    let originalPDF: Data
    /// Original-PDF wie geladen (Seitengroesse und eigene Drehung je PDF-Seite)
    let pdf: PDFDocument
    let fingerprint: String
    let images: [String: UIImage]
    let title: String
}

/// Ergebnis beim Laden der passenden Loesungen fuer ein Dokument.
struct SolutionLayerLoad {
    var layers: [ForeignSolutionLayer] = []
    /// Meldungen zu Loesungen, die nicht angezeigt werden (nichts davon erscheint, auch nicht teilweise)
    var problems: [String] = []
}

/// Teilen und Ansehen von Loesungen ohne Server (docs/LOESUNGEN-TEILEN.md).
enum SolutionSharing {
    static let cipher = CryptoKitSolutionCipher()
    /// Ablage auf diesem Geraet (Application Support/UniFlow/solutions/)
    static let library = SolutionLibrary(root: AppPaths.solutions)
    /// Online-Community: noch kein Dienst (wirft "nicht verbunden", sendet nichts)
    static let community: CommunityService = NotConnectedCommunityService()

    // MARK: Teilen

    /// Groesse ohne Drehung und eigene Drehung der PDF-Seiten (1-basiert).
    static func pageInfo(_ pdf: PDFDocument) -> (Int) -> SolutionBuilder.PDFPageInfo? {
        var infos: [Int: SolutionBuilder.PDFPageInfo] = [:]
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox).size
            infos[i + 1] = SolutionBuilder.PDFPageInfo(width: Double(box.width), height: Double(box.height), rotation: page.rotation)
        }
        return { infos[$0] }
    }

    /// Eigene Bilder als PNG zum Einbetten.
    static func embed(_ images: [String: UIImage]) -> [String: SolutionImage] {
        images.compactMapValues { img in img.pngData().map { SolutionImage(mime: "image/png", data: $0) } }
    }

    /// Inhalt fuer die gewaehlten Seiten.
    static func content(_ source: SolutionSource, keys: [String], displayName: String, solutionID: UUID = UUID(),
                        createdAt: Date = Date()) throws -> SolutionContent {
        let srcs = Set(SolutionBuilder.imageSources(source.document, keys: keys))
        return try SolutionBuilder.build(document: source.document, selectedKeys: keys, pdfPageCount: source.pdf.pageCount,
                                         pdfPage: pageInfo(source.pdf), images: embed(source.images.filter { srcs.contains($0.key) }),
                                         fingerprint: source.fingerprint, title: source.title, displayName: displayName,
                                         solutionID: solutionID, createdAt: createdAt)
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
        let url = dir.appendingPathComponent(PDFExporter.safeFileName(title) + " – Lösung." + SolutionPackage.fileExtension)
        try package.encoded().write(to: url, options: .atomic)
        return url
    }

    // MARK: Ansehen

    /// Ebene aus einem geoeffneten Inhalt. Prueft, dass jede PDF-Seite zur eigenen PDF passt (Seitenzahl und Groesse);
    /// sonst wird die ganze Ebene abgewiesen, nie ein Teil davon gezeigt.
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
                                    visible: visible, pages: content.pages, images: ForeignSolutionLayer.uiImages(content.images),
                                    missingImages: content.missingImages.count)
    }

    /// Alle empfangenen Loesungen zum Fingerabdruck dieser PDF oeffnen. Nur im Arbeitsspeicher entschluesselt; das
    /// eigene Notizmodell wird dabei nicht beruehrt.
    static func loadLayers(library: SolutionLibrary = library, originalPDF: Data, fingerprint: String, pdf: PDFDocument,
                           cipher: SolutionCipher = cipher) -> SolutionLayerLoad {
        var out = SolutionLayerLoad()
        for entry in library.entries(fingerprint: fingerprint) {
            let label = ForeignSolutionLayer.label(displayName: entry.displayName, createdAt: entry.createdAt)
            do {
                let content = try library.package(entry.solutionID).open(originalPDF: originalPDF, cipher: cipher)
                out.layers.append(try layer(content, visible: entry.visible, pdf: pdf))
            } catch {
                out.problems.append("\(label): \((error as? SolutionError)?.description ?? error.localizedDescription)")
            }
        }
        return out
    }

    /// Datei *.uniflowsolution uebernehmen (Teilen-Menue, Dateien-App, AirDrop): Kopf pruefen, verschluesselt ablegen.
    @discardableResult
    static func importFile(_ url: URL, into library: SolutionLibrary = library) throws -> SolutionLibrary.Entry {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SolutionLimits.maxPackageBytes else { throw SolutionError.tooLarge }
        let entry = try library.importPackage(try Data(contentsOf: url))
        NotificationCenter.default.post(name: .uniflowSolutionsChanged, object: nil)
        return entry
    }

    static func isSolutionFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == SolutionPackage.fileExtension
    }
}

extension DocumentStore {
    /// Quelle fuer den Dialog "Lösung teilen". Ausstehende Striche werden vorher verarbeitet (der letzte Strich ist
    /// dabei), das Notizmodell wird nur gelesen. Bilder der Seiten, die in dieser Sitzung noch nicht angezeigt
    /// wurden, werden mit `loadImage` nachgeladen (Zeitlimit); was fehlt, zaehlt das Paket als fehlend.
    func solutionSource(loadImage: ShareExport.ImageLoader?) async throws -> SolutionSource {
        guard let pdf = originalPDF else { throw ShareExportError.notLoaded }
        let doc = await pageStructureDocument()
        let data = try originalPDFData()
        guard let fp = await originalFingerprint() else { throw ShareExportError.notLoaded }
        let keys = SolutionBuilder.candidates(doc).filter(\.shareable).map(\.key)
        let loaded = await ShareExport.completeImages(images, sources: SolutionBuilder.imageSources(doc, keys: keys), load: loadImage)
        return SolutionSource(document: doc, originalPDF: data, pdf: pdf, fingerprint: fp, images: loaded.images,
                              title: ShareExport.cleanTitle(file.displayTitle))
    }

    /// Passende empfangene Loesungen dieses Dokuments.
    func solutionLayers(library: SolutionLibrary = SolutionSharing.library) async -> SolutionLayerLoad {
        guard let pdf = originalPDF, let fp = await originalFingerprint(), let data = try? originalPDFData() else {
            return SolutionLayerLoad()
        }
        return SolutionSharing.loadLayers(library: library, originalPDF: data, fingerprint: fp, pdf: pdf)
    }
}
