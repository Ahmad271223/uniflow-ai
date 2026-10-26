import Foundation
import XCTest
@testable import UniFlowCore

// Neue Original-Fassung mit erhaltenen Notizen (S7): Seitenzuordnung ueber den Seitentext (`PageMatch`), Umhaengen der
// Notizen (`NoteTransfer`), alte Fassung aufbewahren (`FileVersionKeeper`, `file_versions`, Endpunkte). Nur
// erfundene Texte und Dateien.

/// Seitentexte wie PDFKit: die Test-"PDF" ist Text, Seiten durch Seitenvorschub getrennt
struct FormFeedTools: LocalDocumentTools {
    func pdfPageCount(_ data: Data) -> Int? { nil }
    func pdfFromImage(_ data: Data) -> Data? { nil }
    func pdfPageTexts(_ url: URL) -> [String]? {
        guard let d = try? Data(contentsOf: url), !d.isEmpty else { return nil }
        return String(decoding: d, as: UTF8.self).components(separatedBy: "\u{C}")
    }
}

final class PageMatchTests: XCTestCase {

    private func pairs(_ r: PageMatch.Result) -> [String] { r.pairs.map { "\($0.old)>\($0.new) \($0.kind.rawValue)" } }

    func testUnchangedPagesMapOneToOne() {
        let pages = ["Titel der Vorlesung Lineare Algebra", "Eigenwerte und Eigenvektoren einer Matrix", "Fragen?"]
        let r = PageMatch.match(old: pages, new: pages)
        XCTAssertEqual(pairs(r), ["1>1 gleich", "2>2 gleich", "3>3 gleich"])
        XCTAssertEqual(r.removed, [])
        XCTAssertEqual(r.added, [])
    }

    /// Eine eingefuegte Folie verschiebt alle folgenden; Fusszeilen mit Seitenzahl und Datum aendern sich mit, die
    /// Seiten gelten trotzdem als gleich (Ziffern zaehlen nicht), zerlegte Umlaute und Zeilenumbrueche ebenso
    func testInsertedSlideShiftsFollowingPages() {
        let old = ["Lineare Algebra\n1 / 4 – 12.10.2026", "Eigenwerte und Eigenvektoren\n2 / 4 – 12.10.2026",
                   "Determinante und Unabh\u{A8} angigkeit\n3 / 4", "Fragen?\n4 / 4"]
        let new = ["Lineare Algebra\n1 / 5 – 19.10.2026", "Neue Folie: Wiederholung Matrizen\n2 / 5",
                   "Eigenwerte   und Eigenvektoren 3 / 5 – 19.10.2026", "Determinante und Unabhängigkeit\n4 / 5", "Fragen?\n5 / 5"]
        let r = PageMatch.match(old: old, new: new)
        XCTAssertEqual(pairs(r), ["1>1 gleich", "2>3 gleich", "3>4 gleich", "4>5 gleich"])
        XCTAssertEqual(r.added, [2])
        XCTAssertEqual(PageMatch.words("Seite 12 von 30, Stand 1.2.26"), ["seite", "#", "von", "#,", "stand", "#.#.#"])
    }

    /// Entfernte Seite, verschobene Seite (folgt ihrem Text), geaenderte Seite (aehnlich, zu pruefen), ganz neue Seite
    func testRemovedMovedChangedAndNewPages() {
        let a = "Kapitel eins: Vektorräume über Körpern, Unterräume, Basis und Dimension mit Beispielen"
        let b = "Kapitel zwei: Lineare Abbildungen, Kern, Bild und Dimensionsformel mit Beweis"
        let c = "Kapitel drei: Matrizen, Rang und lineare Gleichungssysteme nach Gauß"
        let d = "Kapitel vier: Determinanten nach Leibniz und Laplace mit Rechenregeln"
        let bChanged = "Kapitel zwei: Lineare Abbildungen, Kern, Bild und Rangsatz mit Beweis und Beispiel"
        let r = PageMatch.match(old: [a, b, c, d], new: [a, d, bChanged, "Völlig anderes Thema Graphentheorie Knoten Kanten"])
        XCTAssertEqual(pairs(r), ["1>1 gleich", "2>3 aehnlich", "4>2 gleich"])
        XCTAssertEqual(r.removed, [3])
        XCTAssertEqual(r.added, [4])
        let similar = try? XCTUnwrap(r.pair(old: 2))
        XCTAssertGreaterThanOrEqual(similar?.ratio ?? 0, PageMatch.minimumRatio)
        XCTAssertLessThan(similar?.ratio ?? 1, 1)
    }

    /// Gleiche Seiten (Titel am Anfang und Ende): sicher nur im Block mit einer eindeutigen Seite und mit beiden
    /// Nachbarn darin (oder am Ende beider Fassungen), sonst nach der Lage und zu pruefen; Seiten ohne Text (Scan,
    /// Leerseite) nach ihrer Position zur naechsten zugeordneten Seite, zuerst auf eine Seite ohne Text; ganz ohne Text
    /// Seite fuer Seite
    func testDuplicatesAndPagesWithoutText() {
        let t = "Titel Lineare Algebra Wintersemester"
        let e = "Eigenwerte einer Matrix und ihr charakteristisches Polynom"
        let r = PageMatch.match(old: [t, e, "", t], new: [t, "Neu eingefügt: Motivation und Überblick", e, "", t])
        XCTAssertEqual(pairs(r), ["1>1 wiederholt", "2>3 gleich", "3>4 position", "4>5 gleich"])
        // Leerseite hinter einer neuen Seite: Abstand zur folgenden Seite (Leerseite vor Seite mit Text)
        let r2 = PageMatch.match(old: [t, "", e], new: [t, "Neue Seite mit Text dazwischen", "", e])
        XCTAssertEqual(pairs(r2), ["1>1 gleich", "2>3 position", "3>4 gleich"])
        let scans = PageMatch.match(old: ["", "", ""], new: ["", "", "", ""])
        XCTAssertEqual(pairs(scans), ["1>1 position", "2>2 position", "3>3 position"])
        XCTAssertEqual(scans.added, [4])
        XCTAssertEqual(pairs(PageMatch.byPosition(oldCount: 3, newCount: 2)), ["1>1 position", "2>2 position"])
    }

    /// Wiederholte Notizseiten ("Platz für Notizen" nach jedem Kapitel): ein neues Kapitel mit eigener Notizseite nach
    /// Kapitel 1. Vorher wurden gleiche Seiten nur der Reihe nach vergeben und galten als sicher: die Notizen der Seite
    /// nach "Eigenwerte" landeten nach "Lineare Abbildungen", ohne Hinweis. Jetzt folgt jede Notizseite ihrem Kapitel;
    /// die eine, deren Nachbarn sich geaendert haben, ist zu pruefen.
    func testRepeatedNotesPagesFollowTheirChapter() {
        let n = "Platz für Notizen"
        let old = ["Kapitel 1: Vektorräume", n, "Kapitel 2: Eigenwerte", n, "Kapitel 3: Determinanten", n]
        let new = ["Kapitel 1: Vektorräume", n, "Kapitel 2: Lineare Abbildungen", n, "Kapitel 3: Eigenwerte", n, "Kapitel 4: Determinanten", n]
        let r = PageMatch.match(old: old, new: new)
        XCTAssertEqual(pairs(r), ["1>1 gleich", "2>2 wiederholt", "3>5 gleich", "4>6 gleich", "5>7 gleich", "6>8 gleich"])
        XCTAssertEqual(r.added, [3, 4])
        XCTAssertEqual(r.removed, [])
        // Gegenrichtung: Kapitel A mit seiner Notizseite entfernt; die Notizseite von B bleibt bei B
        let back = PageMatch.match(old: ["Kapitel A: Gruppen", n, "Kapitel B: Ringe", n], new: ["Kapitel B: Ringe", n])
        XCTAssertEqual(pairs(back), ["3>1 gleich", "4>2 gleich"])
        XCTAssertEqual(back.removed, [1, 2])
        // Gliederungsfolie vor jedem Kapitel, ein Kapitel kommt dazu: ob die Folie zum Kapitel davor oder danach gehoert,
        // laesst sich am Text nicht erkennen; bei Gleichstand gilt die Seite davor (wie bei Notizseiten), zu pruefen
        let g = "Gliederung: Einleitung, Grundlagen, Anwendungen"
        let outline = PageMatch.match(old: [g, "Einleitung und Motivation", g, "Grundlagen der Optik"],
                                      new: [g, "Einleitung und Motivation", g, "Neu: Geschichte der Optik", g, "Grundlagen der Optik"])
        XCTAssertEqual(pairs(outline), ["1>1 gleich", "2>2 gleich", "3>3 wiederholt", "4>6 gleich"])
    }

    /// Seiten, die sich nur in Zahlen unterscheiden ("Blatt 1", "Blatt 2"), sind gleich (Ziffern zaehlen nicht) und
    /// darum mehrfach vorhanden: ohne eindeutige Nachbarn nach der Lage zugeordnet und zu pruefen, nicht still sicher
    func testPagesDifferingOnlyInNumbersAreChecked() {
        let r = PageMatch.match(old: ["Blatt 1: Aufgaben zur Woche", "Hinweise zur Abgabe", "Blatt 2: Aufgaben zur Woche", "Hinweise zur Abgabe"],
                                new: ["Blatt 2: Aufgaben zur Woche", "Hinweise zur Abgabe"])
        XCTAssertEqual(pairs(r), ["1>1 wiederholt", "2>2 wiederholt"])
        XCTAssertEqual(r.removed, [3, 4])
        // mit eindeutigem Nachbarn im selben Block: sicher
        let anchored = PageMatch.match(old: ["Blatt 1: Aufgaben zur Woche", "Eigenwerte berechnen", "Blatt 2: Aufgaben zur Woche", "Determinanten"],
                                       new: ["Blatt 1: Aufgaben zur Woche", "Eigenwerte berechnen", "Blatt 2: Aufgaben zur Woche", "Determinanten", "Anhang"])
        XCTAssertEqual(pairs(anchored), ["1>1 gleich", "2>2 gleich", "3>3 gleich", "4>4 gleich"])
    }

    /// Scan (Seiten ohne Text) in einer der Fassungen: Seite fuer Seite, alle zu pruefen (vorher fiel alles heraus und
    /// die Notizen standen nur noch in der alten Fassung); eine einzelne gescannte Seite nach ihrer Lage
    func testScannedVersionMapsByPosition() {
        let text = ["Eigenwerte und Eigenvektoren", "Charakteristisches Polynom einer Matrix", "Diagonalisierung"]
        XCTAssertEqual(pairs(PageMatch.match(old: text, new: ["", "", ""])), ["1>1 position", "2>2 position", "3>3 position"])
        XCTAssertEqual(pairs(PageMatch.match(old: ["", "", ""], new: text + ["Anhang"])), ["1>1 position", "2>2 position", "3>3 position"])
        let partly = PageMatch.match(old: text, new: [text[0], "", text[2]])
        XCTAssertEqual(pairs(partly), ["1>1 gleich", "2>2 position", "3>3 gleich"])
        XCTAssertEqual(partly.removed, [])
    }

    /// Grosses Skript (150 Seiten zu 250 Woertern), jede Seite um ein Wort geaendert: alle Seiten aehnlich und auf
    /// ihrem Platz; die Vorfilter rechnen aus Laengen und vorberechneten Haeufigkeiten, `ratio()` nur fuer
    /// hoechstens fuenf Kandidaten je Seite mit einem Index je neuer Seite (vorher 22.500 Vergleiche mit eigenem Index)
    func testLargeScriptMatchesQuickly() {
        var rng = KernSeedRNG(seed: 7)
        let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")    // ohne Ziffern: die zaehlen als "#"
        var vocabulary: [String] = []
        for n in 0..<4000 { vocabulary.append("w" + String([letters[n / 676 % 26], letters[n / 26 % 26], letters[n % 26]])) }
        var old: [String] = [], new: [String] = []
        for _ in 0..<150 {
            var words: [String] = []
            for _ in 0..<250 { words.append(rng.pick(vocabulary)) }
            old.append(words.joined(separator: " "))
            words.insert("geaendert", at: 1)
            new.append(words.joined(separator: " "))
        }
        let start = Date()
        let r = PageMatch.match(old: old, new: new)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(r.pairs.count, 150)
        XCTAssertEqual(r.pairs.filter { $0.old == $0.new && $0.kind == .similar }.count, 150)
        print("PageMatch 150 Seiten zu 250 Woertern: \(String(format: "%.2f", seconds)) s")
        XCTAssertLessThan(seconds, 20, "Debug-Build; im Release deutlich schneller")
    }

    /// Mindestaehnlichkeit 0.6 wie `difflib.get_close_matches`; die Vorfilter aendern nichts am Ergebnis von ratio()
    func testSimilarityThresholdAndQuickRatios() {
        let a = PageMatch.words("eins zwei drei vier fünf sechs sieben acht neun zehn")
        let b = PageMatch.words("eins zwei drei vier fünf sechs ganz andere woerter hier")
        let m = SequenceMatcher(a, b)
        XCTAssertEqual(m.ratio(), 0.6)
        XCTAssertGreaterThanOrEqual(m.quickRatio(), m.ratio())
        XCTAssertGreaterThanOrEqual(m.realQuickRatio(), m.quickRatio())
        XCTAssertEqual(pairs(PageMatch.match(old: [a.joined(separator: " ")], new: [b.joined(separator: " ")])), ["1>1 aehnlich"])
        let c = PageMatch.words("eins zwei drei vier fünf ganz andere woerter hier und")
        XCTAssertLessThan(SequenceMatcher(a, c).ratio(), 0.6)
        XCTAssertEqual(PageMatch.match(old: [a.joined(separator: " ")], new: [c.joined(separator: " ")]).pairs, [])
        // Zeichenketten weiter wie difflib (ModuleGuess)
        XCTAssertEqual(SequenceMatcher("abcd", "bcde").ratio(), 0.75)
        XCTAssertEqual(SequenceMatcher("abcd", "bcde").quickRatio(), 0.75)
    }
}

final class NoteTransferTests: XCTestCase {

    private func pdf(_ key: String, _ i: Int, rotation: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["key": .string(key), "type": "pdf", "index": .number(Double(i))]
        if let rotation { o["rotation"] = .number(Double(rotation)) }
        return .object(o)
    }

    private func blank(_ key: String) -> JSONValue { ["key": .string(key), "type": "blank", "template": "lined", "w": 595, "h": 842] }

    private func order(_ doc: AnnotationDocument) -> [String] {
        doc.pageOrder.map { e in "\(e["key"]?.string ?? "")" + (e["type"]?.string == "pdf" ? ":\(e["index"]?.int ?? 0)" : "") }
    }

    func testHasNotes() {
        var doc = AnnotationDocument.empty()
        XCTAssertFalse(NoteTransfer.hasNotes(doc))
        doc.ensurePDFPages(count: 3)
        doc.pages = ["p1": ["objects": []], "p2": ["objects": []]]
        XCTAssertFalse(NoteTransfer.hasNotes(doc), "nur die automatische Seitenliste")
        var strokes = doc
        strokes.pages["p2"] = page(["s1"])
        XCTAssertTrue(NoteTransfer.hasNotes(strokes))
        var bookmark = doc
        bookmark.root["bookmarks"] = [["key": "p1", "title": "Wichtig"]]
        XCTAssertTrue(NoteTransfer.hasNotes(bookmark))
        var rotated = doc
        rotated.root["pageOrder"] = .array([pdf("p1", 1, rotation: 90), pdf("p2", 2), pdf("p3", 3)])
        XCTAssertTrue(NoteTransfer.hasNotes(rotated))
        var inserted = doc
        inserted.root["pageOrder"] = .array([pdf("p1", 1), blank("b1"), pdf("p2", 2), pdf("p3", 3)])
        XCTAssertTrue(NoteTransfer.hasNotes(inserted))
    }

    /// Notizen bleiben auf ihrer Seite: Schluessel und Inhalt unveraendert, nur die PDF-Seite wechselt; eingefuegte
    /// Leerseite geht mit, neue Seite bekommt einen eigenen Schluessel, Papierkorb und Lesezeichen bleiben
    func testNotesFollowTheirPagesIntoNewVersion() throws {
        var doc = AnnotationDocument.empty()
        doc.root["pageOrder"] = .array([pdf("p1", 1), pdf("p2", 2), blank("b1"), pdf("p4", 4)])
        doc.root["deletedPages"] = [["entry": pdf("p3", 3), "objects": [stroke("t1")], "at": 1, "pos": 2]]
        doc.root["bookmarks"] = [["key": "p4", "title": "Satz"]]
        doc.pages = ["p1": ["objects": []], "p2": page(["s2"]), "b1": page(["sb"]), "p3": ["objects": []], "p4": page(["s4"])]
        // neue Fassung: Folie vor Seite 2 eingefuegt, alles danach eine Seite weiter
        let match = PageMatch.Result(oldCount: 4, newCount: 5, pairs: [
            .init(old: 1, new: 1, kind: .same, ratio: 1), .init(old: 2, new: 3, kind: .same, ratio: 1),
            .init(old: 3, new: 4, kind: .same, ratio: 1), .init(old: 4, new: 5, kind: .similar, ratio: 0.8)])
        let r = NoteTransfer.transfer(doc, match: match, version: 2, sha256: "abc")
        XCTAssertEqual(order(r.document), ["p1:1", "p2-v2:2", "p2:3", "b1", "p4:5"])
        XCTAssertEqual(r.addedKeys, ["p2-v2"])
        XCTAssertEqual(r.removedKeys, [])
        XCTAssertEqual(r.document.objects(page: "p2").compactMap { $0["id"]?.string }, ["s2"])
        XCTAssertEqual(r.document.objects(page: "b1").compactMap { $0["id"]?.string }, ["sb"])
        XCTAssertEqual(r.document.objects(page: "p4").compactMap { $0["id"]?.string }, ["s4"])
        XCTAssertEqual(r.document.page("p2-v2"), ["objects": []])
        XCTAssertEqual(r.document.root["deletedPages"]?.array?.first?["entry"]?["index"], 4)
        XCTAssertEqual(r.document.root["bookmarks"], doc.root["bookmarks"])
        XCTAssertEqual(r.document.root["origin"], ["sha256": "abc", "pages": 5, "version": 2])
        XCTAssertEqual(NoteTransfer.pagesWithNotes(doc), [2, 4])
    }

    /// Entfernte Seite: verschwindet samt Inhalt (bleibt auf der alten Fassung), ihre eingefuegte Leerseite haengt an
    /// der vorigen Seite; eine entfernte Seite im Papierkorb faellt dort weg
    func testRemovedPageLeavesNewVersion() {
        var doc = AnnotationDocument.empty()
        doc.root["pageOrder"] = .array([pdf("p1", 1), pdf("p2", 2), blank("b1"), pdf("p3", 3)])
        doc.root["deletedPages"] = [["entry": pdf("p9", 4), "objects": [], "at": 1, "pos": 3]]
        doc.pages = ["p1": page(["s1"]), "p2": page(["s2"]), "b1": page(["sb"]), "p3": ["objects": []]]
        let match = PageMatch.Result(oldCount: 4, newCount: 2, pairs: [.init(old: 1, new: 1, kind: .same, ratio: 1), .init(old: 3, new: 2, kind: .same, ratio: 1)])
        let r = NoteTransfer.transfer(doc, match: match, version: 3, sha256: nil)
        XCTAssertEqual(order(r.document), ["p1:1", "b1", "p3:2"])
        XCTAssertEqual(r.removedKeys, ["p2"])
        XCTAssertNil(r.document.page("p2"))
        XCTAssertEqual(r.document.objects(page: "b1").count, 1)
        XCTAssertEqual(r.document.root["deletedPages"], [])
    }

    /// Hat der Nutzer die Seiten umgestellt, bleibt seine Reihenfolge; neue Seiten hinter die naechstkleinere
    func testUserOrderIsKept() {
        var doc = AnnotationDocument.empty()
        doc.root["pageOrder"] = .array([pdf("p3", 3), pdf("p1", 1), pdf("p2", 2)])
        doc.pages = ["p1": page(["s1"]), "p2": ["objects": []], "p3": ["objects": []]]
        let match = PageMatch.Result(oldCount: 3, newCount: 4, pairs: [
            .init(old: 1, new: 1, kind: .same, ratio: 1), .init(old: 2, new: 3, kind: .same, ratio: 1), .init(old: 3, new: 4, kind: .same, ratio: 1)])
        let r = NoteTransfer.transfer(doc, match: match, version: 2, sha256: nil)
        XCTAssertEqual(order(r.document), ["p3:4", "p1:1", "p2-v2:2", "p2:3"])
        // ohne Seitenliste (nie geoeffnet, nur Lesezeichen): erst p1...pN, dann umhaengen
        var bare = AnnotationDocument.empty()
        bare.root["bookmarks"] = [["key": "p2", "title": "x"]]
        let r2 = NoteTransfer.transfer(bare, match: PageMatch.byPosition(oldCount: 2, newCount: 3), version: 2, sha256: nil)
        XCTAssertEqual(order(r2.document), ["p1:1", "p2:2", "p3:3"])
    }
}

final class FileVersionKeeperTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!

    private struct Env {
        let backend: LocalBackend
        let container: URL
        let keeper: FileVersionKeeper
        var db: SQLiteDatabase { backend.context.database }
    }

    private let oldPages = ["Lineare Algebra Vorlesung 3", "Eigenwerte einer Matrix und charakteristisches Polynom",
                            "Determinante nach Laplace entwickeln", "Fragen?"]

    private func env() async throws -> Env {
        let container = try tempContainer(self)
        let files = LocalFiles(container: container, dataDirectory: "", tools: FormFeedTools())
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, files: files)
        let keeper = FileVersionKeeper(database: backend.context.database, files: files, directory: "StudIP/Fassungen", source: "Stud.IP", clock: clock)
        return Env(backend: backend, container: container, keeper: keeper)
    }

    private func pdfData(_ pages: [String]) -> Data { Data(pages.joined(separator: "\u{C}").utf8) }

    private let path = "StudIP/files/d1/VL03.pdf"

    /// Datei d1 mit der alten Fassung auf der Platte und ihrem Hash (wie nach einem Abgleich)
    private func seed(_ e: Env, notes: JSONValue?, pages: [String]? = nil) async throws -> Data {
        let data = pdfData(pages ?? oldPages)
        let url = e.container.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let p = path
        try await e.db.transaction { c in
            try c.execute("INSERT INTO courses(id, title, created_at) VALUES ('c1', 'Testkurs Lineare Algebra', 'x')")
            try c.execute("""
                INSERT INTO files(id, course_id, name, size, mime, chdate, local_path, downloaded_at, status, content_sha256, kind, download_url)
                VALUES ('d1', 'c1', 'VL03.pdf', ?, 'application/pdf', 100, ?, 'x', 'neu', ?, 'pdf', 'x')
                """, [.integer(Int64(data.count)), .text(p), .text(SolutionSHA256.hex(data))])
        }
        if let notes { try await put(e, "d1", notes, base: 0) }
        return data
    }

    private func put(_ e: Env, _ id: String, _ notes: JSONValue, base: Int) async throws {
        let r = await e.backend.handle(LocalRequest(method: "PUT", path: "/api/files/\(id)/annotations", query: [.init("base_version", "\(base)")],
                                                    headers: ["Content-Type": "application/json"], body: notes.serialized()))
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
    }

    /// Wie der Abgleich, Schritt fuer Schritt: neue Fassung geladen (Zwischenordner), `prepare`, an ihren Platz
    private struct Download {
        let data: Data
        let sha: String
        let prepared: FileVersionKeeper.Prepared
        let path: String
    }

    private func download(_ e: Env, _ pages: [String], to target: String? = nil) async throws -> Download {
        let data = pdfData(pages)
        let temp = e.container.appendingPathComponent(".laden/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: temp)
        let sha = SolutionSHA256.hex(data), p = target ?? path
        let prepared = try await e.keeper.prepare(fileID: "d1", newSHA: sha, newFile: temp, newPath: p)
        let url = e.container.appendingPathComponent(p)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temp, to: url)
        return Download(data: data, sha: sha, prepared: prepared, path: p)
    }

    /// Schritt 2: `markDownloaded` mit Seitentexten, alter Fassung und Notizen in einer Transaktion
    @discardableResult
    private func commit(_ e: Env, _ d: Download, chdate: Int, failAfterMark: Bool = false) async throws -> FileVersionKeeper.Outcome? {
        let row = UniStore.FileRow(id: "d1", name: (d.path as NSString).lastPathComponent, size: d.data.count, mime: "application/pdf",
                                   chdate: chdate, downloadURL: "x", folder: nil)
        let p = d.path, sha = d.sha, now = clock.nowISO
        return try await e.keeper.commit(d.prepared) { c in
            try UniStore.markDownloaded(c, row, localPath: p, sha256: sha, now: now)
            if failAfterMark { throw LocalHTTPError(status: 500, message: "Abbruch zum Test") }
        }
    }

    private func newVersion(_ e: Env, _ pages: [String], chdate: Int, to target: String? = nil) async throws -> FileVersionKeeper.Outcome? {
        try await commit(e, try await download(e, pages, to: target), chdate: chdate)
    }

    private func get(_ e: Env, _ path: String) async -> LocalResponse { await e.backend.handle(LocalRequest(method: "GET", path: path)) }

    private func pageText(_ e: Env, _ id: String, _ page: Int) async -> JSONValue? {
        await e.backend.handle(LocalRequest(method: "GET", path: "/api/files/\(id)/pagetext", query: [.init("page", "\(page)")])).json?["text"]
    }

    private func document(_ e: Env, _ id: String) async throws -> AnnotationDocument {
        AnnotationDocument(root: try await data(e, "/api/files/\(id)/annotations"))
    }

    private func data(_ e: Env, _ path: String) async throws -> JSONValue {
        let r = await get(e, path)
        return try XCTUnwrap(r.json?["data"], path)
    }

    private var notes: JSONValue {
        ["version": 2, "zoom": 1.2, "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2],
                                                   ["key": "p3", "type": "pdf", "index": 3], ["key": "p4", "type": "pdf", "index": 4]],
         "pages": ["p1": ["objects": []], "p2": page(["auf-eigenwerte"]), "p3": page(["auf-determinante"]), "p4": page(["auf-fragen"])]]
    }

    /// Kopie d1-kopie ("Duplizieren": gleiche Datei, gleiche Download-Adresse) mit Notizen auf Seite 3
    private func addCopy(_ e: Env) async throws {
        let p = path
        try await e.db.transaction { c in
            try c.execute("""
                INSERT INTO files(id, course_id, name, size, mime, chdate, local_path, downloaded_at, status, kind, download_url)
                VALUES ('d1-kopie', 'c1', 'VL03.pdf', 1, 'application/pdf', 100, ?, 'x', 'gelesen', 'pdf', 'x')
                """, [.text(p)])
        }
        let copyNotes: JSONValue = ["version": 2, "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2],
                                                                ["key": "p3", "type": "pdf", "index": 3], ["key": "p4", "type": "pdf", "index": 4]],
                                    "pages": ["p3": page(["kopie-determinante"])]]
        try await put(e, "d1-kopie", copyNotes, base: 0)
    }

    private let fivePages = ["Lineare Algebra Vorlesung 3", "Neue Folie", "Eigenwerte einer Matrix und charakteristisches Polynom",
                             "Determinante nach Laplace entwickeln", "Fragen?"]

    /// Abnahme S7 im Kern: Datei mit Notizen bekommt eine neue Fassung (Folie eingefuegt, Determinanten-Seite
    /// geaendert, "Fragen?" entfernt) -> alte PDF aufbewahrt, Notizen auf den passenden neuen Seiten, die Notizen der
    /// entfernten Seite nur auf der alten Fassung, Hinweis mit zu pruefenden Seiten, alte Fassung mit ihren Notizen
    /// lesbar (und ihre Bytes mit unveraendertem Fingerabdruck fuer geteilte Loesungen)
    func testNewVersionWithNotesKeepsOldVersionAndMovesNotes() async throws {
        let e = try await env()
        let old = try await seed(e, notes: notes)
        let newPages = ["Lineare Algebra Vorlesung 3", "Wiederholung: Matrizen und lineare Abbildungen",
                        "Eigenwerte einer Matrix und charakteristisches Polynom", "Determinante nach Laplace entwickeln mit Beispiel"]
        let d = try await download(e, newPages)
        guard case .keep(let k) = d.prepared.plan else { return XCTFail("\(d.prepared.plan)") }
        XCTAssertEqual(k.keptPath, "StudIP/Fassungen/d1/\(SolutionSHA256.hex(old)).pdf")
        XCTAssertEqual(k.pageTexts, oldPages)
        XCTAssertEqual(d.prepared.newTexts, newPages, "Seitentexte der neuen Fassung aus der geladenen Datei")
        let outcome = try await commit(e, d, chdate: 200)
        XCTAssertEqual(outcome, FileVersionKeeper.Outcome(version: 1, check: 1, removed: 1))

        // Notizen der neuen Fassung
        let ann = await get(e, "/api/files/d1/annotations")
        XCTAssertEqual(ann.json?["version"], 2)
        let doc = AnnotationDocument(root: try XCTUnwrap(ann.json?["data"]))
        XCTAssertEqual(doc.pageOrder.map { "\($0["key"]?.string ?? ""):\($0["index"]?.int ?? 0)" }, ["p1:1", "p2-v2:2", "p2:3", "p3:4"])
        XCTAssertEqual(doc.objects(page: "p2").compactMap { $0["id"]?.string }, ["auf-eigenwerte"])
        XCTAssertEqual(doc.objects(page: "p3").compactMap { $0["id"]?.string }, ["auf-determinante"])
        XCTAssertNil(doc.page("p4"), "entfernte Seite nur noch auf der alten Fassung")
        XCTAssertEqual(doc.root["origin"]?["sha256"]?.string, d.sha)
        XCTAssertEqual(doc.root["origin"]?["version"], 2)

        // Hinweis und alte Fassung
        let list = await get(e, "/api/files/d1/versions")
        let v = try XCTUnwrap(list.json?["versions"]?.array?.first)
        XCTAssertEqual(list.json?["notice"], v)
        XCTAssertEqual(v["version"], 1)
        XCTAssertEqual(v["source"], "Stud.IP")
        XCTAssertEqual(v["available"], true)
        XCTAssertEqual(v["document_id"], "d1/versions/1")
        XCTAssertEqual(v["check"], [["old": 3, "new": 4, "kind": "aehnlich"]])
        XCTAssertEqual(v["removed"], [4])
        XCTAssertEqual(v["added"], [2])
        XCTAssertEqual(v["content_sha256"]?.string, SolutionSHA256.hex(old))
        let content = await get(e, "/api/files/d1/versions/1/content")
        XCTAssertEqual(content.body, old)
        XCTAssertEqual(content.headers["Content-Type"], "application/pdf")
        XCTAssertEqual(SolutionSHA256.hex(content.body), v["content_sha256"]?.string, "Fingerabdruck der alten Fassung bleibt")
        let oldNotes = await get(e, "/api/files/d1/versions/1/annotations")
        XCTAssertEqual(oldNotes.json?["data"], notes)
        XCTAssertEqual(oldNotes.json?["version"], 1)
        // alte Fassung nur zum Ansehen
        let put = await e.backend.handle(LocalRequest(method: "PUT", path: "/api/files/d1/versions/1/annotations", query: [.init("base_version", "1")],
                                                      headers: ["Content-Type": "application/json"], body: notes.serialized()))
        XCTAssertEqual(put.status, 409)
        XCTAssertNil(put.json?["version"])
        _ = await e.backend.handle(LocalRequest(method: "POST", path: "/api/files/d1/versions/seen"))
        let seen = await get(e, "/api/files/d1/versions")
        XCTAssertEqual(seen.json?["notice"], .null)
        XCTAssertEqual(seen.json?["versions"]?.array?.first?["seen"], true)

        // Seitentexte der neuen Fassung stehen fuer die Suche bereit (in derselben Transaktion geschrieben)
        let texts = try await e.db.rows("SELECT page, text, chdate, search FROM page_texts WHERE file_id='d1' ORDER BY page")
        XCTAssertEqual(texts.compactMap { $0["text"]?.string }, newPages)
        XCTAssertEqual(Set(texts.compactMap { $0["chdate"] }), [200])
        XCTAssertEqual(texts.first?["search"], "lineare algebra vorlesung 3")
        let hit = await e.backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "wiederholung")]))
        XCTAssertEqual(hit.json?["pages"]?.array?.first?["page"], 2)

        // die aufbewahrte PDF bleibt, auch wenn die Stud.IP-Dateien geloescht werden; eine weitere Fassung wird Nummer 2
        try FileManager.default.removeItem(at: e.container.appendingPathComponent("StudIP/files"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.container.appendingPathComponent(try XCTUnwrap(k.keptPath)).path))
        let third = ["Lineare Algebra Vorlesung 3", "Eigenwerte einer Matrix und charakteristisches Polynom"]
        let again = try await download(e, third)
        guard case .keep(let k2) = again.prepared.plan else { return XCTFail("\(again.prepared.plan)") }
        XCTAssertNil(k2.keptPath, "alte Datei fehlt: nur der Stand der Notizen und die gespeicherten Seitentexte")
        XCTAssertEqual(k2.pageTexts, newPages)
        let o2 = try await commit(e, again, chdate: 300)
        XCTAssertEqual(o2?.version, 2)
        let both = await get(e, "/api/files/d1/versions")
        XCTAssertEqual(both.json?["versions"]?.array?.compactMap { $0["version"]?.int }, [2, 1])
        XCTAssertEqual(both.json?["versions"]?.array?.first?["available"], false)
        XCTAssertEqual(both.json?["notice"]?["version"], 2)
        let missing = await get(e, "/api/files/d1/versions/2/content")
        XCTAssertEqual(missing.status, 404)
        let doc3 = try await document(e, "d1")
        XCTAssertEqual(doc3.pageOrder.compactMap { $0["key"]?.string }, ["p1", "p2"])
        XCTAssertEqual(doc3.objects(page: "p2").compactMap { $0["id"]?.string }, ["auf-eigenwerte"])
    }

    /// Ohne Notizen: ersetzen wie bisher (keine alte Fassung); eine automatisch angelegte Seitenliste wird geleert, damit
    /// der Editor neue Seiten zeigt. Gleicher Inhalt (anderes Datum in Stud.IP): nichts. Ohne Notizen-Zeile: nichts.
    func testWithoutNotesOrSameContentNothingIsKept() async throws {
        let e = try await env()
        _ = try await seed(e, notes: ["version": 2, "pageOrder": [["key": "p1", "type": "pdf", "index": 1]], "pages": ["p1": ["objects": []]]])
        let five = oldPages + ["Neue Seite"]
        let d = try await download(e, five)
        XCTAssertEqual(d.prepared.plan, .resetPageList)
        let finished = try await commit(e, d, chdate: 200)
        XCTAssertNil(finished)
        let ann = await get(e, "/api/files/d1/annotations")
        XCTAssertEqual(ann.json?["data"]?["pageOrder"], [])
        XCTAssertEqual(ann.json?["version"], 2)
        let list = await get(e, "/api/files/d1/versions")
        XCTAssertEqual(list.json, ["versions": [], "notice": .null])
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.container.appendingPathComponent("StudIP/Fassungen").path))
        let stored = try await e.db.rows("SELECT text FROM page_texts WHERE file_id='d1' ORDER BY page")
        XCTAssertEqual(stored.compactMap { $0["text"]?.string }, five, "Seitentexte auch ohne Notizen")

        // gleicher Inhalt: nichts
        let same = try await e.keeper.prepare(fileID: "d1", newSHA: SolutionSHA256.hex(pdfData(five)))
        XCTAssertEqual(same.plan, .none)
        // Datei ohne Notizen-Zeile: nichts
        try await e.db.execute("DELETE FROM annotations")
        let none = try await e.keeper.prepare(fileID: "d1", newSHA: "anders")
        XCTAssertEqual(none.plan, .none)
    }

    /// Kopie der Datei ("Duplizieren", gleiche PDF) mit eigenen Notizen: bekommt die neue Fassung mit, ihre Notizen
    /// werden ebenso umgehaengt (eigene alte Fassung mit derselben aufbewahrten PDF), ihr Ladezeitpunkt geht mit
    func testCopySharingTheFileMovesItsNotesToo() async throws {
        let e = try await env()
        _ = try await seed(e, notes: notes)
        try await addCopy(e)
        let d = try await download(e, fivePages)
        XCTAssertEqual(d.prepared.copies.map(\.fileID), ["d1-kopie"])
        guard case .keep = d.prepared.copies.first?.plan else { return XCTFail("\(d.prepared.copies)") }
        try await commit(e, d, chdate: 200)
        let doc = try await document(e, "d1-kopie")
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p3"), 4)
        XCTAssertEqual(doc.objects(page: "p3").compactMap { $0["id"]?.string }, ["kopie-determinante"])
        let versions = await get(e, "/api/files/d1-kopie/versions")
        XCTAssertEqual(versions.json?["versions"]?.array?.first?["available"], true)
        let content = await get(e, "/api/files/d1-kopie/versions/1/content")
        XCTAssertEqual(content.body, pdfData(oldPages))
        let stamps = try await e.db.rows("SELECT id, downloaded_at FROM files ORDER BY id")
        XCTAssertEqual(stamps.map { $0["downloaded_at"] }, [.string(clock.nowISO), .string(clock.nowISO)])
    }

    /// Neue Fassung unter neuem Namen (neuer Ablageort): die Kopie zieht mit an den neuen Ort. Vorher wurden ihre
    /// Notizen auf die neuen Seitenzahlen umgehaengt, sie zeigte aber weiter die alte PDF (Notiz auf Seite 4 einer
    /// dreiseitigen PDF unsichtbar, dauerhaft "nur ansehen").
    func testRenamedNewVersionMovesCopyAlong() async throws {
        let e = try await env()
        _ = try await seed(e, notes: notes)
        try await addCopy(e)
        let renamed = "StudIP/files/d1/VL03-korrigiert.pdf"
        let d = try await download(e, fivePages, to: renamed)
        XCTAssertEqual(d.prepared.copies.map(\.fileID), ["d1-kopie"])
        try await commit(e, d, chdate: 200)
        let rows = try await e.db.rows("SELECT id, local_path, downloaded_at FROM files ORDER BY id")
        XCTAssertEqual(rows.map { $0["local_path"] }, [.string(renamed), .string(renamed)])
        XCTAssertEqual(rows.map { $0["downloaded_at"] }, [.string(clock.nowISO), .string(clock.nowISO)])
        let copy = try await document(e, "d1-kopie")
        XCTAssertEqual(copy.pdfIndex(forPageKey: "p3"), 4)
        XCTAssertEqual(copy.root["origin"]?["sha256"]?.string, d.sha)
        // die Kopie liefert die neue PDF, deren Seite 4 die Determinanten-Seite ist
        let content = await get(e, "/api/files/d1-kopie/content")
        XCTAssertEqual(content.body, d.data)
        let text = await pageText(e, "d1-kopie", 4)
        XCTAssertEqual(text, "Determinante nach Laplace entwickeln")
    }

    /// Nach "Abmelden und Dateien löschen" (Datei und Kopie ohne Ablageort): die Kopie wird trotzdem gefunden (gleiche
    /// Download-Adresse), bekommt den Ablageort zurueck, ihre Notizen werden umgehaengt und sie hat eine alte Fassung
    /// (ohne PDF, nur Notizen). Vorher blieben ihre Notizen an den alten Seitenzahlen der neuen PDF.
    func testCopyAfterForgetDownloadsGetsNotesMoved() async throws {
        let e = try await env()
        _ = try await seed(e, notes: notes)
        try await addCopy(e)
        let pages = oldPages
        try await e.db.transaction { c in try ScriptSearch.storePages(c, fileID: "d1", pages: pages, chdate: .integer(100)) }
        let forgotten = try await e.db.transaction { try StudIPLibrary.forgetDownloads($0, under: "StudIP/") }
        XCTAssertEqual(forgotten, ["d1", "d1-kopie"])
        try FileManager.default.removeItem(at: e.container.appendingPathComponent("StudIP/files"))
        let d = try await download(e, fivePages)
        XCTAssertEqual(d.prepared.copies.map(\.fileID), ["d1-kopie"])
        try await commit(e, d, chdate: 200)
        let rows = try await e.db.rows("SELECT local_path FROM files ORDER BY id")
        XCTAssertEqual(rows.map { $0["local_path"] }, [.string(path), .string(path)])
        let copy = try await document(e, "d1-kopie")
        XCTAssertEqual(copy.pdfIndex(forPageKey: "p3"), 4, "Determinanten jetzt auf Seite 4")
        XCTAssertEqual(copy.root["origin"]?["sha256"]?.string, d.sha)
        let versions = await get(e, "/api/files/d1-kopie/versions")
        XCTAssertEqual(versions.json?["versions"]?.array?.count, 1)
        XCTAssertEqual(versions.json?["versions"]?.array?.first?["available"], false)
    }

    /// Endet die App zwischen Ersetzen der Datei und `commit` (oder scheitert `commit`), bleibt die Datenbank beim
    /// alten Stand: keine Notizen 1:1 auf der neuen PDF, keine verwaiste alte Fassung. Der naechste Abgleich laedt die
    /// Datei erneut (`storeFiles`), nimmt die schon aufbewahrte alte PDF und haengt die Notizen richtig um.
    func testInterruptedOrFailedCommitHealsWithNextSync() async throws {
        let e = try await env()
        let old = try await seed(e, notes: notes)
        // 1. Abbruch nach dem Ersetzen: kein commit
        _ = try await download(e, fivePages)
        // 2. commit scheitert nach markDownloaded: alles zurueck
        let failing = try await download(e, fivePages)
        do {
            try await commit(e, failing, chdate: 200, failAfterMark: true)
            XCTFail("Fehler erwartet")
        } catch {}
        let file = try await e.db.rows("SELECT chdate, content_sha256 FROM files WHERE id='d1'")
        XCTAssertEqual(file.first?["chdate"], 100)
        XCTAssertEqual(file.first?["content_sha256"]?.string, SolutionSHA256.hex(old))
        let unchanged = await get(e, "/api/files/d1/annotations")
        XCTAssertEqual(unchanged.json?["version"], 1)
        XCTAssertEqual(unchanged.json?["data"], notes)
        let none = await get(e, "/api/files/d1/versions")
        XCTAssertEqual(none.json?["versions"], [])
        // der naechste Abgleich haelt die Datei weiter fuer geaendert
        let todo = try await e.db.transaction { c in
            try UniStore.storeFiles(c, courseID: "c1", [UniStore.FileRow(id: "d1", name: "VL03.pdf", size: 1, mime: "application/pdf", chdate: 200,
                                                                         downloadURL: "x", folder: nil)], now: "x", fileExists: { _ in true })
        }
        XCTAssertEqual(todo.map(\.id), ["d1"])
        // 3. erneuter Download: aufbewahrte alte PDF (die Datei am Platz ist schon die neue), Notizen richtig
        let d = try await download(e, fivePages)
        guard case .keep(let k) = d.prepared.plan else { return XCTFail("\(d.prepared.plan)") }
        XCTAssertEqual(k.pageTexts, oldPages)
        let outcome = try await commit(e, d, chdate: 200)
        XCTAssertEqual(outcome?.version, 1)
        let doc = try await document(e, "d1")
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p3"), 4)
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p4"), 5)
        let content = await get(e, "/api/files/d1/versions/1/content")
        XCTAssertEqual(content.body, old)
    }

    /// Kopie ohne Notizen teilt sich die Datei: ihre Seitentexte gehoeren zur alten Fassung und werden verworfen (ihre
    /// Aenderungszeit vom Duplizieren aendert sich nie, sie galten sonst weiter als aktuell); die Suche findet danach
    /// den Text der neuen Fassung, nicht mehr den alten
    func testCopyDropsStalePageTexts() async throws {
        let e = try await env()
        _ = try await seed(e, notes: nil)
        let p = path
        try await e.db.transaction { c in
            try c.execute("""
                INSERT INTO files(id, course_id, name, size, mime, chdate, local_path, downloaded_at, status, kind, download_url)
                VALUES ('d1-kopie', 'c1', 'VL03.pdf', 1, 'application/pdf', 150, ?, 'x', 'gelesen', 'pdf', 'x')
                """, [.text(p)])
        }
        let before = await pageText(e, "d1-kopie", 4)
        XCTAssertEqual(before, "Fragen?")
        _ = try await newVersion(e, ["Lineare Algebra Vorlesung 3", "Jordan-Normalform"], chdate: 200)
        let after = await pageText(e, "d1-kopie", 2)
        XCTAssertEqual(after, "Jordan-Normalform")
        let old = await e.backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "fragen?")]))
        XCTAssertEqual(old.json?["pages"], [])
    }

    /// Kam die neue Fassung, waehrend das Dokument offen war, schickt der Editor danach noch Striche auf eine Seite, die
    /// es in der neuen Fassung nicht gibt (nach dem Zusammenfuehren ohne Eintrag in `pageOrder`): sie kommen in den
    /// Abzug der alten Fassung, die Seite steht unter "Nur in der alten Fassung", der Hinweis ist wieder ungesehen.
    func testLateStrokesOnRemovedPageGoToOldVersion() async throws {
        let e = try await env()
        var start = notes
        start["pages"]?["p4"] = ["objects": []]                       // "Fragen?" noch ohne Notizen
        _ = try await seed(e, notes: start)
        _ = try await newVersion(e, ["Lineare Algebra Vorlesung 3", "Eigenwerte einer Matrix und charakteristisches Polynom",
                                     "Determinante nach Laplace entwickeln"], chdate: 200)
        _ = await e.backend.handle(LocalRequest(method: "POST", path: "/api/files/d1/versions/seen"))
        var current = try await document(e, "d1")
        XCTAssertNil(current.page("p4"))
        XCTAssertEqual(current.pageOrder.compactMap { $0["key"]?.string }, ["p1", "p2", "p3"])
        // ... aber der Hinweis ist schon gesehen: nichts zu tun
        current.pages["p4"] = page(["spaet-1"])
        try await put(e, "d1", current.root, base: 2)
        var old = try await data(e, "/api/files/d1/versions/1/annotations")
        XCTAssertEqual(AnnotationDocument(root: old).objects(page: "p4"), [], "nur solange ein Hinweis offen ist")
        // Hinweis offen: spaete Striche zur alten Fassung
        try await e.db.execute("UPDATE file_versions SET seen=0")
        current.pages["p4"] = page(["spaet-1", "spaet-2"])
        try await put(e, "d1", current.root, base: 3)
        old = try await data(e, "/api/files/d1/versions/1/annotations")
        XCTAssertEqual(AnnotationDocument(root: old).objects(page: "p4").compactMap { $0["id"]?.string }, ["spaet-1", "spaet-2"])
        XCTAssertEqual(AnnotationDocument(root: old).objects(page: "p2").compactMap { $0["id"]?.string }, ["auf-eigenwerte"])
        let v = await get(e, "/api/files/d1/versions")
        XCTAssertEqual(v.json?["notice"]?["removed"], [4])
        XCTAssertEqual(v.json?["notice"]?["seen"], false)
        // Striche auf einer Seite, die es weiter gibt, bleiben nur in der neuen Fassung
        current.pages["p2"] = page(["auf-eigenwerte", "neu-auf-zwei"])
        try await put(e, "d1", current.root, base: 4)
        old = try await data(e, "/api/files/d1/versions/1/annotations")
        XCTAssertEqual(AnnotationDocument(root: old).objects(page: "p2").compactMap { $0["id"]?.string }, ["auf-eigenwerte"])
    }

    /// Neue Fassung als Scan (Seiten ohne Text): die Notizen bleiben Seite fuer Seite im Dokument, alle zu pruefen
    /// (vorher fielen alle heraus und standen nur noch in der alten Fassung)
    func testScannedNewVersionKeepsNotesByPosition() async throws {
        let e = try await env()
        _ = try await seed(e, notes: notes)
        let outcome = try await newVersion(e, ["", "", "", ""], chdate: 200)
        XCTAssertEqual(outcome, FileVersionKeeper.Outcome(version: 1, check: 3, removed: 0))
        let doc = try await document(e, "d1")
        XCTAssertEqual(doc.pageOrder.compactMap { $0["index"]?.int }, [1, 2, 3, 4])
        XCTAssertEqual(doc.objects(page: "p4").compactMap { $0["id"]?.string }, ["auf-fragen"])
        let v = await get(e, "/api/files/d1/versions")
        XCTAssertEqual(v.json?["notice"]?["check"]?.array?.compactMap { $0["kind"]?.string }, ["position", "position", "position"])
    }

    /// Wiederholte Notizseiten im Skript (Abnahme des Befunds): neues Kapitel mit eigener Notizseite nach Kapitel 1.
    /// Die Notizen jeder Notizseite bleiben bei ihrem Kapitel; die eine, deren Nachbar sich geaendert hat, ist zu pruefen.
    func testRepeatedNotesPagesKeepTheirChapterThroughKeeper() async throws {
        let e = try await env()
        let n = "Platz für Notizen"
        let v1 = ["Kapitel 1: Vektorräume", n, "Kapitel 2: Eigenwerte", n, "Kapitel 3: Determinanten", n]
        let marks: JSONValue = ["version": 2, "pageOrder": .array((1...6).map { i -> JSONValue in ["key": .string("p\(i)"), "type": "pdf", "index": .number(Double(i))] }),
                                "pages": ["p2": page(["notiz-vektor"]), "p4": page(["notiz-eigen"]), "p6": page(["notiz-det"])]]
        _ = try await seed(e, notes: marks, pages: v1)
        let v2 = ["Kapitel 1: Vektorräume", n, "Kapitel 2: Lineare Abbildungen", n, "Kapitel 3: Eigenwerte", n, "Kapitel 4: Determinanten", n]
        let outcome = try await newVersion(e, v2, chdate: 200)
        XCTAssertEqual(outcome, FileVersionKeeper.Outcome(version: 1, check: 1, removed: 0))
        let doc = try await document(e, "d1")
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p2"), 2)
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p4"), 6, "Notizen zu Eigenwerte nach Eigenwerte")
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p6"), 8, "Notizen zu Determinanten nach Determinanten")
        let v = await get(e, "/api/files/d1/versions")
        XCTAssertEqual(v.json?["notice"]?["check"], [["old": 2, "new": 2, "kind": "wiederholt"]])
    }

    /// Ohne gespeicherten Hash (Uebernahme von vor S3) zaehlt der Inhalt der Datei; laesst sich die alte Fassung nicht
    /// sichern, scheitert der Schritt (die Datei darf dann nicht ersetzt werden)
    func testUnknownHashAndFailedCopy() async throws {
        let e = try await env()
        let old = try await seed(e, notes: notes)
        try await e.db.execute("UPDATE files SET content_sha256=NULL")
        let same = try await e.keeper.prepare(fileID: "d1", newSHA: SolutionSHA256.hex(old))
        XCTAssertEqual(same.plan, .none, "Hash aus der Datei: gleicher Inhalt")
        let broken = FileVersionKeeper(database: e.db, files: e.keeper.files, directory: "../ausserhalb", source: "Stud.IP", clock: clock)
        do {
            _ = try await broken.prepare(fileID: "d1", newSHA: "neu")
            XCTFail("ohne Sicherung kein Ersetzen")
        } catch {}
        // Seitentexte der alten Fassung aus page_texts, wenn dort gueltig
        try await e.db.transaction { c in
            try ScriptSearch.storePages(c, fileID: "d1", pages: ["gespeichert 1", "gespeichert 2"], chdate: .integer(100))
        }
        let p = try await e.keeper.prepare(fileID: "d1", newSHA: "neu")
        guard case .keep(let k) = p.plan else { return XCTFail("\(p.plan)") }
        XCTAssertEqual(k.pageTexts, ["gespeichert 1", "gespeichert 2"])
    }
}
