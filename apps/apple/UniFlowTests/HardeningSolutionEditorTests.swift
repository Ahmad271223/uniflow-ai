import CryptoKit
import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Haertetests fuer fremde Loesungsebenen im Editor (docs/LOESUNGEN-TEILEN.md, Abschnitt 4 und 5):
/// - Lage der fremden Ebene pixelgenau gegen die Darstellung von PDFKit (Seiten mit /Rotate 90 und 270, eigene
///   Drehung abweichend vom Absender, mehrere Zoomstufen, CropBox != MediaBox, eigene Leerseiten vor der Seite,
///   gemischte Seitengroessen, vertauschte Seitenschluessel beim Absender),
/// - eigene Notizen und Journal bleiben byte-gleich beim Ein-/Ausblenden, Scrollen und im Ansichtsmodus,
/// - Teilen direkt nach einem Strich, Teilen ohne eigene Notizen,
/// - viele fremde Ebenen gleichzeitig und Speicherwarnung.
/// Alle Daten sind erfunden; die PDF wird im Test erzeugt. Zufall nur mit festem Startwert.
@MainActor
final class HardeningSolutionEditorTests: XCTestCase {
    let cipher = CryptoKitSolutionCipher()

    // MARK: Test-PDF

    /// Seite der Test-PDF: MediaBox, optionale CropBox (PDF-Koordinaten, Ursprung unten links), `/Rotate` und eine
    /// schwarze Marke (14 x 14 Punkte, Mitte in UIKit-Koordinaten der MediaBox, Ursprung oben links).
    struct TestPage {
        let media: CGSize
        let crop: CGRect?
        let rotate: Int
        let marker: CGPoint
    }

    /// Vier Seiten: hoch mit /Rotate 90, eigene Groesse mit /Rotate 270, CropBox mit Versatz und /Rotate 90, quer.
    static let testPages = [
        TestPage(media: CGSize(width: 595, height: 842), crop: nil, rotate: 90, marker: CGPoint(x: 150, y: 230)),
        TestPage(media: CGSize(width: 600, height: 780), crop: nil, rotate: 270, marker: CGPoint(x: 420, y: 120)),
        TestPage(media: CGSize(width: 700, height: 900), crop: CGRect(x: 40, y: 70, width: 520, height: 760), rotate: 90,
                 marker: CGPoint(x: 230, y: 610)),
        TestPage(media: CGSize(width: 842, height: 595), crop: nil, rotate: 0, marker: CGPoint(x: 700, y: 450)),
    ]

    static let markerSide: CGFloat = 14

    /// Dateibytes der Test-PDF (so, wie sie auf der Platte liegen).
    private func makePDFData() -> Data {
        let pages = Self.testPages
        let raw = NSMutableData()
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: pages[0].media), nil)
        for p in pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: p.media), nil)
            UIColor.black.setFill()
            let s = Self.markerSide
            UIRectFill(CGRect(x: p.marker.x - s / 2, y: p.marker.y - s / 2, width: s, height: s))
        }
        UIGraphicsEndPDFContext()
        let doc = PDFDocument(data: raw as Data)!
        for (i, p) in pages.enumerated() {
            let page = doc.page(at: i)!
            if let crop = p.crop { page.setBounds(crop, for: .cropBox) }
            page.rotation = p.rotate
        }
        let data = doc.dataRepresentation()!
        // Pruefung der Testdaten: Boxen und Drehung ueberstehen das Speichern
        let check = PDFDocument(data: data)!
        precondition(check.pageCount == pages.count)
        for (i, p) in pages.enumerated() {
            let page = check.page(at: i)!
            precondition(page.bounds(for: .mediaBox).size == p.media, "MediaBox Seite \(i + 1)")
            precondition(page.bounds(for: .cropBox) == (p.crop ?? CGRect(origin: .zero, size: p.media)), "CropBox Seite \(i + 1)")
            precondition(page.rotation == p.rotate, "Rotate Seite \(i + 1)")
        }
        return data
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-haerte-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func source(_ doc: AnnotationDocument, pdf: Data) -> SolutionSource {
        SolutionSource(document: doc, originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                       images: [:], title: "Blatt 7")
    }

    // MARK: Darstellung und Pixel

    /// Bitmap (RGBA, Zeile 0 = oben) eines Bildes.
    private func bitmap(_ image: CGImage) -> (px: [UInt8], w: Int, h: Int) {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (px, w, h)
    }

    /// Schwerpunkt dunkler, deckender Bildpunkte (Tinte bzw. Marke) in Pixelkoordinaten (Mitte des Pixels) und
    /// deren Anzahl. Vorlagenlinien (hellgrau) und Hintergrund zaehlen nicht.
    private func inkCentroid(_ image: CGImage) -> (point: CGPoint, count: Int)? {
        let (px, w, h) = bitmap(image)
        var sx = 0.0, sy = 0.0, n = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard px[i + 3] > 127, px[i] < 100, px[i + 1] < 100, px[i + 2] < 100 else { continue }
                sx += Double(x) + 0.5
                sy += Double(y) + 0.5
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (CGPoint(x: sx / Double(n), y: sy / Double(n)), n)
    }

    /// Groesse der angezeigten Seite (CropBox mit Drehung), unabhaengig vom App-Code gerechnet.
    private func shownSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return ((page.rotation % 180 + 180) % 180) == 90 ? CGSize(width: box.height, height: box.width) : box
    }

    /// Referenz: PDFKit zeichnet die Seite (mit ihrer Drehung und CropBox) auf weissem Grund in `zoom`-facher Groesse.
    private func renderPDFPage(_ page: PDFPage, zoom: CGFloat) -> CGImage {
        let size = shownSize(page)
        let out = CGSize(width: size.width * zoom, height: size.height * zoom)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: out, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: out))
            let cg = ctx.cgContext
            cg.scaleBy(x: zoom, y: zoom)
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .cropBox, to: cg)
        }.cgImage!
    }

    /// Overlay so gross wie die Seite bei `zoom` (wie PDFKit es beim Zoomen anpasst) und als Bild, mit den von
    /// PencilKit gezeichneten Strichen (`InkSnapshot`).
    private func renderOverlay(_ overlay: PageInkView, zoom: CGFloat) -> CGImage {
        let size = overlay.geometry.pageSize
        let out = CGSize(width: size.width * zoom, height: size.height * zoom)
        overlay.frame = CGRect(origin: .zero, size: out)
        overlay.setNeedsLayout()
        overlay.layoutIfNeeded()
        return InkSnapshot.image(overlay, size: out).cgImage!
    }

    /// Erwartete Lage der Marke auf der angezeigten Seite, von Hand gerechnet (ohne App- und Kerncode).
    private func expectedMarker(_ t: TestPage, rotation: Int) -> CGPoint {
        let crop = t.crop ?? CGRect(origin: .zero, size: t.media)
        // UIKit-Koordinaten der MediaBox -> PDF-Raum -> CropBox mit Ursprung oben links
        let pdfY = t.media.height - t.marker.y
        let x = t.marker.x - crop.minX, y = crop.maxY - pdfY
        let W = crop.width, H = crop.height
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGPoint(x: H - y, y: x)
        case 180: return CGPoint(x: W - x, y: H - y)
        case 270: return CGPoint(x: y, y: W - x)
        default: return CGPoint(x: x, y: y)
        }
    }

    // MARK: Eigenes Dokument im lokalen Backend

    private struct Fixture {
        let store: DocumentStore
        let root: URL
    }

    private func makeStore(pdf: Data) async throws -> Fixture {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "haerte-editor-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdfDirectory(api.namespace, root: root).appendingPathComponent(fileID + ".pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt7.pdf", title: "Blatt 7", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-10-25", has_notes: nil,
                           page_count: Self.testPages.count, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return Fixture(store: store, root: root)
    }

    private func serialized(_ store: DocumentStore) async -> Data {
        await store.flush()
        return (await store.pageStructureDocument()).root.serialized(sortedKeys: true)
    }

    /// Alle Dateien des Journals (relativer Pfad -> Bytes).
    private func journalSnapshot(_ root: URL) -> [String: Data] {
        let dir = root.appendingPathComponent("journal", isDirectory: true).resolvingSymlinksInPath()
        var out: [String: Data] = [:]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(dir.path.count))
            out[rel] = try? Data(contentsOf: url)
        }
        return out
    }

    /// Stand nach dem Abarbeiten aller ausstehenden Aufgaben: Dokument und Journal.
    private func settledState(_ fx: Fixture) async -> (doc: Data, journal: [String: Data]) {
        await fx.store.flush()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let doc = await serialized(fx.store)
        try? await Task.sleep(nanoseconds: 100_000_000)
        return (doc, journalSnapshot(fx.root))
    }

    private func waitLoaded(_ overlay: PageInkView, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !overlay.loaded { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(overlay.loaded, "Overlay geladen", file: file, line: line)
    }

    private func nativeStroke(at p: CGPoint) -> PKStroke {
        let pts = (0..<20).map { i in
            PKStrokePoint(location: CGPoint(x: p.x + CGFloat(i) * 3, y: p.y), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    /// Strich wie mit dem Stift: Canvas aendert sich, PencilKit meldet die Aenderung genau einmal.
    private func drawStroke(_ editor: PDFEditorController, on overlay: PageInkView, at p: CGPoint) {
        var d = overlay.canvas.drawing
        d.strokes.append(nativeStroke(at: p))
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = d
        overlay.isApplyingDrawing = false
        editor.canvasViewDrawingDidChange(overlay.canvas)
    }

    /// Fremde Loesung (erfundene Person "Kim") ueber den echten Weg: Paket versiegeln, importieren, mit der eigenen
    /// PDF-Datei des Empfaengers oeffnen.
    private func importedLayers(_ doc: AnnotationDocument, keys: [String], pdf: Data, into store: DocumentStore,
                                name: String = "Kim") async throws -> SolutionLayerLoad {
        let lib = SolutionLibrary(root: try tempDir())
        let content = try SolutionSharing.content(source(doc, pdf: pdf), keys: keys, displayName: name)
        try lib.importPackage(try SolutionSharing.package(content, originalPDF: pdf).encoded())
        let load = await store.solutionLayers(library: lib)
        XCTAssertTrue(load.problems.isEmpty, load.problems.map(\.text).joined(separator: " | "))
        return load
    }

    // MARK: Lage pixelgenau

    /// Absender: eigene Leerseite vorne, PDF-Seiten mit vertauschten Schluesseln ("p2" ist PDF-Seite 1) und eigener
    /// Drehung 0/90/270/180. Je PDF-Seite liegt ein Notizobjekt genau auf der Marke, wie PDFKit sie beim Absender
    /// zeigt. Empfaenger: zwei eigene Leerseiten vor PDF-Seite 1, eine zwischen PDF-Seite 2 und 3, eigene Drehung
    /// 90/0/180/90. Bei jeder Zoomstufe muss die Tinte der fremden Ebene genau auf der Marke liegen, die PDFKit beim
    /// Empfaenger zeichnet; Leerseiten bleiben leer.
    func testForeignLayerLandsOnMarkerPixelExactAcrossRotationCropZoomAndInsertedPages() async throws {
        let pdf = makePDFData()
        let original = PDFDocument(data: pdf)!
        let senderExtra = [0, 90, 270, 180]
        let receiverExtra = [90, 0, 180, 90]
        let senderKeys = ["p2", "p1", "x3", "x4"]

        // Referenz pruefen: PDFKit zeichnet die Marke dort, wo die Handrechnung sie erwartet (Drehung und CropBox)
        for (i, t) in Self.testPages.enumerated() {
            for extra in [0, 90, 180, 270] {
                let copy = original.page(at: i)!.copy() as! PDFPage
                copy.rotation = (t.rotate + extra) % 360
                let found = try XCTUnwrap(inkCentroid(renderPDFPage(copy, zoom: 1)), "Marke Seite \(i + 1)")
                let want = expectedMarker(t, rotation: copy.rotation)
                XCTAssertEqual(found.point.x, want.x, accuracy: 0.75, "Referenz x, Seite \(i + 1), Drehung \(copy.rotation)")
                XCTAssertEqual(found.point.y, want.y, accuracy: 0.75, "Referenz y, Seite \(i + 1), Drehung \(copy.rotation)")
            }
        }

        // Absender: Notizobjekt je PDF-Seite genau auf der Marke seiner Anzeige
        var order: [JSONValue] = [["key": "bS", "type": "blank", "template": "blank", "w": 595, "h": 842]]
        var pages: [String: JSONValue] = [
            // eigene Leerseite des Absenders: Strich dort, wo auf PDF-Seite 1 die Marke liegt (darf nie erscheinen)
            "bS": ["objects": [["id": "leer", "type": "stroke", "tool": "pen", "color": "#000000", "width": 8, "opacity": 1,
                                "points": [300, 300, 310, 300]]]],
        ]
        for (i, t) in Self.testPages.enumerated() {
            let copy = original.page(at: i)!.copy() as! PDFPage
            copy.rotation = (t.rotate + senderExtra[i]) % 360
            let m = try XCTUnwrap(inkCentroid(renderPDFPage(copy, zoom: 1))).point
            var entry: [String: JSONValue] = ["key": .string(senderKeys[i]), "type": "pdf", "index": .number(Double(i + 1))]
            if senderExtra[i] != 0 { entry["rotation"] = .number(Double(senderExtra[i])) }
            order.append(.object(entry))
            let object: JSONValue
            if i < 2 {
                // Strich (PencilKit-Canvas der fremden Schicht)
                object = ["id": .string("s\(i)"), "type": "stroke", "tool": "pen", "color": "#000000", "width": 8, "opacity": 1,
                          "points": [.number(Double(m.x) - 2), .number(Double(m.y)), .number(Double(m.x) + 2), .number(Double(m.y))]]
            } else {
                // Form (PageObjectsView der fremden Schicht)
                object = ["id": .string("r\(i)"), "type": "shape", "shape": "rect", "x": .number(Double(m.x) - 6),
                          "y": .number(Double(m.y) - 6), "width": 12, "height": 12, "fill": "#000000", "stroke": "#000000",
                          "strokeWidth": 1]
            }
            pages[senderKeys[i]] = ["objects": [object]]
        }
        let senderDoc = AnnotationDocument(root: ["version": 2, "pageOrder": .array(order), "pages": .object(pages)])

        // Empfaenger: eigene Leerseiten und eigene Drehung
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        let change = await store.applyPageStructure { doc in
            guard PageOrder.insertBlank(&doc, after: nil, template: "blank", key: "bA") != nil,
                  PageOrder.insertBlank(&doc, after: nil, template: "blank", key: "bB") != nil else { return nil }
            var o = doc.pageOrder
            let b = o.removeLast(), a = o.removeLast()
            o.insert(a, at: 0)
            o.insert(b, at: 1)
            doc.root["pageOrder"] = .array(o)
            return PageOrder.insertBlank(&doc, after: "p2", template: "lined", key: "bC")
        }
        XCTAssertNotNil(change)
        for (i, extra) in receiverExtra.enumerated() {
            for _ in 0..<(extra / 90) { await store.rotatePage(key: "p\(i + 1)") }
        }
        let layout = try XCTUnwrap(store.layout)
        XCTAssertEqual(layout.entries.map(\.key), ["bA", "bB", "p1", "p2", "bC", "p3", "p4"])
        XCTAssertEqual(layout.entries.map(\.rotation), [0, 0, 90, 0, 0, 180, 90])

        let load = try await importedLayers(senderDoc, keys: ["bS"] + senderKeys, pdf: pdf, into: store)
        XCTAssertEqual(load.layers.count, 1)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        editor.foreignLayers = load.layers

        for (i, entry) in layout.entries.enumerated() {
            let overlay = try XCTUnwrap(editor.overlayForTesting(at: i), "Overlay \(i)")
            guard let pdfIndex = entry.pdfIndex else {
                XCTAssertTrue(overlay.foreignLayerViews.isEmpty, "eigene Leerseite \(entry.key): keine fremde Ebene")
                XCTAssertNil(inkCentroid(renderOverlay(overlay, zoom: 1)), "eigene Leerseite \(entry.key): keine Tinte")
                continue
            }
            XCTAssertEqual(overlay.foreignLayerViews.count, 1, "PDF-Seite \(pdfIndex): genau eine fremde Ebene")
            let page = try XCTUnwrap(layout.pdf.page(at: i))
            XCTAssertEqual(overlay.geometry.pageSize, shownSize(page))
            for zoom: CGFloat in [0.5, 1, 2.5] {
                let ref = try XCTUnwrap(inkCentroid(renderPDFPage(page, zoom: zoom)), "Marke PDF-Seite \(pdfIndex)")
                let ink = try XCTUnwrap(inkCentroid(renderOverlay(overlay, zoom: zoom)),
                                        "Tinte der fremden Ebene fehlt auf PDF-Seite \(pdfIndex) bei Zoom \(zoom)")
                let tol = max(1.5, 0.6 * zoom)
                XCTAssertEqual(ink.point.x, ref.point.x, accuracy: tol,
                               "x auf PDF-Seite \(pdfIndex) (Anzeige \(i), Zoom \(zoom)): \(ink.point) statt \(ref.point)")
                XCTAssertEqual(ink.point.y, ref.point.y, accuracy: tol,
                               "y auf PDF-Seite \(pdfIndex) (Anzeige \(i), Zoom \(zoom)): \(ink.point) statt \(ref.point)")
            }
        }
        await store.close()
    }

    /// Zoom ist reine Anzeige: dieselbe Ebene bei 0,25-fach bis 4-fach ergibt dieselbe Lage in Seitenpunkten, die
    /// Koordinaten der Objekte und die Abbildung bleiben unveraendert.
    func testZoomDoesNotChangeForeignGeometry() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let original = PDFDocument(data: pdf)!
        let copy = original.page(at: 3)!.copy() as! PDFPage      // Querformat, ohne Drehung
        let m = try XCTUnwrap(inkCentroid(renderPDFPage(copy, zoom: 1))).point
        let doc = AnnotationDocument(root: ["version": 2, "pageOrder": [["key": "q", "type": "pdf", "index": 4]],
                                            "pages": ["q": ["objects": [["id": "s", "type": "stroke", "tool": "pen",
                                                                         "color": "#000000", "width": 6, "opacity": 1,
                                                                         "points": [.number(Double(m.x) - 1), .number(Double(m.y)),
                                                                                    .number(Double(m.x) + 1), .number(Double(m.y))]]]]]])
        let load = try await importedLayers(doc, keys: ["q"], pdf: pdf, into: fx.store)
        let editor = PDFEditorController(store: fx.store)
        editor.loadViewIfNeeded()
        editor.foreignLayers = load.layers
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 3))
        let mapping = try XCTUnwrap(overlay.foreignLayerViews.first?.mapping)
        let objects = load.layers[0].pages[0].objects
        for zoom: CGFloat in [0.25, 0.75, 1, 1.6, 4] {
            let ink = try XCTUnwrap(inkCentroid(renderOverlay(overlay, zoom: zoom)), "Zoom \(zoom)")
            XCTAssertEqual(ink.point.x / zoom, m.x, accuracy: 2 / zoom + 0.5, "Zoom \(zoom)")
            XCTAssertEqual(ink.point.y / zoom, m.y, accuracy: 2 / zoom + 0.5, "Zoom \(zoom)")
            XCTAssertEqual(overlay.foreignLayerViews.first?.mapping, mapping, "Abbildung haengt nicht vom Zoom ab")
            XCTAssertEqual(overlay.foreignLayerViews.first?.bounds.size, overlay.geometry.pageSize, "Seitenpunkte, kein Zoom")
        }
        XCTAssertEqual(editor.foreignLayers[0].pages[0].objects, objects, "Objekte nie umgerechnet")
        await fx.store.close()
    }

    // MARK: Eigene Notizen bleiben unveraendert

    /// Erfundene fremde Loesung auf allen vier PDF-Seiten.
    private func foreignDoc(name: String = "f", strokesPerPage: Int = 1, seed: UInt64 = 7) -> AnnotationDocument {
        var rng = SplitMix64(seed: seed)
        var order: [JSONValue] = []
        var pages: [String: JSONValue] = [:]
        for i in 1...Self.testPages.count {
            let key = "\(name)\(i)"
            order.append(["key": .string(key), "type": "pdf", "index": .number(Double(i))])
            var objects: [JSONValue] = []
            for s in 0..<strokesPerPage {
                var pts: [JSONValue] = []
                for _ in 0..<12 { pts.append(.number(Double(rng.next() % 500) + 20)); pts.append(.number(Double(rng.next() % 500) + 20)) }
                objects.append(["id": .string("\(key)-\(s)"), "type": "stroke", "tool": "pen", "color": "#2255aa", "width": 2,
                                "opacity": 1, "points": .array(pts)])
            }
            pages[key] = ["objects": .array(objects)]
        }
        return AnnotationDocument(root: ["version": 2, "pageOrder": .array(order), "pages": .object(pages)])
    }

    /// Scrollen wie PDFKit: alle Overlays anfordern und wieder abgeben (die letzten 6 bleiben geparkt).
    private func scrollThrough(_ editor: PDFEditorController, rounds: Int = 3) async {
        guard let doc = editor.pdfView.document else { return }
        for _ in 0..<rounds {
            for i in 0..<doc.pageCount {
                guard let overlay = editor.overlayForTesting(at: i), let page = doc.page(at: i) else { continue }
                await waitLoaded(overlay)
                editor.pdfView(editor.pdfView, willEndDisplayingOverlayView: overlay, for: page)
            }
        }
    }

    /// Eigene Notizen (Text und Strich) bleiben byte-gleich, waehrend fremde Ebenen mehrfach ein- und ausgeblendet
    /// werden und durch alle Seiten gescrollt wird (sichtbar wie ausgeblendet). Journal ebenso.
    func testOwnNotesAndJournalUnchangedWhileTogglingAndScrolling() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        await store.addText("Meine Rechnung", pageKey: "p1")
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let first = try XCTUnwrap(editor.overlayForTesting(at: 0))
        await waitLoaded(first)
        drawStroke(editor, on: first, at: CGPoint(x: 80, y: 500))
        let before = await settledState(fx)
        XCTAssertTrue(String(decoding: before.doc, as: UTF8.self).contains("Meine Rechnung"))
        XCTAssertFalse(before.journal.isEmpty, "Journal vorhanden")

        let load = try await importedLayers(foreignDoc(), keys: ["f1", "f2", "f3", "f4"], pdf: pdf, into: store)
        var layers = load.layers
        editor.foreignLayers = layers
        for round in 0..<4 {
            layers[0].visible = round % 2 == 1
            editor.foreignLayers = layers
            await scrollThrough(editor, rounds: 1)
        }
        editor.foreignLayers = load.layers
        await scrollThrough(editor)
        let during = await settledState(fx)
        XCTAssertEqual(during.doc, before.doc, "eigenes Dokument byte-gleich nach Ein-/Ausblenden und Scrollen")
        XCTAssertEqual(during.journal, before.journal, "Journal byte-gleich nach Ein-/Ausblenden und Scrollen; neu: "
                       + Set(during.journal.keys).subtracting(before.journal.keys).sorted().joined(separator: ", "))

        // "Meine Notizen" ausgeblendet: weiter scrollen und fremde Ebenen schalten
        editor.ownNotesVisible = false
        for round in 0..<3 {
            layers[0].visible = round % 2 == 0
            editor.foreignLayers = layers
            await scrollThrough(editor, rounds: 1)
        }
        editor.ownNotesVisible = true
        await scrollThrough(editor, rounds: 1)
        let after = await settledState(fx)
        XCTAssertEqual(after.doc, before.doc, "eigenes Dokument byte-gleich nach dem Ansichtsmodus")
        XCTAssertEqual(after.journal, before.journal, "Journal byte-gleich nach dem Ansichtsmodus")
        XCTAssertFalse(String(decoding: after.doc, as: UTF8.self).contains("2255aa"), "nichts Fremdes im eigenen Dokument")
        await store.close()
    }

    /// "Meine Notizen" von Anfang an ausgeblendet (nur ansehen), dann durch alle Seiten scrollen und fremde Ebenen
    /// schalten: Es darf nichts ins eigene Dokument oder Journal geschrieben werden, auch nicht fuer Seiten, die in
    /// dieser Sitzung zum ersten Mal angezeigt werden.
    func testScrollingInViewModeWritesNothing() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        await store.addText("Meine Rechnung", pageKey: "p1")
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        var layers = try await importedLayers(foreignDoc(), keys: ["f1", "f2", "f3", "f4"], pdf: pdf, into: store).layers
        editor.foreignLayers = layers
        let before = await settledState(fx)

        editor.ownNotesVisible = false
        for round in 0..<3 {
            layers[0].visible = round % 2 == 1
            editor.foreignLayers = layers
            await scrollThrough(editor, rounds: 1)
        }
        let after = await settledState(fx)
        let beforeDoc = try JSONValue.parse(before.doc), afterDoc = try JSONValue.parse(after.doc)
        let added = Set(afterDoc["pages"]?.object?.keys.map { $0 } ?? []).subtracting(beforeDoc["pages"]?.object?.keys.map { $0 } ?? [])
        XCTAssertEqual(after.doc, before.doc, "Scrollen im Ansichtsmodus schreibt Seiten: " + added.sorted().joined(separator: ", "))
        XCTAssertEqual(after.journal, before.journal, "Journal im Ansichtsmodus; neu: "
                       + Set(after.journal.keys).subtracting(before.journal.keys).sorted().joined(separator: ", "))
        await store.close()
    }

    /// Eigene Drehung aendern, waehrend die fremde Ebene angezeigt wird: nach dem Neuaufbau liegt die Tinte wieder
    /// genau auf der Marke (PDFKit-Referenz).
    func testForeignLayerFollowsRotationChangeWhileShown() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        let original = PDFDocument(data: pdf)!
        var pages: [String: JSONValue] = [:]
        var order: [JSONValue] = []
        for i in 0..<Self.testPages.count {
            let m = try XCTUnwrap(inkCentroid(renderPDFPage(original.page(at: i)!, zoom: 1))).point
            order.append(["key": .string("k\(i)"), "type": "pdf", "index": .number(Double(i + 1))])
            pages["k\(i)"] = ["objects": [["id": .string("s\(i)"), "type": "stroke", "tool": "pen", "color": "#000000", "width": 8,
                                           "opacity": 1, "points": [.number(Double(m.x) - 2), .number(Double(m.y)),
                                                                    .number(Double(m.x) + 2), .number(Double(m.y))]]]]
        }
        let doc = AnnotationDocument(root: ["version": 2, "pageOrder": .array(order), "pages": .object(pages)])
        let load = try await importedLayers(doc, keys: ["k0", "k1", "k2", "k3"], pdf: pdf, into: store)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        editor.foreignLayers = load.layers
        for step in 1...3 {
            for i in 0..<Self.testPages.count { await store.rotatePage(key: "p\(i + 1)") }
            editor.showLayout()                                   // wie updateUIViewController nach dem Drehen
            let layout = try XCTUnwrap(store.layout)
            for i in 0..<Self.testPages.count {
                let overlay = try XCTUnwrap(editor.overlayForTesting(at: i))
                XCTAssertEqual(overlay.foreignLayerViews.count, 1)
                let page = try XCTUnwrap(layout.pdf.page(at: i))
                let ref = try XCTUnwrap(inkCentroid(renderPDFPage(page, zoom: 1)))
                let ink = try XCTUnwrap(inkCentroid(renderOverlay(overlay, zoom: 1)), "Schritt \(step), Seite \(i + 1)")
                XCTAssertEqual(ink.point.x, ref.point.x, accuracy: 1.5, "Schritt \(step), Seite \(i + 1)")
                XCTAssertEqual(ink.point.y, ref.point.y, accuracy: 1.5, "Schritt \(step), Seite \(i + 1)")
            }
        }
        await store.close()
    }

    /// Ansichtsmodus: kein Schreibweg ueber Store und Editor (Text, Leerseite, Drehen, Papierkorb, Wiederherstellen,
    /// Lesezeichen, Rueckgaengig/Wiederholen ueber die Leiste). Dokument und Journal bleiben byte-gleich.
    func testHiddenOwnNotesBlockEveryWritePath() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let first = try XCTUnwrap(editor.overlayForTesting(at: 0))
        await waitLoaded(first)
        drawStroke(editor, on: first, at: CGPoint(x: 80, y: 300))
        // ein Papierkorb-Eintrag, damit Wiederherstellen etwas haette
        let trashed = await editor.trashPage(key: "p4")
        XCTAssertTrue(trashed)
        let load = try await importedLayers(foreignDoc(), keys: ["f1", "f2"], pdf: pdf, into: store)
        editor.foreignLayers = load.layers
        XCTAssertTrue(editor.undoManager?.canUndo == true, "Verlauf vorhanden")
        let before = await settledState(fx)

        editor.ownNotesVisible = false
        XCTAssertTrue(store.ownNotesReadOnly)
        await store.addText("im Ansichtsmodus", pageKey: "p1")
        await store.addBlankPage(afterKey: "p1", template: "grid")
        await store.rotatePage(key: "p2")
        await store.toggleBookmark(pageKey: "p1", title: "Seite 1")
        let inserted = await editor.insertBlankPage(after: "p2", template: "lined")
        XCTAssertNil(inserted)
        let trashedHidden = await editor.trashPage(key: "p3")
        XCTAssertFalse(trashedHidden)
        let restored = await editor.restorePage(key: "p4")
        XCTAssertFalse(restored)
        let viaStore = await store.applyPageStructure { doc in PageOrder.insertBlank(&doc, after: nil, template: "blank") }
        XCTAssertNil(viaStore)
        editor.undo()
        editor.redo()
        // Overlay des aktuellen Seitenaufbaus (nach dem Papierkorb neu aufgebaut)
        let shown = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertTrue(shown.canvas.isHidden)
        XCTAssertFalse(shown.canvas.isUserInteractionEnabled)
        let during = await settledState(fx)
        XCTAssertEqual(during.doc, before.doc, "nichts geschrieben")
        XCTAssertEqual(during.journal, before.journal, "Journal unveraendert")
        await store.close()
    }

    /// Ansichtsmodus und Rueckgaengig ueber das System (Tastatur Cmd-Z, Wischgeste mit drei Fingern): diese Wege
    /// rufen den `undoManager` der Responder-Kette direkt auf, nicht `PDFEditorController.undo()`. Auch dann darf
    /// nichts ins eigene Dokument geschrieben werden.
    func testSystemUndoWhileOwnNotesHiddenDoesNotWrite() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let first = try XCTUnwrap(editor.overlayForTesting(at: 0))
        await waitLoaded(first)
        drawStroke(editor, on: first, at: CGPoint(x: 80, y: 300))
        let before = await settledState(fx)
        XCTAssertTrue(String(decoding: before.doc, as: UTF8.self).contains("stroke"))

        editor.ownNotesVisible = false
        let system = try XCTUnwrap(editor.undoManager, "Responder-Kette liefert den Verlauf des Editors")
        if system.canUndo { system.undo() }
        let after = await settledState(fx)
        XCTAssertEqual(after.doc, before.doc, "Rueckgaengig ueber das System im Ansichtsmodus schreibt ins eigene Dokument")
        XCTAssertEqual(after.journal, before.journal, "Journal unveraendert")
        XCTAssertEqual(first.canvas.drawing.strokes.count, 1, "Strich bleibt auf der Canvas")
        await store.close()
    }

    // MARK: Teilen

    /// Teilen direkt nach einem Strich (keine Wartezeit): der Strich ist im Inhalt und im versiegelten Paket.
    /// Zweiter Strich, waehrend die Verarbeitung des ersten noch laeuft: ebenfalls enthalten.
    func testShareImmediatelyAfterStrokeContainsStroke() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let first = try XCTUnwrap(editor.overlayForTesting(at: 0))
        let second = try XCTUnwrap(editor.overlayForTesting(at: 1))
        await waitLoaded(first)
        await waitLoaded(second)

        drawStroke(editor, on: first, at: CGPoint(x: 120, y: 333))
        let src = try await store.solutionSource(loadImage: nil)
        let keys = SolutionBuilder.defaultSelection(src.document)
        XCTAssertEqual(keys, ["p1"], "Seite mit dem eben gezeichneten Strich ist vorausgewaehlt")
        let content = try SolutionSharing.content(src, keys: keys, displayName: "")
        let strokes = content.pages.first { $0.key == "p1" }?.objects.filter { $0["type"]?.string == "stroke" } ?? []
        XCTAssertEqual(strokes.count, 1, "Strich im Inhalt")
        let ys = (strokes.first?["points"]?.array ?? []).enumerated().filter { $0.offset % 2 == 1 }.compactMap { $0.element.double }
        XCTAssertFalse(ys.isEmpty)
        for y in ys { XCTAssertEqual(y, 333, accuracy: 3, "Strich an seiner Stelle") }

        // zweiter Strich, waehrend die Verarbeitung des ersten (erneut) laeuft
        drawStroke(editor, on: first, at: CGPoint(x: 120, y: 400))
        let running = Task { await store.flush() }
        await Task.yield()
        drawStroke(editor, on: second, at: CGPoint(x: 200, y: 222))
        let lib = SolutionLibrary(root: try tempDir())
        let src2 = try await store.solutionSource(loadImage: nil)
        let url = try await SolutionSharing.shareFile(src2, keys: SolutionBuilder.defaultSelection(src2.document),
                                                      displayName: "", library: lib)
        await running.value
        let opened = try SolutionPackage.decode(try Data(contentsOf: url)).open(originalPDF: pdf, cipher: cipher)
        let p1 = opened.pages.first { $0.key == "p1" }?.objects.filter { $0["type"]?.string == "stroke" } ?? []
        let p2 = opened.pages.first { $0.key == "p2" }?.objects.filter { $0["type"]?.string == "stroke" } ?? []
        XCTAssertEqual(p1.count, 2, "beide Striche auf Seite 1 im Paket")
        XCTAssertEqual(p2.count, 1, "Strich auf Seite 2 im Paket")
        XCTAssertEqual(lib.sharedEntries().count, 1)
        await store.close()
    }

    /// Ohne eigene Notizen: keine Vorauswahl, eine klare Meldung und nie ein Paket ohne Inhalt – auch nicht, wenn
    /// im Dialog "Alle" gewaehlt wird (Seiten ohne Objekte).
    func testShareWithoutOwnNotesGivesClearMessageAndNoEmptyPackage() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        // eigene Leerseite ohne Notizen dazu
        _ = await store.applyPageStructure { doc in PageOrder.insertBlank(&doc, after: "p1", template: "lined", key: "bLeer") }
        let src = try await store.solutionSource(loadImage: nil)
        XCTAssertTrue(SolutionBuilder.defaultSelection(src.document).isEmpty, "keine Seite mit Notizen")
        XCTAssertThrowsError(try SolutionSharing.content(src, keys: [], displayName: "")) {
            XCTAssertEqual($0 as? SolutionError, .nothingSelected)
        }
        // "Alle" im Dialog: alle teilbaren Seiten, keine davon mit Objekten
        let all = SolutionBuilder.candidates(src.document).filter(\.shareable).map(\.key)
        XCTAssertEqual(all.count, 5)
        XCTAssertThrowsError(try SolutionSharing.content(src, keys: all, displayName: ""),
                             "Paket ohne ein einziges eigenes Notizobjekt darf nicht entstehen") { error in
            let text = SolutionSharing.message(error)
            XCTAssertTrue(text.contains("Notizen"), "klare Meldung erwartet, war: \(text)")
        }
        let lib = SolutionLibrary(root: try tempDir())
        do {
            let url = try await SolutionSharing.shareFile(src, keys: all, displayName: "", library: lib)
            XCTFail("leeres Paket geschrieben: \(url.lastPathComponent)")
        } catch {}
        XCTAssertTrue(lib.sharedEntries().isEmpty, "nichts unter „Meine geteilten Lösungen“")
        await store.close()
    }

    // MARK: Viele Ebenen, Speicher

    /// Fremde Ebenen direkt als Ebenen (ohne Verschluesselung, gleiche Pruefung gegen die PDF).
    private func manyLayers(_ count: Int, strokesPerPage: Int, pdf: Data) throws -> [ForeignSolutionLayer] {
        let doc = PDFDocument(data: pdf)!
        return try (0..<count).map { n in
            let content = try SolutionSharing.content(source(foreignDoc(name: "L\(n)-", strokesPerPage: strokesPerPage, seed: UInt64(100 + n)),
                                                             pdf: pdf),
                                                      keys: (1...Self.testPages.count).map { "L\(n)-\($0)" }, displayName: "Person \(n)",
                                                      solutionID: UUID(uuidString: "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - String(n).count) + String(n))!,
                                                      createdAt: Date(timeIntervalSince1970: 1_792_000_000))
            return try SolutionSharing.layer(content, visible: true, pdf: doc)
        }
    }

    /// 30 Ebenen mit je 120 Strichen auf jeder PDF-Seite: Anzeige aller Seiten, Umschalten einer Ebene und
    /// Ausblenden in vertretbarer Zeit; ausgeblendete Ebenen erzeugen keine Ansichten, entfernte Ebenen werden
    /// vollstaendig freigegeben.
    func testManyForeignLayersStayFastAndAreReleased() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let layers = try manyLayers(30, strokesPerPage: 120, pdf: pdf)
        let editor = PDFEditorController(store: fx.store)
        editor.loadViewIfNeeded()
        let pageCount = try XCTUnwrap(editor.pdfView.document?.pageCount)

        var weakViews: [WeakBox<ForeignLayerView>] = []
        let start = Date()
        autoreleasepool {
            editor.foreignLayers = layers
            for i in 0..<pageCount {
                guard let o = editor.overlayForTesting(at: i) else { continue }
                XCTAssertEqual(o.foreignLayerViews.count, 30, "Seite \(i)")
                weakViews += o.foreignLayerViews.map { WeakBox($0) }
            }
        }
        let shown = Date().timeIntervalSince(start)
        XCTAssertLessThan(shown, 4, "30 Ebenen auf allen Seiten anzeigen: \(shown) s")
        XCTAssertEqual(weakViews.count, 30 * pageCount)

        // eine Ebene umschalten
        var toggled = layers
        toggled[7].visible = false
        let t0 = Date()
        autoreleasepool { editor.foreignLayers = toggled }
        let toggle = Date().timeIntervalSince(t0)
        XCTAssertLessThan(toggle, 1.5, "eine von 30 Ebenen ausblenden: \(toggle) s")
        let o0 = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertEqual(o0.foreignLayerViews.count, 29)
        XCTAssertFalse(o0.foreignLayerViews.contains { $0.solutionID == layers[7].id })

        // alle ausblenden: keine Ansichten mehr
        autoreleasepool { editor.foreignLayers = layers.map { var l = $0; l.visible = false; return l } }
        for i in 0..<pageCount { XCTAssertTrue(editor.overlayForTesting(at: i)?.foreignLayerViews.isEmpty == true, "Seite \(i)") }
        // entfernt: alle Ansichten freigegeben
        autoreleasepool { editor.foreignLayers = [] }
        XCTAssertEqual(weakViews.filter { $0.value != nil }.count, 0, "alle fremden Ansichten freigegeben")
        await fx.store.close()
    }

    /// Speicherwarnung: fremde Ebenen nicht sichtbarer (geparkter) Seiten werden freigegeben, die sichtbare Seite
    /// behaelt ihre Ebene, Auswahl und Sichtbarkeit der Ebenen bleiben erhalten, beim Zurueckscrollen erscheint die
    /// Ebene wieder an derselben Stelle. Eigene Notizen und Journal bleiben byte-gleich.
    func testMemoryWarningUnloadsForeignLayersCleanly() async throws {
        let pdf = makePDFData()
        let fx = try await makeStore(pdf: pdf)
        let store = fx.store
        await store.addText("eigen", pageKey: "p2")
        let layers = try manyLayers(4, strokesPerPage: 40, pdf: pdf)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        editor.foreignLayers = layers
        let doc = try XCTUnwrap(editor.pdfView.document)
        // Seiten 0 bis 2 angezeigt und weggescrollt (geparkt), Seite 3 sichtbar
        var parkedViews: [WeakBox<ForeignLayerView>] = []
        var mapping2: CGAffineTransform?
        for i in 0..<3 {
            let o = try XCTUnwrap(editor.overlayForTesting(at: i))
            await waitLoaded(o)
            if i == 2 { mapping2 = o.foreignLayerViews.first?.mapping }
            parkedViews += o.foreignLayerViews.map { WeakBox($0) }
            editor.pdfView(editor.pdfView, willEndDisplayingOverlayView: o, for: doc.page(at: i)!)
        }
        let visible = try XCTUnwrap(editor.overlayForTesting(at: 3))
        await waitLoaded(visible)
        XCTAssertEqual(parkedViews.count, 12)
        let before = await settledState(fx)

        autoreleasepool {
            editor.didReceiveMemoryWarning()
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        }
        XCTAssertEqual(parkedViews.filter { $0.value != nil }.count, 0,
                       "fremde Ebenen weggescrollter Seiten nach der Speicherwarnung freigegeben")
        XCTAssertEqual(visible.foreignLayerViews.count, 4, "sichtbare Seite behaelt ihre Ebenen")
        XCTAssertEqual(editor.foreignLayers.map(\.id), layers.map(\.id), "Ebenen bleiben ausgewaehlt")
        XCTAssertEqual(editor.foreignLayers.map(\.visible), layers.map(\.visible))
        // zurueckscrollen: Ebene wieder da, an derselben Stelle
        let back = try XCTUnwrap(editor.overlayForTesting(at: 2))
        XCTAssertEqual(back.foreignLayerViews.count, 4, "nach dem Zurueckscrollen wieder angezeigt")
        XCTAssertEqual(back.foreignLayerViews.first?.mapping, mapping2)
        let after = await settledState(fx)
        XCTAssertEqual(after.doc, before.doc, "eigenes Dokument byte-gleich")
        XCTAssertEqual(after.journal, before.journal, "Journal byte-gleich")
        await store.close()
    }
}

/// Schwacher Verweis (Freigabe pruefen).
final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Fester Zufall (SplitMix64), damit die Tests bei jedem Lauf dieselben Daten erzeugen.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
