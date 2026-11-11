import PencilKit
import UIKit
import UniFlowCore

// Auswahl, Zwischenablage und Bilder (10.11.2026, docs/EDITOR-VERBESSERUNGEN-2026-11-10.md):
// - ein Lasso fuer Handschrift und Objekte: verschieben, vergroessern, loeschen, kopieren gemeinsam,
// - Kopieren, Ausschneiden, Einfuegen, Duplizieren (Cmd-C/X/V/D, Bearbeiten-Menue, Rechtsklick),
// - Bilder einfuegen (Fotos, Dateien, Ziehen aus Finder/Fotos, Einfuegen aus der Zwischenablage),
// - Reihenfolge (nach vorne/hinten) und Groesse per Menue (Maus ohne Pinch).
// Objekte bleiben im Format des Web-Editors (`PageObjectEdit`), Handschrift in der Zeichnung der Seite.

extension ObjectEditing {
    /// Eigene Typen in der Zwischenablage: Objekte als JSON, Handschrift als PencilKit-Daten
    static let objectsPasteboardType = "de.studinow.objects"
    static let inkPasteboardType = "de.studinow.ink"
    /// Versatz beim Duplizieren und beim Einfuegen auf derselben Stelle
    static let pasteOffset: Double = 20

    // MARK: Handschrift in der Auswahl

    /// Striche, die zum groessten Teil (mindestens 60 % ihrer Punkte) im Lasso liegen
    nonisolated static func strokes(of drawing: PKDrawing, inLasso polygon: [(x: Double, y: Double)]) -> [Int] {
        guard polygon.count >= 3 else { return [] }
        return drawing.strokes.indices.filter { i in
            let s = drawing.strokes[i]
            let pts = s.path.interpolatedPoints(by: .distance(4)).map { $0.location.applying(s.transform) }
            guard !pts.isEmpty else { return false }
            let inside = pts.filter { contains(polygon, $0) }.count
            return Double(inside) >= 0.6 * Double(pts.count)
        }
    }

    /// Punkt im Vieleck (Strahlverfahren)
    nonisolated static func contains(_ poly: [(x: Double, y: Double)], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > Double(p.y)) != (b.y > Double(p.y)),
               Double(p.x) < (b.x - a.x) * (Double(p.y) - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    nonisolated static func bounds(of indices: [Int], in drawing: PKDrawing) -> CGRect {
        indices.reduce(CGRect.null) { r, i in drawing.strokes.indices.contains(i) ? r.union(drawing.strokes[i].renderBounds) : r }
    }

    /// Striche verschieben bzw. um `anchor` skalieren (Transform jedes Strichs, Punkte bleiben)
    nonisolated static func transformed(_ drawing: PKDrawing, indices: [Int], by t: CGAffineTransform) -> PKDrawing {
        var d = drawing
        for i in indices where d.strokes.indices.contains(i) { d.strokes[i].transform = d.strokes[i].transform.concatenating(t) }
        return d
    }

    nonisolated static func scaleTransform(_ f: Double, about a: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -a.x, y: -a.y).concatenating(CGAffineTransform(scaleX: f, y: f))
            .concatenating(CGAffineTransform(translationX: a.x, y: a.y))
    }

    /// Ziehen beginnt: ausgewaehlte Striche als Bild ueber der Seite, die Zeichnung zeigt sie solange nicht
    func beginInkDrag(on overlay: PageInkView) {
        guard let ink = inkSelection, ink.key == overlay.pageKey, overlay.loaded, inkDrag == nil else { return }
        let before = overlay.canvas.drawing
        let box = Self.bounds(of: ink.indices, in: before)
        guard !box.isNull else { return }
        let picked = PKDrawing(strokes: ink.indices.filter { before.strokes.indices.contains($0) }.map { before.strokes[$0] })
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = picked.image(from: box, scale: 2) }
        let view = UIImageView(image: image)
        view.frame = box
        view.isUserInteractionEnabled = false
        overlay.content.addSubview(view)
        var rest = before
        rest.strokes = before.strokes.enumerated().filter { !ink.indices.contains($0.offset) }.map(\.element)
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = rest
        overlay.isApplyingDrawing = false
        inkDrag = (view, before, overlay)
    }

    /// Ziehen abgebrochen: alles wie vorher
    func cancelInkDrag() {
        guard let drag = inkDrag else { return }
        inkDrag = nil
        drag.view.removeFromSuperview()
        drag.overlay.isApplyingDrawing = true
        drag.overlay.canvas.drawing = drag.before
        drag.overlay.isApplyingDrawing = false
    }

    /// Verschieben beenden: Objekte und Handschrift zusammen, ein Rueckgaengig-Schritt
    func finishMove(dx: CGFloat, dy: CGFloat) {
        let sel = selection, ink = inkSelection, drag = inkDrag
        inkDrag = nil
        drag?.view.removeFromSuperview()
        guard dx != 0 || dy != 0 else {
            if let drag {
                drag.overlay.isApplyingDrawing = true
                drag.overlay.canvas.drawing = drag.before
                drag.overlay.isApplyingDrawing = false
            }
            return
        }
        let t = CGAffineTransform(translationX: dx, y: dy)
        Task {
            if let sel { await commit(sel.key) { PageObjectEdit.move($0, ids: sel.ids, dx: Double(dx), dy: Double(dy)) } }
            if let ink, let drag {
                controller?.replaceInk(key: ink.key, before: drag.before, after: Self.transformed(drag.before, indices: ink.indices, by: t))
            } else if let ink {
                await changeInk(ink) { Self.transformed($0, indices: ink.indices, by: t) }
            }
            drawSelection(await objects(sel?.key ?? ink?.key ?? ""))
        }
    }

    /// Auswahl vergroessern bzw. verkleinern (Pinch, Menue "Größer"/"Kleiner"), um ihre linke obere Ecke
    func scaleSelection(by f: Double) {
        guard hasSelection, f > 0 else { return }
        let sel = selection, ink = inkSelection
        Task {
            let list = await objects(sel?.key ?? ink?.key ?? "")
            if let sel { await commit(sel.key) { PageObjectEdit.scale($0, ids: sel.ids, factorX: f, factorY: f) } }
            if let ink {
                await changeInk(ink) { d in
                    var anchor = Self.bounds(of: ink.indices, in: d).origin
                    if let sel {
                        // gemeinsame Ecke mit den Objekten, damit beides zusammenbleibt
                        for o in list where (o["id"]?.string).map(sel.ids.contains) == true {
                            if let b = PageObjectEdit.bounds(o, textHeight: Self.textHeight) {
                                anchor = CGPoint(x: min(anchor.x, CGFloat(b.minX)), y: min(anchor.y, CGFloat(b.minY)))
                            }
                        }
                    }
                    return Self.transformed(d, indices: ink.indices, by: Self.scaleTransform(f, about: anchor))
                }
            }
            drawSelection(await objects(sel?.key ?? ink?.key ?? ""))
        }
    }

    /// Ausgewaehlte Striche entfernen
    func removeInk(_ ink: (key: String, indices: [Int])) async {
        await changeInk(ink) { d in
            var out = d
            out.strokes = d.strokes.enumerated().filter { !ink.indices.contains($0.offset) }.map(\.element)
            return out
        }
    }

    func changeInk(_ ink: (key: String, indices: [Int]), _ change: (PKDrawing) -> PKDrawing) async {
        guard let c = controller else { return }
        let before = await c.inkDrawing(forKey: ink.key)
        c.replaceInk(key: ink.key, before: before, after: change(before))
    }

    // MARK: Zwischenablage

    /// Auswahl kopieren: Objekte (JSON), Handschrift (PencilKit) und der Text der Textfelder als einfacher Text
    @discardableResult
    func copySelection(to pasteboard: UIPasteboard = .general) async -> Bool {
        guard let key = selectedKey else { return false }
        var item: [String: Any] = [:]
        if let sel = selection {
            let picked = await objects(key).filter { ($0["id"]?.string).map(sel.ids.contains) == true }
            if !picked.isEmpty {
                item[Self.objectsPasteboardType] = Data(JSONValue.array(picked).jsonString(sortedKeys: true).utf8)
                let text = NoteSearch.typedText(picked)
                if !text.isEmpty { item["public.utf8-plain-text"] = text }
            }
        }
        if let ink = inkSelection, let c = controller {
            let d = await c.inkDrawing(forKey: ink.key)
            let picked = PKDrawing(strokes: ink.indices.filter { d.strokes.indices.contains($0) }.map { d.strokes[$0] })
            if !picked.strokes.isEmpty { item[Self.inkPasteboardType] = picked.dataRepresentation() }
        }
        guard !item.isEmpty else { return false }
        pasteboard.setItems([item])
        return true
    }

    func cutSelection(to pasteboard: UIPasteboard = .general) async {
        guard await copySelection(to: pasteboard) else { return }
        deleteSelection()
    }

    /// Duplizieren: Kopie daneben (20 pt versetzt), danach ausgewaehlt
    func duplicateSelection() async {
        guard let key = selectedKey else { return }
        let sel = selection, ink = inkSelection
        let list = await objects(key)
        let copies = Self.copies(of: list.filter { (o: JSONValue) in (o["id"]?.string).map { sel?.ids.contains($0) == true } == true },
                                 dx: Self.pasteOffset, dy: Self.pasteOffset)
        var inkCopies: PKDrawing?
        if let ink, let c = controller {
            let d = await c.inkDrawing(forKey: key)
            inkCopies = Self.transformed(PKDrawing(strokes: ink.indices.filter { d.strokes.indices.contains($0) }.map { d.strokes[$0] }),
                                         indices: [], by: .identity)
        }
        await place(objects: copies, ink: inkCopies, inkOffset: CGPoint(x: Self.pasteOffset, y: Self.pasteOffset), on: key)
    }

    /// Objekte mit neuen Kennungen, verschoben
    nonisolated static func copies(of objects: [JSONValue], dx: Double, dy: Double) -> [JSONValue] {
        let renamed = objects.compactMap { o -> JSONValue? in
            guard var obj = o.object else { return nil }
            obj["id"] = .string(PageOrder.uid())
            obj["source"] = "ipad"
            return .object(obj)
        }
        let ids = Set(renamed.compactMap { $0["id"]?.string })
        return PageObjectEdit.move(renamed, ids: ids, dx: dx, dy: dy)
    }

    /// Einfuegen aus der Zwischenablage auf Seite `key` (bei `point` bzw. versetzt an der Originalstelle):
    /// eigene Objekte/Handschrift, sonst ein Bild, sonst Text als Textfeld. `true`, wenn etwas eingefuegt wurde.
    @discardableResult
    func paste(on key: String, at point: CGPoint? = nil, pasteboard: UIPasteboard = .general) async -> Bool {
        guard let c = controller, c.writable else { return false }
        let objectsData = pasteboard.data(forPasteboardType: Self.objectsPasteboardType)
        let inkData = pasteboard.data(forPasteboardType: Self.inkPasteboardType)
        if objectsData != nil || inkData != nil {
            let list = objectsData.flatMap { try? JSONValue.parse(String(decoding: $0, as: UTF8.self)) }?.array ?? []
            let ink = inkData.flatMap { try? PKDrawing(data: $0) }
            // Ziel: linke obere Ecke von allem an `point`, sonst um 20 pt versetzt
            var box = ink?.bounds ?? .null
            for o in list { if let b = PageObjectEdit.bounds(o, textHeight: Self.textHeight) {
                box = box.union(CGRect(x: b.minX, y: b.minY, width: b.maxX - b.minX, height: b.maxY - b.minY)) } }
            let d = point.map { p in box.isNull ? CGPoint.zero : CGPoint(x: p.x - box.minX, y: p.y - box.minY) }
                ?? CGPoint(x: Self.pasteOffset, y: Self.pasteOffset)
            await place(objects: Self.copies(of: list, dx: Double(d.x), dy: Double(d.y)), ink: ink, inkOffset: d, on: key)
            return true
        }
        if pasteboard.hasImages, let image = pasteboard.image {
            return await insertImage(image, on: key, at: point)
        }
        if pasteboard.hasStrings, let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let p = point ?? CGPoint(x: 60, y: 60)
            let o = PageObjectEdit.text(id: PageOrder.uid(), x: Double(p.x), y: Double(p.y), text: String(text.prefix(5000)))
            await place(objects: [o], ink: nil, inkOffset: .zero, on: key)
            return true
        }
        return false
    }

    /// Objekte und Handschrift auf eine Seite setzen (ein Rueckgaengig-Schritt) und auswaehlen
    func place(objects new: [JSONValue], ink: PKDrawing?, inkOffset: CGPoint, on key: String) async {
        guard let c = controller, c.writable, !new.isEmpty || !(ink?.strokes.isEmpty ?? true) else { return }
        if !isActive { c.choose(.select) }
        if !new.isEmpty { await commit(key) { $0 + new } }
        var inkIndices: [Int] = []
        if let ink, !ink.strokes.isEmpty {
            let before = await c.inkDrawing(forKey: key)
            var after = before
            let moved = Self.transformed(ink, indices: Array(ink.strokes.indices),
                                         by: CGAffineTransform(translationX: inkOffset.x, y: inkOffset.y))
            after.strokes.append(contentsOf: moved.strokes)
            inkIndices = Array(before.strokes.count..<after.strokes.count)
            c.replaceInk(key: key, before: before, after: after)
        }
        setTool(.select)
        select(key: key, ids: Set(new.compactMap { $0["id"]?.string }), in: await objects(key), ink: inkIndices)
    }

    // MARK: Bilder

    /// Bild auf eine Seite (hochladen wie im Web, hoechstens halbe Seitenbreite, an `point` bzw. oben links)
    @discardableResult
    func insertImage(_ image: UIImage, on key: String, at point: CGPoint? = nil) async -> Bool {
        guard let c = controller, c.writable, image.size.width > 0, image.size.height > 0 else { return false }
        let pageWidth = c.boundOverlay(forKey: key)?.geometry.pageSize.width ?? 595
        let src: String
        do { src = try await c.store.uploadNoteImage(Self.normalized(image)) } catch {
            c.onHint?("Bild konnte nicht eingefügt werden.")
            return false
        }
        let scale = min(1, pageWidth * 0.5 / image.size.width)
        let p = point ?? CGPoint(x: pageWidth * 0.25, y: 60)
        let o: JSONValue = .object(["id": .string(PageOrder.uid()), "type": "image", "src": .string(src),
                                    "x": .number(Double(p.x)), "y": .number(Double(p.y)),
                                    "width": .number(Double(image.size.width * scale)), "height": .number(Double(image.size.height * scale)),
                                    "rotation": 0, "scaleX": 1, "scaleY": 1, "opacity": 1, "source": "ipad"])
        await place(objects: [o], ink: nil, inkOffset: .zero, on: key)
        return true
    }

    /// Bild ohne Drehung aus der Kamera (EXIF) und hoechstens 2400 Pixel an der laengsten Seite
    nonisolated static func normalized(_ image: UIImage, maxPixels: CGFloat = 2400) -> UIImage {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let f = min(1, maxPixels / max(px.width, px.height, 1))
        guard f < 1 || image.imageOrientation != .up else { return image }
        let size = CGSize(width: (px.width * f).rounded(), height: (px.height * f).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    // MARK: Reihenfolge

    /// Ausgewaehlte Objekte nach vorne (oben) bzw. nach hinten (unter die anderen Objekte)
    func reorderSelection(toFront: Bool) {
        guard let sel = selection else { return }
        Task {
            await commit(sel.key) { list in
                let picked = list.filter { ($0["id"]?.string).map(sel.ids.contains) == true }
                let rest = list.filter { ($0["id"]?.string).map(sel.ids.contains) != true }
                return toFront ? rest + picked : picked + rest
            }
        }
    }

    // MARK: Treffer ohne Warten (Kontextmenue)

    /// Objekt bzw. Striche unter einem Punkt der Seite (zuletzt gezeigter Stand)
    func hitNow(on overlay: PageInkView, at p: CGPoint) -> (objectID: String?, inkIndex: Int?) {
        let id = PageObjectEdit.hit(overlay.objectsView.shownObjects, x: Double(p.x), y: Double(p.y), textHeight: Self.textHeight)
        var ink: Int?
        if id == nil, overlay.loaded {
            ink = overlay.canvas.drawing.strokes.indices.last { overlay.canvas.drawing.strokes[$0].renderBounds.insetBy(dx: -6, dy: -6).contains(p) }
        }
        return (id, ink)
    }

    /// Auswahl auf einen Treffer setzen (Rechtsklick auf ein Objekt oder einen Strich)
    func selectHit(on overlay: PageInkView, objectID: String?, inkIndex: Int?) {
        if objectID == nil, inkIndex == nil { return }
        if let id = objectID, selection?.ids.contains(id) == true { return }
        if let i = inkIndex, inkSelection?.indices.contains(i) == true { return }
        controller?.choose(.select)
        select(key: overlay.pageKey, ids: objectID.map { [$0] } ?? [], in: overlay.objectsView.shownObjects, ink: inkIndex.map { [$0] } ?? [])
    }
}
