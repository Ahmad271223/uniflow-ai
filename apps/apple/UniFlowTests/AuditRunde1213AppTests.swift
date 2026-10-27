import PDFKit
import PencilKit
import XCTest
import UniFlowCore
@testable import UniFlow

// Externer Pruefbericht, Apple-Runden 12 und 13: Teile in der App (APIClient, Notizen-Transport, Anzeige, Teilen).
// Kernteile in UniFlowCoreTests (`AuditRunde1213Tests`, `StudIPScheduleIntegrityTests`); Ergebnis:
// docs/audit/RUNDE-12-13-381-440.md.

/// Antworten je Pfad (ohne Abfrage), merkt sich jede Anfrage mit Methode, Pfad und Inhalt
private final class ScriptedTransport: APITransport, @unchecked Sendable {
    struct Sent { let method: String; let url: URL; let body: Data? }
    private let lock = NSLock()
    private var sent: [Sent] = []
    private let reply: @Sendable (String, URL) -> (Int, Data)

    init(_ reply: @escaping @Sendable (String, URL) -> (Int, Data)) { self.reply = reply }

    var requests: [Sent] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        lock.withLock { sent.append(Sent(method: request.httpMethod ?? "GET", url: url, body: request.httpBody)) }
        let (status, body) = reply(request.httpMethod ?? "GET", url)
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}

private func json(_ s: String) -> Data { Data(s.utf8) }

final class AuditRunde1213AppTests: XCTestCase {
    private let server = URL(string: "https://server.test/")!

    // MARK: 411 Pfade nur unter /api/ derselben Quelle

    /// 411 (Fehler belegt): `src` eines Bildobjekts aus fremden Notizen wie `//anderer.host/x.png` passierte die
    /// Pruefung `hasPrefix("/")` und wurde gegen einen fremden Host aufgeloest, beim eigenen Server mit der PIN als
    /// Cookie. Jetzt erreicht so eine Anfrage den Transport gar nicht.
    func testOnlyPathsBelowApiOfTheSameOriginAreRequested() async throws {
        let t = ScriptedTransport { _, _ in (200, json("{}")) }
        let api = APIClient(base: server, transport: t)
        for bad in ["//anderer.test/x.png", "https://anderer.test/api/x", "http://server.test/api/x", "https://server.test:8443/api/x",
                    "/static/app.js", "/api/../geheim", "https://nutzer@server.test/api/x", "../x"] {
            do {
                _ = try await api.data(bad)
                XCTFail("darf nicht angefragt werden: \(bad)")
            } catch let e as APIError {
                XCTAssertEqual(e.status, -1, bad)
            }
        }
        XCTAssertTrue(t.requests.isEmpty, "\(t.requests.map(\.url))")
        _ = try await api.data("/api/files/f1/content")
        _ = try await api.data("/api/search?q=C%2B%2B")
        XCTAssertEqual(t.requests.map(\.url.absoluteString), ["https://server.test/api/files/f1/content", "https://server.test/api/search?q=C%2B%2B"])
        // lokales Backend: gleiche Regel
        XCTAssertNotNil(APIClient.url("/api/dashboard", base: APIClient.localBase))
        XCTAssertNil(APIClient.url("//device/api/x", base: URL(string: "https://server.test/")!))
        XCTAssertNil(APIClient.url("uniflow-local://anderes/api/x", base: APIClient.localBase))
    }

    // MARK: 416, 417 Antworten des Formulars und Fehlermeldungen

    /// 416 (behoben): erfolgreiche Antwort ohne Inhalt ist kein Lesefehler (sonst "fehlgeschlagen" trotz Speicherung)
    func testEmptySuccessfulUploadAnswerIsNoError() async throws {
        let t = ScriptedTransport { _, _ in (204, Data()) }
        let r = try await APIClient(base: server, transport: t).form("/api/notebooks", fields: ["kind": "pdf"],
                                                                    file: ("upload", "a.pdf", "application/pdf", Data("%PDF".utf8)))
        XCTAssertEqual(r, .null)
        XCTAssertEqual(t.requests.count, 1, "kein zweiter Versuch")
    }

    /// 417 (behoben): "detail" wird aus dem ganzen Antworttext gelesen und erst danach gekuerzt; Pruefungsfehler (422)
    /// nennen ihre Meldungen; gekuerzt wird nur an ganzen Zeichen
    func testErrorDetailSurvivesLongAnswers() async throws {
        let long = String(repeating: "Ä", count: 450)
        let t = ScriptedTransport { _, url in
            if url.path.hasSuffix("/lang") { return (400, json(#"{"detail": "Datei zu groß: \#(long)"}"#)) }
            if url.path.hasSuffix("/liste") { return (422, json(#"{"detail": [{"loc": ["body", "title"], "msg": "Field required", "type": "missing"}, {"msg": "Input should be a valid integer"}]}"#)) }
            return (500, Data(String(repeating: "ö", count: 600).utf8))
        }
        let api = APIClient(base: server, transport: t)
        do { _ = try await api.value("/api/lang"); XCTFail() } catch let e as APIError {
            XCTAssertTrue(e.errorDescription?.hasPrefix("Datei zu groß: ÄÄÄ") ?? false, e.errorDescription ?? "")
            XCTAssertEqual(e.httpDetail, e.errorDescription)
            XCTAssertLessThanOrEqual(e.message.count, APIError.messageLimit)
        }
        do { _ = try await api.form("/api/liste", fields: [:]); XCTFail() } catch let e as APIError {
            XCTAssertEqual(e.errorDescription, "Field required; Input should be a valid integer")
        }
        do { _ = try await api.value("/api/kaputt"); XCTFail() } catch let e as APIError {
            XCTAssertEqual(e.message.count, APIError.messageLimit)
            XCTAssertTrue(e.message.allSatisfy { $0 == "ö" }, "kein halbes Zeichen am Ende")
            XCTAssertEqual(e.errorDescription, HTTPURLResponse.localizedString(forStatusCode: 500).capitalized)
        }
    }

    // MARK: 418-420 Versionsangaben beim Abgleich der Notizen

    /// 418, 419, 420 (behoben): fehlende Versionsnummer oder fehlender Serverstand ist eine unbrauchbare Antwort, kein
    /// "Version 0, leer", keine geratene Version und kein leerer Konfliktstand
    func testAnnotationAnswersWithoutVersionOrDataAreRejected() async throws {
        func transport(get: String, put: (Int, String)) -> HTTPAnnotationTransport {
            HTTPAnnotationTransport(api: APIClient(base: server, transport: ScriptedTransport { method, _ in
                method == "GET" ? (200, json(get)) : (put.0, json(put.1))
            }))
        }
        for get in [#"{"data": {"pages": {}}}"#, #"{"version": "3", "data": {}}"#, #"{"version": 2.5, "data": {}}"#,
                    #"{"version": 3}"#, #"{"version": 3, "data": null}"#, #"{"version": 3, "data": []}"#, ""] {
            do {
                _ = try await transport(get: get, put: (200, "{}")).fetch(documentID: "f1")
                XCTFail("ungueltig: \(get)")
            } catch let e as APIError {
                XCTAssertEqual(e.status, 502, get)
                XCTAssertEqual(SyncIssue.classify(e), .serverfehler(502), get)
            }
        }
        let ok = try await transport(get: #"{"data": {"version": 2, "pages": {}, "zoom": 1.2}, "updated_at": null, "version": 0}"#, put: (200, "{}"))
            .fetch(documentID: "f1")
        XCTAssertEqual(ok.version, 0, "wie app/server.py fuer ein Dokument ohne Notizen")
        for put in [(200, #"{"ok": true}"#), (200, ""), (200, #"{"version": 0}"#)] {
            do {
                _ = try await transport(get: "{}", put: put).put(documentID: "f1", root: AnnotationDocument.emptyRoot, baseVersion: 4)
                XCTFail("ungueltig: \(put)")
            } catch let e as APIError { XCTAssertEqual(e.status, 502) }
        }
        let saved = try await transport(get: "{}", put: (200, #"{"ok": true, "version": 9}"#)).put(documentID: "f1", root: .object([:]), baseVersion: 4)
        XCTAssertEqual(saved, .saved(version: 9), "die Version des Servers, nicht baseVersion + 1")
        for conflict in [#"{"detail": "Konflikt", "version": 5}"#, #"{"version": 5, "data": null}"#] {
            do {
                _ = try await transport(get: "{}", put: (409, conflict)).put(documentID: "f1", root: .object([:]), baseVersion: 4)
                XCTFail("ungueltig: \(conflict)")
            } catch let e as APIError { XCTAssertEqual(e.status, 502, conflict) }
        }
        // 409 ohne "version" bleibt "kann hier nicht speichern" mit der Meldung des Backends
        do {
            _ = try await transport(get: "{}", put: (409, #"{"detail": "Dieses Dokument gibt es auf diesem iPad nicht."}"#))
                .put(documentID: "f1", root: .object([:]), baseVersion: 4)
            XCTFail()
        } catch let e as APIError {
            XCTAssertEqual(SyncIssue.classify(e), .nichtVerfuegbar("Dieses Dokument gibt es auf diesem iPad nicht."))
        }
    }

    /// 420 (Fehler belegt, Ablauf): 409 mit Version, aber ohne Serverstand. Vorher wurde daraus ein leeres Dokument; die
    /// Zusammenfuehrung wertete jede hier unveraenderte Seite als "auf dem Server geloescht" und der naechste Upload
    /// enthielt sie nicht mehr. Jetzt: kein Upload ohne diese Seiten, die Notizen bleiben im Journal.
    func testIncompleteConflictAnswerNeverUploadsADocumentWithoutUnchangedPages() async throws {
        let stored = #"{"version": 2, "pages": {"p1": {"objects": [{"id": "alt", "type": "stroke"}]}, "p2": {"objects": []}}}"#
        let t = ScriptedTransport { method, _ in
            method == "GET" ? (200, json(#"{"version": 4, "data": \#(stored)}"#)) : (409, json(#"{"detail": "Konflikt", "version": 5}"#))
        }
        let engine = SyncEngine(documentID: "f1", transport: HTTPAnnotationTransport(api: APIClient(base: server, transport: t)),
                                journal: LocalJournal(store: MemoryBlobStore(), documentID: "f1"), uploadDelay: 0,
                                sleeper: { _ in try? await Task.sleep(nanoseconds: 30_000_000_000) })   // keine Wiederholung im Test
        _ = await engine.open(pdfPageCount: 2)
        await engine.updatePage("p2", ["objects": [["id": "neu", "type": "stroke"]]])
        await engine.syncNow()
        await engine.shutdown()
        let puts = t.requests.filter { $0.method == "PUT" }
        XCTAssertFalse(puts.isEmpty)
        for p in puts {
            let root = try JSONValue.parse(p.body ?? Data())
            XCTAssertEqual(root["pages"]?["p1"]?["objects"]?.array?.first?["id"], "alt", "jeder Upload enthaelt die unveraenderte Seite")
        }
        XCTAssertEqual(puts.count, 1, "nach der unbrauchbaren Antwort kein zweiter Upload auf leerem Stand")
        let issue = await engine.issue
        XCTAssertEqual(issue, .serverfehler(502))
        let doc = await engine.currentDocument()
        XCTAssertEqual(doc.objects(page: "p1").first?["id"], "alt")
        XCTAssertEqual(doc.objects(page: "p2").first?["id"], "neu")
    }

    // MARK: 400, 404 Anzeige

    /// 404: Leerseite mit ungueltiger Groesse: Editor und Loesungspaket nehmen dieselbe Groesse (`PageOrder.blankSize`)
    func testDisplayLayoutAndPackageUseTheSameBlankSize() throws {
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
            {"version": 2, "pageOrder": [{"key": "b0", "type": "blank", "template": "grid", "w": 0, "h": -1},
                                          {"key": "b1", "type": "blank", "template": "lined", "w": 1e999, "h": 500},
                                          {"key": "b2", "type": "blank", "template": "mm", "w": 3370, "h": 2384}],
             "pages": {"b0": {"objects": []}, "b1": {"objects": []}, "b2": {"objects": []}}}
            """#))
        let layout = DisplayLayout.build(original: PDFDocument(), document: doc)
        let sizes = (0..<3).compactMap { layout.pdf.page(at: $0)?.bounds(for: .cropBox).size }
        XCTAssertEqual(sizes, [CGSize(width: 595, height: 842), CGSize(width: 595, height: 500), CGSize(width: 3370, height: 2384)])
        for (i, entry) in doc.pageOrder.enumerated() {
            let s = PageOrder.blankSize(entry)
            XCTAssertEqual(CGSize(width: s.width, height: s.height), sizes[i])
        }
        XCTAssertFalse(PaperTemplate.layers(for: "lined", size: sizes[1]).isEmpty)
    }

    /// 400: eine wiederhergestellte Seite zeigt genau ihre Objekte: die gespeicherte native Zeichnung behaelt
    /// unveraenderte Striche, im Papierkorb-Zeitraum dazugekommene baut die Anzeige aus den Objekten auf
    func testRestoredPageDrawingMatchesItsObjects() throws {
        func stroke(_ y: CGFloat, _ t: TimeInterval) -> PKStroke {
            let pts = (0..<20).map { i in
                PKStrokePoint(location: CGPoint(x: 50 + CGFloat(i) * 3, y: y), timeOffset: Double(i) * 0.01,
                              size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: t)))
        }
        var drawing = PKDrawing()
        drawing.strokes.append(stroke(100, 800_000_000))
        let written = StrokeConverter.update(from: drawing, previous: ["objects": []], state: InkPageState()).page
        var doc = AnnotationDocument(root: ["version": 2, "pages": ["p1": ["objects": []], "p2": written],
                                            "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2]]])
        PageOrder.trash(&doc, key: "p2")
        // anderes Geraet hat vor dem Loeschen einen Strich ergaenzt (Zusammenfuehrung, siehe Kerntest)
        var other = PKDrawing()
        other.strokes = drawing.strokes + [stroke(200, 800_000_100)]
        let merged = StrokeConverter.update(from: other, previous: written, state: StrokeConverter.drawing(fromPage: written).1).page
        doc.pages["p2"]?["objects"] = merged["objects"]
        PageOrder.restore(&doc, key: "p2")
        let page = try XCTUnwrap(doc.page("p2"))
        XCTAssertEqual(page["objects"]?.array?.count, 2)
        let (shown, state) = StrokeConverter.drawing(fromPage: page)
        XCTAssertEqual(shown.strokes.count, 2, "beide Striche sichtbar")
        XCTAssertEqual(state.represented, Set((page["objects"]?.array ?? []).compactMap { $0["id"]?.string }))
    }

    // MARK: 403, 406, 407, 409 Teilen

    private func source(_ doc: AnnotationDocument) -> SolutionSource {
        let info = SolutionBuilder.PDFPageInfo(width: 595, height: 842, rotation: 0)
        return SolutionSource(document: doc, originalPDF: Data("%PDF-1.7 test".utf8), pdfPageCount: 2, pageInfos: [1: info, 2: info],
                              fingerprint: String(repeating: "b", count: 64), images: [:], title: "Blatt 3")
    }

    /// 403 (behoben): PDF-Seite, die es in der PDF nicht mehr gibt, sperrt den Dialog nicht mehr: sie steht als
    /// Seite mit Grund da, die anderen bleiben teilbar
    func testShareDraftNamesMissingPDFPageAndKeepsTheRest() throws {
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
            {"version": 2, "pageOrder": [{"key": "p1", "type": "pdf", "index": 1}, {"key": "p9", "type": "pdf", "index": 9}],
             "pages": {"p1": {"objects": [{"id": "a", "type": "stroke", "points": [0, 0, 5, 5]}]},
                       "p9": {"objects": [{"id": "z", "type": "stroke", "points": [0, 0, 5, 5]}]}}}
            """#))
        let draft = try SolutionSharing.draft(source(doc))
        XCTAssertEqual(draft.content?.pages.map(\.key), ["p1"])
        XCTAssertEqual(draft.problems.map(SolutionShareDraft.problemText),
                       ["PDF-Seite 9 lässt sich nicht teilen: Diese Seite gibt es in der PDF-Datei nicht (mehr), z. B. nach einer neuen Fassung mit weniger Seiten."])
        XCTAssertEqual(draft.selection, ["p1"])
        XCTAssertTrue(draft.canShare(draft.selection))
    }

    /// 406 (behoben): aeltere Striche ohne Objekt (`strokeIds` []) stehen nur in der nativen Zeichnung; vor dem Teilen
    /// bekommen sie Objekte, eine Seite nur mit solcher Handschrift ist Inhalt. Das Dokument selbst bleibt gleich.
    func testLegacyStrokesWithoutObjectsAreSharedAsObjects() throws {
        let pts = [PKStrokePoint(location: CGPoint(x: 52, y: 90), timeOffset: 0, size: CGSize(width: 3, height: 3),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)]
        var legacy = PKDrawing()
        legacy.strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: 800_000_000))))
        let page: JSONValue = ["objects": [],
                               "pkdrawing": StoredDrawing(data: legacy.dataRepresentation().base64EncodedString(), signature: "teilweise",
                                                          strokeIDs: [[]], strokeSignatures: [""]).json]
        let doc = AnnotationDocument(root: ["version": 2, "pages": ["p1": page], "pageOrder": [["key": "p1", "type": "pdf", "index": 1]]])
        XCTAssertThrowsError(try SolutionSharing.content(source(doc), keys: ["p1"], displayName: "")) {
            XCTAssertEqual($0 as? SolutionError, .noOwnNotes, "vorher: Handschrift sichtbar, aber kein Inhalt")
        }
        let upgraded = SolutionSharing.withObjectsForLegacyStrokes(doc)
        XCTAssertEqual(upgraded.objects(page: "p1").count, 1)
        XCTAssertEqual(upgraded.objects(page: "p1").first?["type"], "stroke")
        XCTAssertEqual(try SolutionSharing.content(source(upgraded), keys: ["p1"], displayName: "").objectCount, 1)
        XCTAssertEqual(doc.objects(page: "p1").count, 0, "eigenes Dokument unveraendert")
        let normal = AnnotationDocument(root: ["version": 2, "pages": ["p1": ["objects": [["id": "s", "type": "stroke", "points": [0, 0, 1, 1]]]]],
                                               "pageOrder": [["key": "p1", "type": "pdf", "index": 1]]])
        XCTAssertEqual(SolutionSharing.withObjectsForLegacyStrokes(normal).root, normal.root, "ohne alte Striche nichts angefasst")
    }

    /// 407, 409: Texte im Dialog: fehlende Bilder (auch in der Bestaetigung vor dem Veroeffentlichen) und was ausser
    /// den Notizen mitgeht
    func testShareDialogTextsNameMissingImagesAndMetadata() {
        XCTAssertEqual(SolutionTexts.missingImages(1), "1 Bild ist nicht verfügbar und fehlt in der Lösung.")
        XCTAssertEqual(SolutionTexts.missingImages(3), "3 Bilder sind nicht verfügbar und fehlen in der Lösung.")
        XCTAssertEqual(SolutionTexts.sentAlong(title: "Blatt 3"), "Mit der Lösung gehen außerdem der Titel „Blatt 3“ und der Zeitpunkt des Teilens mit.")
    }

    // MARK: 430 Teilerfolg im Stundenplan

    /// 430: ein Teilerfolg ist nie "vollstaendig": nicht lesbare Eintraege stehen in der Zusammenfassung, auch neben
    /// neuen Terminen und nach einem Abbruch
    func testPartialScheduleImportIsNeverShownAsComplete() {
        let ok = StudIPScheduleResult(newEvents: 3, pendingGroups: 0, cycles: 4, events: 9)
        XCTAssertEqual(StudIPScheduleSync.Outcome(result: ok, unreadable: 1).summary,
                       ["3 Stundenplan-Termine", "1 Stundenplan-Eintrag aus Stud.IP nicht lesbar"])
        XCTAssertEqual(StudIPScheduleSync.Outcome(result: ok, failedCourses: 2, unreadable: 4).summary,
                       ["3 Stundenplan-Termine", "Termine von 2 Kursen nicht geladen", "4 Stundenplan-Einträge aus Stud.IP nicht lesbar"])
        XCTAssertEqual(StudIPScheduleSync.Outcome(result: ok, unreachable: true, unreadable: 2).summary,
                       ["3 Stundenplan-Termine", "Stundenplan: Stud.IP nicht erreichbar", "2 Stundenplan-Einträge aus Stud.IP nicht lesbar"])
        XCTAssertEqual(StudIPScheduleSync.Outcome(result: ok).summary, ["3 Stundenplan-Termine"])
        XCTAssertEqual(StudIPScheduleSync.Outcome(result: nil, unreadable: 2).summary, ["Stundenplan nicht gespeichert"])
    }
}
