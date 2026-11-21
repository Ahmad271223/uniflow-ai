import UIKit
import UniFlowCore

// Bild ins andere Dokument ziehen (geteilte Ansicht: Hauptdokument <-> Dokument daneben), 21.11.2026.
//
// Wunsch des Inhabers am iPad: "Geht das irgendwie, dass man das auf beide Seiten schieben kann, ohne erst das genaue
// Dokument antippen oder beschreiben zu müssen?" - ein ausgewaehltes Bild mit Finger oder Stift ueber die Trennlinie
// ziehen und im anderen Dokument loslassen.
//
// Ablauf: Verlaesst der Finger beim Verschieben die Ansicht des eigenen Dokuments, folgt ihm das Bild schwebend auf
// Ebene des Fensters (die Vorschau im eigenen Dokument bleibt an dessen Seitenrand stehen und wird blass). Ueber einer
// Seite des anderen Dokuments zeigt ein Rahmen, wo es landet. Loslassen dort: Das Bild wird als EIGENES Bild der
// Zieldatei angelegt (`DocumentStore.adoptNoteImage`, dieselben Bytes), dann auf die Zielseite gesetzt, und erst
// danach aus der Quelle entfernt - schlaegt etwas fehl, bleibt es, wo es war. Im gemeinsamen Verlauf ist das EIN
// Schritt (`ImageTransferStep`). Loslassen neben jeder Seite (Trennlinie, Leisten): wie bisher, das Bild bleibt im
// eigenen Dokument auf der Seite. Gilt fuer ein einzelnes ausgewaehltes Bild; Text, Formen und Handschrift bleiben im
// Dokument.

/// Ein hinuebergezogenes Bild im gemeinsamen Verlauf: Zurueck holt es in die Quelle und entfernt es im Ziel, Vor
/// verschiebt es wieder. Der Verlauf haelt seine Ziele nicht selbst; `EditorToolState.transferSteps` haelt die Schritte.
@MainActor
final class ImageTransferStep {
    private(set) weak var source: PDFEditorController?
    private(set) weak var target: PDFEditorController?
    let sourceKey: String
    let targetKey: String
    /// Bildobjekt, wie es in der Quelle lag, und seine Stelle in der Reihenfolge der Seite
    let sourceObject: JSONValue
    let sourceIndex: Int
    /// Bildobjekt im Ziel (eigene Kennung, eigene Bildadresse der Zieldatei)
    let targetObject: JSONValue

    init(source: PDFEditorController, sourceKey: String, sourceObject: JSONValue, sourceIndex: Int,
         target: PDFEditorController, targetKey: String, targetObject: JSONValue) {
        self.source = source
        self.sourceKey = sourceKey
        self.sourceObject = sourceObject
        self.sourceIndex = sourceIndex
        self.target = target
        self.targetKey = targetKey
        self.targetObject = targetObject
    }

    /// Eintrag im Verlauf: `undoing` = beim Ausfuehren zurueckholen (Rueckgaengig), sonst wieder hinueber (Wiederholen).
    /// Der Gegeneintrag entsteht sofort im Handler (erst nach einem `await` angemeldet, zaehlte er als neuer Schritt).
    func register(undoing: Bool, in undo: UndoManager) {
        undo.beginSeparateStep()
        undo.registerUndo(withTarget: self) { step in
            MainActor.assumeIsolated {
                step.register(undoing: !undoing, in: undo)
                step.source?.objects.clearSelection()
                step.target?.objects.clearSelection()
                Task { @MainActor in await step.apply(undoing: undoing) }
            }
        }
        undo.setActionName("Bild verschieben")
    }

    /// Immer zuerst dort anlegen, wo das Bild hin soll, dann am anderen Ort entfernen - es ist nie nirgends.
    func apply(undoing: Bool) async {
        guard let source, let target else { return }
        let sourceID = sourceObject["id"]?.string ?? "", targetID = targetObject["id"]?.string ?? ""
        let object = sourceObject, index = sourceIndex, moved = targetObject
        if undoing {
            await source.store.editObjects(pageKey: sourceKey) { list in
                guard !list.contains(where: { $0["id"]?.string == sourceID }) else { return list }
                var out = list
                out.insert(object, at: min(max(0, index), out.count))
                return out
            }
            guard await source.store.objects(forPageKey: sourceKey).contains(where: { $0["id"]?.string == sourceID }) else { return }
            await target.store.editObjects(pageKey: targetKey) { PageObjectEdit.delete($0, ids: [targetID]) }
        } else {
            await target.store.editObjects(pageKey: targetKey) { list in
                list.contains(where: { $0["id"]?.string == targetID }) ? list : list + [moved]
            }
            guard await target.store.objects(forPageKey: targetKey).contains(where: { $0["id"]?.string == targetID }) else { return }
            await source.store.editObjects(pageKey: sourceKey) { PageObjectEdit.delete($0, ids: [sourceID]) }
        }
    }
}

extension ObjectEditing {
    static let transferViewID = "objects.transferImage"
    static let transferFrameName = "objects.dropTarget"

    static let transferViewOnlyHint = "Das andere Dokument ist nur zum Ansehen – das Bild bleibt hier."
    static let transferFailedHint = "Das Bild ließ sich nicht ins andere Dokument verschieben – es bleibt hier."

    /// Das eine Bild, das sich hinueberziehen laesst: genau ein Objekt ausgewaehlt, ein Bild, keine Handschrift dabei
    private func transferable(_ gr: Grab) -> JSONValue? {
        guard case .move = gr.kind, gr.ids.count == 1, inkSelection == nil, let id = gr.ids.first,
              let o = gr.list.first(where: { $0["id"]?.string == id }), o["type"]?.string == "image", o["src"]?.string != nil else { return nil }
        return o
    }

    /// Das andere Dokument, wenn der Finger die Ansicht des eigenen verlassen hat (sonst nil: alles wie immer)
    private func transferTarget(_ g: UIPanGestureRecognizer) -> PDFEditorController? {
        guard let c = controller, !c.pdfView.bounds.contains(g.location(in: c.pdfView)) else { return nil }
        return c.tools.otherEditor(than: c)
    }

    /// Seite dieses Editors unter einem Punkt des Fensters und der Punkt in Seitenpunkten
    func page(atWindowPoint w: CGPoint) -> (PageInkView, CGPoint)? {
        guard let c = controller, c.pdfView.bounds.contains(c.pdfView.convert(w, from: nil)) else { return nil }
        for v in c.allOverlays where v.window != nil && !v.pageKey.isEmpty && v.generation == c.shownLayoutVersion {
            let p = v.content.convert(w, from: nil)
            if v.content.bounds.contains(p) { return (v, p) }
        }
        return nil
    }

    /// Wo ein hinuebergezogenes Objekt der Groesse `size` landet: um den Finger, gleiche Groesse in Seitenpunkten
    /// (hoechstens so gross wie die Seite), ganz auf der Seite
    nonisolated static func landing(_ size: CGSize, at p: CGPoint, page: CGRect) -> (rect: CGRect, factor: Double) {
        let f = min(1, page.width / max(size.width, 1), page.height / max(size.height, 1))
        let w = size.width * f, h = size.height * f
        let r = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        let d = clampedOffset(r, by: .zero, in: page)
        return (r.offsetBy(dx: d.x, dy: d.y), Double(f))
    }

    /// Bildobjekt fuer das Ziel: wie `object`, mit eigener Kennung und Bildadresse, an der Stelle `landing`
    nonisolated static func transferred(_ object: JSONValue, id: String, src: String, to p: CGPoint, page: CGRect) -> JSONValue {
        guard var fields = object.object else { return object }
        fields["id"] = .string(id)
        fields["src"] = .string(src)
        fields["source"] = "ipad"
        var list: [JSONValue] = [.object(fields)]
        let before = box(of: list, ids: [id])
        guard !before.isNull else { return list[0] }
        let land = landing(before.size, at: p, page: page)
        if land.factor < 0.9995 { list = scaled(list, ids: [id], by: land.factor, about: before.origin) }
        let now = box(of: list, ids: [id])
        list = PageObjectEdit.move(list, ids: [id], dx: Double(land.rect.minX - now.minX), dy: Double(land.rect.minY - now.minY))
        return list[0]
    }

    // MARK: Waehrend des Ziehens

    /// Verschieben laeuft: Ist der Finger aus dem eigenen Dokument heraus, folgt ihm das Bild schwebend im Fenster; ueber
    /// einer beschreibbaren Seite des anderen Dokuments zeigt ein Rahmen, wo es landet.
    func hoverTransfer(_ g: UIPanGestureRecognizer, _ gr: Grab) {
        guard let object = transferable(gr), let c = controller, let window = c.view.window, let other = transferTarget(g) else {
            if transferView != nil { endTransferHover(gr) }
            return
        }
        let w = g.location(in: window)
        var frame: CGRect
        if other.writable, let (overlay, p) = other.objects.page(atWindowPoint: w) {
            let land = Self.landing(gr.box.size, at: p, page: Self.page(of: overlay)).rect
            frame = overlay.content.convert(land, to: nil)
            showTransferFrame(land, on: overlay)
        } else {
            let s = Self.screenScale(of: gr.overlay)
            frame = CGRect(x: w.x - gr.box.width * s / 2, y: w.y - gr.box.height * s / 2, width: gr.box.width * s, height: gr.box.height * s)
            transferFrame.removeFromSuperlayer()
        }
        let view = transferView ?? {
            let v = UIImageView()
            v.accessibilityIdentifier = Self.transferViewID
            v.isUserInteractionEnabled = false
            v.contentMode = .scaleToFill
            v.alpha = 0.92
            v.layer.shadowColor = UIColor.black.cgColor
            v.layer.shadowOpacity = 0.25
            v.layer.shadowRadius = 8
            v.layer.shadowOffset = CGSize(width: 0, height: 3)
            v.image = (object["src"]?.string).flatMap { c.store.images[$0] }
            v.backgroundColor = v.image == nil ? .secondarySystemFill : .clear
            transferView = v
            // das Bild im eigenen Dokument wird blass: es ist unterwegs
            gr.overlay.objectsView.setDimmed(gr.ids, true)
            return v
        }()
        if view.superview !== window { window.addSubview(view) }
        UIView.performWithoutAnimation { view.frame = frame }
    }

    private func showTransferFrame(_ rect: CGRect, on overlay: PageInkView) {
        let s = Self.screenScale(of: overlay)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transferFrame.name = Self.transferFrameName
        transferFrame.path = CGPath(roundedRect: rect.insetBy(dx: -Self.frameGap, dy: -Self.frameGap), cornerWidth: 4 / s, cornerHeight: 4 / s, transform: nil)
        transferFrame.lineWidth = 2 / s
        transferFrame.lineDashPattern = nil
        transferFrame.strokeColor = UIColor.systemBlue.cgColor
        transferFrame.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        if transferFrame.superlayer !== overlay.content.layer { overlay.content.layer.addSublayer(transferFrame) }
        CATransaction.commit()
    }

    /// Schwebendes Bild und Rahmen weg, die Vorschau im eigenen Dokument wieder deckend
    func endTransferHover(_ gr: Grab?) {
        transferFrame.removeFromSuperlayer()
        guard let view = transferView else { return }
        view.removeFromSuperview()
        transferView = nil
        if let gr { gr.overlay.objectsView.setDimmed(gr.ids, false) }
    }

    // MARK: Loslassen

    /// Loslassen beim Verschieben. `true`: Das andere Dokument war gemeint (das Bild geht hinueber, oder es bleibt mit
    /// Hinweis, wo es war). `false`: nicht ueber einer Seite des anderen Dokuments - der Aufrufer beendet das Verschieben
    /// im eigenen Dokument wie immer.
    func dropTransfer(_ g: UIPanGestureRecognizer, _ gr: Grab) -> Bool {
        guard let object = transferable(gr), let c = controller, let window = c.view.window, let other = transferTarget(g),
              let (overlay, p) = other.objects.page(atWindowPoint: g.location(in: window)) else {
            endTransferHover(gr)
            return false
        }
        guard other.writable else {
            cancelGrab()                                    // nichts verschieben: zurueck an seinen Platz (raeumt auch auf)
            Self.hint(Self.transferViewOnlyHint, c, other)
            return true
        }
        guard let taken = takeGrab() else { return false }
        transferring = true
        transferFrame.removeFromSuperlayer()
        let sourceKey = taken.overlay.pageKey, targetKey = overlay.pageKey, page = Self.page(of: overlay)
        Task {
            let moved = await transfer(object, from: sourceKey, to: other, key: targetKey, at: p, page: page)
            transferring = false
            endTransferHover(taken)
            if !moved {
                // bleibt in der Quelle, an seinem Platz
                taken.overlay.objectsView.previewMove(ids: taken.ids, by: .zero)
                drawSelection(await objects(sourceKey))
                Self.hint(other.writable ? Self.transferFailedHint : Self.transferViewOnlyHint, c, other)
            }
        }
        return true
    }

    /// Hinweise zeigt nur das Hauptdokument (es fuehrt die Leiste)
    private static func hint(_ text: String, _ a: PDFEditorController, _ b: PDFEditorController) {
        (a.ownsToolPicker ? a : b).onHint?(text)
    }

    /// Bild `object` von Seite `sourceKey` dieses Editors auf Seite `key` von `other`. Reihenfolge: eigenes Bild in der
    /// Zieldatei anlegen, Objekt im Ziel speichern, dann erst aus der Quelle entfernen; danach ein Schritt im Verlauf, das
    /// Bild ist im Ziel ausgewaehlt und dort wird weitergearbeitet. `false`: nichts wurde verschoben.
    func transfer(_ object: JSONValue, from sourceKey: String, to other: PDFEditorController, key: String, at p: CGPoint, page: CGRect) async -> Bool {
        guard let c = controller, c.writable, other.writable, other !== c,
              let src = object["src"]?.string, let id = object["id"]?.string else { return false }
        let listed = await objects(sourceKey)
        guard let index = listed.firstIndex(where: { $0["id"]?.string == id }) else { return false }
        let current = listed[index]
        let newSrc: String
        do { newSrc = try await other.store.adoptNoteImage(src, from: c.store) } catch { return false }
        let newID = PageOrder.uid()
        let placed = Self.transferred(current, id: newID, src: newSrc, to: p, page: page)
        guard await other.objects.commit(key, undoable: false, { $0 + [placed] }) else { return false }
        guard await commit(sourceKey, undoable: false, { PageObjectEdit.delete($0, ids: [id]) }) else {
            // die Quelle gibt das Bild nicht her: im Ziel wieder entfernen, sonst gaebe es zwei
            await other.objects.commit(key, undoable: false) { PageObjectEdit.delete($0, ids: [newID]) }
            return false
        }
        let step = ImageTransferStep(source: c, sourceKey: sourceKey, sourceObject: current, sourceIndex: index,
                                     target: other, targetKey: key, targetObject: placed)
        c.tools.transferSteps.append(step)
        step.register(undoing: true, in: c.editUndo)
        clearSelection()
        if !other.objects.isActive { other.choose(.select) }
        other.objects.select(key: key, ids: [newID], in: await other.objects.objects(key))
        return true
    }
}
