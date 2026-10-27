import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// Unsichtbarer Erstantwortgeber fuer die Werkzeugpalette. Die Palette haengt damit nicht an einer Seiten-Canvas,
/// die beim Scrollen verschwindet (sonst schliesst sich die Palette, sobald die erste Seite aus dem Bild ist).
final class ToolPickerAnchor: UIView {
    override var canBecomeFirstResponder: Bool { true }
}

/// PencilKit-Canvas ohne eigenen Rueckgaengig-Verlauf. PencilKit wuerde seine Eintraege an die Canvas binden; die
/// verschwindet aber beim Scrollen (Overlay-Wiederverwendung) und beim Neuaufbau der Seiten. Den Verlauf fuehrt
/// deshalb der Editor je Seitenschluessel (siehe `PDFEditorController.registerUndo`).
final class InkCanvasView: PKCanvasView {
    private let silentUndo: UndoManager = {
        let u = UndoManager()
        u.disableUndoRegistration()
        return u
    }()

    override var undoManager: UndoManager? { silentUndo }
}

/// Overlay einer Seite: fremde Loesungen (nur Anzeige) ganz unten, darueber Vorlage und Web-Objekte (Text, Formen,
/// Bilder), PencilKit-Canvas oben.
/// Beide arbeiten in Seitenpunkten (wie der Web-Editor); passt PDFKit die Overlay-Groesse an, gleicht eine
/// Skalierung des Inhalts das aus. Die Canvas scrollt und zoomt nie selbst.
/// Immer hell: PencilKit kehrt Tintenfarben im Dunkelmodus um; auf dem weissen Papier soll schwarze Tinte schwarz
/// bleiben (wie im Web und im PDF-Export).
final class PageInkView: UIView {
    let pageIndex: Int
    /// Fester Seitenschluessel aus `pageOrder` (gespeichert wird immer ueber ihn, nie ueber den Index).
    let pageKey: String
    /// Seitenaufbau, zu dem das Overlay gehoert; nach Einfuegen/Drehen wird es nicht wiederverwendet.
    let generation: Int
    let geometry: PageGeometry
    let content = UIView()
    let objectsView: PageObjectsView
    let canvas = InkCanvasView()
    /// Eigene Schicht fuer fremde Loesungen: ueber der PDF, unter der eigenen Zeichenflaeche, ohne Eingabe.
    let foreignView = UIView()
    /// Zeichnung wird gerade programmatisch gesetzt (kein Speichern ausloesen).
    var isApplyingDrawing = false
    /// Stift ist gerade auf dieser Canvas aktiv.
    var isDrawing = false
    /// Neuer Stand vom Server, der wartet, bis der laufende Strich fertig ist.
    var deferredReload = false
    var loaded = false
    /// Stand der Zeichnung beim letzten Rueckgaengig-Eintrag (Ausgangspunkt des naechsten Eintrags).
    var undoBase = PKDrawing()
    /// Aenderung, waehrend der Stift noch aktiv ist (z. B. Radierer): Eintrag erst beim Absetzen anlegen.
    var undoPending = false
    /// Fremde Ebenen wurden nach einer Speicherwarnung freigegeben und werden beim naechsten Anzeigen neu gebaut.
    var foreignReleased = false

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
        overrideUserInterfaceStyle = .light            // gilt fuer Canvas, Vorlage und Objekte
        content.bounds = rect
        content.backgroundColor = .clear
        canvas.frame = rect
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        foreignView.frame = rect
        foreignView.backgroundColor = .clear
        foreignView.isUserInteractionEnabled = false
        content.addSubview(foreignView)
        content.addSubview(objectsView)
        content.addSubview(canvas)
        addSubview(content)
    }

    /// Fremde Loesungsseiten dieser Seite setzen (ersetzt die bisherigen).
    func setForeign(_ views: [ForeignLayerView]) {
        foreignView.subviews.forEach { $0.removeFromSuperview() }
        views.forEach { foreignView.addSubview($0) }
        foreignReleased = false
    }

    /// Fremde Ebenen freigeben (Speicherwarnung); die Auswahl der Ebenen bleibt im Editor.
    func releaseForeign() {
        foreignView.subviews.forEach { $0.removeFromSuperview() }
        foreignReleased = true
    }

    var foreignLayerViews: [ForeignLayerView] { foreignView.subviews.compactMap { $0 as? ForeignLayerView } }

    /// "Meine Notizen" ein-/ausblenden. Ausgeblendet nimmt die Canvas keine Eingabe an (nur ansehen); an den
    /// Notizen selbst aendert sich nichts.
    func setOwnNotesVisible(_ visible: Bool) {
        objectsView.isHidden = !visible
        canvas.isHidden = !visible
        canvas.isUserInteractionEnabled = visible
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

/// Aendern der Seitenstruktur im gemeinsamen Modell (Einfuegen, Papierkorb, Wiederherstellen ueber `PageOrder`).
/// Umsetzung im `DocumentStore` (braucht dessen SyncEngine); solange sie fehlt, kann der Editor nur einfuegen.
@MainActor
protocol PageStructureEditing: AnyObject {
    /// Aktuelles Modell (ausstehende Striche zuerst verarbeitet).
    func pageStructureDocument() async -> AnnotationDocument
    /// `change` auf das aktuelle Modell anwenden; bei Erfolg Wurzelfelder und `changedPageKeys` speichern,
    /// den Seitenaufbau aktualisieren und das Ergebnis zurueckgeben.
    func applyPageStructure(_ change: (inout AnnotationDocument) -> PageOrder.Change?) async -> PageOrder.Change?
}

/// Ziel der Rueckgaengig-Eintraege einer Seite (damit sie sich je Seite oder je Editor entfernen lassen).
final class PageUndoTarget {
    let key: String
    init(key: String) { self.key = key }
}

/// Nativer PDF-Arbeitsbereich: PDFKit zeigt, scrollt und zoomt; PencilKit schreibt.
///
/// - Finger: Scrollen und Zoomen (PDFKit). Der Stift scrollt nie (`allowedTouchTypes` der Scroll-Gesten).
/// - "Finger zeichnet": Scrollen dann mit zwei Fingern.
/// - Zoom wird nach dem ersten Einpassen nicht mehr automatisch zurueckgesetzt (siehe `ZoomPolicy`).
/// - Seiten-Overlays werden wiederverwendet (die letzten 6), statt beim Zurueckscrollen neu aufgebaut zu werden.
/// - Rueckgaengig/Wiederholen gilt dokumentweit: Eintraege haengen am Seitenschluessel, nicht am Overlay, und wirken
///   auf die gerade gebundene Canvas oder, ohne Overlay, direkt auf den gespeicherten Stand der Seite.
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
    private var undoTargets: [String: PageUndoTarget] = [:]
    private var live: [Int: PageInkView] = [:]
    private var parked: [PageInkView] = []
    private let parkedLimit = 6
    /// Hoechstens so viel Seitenflaeche (pt^2) geparkt: sechs A4-Seiten. PencilKit haelt je Canvas Kacheln von
    /// 512 x 512 pt in voller Bildschirmaufloesung (je etwa 4 MB, gemessen im Simulator): A4 vier, A0 quer 35
    /// (etwa 140 MB). Grosse Seiten (A2, Whiteboards bis A0, PC-Stand 7bcdfe5) werden darum nicht mehr auf Vorrat
    /// gehalten, sondern beim Zurueckscrollen neu aufgebaut (der Verlauf haengt am Seitenschluessel).
    static let parkedAreaLimit: CGFloat = 6 * 595 * 842
    private var lastFit: CGFloat = 0
    private var userZoomed = false
    private var observers: [NSObjectProtocol] = []
    private(set) var shownLayoutVersion = -1
    /// Seite, die nach dem naechsten Neuaufbau gezeigt werden soll (nach Einfuegen, Papierkorb, Wiederherstellen).
    private var pendingFocusKey: String?

    var onZoomChange: ((CGFloat) -> Void)?
    /// Anzeige-Index und Seitenschluessel der aktuellen Seite.
    var onPageChange: ((Int, String?) -> Void)?
    /// Seitenaufbau, den die PDFView gerade zeigt (kann kurz vom neuesten Stand im Store abweichen).
    private var shownLayout: DisplayLayout?

    /// Fremde Loesungen (nur Anzeige, nie gespeichert), eigene Schicht ueber der PDF und unter der eigenen
    /// Zeichenflaeche. Zuordnung ueber den PDF-Seitenindex, Drehung je Seite umgerechnet.
    var foreignLayers: [ForeignSolutionLayer] = [] {
        didSet {
            foreignSignature = Self.signature(foreignLayers)
            // nach einer Speicherwarnung freigegebene Seiten bauen ihre Ebenen erst beim Anzeigen neu auf
            for overlay in allOverlays where !overlay.foreignReleased { applyForeign(overlay) }
        }
    }
    /// Kennung der gezeigten fremden Ebenen (IDs und Sichtbarkeit), damit SwiftUI nicht bei jeder Aktualisierung
    /// neu aufbaut.
    private(set) var foreignSignature = ""

    static func signature(_ layers: [ForeignSolutionLayer]) -> String {
        layers.map { "\($0.id):\($0.visible)" }.joined(separator: ",")
    }

    /// "Meine Notizen" sichtbar. Ausgeblendet: nur ansehen (Canvas ohne Eingabe, Palette weg, kein Rueckgaengig,
    /// der Store nimmt keine schreibenden Aktionen an).
    var ownNotesVisible = true {
        didSet {
            store.ownNotesReadOnly = !ownNotesVisible
            guard ownNotesVisible != oldValue else { return }
            for v in allOverlays {
                if !ownNotesVisible, v.loaded { commitPendingUndo(v) }
                applyOwnNotes(to: v)
            }
            showToolPicker(writable)
        }
    }

    /// Tarif erlaubt Schreiben (Plus, `UFFeatureMatrix.notes(plan:).canEdit`). Ohne (Free, nach dem Herabstufen):
    /// nur ansehen, die eigenen Notizen bleiben sichtbar (Canvas ohne Eingabe, keine Palette, kein Rueckgaengig,
    /// keine Seitenaktionen). Der Verlauf geht beim Sperren verloren, damit Rueckgaengig ueber das System nichts
    /// mehr schreibt; Ausstehendes wird noch gesichert.
    var canEdit = true {
        didSet {
            store.canEdit = canEdit
            guard canEdit != oldValue else { return }
            for v in allOverlays {
                if !canEdit, v.loaded { commitPendingUndo(v) }
                applyOwnNotes(to: v)
            }
            if !canEdit {
                for t in undoTargets.values { documentUndo.removeAllActions(withTarget: t) }
                undoTargets = [:]
            }
            showToolPicker(writable)
        }
    }

    /// Schreiben gerade moeglich (eigene Notizen eingeblendet und Tarif mit Schreiben)
    var writable: Bool { ownNotesVisible && canEdit }

    /// Sichtbarkeit der eigenen Notizen und Eingabe der Canvas fuer ein Overlay
    private func applyOwnNotes(to overlay: PageInkView) {
        overlay.setOwnNotesVisible(ownNotesVisible)
        if !canEdit { overlay.canvas.isUserInteractionEnabled = false }
    }

    var pencilOnly = true {
        didSet {
            guard pencilOnly != oldValue else { return }
            allOverlays.forEach { $0.canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput }
            configureScrollGestures()
        }
    }

    /// Verlauf fuer den Ansichtsmodus: leer und ohne Eintraege, damit Rueckgaengig ueber das System (Cmd-Z,
    /// Wischen mit drei Fingern, Leiste der Palette) nichts zuruecknimmt und nichts schreibt.
    private let viewOnlyUndo: UndoManager = {
        let u = UndoManager()
        u.disableUndoRegistration()
        return u
    }()

    /// Verlauf der Responder-Kette. Ausgeblendete eigene Notizen = nur ansehen: kein Rueckgaengig (der Verlauf des
    /// Dokuments bleibt erhalten und gilt wieder, sobald die Notizen eingeblendet sind).
    override var undoManager: UndoManager? { ownNotesVisible ? documentUndo : viewOnlyUndo }

    init(store: DocumentStore, toolPicker: PKToolPicker? = nil, ownsToolPicker: Bool = true,
         undoManager: UndoManager? = nil, initialPDFPage: Int? = nil) {
        self.store = store
        self.toolPicker = toolPicker ?? PKToolPicker()
        self.ownsToolPicker = ownsToolPicker
        self.documentUndo = undoManager ?? UndoManager()
        self.initialPDFPage = initialPDFPage
        super.init(nibName: nil, bundle: nil)
        if documentUndo.levelsOfUndo == 0 { documentUndo.levelsOfUndo = 150 }     // wie der Verlauf im Web-Editor
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
        toolPicker.colorUserInterfaceStyle = .light   // Farben wie auf dem hellen Papier; die Palette folgt dem System
        if ownsToolPicker {
            toolPicker.stateAutosaveName = "uniflow.toolpicker"
            toolPicker.setVisible(writable, forFirstResponder: anchor)
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
        // Verlassen schreibt nie: jede Aenderung einer geladenen Canvas ging schon beim Zeichnen an den Store
        // (`canvasViewDrawingDidChange`), hier wird nur ein offener Rueckgaengig-Schritt abgeschlossen
        for v in allOverlays where v.loaded { commitPendingUndo(v) }
        if !ownsToolPicker {
            // geteilter Verlauf: Eintraege dieses Dokuments entfernen, sonst wirkt "Rueckgaengig" ins Leere
            for t in undoTargets.values { documentUndo.removeAllActions(withTarget: t) }
            undoTargets = [:]
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
    /// Der Rueckgaengig-Verlauf haengt am Seitenschluessel und bleibt erhalten.
    func showLayout() {
        guard store.layoutVersion != shownLayoutVersion, let layout = store.layout else { return }
        // Fokus nur verbrauchen, wenn die Seite schon im Aufbau steht (ein fremder Neuaufbau waehrend einer
        // Seitenoperation kommt sonst vor der neuen Seite und wuerde den Sprung dorthin verschlucken)
        var keepKey = currentPageKey
        if let focus = pendingFocusKey, layout.index(ofKey: focus) != nil {
            keepKey = focus
            pendingFocusKey = nil
        }
        let keepScale = pdfView.scaleFactor
        // Der Neuaufbau schreibt nie (alles ist schon im Store), nur offene Rueckgaengig-Schritte abschliessen
        for v in allOverlays where v.loaded { commitPendingUndo(v) }
        for v in allOverlays { toolPicker.removeObserver(v.canvas) }
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
            if overlay.foreignReleased { applyForeign(overlay) }      // nach einer Speicherwarnung neu aufbauen
        } else {
            let box = page.bounds(for: .cropBox).size
            overlay = PageInkView(pageIndex: index, pageKey: key, generation: shownLayoutVersion,
                                  geometry: PageGeometry(boxSize: box, rotation: page.rotation))
            configure(overlay)
            applyOwnNotes(to: overlay)
            applyForeign(overlay)
            loadContent(into: overlay)
        }
        live[index] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageInkView else { return }
        // Scrollen schreibt nie (alles ist schon im Store), nur ein offener Rueckgaengig-Schritt wird abgeschlossen
        if overlay.loaded { commitPendingUndo(overlay) }
        if live[overlay.pageIndex] === overlay { live.removeValue(forKey: overlay.pageIndex) }
        guard overlay.generation == shownLayoutVersion else {       // Overlay eines alten Seitenaufbaus: verwerfen
            toolPicker.removeObserver(overlay.canvas)
            return
        }
        parked.append(overlay)
        // der Verlauf bleibt: er haengt am Seitenschluessel und wirkt spaeter auf ein neues Overlay oder den Store
        while parked.count > parkedLimit || (!parked.isEmpty && parkedArea > Self.parkedAreaLimit) {
            toolPicker.removeObserver(parked.removeFirst().canvas)
        }
    }

    /// Seitenflaeche der geparkten Overlays (pt^2)
    private var parkedArea: CGFloat { parked.reduce(0) { $0 + $1.geometry.pageSize.width * $1.geometry.pageSize.height } }

    /// Zahl der geparkten Overlays (nur fuer Tests)
    var parkedCountForTesting: Int { parked.count }

    /// Fremde Loesungsseiten fuer ein Overlay: nur PDF-Seiten, gedreht von der Drehung des Absenders auf die
    /// angezeigte Drehung dieser Seite (`/Rotate` + eigene Drehung aus `pageOrder`).
    private func applyForeign(_ overlay: PageInkView) {
        guard overlay.generation == shownLayoutVersion, let layout = shownLayout, let entry = layout.entry(at: overlay.pageIndex),
              entry.key == overlay.pageKey, let pdfIndex = entry.pdfIndex, let page = layout.pdf.page(at: overlay.pageIndex) else {
            overlay.setForeign([])
            return
        }
        let views = foreignLayers.filter(\.visible).compactMap { layer -> ForeignLayerView? in
            guard let p = layer.byPDFIndex[pdfIndex] else { return nil }
            return ForeignLayerView(solutionID: layer.id, page: p, images: layer.images, targetRotation: page.rotation,
                                    label: layer.label)
        }
        overlay.setForeign(views)
    }

    /// Speicherwarnung: fremde Ebenen weggescrollter (geparkter) Seiten freigeben. Sichtbare Seiten behalten sie,
    /// Auswahl und Sichtbarkeit der Ebenen bleiben; beim Zurueckscrollen entstehen sie neu an derselben Stelle.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        for overlay in parked where !overlay.foreignReleased { overlay.releaseForeign() }
    }

    /// Overlay einer Anzeige-Seite (nur fuer Tests: erzeugt es wie PDFKit beim Scrollen).
    func overlayForTesting(at index: Int) -> PageInkView? {
        guard let page = pdfView.document?.page(at: index) else { return nil }
        return pdfView(pdfView, overlayViewFor: page) as? PageInkView
    }

    private func configure(_ overlay: PageInkView) {
        let c = overlay.canvas
        c.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        c.delegate = self
        c.tool = toolPicker.selectedTool
        toolPicker.addObserver(c)
    }

    /// - Parameter remote: Inhalt hat sich ausserhalb dieses Editors geaendert (Server, Zusammenfuehrung, Aktion).
    private func loadContent(into overlay: PageInkView, remote: Bool = false) {
        Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay else { return }
            let entry = self.store.entry(forKey: overlay.pageKey)
            let objects = await self.store.objects(forPageKey: overlay.pageKey)
            self.showObjects(objects, entry: entry, on: overlay)
            let drawing = await self.store.drawing(forPageKey: overlay.pageKey)
            self.apply(drawing, to: overlay, remote: remote)
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
    private func apply(_ drawing: PKDrawing, to overlay: PageInkView, remote: Bool = false) {
        if overlay.isDrawing { overlay.deferredReload = true; return }
        var next = drawing
        if !overlay.loaded, !overlay.canvas.drawing.strokes.isEmpty { next.append(overlay.canvas.drawing) }
        if remote, overlay.loaded,
           next.strokes.count != overlay.canvas.drawing.strokes.count || next != overlay.canvas.drawing {
            // fremde Aenderung auf dieser Seite: alte Schnappschuesse wuerden sie wieder zuruecknehmen
            dropUndo(forKey: overlay.pageKey)
        }
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = next
        overlay.isApplyingDrawing = false
        let hadEarlyStrokes = !overlay.loaded && next.strokes.count != drawing.strokes.count
        overlay.loaded = true
        overlay.undoBase = next
        overlay.undoPending = false
        if hadEarlyStrokes {
            store.canvasChanged(pageKey: overlay.pageKey, drawing: next)
            registerUndo(key: overlay.pageKey, restore: drawing, redo: next)
        }
    }

    private func reloadPages(_ keys: [String]) {
        let wanted = Set(keys)
        // Seiten ohne geladene, gebundene Canvas: deren Verlauf kennt die fremde Aenderung nicht. Ein spaeter
        // angelegtes Overlay laedt den neuen Stand, ein alter Schnappschuss wuerde ihn wieder entfernen (und die
        // Loeschung hochladen). Mit geladener Canvas entscheidet `apply(_:to:remote:)`.
        for key in wanted where boundOverlay(forKey: key)?.loaded != true { dropUndo(forKey: key) }
        for overlay in allOverlays where wanted.contains(overlay.pageKey) {
            if overlay.isDrawing { overlay.deferredReload = true } else { loadContent(into: overlay, remote: true) }
        }
    }

    // MARK: Rueckgaengig/Wiederholen je Seitenschluessel

    private func undoTarget(_ key: String) -> PageUndoTarget {
        if let t = undoTargets[key] { return t }
        let t = PageUndoTarget(key: key)
        undoTargets[key] = t
        return t
    }

    private func dropUndo(forKey key: String) {
        guard let t = undoTargets.removeValue(forKey: key) else { return }
        documentUndo.removeAllActions(withTarget: t)
    }

    /// Eintrag "Seite `key` auf `old` zuruecksetzen"; beim Ausfuehren entsteht der Gegeneintrag (zurueck auf `new`).
    /// Schnappschuesse statt Einzelschritte: PKDrawing ist ein Wert, das Merken kostet beim Schreiben praktisch nichts.
    private func registerUndo(key: String, restore old: PKDrawing, redo new: PKDrawing) {
        documentUndo.registerUndo(withTarget: undoTarget(key)) { [weak self] _ in
            MainActor.assumeIsolated {
                // ohne Schreiben im Tarif nimmt ein Schritt, den `removeAllActions(withTarget:)` nicht erreicht hat
                // (z. B. in einer noch offenen Gruppe), nichts zurueck, auch nicht auf der Canvas
                guard let self, self.canEdit else { return }
                self.setDrawing(old, forKey: key)
                self.registerUndo(key: key, restore: new, redo: old)
            }
        }
    }

    /// Aenderung seit dem letzten Eintrag als einen Schritt merken (ohne Vergleich der Zeichnungen: der kostet bei
    /// vollen Seiten Zeit, und PencilKit meldet nur echte Aenderungen).
    private func registerStep(_ overlay: PageInkView) {
        overlay.undoPending = false
        let now = overlay.canvas.drawing
        let before = overlay.undoBase
        overlay.undoBase = now
        registerUndo(key: overlay.pageKey, restore: before, redo: now)
    }

    private func commitPendingUndo(_ overlay: PageInkView) {
        if overlay.undoPending { registerStep(overlay) }
    }

    /// Overlay des aktuellen Seitenaufbaus fuer einen Schluessel (sichtbar oder geparkt).
    private func boundOverlay(forKey key: String) -> PageInkView? {
        allOverlays.first { $0.pageKey == key && $0.generation == shownLayoutVersion }
    }

    /// Zeichnung einer Seite aus dem Verlauf setzen: auf der gebundenen Canvas oder, ohne Overlay, nur im Store
    /// (ein spaeter angelegtes Overlay laedt dann diesen Stand). Ist die Seite nicht im Bild, springt die Ansicht
    /// hin, damit man sieht, was zurueckgenommen wurde.
    private func setDrawing(_ drawing: PKDrawing, forKey key: String) {
        store.canvasChanged(pageKey: key, drawing: drawing)
        if let overlay = boundOverlay(forKey: key) {
            if overlay.loaded {
                overlay.isApplyingDrawing = true
                overlay.canvas.drawing = drawing
                overlay.isApplyingDrawing = false
                overlay.undoBase = drawing
                overlay.undoPending = false
            } else {
                loadContent(into: overlay)          // Laden laeuft noch: neu laden, liefert den eben gesetzten Stand
            }
        }
        let visible = live.values.contains { $0.pageKey == key && $0.generation == shownLayoutVersion }
        if !visible, let i = shownLayout?.index(ofKey: key) { goToPage(i) }
    }

    // MARK: PKCanvasViewDelegate

    private func overlay(of canvasView: PKCanvasView) -> PageInkView? {
        canvasView.superview?.superview as? PageInkView
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let overlay = overlay(of: canvasView), !overlay.isApplyingDrawing else { return }
        // Laden laeuft noch: `apply` uebernimmt die frueh gezeichneten Striche und sichert sie
        guard overlay.loaded else { return }
        store.canvasChanged(pageKey: overlay.pageKey, drawing: canvasView.drawing)
        guard canEdit else { return }                        // ohne Schreiben im Tarif: kein Rueckgaengig-Schritt
        guard !documentUndo.isUndoing, !documentUndo.isRedoing else { return }
        // waehrend der Stift aufliegt (Radierer, Lasso) erst beim Absetzen einen Schritt anlegen
        if overlay.isDrawing { overlay.undoPending = true } else { registerStep(overlay) }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        overlay(of: canvasView)?.isDrawing = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let overlay = overlay(of: canvasView) else { return }
        overlay.isDrawing = false
        if overlay.loaded { commitPendingUndo(overlay) }
        if overlay.deferredReload {
            overlay.deferredReload = false
            loadContent(into: overlay, remote: true)
        }
    }

    // MARK: Seiten (gleiches Modell wie der Web-Editor, siehe PageOrder)

    /// Umsetzung im Store, sobald vorhanden. Pruefung zur Laufzeit, damit der Editor auch ohne sie baut.
    private var pageEditor: PageStructureEditing? { (store as AnyObject) as? PageStructureEditing }

    /// Leere Seite nach `key` (Standard: aktuelle Seite) einfuegen und hinspringen. Vorlage: blank, lined, grid,
    /// dotted, mm, cornell.
    /// - Mit `PageStructureEditing`: Groesse wie die Seite davor ohne deren zusaetzliche Drehung (`baseW`/`baseH`
    ///   im Web), Schluessel im Web-Format (`PageOrder.newBlankKey`).
    /// - Ersatzweg ohne Umsetzung im Store (`DocumentStore.addBlankPage`): angezeigte Groesse der Seite davor,
    ///   also mit zusaetzlicher Drehung (nach einer um 90 Grad gedrehten Seite Breite und Hoehe vertauscht), und
    ///   Schluessel "b" + 11 Hex-Zeichen.
    /// - `size`: gewaehltes Format in PDF-Punkten (A6 ... A2 hoch/quer, Whiteboards bis A0 quer, `PageFormats`) wie
    ///   `addBlankPage(where, template, size)` im Web; ausserhalb von `PageFormats.validSize` gilt die Groesse der
    ///   Seite davor.
    /// - Returns: Schluessel der neuen Seite.
    @discardableResult
    func insertBlankPage(after key: String? = nil, template: String = "blank", size chosen: CGSize? = nil) async -> String? {
        guard writable else { return nil }                  // nur ansehen
        let afterKey = key ?? currentPageKey
        let t = PaperTemplate.isKnown(template) ? template : "blank"
        let format = chosen.flatMap { PageFormats.validSize(Double($0.width), Double($0.height)) ? $0 : nil }
        guard let editor = pageEditor else {
            // ohne Umsetzung im Store: bisheriger Weg, neue Seite ueber den Vergleich der Schluessel finden
            let before = Set(store.layout?.entries.map(\.key) ?? [])
            await store.addBlankPage(afterKey: afterKey, template: t, size: format)
            let added = store.layout?.entries.first { !before.contains($0.key) }?.key
            pendingFocusKey = added
            finishPageChange(PageOrder.Change(focusKey: added, changedPageKeys: []))
            return added
        }
        let size = format ?? afterKey.flatMap { shownLayout?.index(ofKey: $0) }.flatMap { shownLayout?.baseSize(at: $0) }
            ?? CGSize(width: 595, height: 842)
        let newKey = PageOrder.newBlankKey()
        let w = Double(size.width), h = Double(size.height)
        pendingFocusKey = newKey
        let change = await editor.applyPageStructure { doc in
            PageOrder.insertBlank(&doc, after: afterKey, template: t, width: w, height: h, key: newKey)
        }
        finishPageChange(change)
        return change?.focusKey
    }

    /// Seite (Standard: aktuelle) in den Papierkorb legen (`deletedPages`, wiederherstellbar). Die letzte Seite bleibt.
    @discardableResult
    func trashPage(key: String? = nil) async -> Bool {
        guard writable else { return false }
        guard let editor = pageEditor, let key = key ?? currentPageKey, let layout = shownLayout,
              let i = layout.index(ofKey: key), layout.entries.count > 1 else { return false }
        if let v = boundOverlay(forKey: key), v.loaded { store.canvasChanged(pageKey: key, drawing: v.canvas.drawing) }
        pendingFocusKey = layout.key(at: i + 1) ?? layout.key(at: i - 1)
        let change = await editor.applyPageStructure { doc in PageOrder.trash(&doc, key: key) }
        // Verlauf der Seite verwerfen: er wuerde unsichtbar auf die geloeschte Seite wirken
        if change != nil { dropUndo(forKey: key) }
        finishPageChange(change)
        return change != nil
    }

    /// Juengsten Papierkorb-Eintrag einer Seite an ihren frueheren Platz zurueckholen und hinspringen.
    @discardableResult
    func restorePage(key: String) async -> Bool {
        guard writable else { return false }
        guard let editor = pageEditor else { return false }
        pendingFocusKey = key
        let change = await editor.applyPageStructure { doc in PageOrder.restore(&doc, key: key) }
        finishPageChange(change)
        return change != nil
    }

    /// Inhalt des Papierkorbs (aelteste zuerst), leer ohne Umsetzung im Store.
    func trashedPages() async -> [PageOrder.TrashedPage] {
        guard let editor = pageEditor else { return [] }
        return PageOrder.trashedPages(await editor.pageStructureDocument())
    }

    /// Nach einer Seitenoperation neu aufbauen und die betroffene Seite zeigen. Hat SwiftUI schon neu aufgebaut
    /// (`updateUIViewController`), wurde `pendingFocusKey` dort verbraucht; dann nur noch hinspringen. Danach wird
    /// `pendingFocusKey` immer geleert (auch wenn ein fremder Neuaufbau ihn nicht verwenden konnte).
    private func finishPageChange(_ change: PageOrder.Change?) {
        defer { pendingFocusKey = nil }
        guard let change else { return }
        let alreadyShown = shownLayoutVersion == store.layoutVersion
        showLayout()
        if alreadyShown, let key = change.focusKey, key != currentPageKey, let i = shownLayout?.index(ofKey: key) {
            goToPage(i)
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

    func undo() {
        guard writable else { return }                      // ausgeblendet oder ohne Schreiben im Tarif: nur ansehen
        allOverlays.forEach(commitPendingUndo)
        documentUndo.undo()
    }

    func redo() {
        guard writable else { return }
        documentUndo.redo()
    }

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
