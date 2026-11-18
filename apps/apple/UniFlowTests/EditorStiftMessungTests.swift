import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Messungen fuer "Schrift wirklich duenner und feiner", "Fueller" und "Marker besser" (Auftrag des Inhabers 17.11.2026).
/// Echte Striche (Finger im Simulator, gleichmaessiger Druck) mit jeder Tinte und Breite; ausgegeben wird, welche Breite
/// PencilKit annimmt und wie dick es wirklich zeichnet. Zeilen "[Messung]" im Testprotokoll; Bilder mit
/// `TEST_RUNNER_UF_STIFT_BILDER=<Ordner>`.
extension EditorStrichBleibtTests {
    static var bilderOrdner: String? {
        let d = ProcessInfo.processInfo.environment["UF_STIFT_BILDER"]
        return (d ?? "").isEmpty ? nil : d
    }

    static func sichere(_ image: UIImage, _ name: String) {
        guard let dir = bilderOrdner, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// Dicke eines Strichs quer zu seiner Richtung in Seitenpunkten: Pixel mit Tinte (ueber einem Zehntel der staerksten
    /// Deckung) in fuenf Schnitten, Median. Zaehlt die sichtbare Breite - auch bei durchscheinender Tinte (Textmarker).
    static func sichtbareDicke(_ stroke: PKStroke, senkrecht: Bool = false) -> CGFloat {
        let rect = stroke.renderBounds.insetBy(dx: -3, dy: -3)
        let scale: CGFloat = 16
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: [stroke]).image(from: rect, scale: scale)
        }
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var peak: UInt8 = 0
        for i in stride(from: 3, to: px.count, by: 4) where px[i] > peak { peak = px[i] }
        let limit = max(4, Int(peak) / 10)
        var runs: [CGFloat] = []
        for k in 1...5 {
            var n = 0
            if senkrecht {
                let y = h * (k + 1) / 8
                for x in 0..<w where Int(px[(y * w + x) * 4 + 3]) > limit { n += 1 }
            } else {
                let x = w * (k + 1) / 8
                for y in 0..<h where Int(px[(y * w + x) * 4 + 3]) > limit { n += 1 }
            }
            runs.append(CGFloat(n) / scale)
        }
        return runs.sorted()[2]
    }

    /// Welche Breiten nimmt PencilKit je Tinte an, wie dick zeichnet es: Fineliner unter 0,5, Fueller in allen Stufen,
    /// Textmarker waagerecht und senkrecht
    func testMessungFeinerFuellerMarker() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0)
        let canvas = overlay.canvas
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var out: [String] = []
        for (name, type) in [("Fineliner", PKInkingTool.InkType.monoline), ("Fueller", .fountainPen), ("Textmarker", .marker), ("Stift", .pen)] {
            let r = type.validWidthRange
            out.append(String(format: "%@: PencilKit meldet %.4f bis %.2f, Vorgabe %.2f", name, r.lowerBound, r.upperBound, type.defaultWidth))
        }
        var row = 0
        func schreibe(_ tool: PKInkingTool, senkrecht: Bool = false) async throws -> PKStroke? {
            canvas.tool = tool
            var pts: [CGPoint] = []
            if senkrecht {
                let a = overlay.content.convert(CGPoint(x: 330 + CGFloat(row % 12) * 20, y: 60), to: nil)
                for k in 0...30 { pts.append(CGPoint(x: a.x, y: a.y + CGFloat(k) * 5)) }
            } else {
                let a = overlay.content.convert(CGPoint(x: 60, y: 40 + CGFloat(row % 20) * 34), to: nil)
                for k in 0...40 { pts.append(CGPoint(x: a.x + CGFloat(k) * 5, y: a.y)) }
            }
            row += 1
            let n0 = canvas.drawing.strokes.count
            try await TestFinger.strich(pts, in: shown.window, step: 0.008)
            let until = Uhr.now() + 3
            while Uhr.now() < until, canvas.drawing.strokes.count == n0 { try await Task.sleep(nanoseconds: 20_000_000) }
            guard canvas.drawing.strokes.count == n0 + 1 else { return nil }
            return canvas.drawing.strokes.last
        }
        func leere() async throws {
            overlay.isApplyingDrawing = true
            ZeichnungSpion.own = true
            canvas.drawing = PKDrawing()
            ZeichnungSpion.own = false
            overlay.isApplyingDrawing = false
            row = 0
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        let faelle: [(String, PKInkingTool.InkType, [CGFloat])] = [
            ("Fineliner", .monoline, [0.5, 0.35, 0.25, 0.2, 0.18, 0.15, 0.1]),
            ("Fueller", .fountainPen, [0.5, 0.75, 1, 1.5, 2, 3, 4.5, 7, 10, 15]),
            ("Stift", .pen, [0.88, 2]),
            ("Textmarker", .marker, [3, 5, 7.5, 10, 12, 15, 18, 22, 30]),
        ]
        for (name, type, widths) in faelle {
            try await leere()
            for w in widths {
                let tool = PKInkingTool(type, color: type == .marker ? UIColor(red: 1, green: 0.9, blue: 0.2, alpha: 1) : .black, width: w)
                guard let s = try await schreibe(tool) else { out.append("\(name) \(w): kein Strich"); continue }
                let sizes = (0..<s.path.count).map { s.path[$0].size.width }
                let heights = (0..<s.path.count).map { s.path[$0].size.height }
                let az = s.path.count > 0 ? s.path[s.path.count / 2].azimuth : 0
                var line = String(format: "%@ verlangt %.2f: Werkzeug nimmt %.2f an; Punktgroessen %.2f bis %.2f (Hoehe %.2f bis %.2f, Azimut %.2f); gezeichnet %.2f pt = %.2f mm (sichtbar %.2f pt)",
                                  name, w, (canvas.tool as? PKInkingTool)?.width ?? -1, sizes.min() ?? 0, sizes.max() ?? 0,
                                  heights.min() ?? 0, heights.max() ?? 0, az, Self.dicke(s), Self.dicke(s) * 0.3528, Self.sichtbareDicke(s))
                if type == .marker, let v = try await schreibe(tool, senkrecht: true) {
                    line += String(format: "; senkrecht gezogen sichtbar %.2f pt", Self.sichtbareDicke(v, senkrecht: true))
                }
                out.append(line)
            }
        }
        print("[Messung] Breiten je Tinte (Finger, gleichmaessiger Druck; 1 pt = 0,353 mm):\n  " + out.joined(separator: "\n  "))
        await store.close()
    }

    /// Textmarker ueber gedrucktem Text: Farbe der Flaeche und des Textes darunter, einmal und zweimal uebermalt, je
    /// Deckkraft; dazu dieselbe Flaeche mit einem Strich, der sich selbst kreuzt. Bild zum Ansehen.
    func testMessungTextmarkerUeberText() throws {
        let size = CGSize(width: 520, height: 300)
        let colors: [(String, String)] = EditorToolState.markerColors.map { ($0.name, $0.hex) }
        var out: [String] = []
        func strich(_ y: CGFloat, from x0: CGFloat = 30, to x1: CGFloat = 250, width: CGFloat, color: UIColor, azimuth: CGFloat = .pi / 4,
                    ink: PKInk.InkType = .marker, at t: TimeInterval = 0) -> PKStroke {
            let n = Int((x1 - x0) / 4)
            let pts = (0...n).map { PKStrokePoint(location: CGPoint(x: x0 + CGFloat($0) * 4, y: y), timeOffset: Double($0) * 0.008,
                                                  size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: azimuth, altitude: .pi / 2) }
            return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 1_900_000_000 + t)))
        }
        func bild(_ strokes: [PKStroke], text: String) -> UIImage {
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = PKDrawing(strokes: strokes).image(from: CGRect(origin: .zero, size: size), scale: 2)
            }
            let f = UIGraphicsImageRendererFormat()
            f.scale = 2
            return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                for (i, line) in text.split(separator: "\n").enumerated() {
                    for x in [34, 284] as [CGFloat] {
                        String(line).draw(at: CGPoint(x: x, y: 20 + CGFloat(i) * 40 - 7), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black])
                    }
                }
                ink.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        func farbe(_ image: UIImage, _ p: CGPoint) -> (Int, Int, Int) {
            guard let cg = image.cgImage else { return (0, 0, 0) }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: -p.x * 2, y: -(CGFloat(cg.height) - p.y * 2 - 1))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
        /// dunkelster Punkt in einem Feld (der Text unter dem Marker)
        func dunkelstes(_ image: UIImage, _ r: CGRect) -> (Int, Int, Int) {
            var best = (255, 255, 255)
            var y = r.minY
            while y < r.maxY {
                var x = r.minX
                while x < r.maxX {
                    let c = farbe(image, CGPoint(x: x, y: y))
                    if c.0 + c.1 + c.2 < best.0 + best.1 + best.2 { best = c }
                    x += 0.5
                }
                y += 0.5
            }
            return best
        }
        let text = "Signale und Systeme: Faltung\nSignale und Systeme: Faltung\nSignale und Systeme: Faltung\nSignale und Systeme: Faltung\nSignale und Systeme: Faltung\nSignale und Systeme: Faltung\nSignale und Systeme: Faltung"
        for (name, hex) in colors {
            let base = UIColor(hex: hex) ?? .yellow
            var strokes: [PKStroke] = []
            let alphas: [CGFloat] = [1, 0.7, 0.5]
            for (i, a) in alphas.enumerated() {
                let y = 20 + CGFloat(i) * 40
                strokes.append(strich(y, width: 15, color: base.withAlphaComponent(a), at: Double(i)))
                // rechts: zweimal uebermalt
                strokes.append(strich(y, from: 280, to: 490, width: 15, color: base.withAlphaComponent(a), at: 10 + Double(i)))
                strokes.append(strich(y, from: 280, to: 490, width: 15, color: base.withAlphaComponent(a), at: 20 + Double(i)))
            }
            // Zeile 4: Azimut 0 (Finger) und pi/2; Zeile 5: Stift-Tinte halbdurchsichtig, Zeile 6: Wasserfarbe, Zeile 7: Kreide
            strokes.append(strich(140, width: 15, color: base, azimuth: 0, at: 30))
            strokes.append(strich(140, from: 280, to: 490, width: 15, color: base, azimuth: .pi / 2, at: 31))
            strokes.append(strich(180, width: 15, color: base.withAlphaComponent(0.4), ink: .pen, at: 32))
            strokes.append(strich(180, from: 280, to: 490, width: 15, color: base.withAlphaComponent(0.4), ink: .pen, at: 33))
            strokes.append(strich(180, from: 280, to: 490, width: 15, color: base.withAlphaComponent(0.4), ink: .pen, at: 34))
            strokes.append(strich(220, width: 15, color: base, ink: .watercolor, at: 35))
            strokes.append(strich(260, width: 15, color: base, ink: .crayon, at: 36))
            let image = bild(strokes, text: text)
            Self.sichere(image, "marker-ueber-text-\(name)")
            for (i, a) in alphas.enumerated() {
                let y = 20 + CGFloat(i) * 40
                let fl1 = farbe(image, CGPoint(x: 240, y: y)), fl2 = farbe(image, CGPoint(x: 485, y: y))
                let t1 = dunkelstes(image, CGRect(x: 36, y: y - 5, width: 30, height: 10)), t2 = dunkelstes(image, CGRect(x: 286, y: y - 5, width: 30, height: 10))
                out.append("\(name) \(hex), Deckkraft \(Int(a * 100)) %: Flaeche einmal \(fl1), zweimal \(fl2); Text darunter einmal \(t1), zweimal \(t2)")
            }
            let pen1 = farbe(image, CGPoint(x: 240, y: 180)), pen2 = farbe(image, CGPoint(x: 485, y: 180))
            out.append("\(name): Stift-Tinte 40 % einmal \(pen1), zweimal \(pen2); Wasserfarbe \(farbe(image, CGPoint(x: 240, y: 220))); Kreide \(farbe(image, CGPoint(x: 240, y: 260)))")
        }
        // Dicke je Azimut (Keilspitze): waagerechter Strich, Breite 15
        let azimute: [CGFloat] = [0, 0.39, 0.79, 1.18, 1.57, 2.36, 3.14]
        for az in azimute {
            let s = strich(100, width: 15, color: .yellow, azimuth: az)
            out.append(String(format: "Marker Breite 15, Azimut %.2f: waagerecht sichtbar %.1f pt dick", az, Self.sichtbareDicke(s)))
        }
        print("[Messung] Textmarker ueber Text (Farbe als Rot, Gruen, Blau; Papier 255, 255, 255; Text 0, 0, 0):\n  " + out.joined(separator: "\n  "))
    }

    /// Vergleichsbild fuer den Inhaber: dieselbe Schriftzeile in jeder Stufe von Stift, Fineliner und Fueller - einmal
    /// bei 100 % Zoom (1 Seitenpunkt = 2 Bildpunkte des iPad) und einmal bei Seitenbreite hochkant (138 %). Dazu, wie
    /// kraeftig die duennsten Fineliner-Stufen noch sind (dunkelster Bildpunkt; 0 = schwarz, 255 = Papier).
    func testVergleichsbildSchriftJeStufe() throws {
        func zeile(_ row: Int, ink: PKInk.InkType, size: CGFloat, druck: Bool) -> [PKStroke] {
            let base = Handschrift.page(7, strokes: 16)
            return base.strokes.enumerated().map { i, s in
                let pts = (0..<s.path.count).map { k -> PKStrokePoint in
                    let p = s.path[k]
                    let w = druck ? 2 + (size - 2) * (1 + 2 * (p.force - 0.6)) : size       // Fueller: mit dem Druck bis doppelt so kraeftig
                    return PKStrokePoint(location: CGPoint(x: p.location.x * 0.8 + 150, y: 22 + CGFloat(row) * 26 + (p.location.y - 73) * 0.8),
                                         timeOffset: p.timeOffset, size: CGSize(width: w, height: w), opacity: 1, force: p.force, azimuth: p.azimuth, altitude: p.altitude)
                }
                return PKStroke(ink: PKInk(ink, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 1_980_000_000 + Double(row * 100 + i))))
            }
        }
        // Punktgroessen wie PencilKit sie beim Schreiben anlegt (gemessen): Fineliner 2 + Breite, Fueller 2 + 0,64 x Breite,
        // Stift rund 3,1
        var rows: [(String, PKInk.InkType, CGFloat, Bool)] = []
        rows.append(("Stift 0,88", .pen, 3.08, false))
        rows.append(("Stift 2", .pen, 3.14, false))
        for w in [0.18] + EditorToolState.Tool.fineliner.widths { rows.append(("Fineliner \(PenSettingsText.width(w))", .monoline, 2 + w, false)) }
        for w in EditorToolState.Tool.fountain.widths { rows.append(("Füller \(PenSettingsText.width(w))", .fountainPen, 2 + 0.64 * w, true)) }
        var strokes: [PKStroke] = []
        for (r, row) in rows.enumerated() { strokes += zeile(r, ink: row.1, size: row.2, druck: row.3) }
        let size = CGSize(width: 620, height: CGFloat(rows.count) * 26 + 20)
        var out: [String] = []
        for (name, scale) in [("100", 2.0), ("seitenbreite-138", 2.76)] as [(String, CGFloat)] {
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = PKDrawing(strokes: strokes).image(from: CGRect(origin: .zero, size: size), scale: scale)
            }
            let f = UIGraphicsImageRendererFormat()
            f.scale = scale
            let image = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                for (r, row) in rows.enumerated() {
                    row.0.draw(at: CGPoint(x: 12, y: 15 + CGFloat(r) * 26), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray])
                }
                ink.draw(in: CGRect(origin: .zero, size: size))
            }
            Self.sichere(image, "schrift-je-stufe-zoom-\(name)")
            // dunkelster Bildpunkt je Zeile (wie kraeftig der Strich noch ist)
            guard let cg = image.cgImage else { continue }
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            for (r, row) in rows.enumerated() {
                var sum = 0, n = 0, darkest = 255
                let y0 = Int((10 + CGFloat(r) * 26) * scale), y1 = Int((34 + CGFloat(r) * 26) * scale)
                for y in y0..<min(h, y1) {
                    for x in Int(170 * scale)..<min(w, Int(600 * scale)) {
                        let v = Int(px[(y * w + x) * 4 + 1])
                        if v < 200 { sum += v; n += 1 }
                        darkest = min(darkest, v)
                    }
                }
                out.append("Zoom \(name): \(row.0): dunkelster Bildpunkt \(darkest), mittlere Helligkeit der Tinte \(n > 0 ? sum / n : 255)")
            }
        }
        print("[Messung] Schrift je Stufe (0 = schwarz, 255 = Papier):\n  " + out.joined(separator: "\n  "))
    }

    /// Bild fuer den Inhaber (echter Editor, echte Zeichenflaeche von PencilKit ueber der PDF-Seite): Textzeilen einer
    /// PDF markiert - wie bis 17.11. (100 %) und jetzt (50 %), je einmal und zweimal uebermalt, dazu die vier Farben.
    /// Der Test legt `bereit-hell` bzw. `bereit-dunkel` in den Ordner `UF_MARKER_BEREIT` und haelt das Fenster je 9 s
    /// offen; das Foto macht `xcrun simctl io … screenshot` (das Bild des Fensters zeigt die Tinte von PencilKit nicht).
    func testBildTextmarkerUeberPDFText() async throws {
        guard let dir = ProcessInfo.processInfo.environment["UF_MARKER_BEREIT"], !dir.isEmpty else { throw XCTSkip("nur fuer Bilder") }
        let fx = try await makeFixture(pages: 2)
        try Skript.pdf(pages: 2, .vorlesung).write(to: AppPaths.pdf(fx.file.id, namespace: fx.api.namespace, root: fx.root))
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: true)
        defer { hide(shown) }
        let overlay = try await waitForOverlay(shown.editor, page: 0)
        let colors = EditorToolState.markerColors.map { UIColor(hex: $0.hex) ?? .yellow }
        // Zeilen der PDF: y = 90 + 22 * l, Schrift 13 pt
        let rows: [(String, UIColor, CGFloat, Int)] = [
            ("bis 17.11.: Gelb 100 %", colors[0], 1, 1), ("bis 17.11.: Gelb 100 %, zweimal übermalt", colors[0], 1, 2),
            ("jetzt: Gelb 50 %", colors[0], 0.5, 1), ("jetzt: Gelb 50 %, zweimal übermalt", colors[0], 0.5, 2),
            ("bis 17.11.: Grün 100 %", colors[1], 1, 1), ("jetzt: Grün 50 %", colors[1], 0.5, 1),
            ("jetzt: Blau 50 %", colors[2], 0.5, 1), ("jetzt: Pink 50 %", colors[3], 0.5, 1),
        ]
        var strokes: [PKStroke] = []
        for (r, row) in rows.enumerated() {
            let y = 98 + CGFloat(r) * 22
            for k in 0..<row.3 {
                let pts = (0...70).map { PKStrokePoint(location: CGPoint(x: 46 + CGFloat($0) * 4, y: y + CGFloat(k) * 0.5), timeOffset: Double($0) * 0.008,
                                                       size: CGSize(width: 10, height: 10), opacity: 1, force: 1, azimuth: .pi / 2, altitude: .pi / 2) }
                strokes.append(PKStroke(ink: PKInk(.marker, color: row.1.withAlphaComponent(row.2)),
                                        path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 1_990_000_000 + Double(r * 10 + k)))))
            }
            let label = UILabel()
            label.text = row.0
            label.font = .systemFont(ofSize: 8, weight: .semibold)
            label.textColor = .systemRed
            label.backgroundColor = .white
            label.frame = CGRect(x: 332, y: y - 8, width: 255, height: 16)
            overlay.content.addSubview(label)
        }
        overlay.isApplyingDrawing = true
        ZeichnungSpion.own = true
        overlay.canvas.drawing = PKDrawing(strokes: strokes)
        ZeichnungSpion.own = false
        overlay.isApplyingDrawing = false
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "bereit".write(toFile: dir + "/bereit-hell", atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 9_000_000_000)
        shown.window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try? "bereit".write(toFile: dir + "/bereit-dunkel", atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 9_000_000_000)
        await store.close()
    }

    /// Welche Symbole gibt es fuer den Fueller, und wie heissen die Eintraege in Apples Palette
    func testMessungSymboleUndPalette() throws {
        let names = ["pencil.tip", "pencil.tip.crop.circle", "paintbrush.pointed", "signature", "applepencil.tip", "pencil.line", "pencil.and.scribble",
                     "fountainpen", "fountain.pen", "pen.nib", "inkwell", "pencil.and.outline", "scribble.variable", "applepencil.gen2", "pencil",
                     "highlighter", "paintbrush", "pencil.tip.crop.circle.fill", "lineweight", "pencil.and.ruler"]
        let vorhanden = names.filter { UIImage(systemName: $0) != nil }
        print("[Messung] Symbole vorhanden: \(vorhanden.joined(separator: ", ")); fehlen: \(names.filter { !vorhanden.contains($0) }.joined(separator: ", "))")
        let f = UIGraphicsImageRendererFormat()
        f.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(vorhanden.count) * 60, height: 70), format: f).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(vorhanden.count) * 60, height: 70))
            for (i, n) in vorhanden.enumerated() {
                let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                UIImage(systemName: n, withConfiguration: cfg)?.withTintColor(.black).draw(at: CGPoint(x: CGFloat(i) * 60 + 18, y: 12))
                String(i).draw(at: CGPoint(x: CGFloat(i) * 60 + 22, y: 46), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
            }
        }
        Self.sichere(image, "symbole")
        if #available(iOS 18.0, *) {
            print("[Messung] Eintraege in Apples Palette: " + PKToolPicker().toolItems.map(\.identifier).joined(separator: ", "))
        }
    }
}
