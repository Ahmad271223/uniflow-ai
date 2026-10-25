import Foundation

/// Baut den Inhalt eines Loesungspakets aus dem eigenen Notizmodell. Liest nur, aendert nie etwas am Dokument.
///
/// - PDF-Seiten: 1-basierter Index, CropBox ohne Drehung und Drehung der angezeigten Seite (`/Rotate` der PDF plus
///   `rotation` aus `pageOrder`), Objekte 1:1.
/// - Eigene Leerseiten (`type: "blank"`): Vorlage, Breite/Hoehe aus `pageOrder`, Objekte 1:1.
/// - Eingefuegte Bild- oder PDF-Seiten aus dem Browser (`type: "asset"`) werden nie geteilt: ihr Hintergrund kann
///   fremdes Material sein.
/// - `pkdrawing` (native PencilKit-Daten) bleibt weg; die Striche stehen vollstaendig in `objects`.
public enum SolutionBuilder {

    /// Seite der Original-PDF beim Absender.
    public struct PDFPageInfo: Equatable, Sendable {
        /// CropBox ohne Drehung (PDF-Punkte).
        public var width: Double
        public var height: Double
        /// Eigene Drehung der PDF-Seite (`/Rotate`).
        public var rotation: Int

        public init(width: Double, height: Double, rotation: Int) {
            self.width = width
            self.height = height
            self.rotation = rotation
        }
    }

    /// Seite aus `pageOrder` zur Auswahl im Dialog.
    public struct Candidate: Equatable, Sendable {
        public var key: String
        /// pdf | blank | asset
        public var type: String
        public var pdfIndex: Int?
        public var template: String?
        public var objectCount: Int
        /// asset-Seiten lassen sich nicht teilen.
        public var shareable: Bool { type == "pdf" || type == "blank" }
    }

    /// Seiten in Anzeigereihenfolge (ohne Papierkorb).
    public static func candidates(_ doc: AnnotationDocument) -> [Candidate] {
        var seen = Set<String>()
        return doc.pageOrder.compactMap { p in
            guard let key = p["key"]?.string, seen.insert(key).inserted else { return nil }
            let type = p["type"]?.string ?? "pdf"
            return Candidate(key: key, type: type, pdfIndex: type == "pdf" ? p["index"]?.int : nil,
                             template: p["template"]?.string ?? doc.page(key)?["template"]?.string,
                             objectCount: doc.objects(page: key).count)
        }
    }

    /// Standardauswahl: teilbare Seiten mit eigenen Anmerkungen.
    public static func defaultSelection(_ doc: AnnotationDocument) -> [String] {
        candidates(doc).filter { $0.shareable && $0.objectCount > 0 }.map(\.key)
    }

    /// Seite, die sich nicht teilen laesst, mit Grund (fuer den Dialog).
    public struct PageProblem: Equatable, Sendable {
        public var key: String
        /// z. B. "PDF-Seite 3" oder "Eigene Seite 2"
        public var label: String
        public var error: SolutionError
    }

    /// Bezeichnung einer Seite fuer Meldungen: PDF-Seite mit Index, eigene Leerseite mit Position in der Anzeige.
    public static func pageLabel(_ doc: AnnotationDocument, key: String) -> String {
        let order = candidates(doc)
        guard let i = order.firstIndex(where: { $0.key == key }) else { return "Seite „\(key)“" }
        if let p = order[i].pdfIndex { return "PDF-Seite \(p)" }
        return order[i].type == "blank" ? "Eigene Seite \(i + 1)" : "Eingefügte Seite \(i + 1)"
    }

    /// Gewaehlte Seiten, deren Objekte die Pruefungen nicht bestehen (unbekannter Objekttyp, ungueltige Zahlen,
    /// PDF-Daten). Der Dialog nennt sie und laesst sie aus, statt still etwas zu verlieren.
    public static func pageProblems(_ doc: AnnotationDocument, keys: [String]) -> [PageProblem] {
        keys.compactMap { key in
            do {
                for o in doc.objects(page: key) { try SolutionValidator.validateObject(o) }
                return nil
            } catch {
                return PageProblem(key: key, label: pageLabel(doc, key: key),
                                   error: (error as? SolutionError) ?? .invalidContent("Objekt"))
            }
        }
    }

    /// Quellen der Bildobjekte auf den gewaehlten Seiten (sortiert, ohne Doppelte).
    public static func imageSources(_ doc: AnnotationDocument, keys: [String]) -> [String] {
        var out = Set<String>()
        for k in keys {
            for o in doc.objects(page: k) where o["type"]?.string == "image" {
                if let s = o["src"]?.string, !s.isEmpty { out.insert(s) }
            }
        }
        return out.sorted()
    }

    /// - Parameters:
    ///   - selectedKeys: Seitenschluessel; Reihenfolge wie in `pageOrder`, Doppelte zaehlen einmal.
    ///   - pdfPage: Groesse und Drehung einer PDF-Seite (1-basiert), `nil` = gibt es nicht.
    ///   - images: verfuegbare eigene Bilder nach `src`; fehlende werden in `missingImages` gezaehlt.
    ///   - fingerprint: SHA-256 der unveraenderten Original-PDF-Datei.
    ///   - requireOwnNotes: `true` (Teilen): ohne ein einziges eigenes Notizobjekt entsteht kein Inhalt
    ///     (`SolutionError.noOwnNotes`). `false` nur fuer die Vorschau im Dialog: dort stehen auch Seiten ohne
    ///     Notizen, damit der Dialog die eigentlichen Gruende nennt (ausgelassene oder eingefuegte Seiten).
    public static func build(document doc: AnnotationDocument, selectedKeys: [String], pdfPageCount: Int,
                             pdfPage: (Int) -> PDFPageInfo?, images: [String: SolutionImage], fingerprint: String,
                             title: String, displayName: String, solutionID: UUID = UUID(),
                             createdAt: Date = Date(), requireOwnNotes: Bool = true) throws -> SolutionContent {
        let wanted = Set(selectedKeys)
        guard !wanted.isEmpty else { throw SolutionError.nothingSelected }
        var pages: [SolutionPage] = []
        var seen = Set<String>()
        for entry in doc.pageOrder {
            guard let key = entry["key"]?.string, wanted.contains(key), seen.insert(key).inserted else { continue }
            let type = entry["type"]?.string ?? "pdf"
            let extra = SolutionGeometry.normalized(entry["rotation"]?.int ?? 0)
            let objects = doc.objects(page: key)
            do {
                for o in objects { try SolutionValidator.validateObject(o) }
            } catch let e as SolutionError {
                throw SolutionError.onPage(pageLabel(doc, key: key), e)
            }
            switch type {
            case "pdf":
                guard let i = entry["index"]?.int, i >= 1, i <= pdfPageCount, let info = pdfPage(i) else {
                    throw SolutionError.invalidContent("PDF-Seite \(entry["index"]?.int ?? 0)")
                }
                pages.append(SolutionPage(key: key, kind: .pdf, pdfIndex: i, width: info.width, height: info.height,
                                          rotation: info.rotation + extra, extraRotation: extra, objects: objects))
            case "blank":
                let w = entry["w"]?.double ?? 595, h = entry["h"]?.double ?? 842
                let t = entry["template"]?.string ?? doc.page(key)?["template"]?.string
                pages.append(SolutionPage(key: key, kind: .blank, pdfIndex: nil, width: w > 0 ? w : 595, height: h > 0 ? h : 842,
                                          rotation: extra, extraRotation: extra,
                                          template: t.flatMap { PageOrder.templates.contains($0) ? $0 : "blank" },
                                          objects: objects))
            default:
                throw SolutionError.invalidContent("eingefügte Bild-/PDF-Seite")
            }
        }
        guard !pages.isEmpty else { throw SolutionError.nothingSelected }
        // nie ein Paket ohne Inhalt (z. B. "Alle" gewaehlt, aber keine Seite mit Notizen)
        if requireOwnNotes, !pages.contains(where: { !$0.objects.isEmpty }) { throw SolutionError.noOwnNotes }
        var embedded: [String: SolutionImage] = [:]
        var missing: [String] = []
        for src in imageSources(doc, keys: pages.map(\.key)) {
            if let img = images[src], SolutionImage.sniff(img.data) == img.mime { embedded[src] = img } else { missing.append(src) }
        }
        let name = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SolutionLimits.maxDisplayName))
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SolutionLimits.maxTitle))
        let content = SolutionContent(solutionID: solutionID.uuidString.lowercased(), createdAt: SolutionPackage.timestamp(createdAt),
                                      title: cleanTitle, displayName: name, fingerprint: fingerprint.lowercased(),
                                      pdfPageCount: pdfPageCount, pages: pages, images: embedded, missingImages: missing)
        // Inhalt gegen dieselben Regeln wie beim Empfaenger pruefen (Grenzen, Bilder, Zahlen)
        _ = try SolutionContent(json: content.json)
        return content
    }
}
