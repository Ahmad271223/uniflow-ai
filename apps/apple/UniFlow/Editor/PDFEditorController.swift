import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// Unsichtbarer Erstantwortgeber fuer die Werkzeugpalette. Die Palette haengt damit nicht an einer Seiten-Canvas,
/// die beim Scrollen verschwindet (sonst schliesst sich die Palette, sobald die erste Seite aus dem Bild ist).
final class ToolPickerAnchor: UIView {
    override var canBecomeFirstResponder: Bool { true }
}

/// Overlay einer PDF-Seite. Die Canvas arbeitet immer in Seitenpunkten (wie der Web-Editor); passt PDFKit die
/// Overlay-Groesse an, gleicht eine Skalierung das aus. Die Canvas scrollt und zoomt nie selbst.
final class PageInkView: UIView {
    let pageIndex: Int
    let geometry: PageGeometry
    let canvas = PKCanvasView()
    /// Zeichnung wird gerade programmatisch gesetzt (kein Speichern ausloesen).
    var isApplyingDrawing = false
    /// Stift ist gerade auf dieser Canvas aktiv.
    var isDrawing = false
    /// Neuer Stand vom Server, der wartet, bis der laufende Strich fertig ist.
    var deferredReload = false
    var loaded = false

    init(pageIndex: Int, geometry: PageGeometry) {
        self.pageIndex = pageIndex
        self.geometry = geometry
        super.init(frame: CGRect(origin: .zero, size: geometry.pageSize))
        backgroundColor = .clear
        isOpaque = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.bounds = CGRect(origin: .zero, size: geometry.pageSize)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = geometry.scale(forViewSize: bounds.size)
        canvas.bounds = CGRect(origin: .zero, size: geometry.pageSize)
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.transform = abs(s - 1) < 0.0001 ? .identity : CGAffineTransform(scaleX: s, y: s)
    }
}

/// Nativer PDF-Arbeitsbereich: PDFKit zeigt, scrollt und zoomt; PencilKit schreibt.
///
/// - Finger: Scrollen und Zoomen (PDFKit). Der Stift scrollt nie (`allowedTouchTypes` der Scroll-Gesten).
/// - "Finger zeichnet": Scrollen dann mit zwei Fingern.
/// - Zoom wird nach dem ersten Einpassen nicht mehr automatisch zurueckgesetzt (siehe `ZoomPolicy`).
/// - Seiten-Canvases werden wiederverwendet (die letzten 6), statt beim Zurueckscrollen neu aufgebaut zu werden.
final class PDFEditorController: UIViewController, PDFPageOverlayViewProvider, PKCanvasViewDelegate, PKToolPickerObserver {

    private let store: DocumentStore
    let pdfView = PDFView()
    private let toolPicker = PKToolPicker()
    private let anchor = ToolPickerAnchor()
    private let documentUndo = UndoManager()
    private var live: [Int: PageInkView] = [:]
    private var parked: [PageInkView] = []
    private let parkedLimit = 6
    private var lastFit: CGFloat = 0
    private var userZoomed = false
    private var observers: [NSObjectProtocol] = []

    var onZoomChange: ((CGFloat) -> Void)?
    var onPageChange: ((Int) -> Void)?

    var pencilOnly = true {
        didSet {
            guard pencilOnly != oldValue else { return }
            allCanvases.forEach { $0.canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput }
            configureScrollGestures()
        }
    }

    override var undoManager: UndoManager? { documentUndo }

    init(store: DocumentStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private var allCanvases: [PageInkView] { Array(live.values) + parked }

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
        pdfView.document = store.pdf

        toolPicker.stateAutosaveName = "uniflow.toolpicker"
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: anchor)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.scaleChanged()
        })
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self, let page = self.pdfView.currentPage, let doc = self.pdfView.document else { return }
            self.onPageChange?(doc.index(for: page))
        })
        store.onPagesChanged = { [weak self] indices in self?.reloadPages(indices) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureScrollGestures()
        anchor.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        toolPicker.setVisible(false, forFirstResponder: anchor)
        for v in allCanvases where v.loaded { store.canvasChanged(pageIndex: v.pageIndex, drawing: v.canvas.drawing) }
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

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let doc = view.document else { return nil }
        let index = doc.index(for: page)
        if let existing = live[index] { return existing }
        let overlay: PageInkView
        if let i = parked.firstIndex(where: { $0.pageIndex == index }) {
            overlay = parked.remove(at: i)
        } else {
            let box = page.bounds(for: .cropBox).size
            overlay = PageInkView(pageIndex: index, geometry: PageGeometry(boxSize: box, rotation: page.rotation))
            configure(overlay)
            loadDrawing(into: overlay)
        }
        live[index] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageInkView else { return }
        live.removeValue(forKey: overlay.pageIndex)
        parked.append(overlay)
        while parked.count > parkedLimit {
            let old = parked.removeFirst()
            toolPicker.removeObserver(old.canvas)
        }
    }

    private func configure(_ overlay: PageInkView) {
        let c = overlay.canvas
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        c.delegate = self
        c.tool = toolPicker.selectedTool
        toolPicker.addObserver(c)
    }

    private func loadDrawing(into overlay: PageInkView) {
        Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay else { return }
            let drawing = await self.store.drawing(forPageIndex: overlay.pageIndex)
            self.apply(drawing, to: overlay)
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
        if hadEarlyStrokes { store.canvasChanged(pageIndex: overlay.pageIndex, drawing: next) }
    }

    private func reloadPages(_ indices: [Int]) {
        for i in indices {
            guard let overlay = live[i] ?? parked.first(where: { $0.pageIndex == i }) else { continue }
            loadDrawing(into: overlay)
        }
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let overlay = canvasView.superview as? PageInkView, !overlay.isApplyingDrawing, overlay.loaded else { return }
        store.canvasChanged(pageIndex: overlay.pageIndex, drawing: canvasView.drawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        (canvasView.superview as? PageInkView)?.isDrawing = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let overlay = canvasView.superview as? PageInkView else { return }
        overlay.isDrawing = false
        if overlay.deferredReload {
            overlay.deferredReload = false
            loadDrawing(into: overlay)
        }
    }

    // MARK: Steuerung von aussen

    func goToPage(_ index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func undo() { documentUndo.undo() }
    func redo() { documentUndo.redo() }
    var canUndo: Bool { documentUndo.canUndo }
    var canRedo: Bool { documentUndo.canRedo }

    func fitWidth() {
        guard lastFit > 0 else { return }
        userZoomed = false
        pdfView.scaleFactor = lastFit
    }

    func showToolPicker(_ visible: Bool) {
        toolPicker.setVisible(visible, forFirstResponder: anchor)
        if visible { anchor.becomeFirstResponder() }
    }
}
