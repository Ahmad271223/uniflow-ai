import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// Unsichtbarer Erstantwortgeber fuer die Werkzeugpalette. Die Palette haengt damit nicht an einer Seiten-Canvas,
/// die beim Scrollen verschwindet (sonst schliesst sich die Palette, sobald die erste Seite aus dem Bild ist).
final class ToolPickerAnchor: UIView {
    override var canBecomeFirstResponder: Bool { true }
}

/// Overlay einer Seite: Vorlage und Web-Objekte (Text, Formen, Bilder) unten, PencilKit-Canvas oben.
/// Beide arbeiten in Seitenpunkten (wie der Web-Editor); passt PDFKit die Overlay-Groesse an, gleicht eine
/// Skalierung des Inhalts das aus. Die Canvas scrollt und zoomt nie selbst.
final class PageInkView: UIView {
    let pageIndex: Int
    /// Fester Seitenschluessel aus `pageOrder` (gespeichert wird immer ueber ihn, nie ueber den Index).
    let pageKey: String
    /// Seitenaufbau, zu dem das Overlay gehoert; nach Einfuegen/Drehen wird es nicht wiederverwendet.
    let generation: Int
    let geometry: PageGeometry
    let content = UIView()
    let objectsView: PageObjectsView
    let canvas = PKCanvasView()
    /// Zeichnung wird gerade programmatisch gesetzt (kein Speichern ausloesen).
    var isApplyingDrawing = false
    /// Stift ist gerade auf dieser Canvas aktiv.
    var isDrawing = false
    /// Neuer Stand vom Server, der wartet, bis der laufende Strich fertig ist.
    var deferredReload = false
    var loaded = false

    init(pageIndex: Int, pageKey: String = "", generation: Int = 0, geometry: PageGeometry) {
        self.pageIndex = pageIndex
        self.pageKey = pageKey
        self.generation = generation
        self.geometry = geometry
        let rect = CGRect(origin: .zero, size: geometry.pageSize)
        objectsView = PageObjectsView(frame: rect)
        super.init(frame: rect)
        backgroundColor = .clear
        isOpaque = false
        content.bounds = rect
        content.backgroundColor = .clear
        canvas.frame = rect
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        content.addSubview(objectsView)
        content.addSubview(canvas)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = geometry.scale(forViewSize: bounds.size)
        content.bounds = CGRect(origin: .zero, size: geometry.pageSize)
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        content.transform = abs(s - 1) < 0.0001 ? .identity : CGAffineTransform(scaleX: s, y: s)
    }
}

/// Nativer PDF-Arbeitsbereich: PDFKit zeigt, scrollt und zoomt; PencilKit schreibt.
///
/// - Finger: Scrollen und Zoomen (PDFKit). Der Stift scrollt nie (`allowedTouchTypes` der Scroll-Gesten).
/// - "Finger zeichnet": Scrollen dann mit zwei Fingern.
/// - Zoom wird nach dem ersten Einpassen nicht mehr automatisch zurueckgesetzt (siehe `ZoomPolicy`).
/// - Seiten-Overlays werden wiederverwendet (die letzten 6), statt beim Zurueckscrollen neu aufgebaut zu werden.
final class PDFEditorController: UIViewController, PDFPageOverlayViewProvider, PKCanvasViewDelegate, PKToolPickerObserver {

    private let store: DocumentStore
    let pdfView = PDFView()
    private let toolPicker: PKToolPicker
    /// Nur ein Editor zeigt die Palette (geteilte Ansicht: Uebung und Skript teilen sich eine Palette).
    private let ownsToolPicker: Bool
    /// PDF-Seite (1-basiert), zu der beim ersten Anzeigen gesprungen wird (z. B. Skriptstelle).
    private var initialPDFPage: Int?
    private let anchor = ToolPickerAnchor()
    /// In der geteilten Ansicht teilen sich beide Dokumente einen Verlauf, damit "Rueckgaengig" der gemeinsamen
    /// Palette immer den zuletzt geschriebenen Strich zuruecknimmt, egal auf welcher Seite.
    private let documentUndo: UndoManager
    private var live: [Int: PageInkView] = [:]
    private var parked: [PageInkView] = []
    private let parkedLimit = 6
    private var lastFit: CGFloat = 0
    private var userZoomed = false
    private var observers: [NSObjectProtocol] = []
    private(set) var shownLayoutVersion = -1

    var onZoomChange: ((CGFloat) -> Void)?
    /// Anzeige-Index und Seitenschluessel der aktuellen Seite.
    var onPageChange: ((Int, String?) -> Void)?
    /// Seitenaufbau, den die PDFView gerade zeigt (kann kurz vom neuesten Stand im Store abweichen).
    private var shownLayout: DisplayLayout?

    var pencilOnly = true {
        didSet {
            guard pencilOnly != oldValue else { return }
            allOverlays.forEach { $0.canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput }
            configureScrollGestures()
        }
    }

    override var undoManager: UndoManager? { documentUndo }

    init(store: DocumentStore, toolPicker: PKToolPicker? = nil, ownsToolPicker: Bool = true,
         undoManager: UndoManager? = nil, initialPDFPage: Int? = nil) {
        self.store = store
        self.toolPicker = toolPicker ?? PKToolPicker()
        self.ownsToolPicker = ownsToolPicker
        self.documentUndo = undoManager ?? UndoManager()
        self.initialPDFPage = initialPDFPage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private var allOverlays: [PageInkView] { Array(live.values) + parked }

    var currentPageIndex: Int {
        guard let page = pdfView.currentPage, let doc = pdfView.document else { return 0 }
        return doc.index(for: page)
    }

    var currentPageKey: String? { shownLayout?.key(at: currentPageIndex) }

    // MARK: Aufbau

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        anchor.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        anchor.isUserInteractionEnabled = false
        view.addSubview(anchor)

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.autoScales = true                     // nur fuer das erste Einpassen, danach aus
        pdfView.pageOverlayViewProvider = self        // vor dem Setzen des Dokuments
        pdfView.isInMarkupMode = true                 // Overlays bekommen die Stifteingabe, keine Textauswahl
        showLayout()

        toolPicker.addObserver(self)
        if ownsToolPicker {
            toolPicker.stateAutosaveName = "uniflow.toolpicker"
            toolPicker.setVisible(true, forFirstResponder: anchor)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scaleChanged() }
        })
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onPageChange?(self.currentPageIndex, self.currentPageKey)
            }
        })
        store.onPagesChanged = { [weak self] keys in self?.reloadPages(keys) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureScrollGestures()
        if ownsToolPicker { anchor.becomeFirstResponder() }
        if let p = initialPDFPage {
            initialPDFPage = nil
            // PDF-Seite -> Anzeige-Index (eingefuegte oder entfernte Seiten verschieben die Zaehlung)
            let index = shownLayout?.entries.firstIndex { $0.pdfIndex == p } ?? max(0, p - 1)
            goToPage(index)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if ownsToolPicker { toolPicker.setVisible(false, forFirstResponder: anchor) }
        for v in allOverlays where v.loaded { store.canvasChanged(pageKey: v.pageKey, drawing: v.canvas.drawing) }
        if !ownsToolPicker {
            // geteilter Verlauf: Eintraege dieses Dokuments entfernen, sonst wirkt "Rueckgaengig" ins Leere
            for v in allOverlays { documentUndo.removeAllActions(withTarget: v.canvas) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fit = pdfView.scaleFactorForSizeToFit
        guard fit > 0 else { return }
        if lastFit == 0 {
            pdfView.autoScales = false
            applyLimits(fit: fit)
            pdfView.scaleFactor = fit
        } else if abs(fit - lastFit) > 0.0001 {
            let next = ZoomPolicy.scaleAfterResize(current: pdfView.scaleFactor, oldFit: lastFit, newFit: fit, userZoomed: userZoomed)
            applyLimits(fit: fit)
            pdfView.scaleFactor = next
        }
        lastFit = fit
    }

    private func applyLimits(fit: CGFloat) {
        let range = ZoomPolicy.limits(fitScale: fit)
        pdfView.minScaleFactor = range.lowerBound
        pdfView.maxScaleFactor = range.upperBound
    }

    private func scaleChanged() {
        if lastFit > 0 { userZoomed = ZoomPolicy.isUserZoom(scale: pdfView.scaleFactor, fitScale: lastFit) }
        onZoomChange?(lastFit > 0 ? pdfView.scaleFactor / lastFit : 1)
    }

    /// Stift scrollt nie; im Finger-Zeichenmodus scrollen zwei Finger.
    private func configureScrollGestures() {
        guard let scroll = firstScrollView(in: pdfView) else { return }
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.panGestureRecognizer.allowedTouchTypes = fingers
        scroll.panGestureRecognizer.minimumNumberOfTouches = pencilOnly ? 1 : 2
        scroll.pinchGestureRecognizer?.allowedTouchTypes = fingers
        scroll.delaysContentTouches = false
    }

    private func firstScrollView(in v: UIView) -> UIScrollView? {
        if let s = v as? UIScrollView { return s }
        for sub in v.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
    }

    // MARK: Anzeige-PDF (neu aufbauen, wenn sich die Seitenstruktur aendert)

    /// Zeigt den aktuellen Seitenaufbau. Bleibt auf derselben Seite (ueber den Seitenschluessel) und beim Zoom.
    func showLayout() {
        guard store.layoutVersion != shownLayoutVersion, let layout = store.layout else { return }
        let keepKey = currentPageKey
        let keepScale = pdfView.scaleFactor
        // offene Canvases ueber ihren Schluessel sichern (Indizes koennen sich gerade verschoben haben)
        for v in allOverlays where v.loaded { store.canvasChanged(pageKey: v.pageKey, drawing: v.canvas.drawing) }
        for v in allOverlays {
            toolPicker.removeObserver(v.canvas)
            documentUndo.removeAllActions(withTarget: v.canvas)
        }
        live = [:]
        parked = []
        shownLayout = layout
        shownLayoutVersion = store.layoutVersion
        let pdf = layout.pdf
        pdfView.document = pdf
        if lastFit > 0 { pdfView.scaleFactor = keepScale }
        if let keepKey, let i = layout.index(ofKey: keepKey), let page = pdf.page(at: i) { pdfView.go(to: page) }
        // aktuelle Seite melden (auch ohne Blaettern), nach der laufenden SwiftUI-Aktualisierung
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPageChange?(self.currentPageIndex, self.currentPageKey)
        }
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let doc = view.document, doc === shownLayout?.pdf else { return nil }
        let index = doc.index(for: page)
        guard let key = shownLayout?.key(at: index) else { return nil }
        if let existing = live[index], existing.generation == shownLayoutVersion { return existing }
        let overlay: PageInkView
        if let i = parked.firstIndex(where: { $0.pageIndex == index && $0.generation == shownLayoutVersion }) {
            overlay = parked.remove(at: i)
        } else {
            let box = page.bounds(for: .cropBox).size
            overlay = PageInkView(pageIndex: index, pageKey: key, generation: shownLayoutVersion,
                                  geometry: PageGeometry(boxSize: box, rotation: page.rotation))
            configure(overlay)
            loadContent(into: overlay)
        }
        live[index] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageInkView else { return }
        if overlay.loaded { store.canvasChanged(pageKey: overlay.pageKey, drawing: overlay.canvas.drawing) }
        if live[overlay.pageIndex] === overlay { live.removeValue(forKey: overlay.pageIndex) }
        guard overlay.generation == shownLayoutVersion else {       // Overlay eines alten Seitenaufbaus: verwerfen
            toolPicker.removeObserver(overlay.canvas)
            documentUndo.removeAllActions(withTarget: overlay.canvas)
            return
        }
        parked.append(overlay)
        while parked.count > parkedLimit {
            let old = parked.removeFirst()
            toolPicker.removeObserver(old.canvas)
            documentUndo.removeAllActions(withTarget: old.canvas)
        }
    }

    private func configure(_ overlay: PageInkView) {
        let c = overlay.canvas
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        c.delegate = self
        c.tool = toolPicker.selectedTool
        toolPicker.addObserver(c)
    }

    private func loadContent(into overlay: PageInkView) {
        Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay else { return }
            let entry = self.store.entry(forKey: overlay.pageKey)
            let objects = await self.store.objects(forPageKey: overlay.pageKey)
            self.showObjects(objects, entry: entry, on: overlay)
            let drawing = await self.store.drawing(forPageKey: overlay.pageKey)
            self.apply(drawing, to: overlay)
        }
    }

    private func showObjects(_ objects: [JSONValue], entry: DisplayLayout.Entry?, on overlay: PageInkView) {
        let placeholder = entry?.kind == "asset" ? "Eingefügte Seite aus dem Browser – Inhalt nur dort sichtbar. Notizen hier werden gespeichert." : nil
        overlay.objectsView.show(template: entry?.template, placeholder: placeholder, objects: objects, images: store.images)
        for o in objects where o["type"]?.string == "image" {
            if let src = o["src"]?.string, store.images[src] == nil {
                store.loadImage(src) { [weak self, weak overlay] in
                    guard let self, let overlay else { return }
                    overlay.objectsView.show(template: entry?.template, placeholder: placeholder, objects: objects, images: self.store.images)
                }
            }
        }
    }

    /// Zeichnung setzen, ohne einen laufenden Strich zu unterbrechen. Striche, die schon vor dem Laden auf der
    /// Canvas entstanden sind, bleiben erhalten.
    private func apply(_ drawing: PKDrawing, to overlay: PageInkView) {
        if overlay.isDrawing { overlay.deferredReload = true; return }
        var next = drawing
        if !overlay.loaded, !overlay.canvas.drawing.strokes.isEmpty { next.append(overlay.canvas.drawing) }
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = next
        overlay.isApplyingDrawing = false
        let hadEarlyStrokes = !overlay.loaded && next.strokes.count != drawing.strokes.count
        overlay.loaded = true
        if hadEarlyStrokes { store.canvasChanged(pageKey: overlay.pageKey, drawing: next) }
    }

    private func reloadPages(_ keys: [String]) {
        let wanted = Set(keys)
        for overlay in allOverlays where wanted.contains(overlay.pageKey) {
            if overlay.isDrawing { overlay.deferredReload = true } else { loadContent(into: overlay) }
        }
    }

    // MARK: PKCanvasViewDelegate

    private func overlay(of canvasView: PKCanvasView) -> PageInkView? {
        canvasView.superview?.superview as? PageInkView
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let overlay = overlay(of: canvasView), !overlay.isApplyingDrawing, overlay.loaded else { return }
        store.canvasChanged(pageKey: overlay.pageKey, drawing: canvasView.drawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        overlay(of: canvasView)?.isDrawing = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let overlay = overlay(of: canvasView) else { return }
        overlay.isDrawing = false
        if overlay.deferredReload {
            overlay.deferredReload = false
            loadContent(into: overlay)
        }
    }

    // MARK: Steuerung von aussen

    func goToPage(_ index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func show(_ selection: PDFSelection) {
        pdfView.highlightedSelections = [selection]
        pdfView.go(to: selection)
    }

    func undo() { documentUndo.undo() }
    func redo() { documentUndo.redo() }

    func fitWidth() {
        guard lastFit > 0 else { return }
        userZoomed = false
        pdfView.scaleFactor = lastFit
    }

    func showToolPicker(_ visible: Bool) {
        guard ownsToolPicker else { return }
        toolPicker.setVisible(visible, forFirstResponder: anchor)
        if visible { anchor.becomeFirstResponder() }
    }
}
