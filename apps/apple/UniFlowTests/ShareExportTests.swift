import PDFKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Zaehlt die Zeichenoperatoren im Inhaltsstrom einer PDF-Seite und in ihren Formular-XObjects
/// (z. B. Transparenzgruppen). Zusaetzlich: "xobject.form" / "xobject.image" = Anzahl der XObjects je Art.
private final class OperatorCounter {
    var counts: [String: Int] = [:]

    static func bump(_ info: UnsafeMutableRawPointer?, _ op: String) {
        guard let info else { return }
        Unmanaged<OperatorCounter>.fromOpaque(info).takeUnretainedValue().counts[op, default: 0] += 1
    }

    static func count(_ page: CGPDFPage) -> [String: Int] {
        let counter = OperatorCounter()
        guard let table = makeTable() else { return [:] }
        let stream = CGPDFContentStreamCreateWithPage(page)
        scan(stream, table, counter)
        // Formulare der Seite (Transparenzgruppen) mitzaehlen, Bilder nur als Anzahl
        var res: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        if let dict = page.dictionary, CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
           CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xobjects {
            CGPDFDictionaryApplyBlock(xobjects, { _, obj, _ in
                var st: CGPDFStreamRef?
                guard CGPDFObjectGetValue(obj, .stream, &st), let st, let d = CGPDFStreamGetDictionary(st) else { return true }
                var name: UnsafePointer<CChar>?
                CGPDFDictionaryGetName(d, "Subtype", &name)
                let subtype = name.map { String(cString: $0) } ?? ""
                counter.counts["xobject." + subtype.lowercased(), default: 0] += 1
                if subtype == "Form" {
                    var formRes: CGPDFDictionaryRef?
                    CGPDFDictionaryGetDictionary(d, "Resources", &formRes)
                    let form = CGPDFContentStreamCreateWithStream(st, formRes ?? res, stream)
                    scan(form, table, counter)
                    CGPDFContentStreamRelease(form)
                }
                return true
            }, nil)
        }
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return counter.counts
    }

    private static func scan(_ stream: CGPDFContentStreamRef, _ table: CGPDFOperatorTableRef, _ counter: OperatorCounter) {
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(counter).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private static func makeTable() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        // C-Rueckrufe duerfen nichts einfangen, daher je Operator ein eigener Block
        CGPDFOperatorTableSetCallback(table, "m") { _, i in OperatorCounter.bump(i, "m") }
        CGPDFOperatorTableSetCallback(table, "l") { _, i in OperatorCounter.bump(i, "l") }
        CGPDFOperatorTableSetCallback(table, "c") { _, i in OperatorCounter.bump(i, "c") }
        CGPDFOperatorTableSetCallback(table, "S") { _, i in OperatorCounter.bump(i, "S") }
        CGPDFOperatorTableSetCallback(table, "w") { _, i in OperatorCounter.bump(i, "w") }
        CGPDFOperatorTableSetCallback(table, "d") { _, i in OperatorCounter.bump(i, "d") }
        CGPDFOperatorTableSetCallback(table, "gs") { _, i in OperatorCounter.bump(i, "gs") }
        CGPDFOperatorTableSetCallback(table, "Do") { _, i in OperatorCounter.bump(i, "Do") }
        CGPDFOperatorTableSetCallback(table, "BI") { _, i in OperatorCounter.bump(i, "BI") }
        return table
    }
}

/// Merkt sich die angefragten Bildquellen (Lader laufen parallel).
private final class LoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ s: String) {
        lock.lock()
        items.append(s)
        lock.unlock()
    }

    var sources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items.sorted()
    }
}

/// Teilen & Export: Handschrift als Vektoren wie im Web-Editor, Datensatz fuer die Community, Miniaturen.
final class ShareExportTests: XCTestCase {

    /// - Parameter fill: Farbe, mit der jede Seite ganz gefuellt wird (`nil` = leer).
    private func makePDF(pages: Int, size: CGSize = CGSize(width: 595, height: 842), fill: UIColor? = nil) -> PDFDocument {
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(origin: .zero, size: size), nil)
        for _ in 0..<pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            if let fill {
                fill.setFill()
                UIRectFill(CGRect(origin: .zero, size: size))
            }
        }
        UIGraphicsEndPDFContext()
        return PDFDocument(data: data as Data)!
    }

    /// Zwei PDF-Seiten und eine eingefuegte linierte Leerseite dazwischen.
    private func makeLayout(fill: UIColor? = nil) throws -> DisplayLayout {
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pages":{},"pageOrder":[
          {"key":"p1","type":"pdf","index":1},
          {"key":"bA","type":"blank","template":"lined","w":595,"h":842},
          {"key":"p2","type":"pdf","index":2}]}
        """#))
        return DisplayLayout.build(original: makePDF(pages: 2, fill: fill), document: doc)
    }

    private func stroke(_ extra: String) throws -> JSONValue {
        try JSONValue.parse(##"{"id":"s","type":"stroke","color":"#1d2130","x":0,"y":0,"rotation":0,"scaleX":1,"scaleY":1,"##
                            + extra + "}")
    }

    private func imageObject(_ src: String) throws -> JSONValue {
        try JSONValue.parse(#"{"type":"image","src":"\#(src)","x":100,"y":100,"width":200,"height":200,"rotation":0,"scaleX":1,"scaleY":1}"#)
    }

    private func image(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }

    // MARK: Zeichenplan (gleiche Regeln wie makeInkShape)

    func testPenWithWidthsDrawsOnePiecePerSegmentWidth() throws {
        let o = try stroke(##""tool":"pen","width":3,"opacity":1,"points":[0,0,10,0,20,0,30,0],"widths":[1,2,3,4]"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        XCTAssertEqual(plan.pieces.map(\.width), [1.5, 2.5, 3.5], "mittlere Breite je Punktpaar")
        XCTAssertEqual(plan.alpha, 1)
        XCTAssertFalse(plan.multiply)
        XCTAssertTrue(plan.dash.isEmpty)
    }

    func testEqualWidthsShareOnePath() throws {
        let o = try stroke(##""tool":"fountain","width":2,"opacity":1,"points":[0,0,10,0,20,0,30,0,40,0],"widths":[2,2,2,2,5]"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        XCTAssertEqual(plan.pieces.map(\.width), [2, 3.5], "gleiche Breite in einem Pfad")
    }

    func testTranslucentPenIsSinglePathWithAverageWidth() throws {
        let o = try stroke(##""tool":"pencil","width":2,"opacity":0.75,"points":[0,0,10,10,20,0],"widths":[1,2,3]"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        XCTAssertEqual(plan.pieces.count, 1)
        XCTAssertEqual(plan.pieces[0].width, 2, accuracy: 0.001)
        XCTAssertEqual(plan.alpha, 0.75, accuracy: 0.001)
        XCTAssertEqual(plan.dash, InkRenderer.pencilDash, "Bleistift gestrichelt")
        // Mittelpunkt-Kurve: endet im letzten Punkt, Kontrollpunkt (10,10) zieht die Kurve nach oben
        let box = plan.pieces[0].path.boundingBoxOfPath
        XCTAssertEqual(box.maxX, 20, accuracy: 0.001)
        XCTAssertGreaterThan(box.maxY, 4)
        XCTAssertLessThan(box.maxY, 10)
    }

    func testMarkerIsStraightMultiplyLine() throws {
        let o = try stroke(##""tool":"marker","width":16,"opacity":0.35,"points":[0,0,50,0,50,50]"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        XCTAssertTrue(plan.multiply)
        XCTAssertTrue(InkRenderer.isMarker(o))
        XCTAssertFalse(InkRenderer.isMarker(try stroke(##""tool":"pen","points":[0,0,1,1]"##)))
        XCTAssertEqual(plan.alpha, 0.35, accuracy: 0.001)
        XCTAssertEqual(plan.pieces.map(\.width), [16])
        XCTAssertEqual(plan.pieces[0].path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 50, height: 50), "gerader Linienzug")
    }

    func testTransformAndInvisibleStrokes() throws {
        let o = try JSONValue.parse(##"{"type":"stroke","tool":"pen","color":"#000000","width":2,"points":[0,0,10,0],"x":100,"y":50,"rotation":90,"scaleX":2,"scaleY":2}"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        let end = CGPoint(x: 10, y: 0).applying(plan.transform)
        XCTAssertEqual(end.x, 100, accuracy: 0.001)
        XCTAssertEqual(end.y, 70, accuracy: 0.001, "verschieben, drehen, skalieren wie Konva")
        XCTAssertNil(InkRenderer.plan(try stroke(##""tool":"pen","points":[5,5]"##)), "ein Punkt: Konva zeichnet nichts")
        XCTAssertNil(InkRenderer.plan(try JSONValue.parse(##"{"type":"text","text":"x"}"##)))
    }

    // MARK: PDF-Export

    /// Auf der Leerseite (ohne Original-PDF) besteht der Inhalt nur aus Vorlage und Handschrift: Kurven und
    /// Linienbreiten als Pfad-Operatoren, kein Bild. Wegen des Textmarkers liegen die Notizen in einer
    /// Transparenzgruppe (ein Formular-XObject, dessen Operatoren mitgezaehlt werden).
    func testExportDrawsInkAsVectorPaths() throws {
        let layout = try makeLayout()
        let pen = try stroke(##""tool":"pen","width":3,"opacity":1,"points":[100,100,150,120,200,100,250,140,300,100],"widths":[1,2,3,4,5]"##)
        let marker = try stroke(##""tool":"marker","width":16,"opacity":0.35,"points":[100,300,400,300]"##)
        let data = PDFExporter.render(layout: layout, pages: ["bA": .object(["objects": .array([pen, marker])])], images: [:])
        let exported = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(exported.pageCount, 3)
        let cg = try XCTUnwrap(exported.page(at: 1)?.pageRef)
        let ops = OperatorCounter.count(cg)
        XCTAssertGreaterThanOrEqual(ops["c", default: 0], 3, "Mittelpunkt-Kurven: \(ops)")
        XCTAssertGreaterThanOrEqual(ops["w", default: 0], 4, "Breite je Teilstueck: \(ops)")
        XCTAssertGreaterThanOrEqual(ops["S", default: 0], 5, "Vorlage + Teilstuecke + Marker: \(ops)")
        XCTAssertGreaterThanOrEqual(ops["gs", default: 0], 1, "Deckkraft/Multiplizieren ueber Grafikzustand: \(ops)")
        XCTAssertEqual(ops["xobject.form", default: 0], 1, "Notizen als eine Transparenzgruppe: \(ops)")
        XCTAssertEqual(ops["Do", default: 0], 1, "nur das Formular der Gruppe wird eingebunden: \(ops)")
        XCTAssertEqual(ops["xobject.image", default: 0], 0, "kein eingebettetes Bild")
        XCTAssertEqual(ops["BI", default: 0], 0, "kein Inline-Bild")
    }

    /// Ohne Textmarker keine Gruppe: Striche direkt im Inhaltsstrom der Seite.
    func testExportWithoutMarkerHasNoGroup() throws {
        let layout = try makeLayout()
        let pen = try stroke(##""tool":"pen","width":3,"opacity":1,"points":[100,100,150,120,200,100]"##)
        let data = PDFExporter.render(layout: layout, pages: ["bA": .object(["objects": .array([pen])])], images: [:])
        let ops = OperatorCounter.count(try XCTUnwrap(PDFDocument(data: data)?.page(at: 1)?.pageRef))
        XCTAssertEqual(ops["Do", default: 0], 0, "\(ops)")
        XCTAssertGreaterThanOrEqual(ops["c", default: 0], 1, "\(ops)")
    }

    /// Wie im Web-Editor multipliziert der Textmarker nicht mit der PDF-Seite: auf einer schwarzen Folie bleibt er
    /// sichtbar (mit Multiplizieren gegen die Seite waere er dort schwarz).
    func testMarkerDoesNotMultiplyWithPDFPage() throws {
        let layout = try makeLayout(fill: .black)
        let marker = try stroke(##""tool":"marker","color":"#ffff00","width":40,"opacity":0.5,"points":[100,400,400,400]"##)
        let page = try XCTUnwrap(layout.pdf.page(at: 0))
        let entry = try XCTUnwrap(layout.entry(at: 0))
        let img = PageRenderer.thumbnail(page: page, entry: entry, objects: [marker], images: [:], width: 595, scale: 1)
        XCTAssertLessThan(brightness(img, at: CGPoint(x: 250, y: 300)), 0.05, "Folie schwarz")
        XCTAssertGreaterThan(brightness(img, at: CGPoint(x: 250, y: 400)), 0.2, "Marker ueber der Folie sichtbar")
    }

    /// Pixeltest: der Strich ist an der richtigen Stelle dunkel, daneben bleibt die Seite weiss.
    func testExportInkPixelsOnPDFPage() throws {
        let layout = try makeLayout()
        let pen = try stroke(##""tool":"pen","width":6,"opacity":1,"points":[100,400,300,400]"##)
        let data = PDFExporter.render(layout: layout, pages: ["p2": .object(["objects": .array([pen])])], images: [:],
                                      pageIndices: [2])
        let exported = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(exported.pageCount, 1, "nur die gewaehlte Seite")
        let img = try XCTUnwrap(exported.page(at: 0)?.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox))
        XCTAssertLessThan(brightness(img, at: CGPoint(x: 200, y: 400)), 0.4)
        XCTAssertGreaterThan(brightness(img, at: CGPoint(x: 200, y: 450)), 0.9)
    }

    // MARK: Datensatz fuer das Teilen

    func testPayloadForDocumentAndPage() throws {
        let layout = try makeLayout()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let all = try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "Analysis I: Blatt 3",
                                          fileID: "f1", moduleID: 7, module: "Analysis I", scope: .document, createdAt: date)
        XCTAssertEqual(all.pageRange, 1...3)
        XCTAssertEqual(all.pageCount, 3)
        XCTAssertEqual(PDFDocument(data: all.pdf)?.pageCount, 3)
        XCTAssertEqual(all.fileName, "Analysis I- Blatt 3.pdf")
        XCTAssertEqual(all.moduleID, 7)
        XCTAssertEqual(all.module, "Analysis I")
        XCTAssertEqual(all.createdAt, date)
        XCTAssertEqual(all.missingImages, 0)
        XCTAssertEqual(PDFDocument(data: all.pdf)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                       "Analysis I: Blatt 3")

        let one = try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "Skript", fileID: "f1",
                                          moduleID: nil, module: nil, scope: .page(1))
        XCTAssertEqual(one.pageRange, 2...2)
        XCTAssertEqual(PDFDocument(data: one.pdf)?.pageCount, 1)
        XCTAssertThrowsError(try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "x", fileID: "f1",
                                                     moduleID: nil, module: nil, scope: .page(3)))
    }

    /// Wie der Web-Export: die Endung ".pdf" gehoert nicht in Titel, Metadaten und Dateinamen.
    func testTitleWithoutPDFExtension() throws {
        let layout = try makeLayout()
        let p = try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "Skript.pdf", fileID: "f",
                                        moduleID: nil, module: nil, scope: .page(0))
        XCTAssertEqual(p.title, "Skript")
        XCTAssertEqual(p.fileName, "Skript.pdf")
        XCTAssertEqual(PDFDocument(data: p.pdf)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Skript")
        XCTAssertEqual(ShareExport.cleanTitle("Vorlesung_03.PDF "), "Vorlesung_03")
        XCTAssertEqual(ShareExport.cleanTitle("Blatt.pdf.pdf"), "Blatt.pdf", "nur die letzte Endung")
        XCTAssertEqual(ShareExport.cleanTitle("Analysis I"), "Analysis I")
        XCTAssertEqual(ShareExport.cleanTitle(".pdf"), "Dokument")
    }

    func testWriteFileUsesTitleAsFileName() throws {
        let layout = try makeLayout()
        let p = try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "Lineare Algebra", fileID: "f",
                                        moduleID: nil, module: nil, scope: .page(0))
        let url = try ShareExport.writeFile(p)
        XCTAssertEqual(url.lastPathComponent, "Lineare Algebra.pdf")
        XCTAssertEqual(try Data(contentsOf: url), p.pdf)
    }

    // MARK: Bilder im Teilen-PDF

    func testImageSourcesOnlyFromImageObjects() throws {
        let pages: [String: JSONValue] = [
            "p1": .object(["objects": .array([try imageObject("/b"), try imageObject("/a"), try stroke(##""points":[0,0,1,1]"##)])]),
            "p2": .object(["objects": .array([try imageObject("/a")])]),
        ]
        XCTAssertEqual(ShareExport.imageSources(in: pages), ["/a", "/b"])
    }

    func testCompleteImagesLoadsMissingAndReportsFailures() async throws {
        let red = image(.red)
        let log = LoadLog()
        let result = await ShareExport.completeImages(["/da": red], sources: ["/da", "/neu", "/kaputt"], timeout: 5) { src in
            log.add(src)
            return src == "/neu" ? red : nil
        }
        XCTAssertEqual(log.sources, ["/kaputt", "/neu"], "vorhandene Bilder werden nicht erneut geladen")
        XCTAssertEqual(Set(result.images.keys), ["/da", "/neu"])
        XCTAssertEqual(result.missing, ["/kaputt"])
    }

    func testCompleteImagesStopsAtTimeout() async throws {
        let start = Date()
        let result = await ShareExport.completeImages([:], sources: ["/langsam"], timeout: 0.2) { _ in
            try? await Task.sleep(nanoseconds: 20_000_000_000)                  // endet beim Abbruch sofort
            return nil
        }
        XCTAssertEqual(result.missing, ["/langsam"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Zeitlimit greift")
        let none = await ShareExport.completeImages([:], sources: ["/x"], load: nil)
        XCTAssertEqual(none.missing, ["/x"], "ohne Lader fehlt das Bild")
    }

    /// Teilen einer Seite: nur deren Objekte und Bilder; ein nachgeladenes Bild landet als Bild in der PDF.
    /// Beim ganzen Dokument mit einem nicht ladbaren Bild gibt es einen Hinweis.
    @MainActor
    func testShareLoadsImagesOfSelectedPagesIntoPDF() async throws {
        let layout = try makeLayout()
        let objects: [String: [JSONValue]] = ["bA": [try imageObject("/img/blank")], "p2": [try imageObject("/img/p2")]]
        let log = LoadLog()
        let red = image(.red)
        let one = try await ShareExport.make(layout: layout, scope: .page(1), objects: { objects[$0] ?? [] }, images: [:],
                                             title: "Blatt.pdf", fileID: "f", moduleID: 3, module: "Analysis",
                                             timeout: 5) { src in log.add(src); return red }
        XCTAssertEqual(log.sources, ["/img/blank"], "nur Bilder der gewaehlten Seite")
        XCTAssertEqual(one.missingImages, 0)
        XCTAssertNil(one.missingImagesNotice)
        XCTAssertEqual(one.title, "Blatt")
        XCTAssertEqual(one.moduleID, 3)
        let exported = try XCTUnwrap(PDFDocument(data: one.pdf))
        let ops = OperatorCounter.count(try XCTUnwrap(exported.page(at: 0)?.pageRef))
        XCTAssertGreaterThanOrEqual(ops["xobject.image", default: 0] + ops["BI", default: 0], 1, "Bild in der PDF: \(ops)")
        let img = try XCTUnwrap(exported.page(at: 0)?.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox))
        let px = rgb(img, at: CGPoint(x: 200, y: 200))
        XCTAssertGreaterThan(px.r, 0.8, "rotes Bild an seiner Stelle")
        XCTAssertLessThan(px.g, 0.3)

        let all = try await ShareExport.make(layout: layout, scope: .document, objects: { objects[$0] ?? [] }, images: [:],
                                             title: "Blatt", fileID: "f", moduleID: nil, module: nil,
                                             timeout: 5) { src in src == "/img/p2" ? nil : red }
        XCTAssertEqual(all.pageRange, 1...3)
        XCTAssertEqual(all.missingImages, 1)
        XCTAssertEqual(all.missingImagesNotice, "1 Bild nicht enthalten")
    }

    // MARK: Miniaturen

    func testThumbnailShowsInk() throws {
        let layout = try makeLayout()
        let pen = try stroke(##""tool":"pen","width":20,"opacity":1,"points":[100,421,495,421]"##)
        let page = try XCTUnwrap(layout.pdf.page(at: 0))
        let entry = try XCTUnwrap(layout.entry(at: 0))
        let img = PageRenderer.thumbnail(page: page, entry: entry, objects: [pen], images: [:], width: 140, scale: 1)
        XCTAssertEqual(img.size.width, 140)
        XCTAssertEqual(img.size.height, 198, accuracy: 1)
        XCTAssertLessThan(brightness(img, at: CGPoint(x: 70, y: 99)), 0.4, "Strich in der Mitte")
        XCTAssertGreaterThan(brightness(img, at: CGPoint(x: 70, y: 20)), 0.9)
    }

    /// Gleiche Signatur zeichnet nicht neu; weitere Striche (auch offline bei gleichem Status), eigene Bilder oder
    /// ein neuer Seitenaufbau schon. Der Speicher ist begrenzt, verdraengte Seiten werden spaeter neu gezeichnet.
    @MainActor
    func testThumbnailCacheRedrawsOnlyOnSignatureChange() async throws {
        let layout = try makeLayout()
        let page = try XCTUnwrap(layout.pdf.page(at: 0))
        let entry = try XCTUnwrap(layout.entry(at: 0))
        let cache = ThumbnailCache(limit: 2)
        let blue = image(.blue)
        func refresh(_ key: String, _ objects: [JSONValue], images: [String: UIImage] = [:], version: Int = 1) async -> Bool {
            await cache.refresh(key: key, page: page, entry: entry, objects: objects, images: images,
                                layoutVersion: version, width: 70, scale: 1)
        }
        let pen = try stroke(##""tool":"pen","width":4,"opacity":1,"points":[10,10,200,200]"##)
        let second = try stroke(##""tool":"pen","width":4,"opacity":1,"points":[10,200,200,10]"##)
        let pic = try imageObject("/img")

        var drawn = await refresh("p1", [pen])
        XCTAssertTrue(drawn)
        XCTAssertNotNil(cache.images["p1"])
        drawn = await refresh("p1", [pen])
        XCTAssertFalse(drawn, "gleiche Signatur: nicht neu zeichnen")
        drawn = await refresh("p1", [pen, second])
        XCTAssertTrue(drawn, "weiterer Strich")
        drawn = await refresh("p1", [pen, second], version: 2)
        XCTAssertTrue(drawn, "neuer Seitenaufbau")
        drawn = await refresh("p1", [pic], version: 2)
        XCTAssertTrue(drawn)
        drawn = await refresh("p1", [pic], images: ["/anderes": blue], version: 2)
        XCTAssertFalse(drawn, "Bilder anderer Seiten aendern nichts")
        drawn = await refresh("p1", [pic], images: ["/img": blue], version: 2)
        XCTAssertTrue(drawn, "eigenes Bild nachgeladen")
        XCTAssertEqual(cache.renderCount, 5)

        // Begrenzung: p1 ist am laengsten unbenutzt und wird verdraengt
        _ = await refresh("p2", [pen])
        _ = await refresh("p3", [pen])
        XCTAssertEqual(Set(cache.images.keys), ["p2", "p3"])
        drawn = await refresh("p1", [pic], images: ["/img": blue], version: 2)
        XCTAssertTrue(drawn, "verdraengte Seite wird neu gezeichnet")
        XCTAssertEqual(cache.images.count, 2)
    }

    /// Bibliotheksvorschau: erste PDF-Seite mit den Strichen aus dem lokalen Journal (eigener Ordner).
    func testLibraryInkThumbnailFromJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = makePDF(pages: 2)
        let journal = LocalJournal(store: FileBlobStore(root: root), documentID: "f1")
        XCTAssertNil(UFThumbnails.inkThumbnail(journal: journal, pdf: pdf, width: 220), "ohne Journal keine Notizvorschau")

        let pen = try stroke(##""tool":"pen","width":30,"opacity":1,"points":[50,421,545,421]"##)
        try journal.writePage("p2", JournalPage(page: .object(["objects": .array([pen])]), localRev: 1))
        XCTAssertNil(UFThumbnails.inkThumbnail(journal: journal, pdf: pdf, width: 220), "Notizen nur auf Seite 2")

        try journal.writePage("p1", JournalPage(page: .object(["objects": .array([pen])]), localRev: 1))
        let img = try XCTUnwrap(UFThumbnails.inkThumbnail(journal: journal, pdf: pdf, width: 220))
        XCTAssertEqual(img.size.width, 220)
        XCTAssertLessThan(brightness(img, at: CGPoint(x: 110, y: img.size.height / 2)), 0.4, "Strich der ersten Seite")
        XCTAssertGreaterThan(brightness(img, at: CGPoint(x: 110, y: 20)), 0.9)
    }

    // MARK: Pixel lesen

    private func brightness(_ image: UIImage, at p: CGPoint) -> CGFloat {
        let c = rgb(image, at: p)
        return (c.r + c.g + c.b) / 3
    }

    /// Farbe eines Bildpunkts (0...1), gelesen ueber einen RGBA-Kontext mit fester Bytefolge.
    private func rgb(_ image: UIImage, at p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            image.draw(at: CGPoint(x: -p.x, y: -p.y))
        }
        guard let cg = pixel.cgImage else { return (1, 1, 1) }
        var bytes = [UInt8](repeating: 255, count: 4)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
    }
}
