import Foundation
import XCTest
@testable import UniFlowCore

/// NUR FUER TESTS: authentifizierte Verschluesselung aus HMAC-SHA256 (Schluesselstrom + Tag), damit Format, AAD und
/// Pruefungen auch unter Linux ohne CryptoKit getestet werden. Die App verwendet AES-256-GCM (CryptoKit), siehe
/// UniFlowTests/SolutionSharingTests.swift.
struct TestHMACCipher: SolutionCipher {
    struct Failure: Error {}

    static func hmac(_ key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? SolutionSHA256.hash(Data(key)) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let inner = SolutionSHA256.hash(Data(k.map { $0 ^ 0x36 } + message))
        return SolutionSHA256.hash(Data(k.map { $0 ^ 0x5c } + inner))
    }

    /// HKDF-SHA256 (RFC 5869) fuer 64 Byte: Verschluesselungs- und MAC-Schluessel.
    static func hkdf(_ ikm: Data, salt: Data, info: Data) -> [UInt8] {
        let prk = hmac([UInt8](salt), [UInt8](ikm))
        var t: [UInt8] = [], okm: [UInt8] = []
        for i in 1...2 {
            t = hmac(prk, t + [UInt8](info) + [UInt8(i)])
            okm += t
        }
        return okm
    }

    private func stream(_ key: [UInt8], nonce: Data, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        var counter: UInt32 = 0
        while out.count < count {
            out += Self.hmac(key, [UInt8](nonce) + withUnsafeBytes(of: counter.bigEndian) { Array($0) })
            counter += 1
        }
        return Array(out.prefix(count))
    }

    private func tag(_ key: [UInt8], aad: Data, ct: [UInt8]) -> [UInt8] {
        let len = withUnsafeBytes(of: UInt64(aad.count).bigEndian) { Array($0) }
        return Array(Self.hmac(key, len + [UInt8](aad) + ct).prefix(16))
    }

    func seal(_ plaintext: Data, keyMaterial: Data, salt: Data, info: Data, nonce: Data, aad: Data) throws -> Data {
        let keys = Self.hkdf(keyMaterial, salt: salt, info: info)
        let ks = stream(Array(keys[0..<32]), nonce: nonce, count: plaintext.count)
        let ct = zip([UInt8](plaintext), ks).map { $0 ^ $1 }
        return Data(ct + tag(Array(keys[32..<64]), aad: aad, ct: ct))
    }

    func open(_ sealed: Data, keyMaterial: Data, salt: Data, info: Data, nonce: Data, aad: Data) throws -> Data {
        guard sealed.count >= 16 else { throw Failure() }
        let keys = Self.hkdf(keyMaterial, salt: salt, info: info)
        let ct = [UInt8](sealed.dropLast(16))
        guard tag(Array(keys[32..<64]), aad: aad, ct: ct) == [UInt8](sealed.suffix(16)) else { throw Failure() }
        let ks = stream(Array(keys[0..<32]), nonce: nonce, count: ct.count)
        return Data(zip(ct, ks).map { $0 ^ $1 })
    }
}

/// Loesungspaket: nur eigene Notizen, Zuordnung ueber Fingerabdruck und PDF-Seite, Verschluesselung an die
/// Original-PDF gebunden, manipulierte Pakete werden abgewiesen.
final class SolutionPackageTests: XCTestCase {
    let cipher = TestHMACCipher()

    /// Erfundene "PDF-Bytes" (nur fuer den Kern: der Inhalt wird nie als PDF gelesen, nur gehasht und als
    /// Schluesselmaterial verwendet). Die App-Tests nehmen eine selbst erzeugte echte PDF.
    func fakePDF(_ seed: UInt8 = 1, size: Int = 6000) -> Data {
        var bytes = Array("%PDF-1.7\n%Testdatei UniFlow\n".utf8)
        var x = UInt32(seed) &* 2654435761
        while bytes.count < size {
            x = x &* 1103515245 &+ 12345
            bytes.append(UInt8(truncatingIfNeeded: x >> 16))
        }
        return Data(bytes + Array("\n%%EOF\n".utf8))
    }

    /// Erfundene Notizen: zwei PDF-Seiten (eine davon gedreht), eingefuegte Leerseite, Bild-Seite aus dem Browser,
    /// Objekte mit unbekannten Feldern und nativer Zeichnung.
    func makeDocument() throws -> AnnotationDocument {
        AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"zoom":1.4,"note":"privat","bookmarks":[{"key":"p1","title":"Start"}],
         "pageOrder":[
          {"key":"p1","type":"pdf","index":1},
          {"key":"bQ1","type":"blank","template":"grid","w":420,"h":595},
          {"key":"p2","type":"pdf","index":2,"rotation":90},
          {"key":"p3","type":"pdf","index":3},
          {"key":"aX","type":"asset","src":"/api/assets/a1"}],
         "pages":{
          "p1":{"objects":[
             {"id":"s1","type":"stroke","tool":"pen","color":"#1d2130","width":2.5,"opacity":1,
              "points":[10,10,50.25,60.5,90,20],"widths":[1,2,3],"x":0,"y":0,"rotation":0,"scaleX":1,"scaleY":1,
              "pkInk":"com.apple.ink.monoline","zukunftsFeld":{"tief":[1,2,{"x":true}]}},
             {"id":"t1","type":"text","text":"Lösung: x = 3","x":40,"y":70,"fontSize":14,"fill":"#1d2130","bg":"#fff3a3",
              "width":220,"rotation":0,"scaleX":1,"scaleY":1,"unbekannt":null},
             {"id":"i1","type":"image","src":"/api/files/f1/assets/bild.png","x":100,"y":200,"width":50,"height":40}],
           "pkdrawing":{"data":"QUJD","objectsSig":"x","format":"pkdrawing-v1","strokeIds":[["s1"]]}},
          "bQ1":{"objects":[{"id":"r1","type":"shape","shape":"rect","x":5,"y":6,"width":70,"height":30,
                             "stroke":"#d64545","strokeWidth":2,"rotation":15,"scaleX":1.5,"scaleY":1}]},
          "p2":{"objects":[{"id":"s2","type":"stroke","tool":"marker","color":"#ffd400","width":12,"opacity":0.4,
                            "points":[0,0,100,0],"x":30,"y":40,"rotation":0,"scaleX":1,"scaleY":1}]},
          "p3":{"objects":[]},
          "aX":{"objects":[{"id":"s9","type":"stroke","points":[0,0,1,1]}]}
         }}
        """#))
    }

    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    func pdfInfo(_ i: Int) -> SolutionBuilder.PDFPageInfo? {
        switch i {
        case 1: return .init(width: 595, height: 842, rotation: 0)
        case 2: return .init(width: 842, height: 595, rotation: 0)     // Querformat
        case 3: return .init(width: 612, height: 792, rotation: 90)    // eigene /Rotate der PDF
        default: return nil
        }
    }

    func build(_ doc: AnnotationDocument, keys: [String]? = nil, pdf: Data, images: [String: SolutionImage]? = nil,
               name: String = "Mia") throws -> SolutionContent {
        try SolutionBuilder.build(document: doc, selectedKeys: keys ?? SolutionBuilder.defaultSelection(doc), pdfPageCount: 3,
                                  pdfPage: pdfInfo, images: images ?? ["/api/files/f1/assets/bild.png": SolutionImage(mime: "image/png", data: pngBytes)],
                                  fingerprint: cipher.sha256Hex(pdf), title: "Übungsblatt 3", displayName: name,
                                  createdAt: Date(timeIntervalSince1970: 1_793_000_000))
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-solution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: SHA-256

    func testSHA256KnownVectors() {
        XCTAssertEqual(SolutionSHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SolutionSHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SolutionSHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SolutionSHA256.hex(Data(repeating: 0x61, count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        // HMAC-SHA256 (RFC 4231, Fall 2), Grundlage der Test-Verschluesselung
        XCTAssertEqual(SolutionSHA256.hexString(TestHMACCipher.hmac(Array("Jefe".utf8), Array("what do ya want for nothing?".utf8))),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    // MARK: Inhalt

    func testBuildKeepsOwnObjectsExactlyAndNothingElse() throws {
        let doc = try makeDocument()
        let pdf = fakePDF()
        XCTAssertEqual(SolutionBuilder.defaultSelection(doc), ["p1", "bQ1", "p2"], "Seiten mit eigenen Notizen, ohne Bild-Seite")
        let content = try build(doc, pdf: pdf)
        XCTAssertEqual(content.pages.map(\.key), ["p1", "bQ1", "p2"])
        for page in content.pages {
            XCTAssertEqual(page.objects, doc.objects(page: page.key), "Objekte 1:1 inklusive unbekannter Felder: \(page.key)")
        }
        XCTAssertEqual(content.pages[0].objects[0]["zukunftsFeld"], try JSONValue.parse(#"{"tief":[1,2,{"x":true}]}"#))
        XCTAssertEqual(content.pages[0].objects[1]["unbekannt"], .null)
        XCTAssertEqual(content.fingerprint, SolutionSHA256.hex(pdf))
        XCTAssertEqual(content.pdfPageCount, 3)
        XCTAssertEqual(content.title, "Übungsblatt 3")
        XCTAssertEqual(content.displayName, "Mia")
        XCTAssertEqual(content.createdAt, "2026-10-26T07:33:20Z")
        XCTAssertNotNil(UUID(uuidString: content.solutionID))
        // Seitenzuordnung
        let p1 = content.pages[0], blank = content.pages[1], p2 = content.pages[2]
        XCTAssertEqual([p1.kind, blank.kind, p2.kind], [.pdf, .blank, .pdf])
        XCTAssertEqual([p1.pdfIndex, blank.pdfIndex, p2.pdfIndex], [1, nil, 2])
        XCTAssertEqual(blank.template, "grid")
        XCTAssertEqual([blank.width, blank.height], [420, 595])
        XCTAssertEqual([p2.width, p2.height], [842, 595])
        XCTAssertEqual(p2.rotation, 90, "PDF-Drehung 0 plus Drehung aus pageOrder")
        XCTAssertEqual(p2.extraRotation, 90)
        XCTAssertEqual(p2.displaySize.width, 595)
        // Bild eingebettet, kein pkdrawing, keine Wurzelfelder des eigenen Dokuments
        XCTAssertEqual(content.images["/api/files/f1/assets/bild.png"]?.data, pngBytes)
        XCTAssertTrue(content.missingImages.isEmpty)
        let text = content.json.jsonString(sortedKeys: true)
        for forbidden in ["pkdrawing", "QUJD", "objectsSig", "bookmarks", "privat", "deletedPages", "/api/assets/a1"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testRotationOfPDFAddsOwnRotate() throws {
        var doc = try makeDocument()
        doc.pages["p3"] = ["objects": [["id": "z", "type": "text", "text": "a", "x": 1, "y": 2]]]
        var order = doc.pageOrder
        order[3]["rotation"] = 270
        doc.root["pageOrder"] = .array(order)
        let c = try build(doc, keys: ["p3"], pdf: fakePDF())
        XCTAssertEqual(c.pages[0].rotation, 0, "/Rotate 90 + 270 = 360 = 0")
        XCTAssertEqual(c.pages[0].extraRotation, 270)
    }

    func testMissingImagesAreCounted() throws {
        let c = try build(try makeDocument(), pdf: fakePDF(), images: [:])
        XCTAssertEqual(c.missingImages, ["/api/files/f1/assets/bild.png"])
        XCTAssertTrue(c.images.isEmpty)
        // kein PNG/JPEG -> fehlt ebenfalls
        let bad = try build(try makeDocument(), pdf: fakePDF(),
                            images: ["/api/files/f1/assets/bild.png": SolutionImage(mime: "image/png", data: Data("%PDF-1.4".utf8))])
        XCTAssertEqual(bad.missingImages.count, 1)
    }

    func testBuilderRefusesWhatCannotBeSharedSafely() throws {
        let pdf = fakePDF()
        var doc = try makeDocument()
        XCTAssertThrowsError(try build(doc, keys: [], pdf: pdf)) { XCTAssertEqual($0 as? SolutionError, .nothingSelected) }
        XCTAssertThrowsError(try build(doc, keys: ["aX"], pdf: pdf), "Bild-/PDF-Seite aus dem Browser wird nie geteilt")
        // unbekannter Objekttyp: lieber nicht teilen als still etwas verlieren
        doc.pages["p3"] = ["objects": [["id": "q", "type": "hologram"]]]
        XCTAssertThrowsError(try build(doc, keys: ["p3"], pdf: pdf)) {
            XCTAssertEqual($0 as? SolutionError, .unsupportedObjectType("hologram"))
        }
        doc.pages["p3"] = ["objects": [["id": "q", "type": "image", "src": "data:application/pdf;base64,AAAA"]]]
        XCTAssertThrowsError(try build(doc, keys: ["p3"], pdf: pdf)) { XCTAssertEqual($0 as? SolutionError, .containsPDFData) }
        doc.pages["p3"] = ["objects": [["id": "q", "type": "stroke", "points": [.number(.infinity), 1]]]]
        XCTAssertThrowsError(try build(doc, keys: ["p3"], pdf: pdf)) { XCTAssertEqual($0 as? SolutionError, .nonFiniteNumber) }
    }

    // MARK: Paket

    func testPackageContainsNoPDFBytes() throws {
        let pdf = fakePDF(size: 20_000)
        let content = try build(try makeDocument(), pdf: pdf)
        let package = try SolutionPackage.seal(content, originalPDF: pdf, cipher: cipher)
        let file = package.encoded()
        let plain = content.json.serialized(sortedKeys: true)
        for blob in [file, plain] {
            XCTAssertNil(blob.range(of: Data("%PDF".utf8)))
            XCTAssertNil(blob.range(of: Data("JVBER".utf8)), "auch nicht als Base64")
            // keine Stuecke der PDF-Bytes (je 24 Byte, alle 97 Byte eine Stichprobe)
            var i = 0
            while i + 24 <= pdf.count {
                XCTAssertNil(blob.range(of: pdf.subdata(in: i..<(i + 24))), "PDF-Stueck bei \(i)")
                i += 97
            }
        }
        // nur bekannte Felder im Kopf und im Inhalt, keine PDF-Felder
        let root = try JSONValue.parse(file)
        XCTAssertEqual(Set(root.object!.keys), ["format", "formatVersion", "header", "ciphertext"])
        XCTAssertEqual(Set(root["header"]!.object!.keys), ["solutionId", "createdAt", "displayName", "document", "contents", "encryption"])
        XCTAssertEqual(Set(root["header"]!["document"]!.object!.keys), ["sha256", "pageCount"])
        XCTAssertEqual(Set(content.json.object!.keys),
                       ["format", "formatVersion", "solutionId", "createdAt", "title", "displayName", "document", "pages", "images", "missingImages"])
        for p in content.json["pages"]!.array! {
            XCTAssertTrue(Set(p.object!.keys).isSubset(of: ["key", "kind", "pdfIndex", "width", "height", "rotation", "extraRotation", "template", "objects"]))
        }
        // Titel und Notizen stehen nicht im Klartext der Datei
        let text = String(decoding: file, as: UTF8.self)
        XCTAssertFalse(text.contains("Übungsblatt"))
        XCTAssertFalse(text.contains("Lösung: x"))
        XCTAssertTrue(text.contains(SolutionSHA256.hex(pdf)), "Fingerabdruck im Kopf (nur zur Zuordnung)")
    }

    func testSecondDeviceWithSamePDFGetsIdenticalObjects() throws {
        let pdf = fakePDF()
        let doc = try makeDocument()
        let content = try build(doc, pdf: pdf)
        let sender = SolutionLibrary(root: try tempDir())
        let package = try SolutionPackage.seal(content, originalPDF: pdf, cipher: cipher)
        try sender.recordShared(package, title: content.title)
        let file = try Data(contentsOf: sender.sharedPackageURL(content.solutionID))

        // zweites "Geraet": eigener Ordner, eigene Kopie derselben PDF-Datei
        let receiver = SolutionLibrary(root: try tempDir())
        let entry = try receiver.importPackage(file)
        XCTAssertEqual(entry.fingerprint, SolutionSHA256.hex(pdf))
        XCTAssertEqual(entry.displayName, "Mia")
        XCTAssertEqual(receiver.entries(fingerprint: SolutionSHA256.hex(pdf)).map(\.solutionID), [content.solutionID])
        XCTAssertEqual(try Data(contentsOf: receiver.root.appendingPathComponent("received/\(content.solutionID).uniflowsolution")), file,
                       "gespeichert wie empfangen (verschluesselt)")
        let opened = try receiver.package(content.solutionID).open(originalPDF: Data(pdf), cipher: cipher)
        XCTAssertEqual(opened, content)
        for page in opened.pages { XCTAssertEqual(page.objects, doc.objects(page: page.key)) }
    }

    func testOtherPDFNeverOpens() throws {
        let pdf = fakePDF(1), other = fakePDF(2)
        let package = try SolutionPackage.seal(try build(try makeDocument(), pdf: pdf), originalPDF: pdf, cipher: cipher)
        XCTAssertThrowsError(try package.open(originalPDF: other, cipher: cipher)) {
            XCTAssertEqual($0 as? SolutionError, .fingerprintMismatch)
        }
        // selbst mit passend gefaelschtem Fingerabdruck: der Schluessel haengt an den Bytes, nicht am Hash
        var forged = try JSONValue.parse(package.encoded())
        forged["header"]?["document"]?["sha256"] = .string(SolutionSHA256.hex(other))
        let p = try SolutionPackage.decode(forged.serialized(sortedKeys: true))
        XCTAssertThrowsError(try p.open(originalPDF: other, cipher: cipher)) { XCTAssertEqual($0 as? SolutionError, .decryptionFailed) }
        // nur ein veraendertes Byte der PDF reicht
        var changed = [UInt8](pdf)
        changed[changed.count / 2] ^= 1
        XCTAssertThrowsError(try package.open(originalPDF: Data(changed), cipher: cipher))
        // Schluessel kommt nicht aus dem Fingerabdruck: mit dem Hash als "PDF" laesst sich nichts oeffnen
        XCTAssertThrowsError(try cipher.open(package.ciphertext, keyMaterial: Data(SolutionSHA256.hex(pdf).utf8), salt: package.header.salt,
                                             info: SolutionPackage.keyInfo(solutionID: package.header.solutionID),
                                             nonce: package.header.nonce, aad: package.authenticatedHeader))
        // Seal verweigert, wenn der Fingerabdruck nicht zur PDF passt
        XCTAssertThrowsError(try SolutionPackage.seal(try build(try makeDocument(), pdf: pdf), originalPDF: other, cipher: cipher))
    }

    // MARK: Manipulation und kaputte Pakete

    private func mutate(_ package: SolutionPackage, _ change: (inout JSONValue) -> Void) -> Data {
        var json = try! JSONValue.parse(package.encoded())
        change(&json)
        return json.serialized(sortedKeys: true)
    }

    private func assertRejected(_ data: Data, pdf: Data, _ expected: SolutionError? = nil, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let p = try SolutionPackage.decode(data)
            _ = try p.open(originalPDF: pdf, cipher: cipher)
            XCTFail("nicht abgewiesen", file: file, line: line)
        } catch {
            if let expected { XCTAssertEqual(error as? SolutionError, expected, file: file, line: line) }
            XCTAssertNotNil(error as? SolutionError, "\(error)", file: file, line: line)
        }
    }

    func testManipulatedPackagesAreRejected() throws {
        let pdf = fakePDF()
        let package = try SolutionPackage.seal(try build(try makeDocument(), pdf: pdf), originalPDF: pdf, cipher: cipher)
        XCTAssertNoThrow(try SolutionPackage.decode(package.encoded()).open(originalPDF: pdf, cipher: cipher))

        // Chiffrat: ein Bit
        var flipped = package
        flipped.ciphertext[5] ^= 0x01
        assertRejected(flipped.encoded(), pdf: pdf, .decryptionFailed)
        var tag = package
        tag.ciphertext[tag.ciphertext.count - 1] ^= 0x80
        assertRejected(tag.encoded(), pdf: pdf, .decryptionFailed)
        // Kopf (authentifiziert): Name, Datum, Inhaltsangaben, Salz
        assertRejected(mutate(package) { $0["header"]?["displayName"] = "Jemand anderes" }, pdf: pdf, .decryptionFailed)
        assertRejected(mutate(package) { $0["header"]?["createdAt"] = "2020-01-01T00:00:00Z" }, pdf: pdf, .decryptionFailed)
        assertRejected(mutate(package) { $0["header"]?["contents"]?["images"] = 0 }, pdf: pdf, .decryptionFailed)
        assertRejected(mutate(package) { $0["header"]?["encryption"]?["salt"] = .string(Data(repeating: 7, count: 32).base64EncodedString()) },
                       pdf: pdf, .decryptionFailed)
        assertRejected(mutate(package) { $0["header"]?["extra"] = "x" }, pdf: pdf, .invalidHeader("unbekannte Felder"))
        assertRejected(mutate(package) { $0["header"]?["solutionId"] = "keine-uuid" }, pdf: pdf, .invalidHeader("Lösungs-ID"))
        assertRejected(mutate(package) { $0["header"]?["encryption"]?["cipher"] = "ROT13" }, pdf: pdf, .invalidHeader("Verfahren"))
        // Version
        assertRejected(mutate(package) { $0["formatVersion"] = 2 }, pdf: pdf, .unsupportedVersion(2))
        assertRejected(mutate(package) { $0["format"] = "etwas-anderes" }, pdf: pdf, .notASolution)
        // Groesse: angegebene Klartextgroesse, abgeschnittenes Chiffrat, zu grosse Datei
        assertRejected(mutate(package) { $0["header"]?["encryption"]?["plaintextBytes"] = .number(Double(package.header.plaintextBytes + 1)) },
                       pdf: pdf, .invalidHeader("Größe"))
        var short = package
        short.ciphertext = short.ciphertext.dropLast(3)
        assertRejected(short.encoded(), pdf: pdf, .invalidHeader("Größe"))
        assertRejected(Data(count: SolutionLimits.maxPackageBytes + 1), pdf: pdf, .tooLarge)
        // kaputtes JSON
        assertRejected(Data("{\"format\":\"uniflow-solution\",".utf8), pdf: pdf, .notASolution)
        assertRejected(package.encoded().prefix(100), pdf: pdf, .notASolution)
        assertRejected(Data("%PDF-1.7 keine Loesung".utf8), pdf: pdf, .notASolution)
        // nicht endliche Zahl im Kopf (1e999 liest sich als Unendlich)
        let inf = String(decoding: package.encoded(), as: UTF8.self)
            .replacingOccurrences(of: "\"pageCount\":3", with: "\"pageCount\":1e999")
        assertRejected(Data(inf.utf8), pdf: pdf, .nonFiniteNumber)
    }

    /// Gueltig verschluesselter, aber boesartiger Inhalt (wie von einem fremden Programm erzeugt).
    private func sealRaw(_ plaintext: Data, pdf: Data, id: String = "6f1c1c0e-6a63-4c38-9a0b-6c0f0f7b9a11",
                         pages: Int = 1, images: Int = 0) throws -> Data {
        let header = SolutionHeader(solutionID: id, createdAt: "2026-10-25T10:00:00Z", displayName: "",
                                    fingerprint: SolutionSHA256.hex(pdf), pdfPageCount: 3, pageCount: pages, imageCount: images,
                                    missingImageCount: 0, salt: Data(repeating: 1, count: 32), nonce: Data(repeating: 2, count: 12),
                                    plaintextBytes: plaintext.count)
        var p = SolutionPackage(header: header, ciphertext: Data())
        p.ciphertext = try cipher.seal(plaintext, keyMaterial: pdf, salt: header.salt, info: SolutionPackage.keyInfo(solutionID: id),
                                       nonce: header.nonce, aad: p.authenticatedHeader)
        return p.encoded()
    }

    private func contentText(objects: String, page: String? = nil, id: String = "6f1c1c0e-6a63-4c38-9a0b-6c0f0f7b9a11",
                             pdf: Data) -> String {
        let pageJSON = page ?? #"{"key":"p1","kind":"pdf","pdfIndex":1,"width":595,"height":842,"rotation":0,"extraRotation":0,"objects":\#(objects)}"#
        return #"{"format":"uniflow-solution-content","formatVersion":1,"solutionId":"\#(id)","createdAt":"2026-10-25T10:00:00Z","title":"T","displayName":"","document":{"sha256":"\#(SolutionSHA256.hex(pdf))","pageCount":3},"pages":[\#(pageJSON)],"images":{},"missingImages":[]}"#
    }

    func testMaliciousContentIsRejected() throws {
        let pdf = fakePDF()
        // Gegenprobe: derselbe Weg mit gueltigem Inhalt oeffnet
        let ok = try sealRaw(Data(contentText(objects: #"[{"id":"a","type":"text","text":"hi"}]"#, pdf: pdf).utf8), pdf: pdf)
        XCTAssertEqual(try SolutionPackage.decode(ok).open(originalPDF: pdf, cipher: cipher).pages[0].objects.count, 1)

        assertRejected(try sealRaw(Data("{\"format\":\"uniflow-solution-content\",\"pages\":[".utf8), pdf: pdf), pdf: pdf,
                       .invalidContent("JSON"))
        assertRejected(try sealRaw(Data(contentText(objects: #"[{"id":"a","type":"script","code":"x"}]"#, pdf: pdf).utf8), pdf: pdf),
                       pdf: pdf, .unsupportedObjectType("script"))
        assertRejected(try sealRaw(Data(contentText(objects: #"[{"id":"a","type":"stroke","points":[1e999,0,1,1]}]"#, pdf: pdf).utf8), pdf: pdf),
                       pdf: pdf, .nonFiniteNumber)
        assertRejected(try sealRaw(Data(contentText(objects: #"[{"id":"a","type":"text","text":"%PDF-1.7"}]"#, pdf: pdf).utf8), pdf: pdf),
                       pdf: pdf, .containsPDFData)
        assertRejected(try sealRaw(Data(contentText(objects: "[]", page: #"{"key":"p9","kind":"pdf","pdfIndex":9,"width":595,"height":842,"rotation":0,"extraRotation":0,"objects":[]}"#, pdf: pdf).utf8), pdf: pdf),
                       pdf: pdf, .invalidContent("PDF-Seite"))
        assertRejected(try sealRaw(Data(contentText(objects: "[]", page: #"{"key":"p1","kind":"pdf","pdfIndex":1,"width":595,"height":842,"rotation":45,"extraRotation":0,"objects":[]}"#, pdf: pdf).utf8), pdf: pdf),
                       pdf: pdf, .invalidContent("Drehung"))
        assertRejected(try sealRaw(Data(contentText(objects: "[]", page: #"{"key":"p1","kind":"background","width":595,"height":842,"rotation":0,"extraRotation":0,"objects":[]}"#, pdf: pdf).utf8), pdf: pdf),
                       pdf: pdf, .invalidContent("Seitenart"))
        assertRejected(try sealRaw(Data(contentText(objects: "[]", page: #"{"key":"p1","kind":"pdf","pdfIndex":1,"width":-5,"height":842,"rotation":0,"extraRotation":0,"objects":[]}"#, pdf: pdf).utf8), pdf: pdf),
                       pdf: pdf, .invalidContent("Seitengröße"))
        // Inhalt passt nicht zum Kopf (andere Loesungs-ID bzw. Seitenzahl)
        assertRejected(try sealRaw(Data(contentText(objects: "[]", id: "11111111-2222-4333-8444-555555555555", pdf: pdf).utf8), pdf: pdf),
                       pdf: pdf, .invalidContent("passt nicht zum Kopf"))
        assertRejected(try sealRaw(Data(contentText(objects: "[]", pdf: pdf).utf8), pdf: pdf, pages: 2), pdf: pdf,
                       .invalidContent("passt nicht zum Kopf"))
        // Bild, das keins ist
        let fakeImage = contentText(objects: "[]", pdf: pdf).replacingOccurrences(
            of: #""images":{}"#, with: #""images":{"/x":{"mime":"image/png","data":"\#(Data("%PDF-1.4 ...".utf8).base64EncodedString())"}}"#)
        assertRejected(try sealRaw(Data(fakeImage.utf8), pdf: pdf, images: 1), pdf: pdf, .invalidContent("Bilddaten"))
    }

    // MARK: Geometrie

    func testRotationTransformKeepsPositionOnPageContent() {
        let W = 595.0, H = 842.0
        // Absender ohne Drehung, Empfaenger dreht um 90 Grad: oben links -> oben rechts
        let t = SolutionGeometry.transform(width: W, height: H, from: 0, to: 90)
        XCTAssertEqual(t.apply(x: 0, y: 0).x, H, accuracy: 1e-9)
        XCTAssertEqual(t.apply(x: 0, y: 0).y, 0, accuracy: 1e-9)
        XCTAssertEqual(t.apply(x: 10, y: 20).x, H - 20, accuracy: 1e-9)
        XCTAssertEqual(t.apply(x: 10, y: 20).y, 10, accuracy: 1e-9)
        XCTAssertEqual(t.apply(x: W, y: H).x, 0, accuracy: 1e-9)
        XCTAssertEqual(t.apply(x: W, y: H).y, W, accuracy: 1e-9)
        // gleiche Drehung: unveraendert
        XCTAssertTrue(SolutionGeometry.transform(width: W, height: H, from: 270, to: 270).isIdentity)
        // hin und zurueck
        for (f, to) in [(0, 90), (90, 270), (180, 0), (270, 90), (90, 180)] {
            let there = SolutionGeometry.transform(width: W, height: H, from: f, to: to)
            let back = SolutionGeometry.transform(width: W, height: H, from: to, to: f)
            let p = there.followed(by: back).apply(x: 123.5, y: 456.25)
            XCTAssertEqual(p.x, 123.5, accuracy: 1e-9)
            XCTAssertEqual(p.y, 456.25, accuracy: 1e-9)
            // Ecken der Absenderseite landen auf Ecken der Empfaengerseite
            let (sw, sh) = SolutionGeometry.displaySize(width: W, height: H, rotation: f)
            let (rw, rh) = SolutionGeometry.displaySize(width: W, height: H, rotation: to)
            for (x, y) in [(0.0, 0.0), (sw, 0), (0, sh), (sw, sh)] {
                let q = there.apply(x: x, y: y)
                XCTAssertTrue([0, rw].contains { abs($0 - q.x) < 1e-9 } && [0, rh].contains { abs($0 - q.y) < 1e-9 }, "\(f)->\(to)")
            }
        }
        // 180 Grad: Mittelpunkt bleibt, Punkt wird gespiegelt
        let half = SolutionGeometry.transform(width: W, height: H, from: 0, to: 180)
        XCTAssertEqual(half.apply(x: 100, y: 50).x, W - 100, accuracy: 1e-9)
        XCTAssertEqual(half.apply(x: 100, y: 50).y, H - 50, accuracy: 1e-9)
        // Absender 90 (Querformat 842 x 595), Empfaenger 270
        let q = SolutionGeometry.transform(width: W, height: H, from: 90, to: 270).apply(x: 842, y: 0)   // Ecke oben rechts
        XCTAssertEqual(q.x, 0, accuracy: 1e-9)
        XCTAssertEqual(q.y, 595, accuracy: 1e-9)
        XCTAssertEqual(SolutionGeometry.normalized(-90), 270)
        XCTAssertEqual(SolutionGeometry.normalized(450), 90)
    }

    // MARK: Ablage

    func testLibraryIndexVisibilityAndRemoval() throws {
        let pdf = fakePDF(), other = fakePDF(9)
        let lib = SolutionLibrary(root: try tempDir())
        let a = try SolutionPackage.seal(try build(try makeDocument(), pdf: pdf, name: ""), originalPDF: pdf, cipher: cipher)
        let b = try SolutionPackage.seal(try build(try makeDocument(), pdf: other), originalPDF: other, cipher: cipher)
        try lib.importPackage(a.encoded(), now: Date(timeIntervalSince1970: 1_793_000_100))
        try lib.importPackage(b.encoded(), now: Date(timeIntervalSince1970: 1_793_000_200))
        XCTAssertEqual(lib.entries(fingerprint: SolutionSHA256.hex(pdf)).map(\.solutionID), [a.header.solutionID])
        XCTAssertEqual(lib.entries(fingerprint: SolutionSHA256.hex(other)).map(\.solutionID), [b.header.solutionID])
        XCTAssertEqual(lib.entries(fingerprint: SolutionSHA256.hex(pdf))[0].displayName, "", "anonym")
        XCTAssertEqual(lib.allEntries().count, 2)
        // Sichtbarkeit bleibt auch bei erneutem Import erhalten
        try lib.setVisible(a.header.solutionID, false)
        try lib.importPackage(a.encoded())
        XCTAssertEqual(lib.entries(fingerprint: SolutionSHA256.hex(pdf)).map(\.visible), [false])
        XCTAssertEqual(lib.allEntries().count, 2, "gleiche ID ersetzt")
        // Index ueberlebt einen Neustart
        let again = SolutionLibrary(root: lib.root)
        XCTAssertEqual(again.entries(fingerprint: SolutionSHA256.hex(other)).first?.displayName, "Mia")
        try again.remove(a.header.solutionID)
        XCTAssertTrue(again.entries(fingerprint: SolutionSHA256.hex(pdf)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.root.appendingPathComponent("received/\(a.header.solutionID).uniflowsolution").path))
        // ungueltiges Paket: nichts gespeichert
        XCTAssertThrowsError(try again.importPackage(Data("kaputt".utf8)))
        XCTAssertEqual(again.allEntries().count, 1)
        // eigene geteilte Loesungen: merken und lokal zurueckziehen
        try again.recordShared(a, title: "Blatt 3")
        XCTAssertEqual(again.sharedEntries().map(\.title), ["Blatt 3"])
        XCTAssertEqual(try SolutionPackage.decode(Data(contentsOf: again.sharedPackageURL(a.header.solutionID))), a)
        try again.removeShared(a.header.solutionID)
        XCTAssertTrue(again.sharedEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.sharedPackageURL(a.header.solutionID).path))
        XCTAssertEqual(SolutionLibrary.fileName("../../etc"), "ec.uniflowsolution", "kein Pfad aus der ID")
    }

    // MARK: Community

    func testCommunityIsNotConnectedAndFakesNothing() async throws {
        let service: CommunityService = NotConnectedCommunityService()
        XCTAssertFalse(service.isConnected)
        let pdf = fakePDF()
        let package = try SolutionPackage.seal(try build(try makeDocument(), pdf: pdf), originalPDF: pdf, cipher: cipher)
        func expectNotConnected(_ body: () async throws -> Void) async {
            do { try await body(); XCTFail("kein Fehler") } catch {
                XCTAssertEqual(error as? CommunityServiceError, .notConnected)
                XCTAssertEqual(error.localizedDescription, "Community-Dienst noch nicht verbunden.")
            }
        }
        await expectNotConnected { _ = try await service.publish(package) }
        await expectNotConnected { _ = try await service.findMatching(fingerprint: package.header.fingerprint) }
        await expectNotConnected { _ = try await service.download(solutionID: package.header.solutionID) }
        await expectNotConnected { try await service.withdraw(solutionID: package.header.solutionID) }
        await expectNotConnected { try await service.report(solutionID: package.header.solutionID, reason: .foreignMaterial, note: nil) }
    }
}
