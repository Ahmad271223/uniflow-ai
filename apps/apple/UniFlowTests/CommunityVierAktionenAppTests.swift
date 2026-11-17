import PDFKit
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Auftrag des Inhabers 17.11.2026: "prüfe das Kommentare schreiben, ob das wirklich geht, und Diskussion starten und
/// Like und Antworten" – auf iPad, iPhone und Mac.
///
/// Jede der vier Aktionen laeuft hier vom Knopf bis zum Datensatz und zurueck in die Anzeige, bei mir und bei einer
/// zweiten Person: die echten Ansichten, der echte `CloudKitCommunityService` und darunter `ProductionLikeStore`, ein
/// Nachbau der oeffentlichen Datenbank, der nur annimmt, was das Schema der App (`Config/cloudkit-schema.ckdb`) in
/// Production erlaubt (Typen, Felder, Such-Indizes, Rechte). Ein Feld, das im Schema fehlt, oder eine Suche ohne Index
/// laesst diese Tests rot werden. Was sie nicht koennen: beweisen, dass genau dieses Schema bei Apple in Production liegt.
/// Nur erfundene Daten, kein Netz, kein iCloud-Konto.
@MainActor
final class CommunityVierAktionenAppTests: IPhoneLearnTestCase {
    let cipher = CryptoKitSolutionCipher()
    private var services: [String: CloudKitCommunityService] = [:]

    /// Modul-Community, der alle Testpersonen beigetreten sind
    private var space: CommunitySpace {
        var s = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Lineare Algebra")
        s.joined = true
        return s
    }

    /// Lage der Bildschirmtastatur (Bildschirmkoordinaten); `.null`, solange keine zu sehen war
    private final class KeyboardWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = CGRect.null
        private var token: NSObjectProtocol?
        var frame: CGRect { lock.withLock { value } }

        init() {
            token = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: nil) { [weak self] n in
                guard let self, let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                self.lock.withLock { self.value = end }
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    private var keyboard = KeyboardWatch()

    override func setUp() {
        super.setUp()
        keyboard = KeyboardWatch()
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before) }
    }

    /// iPhone: Eingabefeld und Senden-Knopf liegen ueber der Bildschirmtastatur, wenn eine zu sehen ist (iPhone-Simulator);
    /// sonst (iPad-Simulator mit schmalem Fenster, Tastatur des Mac angeschlossen) stehen sie unten fest
    private func assertComposerAboveKeyboard(_ env: HostedEnvironment, field label: String, send: String, file: StaticString = #filePath, line: UInt = #line) {
        env.pump(0.6)
        let field = frame(element(env, label: label)), button = frame(button(env, send))
        let kb = keyboard.frame
        if !kb.isNull, kb.height > 100, kb.minY < env.window.bounds.height - 1 {
            XCTAssertLessThanOrEqual(field.maxY, kb.minY + 1, "die Tastatur verdeckt das Feld „\(label)“ nicht: Feld \(field), Tastatur \(kb)", file: file, line: line)
            XCTAssertLessThanOrEqual(button.maxY, kb.minY + 1, "„\(send)“ liegt ueber der Tastatur: Knopf \(button), Tastatur \(kb)", file: file, line: line)
            XCTAssertGreaterThan(field.minY, 60, "das Feld ist nicht oben aus dem Bild geschoben: \(field)", file: file, line: line)
            print("TASTATUR sichtbar (\(label)): Feld \(field), Knopf \(button), Tastatur \(kb)")
        } else {
            XCTAssertGreaterThan(field.minY, Self.phone.height * 0.6, "Feld „\(label)“ unten fest: \(field)", file: file, line: line)
            print("TASTATUR nicht sichtbar (\(label)): Feld unten fest \(field)")
        }
    }

    // MARK: Hilfen

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-vier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func suite() -> UserDefaults {
        let name = "uniflow.tests.vier.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func store() throws -> ProductionLikeStore {
        ProductionLikeStore(schema: ProductionLikeStore.schema(), assetDir: try tempDir())
    }

    /// Geraet einer Person: eigener Zugang zur gemeinsamen Datenbank, eigene Mitgliedschaft (beigetreten), Pseudonym =
    /// Name. `user` nil = Geraet ohne iCloud-Konto.
    private func device(_ store: ProductionLikeStore, _ name: String, signedIn: Bool = true) async throws -> CloudKitCommunityService {
        let key = name + (signedIn ? "" : "-ohne-icloud")
        if let s = services[key] { return s }
        let space = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Lineare Algebra")
        let s = CloudKitCommunityService(cloud: store.device(signedIn ? "_user-" + name.lowercased() : nil), university: .luh,
                                         membership: CommunityMembership(defaults: suite()),
                                         courseKeys: { [space.key] }, courses: { [space] }, pseudonym: { name })
        try await s.join(space)
        services[key] = s
        return s
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

    /// Lea teilt eine Loesung in der Modul-Community; Ergebnis ist deren Kennung
    private func publish(_ store: ProductionLikeStore) async throws -> String {
        let lea = try await device(store, "Lea")
        let pdf = makePDFData()
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2}],
         "pages":{"p1":{"objects":[{"id":"s1","type":"stroke","tool":"pen","color":"#000000","width":4,"points":[10,10,50,50]}]},
                  "p2":{"objects":[]}}}
        """#))
        let src = SolutionSource(document: doc, originalPDF: pdf, pdf: PDFDocument(data: pdf)!, fingerprint: cipher.sha256Hex(pdf),
                                 images: [:], title: "Übungsblatt 3")
        let options = CommunityPublishOptions(visibility: .module, courseKey: space.key, title: "Übungsblatt 3", communityKey: space.key)
        return try await SolutionSharing.publishToCommunity(src, keys: ["p1"], displayName: "Lea", options: options, space: space,
                                                            service: lea, library: SolutionLibrary(root: try tempDir())).solutionID
    }

    private func expect(_ expected: CommunityServiceError, _ body: () async throws -> Void, line: UInt = #line) async {
        do { try await body(); XCTFail("kein Fehler", line: line) } catch {
            XCTAssertEqual(error as? CommunityServiceError, expected, "\(error)", line: line)
        }
    }

    /// Text wie mit der Tastatur in das letzte Eingabefeld des Fensters (TextField mit axis: .vertical ist eine UITextView)
    @discardableResult
    private func type(_ text: String, in env: HostedEnvironment) -> Bool {
        var fields: [UIView] = []
        func visit(_ v: UIView) {
            if v is UITextView || v is UITextField { fields.append(v); return }
            v.subviews.forEach(visit)
        }
        visit(env.window)
        guard let field = fields.last, let input = field as? UIKeyInput else { return false }
        _ = field.becomeFirstResponder()
        input.insertText(text)
        env.pump(0.3)
        return true
    }

    private enum Geraet: String, CaseIterable { case iPad, iPhone }

    private func host<V: View>(_ view: V, _ geraet: Geraet) throws -> HostedEnvironment {
        let api = remote(Canned())
        return geraet == .iPhone ? try hostPhone(view.environment(\.ufLearnCompact, true), api: api) : try hostPad(view, api: api)
    }

    /// Bild nach UF_SCREENSHOT_DIR nur hell (die Abnahme braucht keinen zweiten Satz)
    private func bild(_ env: HostedEnvironment, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        env.pump(0.4)
        let window = env.window
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// Knopf liegt ganz im Fenster und laesst sich antippen (nicht ausserhalb, nicht gesperrt)
    private func assertReachable(_ env: HostedEnvironment, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let b = button(env, label) else { return XCTFail("Knopf „\(label)“ fehlt: \(dump(env))", file: file, line: line) }
        let f = frame(b)
        XCTAssertTrue(env.window.bounds.insetBy(dx: -1, dy: -1).contains(f), "„\(label)“ liegt nicht ganz im Fenster: \(f)", file: file, line: line)
        XCTAssertFalse(b.accessibilityTraits.contains(.notEnabled), "„\(label)“ ist gesperrt", file: file, line: line)
    }

    // MARK: Schema

    /// Die Schemadatei kennt, was die vier Aktionen brauchen (und der Nachbau liest sie richtig)
    func testSchemaDateiDecktDieVierAktionen() throws {
        // am Mac ("Designed for iPad") liest der Testwirt das Repo nicht: dort gilt die Kopie im Test; hier (Simulator)
        // muss sie fuer die Typen der Community genau der Datei gleichen
        if let file = try? ProductionLikeStore.schemaFromRepo() {
            let fromFile = ProductionLikeStore.parse(file), copy = ProductionLikeStore.parse(ProductionLikeStore.communitySchemaCopy)
            XCTAssertEqual(Set(copy.keys), ["Solution", "Report", "StudyGroup", "Block", "Ban", "Comment", "Like", "Correction"])
            for (name, type) in copy { XCTAssertEqual(fromFile[name], type, "Kopie im Test weicht von Config/cloudkit-schema.ckdb ab: \(name)") }
        } else if !ProcessInfo.processInfo.isiOSAppOnMac {
            XCTFail("Config/cloudkit-schema.ckdb ist nicht lesbar")
        }
        let types = ProductionLikeStore.parse(ProductionLikeStore.schema())
        let comment = try XCTUnwrap(types["Comment"]), like = try XCTUnwrap(types["Like"]), report = try XCTUnwrap(types["Report"])
        for field in ["solutionID", "parentID", "status", "createdAt", "editedAt", "payload", "ownerRecordName", "removedID"] {
            XCTAssertEqual(comment.fields[field]?.kind, "STRING", field)
        }
        XCTAssertEqual(comment.fields["createdOrder"]?.kind, "INT64")
        XCTAssertEqual(comment.fields["solutionID"]?.queryable, true, "Kommentare und Fragen werden ueber solutionID gesucht")
        XCTAssertEqual(like.fields["solutionID"]?.queryable, true, "Likes werden ueber solutionID gesucht")
        XCTAssertEqual(report.fields["solutionID"]?.queryable, true)
        XCTAssertNotNil(report.fields["commentID"])
        for t in [comment, like] {
            XCTAssertTrue(t.allows("CREATE", "_icloud"), "angemeldete Nutzer legen an")
            XCTAssertTrue(t.allows("READ", "_world"), "alle lesen")
            XCTAssertTrue(t.allows("WRITE", "_creator"), "nur der Ersteller aendert und loescht")
            XCTAssertFalse(t.allows("WRITE", "_icloud"), "fremde Beitraege aendert niemand")
        }
        XCTAssertFalse(report.allows("READ", "_world"), "Meldungen liest nur, wer sie geschrieben hat")
        XCTAssertEqual(types["Ban"]?.recordNameQueryable, true, "die App fragt alle Sperren ab")
        XCTAssertFalse(types["Ban"]?.allows("CREATE", "_icloud") ?? true, "Sperren legt nur der Inhaber im Dashboard an")
        // der Nachbau lehnt ab, was Production ablehnt
        let store = try store()
        let cloud = store.device("_user-x")
        let bad = CommunityRecord(type: "Comment", name: "c-1", fields: ["text": .string("Klartext")])
        XCTAssertThrowsError(try awaiting { try await cloud.create(bad, in: .publicDB) })
        XCTAssertThrowsError(try awaiting { try await cloud.query(CommunityQuery(type: "Comment", equals: ["parentID": .string("x")]), in: .publicDB) })
        XCTAssertEqual(store.rejected.map(\.reason), ["Feld Comment.text steht nicht im Schema", "Feld Comment.parentID ist nicht QUERYABLE"])
    }

    // MARK: 1. Kommentar schreiben

    func testKommentarStehtInListeUndZaehlerBeiMirUndBeiAnderen() async throws {
        let store = try store()
        let sid = try await publish(store)
        let ben = try await device(store, "Ben"), lea = try await device(store, "Lea"), mia = try await device(store, "Mia")

        let c = try await ben.addComment(solutionID: sid, text: "  Warum das Minus in 2b?  ", parentID: nil, pageKey: "p1", anchor: .init(x: 0.25, y: 0.5))
        XCTAssertEqual(c.text, "Warum das Minus in 2b?")
        XCTAssertTrue(c.isMine)

        // bei mir: im Verlauf und im Zaehler der Liste
        let mine = try await ben.comments(solutionID: sid)
        XCTAssertEqual(mine.map(\.text), ["Warum das Minus in 2b?"])
        XCTAssertEqual(mine.first?.isMine, true, "der eigene Kommentar ist als eigener erkannt (Ersteller __defaultOwner__)")
        XCTAssertEqual(mine.first?.pseudonym, "Ben")
        let myList = try await ben.solutions(in: space)
        XCTAssertEqual(myList.map(\.commentCount), [1])

        // bei der Autorin und bei einer Dritten: derselbe Text, nicht als eigener, Zaehler 1
        for other in [lea, mia] {
            let seen = try await other.comments(solutionID: sid)
            XCTAssertEqual(seen.map(\.text), ["Warum das Minus in 2b?"])
            XCTAssertEqual(seen.first?.isMine, false)
            XCTAssertEqual(seen.first?.pseudonym, "Ben")
            XCTAssertEqual(seen.first?.anchor, .init(x: 0.25, y: 0.5))
            let list = try await other.solutions(in: space)
            XCTAssertEqual(list.map(\.commentCount), [1])
        }
        let leaList = try await lea.solutions(in: space)
        XCTAssertEqual(leaList.first?.isOwn, true)

        // der Datensatz: Typ, Verweise, Ersteller; Text nur verschluesselt
        let record = try XCTUnwrap(store.all(CommunityRecordType.comment).first)
        XCTAssertEqual(record.name, c.id)
        XCTAssertEqual(record["solutionID"]?.string, sid)
        XCTAssertEqual(record["parentID"]?.string, "")
        XCTAssertEqual(record["status"]?.string, "active")
        XCTAssertEqual(record.creator, "_user-ben")
        XCTAssertNil(Data(base64Encoded: record["payload"]?.string ?? "")?.range(of: Data("Minus".utf8)))

        // bearbeiten und loeschen: nur der Verfasser; danach stimmt der Zaehler wieder
        await expect(.service("Nur der Verfasser kann seinen Kommentar ändern.")) { _ = try await mia.editComment(id: c.id, text: "x") }
        let edited = try await ben.editComment(id: c.id, text: "Warum das Minus in 2b und 2c?")
        XCTAssertTrue(edited.edited)
        let afterEdit = try await lea.comments(solutionID: sid)
        XCTAssertEqual(afterEdit.map(\.text), ["Warum das Minus in 2b und 2c?"])
        try await ben.deleteComment(id: c.id)
        let afterDelete = try await lea.comments(solutionID: sid)
        XCTAssertEqual(afterDelete, [])
        let listAfterDelete = try await lea.solutions(in: space)
        XCTAssertEqual(listAfterDelete.map(\.commentCount), [0])
        XCTAssertEqual(store.rejected, [], "nichts, was Production abgelehnt haette")
    }

    // MARK: 2. Diskussion starten

    func testFrageStehtImKanalBeiMirUndBeiAnderen() async throws {
        let store = try store()
        let lea = try await device(store, "Lea"), ben = try await device(store, "Ben")
        let empty = try await ben.posts(in: space)
        XCTAssertEqual(empty, [])

        let q = try await lea.addPost(in: space, text: "Wie löst man Aufgabe 2b?", parentID: nil)
        XCTAssertTrue(q.isMine)
        let mine = try await lea.posts(in: space)
        XCTAssertEqual(mine.map(\.question.text), ["Wie löst man Aufgabe 2b?"])
        XCTAssertEqual(mine.first?.question.isMine, true)

        let seen = try await ben.posts(in: space)
        XCTAssertEqual(seen.map(\.question.text), ["Wie löst man Aufgabe 2b?"])
        XCTAssertEqual(seen.first?.question.pseudonym, "Lea")
        XCTAssertEqual(seen.first?.question.isMine, false)
        XCTAssertEqual(seen.first?.answered, false)
        XCTAssertEqual(seen.first?.likes, 0)

        let record = try XCTUnwrap(store.all(CommunityRecordType.comment).first)
        XCTAssertEqual(record["solutionID"]?.string, CommunityDiscussion.spaceTarget(space.key), "Frage = Comment mit dem Ziel der Community")
        XCTAssertEqual(record["parentID"]?.string, "")

        // nur Mitglieder; Grenzen des Textes mit verstaendlicher Meldung
        let outsider = CloudKitCommunityService(cloud: store.device("_user-fremd"), university: .luh, membership: CommunityMembership(defaults: suite()),
                                                courseKeys: { [] }, courses: { [] })
        await expect(.notFound) { _ = try await outsider.posts(in: self.space) }
        await expect(.notFound) { _ = try await outsider.addPost(in: self.space, text: "Hallo", parentID: nil) }
        await expect(.service("Höchstens 2000 Zeichen.")) { _ = try await ben.addPost(in: self.space, text: String(repeating: "a", count: 2001), parentID: nil) }
        await expect(.service("Der Kommentar ist leer.")) { _ = try await ben.addPost(in: self.space, text: " \n ", parentID: nil) }
        XCTAssertEqual(store.all(CommunityRecordType.comment).count, 1, "abgelehnte Fragen schreiben nichts")
        XCTAssertEqual(store.rejected, [])
    }

    // MARK: 3. Like

    func testLikeSetzenZuruecknehmenKeinDoppelUndZaehlerNachNeuladen() async throws {
        let store = try store()
        let lea = try await device(store, "Lea"), ben = try await device(store, "Ben"), mia = try await device(store, "Mia")
        let q = try await lea.addPost(in: space, text: "Wie löst man Aufgabe 2b?", parentID: nil)

        // setzen: einmal zaehlt, zweimal tippen legt keinen zweiten an
        let first = try await ben.setPostLiked(in: space, postID: q.id, true)
        XCTAssertEqual(first, 1)
        let again = try await ben.setPostLiked(in: space, postID: q.id, true)
        XCTAssertEqual(again, 1)
        XCTAssertEqual(store.all(CommunityRecordType.like).count, 1, "ein Like je Person")
        XCTAssertEqual(store.all(CommunityRecordType.like).first?["solutionID"]?.string, CommunityDiscussion.postLikeTarget(q.id))

        // nach dem Neuladen: bei mir gemocht, bei anderen gezaehlt
        var benView = try await ben.posts(in: space)
        XCTAssertEqual(benView.first?.likes, 1)
        XCTAssertEqual(benView.first?.likedByMe, true)
        var leaView = try await lea.posts(in: space)
        XCTAssertEqual(leaView.first?.likes, 1)
        XCTAssertEqual(leaView.first?.likedByMe, false)
        await expect(.service("Die eigene Frage lässt sich nicht liken.")) { _ = try await lea.setPostLiked(in: self.space, postID: q.id, true) }

        // zweite Person
        let two = try await mia.setPostLiked(in: space, postID: q.id, true)
        XCTAssertEqual(two, 2)
        leaView = try await lea.posts(in: space)
        XCTAssertEqual(leaView.first?.likes, 2)

        // zuruecknehmen (zweimal schadet nicht); fremde Likes bleiben
        let back = try await ben.setPostLiked(in: space, postID: q.id, false)
        XCTAssertEqual(back, 1)
        let backAgain = try await ben.setPostLiked(in: space, postID: q.id, false)
        XCTAssertEqual(backAgain, 1)
        benView = try await ben.posts(in: space)
        XCTAssertEqual(benView.first?.likes, 1)
        XCTAssertEqual(benView.first?.likedByMe, false)
        XCTAssertEqual(store.all(CommunityRecordType.like).map(\.creator), ["_user-mia"])

        // dasselbe unter einer Loesung
        let sid = try await publish(store)
        let solutionLike = try await ben.setLiked(solutionID: sid, true)
        XCTAssertEqual(solutionLike, 1)
        let solutionLikeAgain = try await ben.setLiked(solutionID: sid, true)
        XCTAssertEqual(solutionLikeAgain, 1)
        var list = try await ben.solutions(in: space)
        XCTAssertEqual(list.first?.likes, 1)
        XCTAssertEqual(list.first?.likedByMe, true)
        let leaList = try await lea.solutions(in: space)
        XCTAssertEqual(leaList.first?.likes, 1)
        XCTAssertEqual(leaList.first?.likedByMe, false)
        await expect(.service("Die eigene Lösung lässt sich nicht liken.")) { _ = try await lea.setLiked(solutionID: sid, true) }
        let solutionBack = try await ben.setLiked(solutionID: sid, false)
        XCTAssertEqual(solutionBack, 0)
        list = try await ben.solutions(in: space)
        XCTAssertEqual(list.first?.likes, 0)
        XCTAssertEqual(list.first?.likedByMe, false)
        XCTAssertEqual(store.rejected, [])
    }

    /// Die Suche von CloudKit kennt einen eben angelegten Datensatz erst nach einem Moment. Wer in dieser Zeit "Gefällt
    /// mir" zuruecknahm, behielt vor dem 17.11.2026 sein Like beim Dienst (die App fand es nicht und loeschte nichts):
    /// nach dem Neuladen war die Frage wieder gemocht. Zweimal "Gefällt mir" in dieser Zeit legte zwei Datensaetze an.
    func testLikeUmschaltenBevorDieSucheNachkommt() async throws {
        let store = try store()
        let lea = try await device(store, "Lea"), ben = try await device(store, "Ben")
        let q = try await lea.addPost(in: space, text: "Wie löst man Aufgabe 2b?", parentID: nil)

        store.indexDelay = true
        let on = try await ben.setPostLiked(in: space, postID: q.id, true)
        XCTAssertEqual(on, 1)
        let off = try await ben.setPostLiked(in: space, postID: q.id, false)
        XCTAssertEqual(off, 0)
        store.catchUp()
        XCTAssertEqual(store.all(CommunityRecordType.like), [], "zurueckgenommen heisst: kein Like mehr beim Dienst")
        var view = try await ben.posts(in: space)
        XCTAssertEqual(view.first?.likes, 0)
        XCTAssertEqual(view.first?.likedByMe, false)

        // zweimal setzen, bevor die Suche nachkommt: ein Datensatz
        let one = try await ben.setPostLiked(in: space, postID: q.id, true)
        XCTAssertEqual(one, 1)
        let same = try await ben.setPostLiked(in: space, postID: q.id, true)
        XCTAssertEqual(same, 1)
        store.catchUp()
        XCTAssertEqual(store.all(CommunityRecordType.like).count, 1)
        view = try await ben.posts(in: space)
        XCTAssertEqual(view.first?.likes, 1)
        XCTAssertEqual(view.first?.likedByMe, true)

        // ein Like aus einer aelteren App-Fassung (Name mit Zufallskennung) nimmt die neue ebenfalls zurueck
        store.indexDelay = false
        _ = try await ben.setPostLiked(in: space, postID: q.id, false)
        var old = CommunityRecord(type: CommunityRecordType.like, name: "like-" + UUID().uuidString.lowercased())
        old["solutionID"] = .string(CommunityDiscussion.postLikeTarget(q.id))
        old["ownerRecordName"] = .string("_user-ben")
        old["createdAt"] = .string(SolutionPackage.timestamp(Date()))
        try await store.device("_user-ben").create(old, in: .publicDB)
        view = try await ben.posts(in: space)
        XCTAssertEqual(view.first?.likedByMe, true)
        let gone = try await ben.setPostLiked(in: space, postID: q.id, false)
        XCTAssertEqual(gone, 0)
        XCTAssertEqual(store.all(CommunityRecordType.like), [])
        XCTAssertEqual(store.rejected, [])
    }

    // MARK: 4. Antworten

    func testAntwortHaengtAmRichtigenBeitrag() async throws {
        let store = try store()
        let lea = try await device(store, "Lea"), ben = try await device(store, "Ben"), mia = try await device(store, "Mia")

        // Fragen: zwei Fragen, je eine Antwort; Antwort auf eine Antwort bleibt bei derselben Frage (eine Ebene)
        let q1 = try await lea.addPost(in: space, text: "Wie löst man Aufgabe 2b?", parentID: nil)
        let q2 = try await lea.addPost(in: space, text: "Wann ist die Klausur?", parentID: nil)
        let a2 = try await ben.addPost(in: space, text: "Am 12. Februar.", parentID: q2.id)
        let a1 = try await mia.addPost(in: space, text: "Mit der Kettenregel.", parentID: q1.id)
        let a2b = try await lea.addPost(in: space, text: "Danke!", parentID: a2.id)
        XCTAssertEqual(a2.parentID, q2.id)
        XCTAssertEqual(a1.parentID, q1.id)
        XCTAssertEqual(a2b.parentID, q2.id, "Antwort auf eine Antwort haengt an der Frage")
        for person in [lea, ben, mia] {
            let posts = try await person.posts(in: space)
            let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
            XCTAssertEqual(Set(posts.map(\.id)), [q1.id, q2.id], "Antworten sind keine eigenen Fragen")
            XCTAssertEqual(byID[q1.id]?.replies.map(\.text), ["Mit der Kettenregel."])
            XCTAssertEqual(byID[q2.id]?.replies.map(\.text), ["Am 12. Februar.", "Danke!"])
            XCTAssertEqual(byID[q1.id]?.answered, true)
            XCTAssertEqual(byID[q2.id]?.replies.map(\.pseudonym), ["Ben", "Lea"])
        }
        XCTAssertEqual(store.all(CommunityRecordType.comment).first { $0.name == a2b.id }?["parentID"]?.string, q2.id)

        // Kommentare unter einer Loesung: Antwort steht direkt unter ihrem Kommentar, nicht am Ende
        let sid = try await publish(store)
        let c1 = try await ben.addComment(solutionID: sid, text: "Erster Kommentar", parentID: nil, pageKey: nil, anchor: nil)
        let c2 = try await mia.addComment(solutionID: sid, text: "Zweiter Kommentar", parentID: nil, pageKey: nil, anchor: nil)
        let r1 = try await lea.addComment(solutionID: sid, text: "Antwort auf den ersten", parentID: c1.id, pageKey: nil, anchor: nil)
        XCTAssertEqual(r1.parentID, c1.id)
        XCTAssertTrue(r1.byAuthor)
        let thread = try await mia.comments(solutionID: sid)
        XCTAssertEqual(thread.map(\.text), ["Erster Kommentar", "Antwort auf den ersten", "Zweiter Kommentar"])
        XCTAssertEqual(thread.map(\.parentID), [nil, c1.id, nil])
        let counted = try await mia.solutions(in: space)
        XCTAssertEqual(counted.first?.commentCount, 3)
        _ = c2

        // Antwort auf etwas, das es nicht (mehr) gibt: verstaendliche Meldung, nichts geschrieben
        let before = store.all(CommunityRecordType.comment).count
        await expect(.service("Der Kommentar, auf den du antwortest, gibt es nicht.")) {
            _ = try await ben.addPost(in: self.space, text: "ins Leere", parentID: UUID().uuidString.lowercased())
        }
        store.moderate(name: q1.id) { $0["status"] = .string("hidden") }                  // Moderation im Dashboard
        await expect(.service("Der Kommentar, auf den du antwortest, gibt es nicht.")) {
            _ = try await ben.addPost(in: self.space, text: "auf Ausgeblendetes", parentID: q1.id)
        }
        XCTAssertEqual(store.all(CommunityRecordType.comment).count, before)
        XCTAssertEqual(store.rejected, [])
    }

    // MARK: Fehlerwege

    func testFehlerwegeSindVerstaendlichUndSchreibenNichts() async throws {
        let store = try store()
        let lea = try await device(store, "Lea"), ben = try await device(store, "Ben")
        let q = try await lea.addPost(in: space, text: "Wie löst man Aufgabe 2b?", parentID: nil)
        let sid = try await publish(store)
        let writes = { store.all(CommunityRecordType.comment).count + store.all(CommunityRecordType.like).count }
        let before = writes()

        // offline und Kontingent: jede der vier Aktionen meldet es, nichts wird geschrieben
        for (failure, expected) in [(CommunityCloudError.offline, CommunityServiceError.offline), (.quota, .quota)] {
            store.failure = failure
            await expect(expected) { _ = try await ben.addPost(in: self.space, text: "Frage", parentID: nil) }
            await expect(expected) { _ = try await ben.addPost(in: self.space, text: "Antwort", parentID: q.id) }
            await expect(expected) { _ = try await ben.setPostLiked(in: self.space, postID: q.id, true) }
            await expect(expected) { _ = try await ben.addComment(solutionID: sid, text: "Kommentar", parentID: nil, pageKey: nil, anchor: nil) }
            await expect(expected) { _ = try await ben.setLiked(solutionID: sid, true) }
            await expect(expected) { _ = try await ben.posts(in: self.space) }
            store.failure = nil
        }
        XCTAssertEqual(writes(), before)
        XCTAssertEqual(CommunityTexts.message(CommunityServiceError.offline), "Keine Verbindung zum Community-Dienst. Prüfe dein Netz und versuche es erneut.")
        XCTAssertEqual(CommunityTexts.message(CommunityServiceError.quota), "Das Kontingent des Community-Dienstes ist erschöpft. Bitte später erneut versuchen.")

        // Datensatz inzwischen geloescht: Like und Antwort sagen es
        try await lea.deleteComment(id: q.id)
        await expect(.service("Diese Frage gibt es nicht mehr.")) { _ = try await ben.setPostLiked(in: self.space, postID: q.id, true) }
        let gone = try await ben.posts(in: space)
        XCTAssertEqual(gone, [], "geloeschte Frage ohne Antworten verschwindet")

        // Konflikt (derselbe Kommentar gerade auf einem anderen Geraet geaendert): deutscher Text
        XCTAssertEqual(CloudKitCommunityService.serviceError(CommunityCloudError.changedElsewhere), .service(CommunityCloudError.changedElsewhereText))
        XCTAssertEqual(writes(), before)
    }

    /// Geraet ohne iCloud-Konto (so laeuft auch der Simulator): lesen geht, schreiben sagt, was fehlt
    func testOhneICloudLesenJaSchreibenNeinMitKlarerMeldung() async throws {
        let store = try store()
        let lea = try await device(store, "Lea")
        let q = try await lea.addPost(in: space, text: "Wie löst man Aufgabe 2b?", parentID: nil)
        let sid = try await publish(store)
        _ = try await lea.addComment(solutionID: sid, text: "Hinweis der Autorin", parentID: nil, pageKey: nil, anchor: nil)
        let before = store.all(CommunityRecordType.comment).count

        let guest = try await device(store, "Gast", signedIn: false)
        let posts = try await guest.posts(in: space)
        XCTAssertEqual(posts.map(\.question.text), ["Wie löst man Aufgabe 2b?"], "Fragen sind ohne iCloud-Konto lesbar")
        XCTAssertEqual(posts.first?.question.isMine, false)
        let comments = try await guest.comments(solutionID: sid)
        XCTAssertEqual(comments.map(\.text), ["Hinweis der Autorin"])
        await expect(.notSignedIn) { _ = try await guest.addPost(in: self.space, text: "Frage", parentID: nil) }
        await expect(.notSignedIn) { _ = try await guest.addPost(in: self.space, text: "Antwort", parentID: q.id) }
        await expect(.notSignedIn) { _ = try await guest.setPostLiked(in: self.space, postID: q.id, true) }
        await expect(.notSignedIn) { _ = try await guest.addComment(solutionID: sid, text: "Kommentar", parentID: nil, pageKey: nil, anchor: nil) }
        await expect(.notSignedIn) { _ = try await guest.setLiked(solutionID: sid, true) }
        XCTAssertEqual(store.all(CommunityRecordType.comment).count, before)
        XCTAssertEqual(store.all(CommunityRecordType.like), [])

        // die Meldung nennt das Geraet, an dem man sitzt
        let text = CommunityTexts.rawMessage(CommunityServiceError.notSignedIn)
        XCTAssertEqual(text, "Melde dich auf diesem iPad bei iCloud an (Einstellungen → Apple-ID), um die Community zu nutzen.")
        XCTAssertEqual(UFDevice.adapt(text, phone: true), "Melde dich auf diesem iPhone bei iCloud an (Einstellungen → Apple-ID), um die Community zu nutzen.")
        XCTAssertEqual(UFDevice.adapt(text, mac: true), "Melde dich auf diesem Mac bei iCloud an (Einstellungen → Apple-ID), um die Community zu nutzen.")
        XCTAssertEqual(CommunityTexts.message(CommunityServiceError.notSignedIn), UFDevice.adapt(text))
    }

    // MARK: Ansichten: Frage stellen, Like, Antworten (iPad und iPhone)

    func testAnsichtFrageStellenLikeUndAntwortenIPad() throws { try frageLikeAntwort(.iPad) }
    func testAnsichtFrageStellenLikeUndAntwortenIPhone() throws { try frageLikeAntwort(.iPhone) }

    private func frageLikeAntwort(_ geraet: Geraet) throws {
        let store = try store()
        let (lea, ben) = try awaiting { (try await self.device(store, "Lea"), try await self.device(store, "Ben")) }
        let leaQuestion = try awaiting { try await lea.addPost(in: self.space, text: "Wie löst man Aufgabe 2b?", parentID: nil) }

        // Bens Geraet: Diskussion der Community
        let env = try host(CommunitySpaceDiscussion(space: space, service: ben), geraet)
        XCTAssertTrue(env.wait { self.shows(env, "Frage von Lea") }, dump(env))
        if geraet == .iPhone { assertFits(env, "diskussion") }

        // Diskussion starten: tippen, senden, steht sofort da, liegt beim Dienst, Lea sieht sie
        XCTAssertTrue(type("Wann ist die Klausur?", in: env))
        assertReachable(env, "Frage stellen")
        XCTAssertTrue(tap(env, "Frage stellen"))
        XCTAssertTrue(env.wait(timeout: 3) { self.shows(env, "Frage von Ben") && self.shows(env, "Wann ist die Klausur?") }, dump(env))
        XCTAssertTrue(env.wait { store.all(CommunityRecordType.comment).count == 2 && !self.shows(env, CommunityPendingSend.sending) }, dump(env))
        XCTAssertTrue(shows(env, "Wann ist die Klausur?, 0 Antworten, 0 Likes"), dump(env))
        let leaSees = try awaiting { try await lea.posts(in: self.space) }
        XCTAssertEqual(Set(leaSees.map(\.question.text)), ["Wie löst man Aufgabe 2b?", "Wann ist die Klausur?"])
        XCTAssertEqual(leaSees.first { $0.question.text == "Wann ist die Klausur?" }?.question.pseudonym, "Ben")
        bild(env, "\(geraet.rawValue)-1-frage-gestellt")

        // die eigene Frage laesst sich nicht liken (Knopf gesperrt), die fremde schon: setzen und zuruecknehmen
        let own = elements(env).filter { $0.accessibilityTraits.contains(.button) && ($0.accessibilityLabel ?? "") == "Gefällt mir, 0 Likes" }
        XCTAssertEqual(own.count, 2, dump(env))
        XCTAssertEqual(own.filter { $0.accessibilityTraits.contains(.notEnabled) }.count, 1, "nur der Stern an der eigenen Frage ist gesperrt")
        let star = try XCTUnwrap(own.first { !$0.accessibilityTraits.contains(.notEnabled) })
        XCTAssertTrue(star.accessibilityActivate())
        XCTAssertTrue(env.wait { self.shows(env, "Gefällt dir, 1 Like") }, dump(env))
        XCTAssertEqual(store.all(CommunityRecordType.like).count, 1)
        let liked = try awaiting { try await lea.posts(in: self.space) }
        XCTAssertEqual(liked.first { $0.id == leaQuestion.id }?.likes, 1, "Lea sieht das Like an ihrer Frage")
        bild(env, "\(geraet.rawValue)-2-like-gesetzt")
        XCTAssertTrue(tap(env, "Gefällt dir, 1 Like"))
        XCTAssertTrue(env.wait { !self.shows(env, "Gefällt dir") && store.all(CommunityRecordType.like).isEmpty }, dump(env))

        // Antworten: Blatt der Frage, tippen, senden, steht unter der Frage, liegt beim Dienst an der richtigen Frage
        let post = try XCTUnwrap(try awaiting { try await ben.posts(in: self.space) }.first { $0.id == leaQuestion.id })
        var changed: [CommunityPost] = []
        let sheet = try host(CommunityThreadSheet(space: space, service: ben, post: post, close: {}, changed: { changed.append($0) }), geraet)
        XCTAssertTrue(sheet.wait { self.shows(sheet, "Noch keine Antworten") }, dump(sheet))
        XCTAssertTrue(type("Mit der Kettenregel.", in: sheet))
        assertReachable(sheet, "Antworten")
        if geraet == .iPhone {
            assertFits(sheet, "frage")
            assertComposerAboveKeyboard(sheet, field: "Antworten …", send: "Antworten")
        }
        XCTAssertTrue(tap(sheet, "Antworten"))
        XCTAssertTrue(sheet.wait(timeout: 3) { self.shows(sheet, "Mit der Kettenregel.") && self.shows(sheet, "1 Antwort") }, dump(sheet))
        XCTAssertTrue(sheet.wait { store.all(CommunityRecordType.comment).count == 3 && !self.shows(sheet, CommunityPendingSend.sending) }, dump(sheet))
        let reply = try XCTUnwrap(store.all(CommunityRecordType.comment).first { !($0["parentID"]?.string ?? "").isEmpty })
        XCTAssertEqual(reply["parentID"]?.string, leaQuestion.id, "die Antwort haengt an Leas Frage")
        XCTAssertEqual(reply.creator, "_user-ben")
        let answered = try awaiting { try await lea.posts(in: self.space) }
        XCTAssertEqual(answered.first { $0.id == leaQuestion.id }?.replies.map(\.text), ["Mit der Kettenregel."])
        XCTAssertEqual(answered.first { $0.id == leaQuestion.id }?.replies.first?.pseudonym, "Ben")
        XCTAssertEqual(answered.first { $0.question.text == "Wann ist die Klausur?" }?.replies, [], "nicht an der anderen Frage")
        XCTAssertTrue(sheet.wait(timeout: 2) { changed.last?.replies.map(\.text) == ["Mit der Kettenregel."] && changed.last?.answered == true },
                      "die Liste bekommt die beantwortete Frage zurueck")
        bild(sheet, "\(geraet.rawValue)-3-antwort-gesendet")
        XCTAssertEqual(store.rejected, [], "nichts, was Production abgelehnt haette")
    }

    // MARK: Ansichten: Kommentar, Antwort und Like unter einer Loesung (iPad und iPhone)

    func testAnsichtKommentarAntwortUndLikeUnterEinerLoesungIPad() throws { try kommentarAntwortLike(.iPad) }
    func testAnsichtKommentarAntwortUndLikeUnterEinerLoesungIPhone() throws { try kommentarAntwortLike(.iPhone) }

    private func kommentarAntwortLike(_ geraet: Geraet) throws {
        let store = try store()
        let sid = try awaiting { try await self.publish(store) }
        let (lea, ben) = try awaiting { (try await self.device(store, "Lea"), try await self.device(store, "Ben")) }
        let first = try awaiting { try await lea.addComment(solutionID: sid, text: "Hinweis der Autorin", parentID: nil, pageKey: nil, anchor: nil) }
        let solution = try XCTUnwrap(try awaiting { try await ben.solutions(in: self.space) }.first)
        XCTAssertFalse(solution.isOwn)

        // Reiter "Diskussion" der Notizen einer Person, auf Bens Geraet
        let env = try host(CommunityPersonPane(solution: solution, service: ben, tab: .constant(.discussion)), geraet)
        XCTAssertTrue(env.wait { self.shows(env, "Hinweis der Autorin") && self.shows(env, "Diskussion (1)") }, dump(env))

        // Kommentar schreiben
        XCTAssertTrue(type("Warum das Minus in 2b?", in: env))
        assertReachable(env, "Senden")
        if geraet == .iPhone {
            assertFits(env, "leser-diskussion")
            assertComposerAboveKeyboard(env, field: "Kommentar schreiben …", send: "Senden")
        }
        XCTAssertTrue(tap(env, "Senden"))
        XCTAssertTrue(env.wait(timeout: 3) { self.shows(env, "Warum das Minus in 2b?") && self.shows(env, "Diskussion (2)") }, dump(env))
        XCTAssertTrue(env.wait { store.all(CommunityRecordType.comment).count == 2 && !self.shows(env, CommunityPendingSend.sending) }, dump(env))
        let leaSees = try awaiting { try await lea.comments(solutionID: sid) }
        XCTAssertEqual(leaSees.map(\.text), ["Hinweis der Autorin", "Warum das Minus in 2b?"])
        let counted = try awaiting { try await lea.solutions(in: self.space) }
        XCTAssertEqual(counted.first?.commentCount, 2, "Zaehler in der Liste der Autorin")
        bild(env, "\(geraet.rawValue)-4-kommentar-gesendet")

        // Antworten auf Leas Kommentar: steht direkt darunter, beim Dienst mit Verweis auf ihn
        let replyButtons = elements(env).filter { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == "Antworten" }
        XCTAssertEqual(replyButtons.count, 2, dump(env))
        XCTAssertTrue(replyButtons[0].accessibilityActivate())
        XCTAssertTrue(env.wait { self.shows(env, "Antwort an Lea") }, dump(env))
        XCTAssertTrue(type("Danke, verstanden.", in: env))
        XCTAssertTrue(tap(env, "Senden"))
        XCTAssertTrue(env.wait { store.all(CommunityRecordType.comment).count == 3 && !self.shows(env, CommunityPendingSend.sending) }, dump(env))
        let reply = try XCTUnwrap(store.all(CommunityRecordType.comment).first { !($0["parentID"]?.string ?? "").isEmpty })
        XCTAssertEqual(reply["parentID"]?.string, first.id)
        let thread = try awaiting { try await lea.comments(solutionID: sid) }
        XCTAssertEqual(thread.map(\.text), ["Hinweis der Autorin", "Danke, verstanden.", "Warum das Minus in 2b?"], "Antwort direkt unter ihrem Kommentar")
        XCTAssertTrue(shows(env, "Diskussion (3)"), dump(env))
        bild(env, "\(geraet.rawValue)-5-antwort-unter-kommentar")

        // Melden eines fremden Kommentars: Rueckmeldung und Datensatz (App-Review 1.2)
        XCTAssertTrue(tap(env, "Melden"))
        XCTAssertTrue(env.wait { self.shows(env, CommunityTexts.commentReported) }, dump(env))
        XCTAssertEqual(store.all(CommunityRecordType.report).map { $0["commentID"]?.string }, [first.id])

        // Like: im Reiter "Dokument" in der Leiste; setzen, Zaehler bei Lea, zuruecknehmen
        let notes = try host(CommunityPersonPane(solution: solution, service: ben, tab: .constant(.notes)), geraet)
        XCTAssertTrue(notes.wait { self.button(notes, "Gefällt mir · 0") != nil }, dump(notes))
        assertReachable(notes, "Gefällt mir · 0")
        if geraet == .iPhone { assertFits(notes, "leser") }
        XCTAssertTrue(tap(notes, "Gefällt mir · 0"))
        XCTAssertTrue(notes.wait { self.button(notes, "Gefällt dir · 1") != nil }, dump(notes))
        XCTAssertEqual(store.all(CommunityRecordType.like).map { $0["solutionID"]?.string }, [sid])
        let liked = try awaiting { try await lea.solutions(in: self.space) }
        XCTAssertEqual(liked.first?.likes, 1)
        bild(notes, "\(geraet.rawValue)-6-loesung-gemocht")
        XCTAssertTrue(tap(notes, "Gefällt dir · 1"))
        XCTAssertTrue(notes.wait { self.button(notes, "Gefällt mir · 0") != nil && store.all(CommunityRecordType.like).isEmpty }, dump(notes))
        XCTAssertEqual(store.rejected, [], "nichts, was Production abgelehnt haette")
    }

    // MARK: Ansichten: Fehlerfall und fehlendes iCloud-Konto

    /// Senden scheitert (kein Netz): die Meldung steht am Beitrag, der Text bleibt, "Erneut senden" schickt ihn genau einmal
    func testFehlerBeimSendenZeigtMeldungBehaeltTextUndSendetNichtDoppelt() throws {
        let store = try store()
        let sid = try awaiting { try await self.publish(store) }
        let (lea, ben) = try awaiting { (try await self.device(store, "Lea"), try await self.device(store, "Ben")) }
        let q = try awaiting { try await lea.addPost(in: self.space, text: "Wie löst man Aufgabe 2b?", parentID: nil) }
        let offline = CommunityPendingSend.failed(CommunityServiceError.offline.localizedDescription)

        // Frage
        let env = try hostPad(CommunitySpaceDiscussion(space: space, service: ben), api: remote(Canned()))
        XCTAssertTrue(env.wait { self.shows(env, "Frage von Lea") }, dump(env))
        store.failure = .offline
        XCTAssertTrue(type("Gibt es Altklausuren?", in: env))
        XCTAssertTrue(tap(env, "Frage stellen"))
        XCTAssertTrue(env.wait { self.shows(env, offline) }, dump(env))
        XCTAssertTrue(shows(env, "Gibt es Altklausuren?"), "der Text bleibt stehen")
        XCTAssertEqual(store.all(CommunityRecordType.comment).count, 1)
        bild(env, "iPad-7-frage-nicht-gesendet")
        store.failure = nil
        XCTAssertTrue(tap(env, CommunityPendingSend.retry))
        XCTAssertTrue(env.wait { store.all(CommunityRecordType.comment).count == 2 && !self.shows(env, CommunityPendingSend.retry) }, dump(env))
        env.pump(0.5)
        XCTAssertEqual(store.all(CommunityRecordType.comment).count, 2, "genau einmal gesendet")

        // Antwort
        let post = try XCTUnwrap(try awaiting { try await ben.posts(in: self.space) }.first { $0.id == q.id })
        var changed: [CommunityPost] = []
        let sheet = try hostPad(CommunityThreadSheet(space: space, service: ben, post: post, close: {}, changed: { changed.append($0) }), api: remote(Canned()))
        XCTAssertTrue(sheet.wait { self.shows(sheet, "Noch keine Antworten") }, dump(sheet))
        store.failure = .offline
        XCTAssertTrue(type("Mit der Kettenregel.", in: sheet))
        XCTAssertTrue(tap(sheet, "Antworten"))
        XCTAssertTrue(sheet.wait { self.shows(sheet, offline) }, dump(sheet))
        XCTAssertTrue(shows(sheet, "Mit der Kettenregel."), "der Text bleibt stehen")
        // die Liste der Fragen zaehlt eine nicht gesendete Antwort nicht als Antwort
        XCTAssertTrue(sheet.wait(timeout: 2) { changed.last?.replies.isEmpty == true }, "\(changed.map { $0.replies.map(\.id) })")
        XCTAssertEqual(changed.last?.answered, false)
        store.failure = nil
        XCTAssertTrue(tap(sheet, CommunityPendingSend.retry))
        XCTAssertTrue(sheet.wait { store.all(CommunityRecordType.comment).count == 3 && !self.shows(sheet, CommunityPendingSend.retry) }, dump(sheet))
        XCTAssertTrue(sheet.wait(timeout: 2) { changed.last?.replies.map(\.text) == ["Mit der Kettenregel."] })

        // Kommentar
        let solution = try XCTUnwrap(try awaiting { try await ben.solutions(in: self.space) }.first)
        let pane = try hostPad(CommunityPersonPane(solution: solution, service: ben, tab: .constant(.discussion)), api: remote(Canned()))
        XCTAssertTrue(pane.wait { self.shows(pane, "Noch keine Kommentare.") }, dump(pane))
        store.failure = .offline
        XCTAssertTrue(type("Warum das Minus in 2b?", in: pane))
        XCTAssertTrue(tap(pane, "Senden"))
        XCTAssertTrue(pane.wait { self.shows(pane, offline) }, dump(pane))
        XCTAssertTrue(shows(pane, "Warum das Minus in 2b?"), "der Text bleibt stehen")
        store.failure = nil
        XCTAssertTrue(tap(pane, CommunityPendingSend.retry))
        XCTAssertTrue(pane.wait { store.all(CommunityRecordType.comment).count == 4 && !self.shows(pane, CommunityPendingSend.retry) }, dump(pane))
        let seen = try awaiting { try await lea.comments(solutionID: sid) }
        XCTAssertEqual(seen.map(\.text), ["Warum das Minus in 2b?"])
    }

    /// Ohne iCloud-Konto (Zustand des Simulators und eines Nutzers, der nicht bei iCloud angemeldet ist): die Fragen
    /// stehen da, Schreiben sagt am Beitrag, was fehlt; nichts wird geschrieben
    func testAnsichtOhneICloudZeigtFragenUndSagtBeimSendenWasFehlt() throws {
        let store = try store()
        let lea = try awaiting { try await self.device(store, "Lea") }
        _ = try awaiting { try await lea.addPost(in: self.space, text: "Wie löst man Aufgabe 2b?", parentID: nil) }
        let guest = try awaiting { try await self.device(store, "Gast", signedIn: false) }
        let env = try hostPad(CommunitySpaceDiscussion(space: space, service: guest), api: remote(Canned()))
        XCTAssertTrue(env.wait { self.shows(env, "Frage von Lea") }, "lesen geht ohne iCloud: \(dump(env))")
        // Like: Meldung oben in der Liste
        XCTAssertTrue(tap(env, "Gefällt mir, 0 Likes"))
        XCTAssertTrue(env.wait { self.shows(env, CommunityTexts.message(CommunityServiceError.notSignedIn)) }, dump(env))
        XCTAssertFalse(shows(env, "Gefällt dir"), dump(env))
        // Frage: Meldung am Beitrag
        XCTAssertTrue(type("Wann ist die Klausur?", in: env))
        XCTAssertTrue(tap(env, "Frage stellen"))
        let message = CommunityPendingSend.failed(CommunityTexts.message(CommunityServiceError.notSignedIn))
        XCTAssertTrue(env.wait { self.shows(env, message) }, dump(env))
        XCTAssertTrue(message.contains("bei iCloud an"), message)
        XCTAssertTrue(shows(env, "Wann ist die Klausur?"), "der Text bleibt stehen")
        XCTAssertNotNil(button(env, CommunityPendingSend.retry))
        XCTAssertNotNil(button(env, CommunityPendingSend.discard))
        XCTAssertEqual(store.all(CommunityRecordType.comment).count, 1)
        XCTAssertEqual(store.all(CommunityRecordType.like), [])
        bild(env, "iPad-8-ohne-icloud")
    }

    /// Antwort geht noch zum Dienst, das Blatt ist schon zu: kommt sie an, zaehlt die Liste den Datensatz des Dienstes;
    /// scheitert sie, zaehlt die Liste sie nicht (vorher blieb "1 Antwort · Beantwortet" stehen), sagt es und hebt den
    /// Text fuer das Antwortfeld auf.
    func testAntwortNachDemSchliessenDesBlatts() throws {
        let service = CommunityChannelAppTests.FakeChannelService()
        service.spaceDiscussion = true
        service.postDelay = 1.5
        service.posts = [CommunityPost(question: CommunityComment(id: "q1", pseudonym: "Lea", text: "Wie geht 2b?", createdAt: "2026-11-01T10:00:00Z"))]
        let space = CommunitySpace(key: "k", kind: .course, name: "Analysis", joined: true)
        let env = try hostPad(CommunitySpaceDiscussion(space: space, service: service), api: remote(Canned()))
        XCTAssertTrue(env.wait { self.shows(env, "Frage von Lea") }, dump(env))

        // gescheitert nach dem Schliessen
        service.postFailure = .offline
        XCTAssertTrue(tap(env, "0 Antworten"))
        XCTAssertTrue(waitSheet(env, showing: "Noch keine Antworten"), dump(env))
        XCTAssertTrue(type("Mit der Kettenregel.", in: env))
        XCTAssertTrue(tap(env, "Antworten"))
        XCTAssertTrue(env.wait(timeout: 2) { self.shows(env, CommunityPendingSend.sending) }, dump(env))
        XCTAssertTrue(tap(env, "Fertig"))
        XCTAssertTrue(env.wait { !self.sheetOpen(env) }, dump(env))
        let notice = CommunitySpaceTexts.replyNotSent(CommunityServiceError.offline.localizedDescription)
        XCTAssertTrue(env.wait(timeout: 5) { self.shows(env, notice) }, dump(env))
        XCTAssertTrue(shows(env, "Wie geht 2b?, 0 Antworten"), "eine nicht gesendete Antwort zaehlt nicht: \(dump(env))")
        XCTAssertFalse(shows(env, "Beantwortet"), dump(env))
        XCTAssertEqual(service.sent, [])

        // der Text wartet im Antwortfeld; diesmal kommt die Antwort nach dem Schliessen an
        service.postFailure = nil
        XCTAssertTrue(tap(env, "0 Antworten"))
        XCTAssertTrue(waitSheet(env, showing: "Noch keine Antworten"), dump(env))
        XCTAssertTrue(env.wait { self.button(env, "Antworten")?.accessibilityTraits.contains(.notEnabled) == false }, "Text steht wieder im Feld: \(dump(env))")
        XCTAssertTrue(tap(env, "Antworten"))
        XCTAssertTrue(env.wait(timeout: 2) { self.shows(env, CommunityPendingSend.sending) }, dump(env))
        XCTAssertTrue(tap(env, "Fertig"))
        XCTAssertTrue(env.wait { !self.sheetOpen(env) }, dump(env))
        XCTAssertTrue(env.wait(timeout: 5) { service.sent == ["Mit der Kettenregel."] })
        XCTAssertTrue(env.wait { self.shows(env, "Wie geht 2b?, Beantwortet, 1 Antwort") }, dump(env))
        // die Liste haelt den Datensatz des Dienstes, nicht mehr den Platzhalter: das Blatt zeigt ihn mit "Mehr" (Loeschen)
        XCTAssertTrue(tap(env, "1 Antwort"))
        XCTAssertTrue(waitSheet(env, showing: "Mit der Kettenregel."), dump(env))
        XCTAssertFalse(shows(env, CommunityPendingSend.sending), dump(env))
    }

    // MARK: Free-Tarif

    /// Free: Schloss mit dem Weg zu Plus statt einer Seite, die still nichts tut; der Dienst wird nicht gefragt
    func testFreeSiehtSchlossStattStillemScheitern() throws {
        Entitlements.shared.setPlanForTesting(.free)
        let store = try store()
        let ben = try awaiting { try await self.device(store, "Ben") }
        let calls = store.log.count
        for geraet in Geraet.allCases {
            let env = try host(CommunitySpacePage(key: space.key, space: space, service: ben), geraet)
            XCTAssertTrue(env.wait { self.shows(env, "Mit \(UFPlan.plus.name) freischalten") }, "\(geraet): \(dump(env))")
            XCTAssertTrue(shows(env, "Community ab \(UFPlan.plus.name)"), dump(env))
            XCTAssertFalse(shows(env, "Frage stellen"), "\(geraet): keine Eingabe, die nichts tut")
            XCTAssertNil(button(env, "Frage stellen"))
            if geraet == .iPhone { assertFits(env, "schloss") }
            bild(env, "\(geraet.rawValue)-9-free-schloss")
        }
        XCTAssertEqual(store.log.count, calls, "Free fragt den Dienst nicht")
    }

    // MARK: Hilfen der Ansichten

    /// Verlauf nach dem Senden im Blatt "Kommentare" eines Dokuments: der gespeicherte Kommentar steht da, auch wenn die
    /// neu geholte Liste ihn noch nicht kennt (Suche von CloudKit verzoegert)
    func testGespeicherterKommentarStehtAuchOhneSuchtrefferImVerlauf() async throws {
        let a = CommunityComment(id: "a", pseudonym: "Lea", text: "A", createdAt: "1")
        let a1 = CommunityComment(id: "a1", parentID: "a", pseudonym: "Ben", text: "A1", createdAt: "2")
        let b = CommunityComment(id: "b", pseudonym: "Mia", text: "B", createdAt: "3")
        let reply = CommunityComment(id: "neu", parentID: "a", pseudonym: "Ich", text: "A2", createdAt: "4", isMine: true)
        XCTAssertEqual(CommunityReaderSheet.including(reply, in: [a, a1, b]).map(\.id), ["a", "a1", "neu", "b"], "Antwort unter ihrem Kommentar")
        let top = CommunityComment(id: "neu", pseudonym: "Ich", text: "C", createdAt: "4", isMine: true)
        XCTAssertEqual(CommunityReaderSheet.including(top, in: [a, a1, b]).map(\.id), ["a", "a1", "b", "neu"])
        XCTAssertEqual(CommunityReaderSheet.including(top, in: [a, top, b]).map(\.id), ["a", "neu", "b"], "schon da: keine Dublette")
        var edited = b
        edited.text = "B neu"
        XCTAssertEqual(CommunityReaderSheet.including(edited, in: [a, b]).map(\.text), ["A", "B neu"])

        // gegen den Dienst: die Suche kennt den neuen Kommentar noch nicht, der Verlauf zeigt ihn trotzdem
        let store = try store()
        let sid = try await publish(store)
        let ben = try await device(store, "Ben")
        store.indexDelay = true
        let saved = try await ben.addComment(solutionID: sid, text: "Warum das Minus in 2b?", parentID: nil, pageKey: nil, anchor: nil)
        let fresh = try await ben.comments(solutionID: sid)
        XCTAssertEqual(fresh, [], "so antwortet CloudKit kurz nach dem Speichern")
        XCTAssertEqual(CommunityReaderSheet.including(saved, in: fresh).map(\.text), ["Warum das Minus in 2b?"])
        store.catchUp()
        let later = try await ben.comments(solutionID: sid)
        XCTAssertEqual(CommunityReaderSheet.including(saved, in: later).map(\.id), [saved.id])
    }
}
