import PDFKit
import PencilKit
import UIKit

/// Nativer PDF-Arbeitsbereich: PDFKit zeigt, scrollt und zoomt; PencilKit zeichnet.
///
/// Pro sichtbarer PDF-Seite liefert `PDFPageOverlayViewProvider` eine `PKCanvasView`, die PDFKit mit der Seite
/// positioniert und beim Zoomen mitskaliert. Die Zeichnung liegt dadurch in Seitenpunkten (Ursprung oben links),
/// genau wie im Web-Editor. Die Canvas scrollt und zoomt nie selbst (`isScrollEnabled = false`), damit PDFKit
/// und PencilKit die Seite nicht gleichzeitig verschieben. Finger-Gesten bleiben bei PDFKit (Scrollen, Zoomen).
final class PDFEditorController: UIViewController, PDFPageOverlayViewProvider, PKCanvasViewDelegate, PKToolPickerObserver {

    private let store: DocumentStore
    private let pdfView = PDFView()
    private let toolPicker = PKToolPicker()
    private var canvases: [PDFPage: PKCanvasView] = [:]

    var pencilOnly = true {
        didSet { canvases.values.forEach { $0.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput } }
    }

    init(store: DocumentStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

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
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.pageOverlayViewProvider = self      // vor dem Setzen des Dokuments
        pdfView.isInMarkupMode = true               // Seitenoverlays bekommen die Stifteingabe, keine Textauswahl
        pdfView.document = store.pdf

        toolPicker.addObserver(self)
        toolPicker.selectedTool = PKInkingTool(.pen, color: .label, width: 2)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fit = pdfView.scaleFactorForSizeToFit
        if fit > 0 {
            pdfView.minScaleFactor = fit * 0.5
            pdfView.maxScaleFactor = fit * 6
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        for (page, canvas) in canvases {
            if let index = store.pdf?.index(for: page) { store.update(drawing: canvas.drawing, pageIndex: index) }
        }
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let existing = canvases[page] { return existing }
        let canvas = PKCanvasView(frame: .zero)
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        if let index = store.pdf?.index(for: page) {
            canvas.tag = index
            canvas.drawing = store.drawing(forPageIndex: index)
        }
        canvas.delegate = self
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvases[page] = canvas
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.canvases.values.contains(where: { $0.isFirstResponder }) else { return }
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        if let index = store.pdf?.index(for: page) { store.update(drawing: canvas.drawing, pageIndex: index) }
        toolPicker.removeObserver(canvas)
        canvases.removeValue(forKey: page)
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        store.update(drawing: canvasView.drawing, pageIndex: canvasView.tag)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        if !canvasView.isFirstResponder {
            canvasView.becomeFirstResponder()
            toolPicker.setVisible(true, forFirstResponder: canvasView)
        }
    }

    // MARK: Steuerung von aussen

    func goToPage(_ index: Int) {
        guard let page = store.pdf?.page(at: index) else { return }
        pdfView.go(to: page)
    }
}
