import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Korrekturvorschlag (03.11.2026): Senden, Liste unter der Loesung, Posteingang des Erstellers, Zuruecknehmen,
/// Sperren und Bann ueber `CloudKitCommunityService` gegen das nachgebaute CloudKit; Korrektur-Modus im Editor, der
/// die eigenen Notizen nicht anfasst, und die Anzeige einer empfangenen Korrektur.
@MainActor
final class CommunityCorrectionAppTests: XCTestCase {
    typealias FakeCloud = CommunityCloudKitTests.FakeCommunityCloud
    let cipher = CryptoKitSolutionCipher()
    let space = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Lineare Algebra")

    // MARK: Hilfen

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-correction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func suite() -> UserDefaults {
        let name = "uniflow.tests.correction.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func makePDFData() -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...2 {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Blatt – Seite \(i)".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func ownDocument() throws -> AnnotationDocument {
        AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2}],
         "pages":{"p1":{"objects":[{"id":"s1","type":"stroke","tool":"pen","color":"#000000","width":4,"points":[10,10,50,50]}]},
                  "p2":{"objects":[]}}}
        """#))
    }

    /// Mitglied der Kurs-Community; `cloud.user` ist danach dieser Nutzer
    private func member(_ cloud: FakeCloud, _ user: String, pseudonym: String = "", membership: CommunityMembership? = nil) -> CloudKitCommunityService {
        cloud.user = user
        let space = self.space
        return CloudKitCommunityService(cloud: cloud, university: .luh, membership: membership ?? CommunityMembership(defaults: suite()),
                                        courseKeys: { [space.key] }, courses: { [space] }, pseudonym: { pseudonym })
    }

    private func publish(_ cloud: FakeCloud) async throws -> String {
        let lea = member(cloud, "_user-ada", pseudonym: "Lea")
        let pdf = makePDFData()
        let src = SolutionSource(document: try ownDocument(), originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                                 images: [:], title: "Übungsblatt 3")
        let options = CommunityPublishOptions(visibility: .module, courseKey: space.key, title: "Übungsblatt 3", communityKey: space.key)
        return try await SolutionSharing.publishToCommunity(src, keys: ["p1"], displayName: "Lea", options: options, space: space,
                                                            service: lea, library: SolutionLibrary(root: try tempDir())).solutionID
    }

    static let strokeJSON: JSONValue = .object(["id": .string("k1"), "type": .string("stroke"), "tool": .string("pen"),
                                                "color": .string("#ff3b30"), "width": .number(3),
                                                "points": .array([100, 100, 160, 120, 220, 180].map { .number($0) })])

    private func correction(_ sid: String, note: String = "Vorzeichen in 2b prüfen") -> CommunityCorrection {
        CommunityCorrection(targetSolutionID: sid, pseudonym: "", note: note,
                            pages: [.init(pdfIndex: 1, width: 595, height: 842, strokes: [Self.strokeJSON],
                                          notes: [.init(x: 0.3, y: 0.4, text: "hier fehlt ein Minus")])])
    }

    private func expect(_ expected: CommunityServiceError, _ body: () async throws -> Void, line: UInt = #line) async {
        do { try await body(); XCTFail("kein Fehler", line: line) } catch {
            XCTAssertEqual(error as? CommunityServiceError, expected, "\(error)", line: line)
        }
    }

    // MARK: CloudKit

    func testSendListInboxIgnoreAndDeleteOverCloudKit() async throws {
        let cloud = FakeCloud(assetDir: try tempDir())
        let sid = try await publish(cloud)
        let solutionBefore = cloud.all(CommunityRecordType.solution)

        // Ben korrigiert Leas Loesung
        let ben = member(cloud, "_user-ben", pseudonym: "Ben")
        XCTAssertTrue(ben.supportsCorrections)
        let sent = try await ben.sendCorrection(correction(sid))
        XCTAssertEqual(sent.pseudonym, "Ben")
        XCTAssertTrue(sent.isMine)
        XCTAssertEqual(sent.targetSolutionID, sid)

        // beim Dienst: Ziel, Ersteller der Loesung, nur Chiffrat; die Loesung selbst unveraendert
        let stored = try XCTUnwrap(cloud.all(CommunityRecordType.correction).first)
        XCTAssertEqual(stored.name, sent.id)
        XCTAssertEqual(stored["solutionID"]?.string, sid)
        XCTAssertEqual(stored["solutionOwner"]?.string, "_user-ada")
        let raw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(stored["payload"]?.string)))
        for plain in ["Vorzeichen", "Ben", "Minus", "stroke"] { XCTAssertNil(raw.range(of: Data(plain.utf8)), plain) }
        XCTAssertEqual(cloud.all(CommunityRecordType.solution), solutionBefore, "die Loesung bleibt unveraendert")

        // andere Mitglieder sehen die Korrektur unter der Loesung
        let mia = member(cloud, "_user-mia")
        let seen = try await mia.corrections(solutionID: sid)
        XCTAssertEqual(seen.map(\.id), [sent.id])
        XCTAssertEqual(seen.first?.note, "Vorzeichen in 2b prüfen")
        XCTAssertEqual(seen.first?.pages.first?.notes.first?.text, "hier fehlt ein Minus")
        XCTAssertEqual(seen.first?.isMine, false)
        XCTAssertEqual(seen.first?.isForMe, false)
        let miaInbox = try await mia.correctionsForMyOwnSolutions()
        XCTAssertEqual(miaInbox, [])

        // Lea: Posteingang mit Hinweis, Ignorieren nur lokal
        let leaMembership = CommunityMembership(defaults: suite())
        let lea = member(cloud, "_user-ada", pseudonym: "Lea", membership: leaMembership)
        let inbox = try await lea.correctionsForMyOwnSolutions()
        XCTAssertEqual(inbox.map(\.id), [sent.id])
        XCTAssertEqual(inbox.first?.inboxMessage, "Deine Lösung hat einen Korrekturhinweis von Ben bekommen")
        XCTAssertEqual(CommunityCorrections.openInbox(inbox).count, 1)
        lea.setCorrectionStatus(.ignored, id: sent.id)
        let afterIgnore = try await lea.correctionsForMyOwnSolutions()
        XCTAssertEqual(afterIgnore.first?.status, .ignored)
        XCTAssertEqual(CommunityCorrections.openInbox(afterIgnore), [])
        cloud.user = "_user-mia"
        let miaAgain = try await mia.corrections(solutionID: sid)
        XCTAssertEqual(miaAgain.first?.status, .open, "Ignorieren gilt nur bei Lea")

        // die eigene Loesung korrigiert man nicht, fremde Korrekturen nimmt nur der Verfasser zurueck
        cloud.user = "_user-ada"
        await expect(.service("Die eigene Lösung änderst du direkt im Dokument.")) { _ = try await lea.sendCorrection(self.correction(sid)) }
        await expect(.service("Nur der Verfasser kann seine Korrektur zurücknehmen.")) { try await lea.deleteCorrection(id: sent.id) }
        await expect(.service("Die Korrektur ist leer: markiere etwas oder schreibe eine Notiz.")) {
            cloud.user = "_user-ben"
            _ = try await ben.sendCorrection(CommunityCorrection(targetSolutionID: sid, pseudonym: ""))
        }

        // Ben nimmt seine Korrektur zurueck
        cloud.user = "_user-ben"
        try await ben.deleteCorrection(id: sent.id)
        XCTAssertEqual(cloud.all(CommunityRecordType.correction), [])
        cloud.user = "_user-ada"
        let emptyInbox = try await lea.correctionsForMyOwnSolutions()
        XCTAssertEqual(emptyInbox, [])
    }

    func testBlockedBannedForgedAndOutsiders() async throws {
        let cloud = FakeCloud(assetDir: try tempDir())
        let sid = try await publish(cloud)
        let mallory = member(cloud, "_user-mallory", pseudonym: "M")
        let m = try await mallory.sendCorrection(correction(sid, note: "Spam"))
        let ben = member(cloud, "_user-ben", pseudonym: "Ben")
        let b = try await ben.sendCorrection(correction(sid, note: "Hilfreich"))

        // Lea sperrt Mallory: seine Korrektur verschwindet bei ihr (Posteingang und Liste)
        let lea = member(cloud, "_user-ada", membership: CommunityMembership(defaults: suite()))
        try await lea.block(owner: "_user-mallory")
        let inbox = try await lea.correctionsForMyOwnSolutions()
        XCTAssertEqual(inbox.map(\.id), [b.id])
        let list = try await lea.corrections(solutionID: sid)
        XCTAssertEqual(list.map(\.id), [b.id])

        // vom Inhaber gesperrt (Ban): kann nichts mehr schicken, seine Korrekturen sieht niemand
        cloud.records["pub|\(CommunityRecordType.ban)|ban-1"] = CommunityRecord(type: CommunityRecordType.ban, name: "ban-1",
                                                                                 fields: ["ownerRecordName": .string("_user-mallory")],
                                                                                 creator: "_owner")
        let banned = member(cloud, "_user-mallory", pseudonym: "M")
        await expect(.service("Dein Konto darf keine Korrekturen mehr schicken.")) { _ = try await banned.sendCorrection(self.correction(sid)) }
        let mia = member(cloud, "_user-mia")
        let miaList = try await mia.corrections(solutionID: sid)
        XCTAssertEqual(miaList.map(\.id), [b.id])
        XCTAssertFalse(miaList.contains { $0.id == m.id })

        // umgelenkter Posteingang: `solutionOwner` setzt der Absender, zaehlt aber nur fuer die eigene Loesung
        let forged = CommunityCorrection(targetSolutionID: sid, pseudonym: "X", note: "an die Falsche")
        var record = CommunityRecord(type: CommunityRecordType.correction, name: forged.id)
        record["solutionID"] = .string(sid)
        record["solutionOwner"] = .string("_user-mia")
        record["payload"] = .string(try CommunityCorrections.seal(forged, communitySecret: try XCTUnwrap(space.secret), cipher: cipher))
        record["createdAt"] = .string("2026-11-03T12:00:00Z")
        cloud.user = "_user-ben"
        try await cloud.save(record, in: .publicDB)
        cloud.user = "_user-mia"
        let miaInbox = try await mia.correctionsForMyOwnSolutions()
        XCTAssertEqual(miaInbox, [], "fremde Loesung landet nicht im Posteingang")

        // Chiffrat unter eine andere Korrektur-ID gehaengt: nicht lesbar, faellt weg
        var moved = record
        moved.name = UUID().uuidString.lowercased()
        cloud.user = "_user-ben"
        try await cloud.save(moved, in: .publicDB)
        cloud.user = "_user-mia"
        let afterMove = try await mia.corrections(solutionID: sid)
        XCTAssertFalse(afterMove.contains { $0.id == moved.name })

        // ohne die Community (andere Kurse): nichts sehen, nichts schicken
        cloud.user = "_user-fremd"
        let outsider = CloudKitCommunityService(cloud: cloud, university: .luh, membership: CommunityMembership(defaults: suite()),
                                                courseKeys: { [] }, courses: { [] })
        await expect(.notFound) { _ = try await outsider.corrections(solutionID: sid) }
        await expect(.notFound) { _ = try await outsider.sendCorrection(self.correction(sid)) }

        // ohne Container und im Kern: nicht verbunden
        let none = CloudKitCommunityService(cloud: nil, university: .luh, membership: CommunityMembership(defaults: suite()), courseKeys: { [] })
        await expect(.unavailable) { _ = try await none.corrections(solutionID: sid) }
        let core = NotConnectedCommunityService()
        XCTAssertFalse(core.supportsCorrections)
        await expect(.notConnected) { _ = try await core.sendCorrection(self.correction(sid)) }
    }

    // MARK: Editor

    private func makeStore(pdf: Data) async throws -> DocumentStore {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-03T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "korrektur-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-11-03", has_notes: nil, page_count: 2, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return store
    }

    private func targetLayer() -> ForeignSolutionLayer {
        ForeignSolutionLayer(id: "sol-ziel", displayName: "Lea", createdAt: "2026-11-02T10:00:00Z", visible: true,
                             pages: [SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0,
                                                  objects: [Self.strokeJSON])],
                             images: [:], missingImages: 0)
    }

    func testCorrectionModeKeepsOwnNotesUntouchedAndKeepsDraft() async throws {
        let store = try await makeStore(pdf: makePDFData())
        await store.addText("Meine Notiz", pageKey: "p1")
        await store.flush()
        let before = await store.pageStructureDocument().root.serialized(sortedKeys: true)
        let ownBefore = await store.drawing(forPageKey: "p1")

        let drafts = CommunityCorrectionDraftStore(directory: try tempDir())
        let layer = targetLayer()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        editor.foreignLayers = [layer]
        editor.ownNotesVisible = false
        let session = CorrectionSession(target: layer, drafts: drafts)
        editor.correction = session
        XCTAssertTrue(editor.pickerAllowed)

        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        let cv = try XCTUnwrap(overlay.correctionView, "Korrektur-Zeichenflaeche auf der PDF-Seite")
        XCTAssertTrue(cv.editable)
        XCTAssertTrue(store.ownNotesReadOnly, "eigene Notizen nur lesbar")
        XCTAssertFalse(overlay.canvas.isUserInteractionEnabled)
        XCTAssertEqual(overlay.foreignLayerViews.map(\.solutionID), ["sol-ziel"])
        XCTAssertEqual(cv.info, CorrectionPageInfo(pdfIndex: 1, width: 595, height: 842, rotation: 0))

        // zeichnen und eine Randnotiz setzen
        let pk = ForeignLayerView.drawing([Self.strokeJSON])
        cv.ink.drawing = pk
        if session.draft.strokeCount == 0 { cv.canvasViewDrawingDidChange(cv.ink) }
        XCTAssertEqual(session.draft.strokeCount, 1)
        session.placingNote = true
        XCTAssertTrue(cv.isPlacing)
        XCTAssertFalse(cv.ink.isUserInteractionEnabled)
        session.addNote(x: 0.5, y: 0.25, text: "  Randnotiz  ", on: cv.info)
        XCTAssertEqual(cv.pins.subviews.count, 1)
        XCTAssertEqual(session.draft.pages.first?.notes.first?.text, "Randnotiz")
        XCTAssertTrue(session.canSend)

        // eigene Notizen unveraendert (Modell und Striche)
        await store.flush()
        let after = await store.pageStructureDocument().root.serialized(sortedKeys: true)
        XCTAssertEqual(after, before)
        let ownAfter = await store.drawing(forPageKey: "p1")
        XCTAssertEqual(ownAfter.strokes.count, ownBefore.strokes.count)

        // Entwurf bleibt: Modus verlassen, neu oeffnen -> dieselben Striche und Notizen
        session.saveNow()
        editor.correction = nil
        XCTAssertNil(overlay.correctionView)
        let resumed = CorrectionSession(target: layer, drafts: drafts)
        XCTAssertEqual(resumed.draft.strokeCount, 1)
        XCTAssertEqual(resumed.draft.noteCount, 1)
        editor.correction = resumed
        XCTAssertEqual(overlay.correctionView?.ink.drawing.strokes.count, 1)
        XCTAssertEqual(overlay.correctionView?.pins.subviews.count, 1)

        // Verwerfen loescht den Entwurf
        resumed.discard()
        XCTAssertNil(drafts.load(solutionID: layer.id))
        editor.correction = nil
        await store.close()
    }

    func testReceivedCorrectionIsShownAsTintedOverlayWithPins() async throws {
        let store = try await makeStore(pdf: makePDFData())
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        var c = correction("sol-ziel")
        c.author = "_user-ben"
        editor.shownCorrection = c
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        let cv = try XCTUnwrap(overlay.correctionView)
        XCTAssertFalse(cv.editable)
        XCTAssertEqual(cv.ink.drawing.strokes.count, 1)
        XCTAssertEqual(cv.pins.subviews.count, 1)
        XCTAssertNil(try XCTUnwrap(editor.overlayForTesting(at: 1)).correctionView, "Seite 2 hat keine Korrektur")
        // Tinte in der Warnfarbe, Eingabe nur auf den Nadeln (eigene Notizen bleiben schreibbar)
        let warn = UIColor(UF.warn).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).uniflowRGBA.0
        XCTAssertEqual(cv.ink.drawing.strokes.first?.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).uniflowRGBA.0, warn)
        XCTAssertNil(cv.hitTest(CGPoint(x: 5, y: 5), with: nil))
        let pin = try XCTUnwrap(cv.pins.subviews.first)
        XCTAssertNotNil(cv.hitTest(pin.center, with: nil))
        XCTAssertTrue(editor.ownNotesVisible)
        XCTAssertFalse(store.ownNotesReadOnly)
        var opened: CorrectionNoteEvent?
        editor.onCorrectionNote = { opened = $0 }
        (pin as? UIButton)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(opened, .open(noteID: c.pages[0].notes[0].id))
        editor.shownCorrection = nil
        XCTAssertNil(overlay.correctionView)
        await store.close()
    }

    func testPageInfoMapsNotesAcrossRotation() {
        let page = CommunityCorrection.Page(pdfIndex: 1, width: 600, height: 800, rotation: 0,
                                            notes: [.init(id: "n", x: 0.25, y: 0.5, text: "x")])
        let same = CorrectionPageInfo(pdfIndex: 1, width: 600, height: 800, rotation: 0)
        XCTAssertEqual(same.point(page.notes[0], on: page), CGPoint(x: 150, y: 400))
        let turned = CorrectionPageInfo(pdfIndex: 1, width: 600, height: 800, rotation: 90)
        XCTAssertEqual(turned.displaySize, CGSize(width: 800, height: 600))
        let p = turned.point(page.notes[0], on: page)
        XCTAssertTrue((0...800).contains(p.x) && (0...600).contains(p.y), "\(p)")
        // hin und zurueck gleich
        let back = same.mapping(from: 90)
        let q = p.applying(back)
        XCTAssertEqual(q.x, 150, accuracy: 0.001)
        XCTAssertEqual(q.y, 400, accuracy: 0.001)
    }
}
