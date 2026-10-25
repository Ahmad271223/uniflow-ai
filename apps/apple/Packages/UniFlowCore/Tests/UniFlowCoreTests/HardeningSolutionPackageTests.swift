import Foundation
import XCTest
@testable import UniFlowCore

// Haertetests fuer das Loesungspaket im Kern (Foundation-only, laeuft auch unter Linux): Bit-Flips an jeder
// Byte-Position, jede Kuerzung, zufaellige Strukturfehler, Rundlauf des Inhalts mit Unicode und Grenzwerten,
// Ablage (doppelter Import, zwei Personen, spaeter geoeffnete PDF, kaputte Ablage) und Groessengrenzen.
// Verschluesselung: `TestHMACCipher` aus SolutionPackageTests (nur Tests); die App-Tests nehmen AES-GCM.

/// SplitMix64 mit festem Seed (deterministisch).
private struct KernSeedRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
    mutating func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &self) }) }
    mutating func uuid() -> UUID {
        var b = [UInt8](bytes(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// NUR FUER TESTS: Chiffre ohne jeden Schutz (Klartext + 16 Nullbytes als "Tag"), ausschliesslich fuer die
/// Groessengrenzen, damit 48 MB Klartext in einer Sekunde statt in Minuten durchlaufen.
private struct SizeOnlyTestCipher: SolutionCipher {
    struct Failure: Error {}
    func seal(_ plaintext: Data, keyMaterial: Data, salt: Data, info: Data, nonce: Data, aad: Data) throws -> Data {
        plaintext + Data(count: 16)
    }
    func open(_ sealed: Data, keyMaterial: Data, salt: Data, info: Data, nonce: Data, aad: Data) throws -> Data {
        guard sealed.count >= 16, sealed.suffix(16).allSatisfy({ $0 == 0 }) else { throw Failure() }
        return sealed.dropLast(16)
    }
}

final class HardeningSolutionPackageTests: XCTestCase {
    let cipher = TestHMACCipher()
    let createdAt = Date(timeIntervalSince1970: 1_793_000_000)

    /// Erfundene "PDF-Bytes" (werden nie als PDF gelesen, nur gehasht und als Schluesselmaterial verwendet).
    func fakePDF(_ seed: UInt64, size: Int = 1_200) -> Data {
        var rng = KernSeedRNG(seed: seed)
        return Data("%PDF-1.7\n".utf8) + rng.bytes(size) + Data("\n%%EOF\n".utf8)
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-haerte-kern-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func pdfInfo(_ i: Int) -> SolutionBuilder.PDFPageInfo? {
        (1...3).contains(i) ? .init(width: 595, height: 842, rotation: i == 3 ? 90 : 0) : nil
    }

    func smallDocument(_ text: String = "Lösung: x = 3 🙂 שלום") -> AnnotationDocument {
        AnnotationDocument(root: .object([
            "version": 2, "note": "privat",
            "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2]],
            "pages": .object([
                "p1": ["objects": [["id": "s1", "type": "stroke", "points": [10, 10, 60, 60], "width": 2, "zukunft": [1, "x", ["a": .null]]],
                                   ["id": "t1", "type": "text", "text": .string(text), "x": 40, "y": 70]]],
                "p2": ["objects": [["id": "r1", "type": "shape", "shape": "rect", "x": 5, "y": 6, "width": 70, "height": 30]]],
            ]),
        ]))
    }

    func package(pdf: Data, doc: AnnotationDocument? = nil, name: String = "Lea", seed: UInt64 = 1,
                 cipher c: SolutionCipher? = nil) throws -> SolutionPackage {
        var rng = KernSeedRNG(seed: seed)
        let d = doc ?? smallDocument()
        let content = try SolutionBuilder.build(document: d, selectedKeys: SolutionBuilder.defaultSelection(d), pdfPageCount: 3,
                                                pdfPage: pdfInfo, images: [:], fingerprint: SolutionSHA256.hex(pdf), title: "Blatt",
                                                displayName: name, solutionID: rng.uuid(), createdAt: createdAt)
        return try SolutionPackage.seal(content, originalPDF: pdf, cipher: c ?? cipher, salt: rng.bytes(32), nonce: rng.bytes(12))
    }

    // MARK: Bit-Flips

    /// An jeder Byte-Position drei Bits (0, 5, 7: Ziffer/Buchstabe, Gross/Klein, ungueltiges UTF-8) kippen: nie ein
    /// Absturz; was sich lesen laesst, scheitert beim Oeffnen mit der PDF - ausser es ergibt GENAU dasselbe Paket.
    /// Lesbare Varianten im Kopf laufen ausserdem durch die Ablage: abgelegt wird nur die kanonische Form.
    func testBitFlipsAtEveryBytePositionAreRejectedOrIdentical() throws {
        let pdf = fakePDF(1)
        let package = try package(pdf: pdf)
        let original = package.encoded()
        let content = try package.open(originalPDF: pdf, cipher: cipher)
        var decodable = 0, identical = 0
        var opened: [String] = []
        let head = try XCTUnwrap(original.range(of: Data("\"ciphertext\":\"".utf8)))
        let tail = try XCTUnwrap(original[head.upperBound...].firstIndex(of: 0x22))
        let lib = SolutionLibrary(root: try tempDir())
        for pos in 0..<original.count {
            for bit in [0, 5, 7] {
                var bytes = original
                bytes[pos] ^= UInt8(1 << bit)
                guard let decoded = try? SolutionPackage.decode(bytes) else { continue }
                decodable += 1
                if decoded == package {
                    identical += 1
                    XCTAssertEqual(try decoded.open(originalPDF: pdf, cipher: cipher), content)
                    continue
                }
                if let c = try? decoded.open(originalPDF: pdf, cipher: cipher) {
                    opened.append("Byte \(pos), Bit \(bit)\(c == content ? " (gleicher Inhalt)" : "")")
                }
                if !(head.upperBound..<tail).contains(pos) {
                    // Kopf: Import legt nur die gepruefte Form ab, eine ID nie doppelt
                    if let e = try? lib.importPackage(bytes) {
                        let stored = try Data(contentsOf: lib.root.appendingPathComponent("received/\(SolutionLibrary.fileName(e.solutionID))"))
                        XCTAssertEqual(stored, decoded.encoded())
                        XCTAssertThrowsError(try lib.package(e.solutionID).open(originalPDF: pdf, cipher: cipher))
                        try lib.remove(e.solutionID)
                    }
                }
            }
        }
        XCTAssertEqual(opened, [], "veraenderte Pakete liessen sich oeffnen")
        XCTAssertGreaterThan(decodable, 100)
        XCTAssertTrue(lib.allEntries().isEmpty)
        print("Bit-Flip (Kern): \(original.count * 3) Varianten, \(decodable) lesbar, \(identical) identisch")
    }

    // MARK: Kuerzungen und Anhaenge

    func testEveryTruncationAndTrailingGarbageIsRejected() throws {
        let pdf = fakePDF(2)
        let original = try package(pdf: pdf).encoded()
        for n in 0..<original.count {
            XCTAssertThrowsError(try SolutionPackage.decode(original.prefix(n)), "\(n) Byte")
            // auch ohne das erste Byte (Anfang abgeschnitten)
            if n > 0 { XCTAssertThrowsError(try SolutionPackage.decode(original.suffix(n)), "ohne die ersten \(original.count - n) Byte") }
        }
        for junk in ["x", "{}", "\u{0}", "\"", "]", ",", "\u{FEFF}"] {
            XCTAssertThrowsError(try SolutionPackage.decode(original + Data(junk.utf8)), "Anhang \(junk.debugDescription)")
        }
        XCTAssertThrowsError(try SolutionPackage.decode(Data([0xEF, 0xBB, 0xBF]) + original), "BOM davor")
        XCTAssertThrowsError(try SolutionPackage.decode(Data())) { XCTAssertEqual($0 as? SolutionError, .notASolution) }
        XCTAssertThrowsError(try SolutionPackage.decode(Data(" \n\t".utf8))) { XCTAssertEqual($0 as? SolutionError, .notASolution) }
        // Leerraum am Ende aendert nichts am Paket
        XCTAssertEqual(try SolutionPackage.decode(original + Data(" \n".utf8)), try SolutionPackage.decode(original))
        let lib = SolutionLibrary(root: try tempDir())
        XCTAssertThrowsError(try lib.importPackage(Data())) { XCTAssertEqual($0 as? SolutionError, .notASolution) }
        XCTAssertThrowsError(try lib.importPackage(original.prefix(original.count / 2)))
        XCTAssertTrue(lib.allEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.root.appendingPathComponent("received").path))
    }

    // MARK: Zufaellige Strukturfehler

    /// 3 000 zufaellige Veraenderungen (Bytes ersetzen, loeschen, verdoppeln, Zahlen und Werte einsetzen, tiefe
    /// Verschachtelung) mit festem Seed: nie ein Absturz, nie ein veraenderter Inhalt.
    func testRandomStructuralMutationsNeverCrashOrOpen() throws {
        let pdf = fakePDF(3)
        let package = try package(pdf: pdf)
        let original = [UInt8](package.encoded())
        let content = try package.open(originalPDF: pdf, cipher: cipher)
        var rng = KernSeedRNG(seed: 0xC0FF_EE20_2610)
        let tokens = ["1e999", "-1e999", "1e300", "-0", "0", "-1", "1.5", "9223372036854775807", "1e18", "null", "true", "[]", "{}",
                      "\"\"", "\"\\ud800\"", "\"\\u0000\"", String(repeating: "[", count: 600), "\"%PDF-1.7\"", "\"JVBERi0xLjc=\""]
        var rejected = 0
        for _ in 0..<3_000 {
            var b = original
            switch rng.int(0...4) {
            case 0: b[rng.int(0...(b.count - 1))] = UInt8(rng.int(0...255))
            case 1:
                let s = rng.int(0...(b.count - 1)), e = min(b.count, s + rng.int(1...40))
                b.removeSubrange(s..<e)
            case 2:
                let s = rng.int(0...(b.count - 1)), e = min(b.count, s + rng.int(1...40))
                b.insert(contentsOf: b[s..<e], at: rng.int(0...b.count))
            case 3:
                // eine Zahl oder einen Wert hinter einem Doppelpunkt ersetzen
                let colons = b.indices.filter { b[$0] == 0x3A }
                let c = rng.pick(colons) + 1
                var end = c
                while end < b.count, ![0x2C, 0x7D, 0x5D].contains(b[end]) { end += 1 }
                b.replaceSubrange(c..<end, with: Array(rng.pick(tokens).utf8))
            default:
                b.insert(contentsOf: Array(rng.pick(tokens).utf8), at: rng.int(0...b.count))
            }
            guard let decoded = try? SolutionPackage.decode(Data(b)) else { rejected += 1; continue }
            if decoded == package { continue }
            if let c = try? decoded.open(originalPDF: pdf, cipher: cipher) {
                XCTAssertEqual(c, content, "veraendertes Paket mit anderem Inhalt geoeffnet")
                XCTFail("veraendertes Paket geoeffnet")
            }
        }
        XCTAssertGreaterThan(rejected, 1_000)
    }

    // MARK: Rundlauf des Inhalts

    /// 300 zufaellige Inhalte (Unicode, Emoji, RTL, NUL, Grenzwerte, unbekannte Felder, lange Striche): Schreiben und
    /// Lesen ergeben denselben Inhalt, byte-gleich; jeder 25. zusaetzlich verschluesselt und auf einem zweiten
    /// "Geraet" (eigene Ablage) geoeffnet.
    func testContentRoundTripPropertyUnicodeAndExtremes() throws {
        var rng = KernSeedRNG(seed: 0x5EED_0300)
        let pieces = ["a", "Z", " ", "ä", "ß", "😀", "👩‍👩‍👧‍👦", "🇩🇪", "שלום", "مرحبا", "\u{200F}", "\u{202E}", "e\u{301}", "\u{0}", "\n",
                      "\r\n", "\"", "\\", "/", "\u{2028}", "\u{FEFF}", "\u{FFFF}", "\u{10FFFF}", "\u{1F}", "{", "]"]
        let numbers: [Double] = [0, -0.0, 1, -1, 0.1 + 0.2, 1e-300, 5e-324, 1e15, 1e15 - 1, 999_999_999_999_999.9, 9_007_199_254_740_993,
                                 1e300, -.greatestFiniteMagnitude, .greatestFiniteMagnitude, 123.456_789_012_345_6]
        func text() -> String { (0..<rng.int(0...15)).map { _ in rng.pick(pieces) }.joined() }
        func num() -> JSONValue { rng.int(0...2) == 0 ? .number(rng.pick(numbers)) : .number(Double.random(in: -1e6...1e6, using: &rng)) }
        func value(_ depth: Int) -> JSONValue {
            switch rng.int(0...(depth > 2 ? 3 : 5)) {
            case 0: return .null
            case 1: return .bool(rng.int(0...1) == 1)
            case 2: return num()
            case 3: return .string(text())
            case 4: return .array((0..<rng.int(0...3)).map { _ in value(depth + 1) })
            default:
                var o: [String: JSONValue] = [:]
                for k in 0..<rng.int(0...3) { o[rng.pick(["z", "ü", "😀", "מ", "\u{0}"]) + "\(k)"] = value(depth + 1) }
                return .object(o)
            }
        }
        let second = SolutionLibrary(root: try tempDir())
        for i in 0..<300 {
            let pdfPages = rng.int(1...40)
            var order: [JSONValue] = []
            var pages: [String: JSONValue] = [:]
            for p in 1...pdfPages where rng.int(0...2) == 0 || p == 1 {
                order.append(["key": .string("p\(p)"), "type": "pdf", "index": .number(Double(p))])
                var objects: [JSONValue] = []
                for n in 0..<rng.int(1...4) {
                    var o: [String: JSONValue] = ["id": .string("o\(p)-\(n)"), "type": .string(rng.pick(["stroke", "text", "shape", "image"])),
                                                  "x": num(), "y": num(), "text": .string(text())]
                    let long = i % 30 == 0 && n == 0 && p == 1
                    o["points"] = .array((0..<(long ? 20_000 : rng.int(0...20))).map { _ in num() })
                    for k in 0..<rng.int(0...3) { o["unbekannt\(k)"] = value(0) }
                    objects.append(.object(o))
                }
                pages["p\(p)"] = ["objects": .array(objects)]
            }
            let doc = AnnotationDocument(root: .object(["version": 2, "pageOrder": .array(order), "pages": .object(pages)]))
            let pdf = fakePDF(UInt64(1000 + i), size: 64)
            let content = try SolutionBuilder.build(
                document: doc, selectedKeys: SolutionBuilder.defaultSelection(doc), pdfPageCount: pdfPages,
                pdfPage: { _ in .init(width: 595, height: 842, rotation: 0) }, images: [:], fingerprint: SolutionSHA256.hex(pdf),
                title: text(), displayName: text(), solutionID: rng.uuid(), createdAt: createdAt)
            let plain = content.json.serialized(sortedKeys: true)
            let back = try SolutionContent(json: try JSONValue.parse(plain))
            XCTAssertEqual(back, content, "Inhalt \(i)")
            XCTAssertEqual(back.json.serialized(sortedKeys: true), plain, "Inhalt \(i): byte-gleich")
            for p in back.pages {
                XCTAssertEqual(JSONValue.array(p.objects).serialized(sortedKeys: true), JSONValue.array(doc.objects(page: p.key)).serialized(sortedKeys: true),
                               "Inhalt \(i), Seite \(p.key)")
            }
            if i % 25 == 0 {
                let sealed = try SolutionPackage.seal(content, originalPDF: pdf, cipher: cipher, salt: rng.bytes(32), nonce: rng.bytes(12))
                try second.importPackage(sealed.encoded())
                XCTAssertEqual(try second.package(sealed.header.solutionID).open(originalPDF: Data(pdf), cipher: cipher), content, "Inhalt \(i)")
            }
        }
        XCTAssertEqual(second.allEntries().count, 12)
    }

    // MARK: Ablage

    /// Doppelter Import, andere Schreibweise, zwei Personen fuer dieselbe PDF, gleiche ID mit anderem Inhalt, eine
    /// Loesung fuer eine erst spaeter geoeffnete PDF (neue Ablage-Instanz = Neustart), kaputte Datei und kaputter
    /// Index.
    func testLibraryDuplicatesTwoPeopleLaterOpenAndBrokenStorage() throws {
        let pdf = fakePDF(10), later = fakePDF(11)
        let fp = SolutionSHA256.hex(pdf), laterFP = SolutionSHA256.hex(later)
        let lea = try package(pdf: pdf, doc: smallDocument("Lea"), name: "Lea", seed: 21)
        let ben = try package(pdf: pdf, doc: smallDocument("Ben"), name: "", seed: 22)
        let mia = try package(pdf: later, doc: smallDocument("Mia"), name: "Mia", seed: 23)
        let root = try tempDir()
        let lib = SolutionLibrary(root: root)
        let t0 = Date(timeIntervalSince1970: 1_793_000_100)

        // doppelt, auch mit zusaetzlichem Leerraum (andere Bytes, gleiches Paket)
        try lib.importPackage(lea.encoded(), now: t0)
        try lib.setVisible(lea.header.solutionID, false)
        let again = try lib.importPackage(lea.encoded(), now: t0.addingTimeInterval(60))
        XCTAssertFalse(again.visible)
        var reordered = String(decoding: lea.encoded(), as: UTF8.self)
        reordered = "  \n" + reordered.replacingOccurrences(of: ",", with: " ,\n ") + "\n"
        XCTAssertNoThrow(try lib.importPackage(Data(reordered.utf8)))
        XCTAssertEqual(lib.entries(fingerprint: fp).map(\.solutionID), [lea.header.solutionID])

        // zweite Person, dieselbe PDF
        try lib.importPackage(ben.encoded(), now: t0.addingTimeInterval(120))
        XCTAssertEqual(lib.entries(fingerprint: fp).map(\.solutionID), [lea.header.solutionID, ben.header.solutionID])
        XCTAssertEqual(try lib.package(lea.header.solutionID).open(originalPDF: pdf, cipher: cipher).pages[0].objects[1]["text"], "Lea")
        XCTAssertEqual(try lib.package(ben.header.solutionID).open(originalPDF: pdf, cipher: cipher).pages[0].objects[1]["text"], "Ben")

        // gleiche ID, anderer Inhalt (z. B. absichtlich nachgebaut): vorhandene bleibt
        var rng = KernSeedRNG(seed: 21)
        let sameID = rng.uuid()
        let impostorContent = try SolutionBuilder.build(document: smallDocument("Mallory"), selectedKeys: ["p1"], pdfPageCount: 3, pdfPage: pdfInfo,
                                                        images: [:], fingerprint: fp, title: "", displayName: "Lea", solutionID: sameID,
                                                        createdAt: createdAt)
        let impostor = try SolutionPackage.seal(impostorContent, originalPDF: pdf, cipher: cipher)
        XCTAssertEqual(impostor.header.solutionID, lea.header.solutionID)
        XCTAssertThrowsError(try lib.importPackage(impostor.encoded())) { XCTAssertEqual($0 as? SolutionError, .conflictingSolution) }
        XCTAssertEqual(try lib.package(lea.header.solutionID), lea)

        // Loesung fuer eine PDF, die erst spaeter geoeffnet wird; danach "Neustart" mit neuer Instanz
        try lib.importPackage(mia.encoded(), now: t0.addingTimeInterval(180))
        let restarted = SolutionLibrary(root: root)
        XCTAssertEqual(restarted.entries(fingerprint: laterFP).map(\.displayName), ["Mia"])
        XCTAssertEqual(try restarted.package(mia.header.solutionID).open(originalPDF: later, cipher: cipher).pages[0].objects[1]["text"], "Mia")
        XCTAssertFalse(restarted.entries(fingerprint: fp).first { $0.solutionID == lea.header.solutionID }?.visible ?? true)

        // eine entfernen: die andere bleibt unberuehrt
        try restarted.remove(ben.header.solutionID)
        XCTAssertEqual(restarted.entries(fingerprint: fp).map(\.solutionID), [lea.header.solutionID])
        XCTAssertEqual(try restarted.package(lea.header.solutionID), lea)

        // kaputte gespeicherte Datei: erneuter Import ersetzt sie
        let leaFile = root.appendingPathComponent("received/\(SolutionLibrary.fileName(lea.header.solutionID))")
        try Data("kaputt".utf8).write(to: leaFile)
        XCTAssertThrowsError(try restarted.package(lea.header.solutionID))
        XCTAssertNoThrow(try restarted.importPackage(lea.encoded()))
        XCTAssertEqual(try restarted.package(lea.header.solutionID), lea)

        // kaputter Index: kein Absturz, Import danach wieder moeglich
        try Data("{\"byFingerprint\":[1,2".utf8).write(to: root.appendingPathComponent("index.json"))
        XCTAssertTrue(restarted.allEntries().isEmpty)
        XCTAssertNoThrow(try restarted.importPackage(mia.encoded()))
        XCTAssertEqual(restarted.entries(fingerprint: laterFP).count, 1)
    }

    // MARK: Groessengrenzen

    func testOversizeInputIsRejectedBeforeParsing() throws {
        let big = Data(count: SolutionLimits.maxPackageBytes + 1)
        XCTAssertThrowsError(try SolutionPackage.decode(big)) { XCTAssertEqual($0 as? SolutionError, .tooLarge) }
        let lib = SolutionLibrary(root: try tempDir())
        XCTAssertThrowsError(try lib.importPackage(big)) { XCTAssertEqual($0 as? SolutionError, .tooLarge) }
        XCTAssertTrue(lib.allEntries().isEmpty)
        // an der Grenze: gelesen, aber kein JSON
        XCTAssertThrowsError(try SolutionPackage.decode(Data(count: SolutionLimits.maxPackageBytes))) {
            XCTAssertEqual($0 as? SolutionError, .notASolution)
        }
    }

    /// Was der Absender erfolgreich versiegelt, muss der Empfaenger auch importieren koennen: Inhalt genau an der
    /// Klartextgrenze (48 MB). Base64 macht daraus mehr als 64 MB Datei - die Datei-Grenze beim Empfaenger.
    /// Erwartung: entweder lehnt schon `seal` mit `tooLarge` ab (der Absender erfaehrt es) oder `decode` nimmt die
    /// Datei an.
    func testSealedPackageAtPlaintextLimitIsImportable() throws {
        let pdf = fakePDF(30, size: 64)
        func content(_ text: String) -> SolutionContent {
            SolutionContent(solutionID: "6f1c1c0e-6a63-4c38-9a0b-6c0f0f7b9a11", createdAt: SolutionPackage.timestamp(createdAt), title: "Gross",
                            displayName: "", fingerprint: SolutionSHA256.hex(pdf), pdfPageCount: 1,
                            pages: [SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0,
                                                 objects: [.object(["id": "t1", "type": "text", "text": .string(text)])])])
        }
        let base = content("").json.serialized(sortedKeys: true).count
        let text = String(repeating: "a", count: SolutionLimits.maxPlaintextBytes - base)
        let full = content(text)
        let cipher = SizeOnlyTestCipher()
        let sealed: SolutionPackage
        do {
            sealed = try SolutionPackage.seal(full, originalPDF: pdf, cipher: cipher)
        } catch SolutionError.tooLarge {
            return                                       // Absender wird informiert: in Ordnung
        }
        XCTAssertEqual(sealed.header.plaintextBytes, SolutionLimits.maxPlaintextBytes)
        let file = sealed.encoded()
        XCTAssertLessThanOrEqual(file.count, SolutionLimits.maxPackageBytes,
                                 "versiegeltes Paket ist \(file.count) Byte, Empfaenger nimmt hoechstens \(SolutionLimits.maxPackageBytes)")
        XCTAssertNoThrow(try SolutionPackage.decode(file), "Absender meldet Erfolg, Empfaenger weist die Datei ab")
    }
}
