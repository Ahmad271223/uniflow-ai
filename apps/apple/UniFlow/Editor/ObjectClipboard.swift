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

    /// Ziehen ohne Aenderung beendet: die Zeichnung zeigt die Striche wieder selbst
    private func restoreInk(_ drag: (view: UIImageView, before: PKDrawing, overlay: PageInkView)?) {
        guard let drag else { return }
        drag.overlay.isApplyingDrawing = true
        drag.overlay.canvas.drawing = drag.before
        drag.overlay.isApplyingDrawing = false
    }

    /// Seite eines Schluessels in Seitenpunkten (nil, solange sie nicht gezeigt wird: dann ohne Grenzen)
    private func pageRect(_ key: String) -> CGRect? { controller?.boundOverlay(forKey: key).map(Self.page(of:)) }

    /// Verschieben beenden: Objekte und Handschrift zusammen, ein Rueckgaengig-Schritt. Die Auswahl bleibt ganz auf der
    /// Seite (21.11.2026: ein ueber den Rand gezogenes Bild war danach nicht mehr zu sehen - "das verschwindet dann").
    func finishMove(dx: CGFloat, dy: CGFloat) {
        let sel = selection, ink = inkSelection, drag = inkDrag
        inkDrag = nil
        drag?.view.removeFromSuperview()
        guard dx != 0 || dy != 0 else { restoreInk(drag); return }
        Task {
            let key = sel?.key ?? ink?.key ?? ""
            let overlay = controller?.boundOverlay(forKey: key)
            var d = CGPoint(x: dx, y: dy)
            if let page = pageRect(key) {
                var box = sel.map { s in Self.box(of: overlay?.objectsView.shownObjects ?? [], ids: s.ids) } ?? .null
                if sel != nil, box.isNull { box = Self.box(of: await objects(key), ids: sel?.ids ?? []) }
                if let ink {
                    let drawing: PKDrawing
                    if let drag { drawing = drag.before } else { drawing = await controller?.inkDrawing(forKey: key) ?? PKDrawing() }
                    box = box.union(Self.bounds(of: ink.indices, in: drawing))
                }
                d = Self.clampedOffset(box, by: d, in: page)
            }
            guard abs(d.x) + abs(d.y) > 0.005 else {
                restoreInk(drag)
                if let sel { overlay?.objectsView.previewMove(ids: sel.ids, by: .zero) }
                drawSelection(await objects(key))
                return
            }
            let t = CGAffineTransform(translationX: d.x, y: d.y)
            holdsFrame = true
            var changed = true
            if let sel { changed = await commit(sel.key) { PageObjectEdit.move($0, ids: sel.ids, dx: Double(d.x), dy: Double(d.y)) } }
            if let ink, let drag {
                controller?.replaceInk(key: ink.key, before: drag.before, after: Self.transformed(drag.before, indices: ink.indices, by: t))
            } else if let ink {
                await changeInk(ink) { Self.transformed($0, indices: ink.indices, by: t) }
            }
            holdsFrame = false
            if let sel, !changed { overlay?.objectsView.previewMove(ids: sel.ids, by: .zero) }
            drawSelection(await objects(key))
        }
    }

    /// Auswahl vergroessern bzw. verkleinern (Anfasser an der Ecke, zwei Finger, Menue "Größer"/"Kleiner") um `anchor`,
    /// ohne Angabe um ihre linke obere Ecke; ein Rueckgaengig-Schritt. Das Seitenverhaeltnis bleibt, Objekte und
    /// Handschrift bleiben zusammen. Grenzen und Lage auf der Seite: `resized`.
    func scaleSelection(by f: Double, about anchor: CGPoint? = nil) {
        let sel = selection, ink = inkSelection, drag = inkDrag
        inkDrag = nil
        drag?.view.removeFromSuperview()
        guard hasSelection, f > 0, f.isFinite else { restoreInk(drag); return }
        Task {
            let key = sel?.key ?? ink?.key ?? ""
            let overlay = controller?.boundOverlay(forKey: key)
            let ids = sel?.ids ?? []
            let list = await objects(key)
            var before: PKDrawing?
            if ink != nil {
                if let drag { before = drag.before } else { before = await controller?.inkDrawing(forKey: key) }
            }
            let inkBox = ink.flatMap { i in before.map { Self.bounds(of: i.indices, in: $0) } } ?? .null
            let box = Self.box(of: list, ids: ids).union(inkBox)
            // ohne gezeigte Seite keine Grenzen der Seite
            let page = pageRect(key) ?? CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)
            let about = anchor ?? box.origin
            let result = Self.resized(list, ids: ids, inkBox: inkBox, by: f, about: about, page: page)
            guard !box.isNull, abs(result.factor - 1) > 0.0005 || result.box != box else {
                restoreInk(drag)
                overlay?.objectsView.preview(nil)
                drawSelection(list)
                return
            }
            holdsFrame = true
            var changed = true
            if let sel {
                changed = await commit(sel.key) { Self.resized($0, ids: sel.ids, inkBox: inkBox, by: f, about: about, page: page).objects }
            }
            if let ink, let before {
                controller?.replaceInk(key: ink.key, before: before, after: Self.transformed(before, indices: ink.indices, by: result.inkTransform))
            }
            holdsFrame = false
            if sel != nil, !changed { overlay?.objectsView.preview(nil) }
            drawSelection(await objects(key))
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
        // ohne Pro AI liessen sich Tabellen, Klappkarten und Verweise nicht wieder einfuegen: Sie bleiben liegen,
        // statt beim Ausschneiden verloren zu gehen (zweite Durchsicht 26.11.2026)
        if !richAllowed, let sel = selection, let key = selectedKey {
            let picked = await objects(key).filter { ($0["id"]?.string).map(sel.ids.contains) == true }
            let locked = Set(picked.filter { SheetObject.isSheet($0) || FlipCover.isCover($0) || PageLink.isLink($0) }.compactMap { $0["id"]?.string })
            if !locked.isEmpty {
                controller?.onHint?(Self.copyLockedHint)
                let rest = sel.ids.subtracting(locked)
                guard !rest.isEmpty || inkSelection != nil else { return }
                select(key: key, ids: rest, in: await objects(key), ink: inkSelection?.indices ?? [])
            }
        }
        guard await copySelection(to: pasteboard) else { return }
        deleteSelection()
    }

    /// Duplizieren: Kopie daneben (20 pt versetzt), danach ausgewaehlt
    func duplicateSelection() async {
        guard let key = selectedKey else { return }
        let sel = selection, ink = inkSelection
        let list = await objects(key)
        let copies = Self.copies(of: copyable(list.filter { (o: JSONValue) in (o["id"]?.string).map { sel?.ids.contains($0) == true } == true }),
                                 dx: Self.pasteOffset, dy: Self.pasteOffset)
        var inkCopies: PKDrawing?
        if let ink, let c = controller {
            let d = await c.inkDrawing(forKey: key)
            inkCopies = Self.transformed(PKDrawing(strokes: ink.indices.filter { d.strokes.indices.contains($0) }.map { d.strokes[$0] }),
                                         indices: [], by: .identity)
        }
        await place(objects: copies, ink: inkCopies, inkOffset: CGPoint(x: Self.pasteOffset, y: Self.pasteOffset), on: key)
    }

    static let copyLockedHint = "Tabellen, Klappkarten und Verweise vervielfältigen geht mit Pro AI."

    /// Was sich vervielfaeltigen laesst: Ohne Pro AI keine Tabellen, Klappkarten und Verweise (anlegen geht dann auch
    /// nicht - Duplizieren und Einfuegen waeren sonst der Weg daran vorbei). Eine kopierte Tabelle ist nie die
    /// "Tabelle als eigene Datei": Sonst oeffnete das Dokument, in das sie eingefuegt wird, kuenftig gleich gross.
    func copyable(_ list: [JSONValue]) -> [JSONValue] {
        let cleaned = list.map { o -> JSONValue in
            guard SheetObject.isSheet(o), o["sheet"]?["doc"] != nil, var obj = o.object, var sheet = obj["sheet"]?.object else { return o }
            sheet["doc"] = nil
            obj["sheet"] = .object(sheet)
            return .object(obj)
        }
        guard !richAllowed else { return cleaned }
        let kept = cleaned.filter { !(SheetObject.isSheet($0) || FlipCover.isCover($0) || PageLink.isLink($0)) }
        if kept.count != cleaned.count { controller?.onHint?(Self.copyLockedHint) }
        return kept
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
            let list = copyable(objectsData.flatMap { try? JSONValue.parse(String(decoding: $0, as: UTF8.self)) }?.array ?? [])
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

    /// Rahmen fuer ein neues Bild der Groesse `size` (Seitenpunkte): hoechstens halbe Seitenbreite und nie hoeher als die
    /// Seite. Mit `point` (Ablegen, Rechtsklick) liegt die linke obere Ecke dort, sonst oben im sichtbaren Teil
    /// `visible` der Seite, waagerecht mittig, und passt ganz hinein. Immer ganz auf der Seite. Vorher lag ein neues Bild
    /// immer bei y = 60 oben auf der Seite - hineingezoomt und nach unten gescrollt also ausserhalb des Bildschirms.
    nonisolated static func imageFrame(_ size: CGSize, page: CGRect, visible: CGRect?, at point: CGPoint?) -> CGRect {
        let margin: CGFloat = 12
        var scale = min(1, page.width * 0.5 / size.width, page.height / size.height)
        var area = page
        if point == nil, let v = visible?.intersection(page), !v.isNull, v.width >= 2 * minimumSide, v.height >= 2 * minimumSide {
            area = v
            scale = min(scale, (v.width - 2 * margin) / size.width, (v.height - 2 * margin) / size.height)
        }
        let w = size.width * scale, h = size.height * scale
        let wanted = point ?? CGPoint(x: area.midX - w / 2, y: area.minY + min(60, max(margin, (area.height - h) / 2)))
        let d = clampedOffset(CGRect(x: wanted.x, y: wanted.y, width: w, height: h), by: .zero, in: point == nil ? area : page)
        return CGRect(x: wanted.x + d.x, y: wanted.y + d.y, width: w, height: h)
    }

    /// Bild auf eine Seite (hochladen wie im Web; Groesse und Lage: `imageFrame`), danach ausgewaehlt
    @discardableResult
    func insertImage(_ image: UIImage, on key: String, at point: CGPoint? = nil) async -> Bool {
        guard let c = controller, c.writable, image.size.width > 0, image.size.height > 0 else { return false }
        let src: String
        do { src = try await c.store.uploadNoteImage(Self.normalized(image)) } catch {
            c.onHint?("Bild konnte nicht eingefügt werden.")
            return false
        }
        // erst nach dem Hochladen messen: bis dahin kann gescrollt worden sein
        let overlay = c.boundOverlay(forKey: key)
        let page = overlay.map(Self.page(of:)) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let r = Self.imageFrame(image.size, page: page, visible: overlay?.viewportInPage(), at: point)
        let o: JSONValue = .object(["id": .string(PageOrder.uid()), "type": "image", "src": .string(src),
                                    "x": .number(Double(r.minX)), "y": .number(Double(r.minY)),
                                    "width": .number(Double(r.width)), "height": .number(Double(r.height)),
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
