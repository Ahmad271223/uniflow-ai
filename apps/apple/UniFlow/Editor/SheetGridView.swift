import Combine
import UIKit
import UniFlowCore

/// Gitter der grossen Tabellen-Ansicht: zeichnet nur, was im Fenster liegt (Zellen, Kopf mit A B C und 1 2 3, Auswahl),
/// auch bei 500 Zeilen. Rollen und Zoomen mit den Fingern; Antippen waehlt, Doppeltipp tippt, die zwei Punkte an der
/// Auswahl ziehen sie groesser; im Kopf am Rand einer Spalte oder Zeile ziehen aendert ihre Groesse. Mit Tastatur:
/// Pfeile, Eingabe, Tab, Entf, einfach lostippen.
final class SheetGridView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    static let headerWidth: CGFloat = 46
    static let headerHeight: CGFloat = 30
    static let zoomRange: ClosedRange<CGFloat> = 0.8...3
    static let accent = UIColor(hex: "#4f5bd5") ?? .systemBlue
    static let background = UIColor(hex: "#e9ecf2") ?? .systemGray5
    static let headFont = UIFont.systemFont(ofSize: 12, weight: .medium)

    let model: SheetEditorModel
    let scroll = UIScrollView()
    private let canvas = Canvas()
    private(set) var zoom: CGFloat
    private(set) var grid: SheetRender.Grid
    private var hiddenRows: Set<Int>
    private let cache = SheetRender.Cache()
    private var shownRevision = -1
    private var shownSelection: SheetRange?
    private var watch: AnyCancellable?
    private var reloadQueued = false

    private enum Target: Equatable {
        case cell(SheetRef), colHeader(Int), rowHeader(Int), colEdge(Int), rowEdge(Int), handle(end: Bool), corner, none
    }
    private var drag: Target = .none
    private var dragStartSize: CGFloat = 0
    private var dragBegan = false
    private var lastTouchIsPointer = false
    private var pinchStart: CGFloat = 1
    private var long: UILongPressGestureRecognizer?
    /// Unten frei halten: Dort liegen die Hinweise (KI arbeitet, Meldungen) ueber dem Gitter
    static let bottomReserve: CGFloat = 40
    /// Zweiter Tipp auf dieselbe Zelle kurz danach = Doppeltipp (ohne dass der erste Tipp darauf warten muss)
    private var lastTap: (ref: SheetRef, time: TimeInterval)?
    static let doubleTapTime: TimeInterval = 0.4
    private var laidOutSize = CGSize.zero
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var headLines: [String: SheetRender.Line] = [:]
    private static let funnel = UIImage(systemName: "line.3.horizontal.decrease.circle.fill")?.withTintColor(accent, renderingMode: .alwaysOriginal)
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))

    private final class Canvas: UIView {
        var render: ((CGContext, CGRect) -> Void)?
        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            render?(ctx, bounds)
        }
    }

    init(model: SheetEditorModel) {
        self.model = model
        zoom = UIDevice.current.userInterfaceIdiom == .phone ? 1.25 : 1.45
        hiddenRows = model.hidden
        grid = SheetRender.Grid(model.sheet, hidden: hiddenRows)
        super.init(frame: .zero)
        backgroundColor = Self.background
        overrideUserInterfaceStyle = .light            // Papier: wie auf der Seite
        canvas.isOpaque = true
        canvas.backgroundColor = Self.background
        canvas.contentMode = .redraw
        canvas.isUserInteractionEnabled = false
        canvas.render = { [weak self] ctx, bounds in self?.draw(in: ctx, bounds: bounds) }
        scroll.delegate = self
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = true
        scroll.alwaysBounceHorizontal = true
        scroll.keyboardDismissMode = .none
        addSubview(canvas)
        addSubview(scroll)

        // ein Erkenner fuer Tipp und Doppeltipp: Der einfache Tipp wirkt sofort, statt die Doppeltipp-Frist abzuwarten
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        long.minimumPressDuration = 0.45
        long.delegate = self
        self.long = long
        let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryClicked(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addInteraction(editMenu)
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = []
        scroll.panGestureRecognizer.require(toFail: pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for g in [tap, long, secondary, pan, pinch] as [UIGestureRecognizer] { scroll.addGestureRecognizer(g) }
        accessibilityIdentifier = "sheet.grid"
        isAccessibilityElement = false

        watch = model.objectWillChange.sink { [weak self] _ in self?.queueReload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        scroll.frame = bounds
        updateContentSize()
        // die Tastatur ist aufgegangen (oder das Geraet gedreht): Die Zelle, in der getippt wird, bleibt im Bild
        if bounds.size != laidOutSize {
            let shrunk = bounds.height < laidOutSize.height
            laidOutSize = bounds.size
            if shrunk || model.isEditing { reveal(model.active) }
        }
        canvas.setNeedsDisplay()
    }

    private func queueReload() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadQueued = false
            self?.reload()
        }
    }

    /// Nach jeder Aenderung des Modells: Lage der Zeilen und Spalten, Auswahl ins Bild, neu zeichnen
    func reload() {
        if model.revision != shownRevision {
            shownRevision = model.revision
            hiddenRows = model.hidden
            grid = SheetRender.Grid(model.sheet, hidden: hiddenRows)
            cache.lines = [:]
            updateContentSize()
        }
        if model.selection != shownSelection {
            shownSelection = model.selection
            // ganze Spalte, Zeile oder alles gewaehlt: nicht ans Ende springen
            let sel = model.selection, s = model.sheet
            reveal(model.corner, horizontal: !(sel.cols.count == s.cols && s.cols > 1), vertical: !(sel.rows.count == s.rows && s.rows > 1))
        }
        // mit Tastatur: Pfeile und Lostippen gehen an das Gitter, solange nicht im Eingabefeld getippt wird - und
        // kein Dialog (KI-Wunsch, Titel) gerade die Tastatur hat
        if !model.isEditing, !model.dialogOpen, window != nil, !isFirstResponder { becomeFirstResponder() }
        canvas.setNeedsDisplay()
    }

    private func updateContentSize() {
        let size = CGSize(width: Self.headerWidth + grid.size.width * zoom + 140, height: Self.headerHeight + grid.size.height * zoom + 180 + Self.bottomReserve)
        if scroll.contentSize != size { scroll.contentSize = size }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { canvas.setNeedsDisplay() }

    // MARK: Lage

    private var offset: CGPoint { scroll.contentOffset }

    /// Punkt der Ansicht → Punkt der Tabelle
    private func tablePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - Self.headerWidth + offset.x) / zoom, y: (p.y - Self.headerHeight + offset.y) / zoom)
    }

    /// Rechteck der Tabelle → Rechteck der Ansicht
    func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: Self.headerWidth + r.minX * zoom - offset.x, y: Self.headerHeight + r.minY * zoom - offset.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// Mitte einer Zelle in der Ansicht (Tests)
    func center(of r: SheetRef) -> CGPoint {
        let v = viewRect(grid.rect(r))
        return CGPoint(x: v.midX, y: v.midY)
    }

    private func reveal(_ r: SheetRef, horizontal: Bool = true, vertical: Bool = true) {
        guard bounds.width > 0, horizontal || vertical else { return }
        let c = grid.rect(r)
        guard !c.isNull else { return }
        let cr = CGRect(x: Self.headerWidth + c.minX * zoom, y: Self.headerHeight + c.minY * zoom, width: c.width * zoom, height: c.height * zoom)
        var off = offset
        if horizontal {
            if cr.minX < off.x + Self.headerWidth { off.x = cr.minX - Self.headerWidth } else if cr.maxX > off.x + bounds.width { off.x = cr.maxX - bounds.width + 8 }
        }
        if vertical {
            let bottom = bounds.height - Self.bottomReserve
            if cr.minY < off.y + Self.headerHeight { off.y = cr.minY - Self.headerHeight } else if cr.maxY > off.y + bottom { off.y = cr.maxY - bottom + 8 }
        }
        off.x = max(0, off.x)
        off.y = max(0, off.y)
        if off != offset { scroll.setContentOffset(off, animated: false) }
    }

    private func handlePoints() -> (start: CGPoint, end: CGPoint) {
        let v = viewRect(grid.rect(model.selection))
        return (CGPoint(x: v.minX, y: v.minY), CGPoint(x: v.maxX, y: v.maxY))
    }

    private func target(at p: CGPoint, forDrag: Bool) -> Target {
        let hw = Self.headerWidth, hh = Self.headerHeight
        if forDrag, !model.isEditing {
            let h = handlePoints()
            if hypot(p.x - h.end.x, p.y - h.end.y) < 24 { return .handle(end: true) }
            if hypot(p.x - h.start.x, p.y - h.start.y) < 24 { return .handle(end: false) }
        }
        let t = tablePoint(p)
        if p.x < hw, p.y < hh { return .corner }
        if p.y < hh {
            if forDrag {
                for c in 0..<grid.cols where abs(grid.colX[c + 1] - t.x) * zoom < 14 { return .colEdge(c) }
                return .none
            }
            return grid.col(at: t.x).map(Target.colHeader) ?? .none
        }
        if p.x < hw {
            if forDrag {
                for r in 0..<grid.rows where !hiddenRows.contains(r) && abs(grid.rowY[r + 1] - t.y) * zoom < 12 { return .rowEdge(r) }
                return .none
            }
            return grid.row(at: t.y).map(Target.rowHeader) ?? .none
        }
        guard let col = grid.col(at: t.x), let row = grid.row(at: t.y) else { return .none }
        return .cell(SheetRef(col: col, row: row))
    }

    // MARK: Beruehrungen

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        lastTouchIsPointer = touch.type == .indirectPointer
        return true
    }

    /// Das Menue (langes Druecken) nimmt dem Ziehen nichts: Wer einen Auswahlpunkt oder Spaltenrand haelt und dann
    /// zieht, zieht; gerollt wird weiter wie immer (zweite Durchsicht 26.11.2026)
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === long || other === long
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === long {
            let p = g.location(in: self)
            switch target(at: p, forDrag: true) {
            case .handle, .colEdge, .rowEdge: return false
            default: break
            }
            if case .cell = target(at: p, forDrag: false) { return true }
            return false
        }
        guard g === pan else { return true }
        let start = pan.location(in: self)
        let t = pan.translation(in: self)
        drag = target(at: CGPoint(x: start.x - t.x, y: start.y - t.y), forDrag: true)
        switch drag {
        case .handle, .colEdge, .rowEdge: return true
        default:
            // mit der Maus: ueber Zellen ziehen waehlt einen Bereich
            if lastTouchIsPointer, case .cell = target(at: CGPoint(x: start.x - t.x, y: start.y - t.y), forDrag: false) {
                drag = target(at: CGPoint(x: start.x - t.x, y: start.y - t.y), forDrag: false)
                return true
            }
            drag = .none
            return false
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        let shift = g.modifierFlags.contains(.shift)
        switch target(at: p, forDrag: false) {
        case .cell(let r):
            if model.isFormulaEditing, r != model.active { lastTap = nil; model.insertReference(r); return }
            let now = ProcessInfo.processInfo.systemUptime
            if let l = lastTap, l.ref == r, now - l.time < Self.doubleTapTime, !shift {
                lastTap = nil
                beginEditing(at: r)
                return
            }
            lastTap = (r, now)
            model.commitEditing()
            model.select(r, extend: shift)
        case .colHeader(let c):
            model.commitEditing()
            model.selectColumn(c, extend: shift)
        case .rowHeader(let r):
            model.commitEditing()
            model.selectRow(r, extend: shift)
        case .corner:
            model.commitEditing()
            model.select(model.sheet.bounds)
        default:
            model.commitEditing()
        }
    }

    private func beginEditing(at r: SheetRef) {
        model.commitEditing()
        model.select(r)
        model.beginEditing()
    }

    // MARK: Menue an der Zelle (langes Druecken, Rechtsklick)

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { showMenu(at: g.location(in: self)) }
    }

    @objc private func secondaryClicked(_ g: UITapGestureRecognizer) { showMenu(at: g.location(in: self)) }

    private func showMenu(at p: CGPoint) {
        guard case .cell(let r) = target(at: p, forDrag: false) else { return }
        if !model.selection.contains(r) {
            model.commitEditing()
            model.select(r)
        }
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: p))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let m = model
        var items = [UIAction(title: "Kopieren", image: UIImage(systemName: "doc.on.doc")) { _ in m.copy() }]
        if !m.readOnly {
            items.insert(UIAction(title: "Ausschneiden", image: UIImage(systemName: "scissors")) { _ in m.cut() }, at: 0)
            items.append(UIAction(title: "Einfügen", image: UIImage(systemName: "doc.on.clipboard")) { _ in m.paste() })
            items.append(UIAction(title: "Inhalt löschen", image: UIImage(systemName: "delete.left"), attributes: .destructive) { _ in m.clearContents() })
        }
        return UIMenu(children: items)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        let t = tablePoint(p)
        switch g.state {
        case .began:
            dragBegan = true
            switch drag {
            case .handle(let end):
                // das andere Ende bleibt stehen
                let sel = model.selection
                model.select(end ? sel.from : sel.to)
                model.select(end ? sel.to : sel.from, extend: true)
            case .colEdge(let c): dragStartSize = grid.colX[c + 1] - grid.colX[c]
            case .rowEdge(let r): dragStartSize = grid.rowY[r + 1] - grid.rowY[r]
            case .cell(let r):
                model.commitEditing()
                model.select(r)
            default: break
            }
            fallthrough
        case .changed:
            switch drag {
            case .handle, .cell: model.select(grid.nearest(t), extend: true)
            case .colEdge(let c):
                if model.resizeLive(col: c, row: nil, to: Double(dragStartSize + g.translation(in: self).x / zoom), begin: dragBegan) { dragBegan = false }
            case .rowEdge(let r):
                if model.resizeLive(col: nil, row: r, to: Double(dragStartSize + g.translation(in: self).y / zoom), begin: dragBegan) { dragBegan = false }
            default: break
            }
        default:
            drag = .none
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { pinchStart = zoom }
        guard g.state == .began || g.state == .changed else { return }
        let next = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, pinchStart * g.scale))
        guard abs(next - zoom) > 0.01 else { return }
        // die Stelle unter den Fingern bleibt stehen
        let p = g.location(in: self)
        let t = tablePoint(p)
        zoom = next
        updateContentSize()
        scroll.contentOffset = CGPoint(x: max(0, t.x * zoom + Self.headerWidth - p.x), y: max(0, t.y * zoom + Self.headerHeight - p.y))
        canvas.setNeedsDisplay()
    }

    // MARK: Tastatur

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        func cmd(_ input: String, _ flags: UIKeyModifierFlags, _ action: Selector, _ title: String) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            c.discoverabilityTitle = title
            return c
        }
        // Pfeile und Tab als Kuerzel: Sie wiederholen sich beim Gedrueckthalten, und Tab bleibt im Gitter
        var moves: [UIKeyCommand] = []
        for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, "\t"] {
            for flags in [UIKeyModifierFlags(), .shift] {
                let c = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(keyMove(_:)))
                c.wantsPriorityOverSystemBehavior = true
                moves.append(c)
            }
        }
        return moves + [
            cmd("c", .command, #selector(keyCopy), "Kopieren"), cmd("x", .command, #selector(keyCut), "Ausschneiden"),
            cmd("v", .command, #selector(keyPaste), "Einfügen"), cmd("z", .command, #selector(keyUndo), "Widerrufen"),
            cmd("z", [.command, .shift], #selector(keyRedo), "Wiederholen"), cmd("b", .command, #selector(keyBold), "Fett"),
            cmd("i", .command, #selector(keyItalic), "Kursiv"), cmd("d", .command, #selector(keyFillDown), "Nach unten ausfüllen"),
            cmd("a", .command, #selector(keySelectAll), "Alles auswählen"),
        ]
    }

    @objc private func keyMove(_ c: UIKeyCommand) {
        let shift = c.modifierFlags.contains(.shift)
        var d = (col: 0, row: 0)
        switch c.input {
        case UIKeyCommand.inputUpArrow: d.row = -1
        case UIKeyCommand.inputDownArrow: d.row = 1
        case UIKeyCommand.inputLeftArrow: d.col = -1
        case UIKeyCommand.inputRightArrow: d.col = 1
        default: d.col = shift ? -1 : 1                       // Tab
        }
        if c.input == "\t" || model.isEditing { model.commitEditing(dCol: d.col, dRow: d.row) }
        else { model.move(dCol: d.col, dRow: d.row, extend: shift) }
    }

    @objc private func keyCopy() { model.copy() }
    @objc private func keyCut() { model.cut() }
    @objc private func keyPaste() { model.paste() }
    @objc private func keyUndo() { model.undo() }
    @objc private func keyRedo() { model.redo() }
    @objc private func keyBold() { model.toggleBold() }
    @objc private func keyItalic() { model.toggleItalic() }
    @objc private func keyFillDown() { model.fillDown() }
    @objc private func keySelectAll() { model.select(model.sheet.bounds) }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let shift = key.modifierFlags.contains(.shift)
            if key.modifierFlags.contains(.command) || key.modifierFlags.contains(.control) { continue }
            if model.isEditing {
                // schnell getippt: Das Eingabefeld hat den Fokus noch nicht - die Zeichen gehen trotzdem in die Zelle
                let chars = key.characters
                if key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter { model.commitEditing(dCol: 0, dRow: 1); handled = true }
                else if key.keyCode == .keyboardEscape { model.cancelEditing(); handled = true }
                else if [.keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow, .keyboardTab].contains(key.keyCode) {}   // `keyMove`
                else if chars.count == 1, let ch = chars.first, !ch.isNewline, ch.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) }) {
                    model.editing = (model.editing ?? "") + chars
                    handled = true
                }
                continue
            }
            switch key.keyCode {
            case .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow, .keyboardTab: break   // `keyMove`
            case .keyboardReturnOrEnter, .keypadEnter: model.commitEditing(dCol: 0, dRow: shift ? -1 : 1); handled = true
            case .keyboardDeleteOrBackspace, .keyboardDeleteForward: model.clearContents(); handled = true
            case .keyboardF2: model.beginEditing(); handled = true
            case .keyboardEscape: handled = true
            default:
                let chars = key.characters
                if chars.count == 1, let ch = chars.first, !ch.isNewline, ch.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) }) {
                    model.beginEditing(chars)
                    handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    // MARK: Zeichnen

    private func draw(in ctx: CGContext, bounds: CGRect) {
        let hw = Self.headerWidth, hh = Self.headerHeight
        let s = model.sheet
        ctx.setFillColor(Self.background.cgColor)
        ctx.fill(bounds)
        let cellsArea = CGRect(x: hw, y: hh, width: bounds.width - hw, height: bounds.height - hh)
        let visible = CGRect(x: offset.x / zoom, y: offset.y / zoom, width: cellsArea.width / zoom, height: cellsArea.height / zoom)
        let sel = model.selection

        ctx.saveGState()
        ctx.clip(to: cellsArea)
        ctx.translateBy(x: hw - offset.x, y: hh - offset.y)
        ctx.scaleBy(x: zoom, y: zoom)
        SheetRender.drawCells(s, model.calc, grid, hidden: hiddenRows, clip: visible, cache: cache,
                              editing: model.editing.map { (model.active, $0) }, in: ctx)
        // Zellen, die die getippte Formel liest
        if model.isFormulaEditing, let text = model.editing {
            for (i, r) in SheetFormula.references(text).prefix(12).enumerated() where s.bounds.contains(r.from) {
                let rect = grid.rect(s.clamped(r))
                ctx.setStrokeColor(SheetChartRender.color(i).cgColor)
                ctx.setFillColor(SheetChartRender.color(i).withAlphaComponent(0.10).cgColor)
                ctx.fill(rect)
                ctx.setLineWidth(1.6 / zoom)
                ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
                ctx.stroke(rect)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        // Auswahl
        let selRect = grid.rect(sel)
        if sel.count > 1 {
            ctx.setFillColor(Self.accent.withAlphaComponent(0.12).cgColor)
            ctx.fill(selRect)
        }
        ctx.setStrokeColor(Self.accent.cgColor)
        ctx.setLineWidth(2 / zoom)
        ctx.stroke(selRect)
        if sel.count > 1 {
            ctx.setLineWidth(1 / zoom)
            ctx.stroke(grid.rect(model.active).insetBy(dx: 1 / zoom, dy: 1 / zoom))
        }
        if !model.isEditing {
            for p in [CGPoint(x: selRect.minX, y: selRect.minY), CGPoint(x: selRect.maxX, y: selRect.maxY)] {
                let r = 5.5 / zoom
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                ctx.setFillColor(Self.accent.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - r + 1.5 / zoom, y: p.y - r + 1.5 / zoom, width: 2 * r - 3 / zoom, height: 2 * r - 3 / zoom))
            }
        }
        ctx.restoreGState()

        // Kopf
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        func label(_ text: String, in rect: CGRect, on: Bool) {
            let key = (on ? "1" : "0") + text
            let l: SheetRender.Line
            if let hit = headLines[key] { l = hit } else {
                if headLines.count > 1_200 { headLines = [:] }
                l = SheetRender.line(text, font: Self.headFont, color: on ? Self.accent : UIColor.darkGray)
                headLines[key] = l
            }
            l.draw(at: CGPoint(x: rect.midX - l.size.width / 2, y: rect.midY - l.size.height / 2), in: ctx)
        }
        if let range = grid.range(in: visible) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: hw, y: 0, width: bounds.width - hw, height: hh))
            for c in range.cols {
                let r = CGRect(x: hw + grid.colX[c] * zoom - offset.x, y: 0, width: (grid.colX[c + 1] - grid.colX[c]) * zoom, height: hh)
                let on = sel.cols.contains(c)
                ctx.setFillColor((on ? Self.accent.withAlphaComponent(0.16) : SheetRender.headerFill).cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(SheetRender.gridColor.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(r)
                label(SheetRef.colName(c), in: r, on: on)
                if model.isFiltered(c), let funnel = Self.funnel {
                    funnel.draw(in: CGRect(x: r.maxX - 16, y: r.midY - 6.5, width: 13, height: 13))
                }
            }
            ctx.restoreGState()
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: hh, width: hw, height: bounds.height - hh))
            for row in range.rows where !hiddenRows.contains(row) {
                let r = CGRect(x: 0, y: hh + grid.rowY[row] * zoom - offset.y, width: hw, height: (grid.rowY[row + 1] - grid.rowY[row]) * zoom)
                let on = sel.rows.contains(row)
                ctx.setFillColor((on ? Self.accent.withAlphaComponent(0.16) : SheetRender.headerFill).cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(SheetRender.gridColor.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(r)
                label("\(row + 1)", in: r, on: on)
                // darunter fehlen gefilterte Zeilen
                if hiddenRows.contains(row + 1) {
                    ctx.setFillColor(Self.accent.cgColor)
                    ctx.fill(CGRect(x: 0, y: r.maxY - 1.5, width: hw, height: 3))
                }
            }
            ctx.restoreGState()
        }
        ctx.setFillColor(SheetRender.headerFill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: hw, height: hh))
        ctx.setStrokeColor(SheetRender.gridColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 0, y: 0, width: hw, height: hh))
    }
}

// MARK: - Bedienungshilfen

/// VoiceOver: jede sichtbare Zelle ist ein Element ("B3: 12,5"); Aktivieren waehlt sie
extension SheetGridView {
    final class CellElement: UIAccessibilityElement {
        var activate: (() -> Void)?
        override func accessibilityActivate() -> Bool { activate?(); return true }
    }

    override var accessibilityElements: [Any]? {
        get {
            let area = CGRect(x: offset.x / zoom, y: offset.y / zoom, width: (bounds.width - Self.headerWidth) / zoom, height: (bounds.height - Self.headerHeight) / zoom)
            guard let range = grid.range(in: area) else { return [] }
            var out: [Any] = []
            let sel = model.selection
            for row in range.rows where !model.hidden.contains(row) {
                for col in range.cols {
                    guard out.count < 400 else { return out }
                    let r = SheetRef(col: col, row: row)
                    let e = CellElement(accessibilityContainer: self)
                    let shown = model.sheet.display(r, model.calc)
                    e.accessibilityLabel = r.name + ": " + (shown.isEmpty ? "leer" : shown)
                    if SheetFormula.isFormula(model.sheet.raw(r)) { e.accessibilityHint = "Formel " + model.sheet.raw(r) }
                    e.accessibilityTraits = sel.contains(r) ? [.button, .selected] : .button
                    e.accessibilityFrameInContainerSpace = viewRect(grid.rect(r))
                    e.accessibilityIdentifier = "sheet.cell." + r.name
                    e.activate = { [weak self] in
                        self?.model.commitEditing()
                        self?.model.select(r)
                    }
                    out.append(e)
                }
            }
            return out
        }
        set {}
    }
}

extension SheetEditorModel {
    /// Spalte oder Zeile am Kopf groesser/kleiner ziehen: ein Rueckgaengig-Schritt fuer das ganze Ziehen (gemerkt
    /// erst, wenn sich wirklich etwas aendert - bloss anfassen hinterlaesst keinen Schritt)
    @discardableResult
    func resizeLive(col: Int?, row: Int?, to v: Double, begin: Bool) -> Bool {
        changeLive(first: begin) { s in
            if let col { s.setWidth(v, col: col) }
            if let row { s.setHeight(v, row: row) }
        }
    }
}
