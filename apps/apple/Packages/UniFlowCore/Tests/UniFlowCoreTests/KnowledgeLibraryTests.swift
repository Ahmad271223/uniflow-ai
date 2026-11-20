import XCTest
@testable import UniFlowCore

/// Wissensbibliothek (20.11.2026): Katalog, Kopfdaten, Abschnitte, Markierungen, Import, Suche und Zuordnung mit der
/// erfundenen Testbibliothek in packages/shared-contracts/fixtures/wissensbibliothek (2 Faecher, 3 Einheiten).
final class KnowledgeLibraryTests: XCTestCase {
    private var fixture: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("packages/shared-contracts/fixtures/wissensbibliothek")
    }

    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("wb-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func catalog() throws -> KnowledgeCatalog {
        try KnowledgeCatalog.parse(Data(contentsOf: fixture.appendingPathComponent("katalog.json")))
    }

    // MARK: Katalog

    func testCatalogReadsSubjectsUnitsAndKeys() throws {
        let c = try catalog()
        XCTAssertEqual(c.version, 1)
        XCTAssertEqual(c.stand, "2026-01-15")
        XCTAssertEqual(c.subjects.map(\.folder), ["Beispielkunde-für-Tests", "Rechnen-Übungsfach"])
        XCTAssertEqual(c.unitCount, 3)
        XCTAssertEqual(c.fileCount, 10)
        let g1 = try XCTUnwrap(c.unit(key: "Beispielkunde-für-Tests/G0001"))
        XCTAssertEqual(g1.area, "Einheiten")
        XCTAssertEqual(g1.semester, "_aeltere-PC-Version")
        XCTAssertEqual(g1.role, "direkt")
        XCTAssertTrue(g1.isCurrentSemester)
        XCTAssertTrue(g1.hasCheckScript)
        XCTAssertEqual(g1.visibleFiles, ["README.md", "01-erklaert.md"])
        XCTAssertEqual(g1.shortTitle, "Folien Beispielkunde, Seiten 1–3")
        // Wochen-Einheit (wie Mathe I): Schluessel ist der Pfad, keine Rolle
        let w = try XCTUnwrap(c.subject("Rechnen-Übungsfach")?.units.first)
        XCTAssertEqual(w.key, "Bibliothek/Rechnen-Übungsfach/Wochen/SoSe 2026/Woche 01")
        XCTAssertEqual(w.area, "Wochen")
        XCTAssertEqual(w.semester, "SoSe 2026")
        XCTAssertEqual(w.role, "")
        XCTAssertEqual(c.unit(key: w.key)?.id, "Woche 01")
        XCTAssertEqual(w.visibleFiles, ["README.md", "01-Vorlesung-erklaert.md", "02-Uebungsblatt-01-geloest.md"])
    }

    func testCatalogIsTolerantAndNormalizesToNFC() throws {
        // NFD im Katalog, Zahl als Text, Einheit ohne Dateien, Fach ohne Ordner, unbekannte Felder
        let nfd = "Beispielkunde-fu\u{0308}r-Tests"
        let json = """
        {"version": "2", "stand": "2026-02-01", "x": [1, 2], "faecher": [
          {"ordner": "\(nfd)", "einheiten": [{"id": "G0007", "pfad": "./Bibliothek/\(nfd)/Einheiten/SoSe_2026/direkt/G0007"}]},
          {"einheiten": []}
        ]}
        """
        let c = try KnowledgeCatalog.parse(Data(json.utf8))
        XCTAssertEqual(c.version, 2)
        XCTAssertEqual(c.subjects.count, 1)
        let u = try XCTUnwrap(c.subjects.first?.units.first)
        XCTAssertEqual(u.subject, "Beispielkunde-für-Tests")
        XCTAssertEqual(u.key, "Beispielkunde-für-Tests/G0007")
        XCTAssertEqual(u.path, "Bibliothek/Beispielkunde-für-Tests/Einheiten/SoSe_2026/direkt/G0007")
        XCTAssertEqual(u.files, [])
        XCTAssertEqual(u.title, "G0007")
        XCTAssertThrowsError(try KnowledgeCatalog.parse(Data("[]".utf8)))
        XCTAssertThrowsError(try KnowledgeCatalog.parse(Data("{\"version\":1}".utf8)))
    }

    func testSemestersCurrentFirstThenNewest() throws {
        let c = try catalog()
        let groups = try XCTUnwrap(c.subject("Beispielkunde-für-Tests")).semesters
        XCTAssertEqual(groups.map(\.semester), ["_aeltere-PC-Version", "WiSe_2024_25"])
        XCTAssertEqual(groups.first?.label, "Aktuelles Semester (WiSe 2026/27)")
        XCTAssertEqual(groups.last?.label, "WiSe 2024/25")
        XCTAssertEqual(groups.last?.roles.first?.label, "Alte Klausuren")
        XCTAssertEqual(groups.first?.roles.first?.label, "Ohne Unterordner")
        XCTAssertGreaterThan(KnowledgeSemester.sortKey("WiSe_2025_26"), KnowledgeSemester.sortKey("SoSe_2025"))
        XCTAssertGreaterThan(KnowledgeSemester.sortKey("SoSe 2026"), KnowledgeSemester.sortKey("WiSe_2025_26"))
        XCTAssertEqual(KnowledgeSemester.label("SoSe_2023"), "SoSe 2023")
    }

    func testFileKindsAndNames() {
        XCTAssertEqual(KnowledgeFileKind.of("_pruefung.py"), .checkScript)
        XCTAssertEqual(KnowledgeFileKind.of("_pruefung_F01.py"), .checkScript)
        XCTAssertEqual(KnowledgeFileKind.of("hilfe.py"), .plainText)
        XCTAssertEqual(KnowledgeFileKind.of("01-Vorlesung-erklaert.md"), .explained)
        XCTAssertEqual(KnowledgeFileKind.of("02-Uebungsblatt-13-geloest.md"), .solved)
        XCTAssertEqual(KnowledgeFileKind.of("kuchen.pf"), .plainText)
        XCTAssertEqual(KnowledgeFileKind.of("bild.png"), .other)
        XCTAssertEqual(KnowledgeFileKind.displayName("README.md"), "Überblick")
        XCTAssertEqual(KnowledgeFileKind.displayName("01-erklaert.md"), "Erklärung")
        XCTAssertEqual(KnowledgeFileKind.displayName("02-geloest.md"), "Lösungen")
        XCTAssertEqual(KnowledgeFileKind.displayName("02-Uebungsblatt-13-geloest.md"), "Übungsblatt 13 gelöst")
        XCTAssertEqual(KnowledgeFileKind.ordered(["_pruefung.py", "a.c", "README.md", "02-geloest.md", "zz.md", "01-erklaert.md"]),
                       ["README.md", "01-erklaert.md", "02-geloest.md", "zz.md", "a.c"])
    }

    // MARK: Kopfdaten, Abschnitte, Markierungen

    func testFrontMatterListsMapsBlocksAndQuotes() throws {
        let text = try String(contentsOf: fixture.appendingPathComponent("Bibliothek/Beispielkunde-für-Tests/Einheiten/_aeltere-PC-Version/direkt/G0001/01-erklaert.md"), encoding: .utf8)
        let doc = KnowledgeDocument.parse(text)
        let fm = try XCTUnwrap(doc.frontMatter)
        XCTAssertEqual(fm["typ"], "folien-erklaert")
        XCTAssertEqual(fm["status"], "alle Seiten erklärt")
        XCTAssertEqual(fm.sources, ["Q1: bsp-folien-teil-a (Seiten 1-3)"])
        XCTAssertEqual(fm["unbekannt"], "wird ignoriert")
        XCTAssertNil(fm["loesung_von"])
        XCTAssertFalse(doc.body.hasPrefix("---"))

        let block = KnowledgeFrontMatter.parse("loesung_von: |\n  KI, unabhängig gelöst,\n  danach verglichen\nquellen: \"Q1 = a.pdf: Seite 2\"\nliste:\n  - \"x: y\"\n  - z\n")
        XCTAssertEqual(block["loesung_von"], "KI, unabhängig gelöst, danach verglichen")
        XCTAssertEqual(block["quellen"], "Q1 = a.pdf: Seite 2")
        XCTAssertEqual(block.values("liste"), ["x: y", "z"])
        // ohne Kopf: kein Front-Matter, Text unveraendert; "---" ohne Ende ist kein Kopf
        XCTAssertNil(KnowledgeDocument.parse("# Titel\n\nText").frontMatter)
        XCTAssertNil(KnowledgeDocument.parse("---\nnur: anfang\n").frontMatter)
    }

    func testWindowsLineEndingsAreRead() {
        // etwa die Haelfte der echten Dateien kommt mit CRLF vom PC; "\r\n" ist in Swift ein einziges Zeichen
        let doc = KnowledgeDocument.parse("---\r\ntyp: uebung-geloest\r\nquellen:\r\n  - \"[Q1] a.pdf\"\r\n---\r\n\r\n## [Q1] Aufgabe 1\r\n\r\nText\r\n## [Q1] Aufgabe 2\r\nMehr\r\n")
        XCTAssertEqual(doc.frontMatter?["typ"], "uebung-geloest")
        XCTAssertEqual(doc.frontMatter?.sources, ["[Q1] a.pdf"])
        XCTAssertEqual(doc.sections.map(\.heading), ["[Q1] Aufgabe 1", "[Q1] Aufgabe 2"])
        XCTAssertFalse(doc.body.contains("\r"))
    }

    func testSectionsSplitAtHeadingsNotInCodeAndAnchorsAreBounded() throws {
        let text = try String(contentsOf: fixture.appendingPathComponent("Bibliothek/Beispielkunde-für-Tests/Einheiten/_aeltere-PC-Version/direkt/G0001/01-erklaert.md"), encoding: .utf8)
        let doc = KnowledgeDocument.parse(text)
        XCTAssertEqual(doc.sections.map(\.heading), [
            "[Q1] bsp-folien-teil-a (Seiten 1–3)", "[Q1] Seite 1: Titelfolie", "[Q1] Seite 2 (Folie 1): Formeln",
            "[Q1] Seite 3: Wiederholung", "[Q1] Seite 31: Spätere Seite",
        ])
        XCTAssertTrue(doc.sections[2].markdown.contains("## keine Überschrift im Code"))
        XCTAssertEqual(doc.sectionIndex(for: "Seite 3"), 3)
        XCTAssertEqual(doc.sectionIndex(for: "[Q1] Seite 31"), 4)
        XCTAssertEqual(doc.sectionIndex(for: "Folie 1"), 2)
        XCTAssertEqual(doc.sectionIndex(for: "s1"), 1)
        XCTAssertNil(doc.sectionIndex(for: "Seite 9"))
    }

    func testMarksBadgesSicNamesAndLinks() throws {
        let base = fixture.appendingPathComponent("Bibliothek")
        let g1 = KnowledgeMarks.scan(try String(contentsOf: base.appendingPathComponent("Beispielkunde-für-Tests/Einheiten/_aeltere-PC-Version/direkt/G0001/01-erklaert.md"), encoding: .utf8))
        XCTAssertEqual(g1.sic, 1)
        XCTAssertEqual(g1.namesRemoved, 1)
        XCTAssertFalse(g1.kiUnchecked)
        XCTAssertEqual(g1.links, [KnowledgeLink(unit: "G0002", hint: "Seite 3")])
        let g2 = KnowledgeMarks.scan(try String(contentsOf: base.appendingPathComponent("Beispielkunde-für-Tests/Einheiten/WiSe_2024_25/Alte-Klausuren/G0002/02-geloest.md"), encoding: .utf8))
        XCTAssertTrue(g2.kiUnchecked)
        let w = KnowledgeMarks.scan(try String(contentsOf: base.appendingPathComponent("Rechnen-Übungsfach/Wochen/SoSe 2026/Woche 01/02-Uebungsblatt-01-geloest.md"), encoding: .utf8))
        XCTAssertTrue(w.independent)
        XCTAssertTrue(w.recomputed)
        XCTAssertFalse(w.kiUnchecked)

        // Formen aus dem Export: mehrere Kennungen, Bereich, [Qk], Folie, Aufgabe
        XCTAssertEqual(KnowledgeMarks.links(in: "alle 60 Seiten identisch mit G0001/G0002 (S. 54)").map(\.unit), ["G0001", "G0002"])
        XCTAssertEqual(KnowledgeMarks.links(in: "Folien ab 3 pixelidentisch mit G0020–G0022 (HÜ4)").map(\.unit), ["G0020", "G0022"])
        XCTAssertEqual(KnowledgeMarks.links(in: "identisch mit G0059 [Q2] Aufgabe 1-2 → Lösung dort"), [KnowledgeLink(unit: "G0059", hint: "[Q2] Aufgabe 1-2")])
        XCTAssertEqual(KnowledgeMarks.links(in: "Identisch mit G0035 Folie 31-32 → Erklärung dort."), [KnowledgeLink(unit: "G0035", hint: "Folie 31-32")])
        XCTAssertEqual(KnowledgeMarks.links(in: "identisch mit G0009 (Ersatzschaltbilder)"), [KnowledgeLink(unit: "G0009")])
        XCTAssertEqual(KnowledgeMarks.links(in: "nicht identisch mit dem Original"), [])
        XCTAssertEqual(KnowledgeMarks.links(in: "Schema: „identisch mit G006x Seite N → Erklärung dort“"), [])
        XCTAssertTrue(KnowledgeMarks.scan("abgleich: KI-Lösung, nicht bestätigt (keine Musterlösung)").kiUnchecked)
    }

    func testSourceMatchingNeedsWholeTitle() {
        let blob = KnowledgeSourceMatch.blob(["[Q1] Übungsblatt 01.pdf, Seiten 1-1", "Q1 = Probeklausur_Beispiel_2025.pdf, Seiten 1-2"])
        XCTAssertTrue(KnowledgeSourceMatch.matches(candidates: KnowledgeSourceMatch.candidates(title: "Übungsblatt 01", fileName: nil), blob: blob))
        XCTAssertTrue(KnowledgeSourceMatch.matches(candidates: KnowledgeSourceMatch.candidates(title: nil, fileName: "Probeklausur Beispiel 2025.pdf"), blob: blob))
        // "Übungsblatt 0" ist kein ganzer Titel, "Blatt" zu kurz
        XCTAssertFalse(KnowledgeSourceMatch.matches(candidates: KnowledgeSourceMatch.candidates(title: "Übungsblatt 0", fileName: nil), blob: blob))
        XCTAssertEqual(KnowledgeSourceMatch.candidates(title: "Blatt", fileName: "b.pdf"), ["blatt"])
        XCTAssertFalse(KnowledgeSourceMatch.matches(candidates: [], blob: blob))
    }

    // MARK: Import, Ersetzen, Suche

    func testImportCopiesWithoutCheckScriptsBuildsIndexAndSearches() throws {
        let store = KnowledgeLibraryStore(containerRoot: temp)
        var progressed = false
        let outcome = try store.importLibrary(from: fixture, clock: .fixed(Date(timeIntervalSince1970: 1_790_000_000))) { _, _ in progressed = true }
        guard case .imported(let m) = outcome else { return XCTFail("nicht importiert: \(outcome)") }
        XCTAssertTrue(progressed)
        XCTAssertEqual(m.stand, "2026-01-15")
        XCTAssertEqual(m.units, 3)
        XCTAssertEqual(m.subjects, 2)
        XCTAssertEqual(m.files, 8)                                   // 10 laut Katalog minus 2 Pruefskripte
        XCTAssertEqual(m.missingCount, 0)
        XCTAssertEqual(m.markdownFiles, 7)
        let lib = try XCTUnwrap(try store.load())
        let fm = FileManager.default
        let all = fm.enumerator(atPath: store.currentFolder.path)?.allObjects as? [String] ?? []
        XCTAssertFalse(all.contains { $0.hasSuffix(".py") }, "Pruefskripte duerfen nicht kopiert werden")
        XCTAssertEqual(lib.title(of: lib.catalog.subjects[1]), "Rechnen (Übungsfach)")

        let g1 = try XCTUnwrap(lib.catalog.unit(key: "Beispielkunde-für-Tests/G0001"))
        XCTAssertEqual(lib.summary(g1).types, ["folien-erklaert"])
        XCTAssertEqual(lib.summary(g1).marks.sic, 1)
        XCTAssertTrue(lib.summary(g1).sources.contains("Q1: bsp-folien-teil-a (Seiten 1-3)"))
        XCTAssertEqual(lib.resolve(KnowledgeLink(unit: "G0002"), from: g1)?.id, "G0002")
        XCTAssertTrue(try lib.read(g1, file: "01-erklaert.md").contains("Zitronenfalter"))
        XCTAssertEqual(try lib.read(g1, file: "_pruefung.py"), "")
        let g2 = try XCTUnwrap(lib.catalog.unit(key: "Beispielkunde-für-Tests/G0002"))
        XCTAssertTrue(lib.summary(g2).marks.kiUnchecked)
        XCTAssertEqual(try lib.read(g2, file: "notizen.csv"), "aufgabe;ergebnis\n1a;9\n1b;12\n")

        // Suche: Gross/klein egal, alle Woerter, aktuelles Semester zuerst, Sprung auf den Abschnitt
        let hits = try lib.search("ZITRONENFALTER")
        XCTAssertEqual(hits.map(\.unitKey), ["Beispielkunde-für-Tests/G0001", "Beispielkunde-für-Tests/G0002"])
        XCTAssertEqual(hits.first?.heading, "[Q1] Seite 1: Titelfolie")
        XCTAssertEqual(hits.first?.section, 1)
        XCTAssertTrue(hits.first?.snippet.contains("Zitronenfalter") == true)
        XCTAssertEqual(try lib.search("fünf minus").map(\.heading), ["[Q1] Seite 2: Subtraktion"])
        XCTAssertEqual(try lib.search("ALLES OK"), [], "Pruefskripte sind nicht durchsuchbar")
        XCTAssertEqual(try lib.search("x"), [])
        // Ueberschrift zuerst
        XCTAssertEqual(try lib.search("wiederholung").first?.heading, "[Q1] Seite 3: Wiederholung")

        // Zuordnung Stud.IP-Datei -> Einheit
        XCTAssertEqual(lib.units(matchingTitle: "bsp-folien-teil-a", fileName: "bsp-folien-teil-a.pdf").map(\.id), ["G0001"])
        XCTAssertEqual(lib.units(matchingTitle: "Probeklausur_Beispiel_2025", fileName: nil).map(\.id), ["G0002"])
        XCTAssertEqual(lib.units(matchingTitle: "Übungsblatt 01", fileName: nil).map(\.id), ["Woche 01"])
        XCTAssertEqual(lib.units(matchingTitle: "Ganz andere Datei", fileName: "x.pdf"), [])
    }

    func testReimportSameStandIsCurrentNewerReplacesOlderIsKept() throws {
        let store = KnowledgeLibraryStore(containerRoot: temp)
        _ = try store.importLibrary(from: fixture)
        XCTAssertEqual(try store.importLibrary(from: fixture), .alreadyCurrent(stand: "2026-01-15"))

        // neuere Fassung: eine Einheit weniger -> ersetzt (nicht zusammengefuehrt)
        let newer = temp.appendingPathComponent("neu", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: newer)
        let catURL = newer.appendingPathComponent("katalog.json")
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: catURL)) as? [String: Any])
        obj["stand"] = "2026-02-01"
        var subjects = try XCTUnwrap(obj["faecher"] as? [[String: Any]])
        subjects[0]["einheiten"] = try XCTUnwrap(subjects[0]["einheiten"] as? [Any]).prefix(1).map { $0 }
        obj["faecher"] = subjects
        try JSONSerialization.data(withJSONObject: obj).write(to: catURL)
        guard case .imported(let m) = try store.importLibrary(from: newer) else { return XCTFail("nicht ersetzt") }
        XCTAssertEqual(m.units, 2)
        let lib = try XCTUnwrap(try store.load())
        XCTAssertNil(lib.catalog.unit(key: "Beispielkunde-für-Tests/G0002"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.currentFolder.appendingPathComponent("Bibliothek/Beispielkunde-für-Tests/Einheiten/WiSe_2024_25").path),
                       "alter Stand darf nicht bleiben")
        XCTAssertEqual(try lib.search("Probeklausur"), [])

        // aelterer Stand: nichts aendern; mit force doch
        XCTAssertEqual(try store.importLibrary(from: fixture), .newerInstalled(installed: "2026-02-01", offered: "2026-01-15"))
        guard case .imported = try store.importLibrary(from: fixture, force: true) else { return XCTFail("force") }
        XCTAssertEqual(store.manifest()?.units, 3)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.base.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testImportFindsNestedRootNFDNamesAndReportsMissingFiles() throws {
        // ZIP-Form: Hauptordner darueber, Fachordner in NFD, eine Datei fehlt
        let outer = temp.appendingPathComponent("entpackt/uniflow-wissensbibliothek", isDirectory: true)
        try FileManager.default.createDirectory(at: outer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: outer)
        let nfc = outer.appendingPathComponent("Bibliothek/Beispielkunde-für-Tests")
        let nfd = outer.appendingPathComponent("Bibliothek/Beispielkunde-fu\u{0308}r-Tests")
        let tmp = outer.appendingPathComponent("Bibliothek/umbenennen")
        try FileManager.default.moveItem(at: nfc, to: tmp)
        try FileManager.default.moveItem(at: tmp, to: nfd)
        try FileManager.default.removeItem(at: outer.appendingPathComponent("Bibliothek/Rechnen-Übungsfach/Wochen/SoSe 2026/Woche 01/README.md"))

        XCTAssertEqual(KnowledgeLibraryStore.locateRoot(in: temp.appendingPathComponent("entpackt"))?.lastPathComponent, "uniflow-wissensbibliothek")
        let store = KnowledgeLibraryStore(containerRoot: temp.appendingPathComponent("container"))
        guard case .imported(let m) = try store.importLibrary(from: temp.appendingPathComponent("entpackt")) else { return XCTFail("nicht importiert") }
        XCTAssertEqual(m.missingCount, 1)
        XCTAssertEqual(m.missing, ["Bibliothek/Rechnen-Übungsfach/Wochen/SoSe 2026/Woche 01/README.md"])
        XCTAssertEqual(m.files, 7)
        let lib = try XCTUnwrap(try store.load())
        let g1 = try XCTUnwrap(lib.catalog.unit(key: "Beispielkunde-für-Tests/G0001"))
        XCTAssertTrue(lib.exists(g1, file: "01-erklaert.md"))
        XCTAssertFalse(try lib.search("zitronenfalter").isEmpty)

        XCTAssertThrowsError(try store.importLibrary(from: temp.appendingPathComponent("container/Wissensbibliothek/fehlt"))) {
            XCTAssertEqual($0 as? KnowledgeImportError, .noCatalog)
        }
        try store.remove()
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.base.path))
    }

    /// Nur von Hand mit der echten (privaten) Bibliothek auf dem Mac: `UF_WISSENSBIBLIOTHEK=<Ordner> swift test --filter
    /// KnowledgeLibraryTests/testRealLibrary`. Liest den Ordner nur, importiert in einen Temp-Ordner, gibt nur Zahlen aus.
    /// Ohne die Variable (CI, normale Laeufe) uebersprungen; im Repo liegt nichts aus der echten Bibliothek.
    func testRealLibraryIfGiven() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_WISSENSBIBLIOTHEK"], !path.isEmpty else {
            throw XCTSkip("UF_WISSENSBIBLIOTHEK nicht gesetzt")
        }
        let source = URL(fileURLWithPath: path, isDirectory: true)
        let offered = try KnowledgeLibraryStore.offeredCatalog(in: source)
        let store = KnowledgeLibraryStore(containerRoot: temp)
        let t0 = Date()
        guard case .imported(let m) = try store.importLibrary(from: source) else { return XCTFail("nicht importiert") }
        let importSeconds = Date().timeIntervalSince(t0)
        let t1 = Date()
        let lib = try XCTUnwrap(try store.load())
        let loadSeconds = Date().timeIntervalSince(t1)
        XCTAssertEqual(lib.catalog.unitCount, offered.unitCount)
        XCTAssertEqual(m.units, offered.unitCount)
        XCTAssertEqual(m.subjects, offered.subjects.count)
        let checkScripts = offered.units.reduce(0) { $0 + $1.files.filter { KnowledgeFileKind.of($0) == .checkScript }.count }
        XCTAssertEqual(m.files + m.missingCount, offered.fileCount - checkScripts)
        var parsed = 0
        for u in lib.catalog.units.prefix(200) {
            for f in u.visibleFiles where KnowledgeFileKind.of(f).isMarkdown {
                _ = KnowledgeDocument.parse(try lib.read(u, file: f))
                parsed += 1
            }
        }
        let t2 = Date()
        let hits = try lib.search("Kirchhoff")
        let searchSeconds = Date().timeIntervalSince(t2)
        let marks = lib.meta.units.values.reduce(into: [0, 0, 0, 0]) { acc, s in
            acc[0] += s.marks.kiUnchecked ? 1 : 0; acc[1] += s.marks.independent ? 1 : 0
            acc[2] += s.marks.recomputed ? 1 : 0; acc[3] += s.marks.links.isEmpty ? 0 : 1
        }
        let open = lib.catalog.units.flatMap { u in lib.summary(u).marks.links.filter { lib.resolve($0, from: u) == nil }.map { "\(u.key) -> \($0.unit)" } }
        let unresolved = open.count
        if !open.isEmpty { print("WB-ECHT verweise ohne Ziel: \(open.prefix(10))") }
        let withSources = lib.meta.units.values.filter { !$0.sources.isEmpty }.count
        let withTypes = lib.meta.units.values.filter { !$0.types.isEmpty }.count
        let probe = lib.units(matchingTitle: "ws26-dua-folien-komplett-ohne-Antworten", fileName: nil).count
        print("WB-ECHT mitQuellen=\(withSources) mitTyp=\(withTypes) zuordnungDuaFolien=\(probe)")
        print("""
        WB-ECHT stand=\(m.stand) faecher=\(m.subjects) einheiten=\(m.units) dateien=\(m.files) fehlend=\(m.missingCount) md=\(m.markdownFiles) \
        abschnitte=\(m.sections) bytes=\(m.bytes) import=\(String(format: "%.1f", importSeconds))s laden=\(String(format: "%.2f", loadSeconds))s \
        suche=\(String(format: "%.3f", searchSeconds))s treffer=\(hits.count) gelesen=\(parsed) kiUngeprueft=\(marks[0]) unabhaengig=\(marks[1]) \
        nachgerechnet=\(marks[2]) mitVerweis=\(marks[3]) verweiseOhneZiel=\(unresolved) fehlendeBeispiele=\(m.missing.prefix(3))
        """)
    }

    func testLoadRebuildsIndexWhenFormatChanges() throws {
        let store = KnowledgeLibraryStore(containerRoot: temp)
        _ = try store.importLibrary(from: fixture)
        let url = store.currentFolder.appendingPathComponent(KnowledgeLibraryStore.manifestName)
        var m = try JSONDecoder().decode(KnowledgeImportManifest.self, from: Data(contentsOf: url))
        m.format = 0
        try JSONEncoder().encode(m).write(to: url)
        try FileManager.default.removeItem(at: store.currentFolder.appendingPathComponent(KnowledgeLibraryStore.indexName))
        let lib = try XCTUnwrap(try store.load())
        XCTAssertEqual(lib.manifest.format, KnowledgeLibraryStore.format)
        XCTAssertFalse(try lib.search("zitronenfalter").isEmpty)
    }
}
