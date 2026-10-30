import PDFKit
import UIKit
import UniFlowCore

/// Objekt-Werkzeuge im Editor (Editor-Schritt 6, P1-4 bis P1-7): Werkzeugmodus "Objekte" neben der Tinte. Die Canvas
/// nimmt dann keine Eingabe an; Antippen waehlt aus oder legt an, Ziehen verschiebt, zwei Finger aendern die Groesse,
/// doppelt Antippen bearbeitet Text (mit dem Pencil per Scribble), das Lasso waehlt mehrere Objekte. Felder und
/// Regeln wie im Web-Editor (`PageObjectEdit`); gespeichert ueber `DocumentStore.editObjects`, Rueckgaengig ueber den
/// Verlauf des Dokuments.
@MainActor
final class ObjectEditing: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate {
    enum Tool: String, CaseIterable {
        case select, text, sticky, rect, ellipse, line, arrow, lasso, markup

        var label: String {
            switch self {
            case .select: return "Auswählen"
            case .text: return "Text"
            case .sticky: return "Haftnotiz"
            case .rect: return "Rechteck"
            case .ellipse: return "Ellipse"
            case .line: return "Linie"
            case .arrow: return "Pfeil"
            case .lasso: return "Lasso"
            case .markup: return "Text markieren"
            }
        }
        var systemImage: String {
            switch self {
            case .select: return "cursorarrow"
            case .text: return "textformat"
            case .sticky: return "note.text"
            case .rect: return "rectangle"
            case .ellipse: return "circle"
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            case .lasso: return "lasso"
            case .markup: return "highlighter"
            }
        }
        var shapeKind: String? { [.rect: "rect", .ellipse: "ellipse", .line: "line", .arrow: "arrow"][self] }
    }

    private weak var controller: PDFEditorController?
    private(set) var isActive = false
    var tool: Tool = .select {
        didSet {
            if tool != .select { clearSelection() }
            // Text markieren: die PDF-Ansicht waehlt Text selbst aus (Overlays lassen die Beruehrung durch)
            controller?.allOverlays.forEach { $0.isUserInteractionEnabled = tool != .markup }
            if tool != .markup { controller?.pdfView.clearSelection() }
        }
    }
    /// PDF-Text ist ausgewaehlt (Leiste zeigt Markieren/Unterstreichen/Durchstreichen)
    var onTextSelection: ((Bool) -> Void)?
    private var selectionObserver: NSObjectProtocol?
    var color = "#e5322d"
    var lineWidth = 2.0
    /// Auswahl (eine Seite)
    private(set) var selection: (key: String, ids: Set<String>)?
    var onSelectionChange: ((Int) -> Void)?

    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var doubleTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        g.numberOfTapsRequired = 2
        return g
    }()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private let selectionLayer = CAShapeLayer()
    private let draftLayer = CAShapeLayer()
    private var panStart: (overlay: PageInkView, point: CGPoint)?
    private var lassoPoints: [CGPoint] = []
    private var editing: (key: String, id: String, view: UITextView, isNew: Bool)?

    init(controller: PDFEditorController) {
        self.controller = controller
        super.init()
        for l in [selectionLayer, draftLayer] {
            l.fillColor = UIColor.clear.cgColor
            l.strokeColor = UIColor.systemBlue.cgColor
            l.lineDashPattern = [4, 3]
            l.lineWidth = 1
        }
        tap.require(toFail: doubleTap)
        [tap, doubleTap, pan, pinch].forEach { $0.delegate = self }
    }

    // MARK: Ein/aus

    func setActive(_ on: Bool) {
        guard let c = controller, on != isActive else { return }
        if on && !c.writable { return }
        isActive = on
        endTextEditing()
        clearSelection()
        for v in c.allOverlays { v.canvas.isUserInteractionEnabled = !on && c.writable }
        for g in [tap, doubleTap, pan, pinch] {
            if on { c.pdfView.addGestureRecognizer(g) } else { c.pdfView.removeGestureRecognizer(g) }
        }
        if on {
            selectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: c.pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onTextSelection?(self.tool == .markup && !(self.controller?.pdfView.currentSelection?.string ?? "").isEmpty)
                }
            }
        } else {
            if tool == .markup { tool = .select }
            if let o = selectionObserver { NotificationCenter.default.removeObserver(o) }
            selectionObserver = nil
            onTextSelection?(false)
        }
    }

    // MARK: PDF-Text markieren (P2-7, wie `addMarkup` im Web)

    /// Zeilen der Textauswahl je Seite in Punkten der angezeigten Seite
    func selectedLines() -> [String: [PageObjectEdit.Line]] {
        guard let c = controller, let sel = c.pdfView.currentSelection, let doc = c.pdfView.document else { return [:] }
        var out: [String: [PageObjectEdit.Line]] = [:]
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let i = doc.index(for: page)
                guard let key = c.store.layout?.key(at: i) else { continue }
                let r = line.bounds(for: page)
                guard r.width > 0, r.height > 0 else { continue }
                let crop = page.bounds(for: .cropBox)
                let t = SolutionGeometry.fromUnrotated(width: Double(crop.width), height: Double(crop.height), rotation: page.rotation)
                // Seitenraum (Ursprung unten links) -> ungedreht oben links -> angezeigte Seite
                let corners = [(r.minX, r.minY), (r.maxX, r.minY), (r.maxX, r.maxY), (r.minX, r.maxY)].map { p in
                    t.apply(x: Double(p.0 - crop.minX), y: Double(crop.maxY - p.1))
                }
                let up = (x: -t.c, y: -t.d)                                         // (0, -1) ohne Verschiebung
                out[key, default: []].append(PageObjectEdit.Line(
                    text: line.string ?? "", x0: corners.map(\.x).min()!, y0: corners.map(\.y).min()!,
                    x1: corners.map(\.x).max()!, y1: corners.map(\.y).max()!, up: up))
            }
        }
        return out
    }

    /// Auswahl als Markierung, Unterstreichung oder Durchstreichung speichern (ein Rueckgaengig je Seite)
    func applyMarkup(_ kind: PageObjectEdit.Markup, color: String = PageObjectEdit.markerColors[0]) {
        let lines = selectedLines()
        controller?.pdfView.clearSelection()
        onTextSelection?(false)
        for (key, l) in lines {
            let objs = PageObjectEdit.markup(kind, lines: l, color: color) { PageOrder.uid() }
            Task { await commit(key) { $0 + objs } }
        }
    }

    /// Neu angelegte Overlays im Objektmodus ohne Eingabe auf der Canvas
    func prepare(_ overlay: PageInkView) {
        if isActive { overlay.canvas.isUserInteractionEnabled = false }
    }

    // MARK: Treffer

    nonisolated private static func textHeight(_ o: JSONValue) -> Double {
        Double(ObjectGeometry.textSize(o, ObjectGeometry.attributedText(o)).height)
    }

    /// Overlay unter einem Punkt der PDF-Ansicht und der Punkt in Seitenpunkten
    private func locate(_ g: UIGestureRecognizer) -> (PageInkView, CGPoint)? {
        guard let c = controller else { return nil }
        for v in c.allOverlays where v.window != nil && !v.pageKey.isEmpty {
            let p = g.location(in: v)
            if v.bounds.contains(p) { return (v, p) }
        }
        return nil
    }

    private func objects(_ key: String) async -> [JSONValue] { await controller?.store.objects(forPageKey: key) ?? [] }

    // MARK: Gesten

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard isActive, tool != .markup else { return false }
        if g === pan {
            // Ziehen mit Form- oder Lassowerkzeug, oder auf der Auswahl; sonst scrollt die Ansicht
            if tool.shapeKind != nil || tool == .lasso { return true }
            guard let sel = selection, let (v, p) = locate(g), v.pageKey == sel.key else { return false }
            return selectionLayer.path?.boundingBoxOfPath.insetBy(dx: -12, dy: -12).contains(p) == true
        }
        if g === pinch { return selection != nil }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === tap || g === doubleTap
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let (v, p) = locate(g) else { clearSelection(); return }
        endTextEditing()
        let key = v.pageKey
        switch tool {
        case .text, .sticky:
            let id = PageOrder.uid()
            let o = tool == .text ? PageObjectEdit.text(id: id, x: Double(p.x), y: Double(p.y))
                                  : PageObjectEdit.sticky(id: id, x: Double(p.x), y: Double(p.y))
            Task {
                await commit(key) { $0 + [o] }
                beginTextEditing(key: key, id: id, isNew: true)
            }
        default:
            Task {
                let list = await objects(key)
                if let id = PageObjectEdit.hit(list, x: Double(p.x), y: Double(p.y), textHeight: Self.textHeight) {
                    select(key: key, ids: [id], in: list)
                } else {
                    clearSelection()
                }
            }
        }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let (v, p) = locate(g) else { return }
        Task {
            let list = await objects(v.pageKey)
            guard let id = PageObjectEdit.hit(list, x: Double(p.x), y: Double(p.y), textHeight: Self.textHeight),
                  list.first(where: { $0["id"]?.string == id })?["type"]?.string == "text" else { return }
            beginTextEditing(key: v.pageKey, id: id, isNew: false)
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            guard let (v, p) = locate(g) else { g.state = .cancelled; return }
            panStart = (v, p)
            lassoPoints = [p]
            if tool.shapeKind != nil || tool == .lasso { v.layer.addSublayer(draftLayer) }
        case .changed:
            guard let start = panStart else { return }
            let p = g.location(in: start.overlay)
            if let kind = tool.shapeKind {
                let path = CGMutablePath()
                if kind == "line" || kind == "arrow" { path.move(to: start.point); path.addLine(to: p) }
                else if kind == "ellipse" { path.addEllipse(in: rect(start.point, p)) }
                else { path.addRect(rect(start.point, p)) }
                draftLayer.path = path
            } else if tool == .lasso {
                lassoPoints.append(p)
                let path = CGMutablePath()
                path.addLines(between: lassoPoints)
                draftLayer.path = path
            } else {
                let d = g.translation(in: start.overlay)
                selectionLayer.setAffineTransform(CGAffineTransform(translationX: d.x, y: d.y))
            }
        case .ended:
            guard let start = panStart else { return }
            panStart = nil
            draftLayer.removeFromSuperlayer()
            draftLayer.path = nil
            let key = start.overlay.pageKey
            let p = g.location(in: start.overlay)
            if let kind = tool.shapeKind {
                guard hypot(p.x - start.point.x, p.y - start.point.y) > 4,
                      let o = PageObjectEdit.shape(id: PageOrder.uid(), kind: kind, from: (Double(start.point.x), Double(start.point.y)),
                                                   to: (Double(p.x), Double(p.y)), color: color, width: lineWidth) else { return }
                Task { await commit(key) { $0 + [o] } }
            } else if tool == .lasso {
                let poly = lassoPoints.map { (x: Double($0.x), y: Double($0.y)) }
                lassoPoints = []
                Task {
                    let list = await objects(key)
                    let ids = PageObjectEdit.inLasso(list, polygon: poly, textHeight: Self.textHeight)
                    if ids.isEmpty { clearSelection() } else { tool = .select; select(key: key, ids: Set(ids), in: list) }
                }
            } else if let sel = selection {
                selectionLayer.setAffineTransform(.identity)
                let d = g.translation(in: start.overlay)
                guard abs(d.x) + abs(d.y) > 0.5 else { return }
                Task { await commit(sel.key) { PageObjectEdit.move($0, ids: sel.ids, dx: Double(d.x), dy: Double(d.y)) } }
            }
        default:
            panStart = nil
            draftLayer.removeFromSuperlayer()
            selectionLayer.setAffineTransform(.identity)
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let sel = selection else { return }
        switch g.state {
        case .changed:
            let b = selectionLayer.path?.boundingBoxOfPath ?? .zero
            selectionLayer.setAffineTransform(CGAffineTransform(translationX: b.minX, y: b.minY).scaledBy(x: g.scale, y: g.scale)
                .translatedBy(x: -b.minX, y: -b.minY))
        case .ended:
            selectionLayer.setAffineTransform(.identity)
            let f = Double(g.scale)
            guard abs(f - 1) > 0.02 else { return }
            Task { await commit(sel.key) { PageObjectEdit.scale($0, ids: sel.ids, factorX: f, factorY: f) } }
        default:
            selectionLayer.setAffineTransform(.identity)
        }
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: Auswahl

    private func select(key: String, ids: Set<String>, in list: [JSONValue]) {
        selection = (key, ids)
        drawSelection(list)
        onSelectionChange?(ids.count)
    }

    func clearSelection() {
        selection = nil
        selectionLayer.removeFromSuperlayer()
        selectionLayer.path = nil
        onSelectionChange?(0)
    }

    private func drawSelection(_ list: [JSONValue]) {
        guard let sel = selection, let overlay = controller?.boundOverlay(forKey: sel.key) else { selectionLayer.removeFromSuperlayer(); return }
        var box = CGRect.null
        for o in list where (o["id"]?.string).map(sel.ids.contains) == true {
            if let b = PageObjectEdit.bounds(o, textHeight: Self.textHeight) {
                box = box.union(CGRect(x: b.minX, y: b.minY, width: b.maxX - b.minX, height: b.maxY - b.minY))
            }
        }
        guard !box.isNull else { clearSelection(); return }
        selectionLayer.path = CGPath(rect: box.insetBy(dx: -4, dy: -4), transform: nil)
        if selectionLayer.superlayer !== overlay.layer { overlay.layer.addSublayer(selectionLayer) }
    }

    // MARK: Aktionen auf der Auswahl (Leiste im Objektmodus)

    func deleteSelection() {
        guard let sel = selection else { return }
        clearSelection()
        Task { await commit(sel.key) { PageObjectEdit.delete($0, ids: sel.ids) } }
    }

    /// Farbe der Auswahl: Text `fill`, Haftnotiz `bg`, Formen `stroke`
    func recolorSelection(_ hex: String) {
        color = hex
        guard let sel = selection else { return }
        Task {
            await commit(sel.key) { list in
                list.map { o in
                    guard let id = o["id"]?.string, sel.ids.contains(id), var obj = o.object else { return o }
                    if o["type"]?.string == "text" { obj[(o["bg"]?.string ?? "").isEmpty ? "fill" : "bg"] = .string(hex) }
                    else if o["type"]?.string == "shape" { obj[o["markup"]?.string == "highlight" ? "fill" : "stroke"] = .string(hex) }
                    return .object(obj)
                }
            }
        }
    }

    /// Schrift der ausgewaehlten Textfelder groesser/kleiner
    func resizeText(by delta: Double) {
        guard let sel = selection else { return }
        Task {
            await commit(sel.key) { list in
                list.map { o in
                    guard let id = o["id"]?.string, sel.ids.contains(id), o["type"]?.string == "text", var obj = o.object else { return o }
                    obj["fontSize"] = .number(min(200, max(6, (o["fontSize"]?.double ?? 14) + delta)))
                    return .object(obj)
                }
            }
        }
    }

    // MARK: Text bearbeiten (UITextView: Tastatur oder Scribble mit dem Pencil)

    private func beginTextEditing(key: String, id: String, isNew: Bool) {
        guard let overlay = controller?.boundOverlay(forKey: key) else { return }
        Task {
            guard let o = await objects(key).first(where: { $0["id"]?.string == id }) else { return }
            let size = ObjectGeometry.textSize(o, ObjectGeometry.attributedText(o))
            let view = UITextView(frame: CGRect(x: o["x"]?.double ?? 0, y: o["y"]?.double ?? 0, width: size.width, height: max(size.height, 28)))
            view.attributedText = ObjectGeometry.attributedText(o)
            view.typingAttributes = ObjectGeometry.attributedText(PageObjectEdit.set([o], ids: [id], "text", "x").first ?? o)
                .attributes(at: 0, effectiveRange: nil)
            view.backgroundColor = (o["bg"]?.string).flatMap { UIColor(hex: $0) } ?? UIColor.white.withAlphaComponent(0.9)
            view.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            view.textContainer.lineFragmentPadding = 0
            view.layer.borderColor = UIColor.systemBlue.cgColor
            view.layer.borderWidth = 1
            view.transform = CGAffineTransform(rotationAngle: CGFloat((o["rotation"]?.double ?? 0) * .pi / 180))
            view.delegate = self
            view.accessibilityIdentifier = "objects.textEditor"
            overlay.addSubview(view)
            editing = (key, id, view, isNew)
            view.becomeFirstResponder()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) { endTextEditing() }

    func textViewDidChange(_ textView: UITextView) {
        let fit = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
        textView.frame.size.height = max(28, fit.height)
    }

    /// Bearbeiten beenden: Text speichern; ein neues, leer gebliebenes Feld wird wieder entfernt
    func endTextEditing() {
        guard let e = editing else { return }
        editing = nil
        let text = e.view.text ?? ""
        e.view.delegate = nil
        e.view.removeFromSuperview()
        Task {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && e.isNew {
                await commit(e.key, undoable: false) { PageObjectEdit.delete($0, ids: [e.id]) }
            } else {
                await commit(e.key) { PageObjectEdit.set($0, ids: [e.id], "text", .string(text)) }
            }
        }
    }

    // MARK: Speichern mit Rueckgaengig

    private func commit(_ key: String, undoable: Bool = true, _ change: @escaping ([JSONValue]) -> [JSONValue]) async {
        guard let c = controller, c.writable else { return }
        guard let before = await c.store.editObjects(pageKey: key, change) else { return }
        let after = await objects(key)
        if undoable { registerUndo(key: key, restore: before, then: after) }
        if let sel = selection, sel.key == key { drawSelection(after) }
    }

    /// Rueckgaengig stellt `restore` her. Der Gegenschritt (Wiederholen: `then`) wird sofort im Handler angemeldet:
    /// erst nach einem `await` angemeldet, zaehlte er beim UndoManager als neuer Rueckgaengig-Schritt.
    private func registerUndo(key: String, restore: [JSONValue], then redo: [JSONValue]) {
        guard let c = controller else { return }
        c.editUndo.registerUndo(withTarget: self) { me in
            me.registerUndo(key: key, restore: redo, then: restore)
            me.clearSelection()
            Task { @MainActor in _ = await me.controller?.store.editObjects(pageKey: key) { _ in restore } }
        }
        c.editUndo.setActionName("Objekte")
    }

    // MARK: Fuer Tests

    var editingTextView: UITextView? { editing?.view }
    func selectForTesting(key: String, ids: Set<String>) async { select(key: key, ids: ids, in: await objects(key)) }
}
