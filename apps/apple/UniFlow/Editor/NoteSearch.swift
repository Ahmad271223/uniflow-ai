import PDFKit
import PencilKit
import UIKit
import UniFlowCore
import Vision

/// Suche in den eigenen Notizen (10.11.2026): Bisher fand "Suchen" nur den gedruckten Text der PDF. Jetzt auch
/// - Textfelder und Haftnotizen (sofort, aus den Notizobjekten),
/// - Handschrift (Texterkennung von Vision ueber ein Bild nur der Striche einer Seite),
/// - eingescannte Seiten ohne Textebene (Texterkennung ueber das Seitenbild).
/// Erkannte Texte bleiben je Seite im Speicher, solange das Dokument offen ist; eine Seite wird nur neu gelesen, wenn
/// sich ihre Striche geaendert haben (Kennung aus Zahl und Lage der Striche).
enum NoteSearch {
    enum Source: String, CaseIterable {
        case pdf, typed, handwriting, scan

        var title: String {
            switch self {
            case .pdf: return "Im PDF"
            case .typed: return "In Textfeldern und Haftnotizen"
            case .handwriting: return "In deiner Handschrift"
            case .scan: return "Auf eingescannten Seiten"
            }
        }

        var icon: String {
            switch self {
            case .pdf: return "doc.text"
            case .typed: return "textformat"
            case .handwriting: return "pencil.and.scribble"
            case .scan: return "doc.viewfinder"
            }
        }
    }

    /// Text der Textfelder und Haftnotizen einer Seite (eine Zeile je Objekt)
    static func typedText(_ objects: [JSONValue]) -> String {
        objects.compactMap { o -> String? in
            guard o["type"]?.string == "text", let t = o["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            return t
        }.joined(separator: "\n")
    }

    /// Text zum Vergleichen: klein, ohne Akzente, Zeilenumbrueche als Leerzeichen, Leerraum zusammengefasst
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Ausschnitte um jeden Treffer von `query` in `text` (hoechstens `limit`), sonst leer. Mindestens zwei Zeichen.
    static func snippets(in text: String, query: String, limit: Int = 3, radius: Int = 60) -> [String] {
        let q = fold(query)
        guard q.count >= 2 else { return [] }
        let plain = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let folded = fold(plain)
        // `fold` aendert die Laenge nicht bei normalen Buchstaben; bei abweichender Laenge den gefalteten Text zeigen
        let shown = folded.count == plain.count ? plain : folded
        var out: [String] = []
        var from = folded.startIndex
        while out.count < limit, let r = folded.range(of: q, range: from..<folded.endIndex) {
            let start = folded.distance(from: folded.startIndex, to: r.lowerBound)
            let end = folded.distance(from: folded.startIndex, to: r.upperBound)
            let a = max(0, start - radius), b = min(shown.count, end + radius)
            let s = shown.index(shown.startIndex, offsetBy: a), e = shown.index(shown.startIndex, offsetBy: b)
            out.append((a > 0 ? "…" : "") + String(shown[s..<e]) + (b < shown.count ? "…" : ""))
            from = r.upperBound
        }
        return out
    }

    /// Kennung der Striche einer Seite (aendert sich mit jedem Strich, ohne die Zeichnung zu kodieren)
    static func signature(_ drawing: PKDrawing) -> Int {
        var h = Hasher()
        h.combine(drawing.strokes.count)
        let b = drawing.bounds
        if !b.isNull { h.combine(Int(b.minX * 10)); h.combine(Int(b.minY * 10)); h.combine(Int(b.width * 10)); h.combine(Int(b.height * 10)) }
        for s in drawing.strokes.suffix(8) { h.combine(s.path.count); h.combine(s.path.creationDate) }
        return h.finalize()
    }

    /// Nur die Striche einer Seite als Bild (weisser Grund, Tinte immer dunkel wie auf Papier), fuer die Texterkennung.
    /// Textmarker bleiben weg (sie verdecken nur). Hoechstens `maxPixels` an der laengsten Seite.
    static func inkImage(_ drawing: PKDrawing, pageSize: CGSize, maxPixels: CGFloat = 3000) -> CGImage? {
        let strokes = drawing.strokes.filter { $0.ink.inkType != .marker }
        guard !strokes.isEmpty, pageSize.width > 0, pageSize.height > 0 else { return nil }
        let ink = PKDrawing(strokes: strokes)
        let rect = ink.bounds.insetBy(dx: -20, dy: -20).intersection(CGRect(origin: .zero, size: pageSize))
        guard !rect.isNull, rect.width >= 4, rect.height >= 4 else { return nil }
        let scale = min(3, maxPixels / max(rect.width, rect.height))
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = ink.image(from: rect, scale: scale) }
        guard let image else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }.cgImage
    }

    /// Seite ohne Textebene? (eingescannt: PDFKit liefert keinen oder fast keinen Text)
    static func needsScanOCR(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 8
    }

    /// PDF-Seite als Bild fuer die Texterkennung (Graustufen genuegen Vision; weisser Grund)
    nonisolated static func pageImage(_ page: PDFPage, maxPixels: CGFloat = 3000) -> CGImage? {
        let size = PageRenderer.size(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(2, maxPixels / max(size.width, size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .cropBox, to: ctx.cgContext)
        }.cgImage
    }
}

/// Suchtext je Seite fuer "Suchen" (Textfelder sofort, Handschrift und Scans im Hintergrund nach und nach).
@MainActor
final class NoteTextIndex: ObservableObject {
    struct PageText: Equatable {
        var typed = ""
        var handwriting = ""
        var scan = ""
    }

    /// Seitenschluessel -> Texte
    @Published private(set) var pages: [String: PageText] = [:]
    /// Fortschritt der Texterkennung (nil: fertig bzw. nicht gestartet)
    @Published private(set) var reading: (done: Int, total: Int)?
    private var inkSignatures: [String: Int] = [:]
    private var scanned: Set<String> = []
    private var task: Task<Void, Never>?
    /// Erkennung austauschbar (Tests)
    var recognize: (CGImage) async -> String = { await PDFEditorController.recognizeText($0) }

    /// Alles neu einsammeln (beim Oeffnen der Suche): Textfelder sofort, dann Handschrift und Scans, sichtbare Seite
    /// zuerst. Laeuft schon ein Durchgang, wird er ersetzt (bereits Gelesenes bleibt).
    func refresh(store: DocumentStore, startAt current: Int = 0) {
        task?.cancel()
        guard let layout = store.layout else { return }
        let entries = layout.entries
        let order = entries.indices.sorted { abs($0 - current) < abs($1 - current) }
        task = Task { [weak self, weak store] in
            guard let self, let store else { return }
            // 1. Textfelder (schnell); Seiten mit neuer Handschrift nur merken (Zeichnungen nicht alle im Speicher halten)
            var drawings: [(Int, String)] = []
            for i in order {
                guard !Task.isCancelled else { return }
                let key = entries[i].key
                let objects = await store.objects(forPageKey: key)
                self.pages[key, default: PageText()].typed = NoteSearch.typedText(objects)
                let drawing = await store.drawing(forPageKey: key)
                if !drawing.strokes.isEmpty, self.inkSignatures[key] != NoteSearch.signature(drawing) {
                    drawings.append((i, key))
                } else if drawing.strokes.isEmpty {
                    self.pages[key]?.handwriting = ""
                    self.inkSignatures[key] = nil
                }
            }
            // 2. Handschrift und Scans
            let scans = order.filter { i in
                entries[i].kind == "pdf" && !self.scanned.contains(entries[i].key)
                    && (layout.pdf.page(at: i).map(NoteSearch.needsScanOCR) ?? false)
            }
            let total = drawings.count + scans.count
            guard total > 0 else { self.reading = nil; return }
            var done = 0
            self.reading = (0, total)
            for (i, key) in drawings {
                guard !Task.isCancelled else { return }
                let drawing = await store.drawing(forPageKey: key)
                let size = layout.pdf.page(at: i).map(PageRenderer.size(of:)) ?? .zero
                let text = await NoteSearch.inkImage(drawing, pageSize: size).asyncMap(self.recognize) ?? ""
                guard !Task.isCancelled else { return }
                self.pages[key, default: PageText()].handwriting = text
                self.inkSignatures[key] = NoteSearch.signature(drawing)
                done += 1
                self.reading = (done, total)
            }
            for i in scans {
                guard !Task.isCancelled, let page = layout.pdf.page(at: i) else { return }
                let key = entries[i].key
                let box = PageBox(page: page.copy() as? PDFPage ?? page)
                let image = await Task.detached(priority: .utility) { NoteSearch.pageImage(box.page).map(ImageBox.init) }.value
                let text = await image.map(\.image).asyncMap(self.recognize) ?? ""
                guard !Task.isCancelled else { return }
                self.pages[key, default: PageText()].scan = text
                self.scanned.insert(key)
                done += 1
                self.reading = (done, total)
            }
            self.reading = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        reading = nil
    }

    /// Treffer in den Notizen in Seitenreihenfolge
    func hits(_ query: String, layout: DisplayLayout?) -> [SearchHit] {
        guard let layout else { return [] }
        var out: [SearchHit] = []
        for (i, entry) in layout.entries.enumerated() {
            guard let t = pages[entry.key] else { continue }
            for (source, text) in [(NoteSearch.Source.typed, t.typed), (.handwriting, t.handwriting), (.scan, t.scan)] {
                for s in NoteSearch.snippets(in: text, query: query) {
                    out.append(SearchHit(pageIndex: i, snippet: s, selection: nil, source: source))
                }
            }
        }
        return out
    }

    private struct PageBox: @unchecked Sendable { let page: PDFPage }
    private struct ImageBox: @unchecked Sendable { let image: CGImage }

    /// Nur fuer Tests: Text einer Seite direkt setzen
    func setForTesting(_ key: String, _ text: PageText) { pages[key] = text }
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        switch self {
        case .some(let w): return await f(w)
        case .none: return nil
        }
    }
}
