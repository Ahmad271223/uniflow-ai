import Darwin
import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Messung des Editors mit grossen Dokumenten (Plan docs/PENCILKIT-ANALYSE-PLAN.md, P0-2; Werte und Grenzen in
/// docs/EDITOR-MESSUNG.md). Geprueft wird der echte Weg: DocumentStore mit lokalem Backend (SQLite) im Temp-Ordner,
/// PDFEditorController als Inhalt eines eigenen Fensters, PDFKit setzt die Seiten-Overlays selbst ein.
///
/// - Oeffnen und durchgehendes Blaettern bei 100, 250 und 500 Seiten (Zeit, Hauptthread, Speicher, ob Overlays und
///   ihre PencilKit-Canvas wieder freigegeben werden), bei 500 Seiten zusaetzlich Drehen und Einfuegen
///   (Strukturwechsel baut das Anzeige-PDF neu).
/// - Dichtes Skript 100 Seiten x 300 Striche: Umrechnung, Journal, Speicherrunden (ganzes Dokument plus Versionskopie
///   im Backend) bei 20, 50 und 100 Seiten, Aufteilung einer Runde.
/// - 50 volle Seiten: durchgehend blaettern, volle Seiten anspringen, erneut oeffnen.
/// - 200 Seiten x 300 Striche nur auf Anforderung (`UNIFLOW_EDITOR_MESSUNG=gross`, dauert unter Last zu lange).
/// - Zoom bis zum Maximum (Zeit, Speicher, Kantenschaerfe von Tinte und PDF im Bild des Fensters).
/// - Eingefuegte Leerseiten A6 bis A0 (Lage eines Strichs, Einpassen, Speicher).
/// - Rueckgaengig und Wiederholen ueber Seiten, deren Overlay schon freigegeben ist.
/// - Dauerschreiben auf einem dichten Dokument (Obergrenze beim Sichern, Schritt 2): Journal alle ~2 s, keine
///   Upload-Runde waehrend des Schreibens.
///
/// Zeiten haengen an der Last des Rechners (volle Laeufe teilen sich den Mac mit anderen Simulatoren). Darum sind
/// Zeitgrenzen nur grobe Haenger-Grenzen, mindestens zehnfach ueber den Werten, die unter hoher Last (Lastmittel ueber
/// 250 auf 8 Kernen) gemessen wurden. Ausnahme ist das Zeitlimit fuers durchgehende Blaettern (5- bis 16-fach): dort
/// gibt der feste Takt des Tests die Dauer vor (500 Seiten mindestens 31 s), sie aendert sich mit der Last kaum.
/// Alles andere wird nur protokolliert. Hart geprueft wird, was nicht von der Last
/// abhaengt: Seitenzahl, Freigabe der Overlays, Striche und Speicherstand. Es gibt keine Schleifen, die Ebenen
/// wiederholt ein- und ausblenden (daran hing `testManyForeignLayersStayFastAndAreReleased`, Plan B12), und jedes
/// Warten hat ein festes Zeitlimit. Jeder Messwert steht als Zeile "[EditorMessung] <Test> | <Name> = <Wert> <Einheit>"
/// auf der Konsole, dazu das Lastmittel bei Beginn und Ende jedes Tests (Auswertung in docs/EDITOR-MESSUNG.md).
/// Alle Daten sind erfunden (PDFs aus UIGraphicsPDFRenderer, Striche mit festem Startwert).
@MainActor
final class EditorScaleTests: XCTestCase {

    // MARK: Grenzen

    /// Grenzen je Seitenzahl fuer Oeffnen und Blaettern (Sekunden bzw. MB). Gemessen unter hoher Last: Oeffnen unter
    /// 0,1 s, erste Seite unter 0,2 s, Blaettern 8 / 23 / 40 s (100 / 250 / 500 Seiten, die Dauer gibt vor allem der
    /// Takt des Tests vor), Zuwachs hoechstens 130 MB.
    struct OpenLimits {
        var open: Double
        var firstPage: Double
        /// Zeitlimit fuers Blaettern bis zum Ende (danach bricht der Test mit Meldung ab)
        var scroll: Double
        var growthMB: Double
    }

    /// Hoechstens so viele Overlays bzw. PencilKit-Canvas leben nach dem Blaettern: sichtbare (bis 3) + geparkte (6)
    /// + die, deren Laden noch laeuft. Gemessen: 9 bis 10, unabhaengig von der Seitenzahl.
    static let aliveLimit = 40

    // MARK: Oeffnen und Blaettern

    func testOpenAndScroll100Pages() async throws {
        try await openAndScroll(pages: 100, limits: OpenLimits(open: 15, firstPage: 15, scroll: 120, growthMB: 700))
    }

    func testOpenAndScroll250Pages() async throws {
        try await openAndScroll(pages: 250, limits: OpenLimits(open: 25, firstPage: 20, scroll: 180, growthMB: 900))
    }

    func testOpenAndScroll500PagesWithStructureChange() async throws {
        try await openAndScroll(pages: 500, limits: OpenLimits(open: 40, firstPage: 25, scroll: 220, growthMB: 1100),
                                structureChange: true)
    }

    private func openAndScroll(pages n: Int, limits: OpenLimits, structureChange: Bool = false) async throws {
        let m = Messwerte("Oeffnen \(n) Seiten")
        let base = Speicher.now()
        var t = Uhr.now()
        let pdf = Skript.pdf(pages: n)
        m.add("PDF erzeugen (nur Vorbereitung)", Uhr.since(t), "s")
        m.add("PDF-Datei", Double(pdf.count) / 1_048_576, "MB")
        let fx = try await makeFixture(pdf: pdf, pageCount: n)
        let main = Hauptthread()
        main.start()

        t = Uhr.now()
        let store = try await openStore(fx)
        let open = Uhr.since(t)
        m.add("Oeffnen (DocumentStore.load)", open, "s")
        XCTAssertEqual(store.layout?.entries.count, n, "alle Seiten im Seitenaufbau")

        t = Uhr.now()
        let shown = show(store)
        defer { hide(shown) }
        m.add("Editor ins Fenster (Hauptthread am Stueck)", Uhr.since(t), "s")
        let first = try await waitForOverlay(shown.editor, page: 0, timeout: limits.firstPage * 2)
        let firstPage = Uhr.since(t)
        m.add("Editor bis erste Seite geladen", firstPage, "s")
        m.add("Zoom eingepasst (scaleFactor)", Double(shown.editor.pdfView.scaleFactor), "")
        XCTAssertGreaterThan(first.bounds.width, 0)
        let opened = Speicher.now()
        m.memory("nach dem Oeffnen", opened, since: base)
        m.blocking("Hauptthread beim Oeffnen", main.take())

        let scroll = try await scrollThrough(shown, timeLimit: limits.scroll)
        m.scroll(scroll)
        let scrolled = Speicher.now()
        m.memory("nach dem Blaettern", scrolled, since: base)
        m.add("Zuwachs durch Blaettern (phys_footprint)", Double(Int64(scrolled.footprint) - Int64(opened.footprint)) / 1_048_576, "MB")
        m.blocking("Hauptthread beim Blaettern", main.take())

        XCTAssertLessThan(open, limits.open, "Oeffnen von \(n) Seiten haengt")
        XCTAssertLessThan(firstPage, limits.firstPage, "erste Seite haengt")
        XCTAssertTrue(scroll.reachedEnd, "Ende des Dokuments nicht in \(Int(limits.scroll)) s erreicht")
        XCTAssertGreaterThanOrEqual(scroll.seen.count, n * 95 / 100, "PDFKit hat fuer zu wenige Seiten ein Overlay eingesetzt")
        XCTAssertLessThanOrEqual(scroll.aliveOverlays, Self.aliveLimit, "Overlays werden nicht freigegeben (sichtbare + 6 geparkte erwartet)")
        XCTAssertLessThanOrEqual(scroll.aliveCanvases, Self.aliveLimit, "PencilKit-Canvas werden nicht freigegeben")
        let growth = Double(Int64(scrolled.footprint) - Int64(base.footprint)) / 1_048_576
        XCTAssertLessThan(growth, limits.growthMB, "Speicher waechst beim Oeffnen und Blaettern zu stark")

        if structureChange { try await measureStructureChange(shown, store: store, m: m, main: main) }

        main.stop()
        await store.close()
        m.finish()
    }

    /// Seite drehen und Leerseite einfuegen: das Anzeige-PDF wird mit Kopien aller Seiten neu gebaut
    /// (DisplayLayout.build, PDFEditorController.showLayout) - beides auf dem Hauptthread.
    private func measureStructureChange(_ shown: Shown, store: DocumentStore, m: Messwerte, main: Hauptthread) async throws {
        let editor = shown.editor
        editor.goToPage(250)
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = main.take()
        let key = try XCTUnwrap(editor.currentPageKey)
        let index = editor.currentPageIndex
        var t = Uhr.now()
        await store.rotatePage(key: key)
        let rebuild = Uhr.since(t)
        editor.showLayout()                                   // wie updateUIViewController nach dem Drehen
        let show = Uhr.since(t) - rebuild
        _ = try await waitForOverlay(editor, page: index, timeout: 30)
        let rotate = Uhr.since(t)
        m.add("Drehen: Store und Seitenaufbau", rebuild, "s")
        m.add("Drehen: Anzeige-PDF setzen", show, "s")
        m.add("Drehen bis Seite wieder geladen", rotate, "s")
        m.blocking("Hauptthread beim Drehen", main.take())
        XCTAssertEqual(editor.currentPageKey, key, "nach dem Drehen auf derselben Seite")
        XCTAssertLessThan(rotate, 30, "Drehen einer Seite bei 500 Seiten dauert zu lange")

        t = Uhr.now()
        let added = await editor.insertBlankPage(after: key, template: "lined")
        let insertKey = try XCTUnwrap(added, "Leerseite eingefuegt")
        let newIndex = try XCTUnwrap(store.layout?.index(ofKey: insertKey))
        _ = try await waitForOverlay(editor, page: newIndex, timeout: 30)
        let insert = Uhr.since(t)
        m.add("Leerseite einfuegen bis geladen", insert, "s")
        m.blocking("Hauptthread beim Einfuegen", main.take())
        XCTAssertEqual(store.layout?.entries.count, 501)
        XCTAssertLessThan(insert, 30, "Einfuegen einer Seite bei 500 Seiten dauert zu lange")
    }

    // MARK: Dichtes Skript

    /// Grenzen fuer das dichte Skript (Sekunden). Gemessen unter hoher Last: Umrechnung 4 s (50 Seiten) bzw. 8 s
    /// (100 Seiten), Speicherrunde 9 s bzw. 16,5 s, erneut oeffnen 6 s (50 Seiten).
    struct DenseLimits {
        /// Umrechnung und Journal aller Striche
        var convert: Double
        /// eine Speicherrunde beim letzten Messpunkt
        var round: Double
        /// erneut oeffnen
        var reopen: Double
    }

    /// 100 Seiten mit je 300 Strichen (30 000 Striche): Speicherrunden bei 20, 50 und 100 Seiten, Aufteilung einer
    /// Runde bei 50 Seiten.
    func testDenseScriptSaveRounds100PagesWith300Strokes() async throws {
        try await denseScript(pages: 100, perPage: 300, checkpoints: [20, 50, 100], breakdownAt: 50, scroll: false, reopen: false,
                              limits: DenseLimits(convert: 120, round: 180, reopen: 0))
    }

    /// 50 volle Seiten (je 300 Striche): durchgehend blaettern (jede Seite: pkdrawing dekodieren, 300 Striche auf die
    /// Canvas), Warteschlange der Ladevorgaenge abarbeiten lassen, danach erneut oeffnen.
    func testScrollThroughFullPagesAndReopen50PagesWith300Strokes() async throws {
        try await denseScript(pages: 50, perPage: 300, checkpoints: [50], breakdownAt: nil, scroll: true, reopen: true,
                              limits: DenseLimits(convert: 80, round: 120, reopen: 90))
    }

    /// 200 Seiten mit je 300 Strichen (60 000 Striche), nur auf Anforderung: eine Speicherrunde dauert dort unter
    /// Last ueber eine Minute, mit Aufbau und erneutem Oeffnen reicht die Zeitgrenze von 300 s je Test fuer volle
    /// Laeufe nicht sicher. Start mit `TEST_RUNNER_UNIFLOW_EDITOR_MESSUNG=gross xcodebuild test ...`.
    func testDenseScript200PagesWith300StrokesOnRequest() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFLOW_EDITOR_MESSUNG"] == "gross",
                          "nur auf Anforderung (UNIFLOW_EDITOR_MESSUNG=gross), siehe docs/EDITOR-MESSUNG.md")
        try await denseScript(pages: 200, perPage: 300, checkpoints: [200], breakdownAt: 200, scroll: false, reopen: true,
                              limits: DenseLimits(convert: 200, round: 240, reopen: 200))
    }

    /// Striche wie vom Editor (`canvasChanged`) in Bloecken zu 25 Seiten. An jedem Messpunkt: ein Strich mehr auf
    /// der vollen Seite 1 (Umrechnung einer vollen Seite), dann genau eine Speicherrunde: ganzes Dokument ans lokale
    /// Backend, dort Stand plus Versionskopie (`AnnotationEndpoints.write`).
    private func denseScript(pages: Int, perPage: Int, checkpoints: [Int], breakdownAt: Int?, scroll: Bool, reopen: Bool,
                             limits: DenseLimits) async throws {
        let m = Messwerte("Dichtes Skript \(pages) x \(perPage)")
        let base = Speicher.now()
        let fx = try await makeFixture(pdf: Skript.pdf(pages: pages, .schlicht), pageCount: pages)
        let store = try await openStore(fx)
        let engine = try XCTUnwrap(Mirror(reflecting: store).children.first { $0.label == "engine" }?.value as? SyncEngine,
                                   "SyncEngine des Stores (nur Zaehler der Uploads)")
        let main = Hauptthread()
        main.start()
        let peak = Spitze()
        peak.start()

        var page1 = Handschrift.page(0, strokes: perPage)
        var fed = 0, convert = 0.0, generate = 0.0, extra = 0
        var lastRound = 0.0
        for checkpoint in checkpoints {
            while fed < checkpoint {
                let chunk = min(25, checkpoint - fed)
                var t = Uhr.now()
                // Testdaten erzeugen laeuft auf dem Hauptthread des Tests: zaehlt nicht zur Messung des Hauptthreads
                let drawings = main.excluding {
                    (fed..<(fed + chunk)).map { $0 == 0 ? page1 : Handschrift.page($0, strokes: perPage) }
                }
                generate += Uhr.since(t)
                for (i, d) in drawings.enumerated() { store.canvasChanged(pageKey: "p\(fed + i + 1)", drawing: d) }
                t = Uhr.now()
                _ = await store.pageStructureDocument()        // Umrechnung und Journal, ohne Upload anzustossen
                convert += Uhr.since(t)
                fed += chunk
            }
            m.add("\(fed) Seiten: Umrechnung und Journal bisher", convert, "s")
            m.blocking("\(fed) Seiten: Hauptthread beim Umrechnen", main.take())
            m.add("\(fed) Seiten: Spitze phys_footprint beim Umrechnen", Double(peak.current().footprint) / 1_048_576, "MB")

            page1.strokes.append(Handschrift.extraStroke(fed))
            extra += 1
            store.canvasChanged(pageKey: "p1", drawing: page1)
            var t = Uhr.now()
            _ = await store.pageStructureDocument()
            m.add("\(fed) Seiten: ein Strich mehr auf voller Seite umrechnen und ins Journal", Uhr.since(t), "s")

            let putsBefore = await engine.stats.puts
            _ = main.take()
            peak.reset()                                       // Spitze nur dieser Runde (ohne die Auswertung davor)
            t = Uhr.now()
            await store.pause()                                // genau eine Runde: alles Ausstehende in einem PUT
            lastRound = Uhr.since(t)
            let roundPeak = peak.current()
            m.add("\(fed) Seiten: eine Speicherrunde (ganzes Dokument)", lastRound, "s")
            m.add("\(fed) Seiten: PUTs in dieser Runde", Double(await engine.stats.puts - putsBefore), "")
            m.blocking("\(fed) Seiten: Hauptthread waehrend der Speicherrunde", main.take())
            m.add("\(fed) Seiten: Spitze phys_footprint waehrend der Runde", Double(roundPeak.footprint) / 1_048_576, "MB")
            let info = await store.info()
            XCTAssertEqual(info.unsentPages, 0, "\(fed) Seiten: alles gespeichert")
            // Groessen und nachgestellte Runde (serialisieren, parsen) laufen auf dem Hauptthread des Tests und
            // zaehlen nicht zur Messung des Hauptthreads
            try await main.excluding {
                try await m.storage("\(fed) Seiten", store: store, fx: fx)
                if fed == breakdownAt { try await m.roundParts("\(fed) Seiten", store: store, round: lastRound) }
            }
            peak.reset()                                       // naechster Abschnitt ohne die Auswertung
        }
        m.add("Striche erzeugen (nur Vorbereitung)", generate, "s")
        m.add("Umrechnung und Journal je Seite (\(perPage) Striche)", convert / Double(pages), "s")
        _ = peak.stop()
        m.memory("nach dem Speichern", Speicher.now(), since: base)
        try await m.versions(fx)

        let doc = await store.pageStructureDocument()
        let strokes = doc.pages.values.reduce(0) { $0 + ($1["objects"]?.array?.count ?? 0) }
        XCTAssertEqual(strokes, pages * perPage + extra, "alle Striche im Dokument")
        XCTAssertLessThan(convert, limits.convert, "Umrechnung von \(pages * perPage) Strichen dauert zu lange")
        XCTAssertLessThan(lastRound, limits.round, "eine Speicherrunde bei \(pages) vollen Seiten dauert zu lange")

        if scroll {
            // Blaettern durch die vollen Seiten (je Seite: pkdrawing dekodieren, 300 Striche auf die Canvas)
            let shown = show(store)
            defer { hide(shown) }
            _ = try await waitForOverlay(shown.editor, page: 0, timeout: 30)
            _ = main.take()
            let before = Speicher.now()
            // Zeitlimit 100 s (gemessen unter hoher Last: 5 s), Abarbeiten hoechstens 60 s
            let r = try await scrollThrough(shown, timeLimit: 100, drain: 60)
            m.scroll(r)
            m.blocking("Hauptthread beim Blaettern durch volle Seiten", main.take())
            let after = Speicher.now()
            m.memory("nach dem Blaettern und Abarbeiten", after, since: base)
            m.add("Spitzenzuwachs beim Blaettern (phys_footprint)",
                  Double(Int64(r.peak.footprint) - Int64(before.footprint)) / 1_048_576, "MB")
            XCTAssertTrue(r.reachedEnd, "Ende nicht in 100 s erreicht")
            XCTAssertGreaterThanOrEqual(r.seen.count, pages * 95 / 100)
            XCTAssertLessThanOrEqual(r.aliveAfterDrain, Self.aliveLimit, "Overlays bleiben nach dem Laden am Leben (Leck)")
            XCTAssertLessThanOrEqual(r.aliveCanvases, Self.aliveLimit, "PencilKit-Canvas werden nicht freigegeben")
            let last = try XCTUnwrap(installedOverlays(shown.editor).last, "sichtbare Seite am Ende")
            XCTAssertTrue(last.loaded, "sichtbare Seite am Ende geladen")
            XCTAssertGreaterThanOrEqual(last.canvas.drawing.strokes.count, perPage, "volle Seite auf der Canvas")

            // volle Seiten anspringen, die nicht mehr geparkt sind: Zeit bis ihre Striche auf der Canvas liegen
            // (Seite aus dem Speicher holen, pkdrawing dekodieren, Zeichnung setzen)
            var jumps: [Double] = []
            for target in [pages / 10, pages * 3 / 10, pages / 2, pages * 7 / 10, pages / 5] {
                let t = Uhr.now()
                shown.editor.goToPage(target)
                let o = try await waitForOverlay(shown.editor, page: target, timeout: 30)
                jumps.append(Uhr.since(t))
                XCTAssertGreaterThanOrEqual(o.canvas.drawing.strokes.count, perPage, "Seite \(target + 1) vollstaendig")
            }
            jumps.sort()
            m.add("volle Seite anspringen bis Striche da: Median aus 5", jumps[2], "s")
            m.add("volle Seite anspringen bis Striche da: laengstes", jumps[4], "s")
            m.blocking("Hauptthread beim Anspringen voller Seiten", main.take())
            XCTAssertLessThan(jumps[2], 10, "volle Seite erscheint zu spaet")
            hide(shown)
        }
        main.stop()
        await store.close()
        guard reopen else { m.finish(); return }

        // erneut oeffnen: Journal (eine Datei je Seite) und Stand aus der Datenbank. Steht die Oberflaeche dabei?
        let reopenMain = Hauptthread()
        reopenMain.start()
        var t = Uhr.now()
        let again = try await openStore(fx)
        let reopen = Uhr.since(t)
        m.add("erneut oeffnen (\(pages * perPage) Striche, DocumentStore.load)", reopen, "s")
        m.blocking("Hauptthread beim erneuten Oeffnen", reopenMain.take())
        reopenMain.stop()
        let p1 = await again.objects(forPageKey: "p1")
        XCTAssertEqual(p1.count, perPage + extra, "Seite 1 nach dem erneuten Oeffnen vollstaendig")
        let notice = again.notice ?? ""
        XCTAssertFalse(notice.contains("beschädigt"), notice)
        XCTAssertLessThan(reopen, limits.reopen, "erneutes Oeffnen haengt")
        // was davon der Abruf des gespeicherten Stands kostet (dieselbe Anfrage wie SyncEngine.open, nachgestellt)
        t = Uhr.now()
        let stored = try await fx.api.value("/api/files/\(fx.file.id)/annotations")
        m.add("davon nachgestellt: gespeicherten Stand abrufen (GET annotations)", Uhr.since(t), "s")
        XCTAssertNotNil(stored["data"]?["pages"], "gespeicherter Stand mit Seiten")
        // bis die erste volle Seite mit ihren Strichen im Bild ist
        t = Uhr.now()
        let shown = show(again)
        defer { hide(shown) }
        _ = try await waitForCanvas(shown.editor, page: 0, strokes: perPage + extra, timeout: 30)
        m.add("danach Editor bis erste volle Seite mit Strichen", Uhr.since(t), "s")
        hide(shown)
        await again.close()
        m.finish()
    }

    // MARK: Dauerschreiben auf einem dichten Dokument (Obergrenze beim Sichern, Schritt 2)

    /// 50 volle Seiten (15 000 Striche, gesichert und hochgeladen), dann 10 s ohne Pause auf der vollen Seite 1: ein
    /// Strich je 100 ms wie beim Schraffieren. Gemessen (nur protokolliert): wie oft die Obergrenze gegriffen hat, was eine
    /// solche Verarbeitung kostet, Journal-Schreibvorgaenge und Upload-Runden waehrend des Schreibens, Hauptthread,
    /// danach die Zeit bis "Gespeichert". Erwartet: Journal alle ~2 s, keine Runde mit dem ganzen Dokument waehrend des
    /// Schreibens (sie dauert hier Sekunden, M1), genau eine danach. Hart geprueft wird nur, dass am Ende jeder Strich
    /// gespeichert ist (Haenger-Grenze 180 s fuers Speichern).
    func testContinuousWritingOnDenseDocument50Pages() async throws {
        let m = Messwerte("Dauerschreiben 50 x 300")
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 50, .schlicht), pageCount: 50)
        let store = try await openStore(fx)
        let engine = try XCTUnwrap(Mirror(reflecting: store).children.first { $0.label == "engine" }?.value as? SyncEngine)
        var page1 = Handschrift.page(0, strokes: 300)
        for first in stride(from: 0, to: 50, by: 25) {
            let drawings = (first..<(first + 25)).map { $0 == 0 ? page1 : Handschrift.page($0, strokes: 300) }
            for (i, d) in drawings.enumerated() { store.canvasChanged(pageKey: "p\(first + i + 1)", drawing: d) }
            _ = await store.pageStructureDocument()
        }
        await store.pause()
        let ready = await store.info()
        XCTAssertEqual(ready.unsentPages, 0, "Aufbau gespeichert")

        let main = Hauptthread()
        main.start()
        let puts0 = await engine.stats.puts, writes0 = await engine.stats.pageWrites
        let forced0 = store.forcedSaves, forcedTime0 = store.forcedSaveSeconds
        let start = Uhr.now()
        var n = 0
        while Uhr.since(start) < 10 {
            page1.strokes.append(Handschrift.extraStroke(n))
            n += 1
            store.canvasChanged(pageKey: "p1", drawing: page1)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let writing = Uhr.since(start)
        let forced = store.forcedSaves - forced0
        let putsWriting = await engine.stats.puts - puts0
        let writesWriting = await engine.stats.pageWrites - writes0
        m.add("Dauer des Dauerschreibens", writing, "s")
        m.add("Striche dabei", Double(n), "")
        m.add("Obergrenze gegriffen (Verarbeitungen waehrend des Schreibens)", Double(forced), "")
        m.add("je Verarbeitung durch die Obergrenze (Umrechnung + Journal, Seite mit 300+ Strichen)",
              forced > 0 ? (store.forcedSaveSeconds - forcedTime0) / Double(forced) : 0, "s")
        m.add("Journal-Schreibvorgaenge waehrend des Schreibens", Double(writesWriting), "")
        m.add("Upload-Runden (PUT) waehrend des Schreibens", Double(putsWriting), "")
        m.blocking("Hauptthread beim Dauerschreiben", main.take())

        let t = Uhr.now()
        var saved = false
        while Uhr.since(t) < 180 {
            if store.status == .saved, await store.info().unsentPages == 0 { saved = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        m.add("nach der Schreibpause bis Gespeichert", Uhr.since(t), "s")
        m.add("Upload-Runden nach der Pause", Double(await engine.stats.puts - puts0 - putsWriting), "")
        main.stop()
        XCTAssertTrue(saved, "nach der Schreibpause nicht gespeichert (Haenger)")
        await store.close()
        let backend = try await fx.host.backend()
        let text = try await backend.context.database.rows("SELECT data FROM annotations WHERE file_id=?", [.text(fx.file.id)])
            .first?["data"]?.string
        let doc = AnnotationDocument(root: try JSONValue.parse(Data((text ?? "{}").utf8)))
        XCTAssertEqual(doc.objects(page: "p1").count, 300 + n, "jeder Strich gespeichert")
        m.finish()
    }

    // MARK: Zoom auf das Maximum

    /// Seite 1 mit einer waagrechten Linie aus PDF-Vektoren (2 pt) und einem Strich (Stift, schwarz) knapp darueber.
    /// Bei Einpassen sowie 2-, 4- und 6-fach (Maximum, ZoomPolicy) wird das Fenster abfotografiert (drawHierarchy)
    /// und die Breite der Kanten beider Linien gezaehlt (Pixel zwischen 15 und 85 % Helligkeit). PDFKit zeichnet beim
    /// Zoomen neu (scharfe Kante); waechst die Kante der Tinte mit dem Zoom, vergroessert PencilKit nur ein Bild (B13).
    func testZoomToMaximum() async throws {
        let m = Messwerte("Zoom Maximum")
        let base = Speicher.now()
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 30), pageCount: 30)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor
        var overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
        drawStroke(editor, on: overlay, Handschrift.line(from: CGPoint(x: Skript.rule.minX + 20, y: Skript.inkY),
                                                          to: CGPoint(x: Skript.rule.maxX - 20, y: Skript.inkY)))
        await store.flush()
        try await Task.sleep(nanoseconds: 800_000_000)
        let fit = editor.pdfView.scaleFactor
        let most = editor.pdfView.maxScaleFactor
        m.add("Zoom eingepasst (scaleFactor)", Double(fit), "")
        m.add("Zoom erlaubt bis (maxScaleFactor)", Double(most), "")
        XCTAssertEqual(Double(most / fit), Double(ZoomPolicy.maxFactor), accuracy: 0.01, "Maximum = 6-fach der Einpassung")
        let main = Hauptthread()
        main.start()
        var atMax = Sharpness()
        var before = Speicher.now()
        for factor: CGFloat in [1, 2, 4, 6] {
            let name = factor == 1 ? "eingepasst" : "\(Int(factor))-fach"
            _ = main.take()                                    // Bilder des Fensters zaehlen nicht mit
            let t = Uhr.now()
            editor.pdfView.scaleFactor = fit * factor
            let set = Uhr.since(t)
            // Overlay folgt dem Zoom: Seitenpunkte -> Fensterpunkte entsprechen dem neuen Zoom
            let expected = editor.pdfView.scaleFactor
            let deadline = Uhr.now() + 15
            var onScreen: CGFloat = 0
            repeat {
                try await Task.sleep(nanoseconds: 50_000_000)
                if let o = installedOverlay(editor, page: 0) {
                    overlay = o
                    onScreen = o.content.convert(CGRect(x: 0, y: 0, width: 100, height: 1), to: shown.window).width / 100
                }
            } while abs(onScreen - expected) > 0.05 * expected && Uhr.now() < deadline
            m.add("\(name): Zoom setzen (Hauptthread)", set, "s")
            m.add("\(name): bis Overlay angepasst", Uhr.since(t), "s")
            m.add("\(name): Bildschirmpunkte je Seitenpunkt", Double(onScreen), "pt")
            XCTAssertEqual(Double(onScreen), Double(expected), accuracy: Double(expected) * 0.05, "\(name): Overlay folgt dem Zoom")
            try await Task.sleep(nanoseconds: 700_000_000)     // PDFKit zeichnet seine Kacheln nach
            m.blocking("\(name): Hauptthread beim Zoomen", main.take())
            let now = Speicher.now()
            m.add("\(name): Zuwachs phys_footprint", Double(Int64(now.footprint) - Int64(before.footprint)) / 1_048_576, "MB")
            if factor == 6 { m.memory("beim Maximum", now, since: base) }
            // wartet nur, bis PDFKit die Linie scharf nachgezeichnet hat (gemessen unter Last: 0,6 s)
            let sharp = try await sharpness(shown, page: 0, waitForPDF: 15)
            m.sharpness(name, sharp)
            if let o = installedOverlay(editor, page: 0) { m.text("\(name): Ebenen der Canvas", Bild.layerInfo(o.canvas)) }
            before = Speicher.now()
            if factor == 6 { atMax = sharp }
        }
        _ = main.take()

        // beim Maximum zwei Seiten weiter scrollen
        var t = Uhr.now()
        let s = try await scrollThrough(shown, timeLimit: 60, distance: 2 * 842 * editor.pdfView.scaleFactor, stepFraction: 0.5)
        m.add("beim Maximum zwei Seiten scrollen", Uhr.since(t), "s")
        m.add("beim Maximum: Schritte", Double(s.steps), "")
        m.blocking("Hauptthread beim Scrollen im Maximum", main.take())
        m.memory("nach dem Scrollen im Maximum", Speicher.now(), since: base)

        t = Uhr.now()
        editor.fitWidth()
        editor.goToPage(0)
        overlay = try await waitForOverlay(editor, page: 0, timeout: 15)
        m.add("zurueck auf Einpassen", Uhr.since(t), "s")
        main.stop()
        XCTAssertEqual(editor.pdfView.scaleFactor, fit, accuracy: 0.001)
        let objects = await store.objects(forPageKey: "p1")
        XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.count, 1, "Zoomen schreibt nichts")
        let pdfSharpAtMax = try XCTUnwrap(atMax.pdf, "PDF-Linie beim Maximum gefunden")
        XCTAssertLessThan(pdfSharpAtMax.edge, 4, "PDFKit zeichnet beim Zoom nicht scharf nach (Messaufbau pruefen)")
        XCTAssertNotNil(atMax.ink, "Tinte beim Maximum im Bild des Fensters")
        await store.close()
        m.finish()
    }

    // MARK: Tinte beim Maximum so glatt wie Vektor (Meldung des Inhabers 20.11.2026)

    /// Meldung des Inhabers 20.11.2026 (iPad A16, 1.0.7): bei 600 % ist die PDF-Schrift scharf, die Handschrift
    /// verpixelt. Strich schreiben, auf das Maximum zoomen (6-fach der Einpassung), erst an den Seitenanfang (Strich nicht
    /// im Bild), dann zum Strich verschieben, Bild des Fensters, Kante des Strichs messen. Bezug: derselbe Strich, von
    /// PencilKit als Vektor in genau der Aufloesung des Bildschirms gezeichnet. Dazu Aufloesung und Flaeche der
    /// Zeichenflaeche beim Maximum (Speicher) und: Der sichtbare Teil der Seite liegt ganz auf der Zeichenflaeche (der
    /// Stift schreibt ueberall, wo die Seite zu sehen ist).
    func testTinteBeimMaximumScharfWieVektor() async throws {
        let m = Messwerte("Tinte scharf beim Maximum")
        let base = Speicher.now()
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 3, .schlicht), pageCount: 3)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor, window = shown.window
        var overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
        let stroke = Handschrift.line(from: CGPoint(x: Skript.rule.minX + 20, y: Skript.inkY),
                                      to: CGPoint(x: Skript.rule.maxX - 20, y: Skript.inkY))
        drawStroke(editor, on: overlay, stroke)
        // Kreis ueber dem Strich: Kanten in jeder Richtung (ein vergroessertes Bild zeigt dort Treppen)
        let ring = Handschrift.circle(center: ringCenter, radius: 14)
        drawStroke(editor, on: overlay, ring)
        await store.flush()
        try await Task.sleep(nanoseconds: 800_000_000)
        let fit = editor.pdfView.scaleFactor
        let screen = window.screen.scale
        m.sharpness("eingepasst", try await sharpness(shown, page: 0, waitForPDF: 10))
        let beforeZoom = Speicher.now()

        editor.pdfView.scaleFactor = editor.pdfView.maxScaleFactor
        let zoom = editor.pdfView.scaleFactor
        m.add("Zoom beim Maximum (scaleFactor)", Double(zoom), "")
        m.add("Zoom relativ zur Einpassung", Double(zoom / fit * 100), "%")
        try await Task.sleep(nanoseconds: 700_000_000)
        let scroll = try XCTUnwrap(scrollView(editor), "Scroll-Ansicht der PDFView")
        overlay = try await waitForOverlay(editor, page: 0, timeout: 15)
        let corner = overlay.content.convert(CGPoint.zero, to: scroll)
        scroll.setContentOffset(CGPoint(x: min(max(0, corner.x), scroll.contentSize.width - scroll.bounds.width),
                                        y: min(max(0, corner.y), scroll.contentSize.height - scroll.bounds.height)), animated: false)
        try await Task.sleep(nanoseconds: 700_000_000)
        let sharp = try await sharpness(shown, page: 0, waitForPDF: 15)
        m.sharpness("Maximum", sharp)
        overlay = try await waitForOverlay(editor, page: 0, timeout: 15)
        let ringRect = CGRect(x: ringCenter.x - 20, y: ringCenter.y - 20, width: 40, height: 40)
        let ringOnScreen = try XCTUnwrap(Bild.snapshot(window).flatMap {
            Bild.grays($0, scale: screen, rect: overlay.content.convert(ringRect, to: window).intersection(window.bounds))
        }, "Kreis beim Maximum im Bild des Fensters")

        // Bezug: Vektor in der Aufloesung des Bildschirms (Bildpunkte je Seitenpunkt wie im Fenster)
        let shownScale = overlay.content.convert(CGRect(x: 0, y: 0, width: 100, height: 1), to: window).width / 100
        let pixelsPerPoint = shownScale * screen
        let refRect = CGRect(x: Skript.rule.minX + 60, y: Skript.inkY - 12, width: 40, height: 24)
        let ref = try XCTUnwrap(Bild.edge(Bild.vector(PKDrawing(strokes: [stroke]), rect: refRect, pixelsPerPoint: pixelsPerPoint),
                                          scale: pixelsPerPoint, rect: CGRect(origin: .zero, size: refRect.size)), "Bezug gemessen")
        m.add("Bezug (Vektor): Kante", ref.edge, "px")
        m.add("Bezug (Vektor): Dicke", ref.thickness, "px")
        let ringRef = try XCTUnwrap(Bild.grays(Bild.vector(PKDrawing(strokes: [ring]), rect: ringRect, pixelsPerPoint: pixelsPerPoint),
                                               scale: pixelsPerPoint, rect: CGRect(origin: .zero, size: ringRect.size)))
        m.add("Kreis im Fenster: Graustufen-Pixel je dunklem Pixel", ringOnScreen.ratio, "")
        m.add("Kreis als Vektor (Bezug): Graustufen-Pixel je dunklem Pixel", ringRef.ratio, "")
        m.add("Kreis im Fenster: dunkle Pixel", Double(ringOnScreen.dark), "")
        m.add("Kreis als Vektor (Bezug): dunkle Pixel", Double(ringRef.dark), "")
        let canvas = overlay.canvas
        // PencilKit zeichnet mit der Aufloesung des Bildschirms in Punkten der (gezoomten) Zeichenflaeche
        let inkPixelsPerPoint = canvas.zoomScale * screen
        m.add("Zeichenflaeche: Bildpunkte je Seitenpunkt", Double(inkPixelsPerPoint), "px")
        m.add("Bildschirm: Bildpunkte je Seitenpunkt", Double(pixelsPerPoint), "px")
        // Flaeche der Zeichenflaechen aller eingesetzten Seiten (Kacheln von PencilKit), in Bildpunkten
        let backing = installedOverlays(editor).reduce(CGFloat(0)) { sum, o in
            sum + o.canvas.bounds.width * o.canvas.bounds.height * screen * screen
        }
        m.add("Zeichenflaechen beim Maximum: Bildpunkte", Double(backing) / 1_000_000, "Mio.")
        m.add("Zeichenflaechen beim Maximum: bei 4 Byte je Bildpunkt", Double(backing) * 4 / 1_048_576, "MB")
        let now = Speicher.now()
        m.add("Zuwachs phys_footprint eingepasst -> Maximum", Double(Int64(now.footprint) - Int64(beforeZoom.footprint)) / 1_048_576, "MB")
        m.memory("beim Maximum", now, since: base)
        m.text("Ebenen der Canvas", Bild.layerInfo(canvas))

        let ink = try XCTUnwrap(sharp.ink, "Tinte beim Maximum im Bild des Fensters")
        let pdf = try XCTUnwrap(sharp.pdf, "PDF-Linie beim Maximum")
        XCTAssertLessThan(pdf.edge, 4, "PDFKit zeichnet beim Zoom scharf nach (Messaufbau)")
        XCTAssertLessThanOrEqual(ink.edge, ref.edge + 1, "Handschrift beim Maximum so glatt wie der Vektor (Bezug \(ref.edge) px, gemessen \(ink.edge) px)")
        XCTAssertEqual(ink.thickness, ref.thickness, accuracy: max(3, ref.thickness * 0.1), "Strich gleich dick wie der Vektor")
        XCTAssertLessThanOrEqual(ringOnScreen.ratio, ringRef.ratio * 1.3, "Rundung so glatt wie der Vektor (kein vergroessertes Bild)")
        XCTAssertEqual(Double(ringOnScreen.dark), Double(ringRef.dark), accuracy: Double(ringRef.dark) * 0.15, "Kreis vollstaendig")
        XCTAssertGreaterThanOrEqual(inkPixelsPerPoint, pixelsPerPoint * 0.98, "Zeichenflaeche mindestens so fein wie der Bildschirm")
        XCTAssertLessThanOrEqual(backing, PageInkView.inkPixelBudget, "Zeichenflaechen beim Maximum zusammen nicht groesser als bisher EINE Seite beim 4-fachen")
        // der sichtbare Teil der Seite liegt ganz auf der Zeichenflaeche
        let pageInWindow = overlay.content.convert(CGRect(origin: .zero, size: overlay.geometry.pageSize), to: window)
        let visible = pageInWindow.intersection(editor.pdfView.convert(editor.pdfView.bounds, to: window))
        let onCanvas = canvas.convert(canvas.bounds, to: window).insetBy(dx: -1, dy: -1)
        XCTAssertTrue(onCanvas.contains(visible), "Stift schreibt ueberall auf der sichtbaren Seite: \(visible) in \(onCanvas)")
        let objects = await store.objects(forPageKey: "p1")
        XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.count, 2, "Zoomen schreibt nichts")
        await store.close()
        m.finish()
    }

    private let ringCenter = CGPoint(x: 210, y: 645)

    /// Rueckmeldung des Inhabers 21.11.2026 (Testfassung 8262c3e4): "Wenn man ranzoomt, darf die Schrift nicht
    /// verrutschen. Sie muss am Blatt haften und darf nicht kurz spinnen - wie bei GoodNotes." ECHTES Pinchen mit zwei
    /// Fingern (`TestFinger.Zwei`, die Pinch-Geste der Scroll-Ansicht von PDFKit zoomt): hinein auf 600 % mit einer
    /// Pause mitten in der Geste, hinaus, schnell hinein ueber das Maximum (Zurueckfedern). Waehrend die Finger liegen,
    /// aendert sich an der Zeichenflaeche NICHTS (Zoom, Lage, Groesse, Versatz, Maske); danach wird sie scharf. Bild fuer
    /// Bild misst die Aufnahme (simctl recordVideo, `TINTE_VIDEO=1`) Tinte gegen PDF-Marke.
    func testTinteHaftetBeimPinchen() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let m = Messwerte("Tinte haftet beim Pinchen")
        let video = ProcessInfo.processInfo.environment["TINTE_VIDEO"] == "1"
        // Rueckfall wie vor de82ea35 (hoechstens 4-fach, ganze Seite) zum Vergleich
        let sharp = ProcessInfo.processInfo.environment["TINTE_ALT"] != "1"
        PencilTuning.sharpInkWindow = sharp
        defer { PencilTuning.sharpInkWindow = true }
        m.text("Fassung", sharp ? "scharf ueber 4-fach (Ausschnitt)" : "Rueckfall: hoechstens 4-fach, ganze Seite")
        let fx = try await makeFixture(pdf: Skript.markPDF(at: ringCenter), pageCount: 3)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor, window = shown.window
        var overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
        drawStroke(editor, on: overlay, Handschrift.circle(center: ringCenter, radius: 14, color: .blue))
        await store.flush()
        try await Task.sleep(nanoseconds: 800_000_000)
        let scroll = try XCTUnwrap(scrollView(editor), "Scroll-Ansicht der PDFView")
        let p = overlay.content.convert(ringCenter, to: scroll)
        scroll.contentOffset = CGPoint(x: max(0, p.x - scroll.bounds.width / 2), y: max(0, p.y - scroll.bounds.height / 2))
        try await Task.sleep(nanoseconds: 600_000_000)
        let center = overlay.content.convert(ringCenter, to: window)
        let fit = editor.pdfView.scaleFactor
        if video { try await Task.sleep(nanoseconds: 1_500_000_000) }

        // Zustand der Zeichenflaeche je Bild der Geste (ohne Bild des Fensters: das wuerde die Geste bremsen)
        struct State: Equatable { var zoom: CGFloat; var center: CGPoint; var bounds: CGRect; var offset: CGPoint; var masked: Bool }
        func state() -> State {
            let c = overlay.canvas
            return State(zoom: c.zoomScale, center: c.center, bounds: c.bounds, offset: c.contentOffset, masked: c.layer.mask != nil)
        }
        var changes: [String] = []
        func gesture(_ name: String, from: CGFloat, to: CGFloat, steps: Int, holdAt: Double?) async throws {
            var last = state()
            try await TestFinger.Zwei.pinch(center: center, from: from, to: to, steps: steps, in: window, holdAt: holdAt, holdSeconds: 0.6) {
                if let o = self.installedOverlay(editor, page: 0), o !== overlay { overlay = o; last = state() }
                let now = state()
                if now != last { changes.append("\(name): \(last) -> \(now)") }
                last = now
            }
            m.add("\(name): Zoom am Ende der Geste", Double(editor.pdfView.scaleFactor / fit * 100), "%")
        }
        var worst = 0.0, measured = 0
        func settle(_ name: String) async throws {
            let end = Uhr.now() + 1.6
            while Uhr.now() < end {
                if let o = installedOverlay(editor, page: 0) { overlay = o }
                if !video, let image = Bild.snapshot(window) {
                    let area = window.bounds.insetBy(dx: window.bounds.width / 2 - 300, dy: window.bounds.height / 2 - 300)
                    if let o = Bild.markOffset(image, scale: window.screen.scale, in: area, ringDiameter: 30.5) {
                        measured += 1
                        worst = max(worst, o.points)
                    }
                }
                try await Task.sleep(nanoseconds: 16_000_000)
            }
            m.text("\(name): danach", "Canvas-Zoom \(overlay.canvas.zoomScale), Ausschnitt \(overlay.inkWindow), Geste laeuft \(overlay.zoomGestureRunning) (isZooming \(scroll.isZooming), federt \(scroll.isZoomBouncing), Pinch \(scroll.pinchGestureRecognizer?.state.rawValue ?? -1)), Seite gezeigt \(overlay.shownScale() ?? 0)")
        }
        try await gesture("hinein", from: 80, to: 480, steps: 50, holdAt: 0.5)
        try await settle("hinein")
        let sharpZoom = overlay.canvas.zoomScale
        let underlays0 = PageInkView.pinchUnderlaysMade
        try await gesture("hinaus", from: 480, to: 110, steps: 40, holdAt: 0.4)
        let underlaysOut = PageInkView.pinchUnderlaysMade - underlays0
        try await settle("hinaus")
        XCTAssertFalse(overlay.hasPinchUnderlay, "Hilfsflaeche nach dem Zoomen wieder weg")
        try await gesture("schnell ueber das Maximum", from: 90, to: 700, steps: 18, holdAt: nil)
        try await settle("schnell ueber das Maximum")
        m.add("Aenderungen an der Zeichenflaeche waehrend der Gesten", Double(changes.count), "")
        for c in changes.prefix(12) { m.text("Aenderung", c) }
        m.add("Bilder nach den Gesten gemessen", Double(measured), "")
        m.add("groesste Abweichung Tinte <-> PDF nach den Gesten", worst, "pt")
        m.add("Zeichenflaeche nach dem Hineinzoomen (Zoom)", Double(sharpZoom), "")
        m.add("Zeichenflaeche nach schnellem Hineinzoomen (Zoom)", Double(overlay.canvas.zoomScale), "")
        m.add("Hilfsflaeche beim Herauszoomen", Double(underlaysOut), "mal")
        if sharp {
            XCTAssertGreaterThan(sharpZoom, 4, "nach dem Hineinzoomen scharf (Zeichenflaeche ueber 4-fach)")
            XCTAssertGreaterThan(overlay.canvas.zoomScale, 4, "auch nach schnellem Zoomen ueber das Maximum scharf")
            XCTAssertEqual(underlaysOut, 1, "beim Herauszoomen aus dem Ausschnitt liegt die ganze Seite darunter")
        } else {
            XCTAssertLessThanOrEqual(sharpZoom, 4, "Rueckfall: hoechstens 4-fach")
        }
        XCTAssertFalse(overlay.hasPinchUnderlay)
        XCTAssertEqual(changes.count, 0, "waehrend die Finger liegen, bleibt die Zeichenflaeche unveraendert")
        if !video { XCTAssertLessThanOrEqual(worst, 0.5, "Tinte bleibt auf der PDF") }
        await store.close()
        m.finish()
    }

    /// Meldung des Inhabers 20.11.2026 abends (Testfassung e337d759): "Scrollen mit dem Finger hakt". ECHTES Wischen mit
    /// einem Finger (`TestFinger`, die Scroll-Ansicht von PDFKit scrollt und rollt aus) ueber volle Seiten (je 300
    /// Striche) bei 100 %, 300 % und 600 %. Gemessen: Pausen des Hauptthreads, Abstand der Bilder (CADisplayLink) und
    /// wie oft die Zeichenflaeche dabei umgebaut wurde. `TINTE_ALT=1`: Rueckfall ohne Ausschnitt zum Vergleich.
    func testFingerScrollenHaktNicht() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let m = Messwerte("Finger-Scrollen")
        let sharp = ProcessInfo.processInfo.environment["TINTE_ALT"] != "1"
        PencilTuning.sharpInkWindow = sharp
        defer { PencilTuning.sharpInkWindow = true }
        m.text("Fassung", sharp ? "scharf ueber 4-fach (Ausschnitt)" : "Rueckfall: hoechstens 4-fach, ganze Seite")
        let pages = 8
        let fx = try await makeFixture(pdf: Skript.pdf(pages: pages, .schlicht), pageCount: pages)
        let store = try await openStore(fx)
        for i in 0..<pages { store.canvasChanged(pageKey: "p\(i + 1)", drawing: Handschrift.page(i, strokes: 300)) }
        _ = await store.pageStructureDocument()
        await store.flush()
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor, window = shown.window
        _ = try await waitForCanvas(editor, page: 0, strokes: 300, timeout: 30)
        let scroll = try XCTUnwrap(scrollView(editor), "Scroll-Ansicht der PDFView")
        let fit = editor.pdfView.scaleFactor
        let main = Hauptthread()
        main.start()
        defer { main.stop() }
        let takt = Bildtakt()
        takt.start()
        defer { takt.stop() }
        let mid = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        func drag(_ d: CGVector, steps: Int = 14) async throws {
            let a = CGPoint(x: mid.x - d.dx / 2, y: mid.y - d.dy / 2)
            let finger = TestFinger(at: a, in: window)
            for i in 1...steps {
                try await Task.sleep(nanoseconds: 16_000_000)
                let t = CGFloat(i) / CGFloat(steps)
                finger.move(to: CGPoint(x: a.x + d.dx * t, y: a.y + d.dy * t))
            }
            try await Task.sleep(nanoseconds: 16_000_000)
            finger.lift()
            try await Task.sleep(nanoseconds: 900_000_000)          // ausrollen
        }
        var worstGap = 0.0
        for zoom in [CGFloat(1), 3, 6] {
            editor.pdfView.scaleFactor = fit * zoom
            try await Task.sleep(nanoseconds: 1_800_000_000)
            _ = main.take()
            _ = takt.take()
            let moves0 = PageInkView.windowMoves, rescales0 = PageInkView.rescalesMade, covers0 = PageInkView.coversMade
            let resizes0 = PageInkView.windowResizes
            let start = scroll.contentOffset
            var travelled: CGFloat = 0
            var last = start
            func track() { travelled += abs(scroll.contentOffset.y - last.y) + abs(scroll.contentOffset.x - last.x); last = scroll.contentOffset }
            for _ in 0..<3 {
                try await drag(CGVector(dx: 0, dy: -420)); track()
                try await drag(CGVector(dx: 0, dy: -420)); track()
                try await drag(CGVector(dx: 0, dy: 420)); track()
                if zoom > 1 {
                    try await drag(CGVector(dx: -300, dy: -200)); track()
                    try await drag(CGVector(dx: 300, dy: 200)); track()
                }
            }
            let name = "\(Int(zoom * 100)) %"
            let frames = takt.take()
            m.add("\(name): gescrollt", Double(travelled), "pt")
            m.blocking("\(name): Hauptthread", main.take())
            m.add("\(name): Bilder", Double(frames.count), "")
            m.add("\(name): laengster Abstand zweier Bilder", frames.max * 1000, "ms")
            m.add("\(name): Bilder mit Abstand ueber 25 ms", Double(frames.over25), "")
            m.add("\(name): Bilder mit Abstand ueber 50 ms", Double(frames.over50), "")
            m.add("\(name): Ausschnitt gewandert", Double(PageInkView.windowMoves - moves0), "mal")
            m.add("\(name): dabei Groesse geaendert", Double(PageInkView.windowResizes - resizes0), "mal")
            m.add("\(name): Zoomstufe gewechselt", Double(PageInkView.rescalesMade - rescales0), "mal")
            m.add("\(name): Deckbilder", Double(PageInkView.coversMade - covers0), "")
            if let o = installedOverlays(editor).first {
                m.text("\(name): Zeichenflaeche", "Zoom \(o.canvas.zoomScale), Ausschnitt \(o.inkWindow), Seite \(o.geometry.pageSize)")
            }
            XCTAssertGreaterThan(travelled, 600, "\(name): der Finger hat gescrollt")
            XCTAssertEqual(PageInkView.windowResizes - resizes0, 0, "\(name): beim Scrollen wird die Zeichenflaeche nur verschoben, nie neu aufgebaut")
            worstGap = max(worstGap, frames.max)
        }
        m.add("laengster Abstand zweier Bilder insgesamt", worstGap * 1000, "ms")
        await store.close()
        m.finish()
    }

    /// Rueckmeldung des Inhabers 21.11.2026 (Testfassung c9dcc5b9): "Beim Schreiben bewegt sich das auch gerade ab und zu,
    /// davor war das nie so". Echter Strich mit dem Finger (`TestFinger`, PencilKit zeichnet selbst) bei 100 %, 300 % und
    /// 600 %, jeweils nach kurzem Verschieben der Seite. Vor, waehrend und nach dem Strich in jedem Bild: vorhandene Tinte
    /// (blauer Kreis) gegen PDF (roter Punkt) hoechstens 0,5 pt; dazu: Der Strich verschiebt die Zeichenflaeche nicht.
    func testTinteBleibtBeimSchreibenAufDerPDF() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let m = Messwerte("Tinte bleibt beim Schreiben")
        let video = ProcessInfo.processInfo.environment["TINTE_VIDEO"] == "1"
        let fx = try await makeFixture(pdf: Skript.markPDF(at: ringCenter), pageCount: 3)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let editor = shown.editor, window = shown.window
        var overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
        drawStroke(editor, on: overlay, Handschrift.circle(center: ringCenter, radius: 14, color: .blue))
        await store.flush()
        try await Task.sleep(nanoseconds: 800_000_000)
        let scroll = try XCTUnwrap(scrollView(editor), "Scroll-Ansicht der PDFView")
        let fit = editor.pdfView.scaleFactor
        var worst = 0.0, measured = 0, moved = 0
        var lines: [String] = []
        let start = Uhr.now()
        func measure(_ phase: String) {
            guard !video else { return }
            autoreleasepool {
                guard let image = Bild.snapshot(window) else { return }
                let area = window.bounds.insetBy(dx: window.bounds.width / 2 - 300, dy: window.bounds.height / 2 - 300)
                guard let o = Bild.markOffset(image, scale: window.screen.scale, in: area, ringDiameter: 30.5) else { return }
                measured += 1
                worst = max(worst, o.points)
                if o.points > 0.3 {
                    lines.append(String(format: "%.3f %@: Abstand %.3f pt (dx %.2f dy %.2f px)", Uhr.since(start), phase, o.points, o.dx, o.dy))
                }
            }
        }
        for factor: CGFloat in [1, 3, 6] {
            let name = "\(Int(factor * 100)) %"
            editor.pdfView.scaleFactor = fit * factor
            if let o = installedOverlay(editor, page: 0) { overlay = o }
            // Punkt in die Mitte, dann ein Stueck verschieben (wie beim Blaettern vor dem Schreiben)
            var p = overlay.content.convert(ringCenter, to: scroll)
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width), maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.contentOffset = CGPoint(x: min(max(0, p.x - scroll.bounds.width / 2), maxX), y: min(max(0, p.y - scroll.bounds.height / 2), maxY))
            try await Task.sleep(nanoseconds: 1_200_000_000)               // Zoomwechsel der Zeichenflaeche fertig
            p = overlay.content.convert(ringCenter, to: scroll)
            scroll.contentOffset = CGPoint(x: min(max(0, p.x - scroll.bounds.width / 2 + 40), maxX), y: min(max(0, p.y - scroll.bounds.height / 2 + 60), maxY))
            try await Task.sleep(nanoseconds: 600_000_000)
            let windowBefore = overlay.inkWindow, zoomBefore = overlay.canvas.zoomScale
            let strokesBefore = overlay.canvas.drawing.strokes.count
            for _ in 0..<10 { measure("\(name) vor dem Strich"); try await Task.sleep(nanoseconds: 16_000_000) }
            // Strich unterhalb des Kreises, quer (Fensterpunkte)
            let c = overlay.content.convert(ringCenter, to: window)
            let points = (0...24).map { i in CGPoint(x: c.x - 120 + CGFloat(i) * 10, y: c.y + 150 + 12 * sin(CGFloat(i) / 3)) }
            var running = true
            let watcher = Task { @MainActor in
                while running { measure("\(name) waehrend des Strichs"); try? await Task.sleep(nanoseconds: 8_000_000) }
            }
            try await TestFinger.strich(points, in: window, step: 0.016)
            running = false
            _ = await watcher.value
            for _ in 0..<40 { measure("\(name) nach dem Strich"); try await Task.sleep(nanoseconds: 16_000_000) }
            m.add("\(name): Striche vorher -> nachher", Double(strokesBefore * 1000 + overlay.canvas.drawing.strokes.count), "")
            XCTAssertEqual(overlay.canvas.drawing.strokes.count, strokesBefore + 1, "\(name): Strich angekommen")
            if overlay.inkWindow != windowBefore || overlay.canvas.zoomScale != zoomBefore {
                moved += 1
                m.text("\(name): Zeichenflaeche umgehaengt", "\(windowBefore) z \(zoomBefore) -> \(overlay.inkWindow) z \(overlay.canvas.zoomScale)")
            }
        }
        m.add("Bilder gemessen", Double(measured), "")
        for l in lines { m.text("Bild ueber 0,3 pt", l) }
        m.add("groesste Abweichung Tinte <-> PDF", worst, "pt")
        m.add("Strich hat die Zeichenflaeche umgehaengt", Double(moved), "mal")
        XCTAssertEqual(moved, 0, "Schreiben haengt die Zeichenflaeche nie um")
        if !video {
            XCTAssertGreaterThan(measured, 60, "genug Bilder")
            XCTAssertLessThanOrEqual(worst, 0.5, "Tinte bleibt in jedem Bild auf der PDF")
        }
        await store.close()
        m.finish()
    }

    /// Rueckmeldung des Inhabers 21.11.2026 am iPad (Testfassung mit c9dcc5b9): "Beim Rein-/Rauszoomen bewegen sich die
    /// Zeichen ganz leicht, aber dann sofort auf die Originalposition". PDF mit rotem Punkt, darum ein blauer Kreis aus
    /// Tinte. Zoomen wie mit zwei Fingern, in Schritten (je ein Bild) hinein ueber die 4-fach-Grenze bis 600 %, mit
    /// Pausen (Wechsel der Zoomstufe der Zeichenflaeche), wieder hinaus, schnell hinein und hinaus. In JEDEM Bild:
    /// Mitte des Kreises gegen Mitte des Punkts, in Seitenpunkten; hoechstens 0,5 pt.
    func testTinteBleibtBeimZoomenAufDerPDF() async throws {
        let m = Messwerte("Tinte bleibt auf der PDF")
        let video = ProcessInfo.processInfo.environment["TINTE_VIDEO"] == "1"
        if ProcessInfo.processInfo.environment["TINTE_GEGENPROBE"] == "1" { PencilTuning.coverWindowMoves = false }
        defer { PencilTuning.coverWindowMoves = true }
        let fx = try await makeFixture(pdf: Skript.markPDF(at: ringCenter), pageCount: 3)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor, window = shown.window
        var overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
        drawStroke(editor, on: overlay, Handschrift.circle(center: ringCenter, radius: 14, color: .blue))
        await store.flush()
        try await Task.sleep(nanoseconds: 800_000_000)
        let scroll = try XCTUnwrap(scrollView(editor), "Scroll-Ansicht der PDFView")
        func centerMark() {
            if let o = installedOverlay(editor, page: 0) { overlay = o }
            let p = overlay.content.convert(ringCenter, to: scroll)
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width), maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.contentOffset = CGPoint(x: min(max(0, p.x - scroll.bounds.width / 2), maxX), y: min(max(0, p.y - scroll.bounds.height / 2), maxY))
        }
        var worst = 0.0, measured = 0
        var lines: [String] = []
        let start = Uhr.now()
        func measure(_ phase: String) {
            guard !video else { return }
            autoreleasepool {
                guard let image = Bild.snapshot(window) else { return }
                let area = window.bounds.insetBy(dx: window.bounds.width / 2 - 300, dy: window.bounds.height / 2 - 300)
                guard let o = Bild.markOffset(image, scale: window.screen.scale, in: area, ringDiameter: 30.5) else {
                    lines.append(String(format: "%.3f %@: Kreis oder Punkt nicht gefunden", Uhr.since(start), phase))
                    return
                }
                measured += 1
                worst = max(worst, o.points)
                lines.append(String(format: "%.3f %@: Abstand %.3f pt (dx %.2f dy %.2f px), Canvas-Zoom %.1f", Uhr.since(start), phase, o.points,
                                    o.dx, o.dy, overlay.canvas.zoomScale))
            }
        }
        let fit = editor.pdfView.scaleFactor
        func zoomSteps(_ from: CGFloat, _ to: CGFloat, _ n: Int, _ phase: String) async throws {
            for i in 1...n {
                editor.pdfView.scaleFactor = fit * from * pow(to / from, CGFloat(i) / CGFloat(n))
                centerMark()
                measure(phase)
                try await Task.sleep(nanoseconds: 16_000_000)
            }
        }
        func hold(_ seconds: Double, _ phase: String) async throws {
            let end = Uhr.now() + seconds
            while Uhr.now() < end {
                measure(phase)
                try await Task.sleep(nanoseconds: 16_000_000)
            }
        }
        centerMark()
        if video { try await Task.sleep(nanoseconds: 2_000_000_000) }
        try await zoomSteps(1, 3, 20, "hinein bis 3-fach")
        try await hold(0.7, "Pause 3-fach")
        try await zoomSteps(3, 6, 20, "hinein bis 6-fach")
        try await hold(0.9, "Pause 6-fach")
        // bei 600 % verschieben wie mit einem Finger: der Ausschnitt der Zeichenflaeche wandert mehrmals mit
        let base = scroll.contentOffset
        let moves0 = PageInkView.windowMoves
        defer { m.add("Ausschnitt beim Verschieben gewandert", Double(PageInkView.windowMoves - moves0), "mal") }
        for i in 1...60 {
            let x = 170 * sin(CGFloat(i) / 60 * 2 * .pi), y = 120 * sin(CGFloat(i) / 30 * 2 * .pi)
            scroll.contentOffset = CGPoint(x: base.x + x, y: base.y + y)
            measure("verschieben bei 6-fach")
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        try await hold(0.3, "nach dem Verschieben")
        try await zoomSteps(6, 2, 25, "hinaus bis 2-fach")
        try await hold(0.9, "Pause 2-fach")
        try await zoomSteps(2, 6, 12, "schnell hinein")
        try await hold(0.9, "Pause 6-fach")
        try await zoomSteps(6, 1, 12, "schnell hinaus")
        try await hold(0.9, "eingepasst")
        m.add("Bilder gemessen", Double(measured), "")
        for l in lines { m.text("Bild", l) }
        m.add("groesste Abweichung Tinte <-> PDF", worst, "pt")
        if !video {
            XCTAssertGreaterThan(measured, 100, "genug Bilder")
            XCTAssertLessThanOrEqual(worst, 0.5, "Tinte bleibt in jedem Bild auf der PDF")
        }
        await store.close()
        m.finish()
    }

    /// Rueckmeldung des Inhabers 21.11.2026 am iPad (Testfassung mit de82ea35): "wenn man ganz nah ranzoomt, wirken die
    /// Zeichen kurz gross, dann wieder klein". Blauen Kreis schreiben, wie mit zwei Fingern in Schritten auf das
    /// Maximum zoomen (Kreis bleibt in der Mitte), dann Bild fuer Bild bis 1,6 s nach dem Zoomen die blaue Flaeche im
    /// Bild des Fensters messen, in Seitenpunkten: Sie darf sich hoechstens um 1 pt aendern (Wechsel auf den Ausschnitt,
    /// Deckbild, Neuzeichnen).
    func testTinteSpringtNichtBeimWechselAufDenAusschnitt() async throws {
        let m = Messwerte("Tinte springt nicht")
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 3, .schlicht), pageCount: 3)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor, window = shown.window
        var overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
        let ring = Handschrift.circle(center: ringCenter, radius: 14, color: .blue)
        drawStroke(editor, on: overlay, ring)
        await store.flush()
        try await Task.sleep(nanoseconds: 800_000_000)
        let scroll = try XCTUnwrap(scrollView(editor), "Scroll-Ansicht der PDFView")
        let expected = ring.renderBounds
        m.text("Kreis (renderBounds, Seitenpunkte)", "\(expected)")

        func centerRing() {
            let p = overlay.content.convert(ringCenter, to: scroll)
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width), maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.contentOffset = CGPoint(x: min(max(0, p.x - scroll.bounds.width / 2), maxX), y: min(max(0, p.y - scroll.bounds.height / 2), maxY))
        }
        struct Frame { let t: Double; let box: CGRect; let zoom: CGFloat; let covers: Int }
        var frames: [Frame] = []
        func measure(_ start: Double) {
            autoreleasepool {
                guard let image = Bild.snapshot(window), let box = Bild.blueBox(image, scale: window.screen.scale,
                                                                                         in: window.bounds.insetBy(dx: window.bounds.width / 2 - 260, dy: window.bounds.height / 2 - 260)) else { return }
                frames.append(Frame(t: Uhr.since(start), box: overlay.content.convert(box, from: window), zoom: overlay.canvas.zoomScale,
                                    covers: overlay.content.subviews.count))
            }
        }
        centerRing()
        if ProcessInfo.processInfo.environment["TINTE_VIDEO"] == "1" { try await Task.sleep(nanoseconds: 3_000_000_000) }
        let fit = editor.pdfView.scaleFactor, most = editor.pdfView.maxScaleFactor
        let renderedBefore = PageInkView.renderingsFinished
        let start = Uhr.now()
        // Pinch in 20 Schritten (je ein Bild), Kreis bleibt in der Mitte
        for i in 1...20 {
            editor.pdfView.scaleFactor = fit * pow(most / fit, CGFloat(i) / 20)
            if let o = installedOverlay(editor, page: 0) { overlay = o }
            centerRing()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        let zoomEnd = Uhr.since(start)
        // Aufnahme des Simulators (simctl io recordVideo): keine Bilder per drawHierarchy, die erzwingen ein Zeichnen
        if ProcessInfo.processInfo.environment["TINTE_VIDEO"] == "1" {
            try await Task.sleep(nanoseconds: 2_500_000_000)
            await store.close()
            return
        }
        while Uhr.since(start) < zoomEnd + 1.6 {
            if let o = installedOverlay(editor, page: 0) { overlay = o }
            measure(start)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let after = frames.filter { $0.t >= zoomEnd }
        m.add("PencilKit 'fertig gezeichnet' nach dem Zoomen", Double(PageInkView.renderingsFinished - renderedBefore), "mal")
        XCTAssertFalse(overlay.isSwitchingZoom, "Deckbild am Ende weg, Canvas wieder sichtbar")
        XCTAssertNil(overlay.canvas.layer.mask, "Canvas am Ende nicht mehr verdeckt")
        XCTAssertGreaterThan(after.count, 10, "genug Bilder nach dem Zoomen")
        for f in after {
            m.text(String(format: "Bild %.3f s", f.t),
                   String(format: "x %.2f y %.2f b %.2f h %.2f, Canvas-Zoom %.1f, Ebenen %d", f.box.minX, f.box.minY, f.box.width, f.box.height, f.zoom, f.covers))
        }
        let last = try XCTUnwrap(after.last)
        XCTAssertEqual(last.zoom, PageInkView.maxCanvasZoom, accuracy: 0.001, "am Ende scharf (Ausschnitt)")
        var worst = 0.0
        for f in after {
            let d = [abs(f.box.minX - expected.minX), abs(f.box.minY - expected.minY), abs(f.box.maxX - expected.maxX), abs(f.box.maxY - expected.maxY)].max() ?? 0
            worst = max(worst, Double(d))
            XCTAssertLessThanOrEqual(d, 1, String(format: "Bild %.3f s: Kreis %@ statt %@ (Sprung in Groesse oder Lage)", f.t, "\(f.box)", "\(expected)"))
        }
        m.add("groesste Abweichung der Tinte nach dem Zoomen", worst, "pt")
        await store.close()
        m.finish()
    }

    // MARK: Eingefuegte Seiten A6 bis A0

    /// Leerseiten in den Formaten des Web-Editors (formats.js: A6 bis A2 hoch, Whiteboard A1 und A0 quer) zwischen
    /// zwei PDF-Seiten. Je Seite: Overlay in Seitenpunkten der Seite, ein Strich in der Seitenmitte landet dort im
    /// Notizmodell. Speicher, solange die A0-Seite im Bild ist.
    func testInsertedPagesA6ToA0() async throws {
        let m = Messwerte("Seitenformate A6 bis A0")
        let base = Speicher.now()
        let formats: [(name: String, w: Double, h: Double)] = [
            ("A6", 298, 420), ("A5", 420, 595), ("A4", 595, 842), ("A3", 842, 1191), ("A2", 1191, 1684),
            ("A1 quer", 2384, 1684), ("A0 quer", 3370, 2384),
        ]
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 2), pageCount: 2)
        let store = try await openStore(fx)
        var after = "p1"
        for (i, f) in formats.enumerated() {
            let key = "bformat\(i)"
            let change = await store.applyPageStructure { doc in
                PageOrder.insertBlank(&doc, after: after, template: i % 2 == 0 ? "grid" : "lined", width: f.w, height: f.h, key: key)
            }
            XCTAssertNotNil(change, f.name)
            after = key
        }
        XCTAssertEqual(store.layout?.entries.count, 2 + formats.count)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor
        _ = try await waitForOverlay(editor, page: 0, timeout: 20)
        m.add("scaleFactor (alle Seiten gleich)", Double(editor.pdfView.scaleFactor), "")
        m.add("scaleFactorForSizeToFit", Double(editor.pdfView.scaleFactorForSizeToFit), "")
        let main = Hauptthread()
        main.start()
        for (i, f) in formats.enumerated() {
            let index = i + 1
            editor.goToPage(index)
            let t = Uhr.now()
            let overlay = try await waitForOverlay(editor, page: index, timeout: 20)
            m.add("\(f.name): Seite geladen", Uhr.since(t), "s")
            XCTAssertEqual(overlay.geometry.pageSize, CGSize(width: f.w, height: f.h), f.name)
            XCTAssertEqual(overlay.canvas.frame.size, CGSize(width: f.w, height: f.h), "\(f.name): Canvas in Seitenpunkten")
            let width = overlay.content.convert(overlay.content.bounds, to: shown.window).width
            m.add("\(f.name): Breite im Fenster", Double(width), "pt")
            let c = CGPoint(x: f.w / 2, y: f.h / 2)
            drawStroke(editor, on: overlay, Handschrift.line(from: CGPoint(x: c.x - 40, y: c.y), to: CGPoint(x: c.x + 40, y: c.y)))
            try await Task.sleep(nanoseconds: 400_000_000)
            m.memory("\(f.name) im Bild", Speicher.now(), since: base)
        }
        m.blocking("Hauptthread beim Wechsel der Formate", main.take())
        main.stop()
        await store.flush()
        for (i, f) in formats.enumerated() {
            let strokes = await store.objects(forPageKey: "bformat\(i)").filter { $0["type"]?.string == "stroke" }
            XCTAssertEqual(strokes.count, 1, f.name)
            let pts = strokes.first?["points"]?.array?.compactMap(\.double) ?? []
            let xs = stride(from: 0, to: pts.count, by: 2).map { pts[$0] }
            let ys = stride(from: 1, to: pts.count, by: 2).map { pts[$0] }
            XCTAssertEqual(((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, f.w / 2, accuracy: 3, "\(f.name): Strich waagrecht in der Mitte")
            XCTAssertEqual(ys.reduce(0, +) / Double(max(ys.count, 1)), f.h / 2, accuracy: 3, "\(f.name): Strich senkrecht in der Mitte")
        }
        await store.close()
        m.finish()
    }

    // MARK: Rueckgaengig ueber Seiten

    /// Dokumentweiter Verlauf (PDFEditorController.registerUndo): je ein Strich auf Seite 2, Seite 9 und einer vollen
    /// Seite 30 (300 Striche von frueher, nicht im Verlauf). Danach weit weg blaettern, bis keine der drei Seiten mehr
    /// ein Overlay hat (weder sichtbar noch geparkt): Rueckgaengig wirkt dann auf den gespeicherten Stand und springt
    /// zur Seite. Dreimal Rueckgaengig nimmt die Striche in umgekehrter Reihenfolge zurueck, dreimal Wiederholen bringt
    /// sie zurueck; nach dem erneuten Oeffnen ist der letzte Stand da. Gemessen wird die Zeit je Schritt, bis die Seite
    /// mit dem erwarteten Stand auf der Canvas liegt (nur protokolliert).
    func testUndoRedoAcrossPagesAfterScrollingAway() async throws {
        try ContainerTestBed.requireEventGroupedUndo()
        let m = Messwerte("Rueckgaengig ueber Seiten")
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 60, .schlicht), pageCount: 60)
        let store = try await openStore(fx)
        store.canvasChanged(pageKey: "p30", drawing: Handschrift.page(29, strokes: 300))
        _ = await store.pageStructureDocument()
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor
        _ = try await waitForOverlay(editor, page: 0, timeout: 30)
        XCTAssertFalse(editor.undoManager?.canUndo ?? true, "Verlauf am Anfang leer")

        let pages: [(key: String, index: Int, before: Int)] = [("p2", 1, 0), ("p9", 8, 0), ("p30", 29, 300)]
        for (n, p) in pages.enumerated() {
            editor.goToPage(p.index)
            let o = try await waitForCanvas(editor, page: p.index, strokes: p.before, timeout: 30)
            let y = 200 + CGFloat(n) * 40
            drawStroke(editor, on: o, Handschrift.line(from: CGPoint(x: 100, y: y), to: CGPoint(x: 300, y: y),
                                                       created: Date(timeIntervalSinceReferenceDate: 796_000_000 + Double(n))))
            try await Task.sleep(nanoseconds: 150_000_000)     // eigener Schritt (UndoManager fasst je Durchlauf zusammen)
        }

        // weit weg: so lange springen, bis keine der drei Seiten mehr ein Overlay hat
        var jumps = 0
        for far in [40, 44, 48, 52, 56, 59, 42, 46, 50, 54] {
            if Set(pages.map(\.key)).isDisjoint(with: boundKeys(editor)) { break }
            editor.goToPage(far)
            _ = try await waitForOverlay(editor, page: far, timeout: 30)
            try await Task.sleep(nanoseconds: 100_000_000)
            jumps += 1
        }
        m.add("Spruenge, bis keine der Seiten mehr ein Overlay hat", Double(jumps), "")
        XCTAssertTrue(Set(pages.map(\.key)).isDisjoint(with: boundKeys(editor)),
                      "Messaufbau: Seiten noch gebunden \(boundKeys(editor).intersection(pages.map(\.key)))")

        for p in pages.reversed() {
            let t = Uhr.now()
            editor.undo()
            _ = try await waitForCanvas(editor, page: p.index, strokes: p.before, timeout: 30)
            m.add("Rueckgaengig \(p.key) (\(p.before) Striche): bis Seite mit altem Stand im Bild", Uhr.since(t), "s")
            XCTAssertEqual(editor.currentPageKey, p.key, "Rueckgaengig springt zur Seite \(p.index + 1)")
        }
        XCTAssertFalse(editor.undoManager?.canUndo ?? true, "genau drei Schritte im Verlauf")
        await store.flush()
        for p in pages {
            let n = await store.objects(forPageKey: p.key).count
            XCTAssertEqual(n, p.before, "\(p.key) nach dem Rueckgaengig gespeichert")
        }

        for p in pages {
            let t = Uhr.now()
            editor.redo()
            _ = try await waitForCanvas(editor, page: p.index, strokes: p.before + 1, timeout: 30)
            m.add("Wiederholen \(p.key): bis Seite mit neuem Stand im Bild", Uhr.since(t), "s")
        }
        XCTAssertFalse(editor.undoManager?.canRedo ?? true, "nichts mehr zu wiederholen")
        hide(shown)
        await store.close()

        let again = try await openStore(fx)
        for p in pages {
            let n = await again.objects(forPageKey: p.key).count
            XCTAssertEqual(n, p.before + 1, "\(p.key) nach Wiederholen und erneutem Oeffnen")
        }
        await again.close()
        m.finish()
    }

    // MARK: Dokument im lokalen Backend

    struct Fixture {
        let root: URL
        let host: LocalBackendHost
        let api: APIClient
        let file: LibFile
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-messung-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Datei im lokalen Backend angemeldet (Kurs und Datei in der Datenbank, damit Speicherrunden wirklich
    /// geschrieben werden), Original-PDF im Zwischenspeicher des Editors mit passendem Stand (`stamp`), so wie nach
    /// dem ersten Oeffnen einer Datei aus Stud.IP.
    private func makeFixture(pdf: Data, pageCount: Int) async throws -> Fixture {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-27T10:00:00")!)
        let backend = try await host.backend()
        let fileID = "messung-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-mess"), .text("Messkurs"), .text("WiSe 2026/27"), .text("Messkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-mess"), .text("Messskript.pdf"), .integer(1_792_000_000),
                           .text("2026-10-27T09:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let meta = try await api.value("/api/files/\(fileID)")
        try DocumentStore.stamp(meta).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Messskript.pdf", title: "Messskript", kind: "pdf", module_id: nil, subject: "Messkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-10-27T09:00:00", has_notes: nil,
                           page_count: pageCount, studip_folder: nil)
        return Fixture(root: root, host: host, api: api, file: file)
    }

    private func openStore(_ fx: Fixture) async throws -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        XCTAssertNotNil(store.layout, "Seitenaufbau vorhanden")
        return store
    }

    // MARK: Editor im Fenster

    struct Shown {
        let editor: PDFEditorController
        let window: UIWindow
    }

    /// Editor als Inhalt eines eigenen Fensters in Bildschirmgroesse (wie PDFEditorView: Stift schreibt, Finger scrollt).
    private func show(_ store: DocumentStore, pencilOnly: Bool = true) -> Shown {
        let editor: PDFEditorController
        if pencilOnly {
            editor = PDFEditorController(store: store)
        } else {
            // Finger schreibt: eigene Werkzeug-Einstellungen (Stift), unabhaengig von anderen Tests
            let suite = "uniflow.tests.tinte-lage.\(UUID().uuidString)"
            let toolDefaults = UserDefaults(suiteName: suite) ?? .standard
            addTeardownBlock { toolDefaults.removePersistentDomain(forName: suite) }
            editor = PDFEditorController(store: store, tools: EditorToolState(defaults: toolDefaults))
        }
        editor.pencilOnly = pencilOnly
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 834, height: 1210)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        return Shown(editor: editor, window: window)
    }

    private func hide(_ shown: Shown) {
        guard shown.window.rootViewController != nil else { return }
        shown.editor.showToolPicker(false)
        shown.window.isHidden = true
        shown.window.rootViewController = nil
    }

    /// Overlays, die PDFKit gerade in die PDFView eingesetzt hat (aktueller Seitenaufbau).
    private func installedOverlays(_ editor: PDFEditorController) -> [PageInkView] {
        var out: [PageInkView] = []
        func walk(_ v: UIView) {
            if let o = v as? PageInkView {
                if o.generation == editor.shownLayoutVersion, o.window != nil { out.append(o) }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(editor.pdfView)
        return out
    }

    private func installedOverlay(_ editor: PDFEditorController, page: Int) -> PageInkView? {
        installedOverlays(editor).first { $0.pageIndex == page }
    }

    private func waitForOverlay(_ editor: PDFEditorController, page: Int, timeout: Double) async throws -> PageInkView {
        let end = Uhr.now() + timeout
        while Uhr.now() < end {
            if let o = installedOverlay(editor, page: page), o.loaded, o.bounds.width > 0 { return o }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MessFehler("PDFKit hat in \(Int(timeout)) s kein geladenes Overlay fuer Seite \(page + 1) eingesetzt")
    }

    /// Wie `waitForOverlay`, dazu genau `strokes` Striche auf der Canvas.
    private func waitForCanvas(_ editor: PDFEditorController, page: Int, strokes: Int, timeout: Double) async throws -> PageInkView {
        let end = Uhr.now() + timeout
        var seen = -1
        while Uhr.now() < end {
            if let o = installedOverlay(editor, page: page), o.loaded, o.bounds.width > 0 {
                seen = o.canvas.drawing.strokes.count
                if seen == strokes { return o }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MessFehler("Seite \(page + 1): nach \(Int(timeout)) s \(seen) statt \(strokes) Striche auf der Canvas")
    }

    /// Seitenschluessel, fuer die der Editor gerade ein Overlay des aktuellen Seitenaufbaus haelt (sichtbar oder
    /// geparkt). Private Felder ueber Mirror, nur fuer den Messaufbau.
    private func boundKeys(_ editor: PDFEditorController) -> Set<String> {
        let mirror = Mirror(reflecting: editor)
        let live = (mirror.children.first { $0.label == "live" }?.value as? [Int: PageInkView]).map { Array($0.values) } ?? []
        let parked = mirror.children.first { $0.label == "parked" }?.value as? [PageInkView] ?? []
        return Set((live + parked).filter { $0.generation == editor.shownLayoutVersion }.map(\.pageKey))
    }

    private func scrollView(_ editor: PDFEditorController) -> UIScrollView? {
        func find(_ v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView, !(v is PKCanvasView) { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return find(editor.pdfView)
    }

    /// Strich wie mit dem Stift: Canvas aendert sich, der Editor bekommt die Meldung von PencilKit.
    private func drawStroke(_ editor: PDFEditorController, on overlay: PageInkView, _ stroke: PKStroke) {
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        var d = overlay.canvas.drawing
        d.strokes.append(stroke)
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = d
        overlay.isApplyingDrawing = false
        editor.canvasViewDrawingDidChange(overlay.canvas)
        editor.canvasViewDidEndUsingTool(overlay.canvas)
    }

    // MARK: Blaettern

    struct ScrollResult {
        var seconds = 0.0
        var steps = 0
        var reachedEnd = false
        var seen: Set<Int> = []
        /// Zeit vom ersten Erscheinen eines Overlays bis "geladen" (nur Seiten, die geladen erschienen oder es wurden)
        var loadLatency: [Double] = []
        /// Seiten, die wieder aus dem Bild waren, bevor ihr Inhalt geladen war
        var unloadedPassed = 0
        /// Ueberschreitung der 16 ms je Schritt (Hauptthread beschaeftigt oder System ausgelastet)
        var stepOverrun: [Double] = []
        /// PageInkView-Objekte, die nach dem Blaettern noch leben (sichtbar, geparkt oder von PDFKit gehalten)
        var aliveOverlays = 0
        /// PencilKit-Canvas-Ansichten (je Overlay eine), die nach dem Blaettern noch leben. Haelt etwas anderes als
        /// das Overlay sie fest (z. B. die Palette als Beobachter), bleiben sie hier stehen, auch wenn das Overlay weg ist.
        var aliveCanvases = 0
        /// neu angelegte PageInkView-Objekte waehrend des Blaetterns
        var createdOverlays = 0
        var liveInEditor = -1
        var parkedInEditor = -1
        var pageCount = 0
        /// nach dem Abarbeiten der Ladevorgaenge (nur mit `drain`)
        var aliveAfterDrain = 0
        var drainSeconds = 0.0
        /// hoechster Speicherstand waehrend des Blaetterns und Abarbeitens (je Schritt abgefragt)
        var peak = Speicher(footprint: 0, resident: 0)
    }

    /// Durchgehend nach unten scrollen wie mit dem Finger: je Bildwechsel (16 ms) ein Viertel der Fensterhoehe
    /// (bei A4 und eingepasster Breite etwa 16 Seiten je Sekunde). Festes Zeitlimit; danach bricht der Test mit
    /// Meldung ab statt zu haengen.
    /// - Parameters:
    ///   - distance: hoechstens so weit scrollen (Punkte der Scroll-Ansicht); ohne Angabe bis zum Ende.
    ///   - drain: danach hoechstens so lange warten, bis weggescrollte Overlays freigegeben sind (laufende
    ///     Ladevorgaenge halten ihr Overlay bis zum Ende fest).
    private func scrollThrough(_ shown: Shown, timeLimit: Double, distance: CGFloat? = nil,
                               stepFraction: CGFloat = 0.25, drain: Double = 0) async throws -> ScrollResult {
        let editor = shown.editor
        let scroll = try XCTUnwrap(scrollView(editor), "Scroll-Ansicht der PDFView")
        var r = ScrollResult()
        r.pageCount = editor.pdfView.document?.pageCount ?? 0
        var firstSeen: [Int: Double] = [:]
        var loaded: Set<Int> = []
        // je Objekt-Adresse ein schwacher Verweis; eine wiederverwendete Adresse (freigegeben, neu angelegt) ersetzt ihn
        var everSeen: [ObjectIdentifier: WeakBox<PageInkView>] = [:]
        var canvases: [ObjectIdentifier: WeakBox<PKCanvasView>] = [:]
        var created = 0
        let step = max(40, scroll.bounds.height * stepFraction)
        let start = Uhr.now()
        let deadline = start + timeLimit
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        var visibleBefore = Set<Int>()
        func observe() {
            let now = Uhr.now()
            let mem = Speicher.now()
            if mem.footprint > r.peak.footprint { r.peak = mem }
            var visible = Set<Int>()
            for o in installedOverlays(editor) {
                visible.insert(o.pageIndex)
                let id = ObjectIdentifier(o)
                if everSeen[id]?.value !== o {
                    everSeen[id] = WeakBox(o)
                    created += 1
                }
                let cid = ObjectIdentifier(o.canvas)
                if canvases[cid]?.value !== o.canvas { canvases[cid] = WeakBox(o.canvas) }
                if firstSeen[o.pageIndex] == nil { firstSeen[o.pageIndex] = now }
                if o.loaded, loaded.insert(o.pageIndex).inserted { r.loadLatency.append(now - firstSeen[o.pageIndex]!) }
            }
            for gone in visibleBefore.subtracting(visible) where !loaded.contains(gone) { r.unloadedPassed += 1 }
            visibleBefore = visible
            r.seen.formUnion(visible)
        }
        observe()
        var y = scroll.contentOffset.y
        let endY = distance.map { min(maxY, y + $0) } ?? maxY
        while Uhr.now() < deadline {
            if y >= endY - 0.5 { r.reachedEnd = true; break }
            y = min(endY, y + step)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
            let t = Uhr.now()
            try await Task.sleep(nanoseconds: 16_000_000)
            r.stepOverrun.append(max(0, Uhr.since(t) - 0.016))
            r.steps += 1
            observe()
        }
        // am Ende: sichtbare Seiten laden lassen (hoechstens 5 s)
        let settle = Uhr.now() + 5
        while Uhr.now() < settle, installedOverlays(editor).contains(where: { !$0.loaded }) {
            try await Task.sleep(nanoseconds: 20_000_000)
            observe()
        }
        r.seconds = Uhr.since(start)
        try await Task.sleep(nanoseconds: 200_000_000)
        r.aliveOverlays = everSeen.values.filter { $0.value != nil }.count
        r.aliveCanvases = canvases.values.filter { $0.value != nil }.count
        let drainStart = Uhr.now()
        r.aliveAfterDrain = r.aliveOverlays
        while drain > 0 {
            let now = Speicher.now()
            if now.footprint > r.peak.footprint { r.peak = now }
            r.aliveAfterDrain = everSeen.values.filter { $0.value != nil }.count
            let visibleLoaded = installedOverlays(editor).allSatisfy(\.loaded)
            if (r.aliveAfterDrain <= 15 && visibleLoaded) || Uhr.since(drainStart) > drain { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        r.drainSeconds = drain > 0 ? Uhr.since(drainStart) : 0
        r.createdOverlays = created
        // nur Hinweis (private Felder des Editors ueber Mirror): sichtbare und geparkte Overlays
        let mirror = Mirror(reflecting: editor)
        r.liveInEditor = (mirror.children.first { $0.label == "live" }?.value as? [Int: PageInkView])?.count ?? -1
        r.parkedInEditor = (mirror.children.first { $0.label == "parked" }?.value as? [PageInkView])?.count ?? -1
        return r
    }

    // MARK: Zoom-Schaerfe

    struct Sharpness {
        var pdf: Edge?
        var ink: Edge?
        var waitedForPDF = 0.0
    }

    struct Edge {
        /// mittlere Breite der oberen und unteren Kante in Bildpunkten des Fensters (Median ueber Spalten)
        var edge: Double
        /// Dicke der Linie (Pixel dunkler als 50 %)
        var thickness: Double
    }

    /// PDF-Linie und Tintenstrich von Seite `page` in die Fenstermitte holen, Bild des Fensters, Kanten messen. Wartet
    /// bis `waitForPDF` Sekunden, bis PDFKit die Linie scharf neu gezeichnet hat.
    private func sharpness(_ shown: Shown, page: Int, waitForPDF: Double) async throws -> Sharpness {
        let editor = shown.editor, window = shown.window
        var overlay = try await waitForOverlay(editor, page: page, timeout: 15)
        let both = Skript.rule.union(CGRect(x: Skript.rule.minX, y: Skript.inkY - 3, width: Skript.rule.width, height: 6))
        if let scroll = scrollView(editor) {
            let r = overlay.content.convert(both, to: window)
            let dx = r.midX - window.bounds.midX, dy = r.midY - window.bounds.midY
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: min(max(0, scroll.contentOffset.x + dx), maxX),
                                            y: min(max(0, scroll.contentOffset.y + dy), maxY)), animated: false)
            try await Task.sleep(nanoseconds: 300_000_000)
            overlay = try await waitForOverlay(editor, page: page, timeout: 15)
        }
        let scale = window.screen.scale
        var out = Sharpness()
        let start = Uhr.now()
        repeat {
            try await Task.sleep(nanoseconds: 400_000_000)
            let ruleRect = overlay.content.convert(Skript.rule, to: window).insetBy(dx: 0, dy: -12)
            let inkRect = overlay.content.convert(CGRect(x: Skript.rule.minX + 40, y: Skript.inkY - 3, width: Skript.rule.width - 80, height: 6),
                                                 to: window).insetBy(dx: 0, dy: -12)
            autoreleasepool {
                guard let image = Bild.snapshot(window) else { return }
                out.pdf = Bild.edge(image, scale: scale, rect: ruleRect.intersection(window.bounds))
                out.ink = Bild.edge(image, scale: scale, rect: inkRect.intersection(window.bounds))
            }
            out.waitedForPDF = Uhr.since(start)
        } while (out.pdf?.edge ?? 99) > 2.5 && Uhr.since(start) < waitForPDF
        return out
    }
}

// MARK: - Messwerte

/// Messwerte eines Tests, sofort auf der Konsole (auch ein abgebrochener Lauf zeigt, was er schon hatte).
@MainActor
final class Messwerte {
    let test: String
    private let start = Uhr.now()

    init(_ test: String) {
        self.test = test
        text("Lastmittel bei Beginn (1/5/15 min)", Last.text())
    }

    /// Am Ende des Tests: Lastmittel und Dauer (die Last schwankt waehrend voller Laeufe stark).
    func finish() {
        text("Lastmittel am Ende (1/5/15 min)", Last.text())
        add("Dauer des Tests", Uhr.since(start), "s")
    }

    func add(_ name: String, _ value: Double, _ unit: String) {
        print("[EditorMessung] \(test) | \(name) = \(String(format: value.magnitude >= 100 ? "%.0f" : "%.3f", value)) \(unit)")
    }

    func text(_ name: String, _ value: String) {
        print("[EditorMessung] \(test) | \(name) = \(value)")
    }

    func memory(_ name: String, _ s: Speicher, since base: Speicher) {
        add("Speicher \(name): phys_footprint", Double(s.footprint) / 1_048_576, "MB")
        add("Speicher \(name): resident_size", Double(s.resident) / 1_048_576, "MB")
        add("Speicher \(name): Zuwachs seit Testbeginn", Double(Int64(s.footprint) - Int64(base.footprint)) / 1_048_576, "MB")
    }

    func blocking(_ name: String, _ b: Hauptthread.Summary) {
        add("\(name): laengster Block", b.max * 1000, "ms")
        add("\(name): 99. Perzentil", b.p99 * 1000, "ms")
        add("\(name): Bloecke ueber 50 ms", Double(b.over50), "")
    }

    func scroll(_ r: EditorScaleTests.ScrollResult) {
        add("Blaettern: Dauer", r.seconds, "s")
        add("Blaettern: Schritte zu 16 ms", Double(r.steps), "")
        add("Blaettern: Seiten mit Overlay", Double(r.seen.count), "von \(r.pageCount)")
        add("Blaettern: Seiten je Sekunde", Double(r.seen.count) / max(r.seconds, 0.001), "")
        let lat = r.loadLatency.sorted()
        if !lat.isEmpty {
            add("Blaettern: Laden bis sichtbar Median", lat[lat.count / 2] * 1000, "ms")
            add("Blaettern: Laden bis sichtbar 95. Perzentil", lat[min(lat.count - 1, lat.count * 95 / 100)] * 1000, "ms")
            add("Blaettern: Laden bis sichtbar laengstes", (lat.last ?? 0) * 1000, "ms")
        }
        add("Blaettern: Seiten vorbeigescrollt, bevor geladen", Double(r.unloadedPassed), "")
        let over = r.stepOverrun.sorted()
        if !over.isEmpty {
            add("Blaettern: Schritt ueber 16 ms Median", over[over.count / 2] * 1000, "ms")
            add("Blaettern: Schritt ueber 16 ms laengster", (over.last ?? 0) * 1000, "ms")
            add("Blaettern: Schritte ueber 100 ms", Double(over.filter { $0 > 0.084 }.count), "")
        }
        add("Blaettern: Overlays angelegt", Double(r.createdOverlays), "")
        add("Blaettern: Overlays noch lebendig", Double(r.aliveOverlays), "")
        add("Blaettern: Canvas-Ansichten noch lebendig", Double(r.aliveCanvases), "")
        add("Blaettern: im Editor sichtbar/geparkt", Double(r.liveInEditor), "/ \(r.parkedInEditor)")
        if r.drainSeconds > 0 {
            add("Blaettern: Ladevorgaenge abgearbeitet nach", r.drainSeconds, "s")
            add("Blaettern: Overlays lebendig nach dem Abarbeiten", Double(r.aliveAfterDrain), "")
        }
        add("Blaettern: Spitze phys_footprint", Double(r.peak.footprint) / 1_048_576, "MB")
    }

    func sharpness(_ name: String, _ s: EditorScaleTests.Sharpness) {
        if let p = s.pdf {
            add("Schaerfe \(name): PDF-Linie Kante", p.edge, "px")
            add("Schaerfe \(name): PDF-Linie Dicke", p.thickness, "px")
        } else { text("Schaerfe \(name): PDF-Linie", "nicht gefunden") }
        if let i = s.ink {
            add("Schaerfe \(name): Tinte Kante", i.edge, "px")
            add("Schaerfe \(name): Tinte Dicke", i.thickness, "px")
        } else { text("Schaerfe \(name): Tinte", "nicht gefunden") }
        add("Schaerfe \(name): gewartet auf PDFKit", s.waitedForPDF, "s")
    }

    /// Groesse des Dokuments, des Journals und der Datenbank nach einer Speicherrunde.
    func storage(_ name: String, store: DocumentStore, fx: EditorScaleTests.Fixture) async throws {
        let doc = await store.pageStructureDocument()
        let body = doc.root.serialized()
        var pk = 0, strokes = 0
        for page in doc.pages.values {
            pk += page["pkdrawing"]?["data"]?.string?.utf8.count ?? 0
            strokes += page["objects"]?.array?.count ?? 0
        }
        add("\(name): Striche im Dokument", Double(strokes), "")
        add("\(name): Dokument (JSON einer Runde)", Double(body.count) / 1_048_576, "MB")
        add("\(name): davon pkdrawing (Base64)", Double(pk) / 1_048_576, "MB")
        add("\(name): je Strich", Double(body.count) / Double(max(strokes, 1)), "Byte")
        add("\(name): Journal auf der Platte", Double(Dateien.size(fx.root.appendingPathComponent("journal", isDirectory: true))) / 1_048_576, "MB")
        let db = fx.host.databaseURL
        add("\(name): Datenbank (Datei)", Double(Dateien.fileSize(db)) / 1_048_576, "MB")
        add("\(name): Datenbank (WAL)", Double(Dateien.fileSize(URL(fileURLWithPath: db.path + "-wal"))) / 1_048_576, "MB")
        let backend = try await fx.host.backend()
        let rows = try await backend.context.database.rows(
            "SELECT version, length(CAST(data AS BLOB)) AS size FROM annotation_versions WHERE file_id=? ORDER BY version",
            [.text(fx.file.id)])
        let total = rows.reduce(0.0) { $0 + ($1["size"]?.double ?? 0) }
        add("\(name): Versionen im Verlauf", Double(rows.count), "")
        add("\(name): Versionen zusammen", total / 1_048_576, "MB")
    }

    /// Aufteilung einer Speicherrunde nachgestellt: dieselben Schritte wie Client und lokales Backend
    /// (SyncEngine.buildRoot + serialized, AnnotationEndpoints: objectBody prueft mit JSONValue.parse, PyJSON.parse,
    /// dumps); der Rest der gemessenen Runde ist SQLite (alter Stand lesen, Stand und Version schreiben, kuerzen).
    func roundParts(_ name: String, store: DocumentStore, round: Double) async throws {
        let doc = await store.pageStructureDocument()
        var t = Uhr.now()
        let data = doc.root.serialized()
        let serialize = Uhr.since(t)
        t = Uhr.now()
        _ = try JSONValue.parse(data)
        let parse = Uhr.since(t)
        t = Uhr.now()
        let py = try PyJSON.parse(data)
        let pyParse = Uhr.since(t)
        t = Uhr.now()
        let text = py.dumps(ensureASCII: false)
        let dumps = Uhr.since(t)
        add("\(name): Runde nachgestellt: serialisieren (Geraet)", serialize, "s")
        add("\(name): Runde nachgestellt: JSON pruefen (objectBody)", parse, "s")
        add("\(name): Runde nachgestellt: PyJSON.parse", pyParse, "s")
        add("\(name): Runde nachgestellt: dumps", dumps, "s")
        add("\(name): Runde nachgestellt: Rest (SQLite, Kopien)", max(0, round - serialize - parse - pyParse - dumps), "s")
        add("\(name): gespeicherter Text", Double(text.utf8.count) / 1_048_576, "MB")
    }

    /// Verlauf im Backend: Anzahl und Groesse je Version.
    func versions(_ fx: EditorScaleTests.Fixture) async throws {
        let backend = try await fx.host.backend()
        let rows = try await backend.context.database.rows(
            "SELECT version, length(CAST(data AS BLOB)) AS size FROM annotation_versions WHERE file_id=? ORDER BY version",
            [.text(fx.file.id)])
        text("Versionen (Nummer:MB)", rows.map { r in
            "\(r["version"]?.int ?? 0):" + String(format: "%.1f", (r["size"]?.double ?? 0) / 1_048_576)
        }.joined(separator: " "))
    }
}

struct MessFehler: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Zeit und Speicher

/// Lastmittel des Rechners (im Simulator das des Macs): 1, 5 und 15 Minuten.
enum Last {
    static func text() -> String {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) == 3 else { return "unbekannt" }
        return l.map { String(format: "%.0f", $0) }.joined(separator: " / ")
    }
}

enum Uhr {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    static func since(_ t: Double) -> Double { now() - t }
}

/// Speicher des Prozesses: `phys_footprint` (Anzeige in Xcode, Grundlage fuer Jetsam auf dem Geraet) und
/// `resident_size`. Im Simulator ist das der Mac-Prozess der App: nur als Groessenordnung brauchbar.
struct Speicher {
    let footprint: UInt64
    let resident: UInt64

    static func now() -> Speicher { Speicher(footprint: footprintBytes(), resident: residentBytes()) }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// Spitzenwert des Speichers, alle 5 ms auf eigenem Thread abgetastet.
final class Spitze: @unchecked Sendable {
    private let lock = NSLock()
    private var footprint: UInt64 = 0
    private var resident: UInt64 = 0
    private var running = true

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let f = Speicher.footprintBytes(), r = Speicher.residentBytes()
                lock.lock()
                footprint = max(footprint, f)
                resident = max(resident, r)
                let go = running
                lock.unlock()
                if !go { return }
                usleep(5_000)
            }
        }
    }

    /// Spitze neu beginnen (ab dem jetzigen Stand)
    func reset() {
        let f = Speicher.footprintBytes(), r = Speicher.residentBytes()
        lock.lock()
        footprint = f
        resident = r
        lock.unlock()
    }

    /// Spitze bis jetzt (Abtastung laeuft weiter)
    func current() -> Speicher {
        lock.lock()
        defer { lock.unlock() }
        return Speicher(footprint: footprint, resident: resident)
    }

    func stop() -> Speicher {
        lock.lock()
        defer { lock.unlock() }
        running = false
        return Speicher(footprint: max(footprint, Speicher.footprintBytes()), resident: max(resident, Speicher.residentBytes()))
    }
}

/// Wie lange der Hauptthread am Stueck nicht zum Zug kommt: ein Task auf dem MainActor schlaeft je 10 ms, was
/// darueber hinausgeht, war der Hauptthread beschaeftigt (oder das System ausgelastet).
@MainActor
final class Hauptthread {
    struct Summary {
        var max = 0.0
        var p99 = 0.0
        var over50 = 0
    }

    private var task: Task<Void, Never>?
    private var delays: [Double] = []
    /// Waehrend `excluding` laeuft: Werte verwerfen. `epoch` zaehlt jeden Wechsel, damit auch ein Wert verworfen wird,
    /// der vor dem Abschnitt begann und erst danach fertig wurde.
    private var excluded = false
    private var epoch = 0

    func start() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let t = Uhr.now()
                let e = self?.epoch ?? 0
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard let me = self else { return }
                if !me.excluded, me.epoch == e { me.delays.append(max(0, Uhr.since(t) - 0.010)) }
            }
        }
    }

    /// Arbeit des Tests selbst (Testdaten erzeugen, Groessen auswerten) zaehlt nicht zur Messung.
    func excluding<T>(_ body: () throws -> T) rethrows -> T {
        excluded = true
        epoch += 1
        defer { excluded = false; epoch += 1 }
        return try body()
    }

    func excluding<T>(_ body: () async throws -> T) async rethrows -> T {
        excluded = true
        epoch += 1
        defer { excluded = false; epoch += 1 }
        return try await body()
    }

    /// Bisherige Werte zusammenfassen und zuruecksetzen.
    func take() -> Summary {
        let d = delays.sorted()
        delays = []
        guard !d.isEmpty else { return Summary() }
        return Summary(max: d.last ?? 0, p99: d[min(d.count - 1, d.count * 99 / 100)], over50: d.filter { $0 > 0.05 }.count)
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Abstand der Bilder auf dem Bildschirm (CADisplayLink): Haelt der Hauptthread ein Bild auf, fehlt es hier.
@MainActor
final class Bildtakt: NSObject {
    struct Summary {
        var count = 0
        var max = 0.0
        var over25 = 0
        var over50 = 0
    }

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []

    func start() {
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 { gaps.append(now - last) }
        last = now
    }

    func take() -> Summary {
        let g = gaps
        gaps = []
        return Summary(count: g.count, max: g.max() ?? 0, over25: g.filter { $0 > 0.025 }.count, over50: g.filter { $0 > 0.05 }.count)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

enum Dateien {
    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func size(_ dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += v?.fileSize ?? 0 }
        }
        return total
    }
}

// MARK: - Testdaten

/// Erfundenes Vorlesungsskript aus UIGraphicsPDFRenderer.
enum Skript {
    /// Waagrechte schwarze Linie auf jeder A4-Seite (Seitenpunkte, Ursprung oben links): Bezugskante fuer die
    /// Zoom-Schaerfe.
    static let rule = CGRect(x: 60, y: 702, width: 300, height: 2)
    /// Hoehe des Tintenstrichs knapp ueber der Linie
    static let inkY: CGFloat = 680

    enum Art {
        /// A4 hoch: Titel, 14 Textzeilen, Diagramm aus Vektoren, jede 3. Seite ein Foto (6 verschiedene JPEGs)
        case vorlesung
        /// wie `vorlesung`, aber jede 10. Seite A4 quer und jede 25. im Folienformat 16:9
        case gemischt
        /// nur Titel und Linie (dichtes Skript: dort sind die Striche der Inhalt)
        case schlicht
    }

    /// Drei leere A4-Seiten, auf der ersten ein roter Punkt (4 x 4 pt) mit der Mitte bei `center` (Seitenpunkte, oben links)
    static func markPDF(at center: CGPoint) -> Data {
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: a4).pdfData { ctx in
            for i in 0..<3 {
                ctx.beginPage()
                UIColor.white.setFill()
                ctx.fill(a4)
                if i == 0 {
                    UIColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
                    ctx.fill(CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
                }
            }
        }
    }

    static func pdf(pages n: Int, _ art: Art = .vorlesung) -> Data {
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: a4)
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.black]
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.darkGray]
        let photos = art == .schlicht ? [] : (0..<6).map(photo)
        return renderer.pdfData { ctx in
            for i in 0..<n {
                var bounds = a4
                if art == .gemischt, i > 0 {
                    if i % 25 == 24 { bounds = CGRect(x: 0, y: 0, width: 960, height: 540) }
                    else if i % 10 == 9 { bounds = CGRect(x: 0, y: 0, width: 842, height: 595) }
                }
                ctx.beginPage(withBounds: bounds, pageInfo: [:])
                ("Messskript – Folie \(i + 1)" as NSString).draw(at: CGPoint(x: 48, y: 40), withAttributes: title)
                if art != .schlicht {
                    for l in 0..<14 {
                        ("Satz \(l + 1) der Folie \(i + 1): erfundener Text, Formel a² + b² = c², Beispiel \(i * 7 % 13)." as NSString)
                            .draw(at: CGPoint(x: 48, y: 90 + CGFloat(l) * 22), withAttributes: body)
                    }
                    diagram(in: CGRect(x: 320, y: min(bounds.height - 260, 420), width: 220, height: 160), seed: i)
                    if i % 3 == 1 {
                        photos[i % photos.count].draw(in: CGRect(x: 48, y: min(bounds.height - 250, 420), width: 240, height: 150))
                    }
                }
                if bounds == a4 {
                    UIColor.black.setFill()
                    UIRectFill(rule)
                }
            }
        }
    }

    /// Achsen, 30 Gitterlinien und eine Kurve (Vektoren, wie ein Diagramm in einer Vorlesung).
    private static func diagram(in r: CGRect, seed: Int) {
        let path = UIBezierPath()
        for k in 0...15 {
            let x = r.minX + r.width * CGFloat(k) / 15, y = r.minY + r.height * CGFloat(k) / 15
            path.move(to: CGPoint(x: x, y: r.minY)); path.addLine(to: CGPoint(x: x, y: r.maxY))
            path.move(to: CGPoint(x: r.minX, y: y)); path.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        UIColor(white: 0.8, alpha: 1).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        let curve = UIBezierPath()
        for k in 0...80 {
            let t = CGFloat(k) / 80
            let p = CGPoint(x: r.minX + r.width * t, y: r.midY - sin(t * .pi * CGFloat(2 + seed % 3)) * r.height * 0.4)
            if k == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
        }
        UIColor.systemBlue.setStroke()
        curve.lineWidth = 1.5
        curve.stroke()
    }

    /// Erfundenes Foto (800 x 500 Pixel, JPEG): Verlauf und 300 farbige Rechtecke mit festem Startwert.
    private static func photo(_ n: Int) -> UIImage {
        var rng = SplitMix64(seed: 77 &+ UInt64(n))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 500), format: format).image { ctx in
            let colors = [UIColor(hue: CGFloat(n) / 6, saturation: 0.5, brightness: 0.9, alpha: 1).cgColor,
                          UIColor(hue: CGFloat(n) / 6 + 0.3, saturation: 0.6, brightness: 0.4, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 800, y: 500), options: [])
            for _ in 0..<300 {
                UIColor(hue: CGFloat(rng.next() % 100) / 100, saturation: 0.6, brightness: 0.8, alpha: 0.5).setFill()
                ctx.fill(CGRect(x: CGFloat(rng.next() % 800), y: CGFloat(rng.next() % 500),
                                width: CGFloat(5 + rng.next() % 60), height: CGFloat(5 + rng.next() % 60)))
            }
        }
        return img.jpegData(compressionQuality: 0.8).flatMap(UIImage.init(data:)) ?? img
    }
}

/// Erfundene Handschrift mit festem Startwert.
enum Handschrift {
    /// `count` Striche in Zeilen (20 je Zeile, Abstand 45 pt), je Strich 14 bis 24 Punkte als Welle wie Buchstaben,
    /// Druck schwankt (Breite je Punkt). Meist Stift, jeder 9. Bleistift, jeder 15. Textmarker. Erstellzeiten
    /// eindeutig je Seite und Strich (Strich-Identitaet in StrokeConverter).
    static func page(_ index: Int, strokes count: Int) -> PKDrawing {
        var rng = SplitMix64(seed: 0xC0FF_EE00 &+ UInt64(index))
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(count)
        for s in 0..<count {
            let line = s / 20, col = s % 20
            let x0 = 30 + CGFloat(col) * 27 + CGFloat(rng.next() % 5)
            let y0 = 70 + CGFloat(line % 16) * 45 + CGFloat(rng.next() % 7)
            let n = 14 + Int(rng.next() % 11)
            let phase = CGFloat(rng.next() % 628) / 100
            var pts: [PKStrokePoint] = []
            pts.reserveCapacity(n)
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n - 1)
                let force = 0.6 + CGFloat(rng.next() % 50) / 100
                pts.append(PKStrokePoint(location: CGPoint(x: x0 + t * 22, y: y0 + sin(t * .pi * 3 + phase) * 6),
                                         timeOffset: Double(i) * 0.012, size: CGSize(width: 2.4 * force, height: 2.4 * force),
                                         opacity: 1, force: force, azimuth: 0.8, altitude: 1.1))
            }
            let ink: PKInk
            if s % 15 == 14 { ink = PKInk(.marker, color: .systemYellow) }
            else if s % 9 == 8 { ink = PKInk(.pencil, color: .darkGray) }
            else { ink = PKInk(.pen, color: s % 4 == 3 ? .systemBlue : .black) }
            let created = Date(timeIntervalSinceReferenceDate: 790_000_000 + Double(index) * 60 + Double(s) * 0.05)
            strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: created)))
        }
        return PKDrawing(strokes: strokes)
    }

    /// Ein weiterer Strich (eigene Erstellzeit) am unteren Rand.
    static func extraStroke(_ n: Int) -> PKStroke {
        line(from: CGPoint(x: 40 + CGFloat(n % 10) * 50, y: 800), to: CGPoint(x: 80 + CGFloat(n % 10) * 50, y: 806),
             created: Date(timeIntervalSinceReferenceDate: 795_000_000 + Double(n)))
    }

    /// Gerader Strich (Stift, schwarz, Breite 2,5) mit 40 Punkten.
    /// Kreis aus einem Strich (Kanten in jeder Richtung)
    static func circle(center c: CGPoint, radius r: CGFloat, color: UIColor = .black, created: Date = Date()) -> PKStroke {
        let pts = (0...72).map { i -> PKStrokePoint in
            let a = CGFloat(i) / 72 * 2 * .pi
            return PKStrokePoint(location: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: pts, creationDate: created))
    }

    static func line(from a: CGPoint, to b: CGPoint, created: Date = Date()) -> PKStroke {
        let pts = (0..<40).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 39
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: created))
    }
}

/// Bild des Fensters und Kantenmessung.
@MainActor
enum Bild {
    /// Bezug: `drawing` von PencilKit als Vektor gezeichnet, Ausschnitt `rect` (Seitenpunkte) auf weissem Grund
    static func vector(_ drawing: PKDrawing, rect: CGRect, pixelsPerPoint: CGFloat) -> CGImage {
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: pixelsPerPoint)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = pixelsPerPoint
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }.cgImage!
    }

    /// Bild des Fensters, wie es auf dem Bildschirm steht (drawHierarchy erfasst auch die Kacheln von PencilKit).
    static func snapshot(_ window: UIWindow) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.cgImage
    }

    /// Ebenen unter einer Canvas (Anzahl, groesster contentsScale, Klassen): zeigt, ob PencilKit beim Zoomen mit
    /// hoeherer Aufloesung zeichnet. Nur Hinweis, die Ebenen sind nicht Teil der Schnittstelle von PencilKit.
    static func layerInfo(_ view: UIView) -> String {
        var count = 0, maxScale: CGFloat = 0
        var classes = Set<String>()
        func walk(_ l: CALayer) {
            count += 1
            maxScale = max(maxScale, l.contentsScale)
            classes.insert(String(describing: type(of: l)))
            l.sublayers?.forEach(walk)
        }
        walk(view.layer)
        return "\(count) Ebenen, contentsScale bis \(String(format: "%.2f", maxScale)), " + classes.sorted().joined(separator: " ")
    }

    struct Grays {
        var gray: Int
        var dark: Int
        /// Graustufen-Pixel (Helligkeit 10 bis 90 %) je dunklem Pixel: ein vergroessertes Bild hat breitere, treppige
        /// Uebergaenge und damit mehr Graustufen am Rand
        var ratio: Double { dark > 0 ? Double(gray) / Double(dark) : .infinity }
    }

    /// Umriss der blauen Pixel (Blau deutlich ueber Rot und Gruen, auch Kantenpixel) in Punkten des Bildes; nil ohne Blau
    /// Abstand der Mitte des blauen Kreises (Tinte) von der Mitte des roten Punkts (PDF): Pixel und Seitenpunkte (Massstab
    /// aus der Breite des Kreises, `ringDiameter` in Seitenpunkten)
    static func markOffset(_ image: CGImage, scale: CGFloat, in rect: CGRect, ringDiameter: CGFloat) -> (dx: Double, dy: Double, points: Double)? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bx0 = w, by0 = h, bx1 = -1, by1 = -1
        var rx = 0.0, ry = 0.0, rw = 0.0
        for y in max(0, Int(rect.minY * scale))..<min(h, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(w, Int(rect.maxX * scale)) {
                let i = (y * w + x) * 4
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                if b - max(r, g) > 60 { bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y) }
                let red = Double(r - max(g, b))
                if red > 40 { rx += Double(x) * red; ry += Double(y) * red; rw += red }
            }
        }
        guard bx1 > bx0, by1 > by0, rw > 0 else { return nil }
        let dx = (Double(bx0 + bx1) / 2) - rx / rw, dy = (Double(by0 + by1) / 2) - ry / rw
        let perPoint = Double(bx1 - bx0 + 1) / Double(ringDiameter)
        return (dx, dy, (dx * dx + dy * dy).squareRoot() / perPoint)
    }

    static func blueBox(_ image: CGImage, scale: CGFloat, in rect: CGRect) -> CGRect? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        let ys = max(0, Int(rect.minY * scale))..<min(h, Int(rect.maxY * scale))
        let xs = max(0, Int(rect.minX * scale))..<min(w, Int(rect.maxX * scale))
        for y in ys {
            for x in xs {
                let i = (y * w + x) * 4
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                if b - max(r, g) > 60 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
        }
        guard x1 >= x0, y1 >= y0 else { return nil }
        return CGRect(x: CGFloat(x0) / scale, y: CGFloat(y0) / scale, width: CGFloat(x1 - x0 + 1) / scale, height: CGFloat(y1 - y0 + 1) / scale)
    }

    /// Graustufen- und dunkle Pixel in `rect` (Punkte des Bildes)
    static func grays(_ image: CGImage, scale: CGFloat, rect: CGRect) -> Grays? {
        guard !rect.isNull, rect.width > 4, rect.height > 4 else { return nil }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = Grays(gray: 0, dark: 0)
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(w - 1, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(h - 1, Int(rect.maxY * scale))
        guard x1 > x0, y1 > y0 else { return nil }
        for y in y0...y1 {
            for x in x0...x1 {
                let i = (y * w + x) * 4
                let l = (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255
                if l < 0.5 { out.dark += 1 }
                if l > 0.1 && l < 0.9 { out.gray += 1 }
            }
        }
        return out
    }

    /// Kanten einer waagrechten dunklen Linie in `rect` (Fensterpunkte): in 15 Spalten die laengste dunkle Folge
    /// (Helligkeit < 50 %) suchen und darueber und darunter die Pixel zwischen 15 und 85 % zaehlen. Median.
    static func edge(_ image: CGImage, scale: CGFloat, rect: CGRect) -> EditorScaleTests.Edge? {
        guard !rect.isNull, rect.width > 4, rect.height > 4 else { return nil }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lum(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255
        }
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(h - 1, Int(rect.maxY * scale))
        var edges: [Double] = [], thick: [Double] = []
        for k in 0..<15 {
            let x = Int((rect.minX + rect.width * (0.15 + 0.7 * CGFloat(k) / 14)) * scale)
            guard x >= 0, x < w, y1 > y0 else { continue }
            var best = (start: -1, len: 0), run = (start: -1, len: 0)
            for y in y0...y1 {
                if lum(x, y) < 0.5 {
                    run = run.start < 0 ? (y, 1) : (run.start, run.len + 1)
                    if run.len > best.len { best = run }
                } else { run = (-1, 0) }
            }
            guard best.len > 0 else { continue }
            var top = 0, y = best.start - 1
            while y >= y0, (0.15...0.85).contains(lum(x, y)) { top += 1; y -= 1 }
            var bottom = 0
            y = best.start + best.len
            while y <= y1, (0.15...0.85).contains(lum(x, y)) { bottom += 1; y += 1 }
            edges.append(Double(top + bottom) / 2)
            thick.append(Double(best.len))
        }
        guard !edges.isEmpty else { return nil }
        return EditorScaleTests.Edge(edge: edges.sorted()[edges.count / 2], thickness: thick.sorted()[thick.count / 2])
    }
}
