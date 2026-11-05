import Foundation
import XCTest
@testable import UniFlowCore

/// Notizen neben der Folie mitschicken (05.11.2026, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md): Verknuepfen der Blattseiten
/// mit der Folie, Einflechten in der Reihenfolge der Seitenleiste, Loesungspaket und Zusammenfuehren, Seitentitel beim
/// Empfaenger und der Block "MEINE NOTIZEN" im Tutor-Prompt.
final class SideNotesTests: XCTestCase {

    private func stroke(_ id: String) -> JSONValue {
        .object(["id": .string(id), "type": "stroke", "color": "#111111", "width": 2, "points": .array([10, 10, 80, 90])])
    }

    private func text(_ id: String, _ t: String) -> JSONValue {
        .object(["id": .string(id), "type": "text", "x": 20, "y": 20, "text": .string(t)])
    }

    /// Skript mit 5 Folien, Seitennotiz "bA" hinter Folie 2 (mit Notiz) und leerer Seitennotiz "bE" hinter Folie 3
    private func script() -> AnnotationDocument {
        var doc = AnnotationDocument.empty()
        doc.ensurePDFPages(count: 5)
        PageOrder.insertBlank(&doc, after: "p2", template: "lined", key: "bA")
        PageOrder.insertBlank(&doc, after: "p3", template: "grid", key: "bE")
        doc.pages["bA"] = .object(["objects": .array([stroke("s-bA")])])
        doc.pages["p1"] = .object(["objects": .array([stroke("s-p1")])])
        return doc
    }

    /// Blatt daneben (Notizbuch) mit drei Seiten: n1 und n2 beschrieben, n3 leer
    private func sheet(_ id: String = "nb-file") -> SideNotes.Sheet {
        var doc = AnnotationDocument.empty()
        for k in ["n1", "n2", "n3"] { PageOrder.insertBlank(&doc, after: nil, template: "grid", width: 595, height: 842, key: k) }
        doc.pages["n1"] = .object(["objects": .array([stroke("s-n1")]), "pkdrawing": .object(["data": "AAAA"])])
        doc.pages["n2"] = .object(["objects": .array([text("t-n2", "Eigenwert = Nullstelle")])])
        return SideNotes.Sheet(fileID: id, document: doc)
    }

    private func keys(_ doc: AnnotationDocument) -> [String] { doc.pageOrder.compactMap { $0["key"]?.string } }

    // MARK: Verknuepfen

    func testFirstSlideWinsAndLinksSurviveJSON() throws {
        var doc = script()
        XCTAssertTrue(SideNotes.needsLink(doc, sheetFile: "nb-file", sheetPage: "n1"))
        XCTAssertTrue(SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n1", to: "p4"))
        XCTAssertFalse(SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n1", to: "p5"), "erste Folie gilt")
        XCTAssertFalse(SideNotes.needsLink(doc, sheetFile: "nb-file", sheetPage: "n1"))
        XCTAssertTrue(SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n2", to: "p4"))
        XCTAssertTrue(SideNotes.link(&doc, sheetFile: "other", sheetPage: "x1", to: "p1"))
        XCTAssertFalse(SideNotes.link(&doc, sheetFile: "", sheetPage: "x", to: "p1"))
        XCTAssertEqual(SideNotes.links(doc), ["nb-file": ["n1": "p4", "n2": "p4"], "other": ["x1": "p1"]])
        XCTAssertEqual(SideNotes.sheetFileIDs(doc), ["nb-file", "other"])
        XCTAssertEqual(doc.root["sideSheets"]?.array?.count, 2, "ein Eintrag je Blatt")
        // Wurzelfeld bleibt beim Speichern und Laden erhalten (unbekannte Felder bleiben, Schema)
        let back = AnnotationDocument(root: try JSONValue.parse(Data(doc.root.jsonString(sortedKeys: true).utf8)))
        XCTAssertEqual(SideNotes.links(back), SideNotes.links(doc))
        // kaputte Eintraege stoeren nicht
        var broken = doc
        broken.root["sideSheets"] = .array([.string("x"), .object(["file": 5]), .object(["file": "f", "pages": .object(["a": 3, "b": "p2"])])])
        XCTAssertEqual(SideNotes.links(broken), ["f": ["b": "p2"]])
    }

    // MARK: Einflechten

    func testSheetPagesFollowTheirSlideAfterItsPageNotes() {
        var doc = script()
        SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n1", to: "p2")
        SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n2", to: "p4")
        SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n3", to: "p4")
        let merged = SideNotes.interleaved(main: doc, sheets: [sheet()])
        XCTAssertEqual(keys(merged), ["p1", "p2", "bA", "sn-n1", "p3", "bE", "p4", "sn-n2", "p5"],
                       "Blatt hinter Folie und Seitennotiz, leere Blattseite n3 fehlt")
        let entry = merged.pageOrder.first { $0["key"]?.string == "sn-n1" }
        XCTAssertEqual(entry?["sideOf"]?.string, "p2")
        XCTAssertEqual(entry?["sideFile"]?.string, "nb-file")
        XCTAssertEqual(entry?["template"]?.string, "grid")
        XCTAssertEqual(merged.objects(page: "sn-n1"), [stroke("s-n1")])
        XCTAssertNil(merged.page("sn-n1")?["pkdrawing"], "keine native Zeichnung im Mitgeschickten")
        XCTAssertEqual(doc.pageOrder.count, 7, "das eigene Dokument bleibt unveraendert")
        XCTAssertEqual(SideNotes.notePages(merged, of: "p2"), ["bA", "sn-n1"])
        XCTAssertEqual(SideNotes.notePages(merged, of: "p4"), ["sn-n2"])
        XCTAssertEqual(SideNotes.notePages(merged, of: "p1"), [])
        XCTAssertEqual(SideNotes.notePageCount(merged), 4)
        XCTAssertEqual(SideNotes.typedText(merged, keys: SideNotes.notePages(merged, of: "p4")), "Eigenwert = Nullstelle")
    }

    func testEmptyPageNotesCanBeSkippedButKeepTheirSheets() {
        var doc = script()
        SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n1", to: "bE")
        let merged = SideNotes.interleaved(main: doc, sheets: [sheet()], skipEmptyNotePages: true)
        XCTAssertEqual(keys(merged), ["p1", "p2", "bA", "p3", "sn-n1", "p4", "p5", "sn-n2"],
                       "leere Seitennotiz bE fehlt, ihr Blatt bleibt hinter Folie 3; unverknuepfte Blattseite ans Ende")
        XCTAssertNil(merged.pageOrder.last?["sideOf"], "unverknuepft")
        XCTAssertEqual(SideNotes.notePages(merged, of: "p3"), ["sn-n1"])
        XCTAssertEqual(SideNotes.notePages(merged, of: "p5"), [], "unverknuepfte gehoeren keiner Folie")
        // Notizbuch ohne Folien: alle Seiten bleiben, auch leere
        var notebook = AnnotationDocument.empty()
        PageOrder.insertBlank(&notebook, after: nil, template: "blank", key: "a")
        PageOrder.insertBlank(&notebook, after: "a", template: "blank", key: "b")
        XCTAssertEqual(keys(SideNotes.interleaved(main: notebook, sheets: [], skipEmptyNotePages: true)), ["a", "b"])
        // ohne Ausschluss bleiben auch leere Blattseiten
        XCTAssertEqual(keys(SideNotes.interleaved(main: script(), sheets: [sheet()], skipEmptySheetPages: false)).suffix(3),
                       ["sn-n1", "sn-n2", "sn-n3"])
    }

    func testLinksToMissingPagesAndKeyCollisions() {
        var doc = script()
        doc.pages["sn-n1"] = .object(["objects": .array([])])           // Schluessel schon vergeben
        SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n1", to: "p9")  // Folie gibt es nicht
        SideNotes.link(&doc, sheetFile: "nb-2", sheetPage: "n1", to: "p1")
        let merged = SideNotes.interleaved(main: doc, sheets: [sheet(), sheet("nb-2")])
        XCTAssertEqual(keys(merged), ["p1", "sn3-n1", "p2", "bA", "p3", "bE", "p4", "p5", "sn2-n1", "sn-n2", "sn2-n2"])
        XCTAssertTrue(["sn-n1", "sn2-n1", "sn12-x"].allSatisfy(SideNotes.isSheetKey))
        XCTAssertFalse(["sn", "snx-1", "b1", "nb-n1", "p2"].contains(where: SideNotes.isSheetKey))
        XCTAssertFalse(SolutionBuilder.isNotebookKey("sn-n1"), "kein Notizblatt-Schluessel: bleibt beim Zusammenfuehren an der Folie")
    }

    // MARK: Loesung

    private let fp = String(repeating: "b", count: 64)

    private func build(_ doc: AnnotationDocument, keys: [String]? = nil, id: UUID = UUID()) throws -> SolutionContent {
        try SolutionBuilder.build(document: doc, selectedKeys: keys ?? SolutionBuilder.defaultSelection(doc), pdfPageCount: 5,
                                  pdfPage: { _ in .init(width: 595, height: 842, rotation: 0) }, images: [:], fingerprint: fp,
                                  title: "Folien", displayName: "", solutionID: id)
    }

    func testSolutionKeepsSheetPagesNextToTheirSlideAlsoAfterMerge() throws {
        var doc = script()
        SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n2", to: "p4")
        let first = try build(SideNotes.interleaved(main: doc, sheets: [sheet()]))
        // n1 ist unverknuepft und steht am Ende, n2 hinter Folie 4 (die selbst keine Notizen hat)
        XCTAssertEqual(first.pages.map(\.key), ["p1", "bA", "sn-n2", "sn-n1"])
        XCTAssertEqual(first.pages.indices.map { SolutionBuilder.pageTitle(first.pages, at: $0) },
                       ["PDF-Seite 1", "Notiz zu Folie 1", "Notiz zu Folie 1", "Notiz zu Folie 1"],
                       "ohne die Folie im Paket heisst die Notiz nach der letzten Folie davor")
        XCTAssertEqual(first.pages[2].kind, .blank)
        XCTAssertEqual(first.pages[2].template, "grid")
        // mit der Folie 4 im Paket: Notiz zu Folie 4; nach dem Zusammenfuehren bleibt sie dort
        doc.pages["p4"] = .object(["objects": .array([stroke("s-p4")])])
        let second = try build(SideNotes.interleaved(main: doc, sheets: [sheet()]))
        XCTAssertEqual(second.pages.map(\.key), ["p1", "bA", "p4", "sn-n2", "sn-n1"])
        XCTAssertEqual(SolutionBuilder.pageTitle(second.pages, at: 3), "Notiz zu Folie 4")
        let merged = try SolutionBuilder.merge(previous: first, new: second)
        XCTAssertEqual(merged.pages.map(\.key), ["p1", "bA", "p4", "sn-n2", "sn-n1"], "sn- bleibt hinter seiner Folie")
        XCTAssertEqual(SolutionBuilder.notePageKeys(second.pages), ["bA", "sn-n2", "sn-n1"])
    }

    func testSelectedNotesBringTheirSlideAlong() throws {
        var doc = script()
        SideNotes.link(&doc, sheetFile: "nb-file", sheetPage: "n2", to: "p4")
        let merged = SideNotes.interleaved(main: doc, sheets: [sheet()])
        // nur Notizseiten gewaehlt: ihre Folien kommen dazu, damit der Empfaenger sie neben der Folie sieht
        let keys = SolutionBuilder.withSlides(merged, keys: ["bA", "sn-n2", "sn-n1"])
        XCTAssertEqual(Set(keys), ["bA", "sn-n2", "sn-n1", "p2", "p4"], "unverknuepftes n1 am Ende bringt keine Folie mit")
        let content = try build(merged, keys: keys)
        XCTAssertEqual(content.pages.map(\.key), ["p2", "bA", "p4", "sn-n2", "sn-n1"])
        XCTAssertEqual(SolutionBuilder.slideKey(of: "sn-n2", in: content.pages), "p4")
        XCTAssertEqual(SolutionBuilder.slideKey(of: "p2", in: content.pages), "p2")
        XCTAssertEqual(SolutionBuilder.withSlides(merged, keys: ["bA"], allowed: { _ in false }), ["bA"])
        XCTAssertEqual(SolutionBuilder.withSlides(merged, keys: ["p1"]), ["p1"], "Folien allein bleiben, wie sie sind")
    }

    func testPageTitles() {
        func page(_ key: String, _ pdf: Int?) -> SolutionPage {
            SolutionPage(key: key, kind: pdf == nil ? .blank : .pdf, pdfIndex: pdf, width: 595, height: 842, rotation: 0, objects: [])
        }
        let pages = [page("b0", nil), page("p2", 2), page("bx", nil), page("p4", 4), page("sn-n1", nil)]
        XCTAssertEqual(pages.indices.map { SolutionBuilder.pageTitle(pages, at: $0) },
                       ["Eigene Seite", "PDF-Seite 2", "Notiz zu Folie 2", "PDF-Seite 4", "Notiz zu Folie 4"])
        XCTAssertEqual(SolutionBuilder.pageTitle(pages, at: 9), "Eigene Seite")
        XCTAssertEqual(SolutionBuilder.notePageKeys([page("b0", nil)] + pages), ["bx", "sn-n1"], "Seiten vor der ersten Folie sind keine Notizseiten")
    }

    // MARK: KI

    func testTutorPromptCarriesOwnNotesOnlyWhenGiven() {
        let plain = AIPrompts.tutor(mode: "ask", pageText: "Folie 4", question: "Stimmt das?")
        XCTAssertEqual(plain, AIPrompts.tutor(mode: "ask", pageText: "Folie 4", question: "Stimmt das?", ownNotes: "  \n"))
        XCTAssertFalse(plain.contains("MEINE NOTIZEN"))
        let p = AIPrompts.tutor(mode: "ask", pageText: "Folie 4", question: "Stimmt das?", ownNotes: " Eigenwert ")
        XCTAssertTrue(p.contains("\n\n" + AIPrompts.ownNotesHeading + "\n<<<\nEigenwert\n>>>\n"))
        XCTAssertLessThan(p.range(of: "MEINE NOTIZEN")!.lowerBound, p.range(of: "MEINE FRAGE")!.lowerBound)
        let long = AIPrompts.tutor(mode: "ask", pageText: "x", ownNotes: String(repeating: "y", count: 5000))
        XCTAssertTrue(long.contains(String(repeating: "y", count: SideNotes.aiNotesChars) + "\n>>>"))
        XCTAssertFalse(long.contains(String(repeating: "y", count: SideNotes.aiNotesChars + 1)))
    }
}
