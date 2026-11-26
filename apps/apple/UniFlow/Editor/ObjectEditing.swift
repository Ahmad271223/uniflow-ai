import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// Objekt-Werkzeuge im Editor (Editor-Schritt 6, P1-4 bis P1-7): Werkzeugmodus "Objekte" neben der Tinte. Die Canvas
/// nimmt dann keine Eingabe an; Antippen waehlt aus oder legt an, Ziehen verschiebt, die Anfasser an den Ecken des
/// Rahmens oder zwei Finger aendern die Groesse, doppelt Antippen bearbeitet Text (mit dem Pencil per Scribble), das
/// Lasso waehlt mehrere Objekte. Felder und Regeln wie im Web-Editor (`PageObjectEdit`); gespeichert ueber
/// `DocumentStore.editObjects`, Rueckgaengig ueber den Verlauf des Dokuments.
///
/// Meldung des Inhabers am iPad (21.11.2026): Ein Bild lasse sich "verschieben, aber nicht kleiner machen", es
/// "verschwindet", und "wenn man das zieht, ist außen ein blauer Kasten, der verzerrt mitgeht". Nachgestellt
/// (`BildGroesseTests`): Groesse ging nur mit zwei Fingern, und dabei zoomte die Seite statt des Bildes; ein ueber den
/// Seitenrand gezogenes Bild blieb ausserhalb der Seite; der Rahmen lief dem Bild mit einer Viertelsekunde Nachlauf
/// hinterher (stille Animation von Core Animation). Seither: Anfasser an den Ecken, Vorschau am Bild selbst, alles bleibt
/// auf der Seite, Rahmen ohne Nachlauf.
@MainActor
final class ObjectEditing: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate {
    enum Tool: String, CaseIterable {
        case select, text, sticky, rect, ellipse, line, arrow, lasso, markup
        /// Klappkarte zum Abfragen (25.11.2026): ueber etwas ziehen verdeckt es, Antippen legt eine in fester Groesse an
        case cover
        /// Verweis auf Dokument + Seite (25.11.2026): Stelle antippen oder ueber ein Wort ziehen, dann das Ziel antippen
        case link
        /// "Bereich an KI" (05.11.2026): Rahmen ziehen oder Bereich einkreisen, der Ausschnitt geht als Bild an die KI-Hilfe
        case area

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
            case .area: return "Bereich an KI"
            case .cover: return "Klappkarte"
            case .link: return "Verweis"
            }
        }
        var systemImage: String {
            switch self {
            // kein Mauszeiger mehr (05.11.2026: am iPad des Inhabers "der komische Pfeil", dessen Sinn unklar blieb)
            case .select: return "rectangle.and.hand.point.up.left"
            case .text: return "textformat"
            case .sticky: return "note.text"
            case .rect: return "rectangle"
            case .ellipse: return "circle"
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            case .lasso: return "lasso"
            case .markup: return "highlighter"
            case .area: return "rectangle.dashed"
            case .cover: return "eye.slash"
            case .link: return "link"
            }
        }
        /// Form, die beim Ziehen entsteht (Klappkarte: ein Rechteck ueber der Stelle)
        var shapeKind: String? { [.rect: "rect", .ellipse: "ellipse", .line: "line", .arrow: "arrow", .cover: "rect", .link: "rect"][self] }
    }

    private(set) weak var controller: PDFEditorController?
    private(set) var isActive = false
    var tool: Tool = .select {
        didSet {
            if tool != .select { clearSelection() }
            if tool != .link, oldValue == .link { cancelLink() }
            if tool == .area, oldValue != .area { controller?.onHint?(Self.areaHint) }
            // Text markieren: die PDF-Ansicht waehlt Text selbst aus (Overlays lassen die Beruehrung durch); im
            // Markup-Modus nimmt sie keine Auswahl an
            controller?.allOverlays.forEach { $0.isUserInteractionEnabled = tool != .markup }
            controller?.pdfView.isInMarkupMode = tool != .markup
            if tool != .markup {
                controller?.pdfView.clearSelection()
                controller?.restorePickerSoon()                     // die PDF-Ansicht hatte den Fokus
            }
        }
    }
    /// PDF-Text ist ausgewaehlt (Leiste zeigt Markieren/Unterstreichen/Durchstreichen)
    var onTextSelection: ((Bool) -> Void)?
    private var selectionObserver: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?
    var color = "#e5322d"
    var lineWidth = 2.0
    /// Auswahl (eine Seite)
    private(set) var selection: (key: String, ids: Set<String>)?
    /// Ausgewaehlte Handschrift derselben Seite (ein Lasso fuer Handschrift und Objekte, 10.11.2026): Indizes der Striche
    var inkSelection: (key: String, indices: [Int])?
    /// Waehrend des Verschiebens: Bild der ausgewaehlten Striche ueber der Seite und die Zeichnung davor
    var inkDrag: (view: UIImageView, before: PKDrawing, overlay: PageInkView)?
    /// Seite der Auswahl (Objekte oder Handschrift)
    var selectedKey: String? { selection?.key ?? inkSelection?.key }
    var hasSelection: Bool { selection != nil || inkSelection != nil }
    var onSelectionChange: ((Int) -> Void)?
    /// Der Editor hat das Werkzeug selbst gewechselt (nach dem Anlegen eines Textes, nach dem Lasso)
    var onToolChange: ((Tool) -> Void)?

    lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    lazy var doubleTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        g.numberOfTapsRequired = 2
        return g
    }()
    private(set) lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    /// Wo der Finger fuer das laufende Ziehen aufgesetzt hat (Punkte des Fensters): Die Geste selbst meldet sich erst
    /// nach rund 10 Punkten Weg, Klappkarten und Verweise sollen aber genau an der Stelle beginnen
    var panDown: CGPoint?
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private let selectionLayer = CAShapeLayer()
    private let draftLayer = CAShapeLayer()
    /// Anfasser an den vier Ecken des Auswahlrahmens: daran zieht ein Finger oder der Stift die Auswahl groesser und
    /// kleiner (die Ecke gegenueber bleibt stehen)
    private let handleLayers = (0..<4).map { _ in CAShapeLayer() }
    /// Rechteck um die Auswahl in Seitenpunkten (Objekte und Handschrift); der Rahmen liegt `frameGap` weiter aussen
    private(set) var selectionBox = CGRect.null
    /// Laufendes Ziehen an der Auswahl
    private(set) var grab: Grab?
    /// Waehrend eine Aenderung gespeichert wird (erst Objekte, dann Handschrift), bleibt der Rahmen der Vorschau stehen
    var holdsFrame = false
    /// Bild ins andere Dokument ziehen (`ObjectTransfer.swift`): schwebendes Bild im Fenster, Rahmen auf der Zielseite,
    /// und ob gerade ein Bild hinuebergeht (solange greift nichts an der Auswahl)
    var transferView: UIImageView?
    let transferFrame = CAShapeLayer()
    var transferring = false
    private var panStart: (overlay: PageInkView, point: CGPoint)?
    private var lassoPoints: [CGPoint] = []
    /// Laufendes Bearbeiten eines Texts (`TextBlockEditing.swift`)
    var editing: TextEdit?
    /// Formatierung der Auswahl bzw. des Texts, der gerade bearbeitet wird (Leiste "Text"); nil = kein Text gewaehlt
    var onTextFormat: ((TextFormat?) -> Void)?
    private(set) var textFormat: TextFormat?
    /// Langes Druecken auf einen Textblock greift ihn (`TextBlockEditing.swift`)
    lazy var hold: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        g.minimumPressDuration = Self.holdSeconds
        g.allowableMovement = 12
        g.delegate = self
        return g
    }()
    var holdStart: CGPoint?
    /// Aenderungen der Leiste "Text" laufen nacheinander (`inOrder`)
    var formatQueue: Task<Void, Never>?
    /// Verweis anlegen: gestrichelte Markierung der Stelle, solange das Ziel fehlt; Meldung an die Leiste
    let linkDraft = CAShapeLayer()
    var onLinkPending: ((Bool) -> Void)?

    init(controller: PDFEditorController) {
        self.controller = controller
        super.init()
        for l in [selectionLayer, draftLayer] {
            l.fillColor = UIColor.clear.cgColor
            l.strokeColor = UIColor.systemBlue.cgColor
            l.lineDashPattern = [4, 3]
            l.lineWidth = 1
        }
        selectionLayer.name = "objects.selection"
        for h in handleLayers {
            h.name = "objects.handle"
            h.fillColor = UIColor.white.cgColor
            h.strokeColor = UIColor.systemBlue.cgColor
        }
        // Eigene Ebenen aendern Lage und Form sonst mit einer stillen Animation von einer Viertelsekunde: Der Rahmen lief
        // dem Bild beim Ziehen hinterher und sprang beim Loslassen ("blauer Kasten, der verzerrt mitgeht")
        let still = Dictionary(uniqueKeysWithValues: ["path", "transform", "position", "bounds", "lineWidth", "lineDashPattern",
                                                      "hidden", "opacity"].map { ($0, NSNull() as CAAction) })
        ([selectionLayer, draftLayer, transferFrame] + handleLayers).forEach { $0.actions = still }
        tap.require(toFail: doubleTap)
        [tap, doubleTap, pan, pinch].forEach { $0.delegate = self }
    }

    // MARK: Ein/aus

    func setActive(_ on: Bool) {
        guard let c = controller, on != isActive else { return }
        // "Bereich an KI" schreibt nichts: auch in Free und in alten Fassungen
        if on && !c.writable && tool != .area { return }
        isActive = on
        endTextEditing()
        if !on { cancelLink() }
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
            // Zoom der Seite: Strich des Rahmens und Anfasser bleiben auf dem Bildschirm gleich gross
            scaleObserver = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: c.pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFrame() }
            }
        } else {
            if tool == .markup { tool = .select }
            if let o = selectionObserver { NotificationCenter.default.removeObserver(o) }
            selectionObserver = nil
            if let o = scaleObserver { NotificationCenter.default.removeObserver(o) }
            scaleObserver = nil
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
    /// Farbe fuer "Text markieren" (vom Editor: Farbe des Textmarkers der Leiste, `PaletteSync.markupColor`)
    var markupColor: ((PageObjectEdit.Markup) -> String)?

    func applyMarkup(_ kind: PageObjectEdit.Markup, color: String? = nil) {
        let color = color ?? markupColor?(kind) ?? PageObjectEdit.markerColors[0]
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
        overlay.isUserInteractionEnabled = tool != .markup
    }

    // MARK: Treffer

    nonisolated static func textHeight(_ o: JSONValue) -> Double {
        Double(ObjectGeometry.textSize(o, ObjectGeometry.attributedText(o)).height)
    }

    /// Overlay unter einem Punkt der PDF-Ansicht und der Punkt in Seitenpunkten
    func locate(_ g: UIGestureRecognizer) -> (PageInkView, CGPoint)? {
        guard let c = controller else { return nil }
        for v in c.allOverlays where v.window != nil && !v.pageKey.isEmpty {
            // Objekte stehen in Seitenpunkten: `content` rechnet die Skalierung der Seite heraus
            let p = g.location(in: v.content)
            if v.content.bounds.contains(p) { return (v, p) }
        }
        return nil
    }

    func objects(_ key: String) async -> [JSONValue] { await controller?.store.objects(forPageKey: key) ?? [] }

    // MARK: Gesten

    /// Hinweise unten im Editor
    static let areaHint = "Rahmen ziehen oder Bereich einkreisen – er geht als Bild an die KI-Hilfe."
    static let selectMissHint = "„Auswählen“ greift Textfelder, Haftnotizen und Formen. Handschrift wählst du mit dem Lasso aus."

    /// "Bereich an KI": Rahmen aus erstem und letztem Punkt; kehrt der Strich zum Anfang zurueck (eingekreist), die
    /// umschliessende Box aller Punkte. `loop` sagt, welches von beiden.
    nonisolated static func areaShape(_ pts: [CGPoint]) -> (rect: CGRect, loop: Bool) {
        guard let first = pts.first, let last = pts.last else { return (.null, false) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let gap = hypot(last.x - first.x, last.y - first.y)
        let loop = pts.count >= 8 && gap <= max(24, 0.3 * hypot(box.width, box.height))
        if loop { return (box, true) }
        return (CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)), false)
    }

    /// Kleinster Bereich, der an die KI geht (Seitenpunkte); kleiner gilt als Antippen
    static let areaMinimum: CGFloat = 12

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === hold { return holdShouldBegin() }
        guard isActive, tool != .markup else { return false }
        if g === pan {
            // Ziehen mit Form-, Lasso- oder Bereichswerkzeug, oder auf der Auswahl bzw. an einem ihrer Anfasser; sonst
            // scrollt die Ansicht
            if tool.shapeKind != nil || tool == .lasso || tool == .area { return true }
            return grip(for: pan) != nil || editorGrip(for: pan) != nil
        }
        if g === pinch {
            // zwei Finger AUF der Auswahl aendern ihre Groesse; daneben zoomt die Seite wie immer
            guard grab == nil, let overlay = selectionOverlay else { return false }
            let reach = 30 / Self.screenScale(of: overlay)
            return selectionBox.insetBy(dx: -reach, dy: -reach).contains(g.location(in: overlay.content))
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // langes Druecken: neben anderen langen Druecken (PDFKit) ja; hat es gegriffen, scrollt und zoomt nichts mehr
        if g === hold { return other is UILongPressGestureRecognizer }
        if other === hold { return false }
        return g === tap || g === doubleTap
    }

    /// Ziehen und die Zwei-Finger-Geste AUF der Auswahl gehoeren der Auswahl: Scrollen und Zoomen der Seite warten, bis
    /// feststeht, dass die Geste ihr nicht gilt (`gestureRecognizerShouldBegin` sagt nein), und laufen dann wie immer.
    /// Vorher gewann die Geste der Seite: mit zwei Fingern auf dem Bild zoomte die Seite, das Bild blieb, wie es war,
    /// und in einer schmalen Spalte scrollte die Seite, statt das Bild zu verschieben (nachgestellt 21.11.2026). Gilt
    /// nur im Objektmodus mit "Auswählen" (nur dann gibt es eine Auswahl); bei Formen, Lasso und Bereich bleibt alles wie
    /// bisher, und ausserhalb des Objektmodus haengen diese Gesten gar nicht an der Ansicht.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard isActive, tool == .select, other.view is UIScrollView else { return false }
        if g === pan { return other is UIPanGestureRecognizer }
        if g === pinch { return other is UIPinchGestureRecognizer }
        return false
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let (v, p) = locate(g) else { clearSelection(); return }
        endTextEditing()
        let key = v.pageKey
        switch tool {
        case .area:
            controller?.onHint?(Self.areaHint)                // Antippen allein waehlt keinen Bereich
        case .link:
            // erster Tipp: Stelle des Verweises (Punkt); zweiter Tipp: das Ziel
            if linkPending { finishLink(targetOn: v, at: p) }
            else { beginLink(on: v, rect: CGRect(x: p.x, y: p.y, width: 0, height: 0), isArea: false) }
        case .cover:
            // Antippen: Karte in der gewaehlten Groesse um den Punkt (das Werkzeug bleibt, fuer die naechste)
            guard controller?.richNotes == true else { controller?.onHint?(Self.coverLockedHint); return }
            // auf eine vorhandene Karte getippt: sie waehlen, statt eine zweite darueberzulegen (spaeter klappte nur
            // die obere auf - die Stelle "ging nicht auf")
            if let hit = TopObjects.hit(v.objectsView.shownObjects, x: Double(p.x), y: Double(p.y)), FlipCover.isCover(hit), let id = hit["id"]?.string {
                setTool(.select)
                select(key: key, ids: [id], in: v.objectsView.shownObjects)
                return
            }
            let o = newCover(id: PageOrder.uid(), on: v, at: p)
            Task { await commit(key) { $0 + [o] } }
        case .text, .sticky:
            let kind = tool
            Task {
                // vorhandenen Text bearbeiten statt ein weiteres Feld darueberzulegen
                let list = await objects(key)
                if let hit = PageObjectEdit.hit(list, x: Double(p.x), y: Double(p.y), textHeight: Self.textHeight),
                   list.first(where: { $0["id"]?.string == hit })?["type"]?.string == "text" {
                    setTool(.select)
                    select(key: key, ids: [hit], in: list)
                    beginTextEditing(key: key, id: hit, isNew: false)
                    return
                }
                let id = PageOrder.uid()
                let o = kind == .text ? newBlock(id: id, on: v, at: p) : newSticky(id: id, on: v, at: p)
                // danach auswaehlen: Antippen trifft den Text, der Papierkorb loescht ihn
                setTool(.select)
                // gespeichert wird erst mit dem ersten Text (ein Rueckgaengig-Schritt; kein leeres Feld auf der Seite)
                beginNewText(o, key: key)
            }
        default:
            Task {
                let list = await objects(key)
                // Klappkarten und Verweise liegen ueber allem: Sie trifft der Tipp zuerst - wie man es sieht
                if let id = TopObjects.hit(list, x: Double(p.x), y: Double(p.y))?["id"]?.string
                    ?? PageObjectEdit.hit(list, x: Double(p.x), y: Double(p.y), textHeight: Self.textHeight) {
                    select(key: key, ids: [id], in: list)
                } else {
                    // nichts getroffen (oft Handschrift): sagen, was "Auswählen" greift, statt still nichts zu tun
                    if selection == nil, tool == .select { controller?.onHint?(Self.selectMissHint) }
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

    /// Gehoert das laufende Ziehen an der Auswahl den zwei Fingern (`pinched`)? Dann fasst `panned` es nicht an.
    private var pinchHoldsGrab: Bool {
        if let gr = grab, case .pinch = gr.kind { return true }
        return false
    }

    @objc func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            guard tool.shapeKind != nil || tool == .lasso || tool == .area else {
                // Auswahl: verschieben oder an einer Ecke die Groesse aendern
                if let (overlay, kind) = grip(for: g) {
                    beginGrab(kind, on: overlay)
                } else if let overlay = editorGrip(for: g) {
                    // am Text gezogen, in dem gerade getippt wird (nicht ausgewaehlt, evtl. noch gar nicht gespeichert)
                    beginGrab(.move, on: overlay, editorOnly: true)
                } else {
                    g.state = .cancelled
                }
                return
            }
            guard let (v, now) = locate(g) else { g.state = .cancelled; return }
            var p = now
            if tool == .cover || tool == .link, let down = panDown {
                // Klappkarte, Verweis: genau ab der Stelle, an der aufgesetzt wurde (die Geste erkennt erst nach ein paar Punkten Weg)
                let start = v.content.convert(down, from: nil)
                if v.content.bounds.contains(start) { p = start }
            }
            panStart = (v, p)
            lassoPoints = [p]
            v.content.layer.addSublayer(draftLayer)
        case .changed:
            if let gr = grab {
                if pinchHoldsGrab { return }
                let t = g.translation(in: gr.overlay.content)
                switch gr.kind {
                case .move:
                    preview(.move(moveOffset(gr, t)))
                    hoverTransfer(g, gr)                    // geteilte Ansicht: ein Bild kann ins andere Dokument
                case .corner(let anchor, let corner):
                    let wanted = Self.cornerFactor(anchor: anchor, corner: corner, translation: t)
                    let limit = Self.anchoredLimit(gr.box, anchor: anchor, corner: corner, in: Self.page(of: gr.overlay))
                    // ueber die Ecke gegenueber hinaus gezogen: so klein wie moeglich (die Grenze setzt `resized`)
                    preview(.scale(max(0.001, min(wanted, limit)), anchor))
                case .pinch:
                    break
                }
                return
            }
            guard let start = panStart else { return }
            let p = g.location(in: start.overlay.content)
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
            } else if tool == .area {
                lassoPoints.append(p)
                let shape = Self.areaShape(lassoPoints)
                let path = CGMutablePath()
                if shape.loop { path.addLines(between: lassoPoints) }
                if !shape.rect.isNull { path.addRect(shape.rect) }
                draftLayer.path = path
            }
        case .ended:
            if let gr = grab, !pinchHoldsGrab {
                // ueber einer Seite des anderen Dokuments losgelassen: das Bild geht hinueber; sonst wie immer
                if !dropTransfer(g, gr) { finishGrab() }
                return
            }
            guard let start = panStart else { return }
            panStart = nil
            draftLayer.removeFromSuperlayer()
            draftLayer.path = nil
            let key = start.overlay.pageKey
            let p = g.location(in: start.overlay.content)
            if tool == .link {
                // Verweis als Bereich ueber dem Wort; danach wird das Ziel angetippt
                let area = rect(start.point, p).intersection(start.overlay.content.bounds)
                guard !area.isNull, hypot(p.x - start.point.x, p.y - start.point.y) > 4 else { return }
                beginLink(on: start.overlay, rect: area, isArea: true)
            } else if tool == .cover {
                // Klappkarte ueber der gezogenen Stelle (auf der Seite)
                let area = rect(start.point, p).intersection(start.overlay.content.bounds)
                guard controller?.richNotes == true, !area.isNull, hypot(p.x - start.point.x, p.y - start.point.y) > 4 else { return }
                let o = newCover(id: PageOrder.uid(), on: start.overlay, rect: area, at: p)
                Task { await commit(key) { $0 + [o] } }
            } else if let kind = tool.shapeKind {
                guard hypot(p.x - start.point.x, p.y - start.point.y) > 4,
                      let o = PageObjectEdit.shape(id: PageOrder.uid(), kind: kind, from: (Double(start.point.x), Double(start.point.y)),
                                                   to: (Double(p.x), Double(p.y)), color: color, width: lineWidth) else { return }
                Task { await commit(key) { $0 + [o] } }
            } else if tool == .area {
                let rect = Self.areaShape(lassoPoints + [p]).rect.intersection(start.overlay.content.bounds)
                lassoPoints = []
                guard !rect.isNull, rect.width >= Self.areaMinimum, rect.height >= Self.areaMinimum else {
                    controller?.onHint?(Self.areaHint)
                    return
                }
                controller?.sendArea(pageIndex: start.overlay.pageIndex, rect: rect)
            } else if tool == .lasso {
                let poly = lassoPoints.map { (x: Double($0.x), y: Double($0.y)) }
                lassoPoints = []
                let drawing = start.overlay.loaded ? start.overlay.canvas.drawing : PKDrawing()
                Task {
                    let list = await objects(key)
                    let ids = PageObjectEdit.inLasso(list, polygon: poly, textHeight: Self.textHeight)
                    // dasselbe Lasso greift auch die Handschrift (vorher nur Objekte; Handschrift brauchte Apples Lasso)
                    let ink = Self.strokes(of: drawing, inLasso: poly)
                    if ids.isEmpty && ink.isEmpty { clearSelection() } else {
                        setTool(.select)
                        select(key: key, ids: Set(ids), in: list, ink: ink)
                    }
                }
            }
        default:
            // ein abgebrochenes Ziehen beendet keine laufende Zwei-Finger-Geste
            if !pinchHoldsGrab { cancelGrab() }
            panStart = nil
            draftLayer.removeFromSuperlayer()
        }
    }

    /// Zwei Finger auf der Auswahl: groesser und kleiner um ihre Mitte, mit Vorschau an den Objekten selbst
    @objc func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            guard grab == nil, let overlay = selectionOverlay else { g.state = .cancelled; return }
            beginGrab(.pinch, on: overlay)
        case .changed:
            guard let gr = grab, case .pinch = gr.kind else { return }
            preview(.scale(Double(g.scale), CGPoint(x: gr.box.midX, y: gr.box.midY)))
        case .ended:
            guard let gr = grab, case .pinch = gr.kind else { return }
            finishGrab()
        default:
            if let gr = grab, case .pinch = gr.kind { cancelGrab() }
        }
    }

    // MARK: Ziehen an der Auswahl (verschieben, Ecke, zwei Finger) mit Vorschau

    /// Stand beim Aufsetzen und die zuletzt gezeigte Aenderung
    struct Grab {
        enum Kind { case move, corner(anchor: CGPoint, corner: CGPoint), pinch }
        let kind: Kind
        let overlay: PageInkView
        /// gezeigte Objekte der Seite beim Aufsetzen
        let list: [JSONValue]
        let ids: Set<String>
        /// Rechteck um die ausgewaehlte Handschrift (`.null` ohne) und um die ganze Auswahl
        let inkBox: CGRect
        let box: CGRect
        /// die Auswahl enthaelt einen Textblock, der auf den Linien sitzt: senkrecht nur in ganzen Zeilen
        var snapsToLines = false
        /// gegriffen ist nur der Text, in dem gerade getippt wird (keine Auswahl, kein Rahmen)
        var editorOnly = false
        var change = Change.none
    }

    /// Aenderung an der Auswahl: Versatz, oder Faktor um einen festen Punkt (Seitenpunkte)
    enum Change: Equatable { case none, move(CGPoint), scale(Double, CGPoint) }

    /// Kleinste laengere Seite einer Auswahl nach dem Verkleinern (Seitenpunkte): bleibt greifbar
    static let minimumSide: CGFloat = 24
    /// Abstand des Rahmens von der Auswahl (Seitenpunkte)
    static let frameGap: CGFloat = 4
    /// Anfasser: sichtbarer Halbmesser und Halbmesser, in dem eine Beruehrung ihn trifft (Bildschirmpunkte)
    static let handleRadius: CGFloat = 7
    static let handleReach: CGFloat = 24

    /// Seite der Auswahl, wenn sie gerade gezeigt wird
    private var selectionOverlay: PageInkView? {
        guard let key = selectedKey, !selectionBox.isNull, let overlay = controller?.boundOverlay(forKey: key), overlay.window != nil else { return nil }
        return overlay
    }

    nonisolated static func page(of overlay: PageInkView) -> CGRect { CGRect(origin: .zero, size: overlay.geometry.pageSize) }

    /// Bildschirmpunkte je Seitenpunkt (Zoom der Seite; in der schmalen Spalte daneben unter 1)
    static func screenScale(of overlay: PageInkView) -> CGFloat {
        let a = overlay.content.convert(CGPoint.zero, to: nil), b = overlay.content.convert(CGPoint(x: 100, y: 0), to: nil)
        let s = hypot(b.x - a.x, b.y - a.y) / 100
        return s.isFinite && s > 0.01 ? s : 1
    }

    /// Was eine Beruehrung an der Auswahl greift: einen Anfasser (Groesse) oder die Auswahl selbst (verschieben). Gemessen
    /// wird, wo der Finger aufgesetzt hat, nicht wo er nach den ersten Punkten Weg steht.
    private func grip(for g: UIPanGestureRecognizer) -> (PageInkView, Grab.Kind)? {
        guard grab == nil, !transferring, let overlay = selectionOverlay else { return nil }
        let now = g.location(in: overlay.content), t = g.translation(in: overlay.content)
        let p = CGPoint(x: now.x - t.x, y: now.y - t.y)
        let s = Self.screenScale(of: overlay)
        if controller?.writable == true, let c = Self.corner(at: p, of: selectionBox, reach: Self.handleReach / s) {
            return (overlay, .corner(anchor: c.anchor, corner: c.corner))
        }
        let reach = Self.frameGap + 12
        return selectionBox.insetBy(dx: -reach, dy: -reach).contains(p) ? (overlay, .move) : nil
    }

    /// Ecke der Auswahl unter einem Punkt (und die Ecke gegenueber, die beim Ziehen stehen bleibt). Ausserhalb der
    /// Auswahl zaehlt der volle Umkreis des Anfassers, innen hoechstens ein Drittel der kuerzeren Seite - ein kleines
    /// Objekt laesst sich so weiter in seiner Mitte greifen und verschieben.
    nonisolated static func corner(at p: CGPoint, of box: CGRect, reach: CGFloat) -> (corner: CGPoint, anchor: CGPoint)? {
        guard !box.isNull else { return nil }
        let inner = min(reach, max(min(box.width, box.height) / 3, reach / 4))
        let limit = box.contains(p) ? inner : reach
        // die Anfasser sitzen auf den Ecken des Rahmens, gezogen wird die Ecke der Auswahl
        let shown = corners(box.insetBy(dx: -frameGap, dy: -frameGap)), all = corners(box)
        guard let i = shown.indices.min(by: { hypot(shown[$0].x - p.x, shown[$0].y - p.y) < hypot(shown[$1].x - p.x, shown[$1].y - p.y) }),
              hypot(shown[i].x - p.x, shown[i].y - p.y) <= limit else { return nil }
        return (all[i], all[(i + 2) % 4])
    }

    /// Ecken im Uhrzeigersinn ab links oben (die Ecke gegenueber steht zwei weiter)
    nonisolated static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// Faktor, wenn die Ecke `corner` um `translation` gezogen wird und `anchor` stehen bleibt: der Weg des Fingers
    /// entlang der Diagonale (das Seitenverhaeltnis bleibt)
    nonisolated static func cornerFactor(anchor: CGPoint, corner: CGPoint, translation t: CGPoint) -> Double {
        let v = CGPoint(x: corner.x - anchor.x, y: corner.y - anchor.y)
        let length = v.x * v.x + v.y * v.y
        guard length > 1 else { return 1 }
        return Double(((v.x + t.x) * v.x + (v.y + t.y) * v.y) / length)
    }

    /// Groesster Faktor, bei dem die Auswahl von `anchor` aus noch auf die Seite passt (mindestens 1)
    nonisolated static func anchoredLimit(_ box: CGRect, anchor: CGPoint, corner: CGPoint, in page: CGRect) -> Double {
        let roomX = corner.x >= anchor.x ? page.maxX - anchor.x : anchor.x - page.minX
        let roomY = corner.y >= anchor.y ? page.maxY - anchor.y : anchor.y - page.minY
        var limit = Double.infinity
        if box.width > 0.5 { limit = min(limit, Double(roomX / box.width)) }
        if box.height > 0.5 { limit = min(limit, Double(roomY / box.height)) }
        return max(1, limit)
    }

    /// Versatz, mit dem `box` ganz auf der Seite bleibt (ist sie groesser als die Seite: mit dem die Seite bedeckt bleibt)
    nonisolated static func clampedOffset(_ box: CGRect, by d: CGPoint, in page: CGRect) -> CGPoint {
        guard !box.isNull else { return d }
        func clamp(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(max(v, min(a, b)), max(a, b)) }
        return CGPoint(x: clamp(d.x, page.minX - box.minX, page.maxX - box.maxX), y: clamp(d.y, page.minY - box.minY, page.maxY - box.maxY))
    }

    /// Rechteck um die Objekte mit diesen IDs (Seitenpunkte), `.null` ohne
    nonisolated static func box(of list: [JSONValue], ids: Set<String>) -> CGRect {
        var box = CGRect.null
        for o in list where (o["id"]?.string).map(ids.contains) == true {
            if let b = PageObjectEdit.bounds(o, textHeight: textHeight) {
                box = box.union(CGRect(x: b.minX, y: b.minY, width: b.maxX - b.minX, height: b.maxY - b.minY))
            }
        }
        return box
    }

    /// Objekte um `anchor` skalieren: Massstab wie `PageObjectEdit.scale` (Text: die Breite), dazu rueckt jedes Objekt so,
    /// dass `anchor` stehen bleibt und mehrere Objekte ihre Lage zueinander behalten. Das Speicherformat bleibt.
    nonisolated static func scaled(_ list: [JSONValue], ids: Set<String>, by f: Double, about anchor: CGPoint) -> [JSONValue] {
        var out = PageObjectEdit.scale(list, ids: ids, factorX: f, factorY: f)
        for o in list {
            guard let id = o["id"]?.string, ids.contains(id) else { continue }
            let dx = ((o["x"]?.double ?? 0) - Double(anchor.x)) * (f - 1), dy = ((o["y"]?.double ?? 0) - Double(anchor.y)) * (f - 1)
            if abs(dx) > 0.004 || abs(dy) > 0.004 { out = PageObjectEdit.move(out, ids: [id], dx: dx, dy: dy) }
        }
        return TextBlock.resnapped(out, ids: ids)
    }

    /// Ergebnis einer Groessenaenderung: Faktor in den Grenzen, geaenderte Objekte, Rechteck danach und dieselbe
    /// Abbildung fuer die Handschrift
    struct Resized {
        var factor: Double
        var objects: [JSONValue]
        var box: CGRect
        var inkTransform: CGAffineTransform
    }

    /// Auswahl (Objekte `ids` aus `list`, Handschrift in `inkBox`) um `anchor` mit `wanted` skalieren. Grenzen: die
    /// laengere Seite nie unter `minimumSide`, nie groesser als die Seite; danach rueckt die Auswahl, falls noetig, ganz auf
    /// die Seite. Vorschau und Speichern rechnen beide hiermit - was man beim Ziehen sieht, wird gespeichert.
    nonisolated static func resized(_ list: [JSONValue], ids: Set<String>, inkBox: CGRect, by wanted: Double, about anchor: CGPoint,
                                    page: CGRect) -> Resized {
        let before = box(of: list, ids: ids).union(inkBox)
        guard !before.isNull, wanted.isFinite, wanted > 0 else { return Resized(factor: 1, objects: list, box: before, inkTransform: .identity) }
        let longest = max(before.width, before.height)
        let lower = longest > minimumSide ? Double(minimumSide / longest) : 1
        var upper = Double.infinity
        if before.width > 0.5 { upper = min(upper, Double(page.width / before.width)) }
        if before.height > 0.5 { upper = min(upper, Double(page.height / before.height)) }
        let f = min(max(wanted, lower), max(1, upper))
        let scaledList = scaled(list, ids: ids, by: f, about: anchor)
        let scale = scaleTransform(f, about: anchor)
        var after = box(of: scaledList, ids: ids)
        if !inkBox.isNull { after = after.union(inkBox.applying(scale)) }
        var d = clampedOffset(after, by: .zero, in: page)
        if abs(d.x) < 0.01 { d.x = 0 }
        if abs(d.y) < 0.01 { d.y = 0 }
        let objects = d == .zero ? scaledList : PageObjectEdit.move(scaledList, ids: ids, dx: Double(d.x), dy: Double(d.y))
        return Resized(factor: f, objects: objects, box: after.offsetBy(dx: d.x, dy: d.y),
                       inkTransform: scale.concatenating(CGAffineTransform(translationX: d.x, y: d.y)))
    }

    func beginGrab(_ kind: Grab.Kind, on overlay: PageInkView, editorOnly: Bool = false) {
        if !editorOnly { beginInkDrag(on: overlay) }        // ausgewaehlte Handschrift geht als Bild mit
        var list = overlay.objectsView.shownObjects, ids = selection?.ids ?? []
        if editorOnly, let e = editing { ids = [e.id] }
        // Text, in dem gerade getippt wird: sein Stand aus der Textansicht (ein neuer steht noch gar nicht auf der Seite)
        if let e = editing, ids.contains(e.id) { list = list.filter { $0["id"]?.string != e.id } + [e.object] }
        let inkBox = editorOnly ? .null : (inkDrag?.view.frame ?? .null)
        var box = Self.box(of: list, ids: ids).union(inkBox)
        if editorOnly, let e = editing { box = e.view.frame }
        grab = Grab(kind: kind, overlay: overlay, list: list, ids: ids, inkBox: inkBox, box: box.isNull ? selectionBox : box,
                    snapsToLines: TextBlock.containsSnapped(list, ids: ids), editorOnly: editorOnly)
    }

    /// Greift die Beruehrung den Text, in dem gerade getippt wird? (Meldung des Inhabers am iPad 25.11.2026: "man kann
    /// Notizzettel nicht verschieben … der blaue Kasten … verzögert stark und Notizzettel geht nicht mit" - am Zettel
    /// wurde gezogen, waehrend die Tastatur offen war; es bewegten sich nur der Rahmen und der ruhende Zettel darunter.)
    /// Gilt, wenn die Auswahl ihn nicht schon greift (`grip`).
    private func editorGrip(for g: UIPanGestureRecognizer) -> PageInkView? {
        guard grab == nil, !transferring, isActive, tool == .select, let e = editing, let c = controller, c.writable,
              let overlay = c.boundOverlay(forKey: e.key), overlay.window != nil else { return nil }
        let now = g.location(in: overlay.content), t = g.translation(in: overlay.content)
        let p = panDown.map { overlay.content.convert($0, from: nil) } ?? CGPoint(x: now.x - t.x, y: now.y - t.y)
        return e.view.frame.insetBy(dx: -8, dy: -8).contains(p) ? overlay : nil
    }

    /// Textansicht des laufenden Tippens an die Stelle und in die Breite eines Stands bringen (Vorschau beim Ziehen,
    /// gespeicherter Stand danach): Der sichtbare Zettel bzw. Block ist beim Tippen die Textansicht.
    func placeEditor(like o: JSONValue) {
        guard let e = editing else { return }
        let x = ObjectGeometry.coordinate(o["x"], 0), y = ObjectGeometry.coordinate(o["y"], 0)
        let width = CGFloat(ObjectGeometry.number(o["width"], 220, in: 0...ObjectGeometry.maxCoordinate))
        // Ankerpunkt ist die linke obere Ecke (`startTextEditing`): `center` ist ihre Lage auf der Seite
        if abs(e.view.center.x - x) > 0.005 || abs(e.view.center.y - y) > 0.005 { e.view.center = CGPoint(x: x, y: y) }
        if abs(e.view.bounds.width - width) > 0.01 {
            e.view.bounds.size.width = width
            fitEditor(e, minHeight: CGFloat(StickyNote.minHeight(o)))
        }
    }

    /// Versatz beim Verschieben: eingerastete Textbloecke in ganzen Zeilen, alles bleibt auf der Seite
    func moveOffset(_ gr: Grab, _ t: CGPoint) -> CGPoint {
        var d = t
        if gr.snapsToLines { d.y = CGFloat(TextBlock.snappedDelta(Double(t.y))) }
        return Self.clampedOffset(gr.box, by: d, in: Self.page(of: gr.overlay))
    }

    /// Aenderung zeigen, ohne zu speichern: Objekte, Handschrift und Rahmen mit Anfassern im selben Schritt, ohne
    /// Animation - der Rahmen liegt in jedem Bild auf der Auswahl.
    func preview(_ change: Change) {
        guard var g = grab else { return }
        g.change = change
        grab = g
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch change {
        case .none:
            g.overlay.objectsView.previewMove(ids: g.ids, by: .zero)
            g.overlay.objectsView.preview(nil)
            inkDrag?.view.transform = .identity
            if !g.editorOnly { showFrame(g.box, on: g.overlay) }
            if let e = editing, g.ids.contains(e.id) { placeEditor(like: e.object) }
        case .move(let d):
            g.overlay.objectsView.previewMove(ids: g.ids, by: d)
            inkDrag?.view.transform = CGAffineTransform(translationX: d.x, y: d.y)
            if !g.editorOnly { showFrame(g.box.offsetBy(dx: d.x, dy: d.y), on: g.overlay) }
            // der Text, in dem getippt wird, folgt dem Finger (seine Anzeige auf der Seite ruht solange)
            if let e = editing, g.ids.contains(e.id) {
                placeEditor(like: PageObjectEdit.move([e.object], ids: [e.id], dx: Double(d.x), dy: Double(d.y)).first ?? e.object)
            }
        case .scale(let f, let anchor):
            let r = Self.resized(g.list, ids: g.ids, inkBox: g.inkBox, by: f, about: anchor, page: Self.page(of: g.overlay))
            g.overlay.objectsView.preview(r.objects.filter { ($0["id"]?.string).map(g.ids.contains) == true })
            if let view = inkDrag?.view {
                // die Ansicht dreht und skaliert um ihre Mitte: die Abbildung der Seite dorthin umrechnen
                let c = CGPoint(x: g.inkBox.midX, y: g.inkBox.midY), to = c.applying(r.inkTransform)
                view.transform = CGAffineTransform(a: r.inkTransform.a, b: r.inkTransform.b, c: r.inkTransform.c, d: r.inkTransform.d,
                                                   tx: to.x - c.x, ty: to.y - c.y)
            }
            showFrame(r.box, on: g.overlay)
            if let e = editing, let o = r.objects.first(where: { $0["id"]?.string == e.id }), g.ids.contains(e.id) { placeEditor(like: o) }
        }
        CATransaction.commit()
    }

    /// Loslassen: die zuletzt gezeigte Aenderung speichern (ein Rueckgaengig-Schritt)
    func finishGrab() {
        guard let g = grab else { return }
        grab = nil
        endTransferHover(g)
        switch g.change {
        case .move(let d) where abs(d.x) + abs(d.y) > 0.5 && g.editorOnly:
            // nur der Text, in dem getippt wird: ein neuer merkt sich die Stelle (gespeichert wird er mit dem Text), ein
            // vorhandener wird verschoben gespeichert; das Tippen geht weiter
            guard var e = editing else { return }
            if e.isNew {
                e.object = TextBlock.resnapped(PageObjectEdit.move([e.object], ids: [e.id], dx: Double(d.x), dy: Double(d.y))).first ?? e.object
                editing = e
                placeEditor(like: e.object)
            } else {
                let key = e.key, id = e.id
                Task { await commit(key) { PageObjectEdit.move($0, ids: [id], dx: Double(d.x), dy: Double(d.y)) } }
            }
        case .move(let d) where abs(d.x) + abs(d.y) > 0.5:
            finishMove(dx: d.x, dy: d.y)
        case .scale(let f, let anchor) where abs(f - 1) > 0.005:
            scaleSelection(by: f, about: anchor)
        default:
            grab = g
            cancelGrab()
        }
    }

    /// Abgebrochen oder nichts geaendert: alles wie vor dem Aufsetzen
    func cancelGrab() {
        guard let g = grab else { return }
        endTransferHover(g)
        preview(.none)
        grab = nil
        cancelInkDrag()
    }

    /// Das laufende Verschieben herausnehmen, ohne es zu beenden: Das Bild geht ins andere Dokument (`dropTransfer`)
    func takeGrab() -> Grab? {
        let g = grab
        grab = nil
        return g
    }

    func setTool(_ t: Tool) {
        let changed = tool != t
        tool = t
        onToolChange?(t)
        controller?.objectToolChangedInternally(t, changed: changed)   // die feste Leiste zeigt das neue Werkzeug
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: Auswahl

    func select(key: String, ids: Set<String>, in list: [JSONValue], ink: [Int] = []) {
        cancelGrab()
        // geteilte Ansicht: Wer etwas auswaehlt, arbeitet in diesem Editor (die Auswahl im anderen endet)
        if !ids.isEmpty || !ink.isEmpty { controller?.becomeActiveEditor() }
        selection = ids.isEmpty ? nil : (key, ids)
        inkSelection = ink.isEmpty ? nil : (key, ink)
        drawSelection(list)
        onSelectionChange?(ids.count + ink.count)
        publishFormat(list)
    }

    func clearSelection() {
        cancelGrab()
        selection = nil
        inkSelection = nil
        hideFrame()
        onSelectionChange?(0)
        publishFormat(nil)
    }

    func drawSelection(_ list: [JSONValue]) {
        guard !holdsFrame else { return }
        guard let key = selectedKey, let overlay = controller?.boundOverlay(forKey: key) else { hideFrame(); return }
        var box = selection.map { Self.box(of: list, ids: $0.ids) } ?? .null
        if let ink = inkSelection, overlay.loaded { box = box.union(Self.bounds(of: ink.indices, in: overlay.canvas.drawing)) }
        guard !box.isNull else { clearSelection(); return }
        showFrame(box, on: overlay)
    }

    /// Rahmen und Anfasser um `box` (Seitenpunkte) zeigen. Strich und Anfasser sind auf dem Bildschirm immer gleich
    /// gross, egal wie weit die Seite gezoomt ist (schmale Spalte daneben: unter 1-fach, hineingezoomt: mehrfach).
    private func showFrame(_ box: CGRect, on overlay: PageInkView) {
        selectionBox = box
        let s = Self.screenScale(of: overlay)
        let frame = box.insetBy(dx: -Self.frameGap, dy: -Self.frameGap)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.path = CGPath(rect: frame, transform: nil)
        selectionLayer.lineWidth = 1.5 / s
        selectionLayer.lineDashPattern = [NSNumber(value: Double(5 / s)), NSNumber(value: Double(4 / s))]
        if selectionLayer.superlayer !== overlay.content.layer { overlay.content.layer.addSublayer(selectionLayer) }
        let r = Self.handleRadius / s
        let shown = controller?.writable == true
        for (h, c) in zip(handleLayers, Self.corners(frame)) {
            h.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            h.position = c
            h.path = CGPath(ellipseIn: h.bounds, transform: nil)
            h.lineWidth = 1.5 / s
            h.isHidden = !shown
            if h.superlayer !== overlay.content.layer { overlay.content.layer.addSublayer(h) }
        }
        CATransaction.commit()
    }

    private func hideFrame() {
        selectionBox = .null
        selectionLayer.removeFromSuperlayer()
        selectionLayer.path = nil
        handleLayers.forEach { $0.removeFromSuperlayer() }
    }

    /// Zoom der Seite hat sich geaendert: Rahmen und Anfasser in der neuen Groesse
    private func refreshFrame() {
        guard grab == nil, let overlay = selectionOverlay else { return }
        showFrame(selectionBox, on: overlay)
    }

    // MARK: Aktionen auf der Auswahl (Leiste im Objektmodus)

    func deleteSelection() {
        guard hasSelection else { return }
        let sel = selection, ink = inkSelection
        clearSelection()
        Task {
            if let sel { await commit(sel.key) { PageObjectEdit.delete($0, ids: sel.ids) } }
            if let ink { await removeInk(ink) }                  // gleicher Durchlauf: ein Rueckgaengig-Schritt
        }
    }

    /// Farbe der Auswahl: Text `fill`, Haftnotiz `bg`, Formen `stroke`
    func recolorSelection(_ hex: String) {
        color = hex
        guard let sel = selection else { return }
        inOrder {
            await $0.commit(sel.key) { list in
                list.map { o in
                    guard let id = o["id"]?.string, sel.ids.contains(id), var obj = o.object else { return o }
                    if o["type"]?.string == "text" {
                        let key = (o["bg"]?.string ?? "").isEmpty ? "fill" : "bg"
                        // Textblock: die Schriftfarbe gilt fuer alle Abschnitte
                        if key == "fill", TextBlock.isBlock(o) { return TextBlock.applying(.fill(hex), to: o) }
                        obj[key] = .string(hex)
                    }
                    else if o["type"]?.string == "shape" { obj[o["markup"]?.string == "highlight" || FlipCover.isCover(o) ? "fill" : "stroke"] = .string(hex) }
                    return .object(obj)
                }
            }
        }
    }

    /// Schrift der ausgewaehlten Textfelder groesser/kleiner
    func resizeText(by delta: Double) {
        guard let sel = selection else { return }
        inOrder {
            await $0.commit(sel.key) { list in
                list.map { o in
                    guard let id = o["id"]?.string, sel.ids.contains(id), o["type"]?.string == "text", var obj = o.object else { return o }
                    if TextBlock.isBlock(o) { return TextBlock.applying(.sizeDelta(delta), to: o) }
                    obj["fontSize"] = .number(min(200, max(6, (o["fontSize"]?.double ?? 14) + delta)))
                    return .object(obj)
                }
            }
        }
    }

    // MARK: Speichern mit Rueckgaengig

    /// `true`, wenn sich etwas geaendert hat
    @discardableResult
    func commit(_ key: String, undoable: Bool = true, _ change: @escaping ([JSONValue]) -> [JSONValue]) async -> Bool {
        guard let c = controller, c.writable else { return false }
        guard let before = await c.store.editObjects(pageKey: key, { Self.resnappingChanged($0, change($0)) }) else { return false }
        let after = await objects(key)
        if undoable { registerUndo(key: key, restore: before, then: after) }
        // Text, in dem gerade getippt wird: Lage und Breite aus dem gespeicherten Stand (verschoben, Groesse geaendert,
        // umgestaltet) - die Textansicht steht wieder genau auf dem Objekt, das Tippen geht weiter
        if var e = editing, e.key == key, !e.isNew, let o = after.first(where: { $0["id"]?.string == e.id }) {
            for k in ["x", "y", "width", "minHeight", "rotation", "bg", "note"] { e.object[k] = o[k] }
            editing = e
            placeEditor(like: e.object)
        }
        if let sel = selection, sel.key == key {
            drawSelection(after)
            publishFormat(after)
        }
        return true
    }

    /// Textbloecke auf Linien: was sich in diesem Schritt geaendert hat oder neu ist (verschoben, eingefuegt, dupliziert,
    /// Groesse), rastet wieder ein. Unveraenderte Objekte bleiben, wie sie sind.
    nonisolated static func resnappingChanged(_ before: [JSONValue], _ after: [JSONValue]) -> [JSONValue] {
        let old = Set(before)
        let changed = Set(after.filter { !old.contains($0) && TextBlock.isSnapped($0) }.compactMap { $0["id"]?.string })
        return changed.isEmpty ? after : TextBlock.resnapped(after, ids: changed)
    }

    /// Formatierung der Auswahl an die Leiste melden (`list`: Objekte der Seite; nil = nichts gewaehlt)
    func publishFormat(_ list: [JSONValue]?) {
        // ohne Liste (Tippen beendet, nichts gespeichert): der zuletzt gezeigte Stand der Seite der Auswahl
        let shown = list ?? selection.flatMap { controller?.boundOverlay(forKey: $0.key)?.objectsView.shownObjects }
        let f = editing != nil ? editingFormat() : shown.flatMap { selectionFormat($0) }
        guard f != textFormat else { return }
        textFormat = f
        onTextFormat?(f)
    }

    /// Rueckgaengig stellt `restore` her. Der Gegenschritt (Wiederholen: `then`) wird sofort im Handler angemeldet:
    /// erst nach einem `await` angemeldet, zaehlte er beim UndoManager als neuer Rueckgaengig-Schritt.
    private func registerUndo(key: String, restore: [JSONValue], then redo: [JSONValue]) {
        guard let c = controller else { return }
        c.editUndo.beginSeparateStep()                      // eigener Schritt, nie mit einem Strich zusammen
        c.editUndo.registerUndo(withTarget: self) { me in
            me.registerUndo(key: key, restore: redo, then: restore)
            me.clearSelection()
            Task { @MainActor in _ = await me.controller?.store.editObjects(pageKey: key) { _ in restore } }
        }
        c.editUndo.setActionName("Objekte")
    }

    // MARK: Fuer Tests

    var editingTextView: UITextView? { editing?.view }
    var grabForTesting: Grab? { grab }
    func selectForTesting(key: String, ids: Set<String>) async { select(key: key, ids: ids, in: await objects(key)) }
}
