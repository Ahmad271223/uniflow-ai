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
        XCTAssertTrue(load.problems.isEmpty, load.problems.joined())
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
        XCTAssertTrue(forgedLoad.problems[0].contains("lässt sich mit dieser PDF-Datei nicht öffnen"), forgedLoad.problems[0])
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

    func testOwnNotesUnchangedAfterImportAndShowing() async throws {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "loesung-test-" + UUID().uuidString.prefix(8).lowercased()
        let pdf = makePDFData()
        let pdfURL = AppPaths.pdfDirectory(api.namespace, root: root).appendingPathComponent(fileID + ".pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-10-25", has_notes: nil, page_count: 3, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.originalPDFURL, pdfURL)
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
        XCTAssertTrue(load.problems.isEmpty, load.problems.joined())
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
