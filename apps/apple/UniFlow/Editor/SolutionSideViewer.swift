import PDFKit
import PencilKit
import SwiftUI
import UIKit
import UniFlowCore

/// "Lösung daneben ansehen": die fremde Loesung in einer eigenen, nur lesbaren PDFView neben dem eigenen Dokument.
///
/// Meldung des Inhabers 20.11.2026: "nicht 1 zu 1 wie das Original-Dokument, wie man es beschriftet; man kann nicht
/// reinzoomen". Bis dahin war die Spalte eine Liste fester Bilder (`SolutionPreview.image`): Striche zeichnete dort die
/// Vektor-Routine des PDF-Exports, nicht PencilKit wie auf der Canvas des Absenders (gemessen: Stift 3 pt -> 2 pt,
/// 8 pt -> 12 pt bei PencilKit, `ForeignInkWidthTests`), die PDF-Seite kam ohne die Drehung des Absenders, und ein
/// Bild laesst sich nicht vergroessern.
///
/// Jetzt zeigt die Spalte jede geteilte Seite wie der Editor: PDF-Seite aus einer EIGENEN PDF-Instanz (nie die PDF der
/// Haupt-PDFView oder das Original im Store, siehe `OffscreenPDF`), gedreht wie beim Absender; darueber dasselbe
/// Seiten-Overlay (`PageInkView`) mit derselben fremden Ebene (`ForeignLayerView`), die auch die Einblendung auf der
/// eigenen PDF benutzt. Positionen, Groessen, Strichbreiten, Farben, Textmarker, Formen, Text und Bilder sind damit
/// dieselben. Zoomen: zwei Finger, Doppeltippen (Mac: Trackpad-Pinch, Doppelklick); die Tinte wird nach dem Zoomen
/// in der Aufloesung der Anzeige neu gezeichnet (wie im Editor).
final class SolutionSideController: UIViewController, PDFPageOverlayViewProvider, UIGestureRecognizerDelegate {
    let layer: ForeignSolutionLayer
    /// Datei der eigenen Original-PDF (nil: Notizbuch ohne PDF; an der Stelle von PDF-Seiten steht dann der Hinweis)
    let pdfURL: URL?
    let pdfView = PDFView()
    /// Klappkarten der geteilten Loesung: Antippen deckt auf und verdeckt wieder, wie beim Absender
    let coverTapper = CoverTapper()
    /// eigene Instanz der Original-PDF; die Seiten der Spalte sind Kopien daraus und brauchen sie, solange sie leben
    private var source: PDFDocument?
    /// eigene Instanz der aufbewahrten Fassung des Absenders (Loesung zu einer anderen Fassung, `layer.oldVersionURL`)
    private var oldSource: PDFDocument?
    /// Overlays der Seiten, die PDFKit gerade zeigt (Index in `pdfView.document` = Index in `layer.pages`)
    private(set) var overlays: [Int: PageInkView] = [:]
    private var observers: [NSObjectProtocol] = []
    private var renderTask: Task<Void, Never>?
    /// Massstab "Seite passt in die Breite" (0 = noch nicht eingepasst)
    private(set) var fitScale: CGFloat = 0
    private(set) var userZoomed = false
    let doubleTap = UITapGestureRecognizer()
    var onPageChange: ((Int) -> Void)?

    init(layer: ForeignSolutionLayer, pdfURL: URL?) {
        self.layer = layer
        self.pdfURL = pdfURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        renderTask?.cancel()
    }

    // MARK: Seiten

    /// Anzeige-PDF der Spalte: je geteilte Seite eine Seite in der Reihenfolge des Absenders
    static func document(for layer: ForeignSolutionLayer, pdf: PDFDocument?, old: PDFDocument? = nil) -> PDFDocument {
        let doc = PDFDocument()
        for (i, p) in layer.pages.enumerated() { doc.insert(page(p, pdf: pdf, old: old, placement: layer.placement(p)), at: i) }
        return doc
    }

    /// Eine geteilte Seite so, wie der Absender sie sah: PDF-Seite (Kopie aus der eigenen Instanz) bzw. leeres Blatt in
    /// seiner Groesse, jeweils mit der Drehung des Absenders (`/Rotate` + eigene Drehung; in ihr stehen die Objekte).
    /// Loesung zu einer anderen Fassung (`placement`): gleich gebliebene Seite = die eigene Seite an ihrer Stelle in der
    /// eigenen Fassung, geaenderte = die Seite der aufbewahrten Fassung des Absenders (`old`); ohne sie ein leeres Blatt,
    /// auf dem nur `SolutionVersions.pageChanged` steht (`overlay`), nie die Striche.
    /// Laesst sich eine PDF-Seite nicht oeffnen (Datei fehlt oder ist nicht lesbar, Seite gibt es nicht), entsteht
    /// ebenfalls ein leeres Blatt in ihrer Groesse – darauf steht dann nur der Hinweis (`missingPDFPage`, `overlay`).
    static func page(_ p: SolutionPage, pdf: PDFDocument?, old: PDFDocument? = nil, placement: SolutionVersions.Placement? = nil) -> PDFPage {
        let target: (doc: PDFDocument?, index: Int?)
        switch placement {
        case .own(let j)?: target = (pdf, j)
        case .oldVersion(let i)?: target = (old, i)
        case .changed?: target = (nil, nil)
        case nil: target = (pdf, p.pdfIndex)
        }
        if p.kind == .pdf, let i = target.index, i >= 1, let src = target.doc?.page(at: i - 1), let copy = src.copy() as? PDFPage {
            copy.rotation = p.rotation
            return copy
        }
        let box = CGRect(x: 0, y: 0, width: ForeignLayerView.pageSide(p.width), height: ForeignLayerView.pageSide(p.height))
        let blank = PDFPage()
        blank.setBounds(box, for: .mediaBox)
        blank.setBounds(box, for: .cropBox)
        blank.rotation = p.rotation
        return blank
    }

    /// Overlay einer Seite: dasselbe `PageInkView` wie im Editor, ohne eigene Zeichenflaeche und ohne Eingabe; die fremde
    /// Ebene liegt darin wie bei der Einblendung (gemeinsame PencilKit-Flaeche fuer die Striche). Leere Blaetter
    /// bekommen ihr Papier (liniert, kariert ...) unter der Ebene.
    static func overlay(for p: SolutionPage, page: PDFPage, index: Int, layer: ForeignSolutionLayer) -> PageInkView {
        let o = PageInkView(pageIndex: index, pageKey: p.key,
                            geometry: PageGeometry(boxSize: page.bounds(for: .cropBox).size, rotation: page.rotation))
        o.isUserInteractionEnabled = false                 // Ziehen und Zoomen gehoeren der PDFView
        o.canvas.isUserInteractionEnabled = false
        o.canvas.drawingGestureRecognizer.isEnabled = false
        o.canvas.removeFromSuperview()                     // eigene Notizen gibt es hier nicht
        // Seite in der eigenen Fassung geaendert und die alte liegt nicht auf dem Geraet, oder die PDF-Seite laesst sich
        // nicht oeffnen: nur der Satz, nie die Striche auf einer weissen Seite (Inhaber 26.11.2026)
        let hidden: UIView? = layer.placement(p) == .changed ? changedNotice()
            : missingPDFPage(p, page: page) ? missingNotice(placement: layer.placement(p)) : nil
        if let notice = hidden {
            o.objectsView.isHidden = true
            o.addSubview(notice)
            NSLayoutConstraint.activate([
                notice.leadingAnchor.constraint(equalTo: o.leadingAnchor), notice.trailingAnchor.constraint(equalTo: o.trailingAnchor),
                notice.topAnchor.constraint(equalTo: o.topAnchor), notice.bottomAnchor.constraint(equalTo: o.bottomAnchor),
            ])
            return o
        }
        if p.kind == .blank {
            o.objectsView.show(template: p.template, placeholder: nil, objects: [], images: [:])
            o.content.sendSubviewToBack(o.objectsView)     // Papier unter der Loesung
        } else {
            o.objectsView.isHidden = true
        }
        let foreign = ForeignLayerView(solutionID: layer.id, page: p, images: layer.images, targetRotation: page.rotation,
                                       label: layer.label)
        o.setForeign([foreign])
        return o
    }

    /// Die Seite steht auf der PDF, aber `page` ist nur das leere Ersatzblatt (`page(_:pdf:old:placement:)` konnte die
    /// PDF-Seite nicht oeffnen). Eigene Blaetter des Absenders (`.blank`) haben nie eine PDF-Seite und zaehlen nicht.
    static func missingPDFPage(_ p: SolutionPage, page: PDFPage) -> Bool { p.kind == .pdf && page.pageRef == nil }

    /// Hinweis an der Stelle einer Seite, die sich in der eigenen Fassung geaendert hat
    static func changedNotice() -> UIView { notice(SolutionVersions.pageChanged, id: "solution.side.changed") }

    /// Hinweis an der Stelle einer PDF-Seite, die sich nicht oeffnen laesst; sollte sie auf der aufbewahrten alten
    /// Fassung stehen, gilt derselbe Satz wie ohne diese Fassung
    static func missingNotice(placement: SolutionVersions.Placement?) -> UIView {
        if case .oldVersion? = placement { return changedNotice() }
        return notice(CommunityTexts.pageNotShown, id: "solution.side.needsPDF")
    }

    /// Satz mittig auf ruhigem Grund statt der Seite (nie Striche ohne ihren Hintergrund)
    static func notice(_ text: String, id: String) -> UIView {
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.backgroundColor = .secondarySystemBackground
        box.isUserInteractionEnabled = false
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .title3)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -24),
        ])
        box.accessibilityIdentifier = id
        box.isAccessibilityElement = true
        box.accessibilityLabel = text
        return box
    }

    // MARK: Aufbau

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        coverTapper.install(on: pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pdfView.interpolationQuality = .high
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.autoScales = true                          // nur fuer das erste Einpassen
        pdfView.pageOverlayViewProvider = self             // vor dem Setzen des Dokuments
        pdfView.accessibilityIdentifier = "solution.side.pdf"
        source = pdfURL.flatMap { PDFDocument(url: $0) }
        oldSource = layer.oldVersionURL.flatMap { PDFDocument(url: $0) }
        pdfView.document = Self.document(for: layer, pdf: source, old: oldSource)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
        pdfView.addGestureRecognizer(doubleTap)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scaleChanged() }
        })
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onPageChange?(self.currentPageIndex)
            }
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fit = pdfView.scaleFactorForSizeToFit
        guard fit > 0, fit.isFinite else { return }
        if fitScale == 0 {
            pdfView.autoScales = false
            applyLimits(fit: fit)
            pdfView.scaleFactor = fit
        } else if abs(fit - fitScale) > 0.0001 {
            // Spalte breiter oder schmaler (Drehen, Split View): eingepasst bleibt eingepasst, ein Zoom bleibt relativ
            let next = ZoomPolicy.scaleAfterResize(current: pdfView.scaleFactor, oldFit: fitScale, newFit: fit,
                                                   userZoomed: userZoomed, widestFit: fit)
            applyLimits(fit: fit)
            pdfView.scaleFactor = next
        }
        fitScale = fit
    }

    private func applyLimits(fit: CGFloat) {
        // wie im Editor; kleiner als "passt in die Breite" bringt in der schmalen Spalte nichts
        let range = ZoomPolicy.limits(fitScale: fit)
        pdfView.minScaleFactor = fit
        pdfView.maxScaleFactor = range.upperBound
    }

    var currentPageIndex: Int {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return max(0, doc.index(for: page))
    }

    // MARK: Zoom

    private var screenScale: CGFloat { view.window?.screen.scale ?? UIScreen.main.scale }

    /// Aufloesung der Tinte wie im Editor (`PDFEditorController.renderScale`)
    var currentRenderScale: CGFloat { PDFEditorController.renderScale(screen: screenScale, zoom: pdfView.scaleFactor) }

    private func scaleChanged() {
        if fitScale > 0 { userZoomed = ZoomPolicy.isUserZoom(scale: pdfView.scaleFactor, fitScale: fitScale) }
        // erst nach dem Zoomen: waehrend des Pinchens wuerde jede Aenderung die Tinte neu zeichnen
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.applyRenderScale()
        }
    }

    /// Tinte, Formen und Text der sichtbaren Seiten in der Aufloesung des aktuellen Zooms
    func applyRenderScale() {
        let s = currentRenderScale
        overlays.values.forEach { $0.setRenderScale(s, screen: screenScale) }
    }

    /// Doppeltippen: eingepasst -> 2,5-fach an der Stelle, sonst zurueck auf die Breite
    static func doubleTapTarget(current: CGFloat, fit: CGFloat, max upper: CGFloat) -> CGFloat {
        current > fit * 1.05 ? fit : min(upper, fit * 2.5)
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard fitScale > 0 else { return }
        pdfView.clearSelection()                           // PDFKit markiert beim Doppeltippen ein Wort
        let target = Self.doubleTapTarget(current: pdfView.scaleFactor, fit: fitScale, max: pdfView.maxScaleFactor)
        zoom(to: target, keeping: g.location(in: pdfView))
    }

    /// Zoomen, wobei die Stelle unter `point` (Punkte der PDFView) dort bleibt
    func zoom(to scale: CGFloat, keeping point: CGPoint) {
        let page = pdfView.page(for: point, nearest: true)
        let onPage = page.map { pdfView.convert(point, to: $0) }
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, scale))
        pdfView.layoutIfNeeded()
        guard let page, let onPage, let scroll = Self.firstScrollView(in: pdfView) else { return }
        let now = pdfView.convert(onPage, from: page)
        let inset = scroll.adjustedContentInset
        let maxX = max(-inset.left, scroll.contentSize.width + inset.right - scroll.bounds.width)
        let maxY = max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        let x = min(maxX, max(-inset.left, scroll.contentOffset.x + now.x - point.x))
        let y = min(maxY, max(-inset.top, scroll.contentOffset.y + now.y - point.y))
        scroll.setContentOffset(CGPoint(x: x, y: y), animated: false)
    }

    static func firstScrollView(in v: UIView) -> UIScrollView? {
        if let s = v as? UIScrollView { return s }
        for sub in v.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let doc = view.document else { return nil }
        let index = doc.index(for: page)
        guard layer.pages.indices.contains(index) else { return nil }
        if let o = overlays[index] { return o }
        let o = Self.overlay(for: layer.pages[index], page: page, index: index, layer: layer)
        o.setRenderScale(currentRenderScale, screen: screenScale)
        overlays[index] = o
        return o
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        // nichts zu sichern (nur ansehen): weggescrollte Seiten freigeben, beim Zurueckscrollen entstehen sie neu
        if let i = overlays.first(where: { $0.value === overlayView })?.key { overlays[i] = nil }
    }
}

/// SwiftUI-Huelle der Spalte
struct SolutionSideViewer: UIViewControllerRepresentable {
    let layer: ForeignSolutionLayer
    let pdfURL: URL?
    var onPageChange: (Int) -> Void = { _ in }

    func makeUIViewController(context: Context) -> SolutionSideController {
        let c = SolutionSideController(layer: layer, pdfURL: pdfURL)
        c.onPageChange = onPageChange
        return c
    }

    func updateUIViewController(_ c: SolutionSideController, context: Context) {
        c.onPageChange = onPageChange
    }
}
