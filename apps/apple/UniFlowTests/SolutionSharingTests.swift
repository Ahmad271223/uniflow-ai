import CryptoKit
import PDFKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// "Lösung teilen" mit echter Verschluesselung (AES-256-GCM, HKDF-SHA256 aus CryptoKit), selbst erzeugter Test-PDF
/// und erfundenen Notizen: nur eigene Notizen im Paket, Import auf einem zweiten "Geraet", Anzeige im Editor mit
/// Drehung, Vorschau ohne Original, eigene Notizen bleiben unveraendert.
@MainActor
final class SolutionSharingTests: XCTestCase {
    let cipher = CryptoKitSolutionCipher()

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-solutions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Selbst erzeugte Test-PDF: Seite 1 hoch (595 x 842, rot gefuellt), Seite 2 quer (842 x 595), Seite 3 600 x 780 mit
    /// eigener Drehung 90 Grad (`/Rotate`). Rueckgabe: Dateibytes, wie sie auf der Platte liegen.
    private func makePDFData(marker: String = "Aufgabe 1") -> Data {
        let sizes = [CGSize(width: 595, height: 842), CGSize(width: 842, height: 595), CGSize(width: 600, height: 780)]
        let raw = NSMutableData()
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: sizes[0]), nil)
        for (i, s) in sizes.enumerated() {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: s), nil)
            if i == 0 {
                UIColor.red.setFill()
                UIRectFill(CGRect(origin: .zero, size: s))
            }
            (marker + " – Seite \(i + 1)").draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        UIGraphicsEndPDFContext()
        let doc = PDFDocument(data: raw as Data)!
        // (612 x 792 ersetzt UIKit hier durch das Standardpapier, daher eine eigene Groesse)
        precondition(doc.page(at: 2)!.bounds(for: .cropBox).size == sizes[2])
        doc.page(at: 2)!.rotation = 90
        return doc.dataRepresentation()!
    }

    /// Erfundene eigene Notizen auf drei PDF-Seiten (Seite 2 zusaetzlich gedreht) und einer Leerseite, mit
    /// unbekannten Feldern, Bild und nativer Zeichnung.
    private func ownDocument() throws -> AnnotationDocument {
        AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pageOrder":[
          {"key":"p1","type":"pdf","index":1},
          {"key":"bL","type":"blank","template":"lined","w":595,"h":842},
          {"key":"p2","type":"pdf","index":2,"rotation":90},
          {"key":"p3","type":"pdf","index":3}],
         "pages":{
          "p1":{"objects":[
            {"id":"s1","type":"stroke","tool":"pen","color":"#000000","width":12,"opacity":1,
             "points":[100,100,140,100,180,100],"x":0,"y":0,"rotation":0,"scaleX":1,"scaleY":1,"eigenesFeld":[1,{"a":"b"}]},
            {"id":"t1","type":"text","text":"x = 42","x":300,"y":400,"fontSize":16,"fill":"#1d2130","bg":"#fff3a3","width":160,
             "rotation":0,"scaleX":1,"scaleY":1},
            {"id":"i1","type":"image","src":"/api/files/x/assets/skizze.png","x":20,"y":600,"width":40,"height":40}],
           "pkdrawing":{"data":"QUJD","objectsSig":"x","format":"pkdrawing-v1","strokeIds":[["s1"]]}},
          "bL":{"objects":[{"id":"s2","type":"stroke","points":[60,84,300,84],"color":"#1d2130","width":2}]},
          "p2":{"objects":[{"id":"r1","type":"shape","shape":"ellipse","x":50,"y":60,"width":80,"height":40,"stroke":"#d64545","strokeWidth":3}]},
          "p3":{"objects":[{"id":"s3","type":"stroke","points":[10,10,20,20],"color":"#1d2130","width":2,"zukunft":true}]}
         }}
        """#))
    }

    private func sketch() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func source(_ doc: AnnotationDocument, pdf: Data, images: [String: UIImage] = [:]) -> SolutionSource {
        SolutionSource(document: doc, originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                       images: images, title: "Übungsblatt 5")
    }

    /// RGBA eines Bildpunkts.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (px[0], px[1], px[2], px[3])
    }

    // MARK: Fingerabdruck

    func testCryptoKitAndCoreSHA256Agree() {
        var rng = SystemRandomNumberGenerator()
        for n in [0, 1, 55, 56, 63, 64, 65, 1000, 100_003] {
            let d = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
            XCTAssertEqual(cipher.sha256Hex(d), SolutionSHA256.hex(d), "\(n) Byte")
        }
    }

    // MARK: Export

    func testExportContainsOnlyOwnNotesAndNoPDF() throws {
        let pdf = makePDFData()
        let doc = try ownDocument()
        let src = source(doc, pdf: pdf, images: ["/api/files/x/assets/skizze.png": sketch()])
        let content = try SolutionSharing.content(src, keys: SolutionBuilder.defaultSelection(doc), displayName: "Lea")
        let package = try SolutionSharing.package(content, originalPDF: pdf)
        let url = try SolutionSharing.writeFile(package, title: src.title)
        XCTAssertEqual(url.pathExtension, "uniflowsolution")
        XCTAssertEqual(url.lastPathComponent, "Übungsblatt 5 – Lösung.uniflowsolution")
        let file = try Data(contentsOf: url)
        let plain = content.json.serialized(sortedKeys: true)
        for blob in [file, plain] {
            XCTAssertNil(blob.range(of: Data("%PDF".utf8)))
            XCTAssertNil(blob.range(of: Data("JVBER".utf8)))
            XCTAssertNil(blob.range(of: Data("%%EOF".utf8)))
            var i = 0
            while i + 32 <= pdf.count {
                XCTAssertNil(blob.range(of: pdf.subdata(in: i..<(i + 32))), "PDF-Stueck bei \(i)")
                i += 61
            }
        }
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("pkdrawing"))
        XCTAssertLessThan(file.count, 20_000, "nur Notizen, keine Seiten")
        // Seitenzuordnung: 1-basierter Index, Groesse ohne Drehung, Drehung = /Rotate + eigene Drehung
        XCTAssertEqual(content.pages.map(\.key), ["p1", "bL", "p2", "p3"])
        XCTAssertEqual(content.pages.map(\.pdfIndex), [1, nil, 2, 3])
        XCTAssertEqual(content.pages.map(\.rotation), [0, 0, 90, 90])
        XCTAssertEqual(content.pages[2].width, 842)
        XCTAssertEqual(content.pages[3].width, 600)
        XCTAssertEqual(content.pages[1].template, "lined")
        XCTAssertEqual(content.pdfPageCount, 3)
        XCTAssertEqual(content.fingerprint, SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined(),
                       "SHA-256 der unveraenderten Dateibytes")
        XCTAssertEqual(SolutionImage.sniff(content.images["/api/files/x/assets/skizze.png"]!.data), "image/png")
        XCTAssertTrue(content.missingImages.isEmpty)
        for p in content.pages { XCTAssertEqual(p.objects, doc.objects(page: p.key), "1:1 inklusive unbekannter Felder") }
        // ohne Bild: fehlt und wird gezaehlt
        let noImage = try SolutionSharing.content(source(doc, pdf: pdf), keys: ["p1"], displayName: "")
        XCTAssertEqual(noImage.missingImages, ["/api/files/x/assets/skizze.png"])
        XCTAssertEqual(try SolutionSharing.package(noImage, originalPDF: pdf).header.missingImageCount, 1)
    }

    // MARK: Zweites Geraet

    func testSecondDeviceSamePDFShowsIdenticalObjects() throws {
        let pdf = makePDFData()
        let doc = try ownDocument()
        let content = try SolutionSharing.content(source(doc, pdf: pdf, images: ["/api/files/x/assets/skizze.png": sketch()]),
                                                  keys: SolutionBuilder.defaultSelection(doc), displayName: "Lea")
        let package = try SolutionSharing.package(content, originalPDF: pdf)
        let sender = SolutionLibrary(root: try tempDir())
        try sender.recordShared(package, title: "Übungsblatt 5")
        let shared = try tempDir().appendingPathComponent("Blatt.uniflowsolution")
        try FileManager.default.copyItem(at: sender.sharedPackageURL(package.header.solutionID), to: shared)

        // zweites Geraet: eigener Ordner, eigene Kopie der PDF (gleiche Bytes)
        let receiver = SolutionLibrary(root: try tempDir())
        let entry = try SolutionSharing.importFile(shared, into: receiver)
        XCTAssertEqual(entry.displayName, "Lea")
        let copy = Data(pdf)
        let load = SolutionSharing.loadLayers(library: receiver, originalPDF: copy, fingerprint: cipher.sha256Hex(copy),
                                              pdf: PDFDocument(data: copy)!)
        XCTAssertTrue(load.problems.isEmpty, load.problems.map(\.text).joined())
        XCTAssertEqual(load.layers.count, 1)
        let layer = try XCTUnwrap(load.layers.first)
        XCTAssertEqual(layer.label, "Lösung von Lea (\(ForeignSolutionLayer.date(content.createdAt)))")
        XCTAssertEqual(layer.pages, content.pages)
        for p in layer.pages { XCTAssertEqual(p.objects, doc.objects(page: p.key)) }
        XCTAssertEqual(Set(layer.byPDFIndex.keys), [1, 2, 3])
        XCTAssertEqual(layer.blankPageCount, 1)
        XCTAssertNotNil(layer.images["/api/files/x/assets/skizze.png"])
        XCTAssertEqual(ForeignSolutionLayer.label(displayName: "", createdAt: "2026-10-25T10:00:00Z"), "Lösung von Anonym (25.10.2026)")
    }

    func testOtherPDFShowsNothingAndCannotDecrypt() throws {
        let pdf = makePDFData(), other = makePDFData(marker: "Andere Fassung")
        XCTAssertNotEqual(pdf, other)
        let doc = try ownDocument()
        let package = try SolutionSharing.package(try SolutionSharing.content(source(doc, pdf: pdf), keys: ["p1"], displayName: ""),
                                                  originalPDF: pdf)
        let lib = SolutionLibrary(root: try tempDir())
        try lib.importPackage(package.encoded())
        // andere PDF: keine passende Ebene, auch nicht teilweise
        let load = SolutionSharing.loadLayers(library: lib, originalPDF: other, fingerprint: cipher.sha256Hex(other), pdf: PDFDocument(data: other)!)
        XCTAssertTrue(load.layers.isEmpty)
        XCTAssertThrowsError(try package.open(originalPDF: other, cipher: cipher)) { XCTAssertEqual($0 as? SolutionError, .fingerprintMismatch) }
        // gefaelschter Fingerabdruck im Kopf: AES-GCM scheitert (Schluessel aus den Bytes, Kopf als AAD)
        var forged = try JSONValue.parse(package.encoded())
        forged["header"]?["document"]?["sha256"] = .string(cipher.sha256Hex(other))
        let forgedLib = SolutionLibrary(root: try tempDir())
        try forgedLib.importPackage(forged.serialized(sortedKeys: true))
        let forgedLoad = SolutionSharing.loadLayers(library: forgedLib, originalPDF: other, fingerprint: cipher.sha256Hex(other),
                                                    pdf: PDFDocument(data: other)!)
        XCTAssertTrue(forgedLoad.layers.isEmpty)
        XCTAssertEqual(forgedLoad.problems.count, 1)
        XCTAssertTrue(forgedLoad.problems[0].text.contains("lässt sich mit dieser PDF-Datei nicht öffnen"), forgedLoad.problems[0].text)
        XCTAssertEqual(forgedLoad.problems[0].id, package.header.solutionID, "mit Loesungs-ID, damit sie sich entfernen laesst")
        // Seitengroessen passen nicht (gleiche Seitenzahl, andere PDF, Fingerabdruck haendisch passend gemacht):
        // abgewiesen, bevor etwas erscheint
        let content = try package.open(originalPDF: pdf, cipher: cipher)
        let letter = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 500, height: 700)).pdfData { ctx in
            for _ in 0..<3 { ctx.beginPage() }
        }
        XCTAssertThrowsError(try SolutionSharing.layer(content, visible: true, pdf: PDFDocument(data: letter)!))
    }

    func testManipulatedPackagesFailWithAESGCM() throws {
        let pdf = makePDFData()
        let package = try SolutionSharing.package(try SolutionSharing.content(source(try ownDocument(), pdf: pdf), keys: ["p1", "p2"],
                                                                                displayName: "Lea"), originalPDF: pdf)
        XCTAssertNoThrow(try SolutionPackage.decode(package.encoded()).open(originalPDF: pdf, cipher: cipher))
        var bit = package
        bit.ciphertext[bit.ciphertext.count / 2] ^= 0x04
        XCTAssertThrowsError(try bit.open(originalPDF: pdf, cipher: cipher)) { XCTAssertEqual($0 as? SolutionError, .decryptionFailed) }
        var head = try JSONValue.parse(package.encoded())
        head["header"]?["displayName"] = "Mallory"
        XCTAssertThrowsError(try SolutionPackage.decode(head.serialized(sortedKeys: true)).open(originalPDF: pdf, cipher: cipher)) {
            XCTAssertEqual($0 as? SolutionError, .decryptionFailed)
        }
        var nonce = try JSONValue.parse(package.encoded())
        nonce["header"]?["encryption"]?["nonce"] = .string(Data(repeating: 0, count: 12).base64EncodedString())
        XCTAssertThrowsError(try SolutionPackage.decode(nonce.serialized(sortedKeys: true)).open(originalPDF: pdf, cipher: cipher))
        // Import weist kaputte Dateien ab und speichert nichts
        let lib = SolutionLibrary(root: try tempDir())
        let broken = try tempDir().appendingPathComponent("kaputt.uniflowsolution")
        try Data("{\"format\":\"uniflow-solution\"".utf8).write(to: broken)
        XCTAssertThrowsError(try SolutionSharing.importFile(broken, into: lib))
        XCTAssertTrue(lib.allEntries().isEmpty)
        XCTAssertTrue(SolutionSharing.isSolutionFile(broken))
        XCTAssertFalse(SolutionSharing.isSolutionFile(URL(fileURLWithPath: "/tmp/x.pdf")))
    }

    // MARK: Anzeige

    /// Absender ohne Drehung, Empfaenger dreht Seite 1 um 90 Grad: Strich bei (100..180, 100) erscheint bei
    /// x = 842 - 100 = 742, y = 100..180 auf der gedrehten Seite; Leerseiten haben keine PDF-Seite.
    func testForeignLayerIsTransformedOntoRotatedPage() throws {
        let pdf = makePDFData()
        let doc = try ownDocument()
        let content = try SolutionSharing.content(source(doc, pdf: pdf), keys: ["p1", "p2", "p3"], displayName: "")
        let layer = try SolutionSharing.layer(content, visible: true, pdf: PDFDocument(data: pdf)!)
        let p1 = try XCTUnwrap(layer.byPDFIndex[1])

        // Empfaenger: Seite 1 um 90 Grad gedreht -> angezeigt 842 x 595
        let view = ForeignLayerView(solutionID: layer.id, page: p1, images: [:], targetRotation: 90, label: layer.label)
        XCTAssertEqual(view.bounds.size, CGSize(width: 842, height: 595))
        XCTAssertFalse(view.isUserInteractionEnabled, "nicht bearbeitbar")
        let mapped = CGPoint(x: 100, y: 100).applying(view.mapping)
        XCTAssertEqual(mapped.x, 742, accuracy: 1e-9)
        XCTAssertEqual(mapped.y, 100, accuracy: 1e-9)
        XCTAssertEqual(view.strokeLayerCount, 1)

        let overlay = PageInkView(pageIndex: 0, pageKey: "p1", geometry: PageGeometry(boxSize: CGSize(width: 595, height: 842), rotation: 90))
        overlay.setForeign([view])
        XCTAssertEqual(overlay.foreignLayerViews.count, 1)
        // Reihenfolge: fremde Schicht unter den eigenen Objekten und der Canvas
        let order = overlay.content.subviews
        XCTAssertLessThan(order.firstIndex(of: overlay.foreignView)!, order.firstIndex(of: overlay.objectsView)!)
        XCTAssertLessThan(order.firstIndex(of: overlay.objectsView)!, order.firstIndex(of: overlay.canvas)!)
        // Pixelprobe der fremden Schicht
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: overlay.foreignView.bounds.size, format: format).image { ctx in
            overlay.foreignView.layer.render(in: ctx.cgContext)
        }.cgImage!
        XCTAssertGreaterThan(pixel(img, 742, 140).a, 200, "Tinte an der gedrehten Stelle")
        XCTAssertEqual(pixel(img, 140, 100).a, 0, "nicht an der ungedrehten Stelle")

        // gleiche Drehung wie der Absender (Seite 2: pageOrder 90, Empfaenger ebenso): unveraendert
        let p2 = try XCTUnwrap(layer.byPDFIndex[2])
        XCTAssertTrue(ForeignLayerView(solutionID: "", page: p2, images: [:], targetRotation: 90, label: "").mapping.isIdentity)
        // Seite 3: eigene /Rotate 90 der PDF, Empfaenger ohne zusaetzliche Drehung ebenfalls 90 -> unveraendert
        let p3 = try XCTUnwrap(layer.byPDFIndex[3])
        XCTAssertEqual(p3.rotation, 90)
        XCTAssertTrue(ForeignLayerView(solutionID: "", page: p3, images: [:], targetRotation: 90, label: "").mapping.isIdentity)
        // Querformat-Seite 2 beim Empfaenger ohne eigene Drehung (0): von 90 zurueck nach 0
        let back = ForeignLayerView(solutionID: "", page: p2, images: [:], targetRotation: 0, label: "")
        XCTAssertEqual(back.bounds.size, CGSize(width: 842, height: 595))
        let t = SolutionGeometry.transform(width: 842, height: 595, from: 90, to: 0)
        let q = CGPoint(x: 50, y: 60).applying(back.mapping)
        XCTAssertEqual(q.x, t.apply(x: 50, y: 60).x, accuracy: 1e-9)
        XCTAssertEqual(q.y, t.apply(x: 50, y: 60).y, accuracy: 1e-9)
    }

    /// Vorschau ohne Original: weisser Hintergrund (auch wo die PDF-Seite rot ist), Tinte vorhanden.
    func testPreviewIsWhiteWithInkAndNoPDF() throws {
        let pdf = makePDFData()
        let content = try SolutionSharing.content(source(try ownDocument(), pdf: pdf), keys: ["p1", "bL"], displayName: "")
        let page = content.pages[0]
        let img = SolutionPreview.image(page, images: [:], width: 595, scale: 1).cgImage!
        XCTAssertEqual(img.width, 595)
        XCTAssertEqual(img.height, 842)
        for (x, y) in [(2, 2), (590, 5), (300, 700), (5, 835)] {
            let p = pixel(img, x, y)
            XCTAssertTrue(p.r > 250 && p.g > 250 && p.b > 250, "weiss bei \(x),\(y): \(p)")
        }
        let ink = pixel(img, 140, 100)
        XCTAssertTrue(ink.r < 60 && ink.g < 60 && ink.b < 60, "schwarze Tinte: \(ink)")
        // Leerseite mit Vorlage: Linien sichtbar, sonst weiss
        let blank = SolutionPreview.image(content.pages[1], images: [:], width: 595, scale: 1).cgImage!
        let line = (106...109).map { Int(pixel(blank, 400, $0).r) }.min() ?? 255     // liniert: 60 + 2 * 24 = 108
        XCTAssertLessThan(line, 250, "Vorlagenlinie")
        let white = pixel(blank, 400, 96)
        XCTAssertGreaterThan(Int(white.r), 250)
    }

    // MARK: Eigene Notizen bleiben unveraendert

    /// Eigenes Dokument im lokalen Backend (Temp-Ordner) mit der Test-PDF als Original-Datei.
    private func makeStore(pdf: Data) async throws -> DocumentStore {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "loesung-test-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdfDirectory(api.namespace, root: root).appendingPathComponent(fileID + ".pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-10-25", has_notes: nil, page_count: 3, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.originalPDFURL, pdfURL)
        return store
    }

    private func serialized(_ store: DocumentStore) async -> Data {
        await store.flush()
        return (await store.pageStructureDocument()).root.serialized(sortedKeys: true)
    }

    func testOwnNotesUnchangedAfterImportAndShowing() async throws {
        let pdf = makePDFData()
        let store = try await makeStore(pdf: pdf)
        XCTAssertEqual(try store.originalPDFData(), pdf, "unveraenderte Dateibytes, nicht dataRepresentation()")
        await store.addText("Meine eigene Notiz", pageKey: "p1")
        await store.flush()
        let before = (await store.pageStructureDocument()).root.serialized(sortedKeys: true)
        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("Meine eigene Notiz"))

        // Loesung einer anderen Person zu derselben PDF empfangen und einblenden
        let lib = SolutionLibrary(root: try tempDir())
        let foreign = try ownDocument()
        let package = try SolutionSharing.package(try SolutionSharing.content(source(foreign, pdf: pdf), keys: ["p1", "p2"], displayName: "Ben"),
                                                  originalPDF: pdf)
        try lib.importPackage(package.encoded())
        let load = await store.solutionLayers(library: lib)
        XCTAssertTrue(load.problems.isEmpty, load.problems.map(\.text).joined())
        XCTAssertEqual(load.layers.count, 1)

        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        editor.foreignLayers = load.layers
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertEqual(overlay.foreignLayerViews.map(\.solutionID), [package.header.solutionID])
        // Meine Notizen ausblenden = nur ansehen, wieder einblenden
        editor.ownNotesVisible = false
        XCTAssertTrue(overlay.canvas.isHidden)
        XCTAssertFalse(overlay.canvas.isUserInteractionEnabled)
        XCTAssertFalse(overlay.foreignView.isHidden, "fremde Ebene bleibt sichtbar")
        editor.ownNotesVisible = true
        XCTAssertFalse(overlay.canvas.isHidden)
        // fremde Ebene aus- und wieder einblenden
        var hidden = load.layers
        hidden[0].visible = false
        editor.foreignLayers = hidden
        XCTAssertTrue(overlay.foreignLayerViews.isEmpty)
        editor.foreignLayers = load.layers
        XCTAssertEqual(overlay.foreignLayerViews.count, 1)
        // Zuordnung ueber den PDF-Seitenindex: eigene Anzeige-Seite 2 = PDF-Seite 2 (die Leerseite der Loesung hat
        // keine Entsprechung und erscheint nicht)
        let second = try XCTUnwrap(editor.overlayForTesting(at: 1))
        XCTAssertEqual(second.foreignLayerViews.count, 1)

        try? await Task.sleep(nanoseconds: 400_000_000)       // ausstehende Verarbeitung haette jetzt begonnen
        await store.flush()
        let after = (await store.pageStructureDocument()).root.serialized(sortedKeys: true)
        XCTAssertEqual(before, after, "eigenes Dokument byte-genau unveraendert")
        XCTAssertFalse(String(decoding: after, as: UTF8.self).contains("x = 42"), "nichts Fremdes im eigenen Dokument")
        await store.close()
    }

    /// Zuordnung ueber den Editor-Pfad: Der Empfaenger hat eine eigene Leerseite VOR PDF-Seite 1 eingefuegt und
    /// PDF-Seite 2 zweimal gedreht (180 Grad). Die fremde Ebene erscheint nur auf PDF-Seiten, an der richtigen
    /// Anzeige-Seite und mit der Abbildung von der Drehung des Absenders (90) auf 180.
    func testForeignLayerFollowsOwnPageOrderInEditor() async throws {
        let pdf = makePDFData()
        let store = try await makeStore(pdf: pdf)
        let change = await store.applyPageStructure { doc in
            guard let c = PageOrder.insertBlank(&doc, after: nil, template: "grid", key: "bVORNE") else { return nil }
            var order = doc.pageOrder
            let blank = order.removeLast()
            order.insert(blank, at: 0)
            doc.root["pageOrder"] = .array(order)
            return c
        }
        XCTAssertNotNil(change)
        await store.rotatePage(key: "p2")
        await store.rotatePage(key: "p2")
        XCTAssertEqual(store.layout?.entries.map(\.key), ["bVORNE", "p1", "p2", "p3"])
        let before = await serialized(store)

        let lib = SolutionLibrary(root: try tempDir())
        let package = try SolutionSharing.package(try SolutionSharing.content(source(try ownDocument(), pdf: pdf), keys: ["p1", "bL", "p2"],
                                                                                displayName: "Ben"), originalPDF: pdf)
        try lib.importPackage(package.encoded())
        let load = await store.solutionLayers(library: lib)
        XCTAssertTrue(load.problems.isEmpty, load.problems.map(\.text).joined())
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        editor.foreignLayers = load.layers

        // Anzeige-Seite 0 ist die eigene Leerseite: keine fremde Ebene (auch nicht die Leerseite der Loesung)
        XCTAssertTrue(try XCTUnwrap(editor.overlayForTesting(at: 0)).foreignLayerViews.isEmpty)
        // Anzeige-Seite 1 = PDF-Seite 1 (ungedreht): Abbildung unveraendert
        let first = try XCTUnwrap(editor.overlayForTesting(at: 1)).foreignLayerViews
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first.first?.mapping.isIdentity == true)
        XCTAssertEqual(first.first?.bounds.size, CGSize(width: 595, height: 842))
        // Anzeige-Seite 2 = PDF-Seite 2 (842 x 595), Absender 90, Empfaenger 180
        let second = try XCTUnwrap(editor.overlayForTesting(at: 2)).foreignLayerViews
        XCTAssertEqual(second.count, 1)
        let t = SolutionGeometry.transform(width: 842, height: 595, from: 90, to: 180)
        let expected = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
        XCTAssertEqual(second.first?.mapping, expected)
        XCTAssertFalse(second.first?.mapping.isIdentity ?? true)
        XCTAssertEqual(second.first?.bounds.size, CGSize(width: 842, height: 595), "180 Grad: Groesse wie ungedreht")
        // Anzeige-Seite 3 = PDF-Seite 3: nicht geteilt -> nichts
        XCTAssertTrue(try XCTUnwrap(editor.overlayForTesting(at: 3)).foreignLayerViews.isEmpty)

        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = await serialized(store)
        XCTAssertEqual(before, after, "eigenes Dokument vor und nach dem Einblenden byte-gleich")
        await store.close()
    }

    // MARK: Nur ansehen

    /// "Meine Notizen" ausgeblendet: Text, Leerseite, Drehen, Papierkorb, Wiederherstellen und Lesezeichen schreiben
    /// nichts ins eigene Dokument.
    func testHiddenOwnNotesAreViewOnly() async throws {
        let pdf = makePDFData()
        let store = try await makeStore(pdf: pdf)
        await store.addText("vorher", pageKey: "p1")
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let before = await serialized(store)

        editor.ownNotesVisible = false
        XCTAssertTrue(store.ownNotesReadOnly)
        await store.addText("im Ansichtsmodus", pageKey: "p1")
        await store.addBlankPage(afterKey: "p1", template: "lined")
        await store.rotatePage(key: "p1")
        await store.toggleBookmark(pageKey: "p1", title: "Seite 1")
        let trashed = await store.applyPageStructure { doc in PageOrder.trash(&doc, key: "p2") }
        XCTAssertNil(trashed)
        let inserted = await editor.insertBlankPage(after: "p1", template: "grid")
        XCTAssertNil(inserted)
        let trashedByEditor = await editor.trashPage(key: "p3")
        XCTAssertFalse(trashedByEditor)
        let during = await serialized(store)
        XCTAssertEqual(during, before, "nichts geschrieben")

        // wieder eingeblendet: schreiben geht wieder
        editor.ownNotesVisible = true
        XCTAssertFalse(store.ownNotesReadOnly)
        await store.addText("danach", pageKey: "p1")
        let after = await serialized(store)
        XCTAssertNotEqual(after, before)
        await store.close()
    }

    // MARK: Import im offenen Dokument

    /// Passender Fingerabdruck, aber nicht lesbarer Inhalt (manipuliertes Chiffrat bzw. mit einer anderen PDF
    /// versiegelt und den Fingerabdruck uebernommen): sofort wieder entfernt, nichts bleibt unter dem Fingerabdruck.
    func testUnreadableImportForOpenDocumentIsRemoved() async throws {
        let pdf = makePDFData(), other = makePDFData(marker: "Andere Fassung")
        let store = try await makeStore(pdf: pdf)
        let fingerprint = await store.originalFingerprint()
        let fp = try XCTUnwrap(fingerprint)
        let lib = SolutionLibrary(root: try tempDir())
        let dir = try tempDir()
        let package = try SolutionSharing.package(try SolutionSharing.content(source(try ownDocument(), pdf: pdf), keys: ["p1"],
                                                                                displayName: "Lea"), originalPDF: pdf)
        // 1) Chiffrat veraendert, Kopf passend
        var flipped = package
        flipped.ciphertext[flipped.ciphertext.count / 3] ^= 0x01
        let flippedURL = dir.appendingPathComponent("veraendert.uniflowsolution")
        try flipped.encoded().write(to: flippedURL)
        guard case .removedUnreadable(let e1, let err1) = try await store.importSolution(flippedURL, library: lib) else {
            return XCTFail("nicht entfernt")
        }
        XCTAssertEqual(e1.solutionID, package.header.solutionID)
        XCTAssertEqual(err1, .decryptionFailed)
        XCTAssertTrue(lib.entries(fingerprint: fp).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.root.appendingPathComponent("received/\(e1.solutionID).uniflowsolution").path))
        // 2) mit einer anderen PDF versiegelt, Fingerabdruck dieser PDF eingetragen
        let foreignSealed = try SolutionSharing.package(try SolutionSharing.content(source(try ownDocument(), pdf: other), keys: ["p1"],
                                                                                      displayName: ""), originalPDF: other)
        var forged = try JSONValue.parse(foreignSealed.encoded())
        forged["header"]?["document"]?["sha256"] = .string(fp)
        let forgedURL = dir.appendingPathComponent("gefaelscht.uniflowsolution")
        try forged.serialized(sortedKeys: true).write(to: forgedURL)
        guard case .removedUnreadable = try await store.importSolution(forgedURL, library: lib) else { return XCTFail("nicht entfernt") }
        XCTAssertTrue(lib.entries(fingerprint: fp).isEmpty)
        XCTAssertTrue(lib.allEntries().isEmpty)
        XCTAssertTrue(SolutionSharing.unreadableImportMessage.contains("passt nicht zu dieser PDF oder wurde verändert"))
        // 3) gueltig: angezeigt; andere PDF: bleibt gespeichert
        let okURL = dir.appendingPathComponent("gut.uniflowsolution")
        try package.encoded().write(to: okURL)
        guard case .shown = try await store.importSolution(okURL, library: lib) else { return XCTFail("nicht angezeigt") }
        XCTAssertEqual(lib.entries(fingerprint: fp).map(\.solutionID), [package.header.solutionID])
        let otherURL = dir.appendingPathComponent("andere.uniflowsolution")
        try foreignSealed.encoded().write(to: otherURL)
        guard case .otherPDF = try await store.importSolution(otherURL, library: lib) else { return XCTFail("nicht als andere PDF erkannt") }
        XCTAssertEqual(lib.allEntries().count, 2)
        await store.close()
    }

    func testProblemNoticeOnlyOncePerSession() {
        SolutionProblemNotices.resetForTesting()
        let p = SolutionLayerLoad.Problem(id: "6f1c1c0e-6a63-4c38-9a0b-6c0f0f7b9a11", label: "Lösung von Anonym (25.10.2026)",
                                          message: SolutionError.decryptionFailed.description)
        XCTAssertEqual(SolutionProblemNotices.unseen([p]), [p])
        XCTAssertTrue(SolutionProblemNotices.unseen([p]).isEmpty, "zweites Laden: kein erneuter Hinweis")
        XCTAssertEqual(p.text, "Lösung von Anonym (25.10.2026): \(SolutionError.decryptionFailed.description)")
    }

    // MARK: Bilder

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }

    private static func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }

    /// Grossflaechiges, stark komprimiertes PNG (1 Bit Grau, einfarbig): wenige Kilobyte, entpackt aber viele
    /// Gigabyte als Bitmap.
    private func bombPNG(width: Int, height: Int) throws -> Data {
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let body = Array(type.utf8) + data
            return Self.be32(UInt32(data.count)) + body + Self.be32(Self.crc32(body))
        }
        let rowBytes = 1 + (width + 7) / 8
        let raw = Data(count: rowBytes * height)
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data      // rohes DEFLATE (RFC 1951)
        // Adler-32 ueber lauter Nullen: a bleibt 1, b = Anzahl Bytes mod 65521
        let a: UInt32 = 1, b = UInt32(raw.count % 65_521)
        let zlib: [UInt8] = [0x78, 0x01] + [UInt8](deflated) + Self.be32((b << 16) | a)
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", Self.be32(UInt32(width)) + Self.be32(UInt32(height)) + [1, 0, 0, 0, 0])
        png += chunk("IDAT", zlib)
        png += chunk("IEND", [])
        return Data(png)
    }

    func testOversizedEmbeddedImageRejectsWholeSolution() throws {
        let bomb = try bombPNG(width: 20_000, height: 20_000)
        XCTAssertLessThan(bomb.count, 200_000, "klein als Datei")
        let size = try XCTUnwrap(ForeignSolutionLayer.pixelSize(bomb))
        XCTAssertEqual(size.width, 20_000)
        XCTAssertEqual(size.height, 20_000)
        XCTAssertFalse(ForeignSolutionLayer.fitsLimits(width: size.width, height: size.height))
        XCTAssertFalse(ForeignSolutionLayer.fitsLimits(width: 8_192, height: 8_193))
        XCTAssertFalse(ForeignSolutionLayer.fitsLimits(width: 5_000, height: 5_000), "25 MP")
        XCTAssertTrue(ForeignSolutionLayer.fitsLimits(width: 4_096, height: 4_096))
        XCTAssertThrowsError(try ForeignSolutionLayer.uiImages(["/x": SolutionImage(mime: "image/png", data: bomb)])) {
            XCTAssertEqual($0 as? SolutionError, .imageTooLarge)
        }

        // gueltig verschluesseltes Paket mit diesem Bild (wie es jeder mit derselben PDF bauen koennte)
        let pdf = makePDFData()
        let doc = try ownDocument()
        let plain = source(doc, pdf: pdf)
        let src = SolutionSource(document: doc, originalPDF: pdf, pdfPageCount: plain.pdfPageCount, pageInfos: plain.pageInfos,
                                 fingerprint: plain.fingerprint,
                                 images: ["/api/files/x/assets/skizze.png": SolutionImage(mime: "image/png", data: bomb)], title: "Blatt")
        let content = try SolutionSharing.content(src, keys: ["p1"], displayName: "")
        XCTAssertEqual(content.images.count, 1)
        let lib = SolutionLibrary(root: try tempDir())
        try lib.importPackage(try SolutionSharing.package(content, originalPDF: pdf).encoded())
        let load = SolutionSharing.loadLayers(library: lib, originalPDF: pdf, fingerprint: cipher.sha256Hex(pdf), pdf: PDFDocument(data: pdf)!)
        XCTAssertTrue(load.layers.isEmpty, "ganze Ebene abgewiesen")
        XCTAssertEqual(load.problems.map(\.message), [SolutionError.imageTooLarge.description])
        XCTAssertThrowsError(try SolutionSharing.layer(content, visible: true, pdf: PDFDocument(data: pdf)!)) {
            XCTAssertEqual($0 as? SolutionError, .imageTooLarge)
        }
        // eigene grosse Bilder werden beim Teilen verkleinert, damit der Empfaenger sie oeffnen kann
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 9_000, height: 60), format: format).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 9_000, height: 60))
        }
        let embedded = try XCTUnwrap(SolutionSharing.embed(["/w": wide])["/w"])
        let fitted = try XCTUnwrap(ForeignSolutionLayer.pixelSize(embedded.data))
        XCTAssertEqual(fitted.width, 8_192)
        XCTAssertTrue(ForeignSolutionLayer.fitsLimits(width: fitted.width, height: fitted.height))
        XCTAssertNoThrow(try ForeignSolutionLayer.uiImages(["/w": embedded]))
    }

    // MARK: Schluessel

    /// HKDF in Bloecken ueber die PDF-Bytes = HKDF-SHA256 nach RFC 5869 (Testfall 1) und = CryptoKit `deriveKey`.
    func testStreamingHKDFMatchesRFC5869AndCryptoKit() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data((0x00...0x0c).map { UInt8($0) })
        let info = Data((0xf0...0xf9).map { UInt8($0) })
        let okm = CryptoKitSolutionCipher.deriveKey(ikm, salt: salt, info: info).withUnsafeBytes { Data($0) }
        XCTAssertEqual(okm.map { String(format: "%02x", $0) }.joined(),
                       "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf")
        var rng = SystemRandomNumberGenerator()
        for n in [1, 1 << 20, (1 << 20) + 1, 3 * (1 << 20) + 17] {
            let data = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let s = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let streamed = CryptoKitSolutionCipher.deriveKey(data, salt: s, info: info).withUnsafeBytes { Data($0) }
            let reference = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: data), salt: s, info: info, outputByteCount: 32)
                .withUnsafeBytes { Data($0) }
            XCTAssertEqual(streamed, reference, "\(n) Byte")
        }
    }

    // MARK: Texte

    func testDialogTextsAreHonest() {
        XCTAssertEqual(SolutionTexts.ownNotesOnly,
                       "Geteilt werden nur deine eigenen Notizen – keine Folien, keine Aufgabenstellungen, keine PDF. Teile nur, was du selbst erstellt hast.")
        XCTAssertTrue(SolutionTexts.examRules.contains("Prüfungsordnung"))
        XCTAssertEqual(SolutionTexts.communityNotConnected, "Community-Dienst noch nicht verbunden")
        XCTAssertTrue(SolutionTexts.pdfExportPrivate.contains("Originalmaterial"))
        XCTAssertFalse(SolutionSharing.community.isConnected)
    }
}
