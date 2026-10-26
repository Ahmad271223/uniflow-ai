import CryptoKit
import PDFKit
import UniFlowCore
import XCTest
@testable import UniFlow

// Haertetests "Loesung teilen" (Paket angreifen) mit echter Verschluesselung (AES-256-GCM, HKDF-SHA256 aus
// CryptoKit), selbst erzeugten Test-PDFs und erfundenen Notizen. Alle Zufallswerte kommen aus einem festen Seed.
//
// - Eigenschaftstest: 200 zufaellige Notiz-Dokumente (1 bis 40 PDF-Seiten, alle Objektarten, unbekannte Felder,
//   Unicode/Emoji/RTL, Striche mit 10 000 Punkten, Grenzwerte) -> Loesung -> Import auf einem zweiten Geraet
//   (eigener Ordner) -> jede Anmerkung byte-gleich, keine PDF-Bytes im Paket.
// - Falsche PDF (ein Byte am Ende anders, gleiche Seitenzahl und Groesse), Bit-Flip an jeder Byte-Position,
//   abgeschnittene, leere und riesige Dateien, doppelter Import, zwei Personen, spaeter geoeffnete PDF, Import bei
//   offenem Dokument, Anzeige von Grenzwerten ohne Absturz.

/// SplitMix64: kleiner, deterministischer Zufallsgenerator (fester Seed, gleiche Folge auf jedem Geraet).
private struct PaketSeedRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
    mutating func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &self) }) }

    /// UUID (Version 4) aus dem Seed.
    mutating func uuid() -> UUID {
        var b = [UInt8](bytes(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// Erzeugt erfundene Notiz-Dokumente aus dem Seed. Kein Text enthaelt "%" oder die Grossbuchstaben von "GEHEIM",
/// damit die Suche nach PDF-Kennungen und Geheimmarken im Paket eindeutig ist.
private struct PaketNoteFuzzer {
    var rng: PaketSeedRNG

    /// Grenzwerte: 0, -0, negativ, winzig, gross, groesste endliche Zahl, ueber 2^53.
    static let extremes: [Double] = [
        0, -0.0, 1, -1, 0.5, -0.25, 1e-300, -1e-300, 5e-324, -5e-324, 1e15, 1e15 - 1, -1e15, 999_999_999_999_999.9,
        9_007_199_254_740_993, 1e300, -1e300, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        123_456_789.123_456_789, -987_654.321, 0.1 + 0.2,
    ]

    /// Bausteine fuer Texte: Umlaute, Emoji (auch ZWJ-Folgen und Flaggen), Hebraeisch/Arabisch (RTL),
    /// Steuerzeichen fuer Richtung, kombinierende Zeichen, JSON-Sonderzeichen, NUL, Zeilen- und Absatztrenner.
    static let pieces: [String] = [
        "a", "Z", "0", "7", " ", "ä", "ö", "ü", "ß", "€", "x = 3", "😀", "👩‍👩‍👧‍👦", "🏳️‍🌈", "🇩🇪", "👍🏽", "שלום", "مرحبا",
        "\u{200F}", "\u{200E}", "\u{202E}", "\u{2067}", "e\u{301}", "\u{0}", "\n", "\t", "\r", "\r\n", "\"", "\\", "/",
        "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{FFFD}", "\u{FFFF}", "𝕏", "中文", "\u{1F}", "\u{7F}", "{", "}", "[", "]",
        ":", ",", "<", ">", "&", "'", "\u{10FFFF}", "ﷺ", "ǅ",
    ]

    static let unknownKeys: [String] = [
        "zukunft", "eigenesFeld", "schlüssel_🔑", "مفتاح", "מפתח", "key with space", "e\u{301}feld", "\u{0}nul",
        "über/Pfad", "emoji😀", "data", "meta",
    ]

    static let colors = ["#000000", "#1d2130", "#d64545", "#ffd400", "#fff3a3", "rgba(0,0,0,0.5)", "", "#GGG", "blau"]

    mutating func number() -> Double {
        switch rng.int(0...9) {
        case 0, 1: return rng.pick(Self.extremes)
        case 2, 3: return Double(rng.int(-1_000_000_000...1_000_000_000))
        case 4: return Double.random(in: -1e6...1e6, using: &rng)               // volle Genauigkeit
        default: return (Double.random(in: -200...1200, using: &rng) * 4).rounded() / 4
        }
    }

    mutating func text(_ maxPieces: Int = 12) -> String {
        (0..<rng.int(0...maxPieces)).map { _ in rng.pick(Self.pieces) }.joined()
    }

    mutating func value(depth: Int = 0) -> JSONValue {
        switch rng.int(0...(depth >= 3 ? 4 : 6)) {
        case 0: return .null
        case 1: return .bool(rng.chance(0.5))
        case 2, 3: return .number(number())
        case 4: return .string(text())
        case 5: return .array((0..<rng.int(0...4)).map { _ in value(depth: depth + 1) })
        default:
            var o: [String: JSONValue] = [:]
            for _ in 0..<rng.int(0...4) { o[rng.pick(Self.unknownKeys) + "\(rng.int(0...9))"] = value(depth: depth + 1) }
            return .object(o)
        }
    }

    mutating func points(_ count: Int) -> JSONValue { .array((0..<(2 * count)).map { _ in .number(number()) }) }

    /// Ein eigenes Objekt (stroke, text, shape, image) mit zufaelligen unbekannten Feldern.
    mutating func object(id: String, imageSources: [String], long: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id)]
        let kind = long ? 0 : rng.int(0...3)
        switch kind {
        case 0:
            o["type"] = "stroke"
            o["tool"] = .string(rng.pick(["pen", "marker", "pencil", "highlighter", "laser"]))
            o["color"] = .string(rng.pick(Self.colors))
            o["width"] = .number(number())
            o["opacity"] = .number(rng.pick([1, 0.4, 0, -1, 2]))
            let n = long ? 10_000 : rng.int(1...40)
            o["points"] = points(n)
            if long || rng.chance(0.3) { o["widths"] = .array((0..<n).map { _ in .number((Double.random(in: 0...8, using: &rng) * 8).rounded() / 8) }) }
            if rng.chance(0.2) { o["pkInk"] = "com.apple.ink.monoline" }
        case 1:
            o["type"] = "text"
            o["text"] = .string(text(40))
            o["fontSize"] = .number(number())
            o["fill"] = .string(rng.pick(Self.colors))
            if rng.chance(0.5) { o["bg"] = .string(rng.pick(Self.colors)) }        // Haftnotiz
            o["width"] = .number(number())
            if rng.chance(0.3) { o["align"] = .string(rng.pick(["left", "center", "right", "blocksatz"])) }
            if rng.chance(0.3) { o["bold"] = .bool(rng.chance(0.5)) }
            if rng.chance(0.2) { o["fontFamily"] = .string(rng.pick(["Arial", "Helvetica", "Unbekannt", ""])) }
        case 2:
            o["type"] = "shape"
            o["shape"] = .string(rng.pick(["rect", "ellipse", "triangle", "polygon", "arrow", "line", "stern"]))
            o["width"] = .number(number())
            o["height"] = .number(number())
            if rng.chance(0.5) { o["points"] = points(rng.int(0...12)) }
            o["stroke"] = .string(rng.pick(Self.colors))
            if rng.chance(0.5) { o["fill"] = .string(rng.pick(Self.colors)) }
            o["strokeWidth"] = .number(number())
        default:
            o["type"] = "image"
            o["src"] = .string(imageSources.isEmpty ? "/api/files/x/assets/ohne.png" : rng.pick(imageSources))
            o["width"] = .number(number())
            o["height"] = .number(number())
        }
        for key in ["x", "y", "rotation", "scaleX", "scaleY"] where rng.chance(0.8) { o[key] = .number(number()) }
        for _ in 0..<rng.int(0...3) { o[rng.pick(Self.unknownKeys) + "\(rng.int(0...99))"] = value() }
        return .object(o)
    }
}

/// Ein erzeugtes Testfall-Dokument mit allem, was der Vergleich braucht.
private struct PaketCase {
    let doc: AnnotationDocument
    let pdf: Data
    let pdfDocument: PDFDocument
    let images: [String: SolutionImage]
    /// geteilte Seiten in Anzeigereihenfolge (pdf/blank mit eigenen Objekten)
    let expectedKeys: [String]
    let expectedMissing: [String]
    let title: String
    let displayName: String
    let longStrokes: Int
}

@MainActor
final class HardeningSolutionRoundTripTests: XCTestCase {
    let cipher = CryptoKitSolutionCipher()

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-haerte-paket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: Testdaten

    private static let pageSizes: [CGSize] = [
        CGSize(width: 595, height: 842), CGSize(width: 842, height: 595), CGSize(width: 600, height: 780),
        CGSize(width: 420, height: 595), CGSize(width: 1190, height: 1684), CGSize(width: 200, height: 200),
        CGSize(width: 500, height: 1400),
    ]

    /// Selbst erzeugte Test-PDF mit `count` Seiten (Groessen und `/Rotate` aus dem Seed). Rueckgabe: Dateibytes.
    private func makePDF(pages count: Int, marker: String, rng: inout PaketSeedRNG) -> Data {
        let sizes = (0..<count).map { _ in rng.pick(Self.pageSizes) }
        let rotations = (0..<count).map { _ in rng.pick([0, 0, 0, 90, 180, 270]) }
        let raw = NSMutableData()
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: sizes[0]), nil)
        for (i, s) in sizes.enumerated() {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: s), nil)
            ("\(marker) Seite \(i + 1)" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
        UIGraphicsEndPDFContext()
        guard rotations.contains(where: { $0 != 0 }), let doc = PDFDocument(data: raw as Data) else { return raw as Data }
        for (i, r) in rotations.enumerated() { doc.page(at: i)?.rotation = r }
        return doc.dataRepresentation()!
    }

    /// Kleine echte PNG- und JPEG-Bilder (eigene Bilder des Absenders).
    private static let tinyImages: (png: Data, jpeg: Data) = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: 6, height: 4), format: format).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        }
        return (img.pngData()!, img.jpegData(compressionQuality: 0.8)!)
    }()

    /// Zufaelliges Notiz-Dokument zu einer zufaelligen PDF (1 bis 40 Seiten).
    private func makeCase(_ i: Int, rng: inout PaketSeedRNG, longStroke: Bool) -> PaketCase {
        let pageCount = rng.int(1...40)
        let pdf = makePDF(pages: pageCount, marker: "Dokument \(i)", rng: &rng)
        let pdfDocument = PDFDocument(data: pdf)!
        var fuzz = PaketNoteFuzzer(rng: rng)
        let srcs = (0..<3).map { "/api/files/f\(i)/assets/bild\($0).png" }
        // bild0 als PNG, bild1 als JPEG verfuegbar, bild2 fehlt beim Absender
        let images = [srcs[0]: SolutionImage(mime: "image/png", data: Self.tinyImages.png),
                      srcs[1]: SolutionImage(mime: "image/jpeg", data: Self.tinyImages.jpeg)]

        var order: [JSONValue] = []
        var pages: [String: JSONValue] = [:]
        var blanks = 0, assets = 0
        for p in 1...pageCount {
            // eigene Leerseiten und eingefuegte Bild-/PDF-Seiten an zufaelligen Stellen
            if fuzz.rng.chance(0.08) {
                blanks += 1
                var e: [String: JSONValue] = ["key": .string("b\(i)x\(blanks)"), "type": "blank"]
                if fuzz.rng.chance(0.8) { e["template"] = .string(fuzz.rng.pick(PageOrder.templates + ["hexagon"])) }
                if fuzz.rng.chance(0.7) { e["w"] = .number(fuzz.rng.pick([595, 842, 0, -5, 14_400, 0.5, 300.25])) }
                if fuzz.rng.chance(0.7) { e["h"] = .number(fuzz.rng.pick([842, 595, 0, -1e300, 14_400, 3, 1000.5])) }
                if fuzz.rng.chance(0.3) { e["rotation"] = .number(Double(fuzz.rng.pick([90, 180, 270, 360, -90, 450]))) }
                order.append(.object(e))
            }
            if fuzz.rng.chance(0.04) {
                assets += 1
                let key = "a\(i)x\(assets)"
                order.append(.object(["key": .string(key), "type": "asset", "src": "/api/assets/fremd.pdf"]))
                pages[key] = .object(["objects": .array([.object(["id": "asset1", "type": "text", "text": "ASSET-GEHEIM",
                                                                   "x": 1, "y": 2])])])
            }
            var e: [String: JSONValue] = ["key": .string("p\(p)"), "type": "pdf", "index": .number(Double(p))]
            if fuzz.rng.chance(0.25) { e["rotation"] = .number(Double(fuzz.rng.pick([90, 180, 270, 360, -90]))) }
            order.append(.object(e))
        }
        let keys = order.compactMap { $0["key"]?.string }.filter { !$0.hasPrefix("a") }
        var longs = 0
        var objectID = 0
        for key in keys {
            guard fuzz.rng.chance(0.45) || key == "p1" else { continue }
            var objects: [JSONValue] = []
            for _ in 0..<fuzz.rng.int(key == "p1" ? 1...6 : 0...6) {
                objectID += 1
                objects.append(fuzz.object(id: "o\(objectID)", imageSources: srcs, long: false))
            }
            if longStroke && longs == 0 {
                longs += 1
                objectID += 1
                objects.append(fuzz.object(id: "lang\(objectID)", imageSources: srcs, long: true))
            }
            var page: [String: JSONValue] = ["objects": .array(objects)]
            if fuzz.rng.chance(0.3) {
                page["pkdrawing"] = .object(["data": "UEtEUkFXSU5HLUdFSEVJTQ==", "objectsSig": "PKDRAWING-GEHEIM",
                                             "format": "pkdrawing-v1"])
            }
            pages[key] = .object(page)
        }
        let root: JSONValue = .object([
            "version": 2, "zoom": 1.4, "note": "WURZEL-GEHEIM", "pageOrder": .array(order), "pages": .object(pages),
            "bookmarks": .array([.object(["key": "p1", "title": "LESEZEICHEN-GEHEIM"])]),
            "deletedPages": .array([.object(["entry": .object(["key": "bWEG", "type": "blank"]),
                                            "objects": .array([.object(["id": "w1", "type": "text", "text": "PAPIERKORB-GEHEIM"])])])]),
        ])
        let doc = AnnotationDocument(root: root)
        let expectedKeys = SolutionBuilder.candidates(doc).filter { $0.shareable && $0.objectCount > 0 }.map(\.key)
        let referenced = Set(expectedKeys.flatMap { doc.objects(page: $0) }.filter { $0["type"]?.string == "image" }
            .compactMap { $0["src"]?.string })
        let expectedMissing = referenced.filter { images[$0] == nil }.sorted()
        let title = fuzz.text(30)
        let name = fuzz.rng.chance(0.3) ? "" : fuzz.text(25)
        rng = fuzz.rng
        return PaketCase(doc: doc, pdf: pdf, pdfDocument: pdfDocument, images: images, expectedKeys: expectedKeys,
                         expectedMissing: expectedMissing, title: title, displayName: name, longStrokes: longs)
    }

    /// Keine PDF-Bytes: keine PDF-Kennungen, keine Stichproben der PDF (roh und als Base64 in allen drei
    /// Ausrichtungen). `binaryOK` = Datei mit Base64-Chiffrat (dort nur Kennungen ausserhalb des Base64-Alphabets).
    private func assertNoPDF(_ blob: Data, pdf: Data, rng: inout PaketSeedRNG, cipherText: Bool, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let markers = cipherText ? ["%PDF", "%%EOF", "JVBERi0"] : ["%PDF", "%%EOF", "JVBERi0", "endobj", "/MediaBox", "xref", "GEHEIM"]
        for m in markers {
            XCTAssertNil(blob.range(of: Data(m.utf8)), "\(what): \(m)", file: file, line: line)
        }
        var checked = 0
        for _ in 0..<40 where checked < 12 {
            let off = rng.int(0...(pdf.count - 24))
            let window = pdf.subdata(in: off..<(off + 24))
            guard Set(window).count >= 10 else { continue }          // Fuellbytes (Nullen, Querverweise) ueberspringen
            checked += 1
            XCTAssertNil(blob.range(of: window), "\(what): PDF-Stueck bei \(off)", file: file, line: line)
        }
        for shift in 0..<3 {
            let b64 = Array(pdf.dropFirst(shift).base64EncodedString().utf8)
            for _ in 0..<4 {
                let off = rng.int(0...((b64.count - 32) / 4)) * 4
                XCTAssertNil(blob.range(of: Data(b64[off..<(off + 32)])), "\(what): Base64 der PDF (Versatz \(shift)) bei \(off)",
                             file: file, line: line)
            }
        }
    }

    // MARK: Eigenschaftstest

    /// 200 zufaellige Dokumente -> Loesung -> Datei -> zweites Geraet (eigener Ordner, eigene Kopie der PDF): jede
    /// Anmerkung byte-gleich (auch unbekannte Felder, Unicode, Grenzwerte, 10 000 Punkte), Bilder gleich, fehlende
    /// Bilder gezaehlt, keine PDF-Bytes, keine Wurzelfelder, kein `pkdrawing`, keine asset-Seiten.
    func testPropertyRoundTrip200RandomDocumentsOnSecondDevice() throws {
        continueAfterFailure = false                      // erstes Gegenbeispiel genuegt
        var rng = PaketSeedRNG(seed: 0x5EED_2026_1025)
        let receiver = SolutionLibrary(root: try tempDir().appendingPathComponent("geraet2", isDirectory: true))
        let transfer = try tempDir()
        let receiverPDFs = try tempDir()
        var totals = (pages: 0, objects: 0, long: 0, blank: 0, missing: 0, maxPDF: 0, bytes: 0)
        let createdAt = Date(timeIntervalSince1970: 1_793_000_000)

        for i in 0..<200 {
            let c = makeCase(i, rng: &rng, longStroke: i % 20 == 7)
            let fp = cipher.sha256Hex(c.pdf)
            let source = SolutionSource(document: c.doc, originalPDF: c.pdf, pdfPageCount: c.pdfDocument.pageCount,
                                        pageInfos: SolutionSharing.pageInfos(c.pdfDocument), fingerprint: fp, images: c.images,
                                        title: c.title)
            XCTAssertTrue(SolutionBuilder.pageProblems(c.doc, keys: c.expectedKeys).isEmpty, "Dokument \(i): Seitenprobleme")
            let id = rng.uuid()
            let content: SolutionContent
            do {
                content = try SolutionSharing.content(source, keys: SolutionBuilder.defaultSelection(c.doc), displayName: c.displayName,
                                                      solutionID: id, createdAt: createdAt)
            } catch {
                return XCTFail("Dokument \(i): Teilen gescheitert: \(error)")
            }
            let package = try SolutionPackage.seal(content, originalPDF: c.pdf, cipher: cipher, salt: rng.bytes(32), nonce: rng.bytes(12))
            let url = transfer.appendingPathComponent("loesung-\(i).uniflowsolution")
            try package.encoded().write(to: url)
            let fileBytes = try Data(contentsOf: url)
            XCTAssertEqual(try SolutionPackage.decode(fileBytes), package, "Dokument \(i)")
            totals.bytes += fileBytes.count

            // keine PDF-Bytes in Datei und Klartext
            let plain = content.json.serialized(sortedKeys: true)
            assertNoPDF(fileBytes, pdf: c.pdf, rng: &rng, cipherText: true, "Dokument \(i), Datei")
            assertNoPDF(plain, pdf: c.pdf, rng: &rng, cipherText: false, "Dokument \(i), Klartext")
            XCTAssertNil(plain.range(of: Data("pkdrawing".utf8)), "Dokument \(i)")

            // zweites Geraet
            let entry = try SolutionSharing.importFile(url, into: receiver, notify: false)
            XCTAssertEqual(entry.solutionID, id.uuidString.lowercased())
            XCTAssertEqual(entry.fingerprint, fp)
            let pdfURL = receiverPDFs.appendingPathComponent("\(i).pdf")
            try Data(c.pdf).write(to: pdfURL)
            let copy = try Data(contentsOf: pdfURL)
            let copyFP = cipher.sha256Hex(copy)
            XCTAssertEqual(receiver.entries(fingerprint: copyFP).map(\.solutionID), [entry.solutionID], "Dokument \(i): genau diese Loesung")
            let load = SolutionSharing.loadLayers(library: receiver, originalPDF: copy, fingerprint: copyFP,
                                                  pdf: PDFDocument(data: copy)!, cipher: cipher)
            XCTAssertEqual(load.problems.map(\.text), [], "Dokument \(i)")
            XCTAssertEqual(load.layers.count, 1, "Dokument \(i)")
            let layer = load.layers[0]
            XCTAssertEqual(layer.id, entry.solutionID)
            XCTAssertEqual(layer.displayName, content.displayName)
            XCTAssertEqual(layer.pages.map(\.key), c.expectedKeys, "Dokument \(i): Seitenauswahl")

            // jede Anmerkung exakt gleich: Werte (==) und Bytes der kanonischen Form (auch NFC/NFD und -0)
            for page in layer.pages {
                let own = c.doc.objects(page: page.key)
                XCTAssertEqual(page.objects, own, "Dokument \(i), Seite \(page.key)")
                XCTAssertEqual(JSONValue.array(page.objects).serialized(sortedKeys: true), JSONValue.array(own).serialized(sortedKeys: true),
                               "Dokument \(i), Seite \(page.key): byte-gleich")
                if let pdfIndex = page.pdfIndex {
                    let p = c.pdfDocument.page(at: pdfIndex - 1)!
                    let box = p.bounds(for: .cropBox).size
                    XCTAssertEqual(page.kind, .pdf)
                    XCTAssertEqual(page.width, Double(box.width), accuracy: 1e-9)
                    XCTAssertEqual(page.height, Double(box.height), accuracy: 1e-9)
                    let extra = c.doc.pageOrder.first { $0["key"]?.string == page.key }?["rotation"]?.int ?? 0
                    XCTAssertEqual(page.rotation, SolutionGeometry.normalized(p.rotation + extra), "Dokument \(i), Seite \(page.key)")
                } else {
                    XCTAssertEqual(page.kind, .blank)
                    totals.blank += 1
                    XCTAssertTrue(page.width > 0 && page.height > 0)
                    XCTAssertTrue(PageOrder.templates.contains(page.template ?? "blank"))
                }
                totals.objects += own.count
            }
            totals.pages += layer.pages.count
            // Bilder: vorhandene gleich, fehlende gezaehlt
            let opened = try receiver.package(entry.solutionID).open(originalPDF: copy, cipher: cipher)
            XCTAssertEqual(opened, content, "Dokument \(i)")
            XCTAssertEqual(opened.json.serialized(sortedKeys: true), plain, "Dokument \(i): Klartext byte-gleich")
            XCTAssertEqual(opened.missingImages, c.expectedMissing, "Dokument \(i)")
            for (src, img) in opened.images { XCTAssertEqual(img, c.images[src], "Dokument \(i), \(src)") }
            XCTAssertEqual(Set(layer.images.keys), Set(opened.images.keys))
            XCTAssertEqual(layer.missingImages, c.expectedMissing.count)
            totals.missing += c.expectedMissing.count
            totals.long += c.longStrokes
            totals.maxPDF = max(totals.maxPDF, c.pdfDocument.pageCount)
        }
        XCTAssertEqual(receiver.allEntries().count, 200)
        // der Seed deckt wirklich ab, was der Test verspricht
        XCTAssertEqual(totals.long, 10, "Striche mit 10 000 Punkten")
        XCTAssertGreaterThan(totals.blank, 10)
        XCTAssertGreaterThan(totals.missing, 10)
        XCTAssertGreaterThanOrEqual(totals.maxPDF, 38)
        XCTAssertGreaterThan(totals.objects, 1_000)
        print("Eigenschaftstest: \(totals.pages) Seiten, \(totals.objects) Objekte, \(totals.bytes) Byte Pakete")
    }

    // MARK: Hilfen fuer kleine Pakete

    private func smallPDF(_ marker: String = "Blatt") -> Data {
        var rng = PaketSeedRNG(seed: 42)
        return makePDF(pages: 3, marker: marker, rng: &rng)
    }

    private func smallDocument(_ text: String = "Lösung: x = 3 🙂") throws -> AnnotationDocument {
        AnnotationDocument(root: .object([
            "version": 2,
            "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2], ["key": "p3", "type": "pdf", "index": 3]],
            "pages": .object([
                "p1": ["objects": [["id": "s1", "type": "stroke", "points": [10, 10, 60, 60], "color": "#1d2130", "width": 2, "zukunft": [1, "x"]],
                                   ["id": "t1", "type": "text", "text": .string(text), "x": 40, "y": 70]]],
                "p2": ["objects": [["id": "r1", "type": "shape", "shape": "rect", "x": 5, "y": 6, "width": 70, "height": 30]]],
            ]),
        ]))
    }

    private func smallPackage(pdf: Data, doc: AnnotationDocument? = nil, name: String = "Lea", seed: UInt64 = 7) throws -> SolutionPackage {
        var rng = PaketSeedRNG(seed: seed)
        let d = try doc ?? smallDocument()
        let src = SolutionSource(document: d, originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                                 images: [:], title: "Blatt")
        let content = try SolutionSharing.content(src, keys: SolutionBuilder.defaultSelection(d), displayName: name,
                                                  solutionID: rng.uuid(), createdAt: Date(timeIntervalSince1970: 1_793_000_000))
        return try SolutionPackage.seal(content, originalPDF: pdf, cipher: cipher, salt: rng.bytes(32), nonce: rng.bytes(12))
    }

    // MARK: Falsche PDF

    /// Andere PDF mit nur einem anderen Byte am Ende (gleiche Seitenzahl, gleiche Groesse): Fingerabdruck passt
    /// nicht, nichts wird angezeigt; mit gefaelschtem Fingerabdruck scheitert AES-GCM; auch direkt mit den Bytes als
    /// Schluesselmaterial laesst sich nichts entschluesseln.
    func testWrongPDFOneByteAtEndDiffersNeitherDecryptsNorShows() async throws {
        let pdf = smallPDF()
        let package = try smallPackage(pdf: pdf)
        for replacement: UInt8 in [0x20, 0x0A ^ 0x01, 0x00, 0xFF] {
            var wrong = pdf
            if wrong[wrong.count - 1] == replacement { continue }
            wrong[wrong.count - 1] = replacement
            XCTAssertEqual(wrong.count, pdf.count, "gleiche Groesse")
            let wrongDoc = try XCTUnwrap(PDFDocument(data: wrong), "PDF bleibt lesbar")
            XCTAssertEqual(wrongDoc.pageCount, 3, "gleiche Seitenzahl")
            let wfp = cipher.sha256Hex(wrong)
            XCTAssertNotEqual(wfp, package.header.fingerprint)

            // 1) echtes Paket: gehoert nicht zu dieser PDF
            let lib = SolutionLibrary(root: try tempDir())
            try lib.importPackage(package.encoded())
            let load = SolutionSharing.loadLayers(library: lib, originalPDF: wrong, fingerprint: wfp, pdf: wrongDoc, cipher: cipher)
            XCTAssertTrue(load.layers.isEmpty)
            XCTAssertThrowsError(try package.open(originalPDF: wrong, cipher: cipher)) { XCTAssertEqual($0 as? SolutionError, .fingerprintMismatch) }
            // 2) direkt mit den falschen Bytes (Fingerabdruckpruefung umgangen): AES-GCM weist ab
            XCTAssertThrowsError(try cipher.open(package.ciphertext, keyMaterial: wrong, salt: package.header.salt,
                                                 info: SolutionPackage.keyInfo(solutionID: package.header.solutionID),
                                                 nonce: package.header.nonce, aad: package.authenticatedHeader))
            // 3) Fingerabdruck im Kopf auf die falsche PDF gefaelscht: wird nicht angezeigt, nur gemeldet
            var forged = try JSONValue.parse(package.encoded())
            forged["header"]?["document"]?["sha256"] = .string(wfp)
            let forgedLib = SolutionLibrary(root: try tempDir())
            try forgedLib.importPackage(forged.serialized(sortedKeys: true))
            let forgedLoad = SolutionSharing.loadLayers(library: forgedLib, originalPDF: wrong, fingerprint: wfp, pdf: wrongDoc, cipher: cipher)
            XCTAssertTrue(forgedLoad.layers.isEmpty, "nichts angezeigt, auch nicht teilweise")
            XCTAssertEqual(forgedLoad.problems.map(\.message), [SolutionError.decryptionFailed.description])
        }

        // 4) im offenen Dokument mit der falschen PDF: echtes Paket = andere PDF (bleibt gespeichert), gefaelschtes =
        //    sofort wieder entfernt
        var wrong = pdf
        wrong[wrong.count - 1] ^= 0x01
        let store = try await makeStore(pdf: wrong, pages: 3)
        let lib = SolutionLibrary(root: try tempDir())
        let dir = try tempDir()
        let realURL = dir.appendingPathComponent("echt.uniflowsolution")
        try package.encoded().write(to: realURL)
        guard case .otherPDF = try await store.importSolution(realURL, library: lib) else { return XCTFail("nicht als andere PDF erkannt") }
        let wfp = await store.originalFingerprint()
        var forged = try JSONValue.parse(package.encoded())
        forged["header"]?["document"]?["sha256"] = .string(try XCTUnwrap(wfp))
        let forgedURL = dir.appendingPathComponent("gefaelscht.uniflowsolution")
        try forged.serialized(sortedKeys: true).write(to: forgedURL)
        // gleiche Loesungs-ID wie das schon gespeicherte echte Paket, anderer Kopf: verdraengt es nicht
        do {
            _ = try await store.importSolution(forgedURL, library: lib)
            XCTFail("gefaelschtes Paket mit vorhandener Loesungs-ID angenommen")
        } catch {
            XCTAssertEqual(error as? SolutionError, .conflictingSolution)
        }
        let emptyLib = SolutionLibrary(root: try tempDir())
        guard case .removedUnreadable(_, let err) = try await store.importSolution(forgedURL, library: emptyLib) else {
            return XCTFail("gefaelschtes Paket nicht entfernt")
        }
        XCTAssertEqual(err, .decryptionFailed)
        XCTAssertTrue(emptyLib.allEntries().isEmpty)
        let shown = await store.solutionLayers(library: lib)
        XCTAssertTrue(shown.layers.isEmpty)
        XCTAssertTrue(shown.problems.isEmpty, "echtes Paket gehoert zur anderen PDF: keine Meldung hier")
        XCTAssertEqual(lib.allEntries().map(\.solutionID), [package.header.solutionID], "echtes Paket bleibt gespeichert")
        await store.close()
    }

    // MARK: Bit-Flip

    /// Jedes Bit jeder Byte-Position eines kleinen Pakets kippen: nie ein Absturz; jede Variante wird beim Lesen
    /// oder beim Oeffnen mit der PDF abgewiesen. Einzige Ausnahme: Varianten, die nach dem Lesen GENAU dasselbe
    /// Paket ergeben (z. B. ungenutzte Bits im letzten Base64-Zeichen) - dann ist auch der Inhalt unveraendert.
    /// Lesbare Varianten laufen zusaetzlich durch Import und Anzeige: keine Ebene mit veraendertem Inhalt.
    func testBitFlipAtEveryBytePositionIsRejectedCleanly() throws {
        let pdf = smallPDF()
        let package = try smallPackage(pdf: pdf)
        let original = package.encoded()
        let content = try package.open(originalPDF: pdf, cipher: cipher)
        XCTAssertLessThan(original.count, 3_000, "kleines Paket")
        var decodable = 0, identical = 0
        var accepted: [String] = []
        // Bereich des Chiffrats (Schluessel sortiert: "ciphertext" steht vorn); dort laeuft der Weg ueber Import und
        // Anzeige nur fuer jede achte lesbare Variante (Laufzeit), im Kopf fuer jede
        let head = try XCTUnwrap(original.range(of: Data("\"ciphertext\":\"".utf8)))
        let tail = try XCTUnwrap(original[head.upperBound...].firstIndex(of: 0x22))
        let cipherRange = head.upperBound..<tail
        let lib = SolutionLibrary(root: try tempDir())
        for pos in 0..<original.count {
            for bit in 0..<8 {
                var bytes = original
                bytes[pos] ^= UInt8(1 << bit)
                guard let decoded = try? SolutionPackage.decode(bytes) else { continue }
                decodable += 1
                if decoded == package {
                    identical += 1
                    XCTAssertEqual(try decoded.open(originalPDF: pdf, cipher: cipher), content)
                    continue
                }
                do {
                    _ = try decoded.open(originalPDF: pdf, cipher: cipher)
                    accepted.append("Byte \(pos), Bit \(bit)")
                } catch {
                    let e = error as? SolutionError
                    XCTAssertTrue(e == .decryptionFailed || e == .fingerprintMismatch, "Byte \(pos), Bit \(bit): \(error)")
                }
                // Import + Anzeige: entweder abgewiesen (gleiche ID, anderes Paket) oder nicht angezeigt
                if !cipherRange.contains(pos) || decodable % 8 == 0, let entry = try? lib.importPackage(bytes) {
                    let load = SolutionSharing.loadLayers(library: lib, originalPDF: pdf, fingerprint: cipher.sha256Hex(pdf),
                                                          pdf: PDFDocument(data: pdf)!, cipher: cipher)
                    XCTAssertTrue(load.layers.allSatisfy { $0.id != entry.solutionID || $0.pages == content.pages },
                                  "Byte \(pos), Bit \(bit): veraenderte Ebene angezeigt")
                    try lib.remove(entry.solutionID)
                }
            }
        }
        XCTAssertEqual(accepted, [], "veraenderte Pakete liessen sich oeffnen")
        XCTAssertGreaterThan(decodable, 0, "Kopffelder wie Name und Datum lassen sich lesen, scheitern aber beim Oeffnen")
        print("Bit-Flip: \(original.count * 8) Varianten, \(decodable) lesbar, \(identical) davon identisch")
    }

    // MARK: Abgeschnittene, leere und riesige Dateien

    func testTruncatedAndEmptyFilesAreRejectedAndStoreNothing() throws {
        let pdf = smallPDF()
        let package = try smallPackage(pdf: pdf)
        let original = package.encoded()
        for n in 0..<original.count {
            XCTAssertThrowsError(try SolutionPackage.decode(original.prefix(n)), "\(n) Byte")
        }
        // ueber den Dateiweg (Oeffnen in / Dateien-App): Stichproben, nichts gespeichert
        let lib = SolutionLibrary(root: try tempDir())
        let dir = try tempDir()
        for n in [0, 1, 2, 10, original.count / 2, original.count - 2, original.count - 1] {
            let url = dir.appendingPathComponent("teil-\(n).uniflowsolution")
            try original.prefix(n).write(to: url)
            XCTAssertThrowsError(try SolutionSharing.importFile(url, into: lib, notify: false), "\(n) Byte") {
                if n == 0 { XCTAssertEqual($0 as? SolutionError, .notASolution, "leere Datei") }
            }
        }
        XCTAssertTrue(lib.allEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.root.appendingPathComponent("received").path), "nichts abgelegt")
        // Chiffrat gekuerzt und Groesse im Kopf passend gemacht: lesbar, aber nicht zu oeffnen
        var short = try JSONValue.parse(original)
        let cut = package.ciphertext.dropLast(5)
        short["ciphertext"] = .string(Data(cut).base64EncodedString())
        short["header"]?["encryption"]?["plaintextBytes"] = .number(Double(cut.count - 16))
        let shortPackage = try SolutionPackage.decode(short.serialized(sortedKeys: true))
        XCTAssertThrowsError(try shortPackage.open(originalPDF: pdf, cipher: cipher)) { XCTAssertEqual($0 as? SolutionError, .decryptionFailed) }
        // nur das Tag (Klartext 0 Byte) und kuerzer als das Tag
        for keep in [16, 15, 0] {
            var t = try JSONValue.parse(original)
            t["ciphertext"] = .string(Data(package.ciphertext.prefix(keep)).base64EncodedString())
            t["header"]?["encryption"]?["plaintextBytes"] = .number(Double(keep - 16))
            XCTAssertThrowsError(try SolutionPackage.decode(t.serialized(sortedKeys: true)).open(originalPDF: pdf, cipher: cipher), "\(keep)")
        }
    }

    /// Datei ueber der Grenze (64 MB, duenn belegt, also ohne Plattenplatz): wird vor dem Lesen abgewiesen. Beweis,
    /// dass nicht gelesen wird: die Datei ist nicht lesbar (Rechte 000) - ein Leseversuch braeche mit einem
    /// Dateifehler ab, nicht mit "zu groß".
    func testHugeFileIsRejectedWithoutReadingIt() throws {
        let dir = try tempDir()
        let lib = SolutionLibrary(root: try tempDir())
        for size in [UInt64(SolutionLimits.maxPackageBytes) + 1, UInt64(SolutionLimits.maxPackageBytes) * 2, 5 << 30] {
            let url = dir.appendingPathComponent("riesig-\(size).uniflowsolution")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("{\"format\":\"uniflow-solution\"".utf8)))
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: size)
            try h.close()
            XCTAssertEqual((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize, Int(size))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            XCTAssertThrowsError(try Data(contentsOf: url), "Datei ist wirklich nicht lesbar")
            XCTAssertThrowsError(try SolutionSharing.importFile(url, into: lib, notify: false)) {
                XCTAssertEqual($0 as? SolutionError, .tooLarge, "\(size) Byte: vor dem Lesen abgewiesen")
            }
        }
        XCTAssertTrue(lib.allEntries().isEmpty)
        // genau an der Grenze lesbar, aber kein JSON: sauber abgewiesen
        let atLimit = dir.appendingPathComponent("grenze.uniflowsolution")
        XCTAssertTrue(FileManager.default.createFile(atPath: atLimit.path, contents: Data()))
        let h = try FileHandle(forWritingTo: atLimit)
        try h.truncate(atOffset: UInt64(SolutionLimits.maxPackageBytes))
        try h.close()
        XCTAssertThrowsError(try SolutionSharing.importFile(atLimit, into: lib, notify: false)) {
            XCTAssertEqual($0 as? SolutionError, .notASolution)
        }
        XCTAssertTrue(lib.allEntries().isEmpty)
    }

    // MARK: Doppelter Import

    /// Dieselbe Loesung zweimal (auch anders formatiert und ueber beide Wege): ein Eintrag, kanonische Datei,
    /// Sichtbarkeit bleibt, Anzeige einmal.
    func testDuplicateImportKeepsOneEntryAndVisibility() async throws {
        let pdf = smallPDF()
        let package = try smallPackage(pdf: pdf)
        let lib = SolutionLibrary(root: try tempDir())
        let dir = try tempDir()
        let url = dir.appendingPathComponent("Blatt – Lösung.uniflowsolution")
        try package.encoded().write(to: url)
        let first = try SolutionSharing.importFile(url, into: lib, notify: false)
        try lib.setVisible(first.solutionID, false)
        let second = try SolutionSharing.importFile(url, into: lib, notify: false)
        XCTAssertEqual(second.solutionID, first.solutionID)
        XCTAssertFalse(second.visible, "ausgeblendet bleibt ausgeblendet")
        // gleicher Inhalt, andere Schreibweise (Leerraum, Schluesselreihenfolge): gilt als dasselbe Paket
        let pretty = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: package.encoded()),
                                                options: [.prettyPrinted, .withoutEscapingSlashes])
        XCTAssertNotEqual(pretty, package.encoded())
        let prettyURL = dir.appendingPathComponent("hübsch.uniflowsolution")
        try pretty.write(to: prettyURL)
        XCTAssertNoThrow(try SolutionSharing.importFile(prettyURL, into: lib, notify: false))
        XCTAssertEqual(lib.allEntries().count, 1)
        let stored = try Data(contentsOf: lib.root.appendingPathComponent("received/\(first.solutionID).uniflowsolution"))
        XCTAssertEqual(stored, package.encoded(), "gespeichert wird die kanonische Form")

        // im offenen Dokument zweimal: beide Male angezeigt, ein Eintrag
        let store = try await makeStore(pdf: pdf, pages: 3)
        try lib.setVisible(first.solutionID, true)
        for _ in 0..<2 {
            guard case .shown = try await store.importSolution(url, library: lib) else { return XCTFail("nicht angezeigt") }
        }
        XCTAssertEqual(lib.allEntries().count, 1)
        let load = await store.solutionLayers(library: lib)
        XCTAssertEqual(load.layers.map(\.id), [first.solutionID])
        XCTAssertTrue(load.problems.isEmpty)
        await store.close()
    }

    // MARK: Zwei Personen, dieselbe PDF

    func testTwoPeopleSamePDFBothShownIndependently() async throws {
        let pdf = smallPDF()
        let lea = try smallPackage(pdf: pdf, doc: try smallDocument("Lea: Weg über Substitution"), name: "Lea", seed: 1)
        let ben = try smallPackage(pdf: pdf, doc: try smallDocument("בן: פתרון"), name: "", seed: 2)
        XCTAssertNotEqual(lea.header.solutionID, ben.header.solutionID)
        let store = try await makeStore(pdf: pdf, pages: 3)
        let before = await serialized(store)
        let lib = SolutionLibrary(root: try tempDir())
        try lib.importPackage(lea.encoded())
        try lib.importPackage(ben.encoded())
        let load = await store.solutionLayers(library: lib)
        XCTAssertTrue(load.problems.isEmpty, load.problems.map(\.text).joined())
        XCTAssertEqual(Set(load.layers.map(\.id)), [lea.header.solutionID, ben.header.solutionID])
        let leaLayer = try XCTUnwrap(load.layers.first { $0.id == lea.header.solutionID })
        let benLayer = try XCTUnwrap(load.layers.first { $0.id == ben.header.solutionID })
        XCTAssertEqual(leaLayer.byPDFIndex[1]?.objects.last?["text"], "Lea: Weg über Substitution")
        XCTAssertEqual(benLayer.byPDFIndex[1]?.objects.last?["text"], "בן: פתרון")
        XCTAssertTrue(benLayer.label.hasPrefix("Lösung von Anonym"))

        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        editor.foreignLayers = load.layers
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertEqual(Set(overlay.foreignLayerViews.map(\.solutionID)), [lea.header.solutionID, ben.header.solutionID])
        // eine ausblenden, eine entfernen: die andere bleibt unberuehrt
        try lib.setVisible(lea.header.solutionID, false)
        try lib.remove(ben.header.solutionID)
        let after = await store.solutionLayers(library: lib)
        XCTAssertEqual(after.layers.map(\.id), [lea.header.solutionID])
        XCTAssertEqual(after.layers.first?.visible, false)
        XCTAssertEqual(after.layers.first?.pages, leaLayer.pages)
        editor.foreignLayers = after.layers
        XCTAssertTrue(overlay.foreignLayerViews.isEmpty)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let unchanged = await serialized(store)
        XCTAssertEqual(before, unchanged, "eigenes Dokument byte-gleich")
        await store.close()
    }

    // MARK: Spaeter geoeffnete PDF

    /// Loesung zuerst empfangen (kein Dokument offen bzw. ein anderes Dokument offen), die PDF erst spaeter oeffnen
    /// (auch nach "Neustart" mit neuer Ablage-Instanz): erscheint dann vollstaendig.
    func testSolutionForPDFOpenedLaterAppearsThen() async throws {
        let pdf = smallPDF("Spaeter")
        let otherPDF = smallPDF("Gerade offen")
        let package = try smallPackage(pdf: pdf)
        let root = try tempDir()
        let dir = try tempDir()
        let url = dir.appendingPathComponent("spaeter.uniflowsolution")
        try package.encoded().write(to: url)
        // anderes Dokument ist offen: gespeichert, nicht angezeigt
        let otherStore = try await makeStore(pdf: otherPDF, pages: 3)
        guard case .otherPDF(let entry) = try await otherStore.importSolution(url, library: SolutionLibrary(root: root)) else {
            return XCTFail("nicht als andere PDF erkannt")
        }
        let otherLoad = await otherStore.solutionLayers(library: SolutionLibrary(root: root))
        XCTAssertTrue(otherLoad.layers.isEmpty && otherLoad.problems.isEmpty)
        await otherStore.close()

        // spaeter (neue Ablage-Instanz = App neu gestartet): die passende PDF oeffnen
        let store = try await makeStore(pdf: pdf, pages: 3)
        let load = await store.solutionLayers(library: SolutionLibrary(root: root))
        XCTAssertTrue(load.problems.isEmpty, load.problems.map(\.text).joined())
        XCTAssertEqual(load.layers.map(\.id), [entry.solutionID])
        let content = try package.open(originalPDF: pdf, cipher: cipher)
        XCTAssertEqual(load.layers.first?.pages, content.pages)
        XCTAssertEqual(load.layers.first?.byPDFIndex[1]?.objects, try smallDocument().objects(page: "p1"))
        await store.close()
    }

    // MARK: Import bei offenem Dokument

    /// Dokument ist offen und wird bearbeitet, waehrenddessen kommt eine Loesung (im Dokument und ueber "Öffnen in"):
    /// angezeigt, Benachrichtigung zum Neuladen, eigene Notizen unveraendert und weiter beschreibbar.
    func testImportWhileDocumentIsOpenAndBeingEdited() async throws {
        let pdf = smallPDF()
        let store = try await makeStore(pdf: pdf, pages: 3)
        await store.addText("eigene Notiz vorher", pageKey: "p1")
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let lib = SolutionLibrary(root: try tempDir())
        editor.foreignLayers = (await store.solutionLayers(library: lib)).layers
        XCTAssertTrue(try XCTUnwrap(editor.overlayForTesting(at: 0)).foreignLayerViews.isEmpty)
        let before = await serialized(store)

        let dir = try tempDir()
        let first = try smallPackage(pdf: pdf, name: "Lea", seed: 11)
        let url = dir.appendingPathComponent("lea.uniflowsolution")
        try first.encoded().write(to: url)
        // Import und eigene Bearbeitung gleichzeitig
        async let imported = store.importSolution(url, library: lib)
        async let edit: Void = store.addText("eigene Notiz waehrend Import", pageKey: "p2")
        let result = try await imported
        await edit
        guard case .shown = result else { return XCTFail("nicht angezeigt") }
        let during = await serialized(store)
        XCTAssertTrue(String(decoding: during, as: UTF8.self).contains("eigene Notiz waehrend Import"))
        XCTAssertFalse(String(decoding: during, as: UTF8.self).contains("Lösung: x = 3"), "nichts Fremdes im eigenen Dokument")
        var expectedDoc = try JSONValue.parse(before)
        let afterDoc = try JSONValue.parse(during)
        expectedDoc["pages"]?["p2"] = afterDoc["pages"]?["p2"]
        XCTAssertEqual(expectedDoc["pages"], afterDoc["pages"], "nur die eigene Aenderung auf Seite 2")

        // zweite Loesung ueber "Öffnen in" (wie AirDrop) bei offenem Dokument: Benachrichtigung zum Neuladen
        let second = try smallPackage(pdf: pdf, name: "Ben", seed: 12)
        let url2 = dir.appendingPathComponent("ben.uniflowsolution")
        try second.encoded().write(to: url2)
        let note = expectation(forNotification: .uniflowSolutionsChanged, object: nil)
        try SolutionSharing.importFile(url2, into: lib)
        await fulfillment(of: [note], timeout: 2)
        let load = await store.solutionLayers(library: lib)
        XCTAssertTrue(load.problems.isEmpty)
        XCTAssertEqual(Set(load.layers.map(\.id)), [first.header.solutionID, second.header.solutionID])
        editor.foreignLayers = load.layers
        XCTAssertEqual(try XCTUnwrap(editor.overlayForTesting(at: 0)).foreignLayerViews.count, 2)
        XCTAssertEqual(try XCTUnwrap(editor.overlayForTesting(at: 1)).foreignLayerViews.count, 2)
        // weiter beschreibbar
        await store.addText("eigene Notiz danach", pageKey: "p3")
        let final = await serialized(store)
        XCTAssertTrue(String(decoding: final, as: UTF8.self).contains("eigene Notiz danach"))
        XCTAssertFalse(String(decoding: final, as: UTF8.self).contains("Lösung: x = 3"))
        await store.close()
    }

    // MARK: Anzeige von Grenzwerten

    /// Loesung mit Grenzwerten in allen Zahlenfeldern (wie sie jeder mit derselben PDF bauen kann): Anzeige im
    /// Editor, eigene Schicht und Vorschau ohne Absturz.
    func testExtremeValuesDisplayWithoutCrash() throws {
        let pdf = smallPDF()
        var objects: [JSONValue] = []
        let extremes: [Double] = [0, -0.0, -1, 1e-300, 1e15, -1e15, 1e300, -1e300, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        for (n, v) in extremes.enumerated() {
            let common: [String: JSONValue] = ["x": .number(v), "y": .number(-v), "rotation": .number(v), "scaleX": .number(v), "scaleY": .number(v)]
            func with(_ o: [String: JSONValue]) -> JSONValue { .object(common.merging(o) { $1 }) }
            objects.append(with(["id": .string("s\(n)"), "type": "stroke", "width": .number(v), "opacity": .number(v),
                                 "points": .array([.number(v), .number(-v), .number(v), .number(v), 1, 2])]))
            objects.append(with(["id": .string("t\(n)"), "type": "text", "text": "Grenzwert 😀 שלום", "fontSize": .number(v),
                                 "width": .number(v), "lineHeight": .number(v), "bg": "#fff3a3"]))
            for shape in ["rect", "ellipse", "triangle", "polygon", "arrow", "line"] {
                objects.append(with(["id": .string("f\(n)\(shape)"), "type": "shape", "shape": .string(shape), "width": .number(v),
                                     "height": .number(v), "strokeWidth": .number(v), "stroke": "#d64545", "fill": "#ffd400",
                                     "points": .array([.number(v), 0, 0, .number(v), .number(-v), .number(v)])]))
            }
            objects.append(with(["id": .string("i\(n)"), "type": "image", "src": "/api/files/x/assets/bild.png",
                                 "width": .number(v), "height": .number(v)]))
        }
        let doc = AnnotationDocument(root: .object([
            "version": 2, "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "bG", "type": "blank", "template": "dotted", "w": 595, "h": 842]],
            "pages": ["p1": ["objects": .array(objects)], "bG": ["objects": .array(objects)]],
        ]))
        let src = SolutionSource(document: doc, originalPDF: pdf, pdfPageCount: 3, pageInfos: SolutionSharing.pageInfos(PDFDocument(data: pdf)!),
                                 fingerprint: cipher.sha256Hex(pdf),
                                 images: ["/api/files/x/assets/bild.png": SolutionImage(mime: "image/png", data: Self.tinyImages.png)],
                                 title: "Grenzwerte")
        let content = try SolutionSharing.content(src, keys: ["p1", "bG"], displayName: "")
        let layer = try SolutionSharing.layer(try SolutionSharing.package(content, originalPDF: pdf).open(originalPDF: pdf, cipher: cipher),
                                              visible: true, pdf: PDFDocument(data: pdf)!)
        let page = try XCTUnwrap(layer.byPDFIndex[1])
        XCTAssertEqual(page.objects, objects)
        for rotation in [0, 90, 180, 270] {
            let view = ForeignLayerView(solutionID: layer.id, page: page, images: layer.images, targetRotation: rotation, label: layer.label)
            view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            _ = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 80), format: format).image { ctx in
                ctx.cgContext.scaleBy(x: 0.1, y: 0.1)
                view.layer.render(in: ctx.cgContext)
            }
        }
        for p in content.pages {
            let img = SolutionPreview.image(p, images: layer.images, width: 120, scale: 1)
            XCTAssertEqual(img.size.width, 120)
        }
    }

    // MARK: Eigenes Dokument im lokalen Backend

    /// Eigenes Dokument im lokalen Backend (Temp-Ordner) mit der Test-PDF als Original-Datei.
    private func makeStore(pdf: Data, pages: Int) async throws -> DocumentStore {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "haerte-paket-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-10-25", has_notes: nil, page_count: pages, studip_folder: nil)
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
}
