import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Schriftbild (Auftrag des Inhabers 17.11.2026: "Schrift wirklich dünner und feiner machen und auch diese
/// Füller-Schriftart hinzufügen und Marker besser machen"): die feinen Fineliner-Stufen und der Fueller gehoeren fest
/// zur Leiste, der Textmarker laesst den Text lesbar. Alles wirkt schon waehrend des Strichs - nach einem normalen
/// Strich setzt das Programm die Zeichnung in keiner Werkzeugart neu.
extension EditorStrichBleibtTests {
    private func frischeWerkzeuge() throws -> (EditorToolState, UserDefaults) {
        let suite = "uniflow.tests.schriftbild.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (EditorToolState(defaults: defaults), defaults)
    }

    /// Stufen, Grenzen und der Fueller als Werkzeug wie die anderen Stifte (ohne Editor)
    func testFeineStufenUndFuellerGehoerenFestDazu() throws {
        typealias T = EditorToolState.Tool
        XCTAssertEqual(T.canvasTools, [.pen, .fineliner, .fountain, .marker, .eraser, .lasso], "Fueller neben Stift und Fineliner")
        XCTAssertEqual(T.fineliner.widths, [0.25, 0.35, 0.5, 0.8, 1.5, 2.5, 4], "zwei feinere Stufen, die bisherigen bleiben")
        XCTAssertEqual(T.pen.widths, [0.88, 2, 3.5, 6, 10], "Stift unveraendert")
        XCTAssertEqual(T.marker.widths, [7.5, 10, 15, 22, 30], "Textmarker unveraendert")
        XCTAssertEqual(T.pen.inkType, .pen, "der Stift bleibt Stift")
        XCTAssertEqual(T.fountain.inkType, .fountainPen)
        XCTAssertEqual(T.fountain.widths, [1, 1.5, 2.5, 4, 6.5], "fein beginnend")
        XCTAssertEqual(T.fountain.title, "Füller")
        XCTAssertNotNil(UIImage(systemName: T.fountain.icon))
        XCTAssertNotEqual(T.fountain.icon, T.pen.icon)
        XCTAssertTrue(T.fountain.isInk && T.fountain.isPen && T.fountain.drawsOnCanvas && T.fountain.hasColor)
        XCTAssertEqual(EditorToolState.colors(for: .fountain).map(\.hex), EditorToolState.inkColors.map(\.hex))
        XCTAssertFalse(PenSettingsText.character(.fountain).isEmpty)

        // Grenzen: Fineliner bis 0,18, Fueller ab 1 (beides unter dem, was PencilKit meldet)
        XCTAssertEqual(EditorToolState.widthLimits(.fineliner).lowerBound, 0.18, accuracy: 0.001)
        XCTAssertEqual(EditorToolState.sliderRange(.fineliner), 0.18...4)
        XCTAssertEqual(EditorToolState.sliderRange(.fountain), 1...14)
        XCTAssertEqual(EditorToolState.widthLimits(.pen).lowerBound, 0.88, accuracy: 0.001)
        XCTAssertEqual(EditorToolState.widthLimits(.marker).lowerBound, 7.5, accuracy: 0.001)
        for t in [T.pen, .fineliner, .fountain, .marker] {
            let r = EditorToolState.widthLimits(t)
            for w in t.widths { XCTAssertTrue(r.contains(w), "\(t.title) \(w) ausserhalb \(r)") }
            XCTAssertEqual(t.widths, t.widths.sorted(), t.title)
            XCTAssertEqual(Set(t.widths).count, t.widths.count, t.title)
        }
        // "−"/"+" unter 0,5 in Schritten von 0,05
        XCTAssertEqual(EditorToolState.steppedWidth(0.25, up: false, for: .fineliner), 0.2, accuracy: 0.001)
        XCTAssertEqual(EditorToolState.steppedWidth(0.2, up: false, for: .fineliner), 0.18, accuracy: 0.001, "unten bleibt")
        XCTAssertEqual(EditorToolState.steppedWidth(0.35, up: true, for: .fineliner), 0.4, accuracy: 0.001)
        XCTAssertEqual(EditorToolState.steppedWidth(1, up: false, for: .fountain), 1, "unten bleibt")
        // die Auswahl zeigt die feinen Stufen verschieden hoch
        let heights = T.fineliner.widths.map { EditorToolAttributes.lineHeight($0, tool: .fineliner) }
        XCTAssertEqual(Set(heights).count, heights.count, "\(heights)")

        let (tools, defaults) = try frischeWerkzeuge()
        tools.setWidth(0.25, for: .fineliner)
        XCTAssertEqual(tools.inkingTool(.fineliner)?.width ?? 0, 0.25, accuracy: 0.001, "die feine Stufe geht bis an die Tinte")
        tools.setWidth(0.05, for: .fineliner)
        XCTAssertEqual(tools.style(.fineliner).width, 0.18, accuracy: 0.001, "nie duenner als die Grenze")
        tools.setWidth(0.3, for: .pen)
        XCTAssertEqual(tools.style(.pen).width, 0.88, accuracy: 0.001, "der Stift bleibt an seiner Grenze")

        // Fueller: Vorgabe, Farbe, Staerke, Deckkraft, eigener Stift, gemerkt je Geraet
        let fresh = try XCTUnwrap(tools.inkingTool(.fountain))
        XCTAssertEqual(fresh.inkType, .fountainPen)
        XCTAssertEqual(fresh.width, 2.5, accuracy: 0.001)
        XCTAssertTrue(T.fountain.widths.contains(tools.style(.fountain).width), "Vorgabe ist eine Stufe")
        tools.select(.fountain)
        XCTAssertEqual(tools.lastInk, .fountain)
        XCTAssertEqual(tools.lastPen, .fountain, "Farbe des Fuellers gilt auch fuer Text und Form")
        XCTAssertEqual((tools.canvasTool as? PKInkingTool)?.inkType, .fountainPen)
        tools.setColor("#2f7fd1", for: .fountain)
        tools.setWidth(1, for: .fountain)
        tools.setOpacity(0.6, for: .fountain)
        let ink = try XCTUnwrap(tools.inkingTool(.fountain))
        var alpha: CGFloat = 0
        ink.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertEqual(alpha, 0.6, accuracy: 0.01)
        XCTAssertEqual(ink.width, 1, accuracy: 0.001)
        let preset = try XCTUnwrap(tools.addPreset(from: .fountain))
        XCTAssertTrue(PenSettingsText.preset(preset).contains("Füller"))
        tools.select(.pen)
        tools.setWidth(4, for: .fountain)
        tools.applyPreset(preset.id)
        XCTAssertEqual(tools.tool, .fountain)
        XCTAssertEqual(tools.style(.fountain).width, 1)
        XCTAssertTrue(tools.isActive(preset))
        tools.resetStyle(.fountain)
        XCTAssertEqual(tools.style(.fountain), EditorToolState.defaultStyle(.fountain))
        let again = EditorToolState(defaults: defaults)
        XCTAssertEqual(again.tool, .fountain, "nach dem Neustart wieder der Fueller")
        XCTAssertEqual(again.presets.first?.toolValue, .fountain)

        // Menue und Tastatur (Mac, iPad mit Tastatur): Cmd-9, die bisherigen Kuerzel bleiben
        XCTAssertEqual(EditorTool.fountain.barTool, .fountain)
        XCTAssertEqual(String(EditorTool.fountain.shortcut.character), "9")
        XCTAssertEqual(EditorTool.allCases.prefix(8).map(\.rawValue), ["pen", "marker", "eraser", "lasso", "text", "sticky", "shape", "select"])
        XCTAssertTrue(EditorTool.fountain.isInk)
        // Apples schwebende Palette: ihr Fueller ist unser Fueller
        XCTAssertEqual(EditorFloatingPalette.tool(for: .fountainPen), .fountain)
        XCTAssertEqual(EditorFloatingPalette.identifier(for: .fountain), "com.apple.ink.fountainpen")
    }

    /// Ein Stand der Leiste von vor dem 17.11. (ohne Fueller) laedt unveraendert; ein Werkzeug, das diese Fassung nicht
    /// kennt, faellt auf den letzten Stift zurueck
    func testAlterUndFremderStandDerLeisteLaden() throws {
        let suite = "uniflow.tests.schriftbild.alt.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        let old = ##"{"tool":"fineliner","lastInk":"fineliner","lastPen":"fineliner","eraser":"object","styles":{"fineliner":{"hex":"#2f7fd1","width":0.8},"marker":{"hex":"#7ee081","width":22}}}"##
        d.set(Data(old.utf8), forKey: "uniflow.toolbar")
        let tools = EditorToolState(defaults: d)
        XCTAssertEqual(tools.tool, .fineliner)
        XCTAssertEqual(tools.style(.fineliner).width, 0.8, "gewaehlte Staerke bleibt")
        XCTAssertEqual(tools.style(.marker).width, 22)
        XCTAssertEqual(tools.style(.pen), EditorToolState.defaultStyle(.pen), "nie angefasst: Vorgabe wie bisher")
        XCTAssertEqual(tools.start, .classic)
        let foreign = ##"{"tool":"kalligrafie","lastInk":"fountain","lastPen":"fountain","eraser":"object","styles":{"kalligrafie":{"hex":"#000000","width":3}}}"##
        d.set(Data(foreign.utf8), forKey: "uniflow.toolbar")
        let later = EditorToolState(defaults: d)
        XCTAssertEqual(later.tool, .fountain, "unbekanntes Werkzeug: der letzte Stift")
    }

    /// Vorgabe fuer neue Nutzer: mit EINER Zeile (`EditorToolState.firstStart`) auf "fein" umzustellen. Wer die App
    /// schon benutzt hat, behaelt alles - auch die nie angefassten Vorgaben von damals.
    func testVorgabeFuerNeueNutzerMitEinerZeile() throws {
        let before = EditorToolState.firstStart
        addTeardownBlock { @MainActor in EditorToolState.firstStart = before }
        XCTAssertEqual(before, .classic, "ausgeliefert: wie bisher, bis der Inhaber am Geraet zustimmt")
        let (classic, _) = try frischeWerkzeuge()
        XCTAssertEqual(classic.tool, .pen)
        XCTAssertEqual(classic.style(.pen).width, 2)
        XCTAssertEqual(classic.style(.fineliner), EditorToolState.Style(hex: "#2f7fd1", width: 1.5))

        EditorToolState.firstStart = .fine
        let (fine, defaults) = try frischeWerkzeuge()
        XCTAssertEqual(fine.tool, .fineliner, "neuer Nutzer beginnt mit dem Fineliner")
        XCTAssertEqual(fine.lastInk, .fineliner)
        XCTAssertEqual(fine.style(.fineliner), EditorToolState.Style(hex: "#1d2130", width: 0.5), "schwarz, 0,5 (gezeichnet 1,0 pt = 0,35 mm)")
        XCTAssertEqual((fine.canvasTool as? PKInkingTool)?.inkType, .monoline)
        XCTAssertEqual((fine.canvasTool as? PKInkingTool)?.width ?? 0, 0.5, accuracy: 0.001)
        fine.select(.marker)                                           // irgendetwas merken
        EditorToolState.firstStart = .classic
        let restarted = EditorToolState(defaults: defaults)
        XCTAssertEqual(restarted.style(.fineliner).width, 0.5, "die Vorgabe des ersten Starts bleibt auf diesem Geraet")
        XCTAssertEqual(restarted.start, .fine)

        // bestehender Nutzer (Stand ohne Angabe): nichts aendert sich, auch wenn die Zeile auf "fein" steht
        EditorToolState.firstStart = .fine
        let suite = "uniflow.tests.schriftbild.bestand.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        d.set(Data(##"{"tool":"pen","lastInk":"pen","lastPen":"pen","eraser":"object","styles":{"pen":{"hex":"#1d2130","width":0.88}}}"##.utf8), forKey: "uniflow.toolbar")
        let existing = EditorToolState(defaults: d)
        XCTAssertEqual(existing.tool, .pen)
        XCTAssertEqual(existing.style(.pen).width, 0.88)
        XCTAssertEqual(existing.style(.fineliner), EditorToolState.Style(hex: "#2f7fd1", width: 1.5), "nie angefasst: wie damals")
    }

    /// Textmarker: ohne eigene Einstellung durchscheinend (50 %), damit der Text darunter lesbar bleibt; wer die
    /// Deckkraft selbst eingestellt hat, behaelt sie
    func testTextmarkerLaesstDenTextLesbar() throws {
        func alpha(_ tool: PKInkingTool?) -> CGFloat {
            var a: CGFloat = 0
            tool?.color.getRed(nil, green: nil, blue: nil, alpha: &a)
            return a
        }
        XCTAssertEqual(EditorToolState.markerDefaultOpacity, 0.5)
        let (tools, defaults) = try frischeWerkzeuge()
        XCTAssertEqual(alpha(tools.inkingTool(.marker)), 0.5, accuracy: 0.01)
        XCTAssertEqual(tools.style(.marker).alpha, 0.5, accuracy: 0.001, "das Einstellungsblatt zeigt 50 %")
        XCTAssertEqual(alpha(tools.inkingTool(.pen)), 1, accuracy: 0.01, "Stifte bleiben deckend")
        XCTAssertEqual(alpha(tools.inkingTool(.fountain)), 1, accuracy: 0.01)
        // nur Farbe gewaehlt (Deckkraft nie eingestellt): weiter 50 %
        tools.setColor(EditorToolState.markerColors[1].hex, for: .marker)
        XCTAssertEqual(alpha(tools.inkingTool(.marker)), 0.5, accuracy: 0.01)
        let preset = try XCTUnwrap(tools.addPreset(from: .marker))
        tools.select(.marker)
        XCTAssertTrue(tools.isActive(preset))
        // selbst eingestellt: bleibt, auch nach dem Neustart
        tools.setOpacity(1, for: .marker)
        XCTAssertEqual(alpha(tools.inkingTool(.marker)), 1, accuracy: 0.01)
        XCTAssertEqual(alpha(EditorToolState(defaults: defaults).inkingTool(.marker)), 1, accuracy: 0.01)
        // Stand von frueher mit Farbe und Staerke, ohne Deckkraft
        let suite = "uniflow.tests.schriftbild.marker.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        d.set(Data(##"{"tool":"marker","lastInk":"marker","lastPen":"pen","eraser":"object","styles":{"marker":{"hex":"#ff9ecb","width":22},"pen":{"hex":"#1d2130","width":2}}}"##.utf8), forKey: "uniflow.toolbar")
        let old = EditorToolState(defaults: d)
        XCTAssertEqual(old.style(.marker).width, 22)
        XCTAssertEqual(old.style(.marker).hex, "#ff9ecb")
        XCTAssertEqual(alpha(old.inkingTool(.marker)), 0.5, accuracy: 0.01, "nie eingestellt: die neue Vorgabe")
        XCTAssertEqual(alpha(old.inkingTool(.pen)), 1, accuracy: 0.01)

        // gemessen: Gelb ueber schwarzem Text - der Text bleibt deutlich dunkler als die Flaeche
        let yellow = UIColor(hex: EditorToolState.markerColors[0].hex) ?? .yellow
        func kontrast(_ a: CGFloat) -> CGFloat {
            let pts = (0...40).map { PKStrokePoint(location: CGPoint(x: 10 + CGFloat($0) * 4, y: 20), timeOffset: Double($0) * 0.008,
                                                   size: CGSize(width: 15, height: 15), opacity: 1, force: 1, azimuth: .pi / 4, altitude: .pi / 2) }
            let stroke = PKStroke(ink: PKInk(.marker, color: yellow.withAlphaComponent(a)), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
            let size = CGSize(width: 180, height: 40)
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent { ink = PKDrawing(strokes: [stroke]).image(from: CGRect(origin: .zero, size: size), scale: 1) }
            // links schwarz (Text), rechts weiss (Papier), der Marker darueber
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 90, height: 40))
                ink.draw(in: CGRect(origin: .zero, size: size))
            }
            func hell(_ x: Int) -> CGFloat {
                var px = [UInt8](repeating: 0, count: 4)
                let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.translateBy(x: -CGFloat(x), y: -19)
                c.draw(image.cgImage!, in: CGRect(origin: .zero, size: size))
                return (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / 255
            }
            return hell(130) - hell(50)                               // Flaeche minus Text darunter
        }
        let full = kontrast(1), half = kontrast(0.5)
        print(String(format: "[Marker] Helligkeit Flaeche minus Text darunter: Deckkraft 100 %% %.2f, 50 %% %.2f (ohne Marker 1,00)", full, half))
        XCTAssertLessThan(full, 0.3, "bei 100 % geht der Text fast unter (Stand bis 17.11.)")
        XCTAssertGreaterThan(half, 0.5, "bei 50 % bleibt der Text klar lesbar")
    }

    /// Unbekannte Tintenart in einem Dokument (neuere App, anderes Geraet): der Strich erscheint als normaler Stift,
    /// nichts scheitert. Ein Fueller-Strich bleibt Fueller - mit dem Speicherformat, das schon die Store-Version 1.0.4
    /// liest und schreibt (`tool` "fountain", `pkInk` der Fueller-Tinte; dort seit Build 42 unveraendert).
    func testFuellerImSpeicherformatUndUnbekannteTinte() throws {
        XCTAssertEqual(StrokeConverter.webTool(for: .fountainPen), "fountain")
        XCTAssertEqual(StrokeConverter.inkType(forWebTool: "fountain", pkInk: PKInk.InkType.fountainPen.rawValue), .fountainPen)
        XCTAssertEqual(StrokeConverter.inkType(forWebTool: "fountain", pkInk: nil), .fountainPen, "im Browser geschriebener Fueller")
        XCTAssertEqual(StrokeConverter.inkType(forWebTool: "pen", pkInk: PKInk.InkType.fountainPen.rawValue), .pen, "im Browser zum Stift gemacht")
        XCTAssertEqual(StrokeConverter.inkType(forWebTool: "kalligrafie", pkInk: "com.apple.ink.reedcalligraphy"), .pen, "unbekannt: Stift")
        XCTAssertEqual(StrokeConverter.inkType(forWebTool: "pen", pkInk: "com.erfunden.tinte"), .pen)
        XCTAssertEqual(StrokeConverter.inkType(forWebTool: "", pkInk: nil), .pen)

        // Hin- und Rueckweg eines Fueller-Strichs mit an- und abschwellender Breite
        let pts = (0...50).map { i -> PKStrokePoint in
            let w = 0.6 + 1.2 * abs(sin(CGFloat(i) / 8))
            return PKStrokePoint(location: CGPoint(x: 30 + CGFloat(i) * 3, y: 60 + sin(CGFloat(i) / 5) * 6), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: w, height: w), opacity: 1, force: 1, azimuth: 0.6, altitude: 1)
        }
        let ink = PKInk(.fountainPen, color: UIColor(hex: "#2f7fd1") ?? .blue)
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 1_970_000_000)))
        let page = StrokeConverter.update(from: PKDrawing(strokes: [stroke]), previous: ["objects": []], state: InkPageState()).page
        let o = try XCTUnwrap(page["objects"]?.array?.first)
        XCTAssertEqual(o["type"]?.string, "stroke")
        XCTAssertEqual(o["tool"]?.string, "fountain", "Werkzeug fuer Browser und Windows")
        XCTAssertEqual(o["pkInk"]?.string, PKInk.InkType.fountainPen.rawValue)
        XCTAssertEqual(o["color"]?.string?.lowercased(), "#2f7fd1")
        XCTAssertNotNil(o["widths"]?.array, "die Breite je Punkt geht mit (Schwellen des Fuellers)")
        // nur aus den Objekten (wie nach einer Aenderung im Browser, wie auf einem Geraet ohne die native Zeichnung)
        var objectsOnly = page.object ?? [:]
        objectsOnly["pkdrawing"] = nil
        let rebuilt = try XCTUnwrap(StrokeConverter.drawing(fromPage: .object(objectsOnly)).0.strokes.first)
        XCTAssertEqual(rebuilt.ink.inkType, .fountainPen, "aus dem JSON wieder Fueller")
        let widths = (0..<rebuilt.path.count).map { rebuilt.path[$0].size.width }
        XCTAssertGreaterThan((widths.max() ?? 0) - (widths.min() ?? 0), 0.5, "schwillt weiter an und ab")
        // mit der nativen Zeichnung (derselbe iPad-Stand)
        let native = try XCTUnwrap(StrokeConverter.drawing(fromPage: page).0.strokes.first)
        XCTAssertEqual(native.ink.inkType, .fountainPen, "mit nativer Zeichnung wieder Fueller")

        // dasselbe Objekt mit einer Tintenart, die diese Fassung nicht kennt: als Stift, mit Farbe und Breite
        var unknown = o.object ?? [:]
        unknown["tool"] = "kalligrafie"
        unknown["pkInk"] = "com.apple.ink.reedcalligraphy"
        let shown = try XCTUnwrap(StrokeConverter.stroke(from: .object(unknown), created: Date()), "unbekannte Tinte wird trotzdem gezeichnet")
        XCTAssertEqual(shown.ink.inkType, .pen)
        XCTAssertEqual(shown.path.count, rebuilt.path.count)
        let (drawing, state) = StrokeConverter.drawing(fromPage: ["objects": [.object(unknown)]])
        XCTAssertEqual(drawing.strokes.count, 1)
        XCTAssertEqual(state.unrenderable, 0)
    }

    /// Echte Striche (Finger) mit jedem Stift: Die feinen Stufen und der Fueller schreiben wirklich so (schon waehrend
    /// des Strichs), das Programm setzt die Zeichnung dabei nie neu, und nach Sichern, Schliessen und Oeffnen ist jeder
    /// Strich mit seiner Tinte und Dicke wieder da. Radierer, Rueckgaengig, Lasso und Lineal gehen mit dem Fueller.
    func testJederStiftSchreibtWirklichSoUndBleibtNachDemOeffnen() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0)
        let canvas = overlay.canvas
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var row = 0
        func schreibe() async throws -> PKStroke {
            let a = overlay.content.convert(CGPoint(x: 100, y: 60 + CGFloat(row) * 30), to: nil)
            row += 1
            var pts: [CGPoint] = []
            for k in 0...40 { pts.append(CGPoint(x: a.x + CGFloat(k) * 5, y: a.y)) }
            let n0 = canvas.drawing.strokes.count
            try await TestFinger.strich(pts, in: shown.window, step: 0.008)
            let until = Uhr.now() + 3
            while Uhr.now() < until, canvas.drawing.strokes.count == n0 { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertEqual(canvas.drawing.strokes.count, n0 + 1, "Strich angenommen")
            return try XCTUnwrap(canvas.drawing.strokes.last)
        }
        let log0 = ZeichnungSpion.log.count
        let faelle: [(EditorToolState.Tool, CGFloat, PKInk.InkType)] = [
            (.fineliner, 0.5, .monoline), (.fineliner, 0.35, .monoline), (.fineliner, 0.25, .monoline), (.fineliner, 0.18, .monoline),
            (.fountain, 1, .fountainPen), (.fountain, 2.5, .fountainPen), (.fountain, 6.5, .fountainPen),
            (.pen, 0.88, .pen), (.marker, 15, .marker),
        ]
        var dick: [CGFloat] = []
        var out: [String] = []
        for (tool, width, ink) in faelle {
            editor.tools.setWidth(width, for: tool)
            editor.tools.select(tool)
            try await Task.sleep(nanoseconds: 150_000_000)
            let onCanvas = try XCTUnwrap(canvas.tool as? PKInkingTool, tool.title)
            XCTAssertEqual(onCanvas.inkType, ink, tool.title)
            XCTAssertEqual(onCanvas.width, width, accuracy: 0.001, "\(tool.title): die Zeichenflaeche hat die Breite \(width)")
            let s = try await schreibe()
            XCTAssertEqual(s.ink.inkType, ink, tool.title)
            let d = tool == .marker ? Self.sichtbareDicke(s) : Self.dicke(s)
            dick.append(d)
            out.append(String(format: "%@ %@: %.2f pt = %.2f mm", tool.title, PenSettingsText.width(width), d, d * 0.3528))
        }
        // Fineliner: jede feinere Stufe wirklich duenner, die feinste noch zu sehen
        XCTAssertLessThan(dick[1], dick[0] * 0.8)
        XCTAssertLessThan(dick[2], dick[1] * 0.8)
        XCTAssertLessThan(dick[2], dick[0] * 0.6, "0,25 schreibt halb so dick wie 0,5")
        XCTAssertLessThan(dick[3], dick[2])
        XCTAssertGreaterThan(dick[3], 0.2, "auch die feinste Breite ist zu sehen")
        // Fueller: fein beginnend, jede Stufe kraeftiger, die feinste duenner als der duennste Stift
        XCTAssertLessThan(dick[4], dick[5])
        XCTAssertLessThan(dick[5], dick[6])
        XCTAssertLessThan(dick[4], dick[7] * 0.5, "Fueller fein ist viel duenner als der duennste Stift")
        // Textmarker: durchscheinend
        var markerAlpha: CGFloat = 0
        canvas.drawing.strokes.last?.ink.color.getRed(nil, green: nil, blue: nil, alpha: &markerAlpha)
        XCTAssertEqual(markerAlpha, 0.5, accuracy: 0.02)

        // Lineal mit dem Fueller: der Strich wird angenommen
        editor.tools.select(.fountain)
        editor.tools.setRuler(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(canvas.isRulerActive)
        let ruled = try await schreibe()
        XCTAssertEqual(ruled.ink.inkType, .fountainPen)
        editor.tools.setRuler(false)
        try await Task.sleep(nanoseconds: 300_000_000)

        // nichts wurde nach dem Absetzen neu gesetzt - in keiner Werkzeugart
        let sets = ZeichnungSpion.log[log0...].filter { $0.canvas == ObjectIdentifier(canvas) && !$0.own }
        XCTAssertEqual(sets.count, 0, "kein Stift setzt die Zeichnung neu")
        let total = faelle.count + 1
        XCTAssertEqual(canvas.drawing.strokes.count, total)
        print("[Strich] Gezeichnete Dicke je Stift und Stufe (Finger, gleichmaessiger Druck):\n  " + out.joined(separator: "\n  ")
              + "\n  vom Programm neu gesetzt: \(sets.count) Mal bei \(total) Strichen")

        // Radierer (ganzer Strich) am Fueller-Strich, Rueckgaengig holt ihn zurueck
        func setze(_ d: PKDrawing) {
            overlay.isApplyingDrawing = true
            ZeichnungSpion.own = true
            canvas.drawing = d
            ZeichnungSpion.own = false
            overlay.isApplyingDrawing = false
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        editor.tools.select(.eraser)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(canvas.tool is PKEraserTool)
        editor.canvasViewDidBeginUsingTool(canvas)
        var erased = canvas.drawing
        erased.strokes.remove(at: 5)                                   // Fueller 2,5
        setze(erased)
        editor.canvasViewDrawingDidChange(canvas)
        editor.canvasViewDidEndUsingTool(canvas)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(canvas.drawing.strokes.count, total - 1)
        editor.undo()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(canvas.drawing.strokes.count, total, "Rueckgaengig nach dem Radieren")
        XCTAssertEqual(canvas.drawing.strokes.filter { $0.ink.inkType == .fountainPen }.count, 4)
        // Lasso verschiebt einen Fueller-Strich, Rueckgaengig stellt ihn zurueck
        let index = try XCTUnwrap(canvas.drawing.strokes.firstIndex { $0.ink.inkType == .fountainPen })
        var moved = canvas.drawing
        moved.strokes[index].transform = CGAffineTransform(translationX: 24, y: 8)
        editor.replaceInk(key: overlay.pageKey, before: canvas.drawing, after: moved)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(canvas.drawing.strokes[index].transform.tx, 24)
        XCTAssertEqual(canvas.drawing.strokes[index].ink.inkType, .fountainPen)
        editor.undo()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(canvas.drawing.strokes[index].transform.tx, 0, "Lasso rueckgaengig")

        // sichern: im Speicherformat steht der Fueller, wie ihn Browser, Windows und die Store-Version lesen
        let vorher = canvas.drawing.strokes
        await store.flush()
        let saved = await store.objects(forPageKey: "p1").filter { $0["type"]?.string == "stroke" }
        XCTAssertEqual(saved.count, total)
        XCTAssertEqual(saved.filter { $0["tool"]?.string == "fountain" }.count, 4)
        XCTAssertEqual(saved.filter { $0["pkInk"]?.string == PKInk.InkType.fountainPen.rawValue }.count, 4)
        XCTAssertEqual(saved.filter { $0["pkInk"]?.string == PKInk.InkType.monoline.rawValue }.count, 4)
        XCTAssertEqual(saved.filter { $0["tool"]?.string == "marker" }.count, 1)
        await store.close()
        hide(shown)

        // schliessen und oeffnen: jeder Strich mit seiner Tinte und Dicke
        let again = try await openStore(fx)
        let reloaded = await again.drawing(forPageKey: "p1")
        XCTAssertEqual(reloaded.strokes.count, total)
        if reloaded.strokes.count == total {
            for (i, s) in reloaded.strokes.enumerated() {
                if vorher[i].ink.inkType == .monoline {
                    // Befund 14.11.2026 (docs/STIFT-EINSTELLUNGEN-2026-11-14.md), unveraendert: PencilKits eigenes
                    // Speicherformat liefert einen Fineliner-Strich als Stift zurueck - gleich dick (unten geprueft),
                    // im JSON steht der Fineliner. Bewusst nicht angefasst (vorhandene Notizen bleiben, wie sie sind).
                    XCTAssertTrue([PKInk.InkType.monoline, .pen].contains(s.ink.inkType), "Strich \(i + 1)")
                } else {
                    XCTAssertEqual(s.ink.inkType, vorher[i].ink.inkType, "Strich \(i + 1): Tinte nach dem Oeffnen")
                }
                if s.ink.inkType != .marker {
                    XCTAssertEqual(Self.dicke(s), Self.dicke(vorher[i]), accuracy: 0.06, "Strich \(i + 1): Dicke nach dem Oeffnen")
                }
            }
        }
        // und nur aus den Objekten (anderes Geraet ohne die native Zeichnung, nach einer Aenderung im Browser)
        let objects = await again.objects(forPageKey: "p1")
        let rebuilt = StrokeConverter.drawing(fromPage: ["objects": .array(objects)]).0
        XCTAssertEqual(rebuilt.strokes.map { $0.ink.inkType }, vorher.map { $0.ink.inkType }, "aus dem JSON: jede Tinte wieder da")
        await again.close()
    }
}
