import PDFKit
import PencilKit
import UIKit
import UniFlowCore

// Maus, Trackpad und Tastatur im Dokument (10.11.2026, docs/EDITOR-VERBESSERUNGEN-2026-11-10.md):
// - Rechtsklick (Mac) auf eine Seite: Text oder Haftnotiz hier, Einfuegen, Bild einfuegen, Seite einfuegen/drehen, KI;
//   auf ein Objekt oder einen Strich: Ausschneiden, Kopieren, Duplizieren, Loeschen, Reihenfolge, Groesse.
// - Ziehen und Ablegen von Bildern (Finder, Fotos, andere Apps) auf eine Seite (iPad und Mac).
// - Mauszeiger je Werkzeug (Textcursor fuer Text, Fadenkreuz fuer Formen und Bereiche).
// - Bearbeiten-Menue und Cmd-C/X/V/D, Entf: auf der Auswahl im Dokument.

@MainActor
final class EditorMouseSupport: NSObject, UIContextMenuInteractionDelegate, UIDropInteractionDelegate, UIPointerInteractionDelegate {
    private weak var controller: PDFEditorController?
    private(set) var contextMenu: UIContextMenuInteraction?

    init(controller: PDFEditorController) {
        self.controller = controller
        super.init()
    }

    func install(on view: UIView) {
        // Kontextmenue nur am Mac (Rechtsklick); am iPad gehoert das lange Druecken der Textauswahl und den Objekten
        if PDFEditorController.isMac {
            let menu = UIContextMenuInteraction(delegate: self)
            view.addInteraction(menu)
            contextMenu = menu
        }
        view.addInteraction(UIDropInteraction(delegate: self))
        view.addInteraction(UIPointerInteraction(delegate: self))
    }

    /// Mac: Die Zeichenflaeche von PencilKit bringt ein eigenes Rechtsklick-Menue mit ("Alles auswählen", "Leerzeile
    /// einfügen", gemessen 11.11.2026), das unseres verdeckte. Am Mac tritt unseres an seine Stelle: dieselbe Ansicht,
    /// die das Menue von PencilKit traegt, bekommt unsere Interaktion. Nur der Mac; am iPad bleibt alles, wie es ist.
    func adoptContextMenu(of canvas: UIView) {
        func walk(_ v: UIView) {
            let bridged = v.interactions.filter { String(describing: type(of: $0)).contains("BridgedContextMenu") }
            if !bridged.isEmpty {
                bridged.forEach { v.removeInteraction($0) }
                if !v.interactions.contains(where: { ($0 as? UIContextMenuInteraction)?.delegate === self }) {
                    v.addInteraction(UIContextMenuInteraction(delegate: self))
                }
            }
            v.subviews.forEach(walk)
        }
        walk(canvas)
    }

    /// Unser Kontextmenue an einer Ansicht (einmal)
    func ensureContextMenu(on view: UIView) {
        guard !view.interactions.contains(where: { ($0 as? UIContextMenuInteraction)?.delegate === self }) else { return }
        view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    /// Seite und Punkt in Seitenpunkten unter einem Punkt der PDF-Ansicht
    func locate(_ point: CGPoint, in view: UIView) -> (PageInkView, CGPoint)? {
        guard let c = controller else { return nil }
        for v in c.allOverlays where v.window != nil && !v.pageKey.isEmpty {
            let p = view.convert(point, to: v.content)
            if v.content.bounds.contains(p) { return (v, p) }
        }
        return nil
    }

    // MARK: Kontextmenue

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let c = controller, let view = interaction.view, c.freezeMode == .off,
              let (overlay, p) = locate(location, in: view) else { return nil }
        let menu = self.menu(on: overlay, at: p)
        guard !menu.children.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    /// Eintraege des Kontextmenues an einer Stelle (auch fuer Tests)
    func menu(on overlay: PageInkView, at p: CGPoint) -> UIMenu {
        guard let c = controller else { return UIMenu(children: []) }
        let objects = c.objects
        let key = overlay.pageKey
        var groups: [[UIMenuElement]] = []
        let hit: (objectID: String?, inkIndex: Int?) = c.writable ? objects.hitNow(on: overlay, at: p) : (nil, nil)
        if hit.objectID != nil || hit.inkIndex != nil || (objects.selectedKey == key && objects.hasSelection) {
            objects.selectHit(on: overlay, objectID: hit.objectID, inkIndex: hit.inkIndex)
            groups.append([
                UIAction(title: "Ausschneiden", image: UIImage(systemName: "scissors")) { _ in Task { await objects.cutSelection() } },
                UIAction(title: "Kopieren", image: UIImage(systemName: "doc.on.doc")) { _ in Task { await objects.copySelection() } },
                UIAction(title: "Duplizieren", image: UIImage(systemName: "plus.square.on.square")) { _ in Task { await objects.duplicateSelection() } },
                UIAction(title: "Löschen", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in objects.deleteSelection() },
            ])
            var arrange: [UIMenuElement] = [
                UIAction(title: "Größer", image: UIImage(systemName: "plus.magnifyingglass")) { _ in objects.scaleSelection(by: 1.25) },
                UIAction(title: "Kleiner", image: UIImage(systemName: "minus.magnifyingglass")) { _ in objects.scaleSelection(by: 0.8) },
            ]
            if objects.selection != nil {
                arrange += [
                    UIAction(title: "Nach vorne", image: UIImage(systemName: "square.2.layers.3d.top.filled")) { _ in objects.reorderSelection(toFront: true) },
                    UIAction(title: "Nach hinten", image: UIImage(systemName: "square.2.layers.3d.bottom.filled")) { _ in objects.reorderSelection(toFront: false) },
                ]
            }
            groups.append(arrange)
        } else if c.writable {
            groups.append([
                UIAction(title: "Text hier", image: UIImage(systemName: "textformat")) { [weak c] _ in c?.addText(on: key, at: p, sticky: false) },
                UIAction(title: "Haftnotiz hier", image: UIImage(systemName: "note.text")) { [weak c] _ in c?.addText(on: key, at: p, sticky: true) },
                UIAction(title: "Einfügen", image: UIImage(systemName: "doc.on.clipboard"),
                         attributes: Self.pasteboardHasContent ? [] : .disabled) { _ in Task { await objects.paste(on: key, at: p) } },
                UIAction(title: "Bild einfügen …", image: UIImage(systemName: "photo")) { [weak c] _ in c?.onRequestImage?(false) },
            ])
            groups.append([
                UIAction(title: "Leere Seite danach", image: UIImage(systemName: "doc.badge.plus")) { [weak c] _ in
                    Task { _ = await c?.insertBlankPage(after: key) }
                },
                UIAction(title: "Seite drehen", image: UIImage(systemName: "rotate.right")) { [weak c] _ in
                    Task { await c?.store.rotatePage(key: key) }
                },
            ])
        }
        if c.onAskAI != nil {
            groups.append([
                UIAction(title: "Bereich an KI …", image: UIImage(systemName: "rectangle.dashed")) { [weak c] _ in c?.startAreaCapture() },
                UIAction(title: "Ganze Seite an KI", image: UIImage(systemName: "doc.viewfinder")) { [weak c] _ in c?.sendVisiblePage() },
            ])
        }
        return UIMenu(children: groups.map { UIMenu(options: .displayInline, children: $0) })
    }

    static var pasteboardHasContent: Bool {
        let pb = UIPasteboard.general
        return pb.contains(pasteboardTypes: [ObjectEditing.objectsPasteboardType, ObjectEditing.inkPasteboardType]) || pb.hasImages || pb.hasStrings
    }

    // MARK: Ziehen und Ablegen (Bilder)

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        (controller?.writable ?? false) && session.canLoadObjects(ofClass: UIImage.self)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let view = interaction.view, locate(session.location(in: view), in: view) != nil else { return UIDropProposal(operation: .forbidden) }
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let view = interaction.view, let (overlay, p) = locate(session.location(in: view), in: view) else { return }
        let key = overlay.pageKey
        _ = session.loadObjects(ofClass: UIImage.self) { [weak self] items in
            let images = items.compactMap { $0 as? UIImage }
            Task { @MainActor in
                guard let objects = self?.controller?.objects else { return }
                for (i, image) in images.prefix(10).enumerated() {
                    let offset = CGFloat(i) * CGFloat(ObjectEditing.pasteOffset)
                    await objects.insertImage(image, on: key, at: CGPoint(x: p.x + offset, y: p.y + offset))
                }
            }
        }
    }

    // MARK: Mauszeiger

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        // Kennung je Zeiger: wechselt das Werkzeug, fragt UIKit den Zeiger neu ab
        Self.cursor(for: controller).map { UIPointerRegion(rect: defaultRegion.rect, identifier: "\($0)" as NSString) }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        switch Self.cursor(for: controller) {
        case .beam: return UIPointerStyle(shape: .verticalBeam(length: 22), constrainedAxes: [])
        case .cross:
            return UIPointerStyle(shape: .path(UIBezierPath(rect: CGRect(x: 8, y: 0, width: 2, height: 18)).appending(
                UIBezierPath(rect: CGRect(x: 0, y: 8, width: 18, height: 2)))), constrainedAxes: [])
        case .circle:
            return UIPointerStyle(shape: .path(UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 16, height: 16))), constrainedAxes: [])
        case nil: return nil
        }
    }

    enum Cursor: Equatable { case beam, cross, circle }

    /// Zeiger zum Werkzeug: Text = Textcursor, Formen/Lasso/Bereich = Fadenkreuz, Radierer (Maus schreibt) = Kreis
    static func cursor(for c: PDFEditorController?) -> Cursor? {
        guard let c, c.freezeMode == .off else { return nil }
        if c.objects.isActive {
            switch c.objects.tool {
            case .text, .sticky: return .beam
            case .rect, .ellipse, .line, .arrow, .lasso, .area: return .cross
            default: return nil
            }
        }
        guard !c.effectivePencilOnly, c.writable else { return nil }
        return c.tools.tool == .eraser ? .circle : nil
    }
}

private extension UIBezierPath {
    func appending(_ other: UIBezierPath) -> UIBezierPath {
        append(other)
        return self
    }
}

extension PDFEditorController {
    /// Textfeld oder Haftnotiz an einer Stelle anlegen und gleich bearbeiten (Kontextmenue)
    func addText(on key: String, at p: CGPoint, sticky: Bool) {
        guard writable else { return }
        choose(.select)
        let id = PageOrder.uid()
        let o = sticky ? PageObjectEdit.sticky(id: id, x: Double(p.x), y: Double(p.y)) : PageObjectEdit.text(id: id, x: Double(p.x), y: Double(p.y))
        Task {
            await objects.commit(key) { $0 + [o] }
            objects.beginTextEditing(key: key, id: id, isNew: true)
        }
    }

    // MARK: Bearbeiten-Menue (Cmd-C/X/V/D, Entf) auf der Auswahl

    /// Seite, auf die eingefuegt wird: Seite der Auswahl, sonst die aktuelle
    var pasteTargetKey: String? { objects.selectedKey ?? currentPageKey }

    func canPerformEditAction(_ action: Selector) -> Bool? {
        switch action {
        case #selector(copy(_:)): return acceptsEditorKeys && objects.hasSelection
        case #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)):
            return acceptsEditorKeys && writable && objects.hasSelection
        case #selector(paste(_:)):
            return acceptsEditorKeys && writable && pasteTargetKey != nil && EditorMouseSupport.pasteboardHasContent
        default: return nil
        }
    }

    override func copy(_ sender: Any?) { Task { await objects.copySelection() } }
    override func cut(_ sender: Any?) { Task { await objects.cutSelection() } }
    override func delete(_ sender: Any?) { objects.deleteSelection() }
    override func duplicate(_ sender: Any?) { Task { await objects.duplicateSelection() } }
    override func paste(_ sender: Any?) {
        guard let key = pasteTargetKey else { return }
        Task { await objects.paste(on: key) }
    }
}
