import Foundation
import XCTest
@testable import UniFlowCore

// Externer Pruefbericht, Apple-Runden 12 und 13 (Nr. 391-440): Seiten, Papierkorb, Vorlagen, Loesungspakete,
// Formulare, Zusammenfuehrung und Synchronisierung. Die Stud.IP-Punkte (381-390, 421-430) stehen in
// StudIPScheduleStoreTests.swift (`StudIPScheduleIntegrityTests`). Ergebnis: docs/audit/RUNDE-12-13-381-440.md.

private func doc(_ text: String) throws -> AnnotationDocument { AnnotationDocument(root: try JSONValue.parse(text)) }

private func ids(_ objects: [JSONValue]) -> [String] { objects.compactMap { $0["id"]?.string } }

private func orderKeys(_ d: AnnotationDocument) -> [String] { d.pageOrder.compactMap { $0["key"]?.string } }

// MARK: - 391-400 Seiten, Papierkorb, Vorlagen

final class AuditPagesTrashTemplatesTests: XCTestCase {

    /// 392 (Fehler belegt): Beide Geraete legen dieselbe Seite in den Papierkorb, das andere hatte vorher darauf
    /// geschrieben. Die Zusammenfuehrung behaelt den Papierkorb-Eintrag dieses Geraets (`mergeTrash`, hier zuerst) und
    /// in `pages` den neueren Stand. Wiederherstellen setzte frueher die alten Papierkorb-Objekte ein: der Strich des
    /// anderen Geraets war weg, auch auf dem Server (naechster Upload).
    func testRestoreAfterBothDevicesTrashedThePageKeepsTheOtherDevicesStrokes() async {
        let server = MockServer()
        let a = makeEngine(server, MemoryBlobStore())
        _ = await a.open(pdfPageCount: 2)
        await a.updatePage("p2", page(["a1"]))
        await a.syncNow()

        let b = makeEngine(server, MemoryBlobStore())
        _ = await b.open(pdfPageCount: 2)
        await b.updatePage("p2", page(["a1", "b2"]))                      // B schreibt ...
        var db = await b.currentDocument()
        XCTAssertNotNil(PageOrder.trash(&db, key: "p2"))                 // ... und legt die Seite in den Papierkorb
        await b.updateRootMeta(db.rootMeta)
        await b.syncNow()

        var da = await a.currentDocument()                               // A kennt nur a1 und loescht die Seite auch
        XCTAssertNotNil(PageOrder.trash(&da, key: "p2"))
        await a.updateRootMeta(da.rootMeta)
        await a.syncNow()                                                // 409 -> zusammenfuehren -> speichern

        var merged = await a.currentDocument()
        XCTAssertEqual(orderKeys(merged), ["p1"])
        XCTAssertEqual(PageOrder.trashedPages(merged).map(\.objectCount), [1], "Papierkorb-Eintrag dieses Geraets (nur a1)")
        XCTAssertEqual(ids(merged.objects(page: "p2")), ["a1", "b2"], "pages hat den neueren Stand")
        let change = PageOrder.restore(&merged, key: "p2")
        XCTAssertEqual(change?.changedPageKeys, [], "nichts zu aendern: der neuere Stand bleibt")
        XCTAssertEqual(orderKeys(merged), ["p1", "p2"])
        XCTAssertEqual(ids(merged.objects(page: "p2")), ["a1", "b2"], "der Strich des anderen Geraets bleibt")
        await a.updateRootMeta(merged.rootMeta)
        await a.syncNow()
        let onServer = await server.objectIDs(page: "p2")
        XCTAssertEqual(onServer, ["a1", "b2"])
    }

    /// 392: Regel im Einzelnen: Papierkorb-Reihenfolge, je Kennung der neuere Stand, dahinter nur in der Seite
    /// stehende Objekte; Objekte ohne Kennung nach Inhalt; ohne Aenderung genau der Papierkorb
    func testRestoredObjectsKeepEverything() {
        let x: JSONValue = ["id": "x", "type": "stroke", "points": [1, 2]]
        let a: JSONValue = ["id": "a", "type": "stroke", "points": [0, 0]]
        let aMoved: JSONValue = ["id": "a", "type": "stroke", "points": [5, 5]]
        let y: JSONValue = ["id": "y", "type": "text", "text": "neu"]
        let noID: JSONValue = ["type": "shape", "w": 3]
        XCTAssertEqual(PageOrder.restoredObjects(trashed: [a, x], current: [a, x]), [a, x])
        XCTAssertEqual(PageOrder.restoredObjects(trashed: [a, x, noID], current: [aMoved, y]), [aMoved, x, noID, y])
        XCTAssertEqual(PageOrder.restoredObjects(trashed: [], current: [y]), [y])
        XCTAssertEqual(PageOrder.restoredObjects(trashed: [a, a], current: []), [a], "doppelt im Papierkorb: einmal")
    }

    /// 400: Native Zeichnung bleibt beim Wiederherstellen erhalten; ihre Signatur passt dann nicht mehr zu allen
    /// Objekten, die Anzeige baut die betroffenen Striche aus den Objekten (StrokeConverter, App-Test
    /// `AuditRunde1213AppTests.testRestoredPageDrawingMatchesItsObjects`)
    func testRestoreKeepsDrawingFieldBesideRestoredObjects() throws {
        var d = try doc(#"""
            {"version":2,"pages":{"p1":{"objects":[]},"p2":{"objects":[{"id":"s1","type":"stroke","points":[0,0,1,1]}],
              "pkdrawing":{"format":"pkdrawing-v2","data":"QUJD","objectsSig":"x","strokeIds":[["s1"]],"strokeSigs":["s"]}}},
             "pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2}]}
            """#)
        PageOrder.trash(&d, key: "p2")
        d.pages["p2"]?["objects"] = [["id": "s1", "type": "stroke", "points": [0, 0, 1, 1]], ["id": "s2", "type": "stroke", "points": [2, 2, 3, 3]]]
        PageOrder.restore(&d, key: "p2")
        XCTAssertEqual(ids(d.objects(page: "p2")), ["s1", "s2"])
        XCTAssertNotNil(d.page("p2")?["pkdrawing"], "Zeichnung bleibt, Pruefung je Strich beim Laden")
    }

    /// 393: Frueherer Platz ist ein Hinweis: hat das andere Geraet umsortiert, landet die Seite an derselben Stelle
    /// (hoechstens am Ende) mit vollstaendigem Inhalt, wie `restorePage` im Web
    func testRestorePositionAfterReorderElsewhereIsClampedAndContentComplete() throws {
        var d = try doc(#"""
            {"version":2,"pages":{"p1":{"objects":[]},"p2":{"objects":[{"id":"s"}]},"p3":{"objects":[]},"p4":{"objects":[]}},
             "pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2},{"key":"p3","type":"pdf","index":3},{"key":"p4","type":"pdf","index":4}]}
            """#)
        PageOrder.trash(&d, key: "p2")
        d.root["pageOrder"] = [["key": "p4", "type": "pdf", "index": 4], ["key": "p3", "type": "pdf", "index": 3]]   // anderes Geraet
        PageOrder.restore(&d, key: "p2")
        XCTAssertEqual(orderKeys(d), ["p4", "p2", "p3"])
        XCTAssertEqual(ids(d.objects(page: "p2")), ["s"])
        // Platz hinter dem Ende (kaputter oder sehr grosser Wert): ans Ende
        PageOrder.trash(&d, key: "p2")
        var deleted = d.root["deletedPages"]?.array ?? []
        deleted[0]["pos"] = 99_999
        d.root["deletedPages"] = .array(deleted)
        PageOrder.restore(&d, key: "p2")
        XCTAssertEqual(orderKeys(d), ["p4", "p3", "p2"])
    }

    /// 395: Viele schnelle Einfuegungen in derselben Millisekunde: jeder Schluessel ist neu (8 Zufallszeichen aus 36,
    /// dazu wird jeder vergebene Schluessel des Dokuments uebersprungen)
    func testRapidInsertionsNeverReuseAKey() throws {
        let fixed = Date(timeIntervalSince1970: 1_793_000_000)
        var seen = Set<String>()
        for _ in 0..<50_000 { seen.insert(PageOrder.newBlankKey(now: fixed)) }
        XCTAssertEqual(seen.count, 50_000)
        var d = try doc(#"{"version":2,"pages":{"p1":{"objects":[]}},"pageOrder":[{"key":"p1","type":"pdf","index":1}]}"#)
        for _ in 0..<2_000 { XCTAssertNotNil(PageOrder.insertBlank(&d, after: "p1", template: "lined")) }
        XCTAssertEqual(Set(orderKeys(d)).count, 2_001)
        XCTAssertEqual(d.pages.count, 2_001)
    }

    /// 396 (Fehler belegt): eine Seitengroesse 1e999 (JSON-Zahl, wird zu unendlich) liess die Schleife der Vorlage nie
    /// enden; jetzt keine Geometrie bei nicht endlicher Groesse und hoechstens bis zur groessten PDF-Seite
    func testTemplateGeometryHasUpperBounds() throws {
        let inf = try XCTUnwrap(try JSONValue.parse("[1e999]").array?.first?.double)
        XCTAssertEqual(inf, .infinity, "Voraussetzung: so kommt unendlich in ein Notizdokument")
        for t in PageOrder.templates {
            XCTAssertTrue(TemplateGeometry.make(t, width: .infinity, height: 842).isEmpty, t)
            XCTAssertTrue(TemplateGeometry.make(t, width: 595, height: .nan).isEmpty, t)
            let huge = TemplateGeometry.make(t, width: 1e12, height: 1e12)
            XCTAssertLessThanOrEqual(huge.horizontal.count, 5_100, t)
            XCTAssertLessThanOrEqual(huge.vertical.count, 5_100, t)
            XCTAssertLessThanOrEqual(huge.dotColumns.count, 1_100, t)
            XCTAssertTrue((huge.horizontal + huge.vertical + huge.dotColumns + huge.dotRows).allSatisfy { $0 <= PageOrder.maxSide }, t)
        }
        let start = Date()
        _ = TemplateGeometry.make("mm", width: PageOrder.maxSide, height: PageOrder.maxSide)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    /// 397: Cornell auf sehr kleinen Seiten rechnet wie `renderTemplate` im Web (Trennlinie bei x = 150, Fuss 150 pt
    /// ueber dem unteren Rand); bei weniger als 150 pt liegt der Fuss ausserhalb der Seite und wird nicht sichtbar.
    /// Abweichen wuerde von der Web-Darstellung; alle Werte bleiben endlich.
    func testCornellOnTinyPagesMatchesWebAndStaysFinite() {
        let a6 = TemplateGeometry.make("cornell", width: 298, height: 420)
        XCTAssertEqual(a6.cornellFooterY, 270)
        XCTAssertEqual(a6.horizontal.first, 60)
        let tiny = TemplateGeometry.make("cornell", width: 100, height: 100)
        XCTAssertEqual(tiny.cornellFooterY, -50, "wie H - 150 im Web")
        XCTAssertEqual(tiny.horizontal, [60, 84])
        XCTAssertTrue(tiny.horizontal.allSatisfy { $0 < 100 })
    }

    /// 398: Millimeter- und Punktraster auf nicht genormten Groessen: Positionen als Vielfache (kein Wandern), letzte
    /// Linie innerhalb der Seite, jede zehnte Millimeterlinie kraeftig, auch auf A0 quer
    func testGridsOnUnusualSizes() {
        for (w, h) in [(1000.5, 333.3), (3370.0, 2384.0), (101.0, 3399.0), (14_400.0, 100.0)] {
            let mm = TemplateGeometry.make("mm", width: w, height: h)
            XCTAssertEqual(mm.vertical.count, Int((w / TemplateGeometry.step("mm")).rounded(.up)), "\(w)")
            XCTAssertLessThan(mm.vertical.last ?? 0, w)
            XCTAssertLessThan(mm.horizontal.last ?? 0, h)
            for (i, x) in mm.vertical.enumerated() { XCTAssertEqual(x, Double(i) * 2.835, accuracy: 1e-9) }
            XCTAssertTrue(mm.isBold(0) && mm.isBold(10) && !mm.isBold(5))
            let dots = TemplateGeometry.make("dotted", width: w, height: h)
            XCTAssertEqual(dots.dotColumns.first, 14.17)
            XCTAssertLessThan(dots.dotColumns.last ?? 0, w)
            XCTAssertLessThan(dots.dotRows.last ?? 0, h)
            XCTAssertEqual(dots.dotRows.last ?? 0, Double(dots.dotRows.count) * 14.17, accuracy: 1e-6)
        }
    }

    /// 399: ungewoehnliche Drehungen wie in der Anzeige (`SolutionGeometry.normalized`): 45 wie 0, -90 wie 270,
    /// 450 wie 90; vorher vertauschte 45 Breite und Hoehe, waehrend die Anzeige nicht drehte
    func testBaseSizeNormalizesUnusualRotations() {
        func swapped(_ r: Int) -> Bool { PageOrder.baseSize(shownWidth: 100, shownHeight: 200, extraRotation: r).width == 200 }
        XCTAssertEqual([0, 45, 89, 180, -180, 360, 720, 135].map(swapped), [false, false, false, false, false, false, false, true])
        XCTAssertEqual([90, -90, 270, -270, 450, 99].map(swapped), [true, true, true, true, true, true])
        XCTAssertFalse(swapped(Int.min))
        XCTAssertNotNil(PageOrder.baseSize(shownWidth: 1, shownHeight: 2, extraRotation: Int.max))
    }

    /// 404: eine Regel fuer die Groesse eingefuegter Leerseiten (Editor, Loesungspaket, Einfuegen)
    func testBlankSizeIsOneRuleForEditorAndPackage() throws {
        XCTAssertTrue(PageOrder.blankSize(width: nil, height: nil) == (595, 842))
        XCTAssertTrue(PageOrder.blankSize(width: 0, height: -3) == (595, 842))
        XCTAssertTrue(PageOrder.blankSize(width: .infinity, height: .nan) == (595, 842))
        XCTAssertTrue(PageOrder.blankSize(width: 20_000, height: 420) == (14_400, 420))
        XCTAssertTrue(PageOrder.blankSize(width: 3370, height: 2384) == (3370, 2384), "A0 quer bleibt")
        var d = try doc(#"{"version":2,"pages":{"p1":{"objects":[]}},"pageOrder":[{"key":"p1","type":"pdf","index":1}]}"#)
        PageOrder.insertBlank(&d, after: "p1", template: "lined", width: .infinity, height: 0, key: "bX")
        XCTAssertEqual(d.pageOrder[1]["w"]?.double, 595)
        XCTAssertEqual(d.pageOrder[1]["h"]?.double, 842)
        // Loesungspaket: dieselbe Groesse wie der Editor (DisplayLayout nimmt dieselbe Funktion)
        d.root["pageOrder"] = [["key": "p1", "type": "pdf", "index": 1], ["key": "bX", "type": "blank", "template": "lined", "w": 0, "h": 500]]
        d.pages["bX"] = ["objects": [["id": "t", "type": "text", "text": "Notiz", "x": 500, "y": 400]]]
        let c = try AuditSolution.build(d, keys: ["bX"])
        XCTAssertEqual(c.pages.first?.width, 595)
        XCTAssertEqual(c.pages.first?.height, 500)
        XCTAssertEqual(c.pages.first?.objects.first?["x"], 500, "Notiz bleibt an ihrer Stelle")
    }
}

// MARK: - 401-410 Loesungspakete

/// Kleine Hilfen fuer Loesungspakete (wie in SolutionPackageTests, ohne deren Testklasse)
enum AuditSolution {
    static func info(_ i: Int) -> SolutionBuilder.PDFPageInfo? {
        (1...3).contains(i) ? .init(width: 595, height: 842, rotation: 0) : nil
    }

    static func build(_ d: AnnotationDocument, keys: [String], name: String = "", title: String = "Blatt",
                      id: UUID = UUID()) throws -> SolutionContent {
        try SolutionBuilder.build(document: d, selectedKeys: keys, pdfPageCount: 3, pdfPage: info, images: [:],
                                  fingerprint: String(repeating: "a", count: 64), title: title, displayName: name,
                                  solutionID: id, createdAt: Date(timeIntervalSince1970: 1_793_000_000))
    }

    static func document() throws -> AnnotationDocument {
        try doc(#"""
            {"version":2,"pages":{"p1":{"objects":[{"id":"a","type":"stroke","points":[0,0,1,1]}]},
              "p2":{"objects":[]},"p3":{"objects":[{"id":"c","type":"text","text":"x"}]},"p7":{"objects":[{"id":"z","type":"text","text":"alt"}]}},
             "pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2},{"key":"p3","type":"pdf","index":3},
                          {"key":"p7","type":"pdf","index":7}]}
            """#)
    }
}

final class AuditSolutionTests: XCTestCase {

    /// 401, 402: Reihenfolge des Pakets ist die Anzeigereihenfolge (der Dialog zeigt die Seiten so, die Auswahl ist eine
    /// Menge); Doppelte zaehlen einmal; der Dialog waehlt nur aus seinem eigenen Stand, unbekannte Schluessel kommen
    /// dort nicht vor und werden hier ausgelassen
    func testPackageFollowsPageOrderNotSelectionOrder() throws {
        let c = try AuditSolution.build(try AuditSolution.document(), keys: ["p3", "p1", "p3", "gibtsnicht"])
        XCTAssertEqual(c.pages.map(\.key), ["p1", "p3"])
    }

    /// 403 (behoben): PDF-Seite, die es in der PDF nicht (mehr) gibt (z. B. neue Fassung mit weniger Seiten), sperrte
    /// das Teilen ganz mit "Die Lösung ist beschädigt (Inhalt: PDF-Seite 7)". Jetzt nennt der Dialog sie als nicht
    /// teilbare Seite mit Grund und laesst sie aus; direkt erzeugt nennt der Fehler die Seite.
    func testMissingPDFPageIsANamedProblemNotABlocker() throws {
        let d = try AuditSolution.document()
        let problems = SolutionBuilder.pageProblems(d, keys: ["p1", "p2", "p3", "p7"], pdfPageCount: 3, pdfPage: AuditSolution.info)
        XCTAssertEqual(problems.map(\.label), ["PDF-Seite 7"])
        XCTAssertEqual(problems.first?.error, .pageNotInPDF)
        XCTAssertTrue(problems.first?.error.description.contains("nicht (mehr)") ?? false)
        XCTAssertEqual(SolutionBuilder.pageProblems(d, keys: ["p7"]).count, 0, "ohne PDF-Angaben wie bisher nur die Objekte")
        XCTAssertThrowsError(try AuditSolution.build(d, keys: ["p7"])) {
            XCTAssertEqual($0 as? SolutionError, .onPage("PDF-Seite 7", .pageNotInPDF))
        }
        XCTAssertEqual(try AuditSolution.build(d, keys: ["p1", "p3"]).pages.count, 2, "die anderen Seiten bleiben teilbar")
    }

    /// 406: Handschrift steht immer auch in `objects` (Striche als Objekte, `pkdrawing` bleibt draussen): eine Seite
    /// nur mit Strichen ist Inhalt; nur eine native Zeichnung ohne Objekte ist es nicht (dafuer bekommen alte Striche
    /// ohne Objekt in der App vor dem Teilen Objekte, `AuditRunde1213AppTests`)
    func testHandwritingOnlyIsContentAndDrawingDataIsNeverShared() throws {
        var d = try doc(#"""
            {"version":2,"pages":{"p1":{"objects":[{"id":"s","type":"stroke","points":[0,0,4,4]}],
              "pkdrawing":{"format":"pkdrawing-v2","data":"QUJD","objectsSig":"x","strokeIds":[["s"]],"strokeSigs":["q"]}}},
             "pageOrder":[{"key":"p1","type":"pdf","index":1}]}
            """#)
        let c = try AuditSolution.build(d, keys: ["p1"])
        XCTAssertEqual(c.objectCount, 1)
        XCTAssertFalse(String(decoding: c.json.serialized(), as: UTF8.self).contains("pkdrawing"))
        d.pages["p1"]?["objects"] = []
        XCTAssertThrowsError(try AuditSolution.build(d, keys: ["p1"])) { XCTAssertEqual($0 as? SolutionError, .noOwnNotes) }
    }

    /// 408: Titel und Pseudonym werden auf ganze Zeichen gekuerzt (Emoji bleiben heil); gleiche gekuerzte Namen sind
    /// zwei Loesungen mit eigener Kennung, keine ersetzt die andere
    func testTruncatedNamesStayWholeAndDistinctPackagesStayDistinct() throws {
        let d = try AuditSolution.document()
        let long = String(repeating: "👩‍🎓", count: 70)
        let first = try AuditSolution.build(d, keys: ["p1"], name: long + "A", title: String(repeating: "Ä", count: 250))
        let second = try AuditSolution.build(d, keys: ["p1"], name: long + "B")
        XCTAssertEqual(first.displayName.count, SolutionLimits.maxDisplayName)
        XCTAssertTrue(first.displayName.allSatisfy { $0 == "👩‍🎓" })
        XCTAssertEqual(first.title.count, SolutionLimits.maxTitle)
        XCTAssertEqual(first.displayName, second.displayName)
        XCTAssertNotEqual(first.solutionID, second.solutionID)
        XCTAssertNoThrow(try SolutionContent(json: first.json))
    }

    /// 409: Was ausser den Notizen im Inhalt steht (der Kopf ist unverschluesselt und enthaelt nur Kennung, Zeitpunkt
    /// und Pseudonym): Format, Kennung, Zeitpunkt, Titel, Pseudonym, Fingerabdruck und Seitenzahl der PDF, Seiten,
    /// eingebettete Bilder und die Quellen fehlender Bilder. Kein Geraet, kein Konto, keine Hochschule.
    func testPackageMetadataIsExactlyThis() throws {
        var d = try AuditSolution.document()
        d.pages["p3"] = ["objects": [["id": "i", "type": "image", "src": "/api/assets/f1/bild.png", "x": 0, "y": 0, "width": 10, "height": 10]]]
        let c = try AuditSolution.build(d, keys: ["p1", "p3"], name: "Mia")
        XCTAssertEqual(Set(c.json.object.map { Array($0.keys) } ?? []),
                       ["format", "formatVersion", "solutionId", "createdAt", "title", "displayName", "document", "pages", "images", "missingImages"])
        XCTAssertEqual(Set(c.json["document"]?.object.map { Array($0.keys) } ?? []), ["sha256", "pageCount"])
        XCTAssertEqual(c.missingImages, ["/api/assets/f1/bild.png"])
    }
}

// MARK: - 411-420 Formulare (APIClient.form baut den Inhalt mit MultipartBody)

final class AuditMultipartTests: XCTestCase {

    private func roundTrip(fields: [String: String], name: String, field: String = "upload", mime: String = "application/pdf") throws -> MultipartForm {
        let boundary = "uniflow-test"
        let body = MultipartBody.build(fields: fields, file: .init(field: field, name: name, mime: mime, data: Data("%PDF-1.7".utf8)), boundary: boundary)
        return try MultipartForm.parse(body, contentType: "multipart/form-data; boundary=" + boundary)
    }

    /// 413: Umlaute, Emoji, Semikolon, Gleichheitszeichen bleiben; Anfuehrungszeichen, Backslash (sonst verschwand er
    /// als Maskierung) und Zeilenumbrueche werden zu "_" und koennen keine Kopfzeile einschleusen
    func testFileNamesSurviveAndCannotInjectHeaders() throws {
        let cases: [(String, String)] = [
            ("Übungsblatt 3 – Lösung.pdf", "Übungsblatt 3 – Lösung.pdf"),
            ("Emoji 😀 ✓.pdf", "Emoji 😀 ✓.pdf"),
            ("semi;colon=1.pdf", "semi;colon=1.pdf"),
            ("a\"b.pdf", "a_b.pdf"),
            ("a\\b.pdf", "a_b.pdf"),
            ("x\r\nContent-Type: text/html\r\n\r\nboese.pdf", "x__Content-Type: text/html____boese.pdf"),
            ("tab\tnull\u{0}.pdf", "tab_null_.pdf"),
        ]
        for (name, expected) in cases {
            let form = try roundTrip(fields: ["kind": "pdf"], name: name)
            XCTAssertEqual(form.files.count, 1, name)
            XCTAssertEqual(form.files.first?.filename, expected, name)
            XCTAssertEqual(form.files.first?.contentType, "application/pdf", name)
            XCTAssertEqual(form.files.first?.data, Data("%PDF-1.7".utf8))
            XCTAssertEqual(form.fields, ["kind": "pdf"], name)
        }
    }

    /// 414: Feldname und Typ stammen aus dem Code, werden aber trotzdem bereinigt: kein zusaetzliches Feld, keine
    /// fremde Kopfzeile, ein ungueltiger Typ wird application/octet-stream
    func testFieldNameAndMimeAreSanitized() throws {
        let form = try roundTrip(fields: ["title\"; filename=\"x": "Wert\r\nmit Umbruch"], name: "a.pdf", field: "upload\r\nX: 1",
                                 mime: "application/pdf\r\nX-Boese: 1")
        XCTAssertEqual(form.files.count, 1)
        XCTAssertEqual(form.files.first?.field, "upload__X: 1")
        XCTAssertEqual(form.files.first?.contentType, "application/octet-stream")
        XCTAssertEqual(form.fields["title_; filename=_x"], "Wert\r\nmit Umbruch", "Werte stehen im Inhalt, nicht im Kopf")
        XCTAssertEqual(MultipartBody.mimeType("image/svg+xml"), "image/svg+xml")
        XCTAssertEqual(MultipartBody.mimeType("text/calendar"), "text/calendar")
        XCTAssertEqual(MultipartBody.mimeType("pdf"), "application/octet-stream")
    }
}

// MARK: - 431-438 Zusammenfuehrung

final class AuditMergeTests: XCTestCase {

    private func docJSON(_ order: [String], _ pages: [String: [String]], trash: [String] = []) -> JSONValue {
        var p: [String: JSONValue] = [:]
        for (k, ids) in pages { p[k] = ["objects": .array(ids.map { ["id": .string($0), "type": "stroke"] })] }
        var o: [String: JSONValue] = ["version": 2, "pages": .object(p),
                                      "pageOrder": .array(order.map { ["key": .string($0), "type": "blank", "template": "blank"] })]
        if !trash.isEmpty {
            o["deletedPages"] = .array(trash.map { k in ["entry": ["key": .string(k), "type": "blank"], "objects": p[k]?["objects"] ?? [], "pos": 1] })
        }
        return .object(o)
    }

    /// 431 (Vertrag): beidseitig verschieden geaendert -> dieses Geraet, ein Konflikt wird gezaehlt und angezeigt.
    /// Die verworfene Fassung steht im Versionsverlauf des Backends (30 Fassungen, `testAtMostThirtyVersionsAndRestore`),
    /// eine Konfliktkopie im Dokument waere eine Aenderung des gemeinsamen Vertrags.
    func testBothChangedSameObjectLocalWinsAndIsCounted() {
        let base = pageWith([stroke("a", x: 1)]), local = pageWith([stroke("a", x: 2)]), server = pageWith([stroke("a", x: 3)])
        let r = AnnotationMerge.mergePage(base: base, local: local, server: server)
        XCTAssertEqual(r.page?["objects"]?.array?.first?["points"], stroke("a", x: 2)["points"])
        XCTAssertEqual(r.conflicts, 1)
    }

    /// 432: ohne Kennung zaehlt der Inhalt; eine kleine Aenderung ist ein neues Objekt. Dabei geht nichts verloren
    /// (hoechstens stehen beide Fassungen da); Apple und Web vergeben jedem Objekt eine Kennung
    func testObjectsWithoutIDNeverGetLost() {
        let x: JSONValue = ["type": "shape", "w": 1], xHere: JSONValue = ["type": "shape", "w": 2], xThere: JSONValue = ["type": "shape", "w": 3]
        let r = AnnotationMerge.mergePage(base: pageWith([x]), local: pageWith([xHere, stroke("l")]), server: pageWith([xThere, stroke("s")]))
        let objs = r.page?["objects"]?.array ?? []
        XCTAssertTrue(objs.contains(xHere))
        XCTAssertTrue(objs.contains(xThere))
        XCTAssertEqual(ids(objs), ["s", "l"])
    }

    /// 433 (Vertrag offen): zwei Objekte mit derselben Kennung fallen beim Zusammenfuehren zusammen (Index "letzter
    /// gewinnt", Ausgabe "erster gewinnt", gleich in merge.js und Kotlin). Erkennen und melden waere eine Aenderung des
    /// gemeinsamen Vertrags (docs/PRUEFPUNKTE-WINDOWS-ANDROID-571-681.md, "Benoetigte Entscheidungen" 1).
    func testDuplicateIDsCollapseAsInTheSharedContract() {
        let one: JSONValue = ["id": "d", "type": "text", "text": "eins"], two: JSONValue = ["id": "d", "type": "text", "text": "zwei"]
        let r = AnnotationMerge.mergePage(base: pageWith([]), local: pageWith([one, two]), server: pageWith([stroke("s")]))
        XCTExpectFailure("Vertrag offen (Pruefbericht 433): doppelte IDs fallen zusammen, Entscheidung mit der PC-Sitzung") {
            XCTAssertEqual(r.page?["objects"]?.array?.count, 3, "beide Objekte mit Kennung d und der Strich des Servers")
        }
        XCTAssertEqual(r.page?["objects"]?.array?.count, 2, "heutiger Stand des Vertrags")
    }

    /// 434: Ebenen: gemeinsame Objekte in der Reihenfolge des Servers (kein Client sortiert Objekte um: weder Web noch
    /// iPad haben "nach vorne/hinten"), neue des Servers, dann neue dieses Geraets obenauf; beide Geraete enden nach
    /// dem Abgleich mit derselben Reihenfolge
    func testLayerOrderConvergesOnBothDevices() async {
        let server = MockServer(), storeB = MemoryBlobStore()
        let a = makeEngine(server, MemoryBlobStore()), b = makeEngine(server, storeB)
        _ = await a.open(pdfPageCount: 1)
        await a.updatePage("p1", page(["unten", "mitte"]))
        await a.syncNow()
        _ = await b.open(pdfPageCount: 1)
        await b.updatePage("p1", page(["unten", "mitte", "b-oben"]))
        await b.syncNow()
        await a.updatePage("p1", page(["unten", "mitte", "a-oben"]))      // A kennt B's Strich noch nicht
        await a.syncNow()
        await b.shutdown()
        let b2 = makeEngine(server, storeB)                                   // B oeffnet das Dokument erneut
        _ = await b2.open(pdfPageCount: 1)
        let onA = await a.page("p1")?["objects"]?.array.map(ids), onB = await b2.page("p1")?["objects"]?.array.map(ids)
        XCTAssertEqual(onA, ["unten", "mitte", "b-oben", "a-oben"])
        XCTAssertEqual(onB, onA)
        let onServer = await server.objectIDs(page: "p1")
        XCTAssertEqual(onServer, onA)
    }

    /// 436: Loeschen gegen Verschieben: die geloeschte Seite kommt nicht zurueck, egal wer was getan hat; hat die
    /// andere Seite sie inhaltlich geaendert, bleibt sie (Notizen gehen vor)
    func testDeleteAgainstMoveNeverResurrects() {
        let base = docJSON(["p1", "p2", "p3"], ["p1": ["a"], "p2": ["b"], "p3": ["c"]])
        let deletedHere = docJSON(["p1", "p3"], ["p1": ["a"], "p2": ["b"], "p3": ["c"]], trash: ["p2"])
        let movedThere = docJSON(["p3", "p1", "p2"], ["p1": ["a"], "p2": ["b"], "p3": ["c"]])
        for (local, server) in [(deletedHere, movedThere), (movedThere, deletedHere)] {
            let r = AnnotationMerge.mergeDocument(base: base, local: local, server: server)
            XCTAssertEqual(AnnotationMerge.orderKeys(r.doc).filter { $0 == "p2" }, [], "geloescht bleibt geloescht")
            XCTAssertEqual(Set(AnnotationMerge.orderKeys(r.doc)), ["p1", "p3"])
            XCTAssertEqual(AnnotationMerge.mergeTrash(local: r.doc, server: nil, keys: []).compactMap(AnnotationMerge.keyOf), ["p2"], "im Papierkorb")
        }
        let movedAndWritten = docJSON(["p3", "p1", "p2"], ["p1": ["a"], "p2": ["b", "neu"], "p3": ["c"]])
        let r = AnnotationMerge.mergeDocument(base: base, local: deletedHere, server: movedAndWritten)
        XCTAssertTrue(AnnotationMerge.orderKeys(r.doc).contains("p2"), "dort geaendert: bleibt")
        XCTAssertEqual(ids(r.doc["pages"]?["p2"]?["objects"]?.array ?? []), ["b", "neu"])
    }

    /// 437: Seite in der Reihenfolge ohne Inhalt in `pages`: die Reparatur nimmt nur Inhalt mit demselben Schluessel
    /// (hier, sonst dort), sonst eine leere Seite; nie den Inhalt einer anderen Seite
    func testRepairOfMissingPageContentNeverTakesForeignContent() throws {
        var server = docJSON(["p1", "bX", "bY"], ["p1": ["a"]])          // Server: bX und bY ohne Inhalt
        server["pages"]?["bZ"] = ["objects": [["id": "fremd", "type": "stroke"]]]
        let local = docJSON(["p1", "bX"], ["p1": ["a"], "bX": ["x"]])
        let r = AnnotationMerge.mergeDocument(base: docJSON(["p1"], ["p1": ["a"]]), local: local, server: server)
        XCTAssertEqual(ids(r.doc["pages"]?["bX"]?["objects"]?.array ?? []), ["x"])
        XCTAssertEqual(r.doc["pages"]?["bY"]?["objects"], [], "leer statt fremd")
        XCTAssertFalse(String(decoding: (r.doc["pages"]?["bY"] ?? .null).serialized(), as: UTF8.self).contains("fremd"))
    }
}

// MARK: - 439, 440 und Tiefentest C: Synchronisierung

final class AuditSyncTests: XCTestCase {

    /// 440: Entfernen einer alten Vergleichsbasis scheitert (Fehler wird bewusst nicht gemeldet). Nach einem Neustart
    /// liegt die alte Basis noch da; sie wird nie benutzt, weil die erste Aenderung danach eine neue Basis schreibt:
    /// eine im Browser geloeschte Notiz kommt nicht zurueck.
    func testLeftoverBaseFileIsNeverUsedAfterRestart() async {
        let server = MockServer(), store = MemoryBlobStore()
        let first = makeEngine(server, store)
        _ = await first.open(pdfPageCount: 1)
        await first.updatePage("p1", page(["a"]))
        await first.syncNow()
        store.setFailRemoves(prefix: "docs/doc1/base/", true)
        await first.updatePage("p1", page(["a", "x"]))                  // Basis [a] geschrieben ...
        await first.syncNow()                                             // ... bestaetigt, Entfernen scheitert
        let leftover = store.paths.filter { $0.hasPrefix("docs/doc1/base/") }
        XCTAssertEqual(leftover.count, 1, "alte Basis [a] liegt noch da")
        let status = await first.status
        XCTAssertEqual(status, .saved, "kein Fehler fuer den Nutzer: harmlos")
        await first.shutdown()
        store.setFailRemoves(prefix: "docs/doc1/base/", false)

        let restarted = makeEngine(server, store)                         // laedt die alte Basis [a] mit
        _ = await restarted.open(pdfPageCount: 1)
        await server.externalEdit { $0.pages["p1"] = page(["a"]) }       // danach loescht der Browser x
        await restarted.updatePage("p1", page(["a", "x", "neu"]))         // hier: neuer Strich auf [a, x]
        await restarted.syncNow()                                          // 409 -> zusammenfuehren
        let ids = await server.objectIDs(page: "p1")
        // mit der alten Basis [a] saehe x wie neu auf diesem Geraet aus und kaeme zurueck
        XCTAssertEqual(ids, ["a", "neu"], "Basis ist [a, x] (erste Aenderung schreibt sie neu): x bleibt geloescht")
    }

    /// Tiefentest C: Verbindungsabbruch nach erfolgreicher Speicherung auf dem Server: der naechste Versuch bekommt
    /// 409, fuehrt mit dem eigenen schon gespeicherten Stand zusammen und legt nichts doppelt an
    func testLostResponseAfterServerSavedDoesNotDuplicate() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 1)
        await server.loseNextPutResponse()
        await engine.updatePage("p1", page(["a", "b"]))
        await engine.syncNow()
        let saved = await waitUntil(timeout: 5) { await engine.status == .saved }
        XCTAssertTrue(saved)
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a", "b"])
        let stats = await engine.stats
        XCTAssertEqual(stats.mergedConflicts, 0)
        XCTAssertGreaterThanOrEqual(stats.puts, 2, "zweiter Versuch nach dem Abbruch")
        let version = await server.version
        XCTAssertEqual(version, 1, "auf dem Server genau einmal gespeichert (der zweite Versuch bekam 409)")
    }

    /// Tiefentest C: wiederholte 409 (anderes Geraet speichert staendig): nach sechs Runden haelt die Synchronisierung
    /// mit sichtbarem Grund an, die Notizen bleiben im Journal und gehen beim naechsten Versuch hoch
    func testRepeatedConflictsStopVisiblyAndKeepNotes() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 1)
        await engine.updatePage("p1", page(["a"]))
        await engine.syncNow()
        await server.setConflictStorm(20)
        await engine.updatePage("p1", page(["a", "b"]))
        await engine.syncNow()
        let status = await engine.status
        guard case .conflictUnresolved(let reason) = status else { return XCTFail("erwartet conflictUnresolved, war \(status)") }
        XCTAssertTrue(reason.contains("ändert sich ständig"))
        XCTAssertTrue(status.isSafeLocally)
        let unsent = await engine.unsentPageKeys
        XCTAssertEqual(unsent, ["p1"])
        await engine.shutdown()
        let reopened = makeEngine(server, store)
        let r = await reopened.open(pdfPageCount: 1)
        XCTAssertEqual(r.document.objects(page: "p1").compactMap { $0["id"]?.string }, ["a", "b"], "im Journal")
        await server.setConflictStorm(0)
        await reopened.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a", "b"])
    }
}
