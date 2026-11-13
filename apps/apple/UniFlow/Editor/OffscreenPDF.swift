import PDFKit
import UIKit
import UniFlowCore

/// PDF-Seiten ausserhalb des Hauptthreads zeichnen (Seitenminiaturen, Scans fuer die Suche) – immer aus einer EIGENEN,
/// getrennt aus der Datei geoeffneten PDF-Instanz, nie aus der PDF der PDFView oder dem Original im Store.
///
/// Hintergrund (Absturz Build 30, iPad 9 mit iPadOS 26.5, 11.11.2026): PDFKit gab beim Scrollen eine Kachel-Oberflaeche
/// zu oft frei (`-[PDFTileSurface releaseSurface]`). Der Fehler sitzt in PDFKit (Apple-Forum 837282/838272, fast nur
/// iPad 9 mit 26.4/26.5, Speicherdruck); die App soll PDFKit dabei nicht zusaetzlich reizen. Vorher zeichneten die
/// Miniaturen Kopien (`page.copy()`) der angezeigten Seiten im Hintergrund – eine Kopie teilt die CGPDFPage mit der
/// Seite in der PDFView, PDFKit ist dafuer nicht threadsicher.
///
/// Der Actor fuehrt alle Zugriffe nacheinander aus; die Instanz entsteht beim ersten Zeichnen und wird bei einer
/// Speicherwarnung oder beim Schliessen freigegeben (`release`).
actor OffscreenPDF {
    /// Form einer angezeigten Seite, auf dem Hauptthread aus dem Seitenaufbau gelesen (reine Werte, keine PDFKit-Objekte)
    struct Shape: Sendable, Equatable {
        /// CropBox der Seite (ohne Drehung)
        let cropBox: CGRect
        /// Drehung der angezeigten Seite (`/Rotate` plus Drehung aus `pageOrder`)
        let rotation: Int
        /// PDF-Seite (1-basiert) im Original; nil fuer Leer- und Browser-Seiten (die zeichnet `PageRenderer` weiss)
        let pdfIndex: Int?

        @MainActor
        init(page: PDFPage, entry: DisplayLayout.Entry) {
            cropBox = page.bounds(for: .cropBox)
            rotation = page.rotation
            pdfIndex = entry.kind == "pdf" ? entry.pdfIndex : nil
        }

        init(cropBox: CGRect, rotation: Int, pdfIndex: Int?) {
            self.cropBox = cropBox
            self.rotation = rotation
            self.pdfIndex = pdfIndex
        }
    }

    /// Datei der Original-PDF (nil: Notizbuch ohne PDF)
    nonisolated let url: URL?
    private var document: PDFDocument?
    private var openFailed = false
    /// Zahl der Seiten, die aus der eigenen Instanz gezeichnet wurden (Tests, Diagnose)
    private(set) var pdfPagesDrawn = 0

    init(url: URL?) { self.url = url }

    /// Eigene Instanz (fuer Tests: darf nie die der PDFView sein)
    func documentForTesting() -> PDFDocument? { openIfNeeded() }

    /// Instanz freigeben (Speicherwarnung, Seitenleiste zu); beim naechsten Zeichnen wird neu geoeffnet
    func release() {
        document = nil
        openFailed = false
    }

    private func openIfNeeded() -> PDFDocument? {
        if let document { return document }
        guard !openFailed, let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        document = PDFDocument(url: url)
        openFailed = document == nil
        return document
    }

    /// Seite fuer das Zeichnen: PDF-Seite aus der eigenen Instanz (Kopie mit der angezeigten Drehung), sonst eine leere
    /// Seite derselben Form. Ohne lesbare Datei bleibt auch eine PDF-Seite leer (weiss) statt die PDFView anzufassen.
    private func page(for shape: Shape) -> PDFPage {
        if let i = shape.pdfIndex, i >= 1, let src = openIfNeeded()?.page(at: i - 1), let copy = src.copy() as? PDFPage {
            copy.rotation = shape.rotation
            pdfPagesDrawn += 1
            return copy
        }
        let blank = PDFPage()
        blank.setBounds(shape.cropBox, for: .mediaBox)
        blank.setBounds(shape.cropBox, for: .cropBox)
        blank.rotation = shape.rotation
        return blank
    }

    /// Miniatur wie `PageRenderer.thumbnail`, die PDF-Seite aus der eigenen Instanz
    func thumbnail(shape: Shape, entry: DisplayLayout.Entry, objects: [JSONValue], images: [String: UIImage],
                   width: CGFloat, scale: CGFloat) -> UIImage {
        PageRenderer.thumbnail(page: page(for: shape), entry: entry, objects: objects, images: images, width: width, scale: scale)
    }

    /// Seitenzahl der eigenen Instanz (nil: Datei fehlt oder ist nicht lesbar)
    func pageCount() -> Int? { openIfNeeded()?.pageCount }

    /// Vorschau einer fremden Loesungsseite mit der eigenen PDF-Seite darunter ("Daneben ansehen", `SolutionPreview`)
    func solutionPreview(_ page: SolutionPage, images: [String: UIImage], width: CGFloat, scale: CGFloat) -> UIImage {
        let pdfPage = page.kind == .pdf ? page.pdfIndex.flatMap { openIfNeeded()?.page(at: $0 - 1) } : nil
        if pdfPage != nil { pdfPagesDrawn += 1 }
        return SolutionPreview.image(page, images: images, width: width, scale: scale, pdfPage: pdfPage)
    }

    /// Seite als Bild fuer die Texterkennung (`NoteSearch.pageImage`), nil ohne PDF-Seite
    func scanImage(shape: Shape) -> CGImage? {
        guard shape.pdfIndex != nil else { return nil }
        let p = page(for: shape)
        guard p.pageRef != nil else { return nil }                       // Datei nicht lesbar: nichts erkennen
        return NoteSearch.pageImage(p)
    }
}
