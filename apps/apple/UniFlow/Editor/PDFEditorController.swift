import Combine
import OSLog
import PDFKit
import PencilKit
import UIKit
import UniFlowCore
import Vision

/// Unsichtbarer Erstantwortgeber des Editors: Tastenbefehle (Blaettern, Zoom) und Rueckgaengig ueber die
/// Responder-Kette erreichen den Editor auch, wenn gerade keine Seiten-Canvas im Bild ist (frueher hing daran Apples
/// Werkzeugpalette; die Werkzeuge stehen seit 11.11.2026 in der festen Leiste, `EditorToolbar.swift`).
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

/// Lage einer gezoomten Zeichenflaeche: Zoom der Canvas und Ausschnitt der Seite (Seitenpunkte), den sie zeigt
/// (`PageInkView.inkLayout(pageSize:viewport:zoom:screen:)`)
struct InkLayout: Equatable, Sendable {
    var zoom: CGFloat
    var window: CGRect
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
    /// Rohpunkte des Pencil fuer die einstellbare Glaettung (`PencilSmoothing`)
    let rawRecorder = RawPencilRecorder()
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
    /// Aenderung, waehrend der Stift noch aktiv ist: beim Absetzen einmal sichern (`PencilTuning.saveOnLift`)
    var storePending = false
    /// Abgesetzte Striche, deren Meldung "Zeichnung geaendert" noch aussteht, in der Reihenfolge des Absetzens (iOS
    /// meldet Absetzen und Zeichnung in beliebiger Reihenfolge, beim schnellen Schreiben kommt die Meldung zum
    /// vorigen Strich erst, wenn der naechste schon laeuft). Jede Meldung nimmt das aelteste Absetzen: Formerkennung
    /// und Rohpunkte gehoeren so immer zu ihrem eigenen Strich. Vorher (bis 17.11.2026) gab es nur EIN gemerktes
    /// Absetzen, und ein waehrend des naechsten Strichs gemeldeter Strich wurde beim Absetzen mit den Messpunkten
    /// des NAECHSTEN neu gebaut - er lag dann auf dem naechsten, an seiner Stelle fehlte er.
    var lifts: [StrokeLift] = []
    /// Der laufende Strich ist schon gemeldet (PencilKit meldet manche Striche kurz vor dem Absetzen)
    var reportedWhileDrawing = false
    /// Sieht jede Beruehrung der Zeichenflaeche sofort (`InkTouchTracker`)
    let touchTracker = InkTouchTracker()
    /// Liegt gerade ein Stift (oder, wenn auch der Finger schreibt, ein Finger) auf der Zeichenflaeche? Dann hat
    /// womoeglich schon der NAECHSTE Strich begonnen, auch wenn PencilKit ihn noch nicht gemeldet hat
    /// (`canvasViewDidBeginUsingTool` kommt spaeter als die Beruehrung): Jetzt die Zeichnung neu zu setzen, braeche
    /// ihn ab - der Strich waere weg (Meldung des Inhabers 17.11.2026, im Simulator nachgestellt:
    /// `EditorStrichBleibtTests.testWaechterKeinStrichGehtVerloren`).
    var touchCouldDraw: Bool {
        touchTracker.pencilsDown > 0 || (canvas.drawingPolicy != .pencilOnly && touchTracker.othersDown > 0)
    }
    /// Ist ein Strich abgesetzt, aber von PencilKit noch nicht gemeldet? Dann steht er noch nicht in `canvas.drawing`
    /// und nicht im Speicher: Solange darf die Zeichnung nicht neu gesetzt werden.
    var hasOpenLift: Bool { lifts.contains { $0.isRecent } }
    /// Zeitpunkt der letzten Aenderung, nach der weniger Striche da sein duerfen (Radierer, Lasso, Rueckgaengig, neu
    /// geladen): fuer die Pruefung "Strich fehlt nach dem Absetzen" (`StiftZaehler`)
    var lastShrinkAllowed: CFTimeInterval = 0
    /// Eine Nachpruefung fuer ein verschobenes Laden ist schon bestellt (`PDFEditorController.scheduleDeferredReload`)
    var reloadCheckScheduled = false
    /// Fremde Ebenen wurden nach einer Speicherwarnung freigegeben und werden beim naechsten Anzeigen neu gebaut.
    var foreignReleased = false
    /// Korrekturvorschlag auf dieser Seite (Korrektur-Modus oder empfangene Korrektur, `CorrectionMode.swift`)
    var correctionView: CorrectionPageView?
    /// Laufendes Laden von Objekten und Zeichnung (`PDFEditorController.loadContent`)
    var loadTask: Task<Void, Never>?

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
        inkLayout = InkLayout(zoom: 1, window: rect)
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
        canvas.addGestureRecognizer(rawRecorder)
        canvas.addGestureRecognizer(touchTracker)
        addSubview(content)
    }

    /// Fremde Loesungsseiten dieser Seite setzen (ersetzt die bisherigen).
    func setForeign(_ views: [ForeignLayerView]) {
        foreignView.subviews.forEach { $0.removeFromSuperview() }
        views.forEach { foreignView.addSubview($0) }
        // Striche aller Ebenen in EINER Canvas ueber den Ebenen (Text und Formen bleiben je Ebene): eine gezoomte Canvas
        // je Ebene kostete gut 100 MB
        views.forEach { $0.detachInk() }
        if views.isEmpty {
            foreignInk = nil
        } else {
            let c = foreignInk ?? Self.foreignCanvas(size: geometry.pageSize)
            var all = PKDrawing()
            for v in views { all.append(v.mappedDrawing) }
            c.drawing = all
            foreignView.addSubview(c)
            foreignInk = c
            Self.place(c, pageSize: geometry.pageSize, layout: inkLayout)
        }
        foreignReleased = false
        // neue Ebenen in der aktuellen Aufloesung (sonst grob, bis der Zoom das naechste Mal wechselt)
        if lastRenderScale > 0 { views.forEach { $0.setRenderScale(Self.objectScale(lastRenderScale), zoom: inkLayout.zoom) } }
    }

    /// Gemeinsame Canvas der fremden Striche dieser Seite (nur Anzeige)
    private(set) var foreignInk: PKCanvasView?

    static func foreignCanvas(size: CGSize) -> PKCanvasView {
        let c = PKCanvasView(frame: CGRect(origin: .zero, size: size))
        c.backgroundColor = .clear
        c.isOpaque = false
        c.isUserInteractionEnabled = false
        c.drawingGestureRecognizer.isEnabled = false
        c.isScrollEnabled = false
        c.minimumZoomScale = 1
        c.maximumZoomScale = 1
        c.contentInsetAdjustmentBehavior = .never
        c.showsVerticalScrollIndicator = false
        c.showsHorizontalScrollIndicator = false
        c.overrideUserInterfaceStyle = .light
        c.accessibilityElementsHidden = true
        return c
    }

    /// Canvas zoomt selbst (PencilKit rendert fertige Striche nur nach dem eigenen Zoom) und wird per Transform auf
    /// Seitengroesse gebracht; die Striche bleiben in Seitenpunkten
    static func zoom(_ c: PKCanvasView, pageSize size: CGSize, to zoom: CGFloat) {
        place(c, pageSize: size, layout: InkLayout(zoom: max(1, zoom), window: CGRect(origin: .zero, size: size)))
    }

    /// Canvas zeigt den Ausschnitt `layout.window` (Seitenpunkte) der Seite, `layout.zoom`-fach gezoomt und per
    /// Transform wieder auf Seitenpunkte gebracht: Rahmen = Ausschnitt, Inhalt verschoben (`contentOffset`), die
    /// Striche bleiben in Seitenpunkten. Ganze Seite: wie bis 1.0.7 (Rahmen = Seite, kein Versatz). Nur der Ausschnitt
    /// verschoben: PencilKit zeichnet nur die neu sichtbaren Kacheln, wie beim eigenen Scrollen.
    static func place(_ c: PKCanvasView, pageSize size: CGSize, layout l: InkLayout) {
        let z = min(max(1, l.zoom), maxCanvasZoom), w = l.window
        let boundsSize = CGSize(width: w.width * z, height: w.height * z)
        let offset = CGPoint(x: w.minX * z, y: w.minY * z)
        let center = CGPoint(x: w.midX, y: w.midY)
        let zoomChanges = abs(z - c.zoomScale) > 0.001
        guard zoomChanges || c.bounds.size != boundsSize || c.center != center
              || abs(c.contentOffset.x - offset.x) > 0.01 || abs(c.contentOffset.y - offset.y) > 0.01 else { return }
        c.transform = .identity
        if zoomChanges {
            c.minimumZoomScale = min(z, c.zoomScale)
            c.maximumZoomScale = max(z, c.zoomScale)
            c.bounds = CGRect(origin: .zero, size: boundsSize)
            c.center = center
            c.zoomScale = z
            c.minimumZoomScale = z
            c.maximumZoomScale = z
        }
        c.bounds = CGRect(origin: c.bounds.origin, size: boundsSize)
        c.center = center
        c.contentSize = CGSize(width: size.width * z, height: size.height * z)
        c.contentOffset = offset
        c.transform = CGAffineTransform(scaleX: 1 / z, y: 1 / z)
    }

    /// zuletzt gesetzte Aufloesung (`setRenderScale`), fuer spaeter angelegte fremde Ebenen
    private(set) var lastRenderScale: CGFloat = 0
    /// Zoom und Ausschnitt fuer fremde Striche und Korrektur (folgen sofort, auch waehrend eines eigenen Strichs)
    private(set) var inkLayout = InkLayout(zoom: 1, window: .zero)
    /// Ausschnitt der Seite, den die eigene Zeichenflaeche zeigt (Seitenpunkte); die ganze Seite bis zum 4-fachen Zoom
    var inkWindow: CGRect {
        let z = max(canvas.zoomScale, 0.0001)
        return CGRect(x: canvas.contentOffset.x / z, y: canvas.contentOffset.y / z, width: canvas.bounds.width / z, height: canvas.bounds.height / z)
    }
    /// Gewollter Zoom der Canvas nach dem letzten `setRenderScale` (vor der Speichergrenze)
    private var wantedZoom: CGFloat = 1
    private var layoutScreen: CGFloat = UIScreen.main.scale
    /// Ausschnitt noch offen: Die ganze Seite waere zu gross und der sichtbare Teil ist noch unbekannt (ohne Fenster,
    /// z. B. gleich nach dem Anlegen). Kommt beim Einsetzen ins Fenster bzw. beim naechsten Scrollen.
    private var layoutDeferred = false
    /// Scrollen der PDFView: der Ausschnitt folgt (`followViewport`)
    private var scrollObservation: NSKeyValueObservation?
    /// Scroll-Ansicht der PDFView (ihre Pinch-Geste, Zurueckfedern)
    private weak var enclosingScroll: UIScrollView?
    /// Waehrend des Zoomens verlangte Aufloesung: kommt nach dem Zoomen (`settleAfterZoomGesture`)
    private var pendingRenderScale: (scale: CGFloat, screen: CGFloat)?
    /// Nur Anzeige, waehrend gezoomt wird: die ganze Seite unter der scharfen Zeichenflaeche, die dann nur einen
    /// Ausschnitt zeigt (beim Herauszoomen fehlte sonst ausserhalb des Ausschnitts die Tinte)
    private var pinchUnderlay: PKCanvasView?
    private var settleScheduled = false

    /// Fremde Ebenen freigeben (Speicherwarnung); die Auswahl der Ebenen bleibt im Editor.
    func releaseForeign() {
        foreignView.subviews.forEach { $0.removeFromSuperview() }
        foreignInk = nil
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

    /// PDFKit vergroessert die Seite von aussen. Fertige Striche rendert PencilKit nur nach seinem eigenen Zoom, ein
    /// hoeherer `contentScaleFactor` wirkt nur auf den laufenden Strich (gemessen: Kante 23 statt 3 Pixel bei Zoom 5).
    /// Darum zoomt die Canvas selbst und wird per Transform wieder auf Seitengroesse gebracht; die Striche bleiben in
    /// Seitenpunkten. Waehrend eines Strichs bleibt alles, sonst bricht er ab.
    ///
    /// Bis 1.0.7 endete der Zoom der Canvas beim 4-fachen (ganze Seite, Speicher): bei 600 % (PDF-Zoom 8 bis 12) zeigte
    /// der Bildschirm die Tinte zwei- bis dreifach vergroessert, verpixelt (Meldung des Inhabers 20.11.2026). Jetzt
    /// zoomt die Canvas so weit wie die Anzeige; waere die ganze Seite dafuer zu gross (`inkPixelBudget`), zeigt sie
    /// nur den sichtbaren Teil der Seite mit Rand (`inkLayout(pageSize:viewport:zoom:screen:)`), und dieser Ausschnitt
    /// folgt dem Scrollen (`followViewport`). Bis zum 4-fachen Zoom bleibt alles wie bisher.
    ///
    /// Waehrend gezoomt wird (Finger liegen, Zurueckfedern), bleibt die Zeichenflaeche wie sie ist und PDFKit skaliert
    /// sie mit der Seite; die Aufloesung kommt danach (`settleAfterZoomGesture`). Rueckmeldung des Inhabers 21.11.2026:
    /// "die Schrift muss am Blatt haften und darf nicht kurz spinnen" - bis 8262c3e4 wanderte der Ausschnitt beim
    /// Herauszoomen in fast jedem Bild der Geste mit (echtes Pinchen nachgestellt: 17 Mal in einer Geste).
    func setRenderScale(_ scale: CGFloat, screen: CGFloat = UIScreen.main.scale) {
        if zoomGestureRunning {
            pendingRenderScale = (scale, screen)
            settleAfterZoomGesture()
            return
        }
        objectsView.setRenderScale(Self.objectScale(scale))
        lastRenderScale = scale
        layoutScreen = screen
        let zoom = max(1, scale / screen)
        // Der Wechsel zeichnet alle Striche neu. Beim Herauszoomen reichen die feineren Kacheln, bis es deutlich weniger wird
        let current = canvas.zoomScale
        let change = abs(zoom - current) > 0.001 && (zoom > current || zoom <= current / 2 || zoom == 1)
        wantedZoom = change ? zoom : current
        let viewport = viewportInPage()
        guard var l = Self.inkLayout(pageSize: geometry.pageSize, viewport: viewport, zoom: wantedZoom, screen: screen) else {
            layoutDeferred = true
            foreignLayerViews.forEach { $0.setRenderScale(Self.objectScale(scale), zoom: inkLayout.zoom) }
            return
        }
        // Gleiche Zoomstufe (z. B. nach jedem Strich): Der Ausschnitt bleibt, solange er den sichtbaren Teil noch enthaelt.
        // Bis c9dcc5b9 rechnete jedes Strichende den Ausschnitt neu und haengte die Zeichenflaeche um wenige Punkte um -
        // das zeigte ein Bild lang die Tinte versetzt ("beim Schreiben bewegt sich das ab und zu", 21.11.2026).
        let page = CGRect(origin: .zero, size: geometry.pageSize)
        if !layoutDeferred, abs(l.zoom - inkLayout.zoom) < 0.001, l.window != page, inkLayout.window != page, let v = viewport,
           Self.covers(inkLayout.window, needed(v)) {
            l = inkLayout
        }
        layoutDeferred = false
        apply(l, coverMoves: true)
    }

    /// Teil der Seite, der auf der Zeichenflaeche liegen muss: sichtbarer Teil mit halbem Rand
    private func needed(_ v: CGRect) -> CGRect {
        let half = Self.windowMargin / 2
        return v.insetBy(dx: -v.width * half, dy: -v.height * half).intersection(CGRect(origin: .zero, size: geometry.pageSize))
    }

    private static func covers(_ window: CGRect, _ need: CGRect) -> Bool {
        need.isNull || need.isEmpty || window.insetBy(dx: -0.5, dy: -0.5).contains(need)
    }

    /// Ausschnitt (Seitenpunkte), den eine Canvas gerade zeigt
    private static func window(of c: PKCanvasView) -> CGRect {
        let z = max(c.zoomScale, 0.0001)
        return CGRect(x: c.contentOffset.x / z, y: c.contentOffset.y / z, width: c.bounds.width / z, height: c.bounds.height / z)
    }

    /// Zoom und Ausschnitt setzen: fremde Striche und Korrektur sofort, die eigene Zeichenflaeche nicht mitten im Strich.
    ///
    /// Jede Canvas, deren Zoomstufe wechselt oder deren Ausschnitt wandert, liegt dabei unter einem Deckbild und ist
    /// selbst unsichtbar (`coverWhileRedrawing`): Beim Zoomwechsel zeichnet PencilKit alles neu; beim Verschieben zeigt
    /// PencilKit ein Bild lang die alten Kacheln an der neuen Stelle - die Tinte sprang um den Weg des Ausschnitts (im
    /// Simulator aufgenommen: 5 x 7 pt bei 600 %, ein Bild lang; "bewegen sich ganz leicht, dann sofort zurueck").
    /// Das trat nur auf, wenn die Seite still stand und PencilKit gerade gezeichnet hatte (nach einem Strich); beim
    /// Scrollen und Pinchen nicht (gemessen, 0,23 pt). Dort (`followViewport`, `coverMoves` false) kein Deckbild: es
    /// wuerde bei jedem Bild des Herauszoomens erneuert und liesse am Rand Tinte fehlen.
    private func apply(_ l: InkLayout, coverMoves: Bool) {
        inkLayout = l
        let z = min(max(1, l.zoom), Self.maxCanvasZoom)
        let zoomChanges = !isDrawing && abs(z - canvas.zoomScale) > 0.001
        let moves = !isDrawing && !zoomChanges && !Self.same(l.window, inkWindow)
        func changes(_ c: PKCanvasView) -> (zoom: Bool, move: Bool) {
            let zoom = abs(z - c.zoomScale) > 0.001
            return (zoom, !zoom && !Self.same(l.window, Self.window(of: c)))
        }
        var zoomed: [PKCanvasView] = zoomChanges ? [canvas] : [], moved: [PKCanvasView] = moves ? [canvas] : []
        for c in [foreignInk, correctionView?.ink].compactMap({ $0 }) {
            let ch = changes(c)
            if ch.zoom { zoomed.append(c) } else if ch.move { moved.append(c) }
        }
        if zoomChanges || moves { removeTranslucentHole() }     // die Maske passt nach dem Wechsel nicht mehr
        if !zoomed.isEmpty { coverWhileRedrawing(zoomed, for: Self.zoomSwitchReveal, zoom: true) }
        if !moved.isEmpty, coverMoves, PencilTuning.coverWindowMoves { coverWhileRedrawing(moved, for: Self.windowMoveReveal, zoom: false) }
        foreignLayerViews.forEach { $0.setRenderScale(Self.objectScale(lastRenderScale), zoom: l.zoom) }   // importierte Loesungen ebenso
        if let f = foreignInk { Self.place(f, pageSize: geometry.pageSize, layout: l) }
        correctionView?.setZoom(l.zoom, window: l.window)
        guard zoomChanges || moves else { return }
        if zoomChanges {
            Self.rescalesMade += 1
            StiftZaehler.bump(.zoomstufeGewechselt)
        } else {
            Self.windowMoves += 1
            StiftZaehler.bump(coverMoves ? .ausschnittNachStrich : .ausschnittBeimScrollen)
            let now = inkWindow
            if abs(now.width - l.window.width) > 0.01 || abs(now.height - l.window.height) > 0.01 { Self.windowResizes += 1 }
        }
        Self.place(canvas, pageSize: geometry.pageSize, layout: l)
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    /// Text und Bilder der Objekte hoechstens so fein wie bis 1.0.7 (eine Textansicht kostet Bildpunkte im Quadrat
    /// des Faktors; Formen und Vorlage sind Vektor-Ebenen und bleiben ohnehin scharf)
    static let objectScaleLimit: CGFloat = 8
    static func objectScale(_ scale: CGFloat) -> CGFloat { min(scale, objectScaleLimit) }

    // MARK: Ausschnitt der Zeichenflaeche (Tinte bei jedem Zoom scharf)

    /// Hoechstens so viele Bildpunkte zeigt eine Zeichenflaeche: der bisherige Hoechstwert, eine A4-Seite beim 4-fachen
    /// Zoom auf einem 2x-Bildschirm (595 x 842 x 4^2 x 2^2 = 32 Mio., rund 128 MB). Darueber nur der sichtbare Teil.
    nonisolated static let inkPixelBudget: CGFloat = 33_000_000
    /// Rand um den sichtbaren Teil, je Seite als Anteil seiner Groesse: dort ist die Tinte beim Verschieben schon gezeichnet
    nonisolated static let windowMargin: CGFloat = 0.25
    /// Zoomstufen der Canvas (jeder Wechsel zeichnet alle Striche der Seite neu)
    nonisolated static let zoomSteps: [CGFloat] = [1, 1.5, 2, 3, 4, 6, 8, 10]
    /// PencilKit nimmt hoechstens den 10-fachen Zoom an (`zoomScale` 12 liest sich als 10, gemessen iPadOS 27.2,
    /// `EditorDeviceFixesTests`). Bei 2x-Bildschirm 20 Bildpunkte je Seitenpunkt: 600 % auf dem iPad hoch braucht 16,3.
    nonisolated static let maxCanvasZoom: CGFloat = 10

    /// Messung (Tests): wie oft der Ausschnitt nur verschoben wurde (ohne Neuzeichnen der ganzen Seite)
    private(set) static var windowMoves = 0
    /// Messung (Tests): wie oft sich dabei auch die Groesse des Ausschnitts geaendert hat (PencilKit baut dann neu auf)
    private(set) static var windowResizes = 0

    /// Bis zu diesem Zoom zeigt die Canvas immer die ganze Seite, genau wie bis 1.0.7 (auch grosse Seiten wie A1/A0;
    /// sichtbar soll sich dort nichts aendern). Der Ausschnitt gilt nur darueber, wo es bisher nicht schaerfer ging.
    nonisolated static let wholePageZoom: CGFloat = 4

    /// Zoom und Ausschnitt der Canvas fuer den gewollten Zoom. Bis `wholePageZoom` oder wenn die ganze Seite in `budget`
    /// passt: die ganze Seite (wie bisher). Sonst der sichtbare Teil `viewport` (Seitenpunkte) mit Rand `margin`; passt
    /// auch der nicht, eine Zoomstufe tiefer (bis `wholePageZoom`, dann wieder die ganze Seite wie bisher). nil: die
    /// ganze Seite ist zu gross und der sichtbare Teil unbekannt oder weit weg.
    ///
    /// Der Ausschnitt ist immer gleich gross, solange der sichtbare Teil gleich gross ist (`window(around:in:margin:keeping:)`).
    nonisolated static func inkLayout(pageSize size: CGSize, viewport: CGRect?, zoom wanted: CGFloat, screen: CGFloat,
                                      budget: CGFloat = inkPixelBudget, margin: CGFloat = windowMargin,
                                      keeping size0: CGSize? = nil) -> InkLayout? {
        let page = CGRect(origin: .zero, size: size)
        func pixels(_ r: CGRect, _ z: CGFloat) -> CGFloat { r.width * r.height * z * z * screen * screen }
        let z0 = min(max(1, wanted.isFinite ? wanted : 1), maxCanvasZoom)
        if z0 <= wholePageZoom + 0.001 || pixels(page, z0) <= budget { return InkLayout(zoom: z0, window: page) }
        guard let v = viewport, !v.isNull, v.width > 0, v.height > 0,
              let near = window(around: v, in: page, margin: margin, keeping: size0) else { return nil }
        var z = z0
        while z > wholePageZoom + 0.001, pixels(near, z) > budget { z = zoomSteps.last { $0 < z - 0.001 } ?? 1 }
        if z <= wholePageZoom + 0.001 || pixels(page, z) <= budget { return InkLayout(zoom: z, window: page) }
        return InkLayout(zoom: z, window: near)
    }

    /// Ausschnitt um den sichtbaren Teil `v` mit Rand, ganz auf der Seite. Seine GROESSE haengt nur von der Groesse des
    /// sichtbaren Teils ab, nicht von seiner Lage: Am Seitenrand wird er auf die Seite geschoben statt beschnitten.
    ///
    /// Meldung des Inhabers 20.11.2026 abends (Testfassung e337d759): "Scrollen mit dem Finger hakt". Bis dahin war der
    /// Ausschnitt der auf ganze Punkte gerundete, an der Seite beschnittene Bereich: Seine Groesse aenderte sich beim
    /// Scrollen fast jedes Mal (Rundung um einen Punkt, am Seitenrand laufend). Jede neue Groesse baut die Zeichenflaeche
    /// von PencilKit neu auf (gemessen mit echtem Wischen, `testFingerScrollenHaktNicht`: bei 300 % 50 Umbauten in 15
    /// Wischern, Hauptthread dreimal so lang beschaeftigt wie ohne Ausschnitt). Jetzt wird beim Scrollen nur noch
    /// verschoben, wie PencilKit selbst scrollt. `keeping`: bisherige Groesse; weicht die neue um hoechstens einen Punkt
    /// ab (Rechengenauigkeit), bleibt die bisherige. nil: der sichtbare Teil mit Rand liegt nicht auf der Seite.
    nonisolated static func window(around v: CGRect, in page: CGRect, margin: CGFloat, keeping: CGSize? = nil) -> CGRect? {
        guard v.insetBy(dx: -v.width * margin, dy: -v.height * margin).intersects(page) else { return nil }
        var w = min(page.width, (v.width * (1 + 2 * margin)).rounded(.up))
        var h = min(page.height, (v.height * (1 + 2 * margin)).rounded(.up))
        if let k = keeping, abs(k.width - w) <= 1, abs(k.height - h) <= 1, k.width <= page.width, k.height <= page.height {
            w = k.width
            h = k.height
        }
        guard w > 0, h > 0 else { return nil }
        let x = min(max(page.minX, (v.midX - w / 2).rounded()), page.maxX - w)
        let y = min(max(page.minY, (v.midY - h / 2).rounded()), page.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Teil der Seite (Seitenpunkte), der gerade zu sehen sein kann: das Fenster, beschnitten von allen Vorfahren, die
    /// ihren Inhalt beschneiden (Scroll-Ansicht der PDFView). nil ohne Fenster.
    func viewportInPage() -> CGRect? {
        guard let window else { return nil }
        var r = window.bounds
        var v = superview
        while let a = v, a !== window {
            if a.clipsToBounds { r = r.intersection(a.convert(a.bounds, to: window)) }
            v = a.superview
        }
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        return content.convert(r, from: window)
    }

    /// Beim Scrollen: Liegt der sichtbare Teil (mit halbem Rand) nicht mehr im Ausschnitt, wandert der Ausschnitt mit.
    /// Der Zoom steigt dabei nie (das macht `setRenderScale` nach dem Zoomen), er sinkt nur, wenn der Ausschnitt beim
    /// Herauszoomen sonst zu gross wuerde. Zeigt die Canvas die ganze Seite, kostet das nichts.
    func followViewport() {
        guard !isDrawing, lastRenderScale > 0, !zoomGestureRunning else { return }
        let page = CGRect(origin: .zero, size: geometry.pageSize)
        guard layoutDeferred || inkLayout.window != page else { return }
        guard let v = viewportInPage() else { return }
        if !layoutDeferred, Self.covers(inkLayout.window, needed(v)) { return }
        let zoom = layoutDeferred ? wantedZoom : min(wantedZoom, inkLayout.zoom)
        guard let l = Self.inkLayout(pageSize: geometry.pageSize, viewport: v, zoom: zoom, screen: layoutScreen,
                                     keeping: layoutDeferred ? nil : inkLayout.window.size) else { return }
        layoutDeferred = false
        apply(l, coverMoves: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scrollObservation = nil
        enclosingScroll?.pinchGestureRecognizer?.removeTarget(self, action: #selector(zoomGestureChanged(_:)))
        enclosingScroll = nil
        guard window != nil else {
            removePinchUnderlay()
            return
        }
        var v = superview
        while let a = v, !(a is UIScrollView) || a is PKCanvasView { v = a.superview }
        if let scroll = v as? UIScrollView {
            enclosingScroll = scroll
            scrollObservation = scroll.observe(\.contentOffset, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.followViewport() }
            }
            scroll.pinchGestureRecognizer?.addTarget(self, action: #selector(zoomGestureChanged(_:)))
        }
        // PDFKit setzt Rahmen und Lage erst nach dem Einsetzen
        DispatchQueue.main.async { [weak self] in self?.followViewport() }
    }

    // MARK: Zoomen mit zwei Fingern: die Zeichenflaeche bleibt unberuehrt

    /// Liegen die Finger zum Zoomen auf oder federt der Zoom zurueck? Dann aendert sich an der Zeichenflaeche nichts.
    var zoomGestureRunning: Bool {
        guard let s = enclosingScroll else { return false }
        let state = s.pinchGestureRecognizer?.state
        if state == .began || state == .changed || s.isZooming { return true }
        // Zurueckfedern hoechstens `zoomBounceLimit` nach dem Loslassen: nach schnellem Zoomen ueber das Maximum blieb
        // `isZoomBouncing` (nachgestellt) dauerhaft gesetzt, die Seite wurde nie mehr scharf
        return s.isZoomBouncing && CACurrentMediaTime() - zoomGestureEnded < Self.zoomBounceLimit
    }
    private var zoomGestureEnded: CFTimeInterval = 0
    static let zoomBounceLimit: CFTimeInterval = 0.6

    @objc private func zoomGestureChanged(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: showPinchUnderlay()
        case .ended, .cancelled, .failed:
            zoomGestureEnded = CACurrentMediaTime()
            settleAfterZoomGesture()
        default: break
        }
    }

    /// Nach dem Zoomen (Finger weg, Zurueckfedern vorbei, kurz Ruhe) einmal die verlangte Aufloesung setzen
    private func settleAfterZoomGesture() {
        guard !settleScheduled else { return }
        settleScheduled = true
        func check(_ quietSince: CFTimeInterval?) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                if self.zoomGestureRunning { return check(nil) }
                let since = quietSince ?? CACurrentMediaTime()
                guard CACurrentMediaTime() - since >= Self.zoomGestureQuiet else { return check(since) }
                self.settleScheduled = false
                // Aufloesung aus dem Massstab, in dem die Seite jetzt auf dem Bildschirm steht (wie
                // `PDFEditorController.renderScale`): Nach schnellem Zoomen ueber das Maximum kam fuer die sichtbare Seite
                // sonst keine Aufloesung mehr an, sie blieb unscharf (nachgestellt mit echtem Pinchen)
                let screen = self.pendingRenderScale?.screen ?? self.layoutScreen
                let request = self.pendingRenderScale
                self.pendingRenderScale = nil
                if let shown = self.shownScale() {
                    self.setRenderScale(PDFEditorController.renderScale(screen: screen, zoom: shown), screen: screen)
                } else if let p = request {
                    self.setRenderScale(p.scale, screen: p.screen)
                }
                // die Hilfsflaeche geht, sobald die Zeichenflaeche wieder offen ist (Deckbild eines Wechsels weg)
                if self.zoomSwitch == nil { self.removePinchUnderlay() }
            }
        }
        check(nil)
    }

    /// Bildschirmpunkte je Seitenpunkt, wie die Seite gerade im Fenster steht (nil ohne Fenster)
    func shownScale() -> CGFloat? {
        guard let window else { return nil }
        let o = content.convert(CGPoint.zero, to: window)
        let x = content.convert(CGPoint(x: 1, y: 0), to: window), y = content.convert(CGPoint(x: 0, y: 1), to: window)
        let det = abs((x.x - o.x) * (y.y - o.y) - (x.y - o.y) * (y.x - o.x))
        return det > 0 && det.isFinite ? det.squareRoot() : nil
    }

    /// Ruhe nach dem Zoomen, bevor die Zeichenflaeche neu gezeichnet wird
    static let zoomGestureQuiet: CFTimeInterval = 0.15

    /// Zeigt die Zeichenflaeche nur einen Ausschnitt, liegt beim Zoomen darunter die ganze Seite in der bisherigen
    /// Aufloesung (hoechstens 4-fach, nur Anzeige). Die Zeichenflaeche selbst bleibt unveraendert; dort, wo sie Tinte
    /// zeigt, deckt sie die Hilfsflaeche.
    private func showPinchUnderlay() {
        let page = CGRect(origin: .zero, size: geometry.pageSize)
        guard pinchUnderlay == nil, window != nil, inkLayout.window != page else { return }
        var all = canvas.drawing
        if let f = foreignInk { all.append(f.drawing) }
        if let c = correctionView?.ink { all.append(c.drawing) }
        guard !all.strokes.isEmpty else { return }
        let u = Self.foreignCanvas(size: geometry.pageSize)
        u.drawing = all
        var z = Self.wholePageZoom
        while z > 1, page.width * page.height * z * z * layoutScreen * layoutScreen > Self.inkPixelBudget {
            z = Self.zoomSteps.last { $0 < z - 0.001 } ?? 1
        }
        Self.place(u, pageSize: geometry.pageSize, layout: InkLayout(zoom: z, window: page))
        content.insertSubview(u, belowSubview: canvas)
        pinchUnderlay = u
        Self.pinchUnderlaysMade += 1
    }

    private func removePinchUnderlay() {
        pinchUnderlay?.removeFromSuperview()
        pinchUnderlay = nil
    }

    /// Messung (Tests): Hilfsflaechen beim Zoomen
    private(set) static var pinchUnderlaysMade = 0
    /// Liegt gerade die Hilfsflaeche unter der Zeichenflaeche? (Tests)
    var hasPinchUnderlay: Bool { pinchUnderlay != nil }

    /// Messung (`EditorStrichBleibtTests`): wie oft eine Zeichenflaeche ihre Zoomstufe gewechselt hat (PencilKit zeichnet
    /// dann alle Striche neu) und wie viele Deckbilder angelegt wurden
    private(set) static var rescalesMade = 0
    private(set) static var coversMade = 0

    /// PencilKit verwirft beim Zoomwechsel seine Kacheln und zeichnet sie neu: Bis dahin steht ein Bild der Tinte darueber,
    /// sonst verschwindet sie kurz.
    ///
    /// Rueckmeldung des Inhabers 21.11.2026 ("wenn man ganz nah ranzoomt, wirken die Zeichen kurz gross, dann wieder
    /// klein"), im Simulator Bild fuer Bild aufgenommen (simctl recordVideo): Bis dahin lag das Deckbild 0,35 s ueber der
    /// Canvas, die schon ihre neue Zoomstufe zeigte. Die zeigte zwei Bilder lang einen Zwischenstand (Kreis 481 statt
    /// 478 Pixel breit, 13 % mehr Tinte), danach lag das unscharfe, dickere Deckbild noch 0,5 s ueber der duennen
    /// scharfen Tinte. Jetzt ist die Canvas waehrend des Neuzeichnens unsichtbar (leere Maske, die Eingabe bleibt), es
    /// steht nur das Deckbild; nach `zoomSwitchReveal` zeigt sich die Canvas und das Deckbild geht in 0,1 s weg.
    /// PencilKit meldet nach einem Zoomwechsel kein "fertig gezeichnet" (gemessen: 0 Meldungen), darum die feste Zeit;
    /// kommt die Meldung doch (`inkRendered`), geht es frueher. Beim naechsten Strich sofort (`endTranslucentHole`).
    ///
    /// Dasselbe beim Verschieben des Ausschnitts (`zoom` false), dort nur `windowMoveReveal` lang und ohne Ausblenden.
    /// Laeuft schon ein Wechsel, bleiben dessen Deckbilder (sie zeigen den Stand davor an der richtigen Stelle der
    /// Seite); neue Canvas kommen dazu, und es dauert hoechstens bis zum spaeteren Ende. Jede Canvas hat ihre eigene
    /// Maske (eine Ebene kann nur EINE Ebene maskieren; c9dcc5b9 teilte eine fuer alle).
    private func coverWhileRedrawing(_ canvases: [PKCanvasView], for duration: CFTimeInterval, zoom: Bool) {
        guard window != nil else { return }
        if zoomSwitch == nil {
            zoomSwitchID += 1
            zoomSwitch = ZoomSwitch(id: zoomSwitchID, started: CACurrentMediaTime())
        }
        guard var s = zoomSwitch else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in canvases where !s.entries.contains(where: { $0.canvas === c }) {
            guard !c.isHidden, c.alpha > 0, !c.drawing.strokes.isEmpty, c.layer.mask == nil, let superview = c.superview,
                  let cover = c.snapshotView(afterScreenUpdates: false) else { continue }
            cover.transform = c.transform
            cover.center = c.center
            cover.isUserInteractionEnabled = false
            superview.insertSubview(cover, aboveSubview: c)
            let mask = CALayer()
            c.layer.mask = mask
            s.entries.append((c, mask, cover))
            Self.coversMade += 1
        }
        CATransaction.commit()
        guard !s.entries.isEmpty else {
            zoomSwitch = nil
            return
        }
        s.zoom = s.zoom || zoom
        s.revealAt = max(s.revealAt, CACurrentMediaTime() + duration)
        zoomSwitch = s
        let id = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, let now = self.zoomSwitch, now.id == id, CACurrentMediaTime() >= now.revealAt - 0.005 else { return }
            self.finishZoomSwitch(animated: now.zoom)
        }
    }

    /// Laufender Wechsel: je Canvas Maske und Deckbild; Ende frühestens `revealAt`; `zoom`: mit Zoomwechsel (Ausblenden)
    private struct ZoomSwitch {
        let id: Int
        let started: CFTimeInterval
        var entries: [(canvas: PKCanvasView, mask: CALayer, cover: UIView)] = []
        var revealAt: CFTimeInterval = 0
        var zoom = false
    }
    private var zoomSwitch: ZoomSwitch?
    private var zoomSwitchID = 0
    /// Frueher als so meldet PencilKit "fertig" womoeglich noch fuer den Stand davor
    static let zoomSwitchMinimum: CFTimeInterval = 0.08
    /// So lange steht nur das Deckbild (gemessen: neue Kacheln nach rund 45 ms fertig; bisher lag das Deckbild 0,35 s
    /// ueber der schon sichtbaren Canvas und ging in 0,15 s weg)
    static let zoomSwitchReveal: CFTimeInterval = 0.3
    /// Verschobener Ausschnitt: PencilKit zeigt die Kacheln ein Bild lang an der alten Stelle (gemessen), drei Bilder Ruhe
    static let windowMoveReveal: CFTimeInterval = 0.05
    /// Liegt gerade ein Deckbild ueber einem Zoomwechsel oder verschobenen Ausschnitt? (Tests)
    var isSwitchingZoom: Bool { zoomSwitch != nil }

    /// Canvas wieder zeigen (im selben Bild wie das Deckbild beginnt zu verschwinden)
    private func finishZoomSwitch(animated: Bool) {
        guard let s = zoomSwitch else { return }
        zoomSwitch = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for e in s.entries where e.canvas.layer.mask === e.mask { e.canvas.layer.mask = nil }
        if !animated { s.entries.forEach { $0.cover.removeFromSuperview() } }
        if !zoomGestureRunning, !settleScheduled { removePinchUnderlay() }   // Zeichenflaeche wieder offen
        CATransaction.commit()
        guard animated else { return }
        let covers = s.entries.map(\.cover)
        UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction], animations: { covers.forEach { $0.alpha = 0 } }) { _ in
            covers.forEach { $0.removeFromSuperview() }
        }
    }

    // MARK: Letzten Strich ersetzen, ohne dass Tinte fehlt (Form, Glaettung "Leicht"/"Aus", Schriftbild)

    /// Messung (`EditorStrichBleibtTests`): wie oft der letzte Strich ersetzt wurde und wie oft PencilKit "fertig
    /// gezeichnet" gemeldet hat
    private(set) static var replacementsMade = 0
    private(set) static var renderingsFinished = 0
    /// Deckbilder ueber einem ersetzten Strich, bis PencilKit den neuen Stand gezeichnet hat
    private var replacementCovers: [(view: UIView, placed: CFTimeInterval)] = []

    /// So lange bleibt ein Deckbild mindestens (PencilKit kann "fertig" noch fuer den Stand davor melden) und hoechstens
    static let replacementCoverMinimum: CFTimeInterval = 0.25
    static let replacementCoverMaximum: CFTimeInterval = 1.2

    /// Der eben beendete Strich wird durch `stroke` ersetzt (erkannte Form, Strich aus den Messpunkten). PencilKit
    /// kann einen einzelnen Strich nicht tauschen: Die ganze Zeichnung wird neu gesetzt, PencilKit wirft dabei seine
    /// Kacheln weg und zeichnet neu - bis dahin fehlte die Tinte ("der Strich geht kurz weg", Meldung des Inhabers
    /// 16.11.2026). Darum liegt bis dahin ein Deckbild darueber: das, was eben auf dem Bildschirm stand (alle Striche
    /// der Seite), und bei deckender Tinte zusaetzlich der neue Strich, frisch gezeichnet. Es geht weg, sobald
    /// PencilKit fertig gezeichnet hat (`inkRendered`), fruehestens nach `replacementCoverMinimum`.
    func replaceLastStroke(with stroke: PKStroke) {
        var drawing = canvas.drawing
        guard let old = drawing.strokes.last else { return }
        drawing.strokes[drawing.strokes.count - 1] = stroke
        if PencilTuning.coverWhenStrokeIsReplaced { coverReplacement(stroke, replacing: old, others: Array(drawing.strokes.dropLast())) }
        canvas.drawing = drawing
        Self.replacementsMade += 1
        StiftZaehler.bump(.ersetzt)
    }

    /// Deckt diese Tinte? (Textmarker, Wasserfarbe und Farben mit Deckkraft unter 100 % scheinen durch)
    static func isOpaque(_ ink: PKInk) -> Bool {
        var alpha: CGFloat = 1
        ink.color.getWhite(nil, alpha: &alpha)
        return alpha >= 0.999 && ink.inkType != .marker && ink.inkType != .watercolor
    }

    /// Messung (Tests): wie oft ein Deckbild an der Stelle eines durchscheinenden Strichs ausgespart wurde
    private(set) static var translucentCoversMade = 0
    /// Deckbild an der Stelle eines durchscheinenden Strichs aussparen. `false`: wie bis 17.11.2026 (Gegenprobe im Test
    /// `testFormenTextmarkerNurLinieUndFueller`: die Markierung ist dann fuer die Dauer des Deckbilds doppelt zu sehen)
    static var spareTranslucentStroke = true

    /// Durchscheinende Tinte im Tausch: Deckbild, an dessen Stelle die Zeichenflaeche gerade verdeckt ist (Maske), und
    /// das Bild des neuen Stands dort (`coverReplacement`)
    private var translucentHole: (cover: UIView, image: UIView)?

    /// Die Zeichenflaeche zeigt die Stelle wieder selbst: Maske und Bild weg, im selben Bild (kein Ueberblenden, sonst
    /// laege die Markierung kurz doppelt). Vor einem neuen Strich und einem Zoomwechsel sofort.
    func endTranslucentHole() {
        finishZoomSwitch(animated: false)                      // ein neuer Strich muss sofort zu sehen sein
        removeTranslucentHole()
    }

    /// Nur die Maske des durchscheinenden Tauschs (ohne einen laufenden Zoomwechsel zu beenden)
    private func removeTranslucentHole() {
        guard let hole = translucentHole else { return }
        translucentHole = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hole.image.removeFromSuperview()
        canvas.layer.mask = nil
        CATransaction.commit()
    }

    private func coverReplacement(_ stroke: PKStroke, replacing old: PKStroke, others: [PKStroke]) {
        guard window != nil else { return }
        removeTranslucentHole()
        let page = CGRect(origin: .zero, size: geometry.pageSize)
        let cover = UIView(frame: page)
        cover.isUserInteractionEnabled = false
        cover.backgroundColor = .clear
        let opaque = Self.isOpaque(stroke.ink)
        let shot = canvas.snapshotView(afterScreenUpdates: false)
        if let shot {
            shot.transform = canvas.transform
            shot.center = canvas.center
            shot.isUserInteractionEnabled = false
            cover.addSubview(shot)
        }
        // Deckende Tinte: der neue Strich als Bild, sofort (ein Strich, unter 1 ms).
        // Durchscheinende Tinte (Textmarker, Stift mit Deckkraft unter 100 %): Laege das Bild von eben (mit dem alten
        // Strich) ueber dem neuen Strich, den PencilKit darunter zeichnet, waere der Strich fuer die Dauer des Deckbilds
        // doppelt da und dort, wo beide sich decken, dunkler. Darum ist das Deckbild an der Stelle des alten und des
        // neuen Strichs ausgespart. Dort zeigte bis 19.11.2026 PencilKit selbst den neuen Stand - aber nicht sofort:
        // gemessen (iPadOS 26.2 und 27.2, Bild fuer Bild) erst ein bis zwei Bilder lang noch den alten Strich (mit dem
        // Knaeuel vom Halten dunkler als die fertige Markierung), dann ein bis drei Bilder lang GAR NICHTS (die
        // Markierung war weg), dann die gerade Linie. Jetzt ist die Zeichenflaeche an dieser Stelle fuer die Dauer des
        // Deckbilds verdeckt (Maske) und das Deckbild zeigt dort den neuen Stand als Bild: alle Striche, die durch die
        // Stelle laufen, in ihrer Reihenfolge, die Markierung genau ein Mal. Weg geht beides im selben Bild
        // (`endTranslucentHole`), wenn PencilKit fertig gezeichnet hat.
        let hole = old.renderBounds.union(stroke.renderBounds).insetBy(dx: -3, dy: -3).intersection(page).integral
        if Self.spareTranslucentStroke, !opaque, let shot, !hole.isNull, hole.width >= 1, hole.height >= 1 {
            // Punkte des sichtbaren Ausschnitts der Canvas (bei starkem Zoom zeigt sie nur einen Teil der Seite)
            let zoom = max(canvas.zoomScale, 0.0001), origin = canvas.contentOffset
            let holeInCanvas = CGRect(x: hole.minX * zoom - origin.x, y: hole.minY * zoom - origin.y,
                                      width: hole.width * zoom, height: hole.height * zoom)
            func cutOut(_ bounds: CGRect) -> CAShapeLayer {
                let path = UIBezierPath(rect: CGRect(origin: .zero, size: bounds.size))
                path.append(UIBezierPath(rect: holeInCanvas))
                let mask = CAShapeLayer()
                mask.frame = bounds
                mask.fillRule = .evenOdd
                mask.path = path.cgPath
                return mask
            }
            shot.layer.mask = cutOut(shot.bounds)
            // Zeichenflaeche verdecken nur, wenn sie keine eigene Maske hat; sonst wie bisher (PencilKit zeigt die Stelle)
            let hideCanvas = canvas.layer.mask == nil && abs(canvas.bounds.width - shot.bounds.width) < 1
            let crossing = (others + [stroke]).filter { $0.renderBounds.intersects(hole) && (hideCanvas || Self.isOpaque($0.ink)) }
            if !crossing.isEmpty {
                let wanted = max(1, lastRenderScale > 0 ? lastRenderScale : UIScreen.main.scale)
                let scale = max(1, min(wanted, (4_000_000 / max(1, hole.width * hole.height)).squareRoot()))
                var image = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    image = PKDrawing(strokes: crossing).image(from: hole, scale: scale)
                }
                let view = UIImageView(image: image)
                view.frame = hole
                view.isUserInteractionEnabled = false
                cover.addSubview(view)
                if hideCanvas {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    canvas.layer.mask = cutOut(canvas.bounds)
                    CATransaction.commit()
                    translucentHole = (cover, view)
                }
            }
            Self.translucentCoversMade += 1
        }
        let rect = stroke.renderBounds.insetBy(dx: -2, dy: -2).intersection(page).integral
        if opaque, !rect.isNull, rect.width >= 1, rect.height >= 1 {
            // so scharf wie die Zeichenflaeche; ein sehr langer Strich bei starkem Zoom hoechstens 4 Mio. Pixel
            let wanted = max(1, lastRenderScale > 0 ? lastRenderScale : UIScreen.main.scale)
            let scale = max(1, min(wanted, (4_000_000 / max(1, rect.width * rect.height)).squareRoot()))
            var image = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = PKDrawing(strokes: [stroke]).image(from: rect, scale: scale)
            }
            let view = UIImageView(image: image)
            view.frame = rect
            view.isUserInteractionEnabled = false
            cover.addSubview(view)
        }
        content.addSubview(cover)
        Self.coversMade += 1
        let placed = CACurrentMediaTime()
        replacementCovers.append((cover, placed))
        // Sicherheitsnetz: meldet PencilKit nichts, geht das Deckbild von selbst weg
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replacementCoverMaximum) { [weak self, weak cover] in
            guard let self, let cover else { return }
            self.dropReplacementCover(cover)
        }
        // schnell viele Striche: nie mehr als drei Deckbilder uebereinander
        while replacementCovers.count > 3 { dropReplacementCover(replacementCovers[0].view) }
    }

    /// PencilKit hat fertig gezeichnet (`canvasViewDidFinishRendering`): Deckbilder, die lange genug liegen, gehen weg
    func inkRendered() {
        Self.renderingsFinished += 1
        if let s = zoomSwitch, s.zoom {
            let wait = Self.zoomSwitchMinimum - (CACurrentMediaTime() - s.started)
            if wait <= 0 {
                finishZoomSwitch(animated: true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self, self.zoomSwitch?.id == s.id else { return }
                    self.finishZoomSwitch(animated: true)
                }
            }
        }
        guard !replacementCovers.isEmpty else { return }
        let now = CACurrentMediaTime()
        for entry in replacementCovers {
            let wait = max(0.05, Self.replacementCoverMinimum - (now - entry.placed))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak view = entry.view] in
                guard let self, let view else { return }
                self.dropReplacementCover(view)
            }
        }
    }

    private func dropReplacementCover(_ view: UIView) {
        guard let i = replacementCovers.firstIndex(where: { $0.view === view }) else { return }
        replacementCovers.remove(at: i)
        if translucentHole?.cover === view { removeTranslucentHole() }
        UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction], animations: { view.alpha = 0 }) { _ in
            view.removeFromSuperview()
        }
    }

    /// Liegt gerade ein Deckbild ueber einem ersetzten Strich? (Tests)
    var hasReplacementCover: Bool { !replacementCovers.isEmpty }

    /// PDFKit gibt dem Overlay einer gedrehten Seite (`/Rotate`, auch mit Drehung aus `pageOrder`) den Rahmen der
    /// UNGEDREHTEN Seitenbox und dreht das Overlay selbst per `transform` in die Anzeige (gemessen iPadOS 26,
    /// /Rotate 90: bounds 595 x 842, transform 90 Grad, Seite quer 842 x 595). `content` rechnet in Punkten der
    /// ANGEZEIGTEN Seite (Web-Vertrag) und wird deshalb um dieselbe Drehung zurueckgedreht; der Massstab kommt aus der
    /// angezeigten Groesse. Vorher lag der Inhalt quer im Overlay, die Canvas deckte nur einen Streifen der Seite
    /// (Stift "hoert ploetzlich auf zu schreiben") und gespeicherte Punkte lagen ausserhalb der Seite (GDS, 04.11.2026).
    override func layoutSubviews() {
        super.layoutSubviews()
        let turns = Self.quarterTurns(of: transform)
        let shown = turns % 2 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        let s = geometry.scale(forViewSize: shown)
        content.bounds = CGRect(origin: .zero, size: geometry.pageSize)
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = turns == 0 ? CGAffineTransform.identity : CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)
        if abs(s - 1) >= 0.0001 { t = t.scaledBy(x: s, y: s) }
        content.transform = t
    }

    /// Vierteldrehungen (0...3) im Drehanteil von `t` (der Massstab spielt keine Rolle)
    static func quarterTurns(of t: CGAffineTransform) -> Int {
        let q = Int((atan2(t.b, t.a) / (.pi / 2)).rounded())
        return ((q % 4) + 4) % 4
    }

    /// Dreht PDFKit das Overlay erst nach dem Einsetzen, folgt der Inhalt beim naechsten Layout
    override var transform: CGAffineTransform {
        didSet { if Self.quarterTurns(of: transform) != Self.quarterTurns(of: oldValue) { setNeedsLayout() } }
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
final class PDFEditorController: UIViewController, PDFPageOverlayViewProvider, PKCanvasViewDelegate {

    let store: DocumentStore
    let pdfView = PDFView()
    /// Werkzeuge der festen Leiste (geteilte Ansicht: beide Dokumente teilen sich einen Stand)
    let tools: EditorToolState
    /// Nur ein Editor fuehrt die Leiste (geteilte Ansicht: Uebung und Skript teilen sich eine Leiste); er schaltet den
    /// Objektmodus, meldet, ob die Leiste zu sehen ist, und nimmt Doppeltippen/Druecken des Apple Pencil an.
    let ownsToolPicker: Bool
    /// Leiste soll zu sehen sein (Schreiben erlaubt); `restorePicker` holt den Fokus zum Editor zurueck
    private var pickerWanted = false
    /// PDF-Seite (1-basiert), zu der beim ersten Anzeigen gesprungen wird (z. B. Skriptstelle).
    private var initialPDFPage: Int?
    /// Gemerkte Stelle des Reiters (Seite, Punkt, Zoom), beim ersten Anzeigen; gilt nur ohne `initialPDFPage`
    private var initialSpot: DocumentViewSpot?
    private let anchor = ToolPickerAnchor()
    /// Farbe und Staerke der Stifte fuer Objekte und "Text markieren" (`EditorPalette.swift`)
    let paletteSync = PaletteSync()
    /// Ein Objektwerkzeug der Leiste ist gewaehlt. In der anderen Haelfte der geteilten Ansicht schreibt die Canvas dann
    /// nicht (sie schriebe sonst mit dem letzten Stift weiter).
    private(set) var paletteObjectToolActive = false
    /// Blatt ueber dem Editor, nach dessen Verschwinden der Fokus zurueckkommt
    private weak var presentationSentinel: WindowExitSentinel?
    /// Ersatzversuche, wenn der Fokus ohne erkennbaren Grund nicht zurueckkam (hoechstens zwei)
    private var restoreFallbacks = 0
    /// Meldungen der Leiste (`EditorToolState.changes`)
    private var toolsSubscription: AnyCancellable?
    /// Leiste sichtbar bzw. nur Tinte (Korrektur-Modus); fuer `DocumentView` (nur der Editor, der die Leiste fuehrt)
    var onToolbarChange: ((EditorToolbarMode) -> Void)?
    /// Objektmodus an/aus oder anderes Objektwerkzeug (auch ueber die Leiste); fuer die Leisten in SwiftUI
    var onObjectModeChange: ((Bool, ObjectEditing.Tool) -> Void)?
    /// "In KI-Hilfe einfügen" im Bearbeitungsmenue und
    /// "Bereich an KI" (05.11.2026): oeffnet die KI-Hilfe; mit Anhang (markierter Text, Ausschnitt als Bild) steht er
    /// dort im Eingabefeld, ohne Anhang nur die KI-Hilfe zur aktuellen Seite
    var onAskAI: ((TutorAttachment?) -> Void)?
    /// Kurzer Hinweis unten im Editor (z. B. was "Auswählen" greift, wie "Bereich an KI" geht)
    var onHint: ((String) -> Void)?
    /// KI verbunden (`ufAIEnabled`); traegt "Schwebend" dann "KI fragen" am Rand der Palette
    var aiAvailable = false {
        didSet { if aiAvailable != oldValue { updateFloatingPalette() } }
    }
    /// Lage der Werkzeuge (Einstellung, `EditorToolbarPlacement`): oben/unten fest zeigt `DocumentView` die Leiste,
    /// "Schwebend" zeigt dieser Editor Apples Palette (nur der Editor, der die Werkzeuge fuehrt; am Mac nie)
    var toolbarPlacement: EditorToolbarPlacement = .standard {
        didSet { if toolbarPlacement != oldValue { updateFloatingPalette() } }
    }
    /// Apples schwebende Palette ("Schwebend"), erst bei Bedarf angelegt
    private(set) var floatingPalette: EditorFloatingPalette?
    /// "Als Karteikarte" aus markiertem PDF-Text (Schritt K): der markierte Text geht an das Blatt "Karte anlegen"
    var onFlashcardFromSelection: ((String) -> Void)?
    /// In der geteilten Ansicht teilen sich beide Dokumente einen Verlauf, damit "Rueckgaengig" der gemeinsamen
    /// Leiste immer den zuletzt geschriebenen Strich zuruecknimmt, egal auf welcher Seite.
    private let documentUndo: UndoManager
    private var undoTargets: [String: PageUndoTarget] = [:]
    /// Ziel der Eintraege "Seite eingefuegt" (Rueckgaengig legt die Seite in den Papierkorb, Wiederholen holt sie zurueck)
    private let pageUndoTarget = PageUndoTarget(key: "#seiten")
    private var live: [Int: PageInkView] = [:]
    private var parked: [PageInkView] = []
    private let parkedLimit = 6
    /// Hoechstens so viel Seitenflaeche (pt^2) geparkt: sechs A4-Seiten. PencilKit haelt je Canvas Kacheln von
    /// 512 x 512 pt in voller Bildschirmaufloesung (je etwa 4 MB, gemessen im Simulator): A4 vier, A0 quer 35
    /// (etwa 140 MB). Grosse Seiten (A2, Whiteboards bis A0, PC-Stand 7bcdfe5) werden darum nicht mehr auf Vorrat
    /// gehalten, sondern beim Zurueckscrollen neu aufgebaut (der Verlauf haengt am Seitenschluessel).
    static let parkedAreaLimit: CGFloat = 6 * 595 * 842
    private var renderScaleTask: Task<Void, Never>?
    private var lastFit: CGFloat = 0
    /// Einpassen auf die mittlere Seitenbreite statt der breitesten (M6, `ZoomPolicy.mixedFormatFactor`)
    private var mixedFormatFactor: CGFloat = 1
    private var userZoomed = false
    private var observers: [NSObjectProtocol] = []
    /// Mac: zwei Finger waagerecht auf dem Trackpad blaettern eine Seite weiter bzw. zurueck (`EditorPointerInput.swift`)
    private(set) var trackpadPageSwipe: TrackpadPageSwipe?
    private(set) var shownLayoutVersion = -1
    /// Ein Neuaufbau kam, waehrend der Stift auflag: er folgt beim Absetzen (`canvasViewDidEndUsingTool`, Audit P41-Z1)
    private var layoutWaitsForPencil = false
    /// Ein Neuaufbau kam, waehrend der Finger scrollte oder zoomte (auch Ausrollen): er folgt, sobald die Ansicht steht
    /// (`waitForScrollToSettle`). Der Tausch von `pdfView.document` verwirft alle Kacheln; mitten im Scrollen geriet
    /// PDFKit dabei auf dem iPad 9 (iPadOS 26.5, 3 GB) in die Ueberfreigabe einer Kachel-Oberflaeche (Absturz Build 30).
    private(set) var layoutWaitsForGesture = false
    private var settleTask: Task<Void, Never>?
    /// Nur fuer Tests: Geste laeuft (true) bzw. steht (false) statt des Zustands der Scroll-Ansicht
    var scrollGestureOverrideForTesting: Bool?
    /// Seite, die nach dem naechsten Neuaufbau gezeigt werden soll (nach Einfuegen, Papierkorb, Wiederherstellen).
    private var pendingFocusKey: String?

    /// Bildschirm fixieren (`EditorFreezeLock.swift`, docs/FIXIEREN-ABPAUSEN-2026-11-05.md): "Ansicht fixieren" sperrt
    /// Zoom, Scrollen und Seitenwechsel, "Zum Abpausen einfrieren" zusaetzlich jede Eingabe.
    var freezeMode: EditorFreeze.Mode = .off {
        didSet { if freezeMode != oldValue { freezeModeChanged(from: oldValue) } }
    }
    /// Kontrast fuer das Abpausen (weisser Hintergrund, ohne Seitenschatten); wirkt nur beim Abpausen
    var traceContrast = false {
        didSet { if traceContrast != oldValue { applyTraceLook() } }
    }
    /// Stelle und Zoom beim Fixieren; die Ansicht kehrt nach jedem Layout dorthin zurueck
    var freezeAnchor: FreezeAnchor?
    /// vom Fixieren abgeschaltete Gesten (werden beim Loesen wieder eingeschaltet)
    var freezeDisabledGestures: [WeakGesture] = []
    /// Stand der Gesten des Systems vor dem Fixieren (Zurueck-Wischen, Seitenleiste der geteilten Ansicht)
    var freezeSystemGestures: FreezeSystemGestures?

    var onZoomChange: ((CGFloat) -> Void)?
    private var lastZoomPublish: TimeInterval = 0
    private var lastPublishedZoom: CGFloat = -1
    /// Messung (`PencilFeelTests`): Sicherungen der Canvas an den Store und Zoom-Meldungen an SwiftUI
    private(set) var canvasSaves = 0
    private(set) var rawRebuilds = 0
    private(set) var zoomPublishes = 0
    /// Anzeige-Index und Seitenschluessel der aktuellen Seite.
    var onPageChange: ((Int, String?) -> Void)?
    /// Seitenaufbau, den die PDFView gerade zeigt (kann kurz vom neuesten Stand im Store abweichen).
    private(set) var shownLayout: DisplayLayout?

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

    /// Korrektur-Modus (`CorrectionMode.swift`): eigene Zeichenflaeche je Seite fuer den Korrekturvorschlag, schreibt
    /// nie in die eigenen Notizen (die sind in diesem Modus ausgeblendet und nur lesbar)
    var correction: CorrectionSession? {
        didSet { if correction !== oldValue { correctionModeChanged(from: oldValue) } }
    }
    /// Empfangene Korrektur ueber den eigenen Notizen (nur Anzeige, Warnfarbe, Randnotizen als Nadeln)
    var shownCorrection: CommunityCorrection? {
        didSet { if shownCorrection != oldValue { allOverlays.forEach(applyCorrection) } }
    }
    /// Verlauf der Korrektur-Zeichenflaechen (getrennt vom Verlauf der eigenen Notizen)
    let correctionUndo = UndoManager()
    /// Randnotiz setzen oder angetippt
    var onCorrectionNote: ((CorrectionNoteEvent) -> Void)?

    static func signature(_ layers: [ForeignSolutionLayer]) -> String {
        layers.map { "\($0.id):\($0.visible)" }.joined(separator: ",")
    }

    /// "Meine Notizen" sichtbar. Ausgeblendet: nur ansehen (Canvas ohne Eingabe, Leiste weg, kein Rueckgaengig,
    /// der Store nimmt keine schreibenden Aktionen an).
    var ownNotesVisible = true {
        didSet {
            store.ownNotesReadOnly = !ownNotesVisible
            guard ownNotesVisible != oldValue else { return }
            for v in allOverlays {
                if !ownNotesVisible, v.loaded { commitPendingUndo(v) }
                applyOwnNotes(to: v)
            }
            showToolPicker(pickerAllowed)
        }
    }

    /// Tarif erlaubt Schreiben (Plus, `UFFeatureMatrix.notes(plan:).canEdit`). Ohne (Free, nach dem Herabstufen):
    /// nur ansehen, die eigenen Notizen bleiben sichtbar (Canvas ohne Eingabe, keine Leiste, kein Rueckgaengig,
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
                documentUndo.removeAllActions(withTarget: pageUndoTarget)
            }
            showToolPicker(pickerAllowed)
        }
    }

    /// Schreiben gerade moeglich (eigene Notizen eingeblendet und Tarif mit Schreiben)
    var writable: Bool { ownNotesVisible && canEdit }

    /// Sichtbarkeit der eigenen Notizen und Eingabe der Canvas fuer ein Overlay
    private func applyOwnNotes(to overlay: PageInkView) {
        overlay.setOwnNotesVisible(ownNotesVisible)
        if !canEdit || (paletteObjectToolActive && !ownsToolPicker) { overlay.canvas.isUserInteractionEnabled = false }
        objects.prepare(overlay)
    }

    /// Mac ("Designed for iPad"): dieselbe App, ohne Apple Pencil; Maus, Trackpad und Tastatur (`EditorPointerInput.swift`)
    static var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }
    /// iPad: Standard "Nur Stift" (`.pencilOnly`: der Finger blaettert), ueber den Schalter in der Leiste "Finger
    /// zeichnet" (`.anyInput`: zwei Finger blaettern). Nie `.default`: damit entschiede die iPadOS-Einstellung "Nur mit
    /// Apple Pencil zeichnen"; die war am Geraet aus, der Finger schrieb statt zu blaettern (Geraetetest 03.11.2026).
    /// Mac siehe `EditorPointer.config`.
    var drawingPolicy: PKCanvasViewDrawingPolicy { pointerConfig.drawingPolicy }

    /// Schreiben und Blaettern auf diesem Geraet
    var pointerConfig: EditorPointer.Config { EditorPointer.config(isMac: Self.isMac, pencilOnly: pencilOnly) }

    var pencilOnly = true {
        didSet {
            guard pencilOnly != oldValue else { return }
            allOverlays.forEach {
                $0.canvas.drawingPolicy = drawingPolicy
                $0.correctionView?.ink.drawingPolicy = drawingPolicy
            }
            configureScrollGestures()
        }
    }

    /// Schreibt der Finger (am Mac: die Maus) gerade nicht, sondern blaettert?
    var effectivePencilOnly: Bool { pointerConfig.panMinimumTouches == 1 }

    /// Verlauf fuer den Ansichtsmodus: leer und ohne Eintraege, damit Rueckgaengig ueber das System (Cmd-Z,
    /// Wischen mit drei Fingern, Leiste) nichts zuruecknimmt und nichts schreibt.
    private let viewOnlyUndo: UndoManager = {
        let u = UndoManager()
        u.disableUndoRegistration()
        return u
    }()

    /// Verlauf der Responder-Kette. Ausgeblendete eigene Notizen = nur ansehen: kein Rueckgaengig (der Verlauf des
    /// Dokuments bleibt erhalten und gilt wieder, sobald die Notizen eingeblendet sind).
    override var undoManager: UndoManager? { ownNotesVisible ? documentUndo : (correction != nil ? correctionUndo : viewOnlyUndo) }

    /// Tastatur (Mac, iPad mit Tastatur): Blaettern, Seiten, Zoom (`EditorPointerInput.swift`)
    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + editorKeyCommands }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(editorKey(_:)) { return acceptsEditorKeys }
        if let edit = canPerformEditAction(action) { return edit }
        if action == #selector(deleteSelectedObjects(_:)) { return acceptsEditorKeys && objects.selection != nil }
        if action == #selector(finishObjectsKey(_:)) { return (Self.isMac && presentationMode) || (acceptsEditorKeys && objects.isActive) }
        return super.canPerformAction(action, withSender: sender)
    }

    init(store: DocumentStore, tools: EditorToolState? = nil, ownsToolPicker: Bool = true,
         undoManager: UndoManager? = nil, initialPDFPage: Int? = nil, initialSpot: DocumentViewSpot? = nil) {
        self.store = store
        self.tools = tools ?? EditorToolState()
        self.ownsToolPicker = ownsToolPicker
        self.documentUndo = undoManager ?? UndoManager()
        self.initialPDFPage = initialPDFPage
        self.initialSpot = initialPDFPage == nil ? initialSpot : nil
        super.init(nibName: nil, bundle: nil)
        if documentUndo.levelsOfUndo == 0 { documentUndo.levelsOfUndo = 150 }     // wie der Verlauf im Web-Editor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    var allOverlays: [PageInkView] { Array(live.values) + parked }
    /// Verlauf des Dokuments (auch fuer die Objekt-Werkzeuge)
    var editUndo: UndoManager { documentUndo }
    /// Objekt-Werkzeuge (Editor-Schritt 6); eingeschaltet nimmt die Canvas keine Eingabe an
    private(set) lazy var objects = ObjectEditing(controller: self)
    /// Rechtsklick-Menue, Ziehen und Ablegen, Mauszeiger (10.11.2026)
    private(set) lazy var mouseSupport = EditorMouseSupport(controller: self)
    /// "Bild einfügen …" aus Kontextmenue oder Menueleiste: die Dokumentansicht zeigt die Auswahl (Fotos oder Dateien)
    var onRequestImage: ((Bool) -> Void)?
    /// Schreiblupe (`WritingMagnifier.swift`), offen oder nil
    var magnifier: WritingMagnifier?
    /// Praesentation (11.11.2026, `EditorPresentation.swift`): ohne Leiste, ganze Seite, Tasten und Klicker blaettern
    /// seitenweise
    var presentationMode = false {
        didSet {
            guard presentationMode != oldValue else { return }
            presentedSize = view.bounds.size
            presentationModeChanged()
        }
    }
    /// Groesse beim letzten Einpassen der Praesentation
    var presentedSize: CGSize = .zero
    /// Esc in der Praesentation: die Dokumentansicht beendet sie
    var onEndPresentation: (() -> Void)?
    var onMagnifierChange: ((Bool) -> Void)?

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
        pdfView.interpolationQuality = .high
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.autoScales = true                     // nur fuer das erste Einpassen, danach aus
        pdfView.pageOverlayViewProvider = self        // vor dem Setzen des Dokuments
        pdfView.isInMarkupMode = true                 // Overlays bekommen die Stifteingabe; aus nur bei "Text markieren"
        showLayout()

        if ownsToolPicker {
            pickerWanted = pickerAllowed
            publishToolbar()
            installPencilInteraction()
        }

        objects.markupColor = { [weak self] kind in self?.paletteSync.markupColor(kind) ?? PageObjectEdit.markerColors[0] }
        toolsSubscription = tools.changes.sink { [weak self] change in
            MainActor.assumeIsolated { self?.toolsChanged(change) }
        }
        toolsChanged(.tool, initial: true)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scaleChanged() }
        })
        // Fokus zurueck zum Editor, sobald das Hindernis weg ist (statt in Abstaenden nachzusehen): Tastatur weg, Textfeld
        // fertig, Menue- oder Popover-Fenster zu, Fenster wieder vorn, zurueck in der App
        for name in [UIResponder.keyboardDidHideNotification, UIApplication.didBecomeActiveNotification,
                     UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIWindow.didBecomeHiddenNotification, UIWindow.didBecomeKeyNotification,
                     UIScene.didActivateNotification] {                  // Fenster der App (Split View, Stage Manager) wieder aktiv
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, self.pickerWanted, !self.editorHoldsFocus else { return }
                    self.restorePickerSoon()
                }
            })
        }
        // Lasso-Auswahl von PencilKit ohne Bildschirmtastatur (Meldung 20.11.2026, `InkSelectionKeyboard`): vorab, und
        // falls die Auswahl in einer neuen iPadOS-Fassung anders heisst, beim ersten Erscheinen der Tastatur
        InkSelectionKeyboard.install()
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let v = UIResponder.uf_current as? UIView, v.isDescendant(of: self.view) else { return }
                InkSelectionKeyboard.suppress(for: v)
            }
        })
        // Auswahl von PDF-Text aufgehoben: der Fokus darf zurueck (waehrend der Auswahl haelt PDFKit ihn)
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pickerWanted, !self.editorHoldsFocus, !self.hasPDFSelection else { return }
                self.restorePickerSoon()
            }
        })
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onPageChange?(self.currentPageIndex, self.currentPageKey)
            }
        })
        store.onPagesChanged = { [weak self] keys in self?.reloadPages(keys) }
        // Rechtsklick (Mac), Ziehen von Bildern hinein, Mauszeiger je Werkzeug (`EditorMouseSupport.swift`)
        mouseSupport.install(on: pdfView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureScrollGestures()
        if ownsToolPicker { publishToolbar() }
        // Fokus zum Anker (Tastenbefehle, schwebende Palette), ausser jemand markiert gerade PDF-Text oder tippt
        if ownsToolPicker, !hasPDFSelection, !Self.isTypingField(UIResponder.uf_current) {
            anchor.becomeFirstResponder()
        } else {
            restorePickerSoon()                             // wartet auf das Hindernis (Textfeld fertig, Blatt weg)
        }
        logPaletteProbeIfRequested()
        if let p = initialPDFPage {
            initialPDFPage = nil
            // PDF-Seite -> Anzeige-Index (eingefuegte oder entfernte Seiten verschieben die Zaehlung)
            let index = shownLayout?.entries.firstIndex { $0.pdfIndex == p } ?? max(0, p - 1)
            goToPage(index)
        } else if let s = initialSpot {
            initialSpot = nil
            restore(s)
            // PDFKit legt die Seiten nach dem Zoom erst im naechsten Durchlauf neu: dort noch einmal an die Stelle
            DispatchQueue.main.async { [weak self] in self?.restore(s, zoom: false) }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        releaseSystemGestures()                               // Zurueck-Wischen gehoert wieder der Navigation
        if magnifier != nil { setMagnifier(false) }          // Schreiblupe gehoert zu diesem Dokument
        // schwebende Palette gehoert zu diesem Dokument (erscheint die Ansicht wieder, zeigt `viewDidAppear` sie neu)
        floatingPalette?.setVisible(false, for: [anchor])
        // Verlassen schreibt nie: jede Aenderung einer geladenen Canvas ging schon beim Zeichnen an den Store
        // (`canvasViewDrawingDidChange`), hier wird nur ein offener Rueckgaengig-Schritt abgeschlossen
        for v in allOverlays where v.loaded { commitPendingUndo(v) }
        if !ownsToolPicker {
            // geteilter Verlauf: Eintraege dieses Dokuments entfernen, sonst wirkt "Rueckgaengig" ins Leere
            for t in undoTargets.values { documentUndo.removeAllActions(withTarget: t) }
            undoTargets = [:]
            documentUndo.removeAllActions(withTarget: pageUndoTarget)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // fixiert: kein neues Einpassen, Zoom und Stelle bleiben (Leisten ein/aus, geteilte Ansicht, Drehen)
        if freezeAnchor != nil, lastFit > 0 {
            keepFrozenView()
            return
        }
        let widest = pdfView.scaleFactorForSizeToFit
        guard widest > 0 else { return }
        let fit = widest * mixedFormatFactor
        if lastFit == 0 {
            let page = pdfView.currentPage
            pdfView.autoScales = false
            applyLimits(fit: fit, widest: widest)
            pdfView.scaleFactor = fit
            centerColumn(keeping: page)
        } else if abs(fit - lastFit) > 0.0001 {
            let next = ZoomPolicy.scaleAfterResize(current: pdfView.scaleFactor, oldFit: lastFit, newFit: fit, userZoomed: userZoomed,
                                                   widestFit: widest)
            applyLimits(fit: fit, widest: widest)
            let page = pdfView.currentPage
            pdfView.scaleFactor = next
            if !userZoomed { centerColumn(keeping: page) }
        }
        lastFit = fit
        // Praesentation: neue Fenstergroesse (Vollbild, Beamer) -> ganze Seite neu einpassen
        if presentationMode, view.bounds.size != presentedSize {
            presentedSize = view.bounds.size
            DispatchQueue.main.async { [weak self] in self?.fitPage() }
        }
    }

    /// Gemischte Formate (M6): PDFView legt alle Seiten mittig in eine Spalte so breit wie die breiteste Seite. Bei der
    /// Einpassung auf die mittlere Breite die Ansicht waagerecht auf die Mitte stellen; dort liegen alle schmaleren
    /// Seiten (sonst stand sie am linken Rand der breiten Spalte, und die Seiten waren nicht zu sehen).
    /// `page`: die Seite vor dem Zoomwechsel; PDFView verschiebt beim Zoomen auch senkrecht, danach wieder zu ihr.
    private func centerColumn(keeping page: PDFPage?) {
        guard mixedFormatFactor > 1.001, freezeMode == .off else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let page, page.document === self.pdfView.document { self.pdfView.go(to: page) }
            self.centerHorizontally()
        }
    }

    /// Ansicht waagerecht auf die Mitte der Seitenspalte (dort liegen alle Seiten, gemischte Formate)
    private func centerHorizontally() {
        guard mixedFormatFactor > 1.001, let scroll = firstScrollView(in: pdfView) else { return }
        let x = max(0, (scroll.contentSize.width - scroll.bounds.width) / 2)
        scroll.setContentOffset(CGPoint(x: x, y: scroll.contentOffset.y), animated: false)
    }

    /// Zu einer Seite springen. Bei gemischten Formaten schiebt `PDFView.go(to:)` die Ansicht in der breiten Spalte
    /// waagerecht neben alle Seiten (gemessen: Versatz 3 800 pt, keine Seite sichtbar); danach wieder auf die Mitte.
    private func show(page: PDFPage) {
        pdfView.go(to: page)
        centerHorizontally()
    }

    /// Zoomgrenzen wie nach dem Einpassen (nach der Praesentation, die fuer die ganze Seite weiter herauszoomt)
    func restoreZoomLimits() {
        let widest = pdfView.scaleFactorForSizeToFit
        guard widest > 0 else { return }
        applyLimits(fit: widest * mixedFormatFactor, widest: widest)
    }

    private func applyLimits(fit: CGFloat, widest: CGFloat) {
        let range = ZoomPolicy.limits(fitScale: fit, widestFit: widest)
        pdfView.minScaleFactor = range.lowerBound
        pdfView.maxScaleFactor = range.upperBound
    }

    /// Faktor fuer die Zeichenflaeche: Bildschirm mal PDF-Zoom in festen Stufen. Den Speicher begrenzt die Flaeche der
    /// Zeichenflaeche (`PageInkView.inkPixelBudget`), nicht mehr dieser Faktor; `limit` bleibt fuer Aufrufer mit eigener Grenze.
    nonisolated static func renderScale(screen: CGFloat, zoom: CGFloat, limit: CGFloat = .infinity) -> CGFloat {
        guard zoom.isFinite, zoom > 0 else { return screen }
        // feste Stufen: jeder Wechsel zeichnet die Tinte neu, das soll nicht bei jedem kleinen Pinch passieren
        // ab dem 4-fachen zeigt die Zeichenflaeche nur den sichtbaren Teil der Seite (`PageInkView.inkLayout`): Die
        // Grenze ist die Flaeche, nicht mehr der Zoom (bis 1.0.7 hoechstens 4-fach, bei 600 % verpixelt)
        let steps = PencilTuning.sharpInkWindow ? PageInkView.zoomSteps : PageInkView.zoomSteps.filter { $0 <= PageInkView.wholePageZoom }
        let step = steps.first { $0 >= zoom } ?? steps[steps.count - 1]
        return min(limit, screen * step)
    }

    private var currentRenderScale: CGFloat {
        Self.renderScale(screen: screenScale, zoom: pdfView.scaleFactor)
    }

    private var screenScale: CGFloat { view.window?.screen.scale ?? UIScreen.main.scale }

    /// Erst nach dem Zoomen: Waehrend des Pinchens wuerde jede Aenderung die Zeichenflaeche neu anlegen
    private func scheduleRenderScale() {
        renderScaleTask?.cancel()
        renderScaleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            let s = self.currentRenderScale
            // nur sichtbare: geparkte bekommen den Zoom beim Wiederanzeigen (`pdfView(_:overlayViewFor:)`)
            let targets = PencilTuning.rescaleVisibleOnly ? Array(self.live.values) : self.allOverlays
            targets.forEach { $0.setRenderScale(s, screen: self.screenScale) }
            self.publishZoom(force: true)
        }
    }

    private func scaleChanged() {
        // fixiert: ein Zoom, der doch durchkam (Trackpad, PDFKit), wird zurueckgenommen
        if let a = freezeAnchor, abs(pdfView.scaleFactor - a.scale) > 0.0001 {
            DispatchQueue.main.async { [weak self] in self?.keepFrozenView() }
        }
        scheduleRenderScale()
        if lastFit > 0 { userZoomed = ZoomPolicy.isUserZoom(scale: pdfView.scaleFactor, fitScale: lastFit) }
        publishZoom(force: false)
    }

    /// Zoom an SwiftUI melden (Anzeige, gemerkte Stelle): beim Pinchen hoechstens alle `zoomPublishInterval`, am Ende
    /// (`scheduleRenderScale`) sicher mit dem letzten Wert; nur bei geaendertem Wert
    private func publishZoom(force: Bool) {
        guard let report = onZoomChange else { return }
        let value = lastFit > 0 ? pdfView.scaleFactor / lastFit : 1
        guard value != lastPublishedZoom else { return }
        let now = CACurrentMediaTime()   // keine Startzeit-API mit Begruendungspflicht (PrivacyInfo, tests/test_ai_consent.py)
        if !force, PencilTuning.throttleZoomPublish, now - lastZoomPublish < PencilTuning.zoomPublishInterval { return }
        lastZoomPublish = now
        lastPublishedZoom = value
        zoomPublishes += 1
        report(value)
    }

    /// Stift scrollt nie; im Finger-Zeichenmodus scrollen zwei Finger. Mausrad und Trackpad (zwei Finger rollen, Pinch)
    /// kommen als eigene Ereignisse, nicht als Beruehrungen: `allowedTouchTypes` und `minimumNumberOfTouches` halten sie
    /// nicht auf (geprueft in UIKit 09.11.2026, docs/paritaet/MAC-BEDIENUNG-2026-11-09.md).
    func configureScrollGestures() {
        guard let scroll = firstScrollView(in: pdfView) else { return }
        let c = pointerConfig
        let types = c.panTouchTypes.map { NSNumber(value: $0.rawValue) }
        scroll.panGestureRecognizer.allowedTouchTypes = types
        scroll.panGestureRecognizer.minimumNumberOfTouches = c.panMinimumTouches
        scroll.pinchGestureRecognizer?.allowedTouchTypes = types
        if Self.isMac, trackpadPageSwipe == nil {
            let swipe = TrackpadPageSwipe(controller: self)
            pdfView.addGestureRecognizer(swipe.recognizer)
            trackpadPageSwipe = swipe
        }
        scroll.delaysContentTouches = false
        applyFreezeGestures()
    }

    func firstScrollView(in v: UIView) -> UIScrollView? {
        if let s = v as? UIScrollView { return s }
        for sub in v.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
    }

    // MARK: Anzeige-PDF (neu aufbauen, wenn sich die Seitenstruktur aendert)

    /// Ein Neuaufbau aus `updateUIViewController` ist schon fuer den naechsten Durchlauf bestellt
    private var layoutScheduled = false

    /// Neuaufbau aus `PDFEditorView.updateUIViewController`: erst NACH der laufenden SwiftUI-Aktualisierung.
    ///
    /// Haenger am iPad des Inhabers (17.11.2026, iPadOS 27.2, Mitschnitt `~/Studora-Builds/haenger-ipad-17-11.trace`):
    /// "Seite drehen" aus dem Menue -> neue Seitenliste -> SwiftUI ruft `updateUIViewController` -> `showLayout()` setzt
    /// `pdfView.document` -> PDFKit haengt neue Ansichten ein und UIKit gibt dabei den Fokus weiter
    /// (`_promoteSelfOrDescendantToFirstResponderIfNecessary`) -> die SwiftUI-Huelle erfaehrt den Fokuswechsel
    /// (`_UIHostingView._didChange(toFirstResponder:)`) und will ihre Ansichten aktualisieren, WAEHREND sie gerade
    /// aktualisiert: Der Hauptthread kam aus AttributeGraph nie zurueck (12 s lang jede Probe an derselben Stelle,
    /// App eingefroren). Darum laeuft der Tausch einen Durchlauf spaeter, ausserhalb der Aktualisierung.
    func showLayoutAfterUpdate() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            self.showLayout()
        }
    }

    /// Zeigt den aktuellen Seitenaufbau. Bleibt auf derselben Seite (ueber den Seitenschluessel) und beim Zoom.
    /// Der Rueckgaengig-Verlauf haengt am Seitenschluessel und bleibt erhalten.
    func showLayout() {
        guard store.layoutVersion != shownLayoutVersion, let layout = store.layout else { return }
        // Stift liegt auf: das neue Dokument nahme die Zeichenflaeche unter ihm weg, PencilKit braeche den laufenden
        // Strich ab (verloren). Neue Seitenliste vom Server, fertig geladene Browser-Seite: erst nach dem Absetzen.
        if live.values.contains(where: \.isDrawing) {
            layoutWaitsForPencil = true
            return
        }
        layoutWaitsForPencil = false
        // Finger scrollt/zoomt (oder die Ansicht rollt aus): Dokument erst tauschen, wenn sie steht. Das erste Dokument
        // (noch keins gezeigt) kommt sofort.
        if shownLayout != nil, scrollGestureActive {
            layoutWaitsForGesture = true
            waitForScrollToSettle()
            return
        }
        layoutWaitsForGesture = false
        settleTask?.cancel()
        settleTask = nil
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
        for v in allOverlays { keepPaletteFocus(leaving: v) }
        if shownLayout != nil { StiftZaehler.bump(.seitenNeuAufgebaut) }
        StiftSpur.log("Seiten neu aufgebaut (erstes Mal: \(shownLayout == nil))")
        live = [:]
        parked = []
        shownLayout = layout
        shownLayoutVersion = store.layoutVersion
        let pdf = layout.pdf
        pdfView.document = pdf
        // fixiert: PDFKit legt mit dem neuen Dokument neue Seitenansichten samt Doppeltippen-Zoom an (Audit P41-09)
        if freezeMode != .off { applyFreezeGestures() }
        mixedFormatFactor = ZoomPolicy.mixedFormatFactor(widths: (0..<pdf.pageCount).compactMap { i in
            pdf.page(at: i).map { PageGeometry(boxSize: $0.bounds(for: .cropBox).size, rotation: $0.rotation).pageSize.width }
        })
        view.setNeedsLayout()                                   // neue Einpassung, falls sich die Formate geaendert haben
        if lastFit > 0 { pdfView.scaleFactor = freezeAnchor?.scale ?? keepScale }
        if freezeAnchor != nil {
            restoreFreezeAnchor()                               // fixiert: dieselbe Stelle derselben Seite
        } else if let keepKey, let i = layout.index(ofKey: keepKey), let page = pdf.page(at: i) {
            show(page: page)
        }
        // PDFKit nimmt beim Setzen des Dokuments den Fokus; zurueck zum Anker (Tastenbefehle, Rueckgaengig)
        if ownsToolPicker, pickerWanted, paletteBlocker == .none, !anchor.isFirstResponder { anchor.becomeFirstResponder() }
        // aktuelle Seite melden (auch ohne Blaettern), nach der laufenden SwiftUI-Aktualisierung
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPageChange?(self.currentPageIndex, self.currentPageKey)
        }
    }

    /// Scrollt, zoomt oder rollt die PDF-Ansicht gerade aus?
    var scrollGestureActive: Bool {
        if let o = scrollGestureOverrideForTesting { return o }
        guard let s = firstScrollView(in: pdfView) else { return false }
        return s.isTracking || s.isDragging || s.isDecelerating || s.isZooming || s.isZoomBouncing
    }

    /// Wartet, bis die Ansicht steht, und holt dann den aufgeschobenen Neuaufbau nach (kurze Abfrage statt eigener
    /// Gestenziele: Ausrollen und Zurueckfedern haben keine Geste mehr)
    private func waitForScrollToSettle() {
        guard settleTask == nil else { return }
        settleTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.layoutWaitsForGesture else { self.settleTask = nil; return }
                if !self.scrollGestureActive {
                    self.settleTask = nil
                    self.showLayout()
                    return
                }
            }
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
            overlay.setRenderScale(currentRenderScale, screen: screenScale)     // Zoom kann sich seit dem Parken geaendert haben
            if overlay.foreignReleased { applyForeign(overlay) }      // nach einer Speicherwarnung neu aufbauen
            // Laden wurde beim Wegscrollen abgebrochen (M4): jetzt nachholen
            if !overlay.loaded, overlay.loadTask == nil { loadContent(into: overlay) }
        } else {
            let box = page.bounds(for: .cropBox).size
            overlay = PageInkView(pageIndex: index, pageKey: key, generation: shownLayoutVersion,
                                  geometry: PageGeometry(boxSize: box, rotation: page.rotation))
            configure(overlay)
            applyOwnNotes(to: overlay)
            applyForeign(overlay)
            applyCorrection(overlay)
            loadContent(into: overlay)
        }
        live[index] = overlay
        if Self.isMac {
            mouseSupport.adoptContextMenu(of: overlay.canvas)               // falls PencilKit seine Ansicht neu anlegte
            // im Objektmodus nimmt die Zeichenflaeche keine Eingabe an: dann trifft der Rechtsklick die Seite selbst
            // (vorher kam das Textmenue der PDF statt dem der Textfelder und Formen)
            mouseSupport.ensureContextMenu(on: overlay.content)
        }
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageInkView else { return }
        keepPaletteFocus(leaving: overlay)
        // Scrollen schreibt nie (alles ist schon im Store), nur ein offener Rueckgaengig-Schritt wird abgeschlossen;
        // eine noch nicht gesicherte Aenderung (Stift lag auf, `storePending`) jetzt sichern
        if overlay.storePending { saveCanvas(overlay) }
        if overlay.loaded { commitPendingUndo(overlay) }
        if live[overlay.pageIndex] === overlay { live.removeValue(forKey: overlay.pageIndex) }
        guard overlay.generation == shownLayoutVersion else { return }       // Overlay eines alten Seitenaufbaus: verwerfen
        parked.append(overlay)
        // geparkt: zurueck auf Bildschirmaufloesung (gezoomte Kacheln kosten je Seite bis ~130 MB); beim Wiederanzeigen
        // stellt `pdfView(_:overlayViewFor:)` den aktuellen Zoom ein
        overlay.setRenderScale(screenScale, screen: screenScale)
        // der Verlauf bleibt: er haengt am Seitenschluessel und wirkt spaeter auf ein neues Overlay oder den Store
        while parked.count > parkedLimit || (!parked.isEmpty && parkedArea > Self.parkedAreaLimit) {
            parked.removeFirst()
        }
    }

    /// Seitenflaeche der geparkten Overlays (pt^2)
    private var parkedArea: CGFloat { parked.reduce(0) { $0 + $1.geometry.pageSize.width * $1.geometry.pageSize.height } }

    /// Zahl der geparkten Overlays (nur fuer Tests)
    var parkedCountForTesting: Int { parked.count }
    var parkedOverlaysForTesting: [PageInkView] { parked }

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
    /// Danach die geparkten Overlays selbst (je Seite eine PencilKit-Flaeche mit eigenen Kacheln): ihr Inhalt liegt schon
    /// im Store, der Verlauf haengt am Seitenschluessel; beim Zurueckscrollen wird die Seite neu aufgebaut. Auf dem
    /// iPad 9 (3 GB) traf PDFKit unter Speicherdruck seinen Kachelfehler (Absturz Build 30). Ein Overlay mit Strichen,
    /// die vor dem Laden entstanden und noch nicht gesichert sind, bleibt.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        for overlay in parked where !overlay.foreignReleased { overlay.releaseForeign() }
        releaseParkedOverlays()
    }

    /// Geparkte Overlays freigeben (Speicherwarnung), ausser solchen mit noch ungesicherten fruehen Strichen
    func releaseParkedOverlays() {
        let keep = parked.filter { !$0.loaded && !$0.canvas.drawing.strokes.isEmpty }
        for overlay in parked where !keep.contains(where: { $0 === overlay }) {
            overlay.loadTask?.cancel()
            overlay.loadTask = nil
        }
        parked = keep
    }

    /// Overlay einer Anzeige-Seite (nur fuer Tests: erzeugt es wie PDFKit beim Scrollen).
    func overlayForTesting(at index: Int) -> PageInkView? {
        guard let page = pdfView.document?.page(at: index) else { return nil }
        return pdfView(pdfView, overlayViewFor: page) as? PageInkView
    }

    private func configure(_ overlay: PageInkView) {
        overlay.setRenderScale(currentRenderScale, screen: screenScale)
        let c = overlay.canvas
        c.drawingPolicy = drawingPolicy
        c.delegate = self
        // alle Finger und der Stift sind weg: ein Laden, das darauf gewartet hat, kann laufen
        overlay.touchTracker.onAllEnded = { [weak self, weak overlay] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self, let overlay else { return }
                self.reloadIfDeferred(overlay)
            }
        }
        c.tool = canvasTool
        c.isRulerActive = tools.ruler
        if Self.isMac { mouseSupport.adoptContextMenu(of: c) }   // Rechtsklick: unser Menue statt dem der Zeichenflaeche
        // "Schwebend": Palette auch, wenn diese Zeichenflaeche den Fokus hat (Schreiben im Dokument daneben)
        if let f = floatingPalette, floatingPaletteWanted { f.setVisible(true, for: [c]) }
    }

    /// - Parameter remote: Inhalt hat sich ausserhalb dieses Editors geaendert (Server, Zusammenfuehrung, Aktion).
    /// Erstes Laden einer Seite, die schon wieder aus dem Bild ist, wird abgebrochen (M4, docs/EDITOR-MESSUNG.md): beim
    /// schnellen Blaettern ueber volle Seiten warteten die sichtbaren Seiten sonst auf das Dekodieren aller
    /// uebersprungenen (Striche bis 2,8 s zu spaet). Das Overlay laedt beim Wiederanzeigen (`pdfView(_:overlayViewFor:)`).
    /// Geladene Overlays laden immer zu Ende (fremde Aenderung, Rueckgaengig), auch geparkt.
    private func loadContent(into overlay: PageInkView, remote: Bool = false) {
        overlay.loadTask?.cancel()
        overlay.loadTask = Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay else { return }
            defer { if !Task.isCancelled { overlay.loadTask = nil } }
            guard self.wantsContent(overlay) else { return }
            let entry = self.store.entry(forKey: overlay.pageKey)
            let objects = await self.store.objects(forPageKey: overlay.pageKey)
            guard !Task.isCancelled else { return }
            self.showObjects(objects, entry: entry, on: overlay)
            guard self.wantsContent(overlay) else { return }
            let drawing = await self.store.drawing(forPageKey: overlay.pageKey)
            guard !Task.isCancelled else { return }
            self.apply(drawing, to: overlay, remote: remote)
        }
    }

    /// Lohnt sich das Laden noch? Sichtbar, schon geladen oder mit fruehen Strichen (die gesichert werden muessen)
    private func wantsContent(_ overlay: PageInkView) -> Bool {
        overlay.loaded || live[overlay.pageIndex] === overlay || !overlay.canvas.drawing.strokes.isEmpty
    }

    private func showObjects(_ objects: [JSONValue], entry: DisplayLayout.Entry?, on overlay: PageInkView) {
        let placeholder = entry?.kind == "asset" && entry?.assetShown != true
            ? "Eingefügte Seite aus dem Browser – wird geladen oder ist hier nicht verfügbar. Notizen hier werden gespeichert." : nil
        overlay.objectsView.show(template: entry?.template, placeholder: placeholder, objects: objects, images: store.images)
        for o in objects where o["type"]?.string == "image" {
            if let src = o["src"]?.string, store.images[src] == nil {
                // mit dem zuletzt gezeigten Inhalt neu zeichnen, nie mit dem Stand beim Anstossen (Pruefbericht 502)
                store.loadImage(src) { [weak self, weak overlay] in
                    guard let self, let overlay else { return }
                    overlay.objectsView.update(images: self.store.images)
                }
            }
        }
    }

    /// Zeichnung setzen, ohne einen laufenden Strich zu unterbrechen. Striche, die schon vor dem Laden auf der
    /// Canvas entstanden sind, bleiben erhalten.
    private func apply(_ drawing: PKDrawing, to overlay: PageInkView, remote: Bool = false) {
        if overlay.isDrawing { overlay.deferredReload = true; return }
        // Ein Strich ist abgesetzt, aber von PencilKit noch nicht gemeldet: Er steht weder in der Zeichenflaeche noch im
        // geladenen Stand. Jetzt (neu) setzen koennte ihn kosten (Meldung 17.11.2026: "ab und zu geht ein Strich ganz
        // weg") - erst nach seiner Meldung (`reloadIfDeferred`). Gilt auch fuer das erste Laden einer Seite, auf der
        // man sofort losschreibt.
        // Eine schon geladene Seite wird ausserdem nur in einer Schreibpause neu gesetzt: PencilKit verliert einen
        // Strich, der wenige Millisekunden nach dem Neu-Setzen beginnt (`PencilTuning.rebuildFromRawPointsAfterLift`).
        if PencilTuning.liftBelongsToItsStroke,
           overlay.hasOpenLift || overlay.touchCouldDraw
            || (overlay.loaded && overlay.touchTracker.quiet < PencilTuning.reloadQuietSeconds) {
            overlay.deferredReload = true
            scheduleDeferredReload(overlay)
            return
        }
        // Neu setzen baut alle Striche neu auf (sie verschwinden kurz): gleicher Stand bleibt stehen
        if overlay.loaded, drawing == overlay.canvas.drawing { return }
        var next = drawing
        if !overlay.loaded, !overlay.canvas.drawing.strokes.isEmpty { next.append(overlay.canvas.drawing) }
        if remote, overlay.loaded,
           next.strokes.count != overlay.canvas.drawing.strokes.count || next != overlay.canvas.drawing {
            // fremde Aenderung auf dieser Seite: alte Schnappschuesse wuerden sie wieder zuruecknehmen
            dropUndo(forKey: overlay.pageKey)
        }
        if overlay.loaded { StiftZaehler.bump(.neuGeladen) }
        StiftSpur.log("Zeichnung aus dem Speicher gesetzt: geladen \(overlay.loaded), fremd \(remote), Striche \(overlay.canvas.drawing.strokes.count) -> \(next.strokes.count)")
        overlay.lastShrinkAllowed = CACurrentMediaTime()
        if overlay.loaded { endInkSelection(on: overlay) }
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
        StiftSpur.log("Verlauf einer Seite verworfen (hatte Eintraege: \(undoTargets[key] != nil))")
        guard let t = undoTargets.removeValue(forKey: key) else { return }
        documentUndo.removeAllActions(withTarget: t)
    }

    /// Schritt "Seite `key` von `old` nach `new`" merken. Gemerkt wird nur der Unterschied (`InkUndoStep`: welche
    /// Striche entfernt, welche hinzugefuegt); Rueckgaengig wendet ihn umgekehrt auf den jetzigen Stand an. Vorher
    /// setzte Rueckgaengig die ganze Seite auf `old` zurueck - war `old` veraltet, kamen geloeschte Striche zurueck
    /// (Fehlerbericht 13.11.2026). Schritte ohne Aenderung werden nicht gemerkt (sie leerten nur "Wiederholen").
    private func registerUndo(key: String, restore old: PKDrawing, redo new: PKDrawing) {
        let step = InkUndoStep.between(old, new)
        StiftSpur.log("Schritt merken: -\(step.removed.count) +\(step.added.count)\(step.isEmpty ? " (leer, nicht gemerkt)" : ""), vorher \(old.strokes.count) nachher \(new.strokes.count) Striche, Gruppe \(documentUndo.groupingLevel), kannZurueck \(documentUndo.canUndo), kannVor \(documentUndo.canRedo)")
        guard !step.isEmpty else { return }
        documentUndo.beginSeparateStep()                    // nie mit einem anderen Strich/Radieren zusammen
        registerInk(step, key: key, undoing: true)
    }

    /// Eintrag im Verlauf: `undoing` = beim Ausfuehren zuruecknehmen (Rueckgaengig), sonst wieder anwenden
    /// (Wiederholen); der Gegeneintrag entsteht sofort im Handler
    private func registerInk(_ step: InkUndoStep, key: String, undoing: Bool) {
        documentUndo.registerUndo(withTarget: undoTarget(key)) { [weak self] _ in
            MainActor.assumeIsolated {
                // ohne Schreiben im Tarif nimmt ein Schritt, den `removeAllActions(withTarget:)` nicht erreicht hat
                // (z. B. in einer noch offenen Gruppe), nichts zurueck, auch nicht auf der Canvas
                guard let self, self.canEdit else { return }
                self.registerInk(step, key: key, undoing: !undoing)
                self.applyInk(step, key: key, undoing: undoing)
            }
        }
    }

    /// Schritt auf den jetzigen Stand der Seite anwenden: geladene Canvas sofort, sonst den gespeicherten Stand
    private func applyInk(_ step: InkUndoStep, key: String, undoing: Bool) {
        func change(_ d: PKDrawing) -> PKDrawing { undoing ? step.reverted(on: d) : step.reapplied(on: d) }
        StiftZaehler.bump(undoing ? .rueckgaengig : .wiederholen)
        if StiftSpur.isOn {
            let o = boundOverlay(forKey: key)
            let before = o?.canvas.drawing
            let after = before.map(change)
            StiftSpur.log("Schritt anwenden (\(undoing ? "zurueck" : "vor")): Schritt -\(step.removed.count) +\(step.added.count), Seite gebunden \(o != nil) geladen \(o?.loaded == true), Striche \(before?.strokes.count ?? -1) -> \(after?.strokes.count ?? -1), tatsaechlich geaendert \(before.map { InkUndoStep.between($0, after ?? $0) }.map { "-\($0.removed.count) +\($0.added.count)" } ?? "?"), Fokus \(StiftSpur.focus)")
        }
        if let overlay = boundOverlay(forKey: key), overlay.loaded {
            setDrawing(change(overlay.canvas.drawing), forKey: key)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let current = await self.store.drawing(forPageKey: key)
            // inzwischen geladen: dann zaehlt deren Stand
            if let overlay = self.boundOverlay(forKey: key), overlay.loaded {
                self.setDrawing(change(overlay.canvas.drawing), forKey: key)
            } else {
                self.setDrawing(change(current), forKey: key)
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
    func boundOverlay(forKey key: String) -> PageInkView? {
        allOverlays.first { $0.pageKey == key && $0.generation == shownLayoutVersion }
    }

    /// Messung (Tests): wie oft eine stehende Lasso-Auswahl beendet wurde, bevor das Programm die Zeichnung setzte
    private(set) var inkSelectionsEnded = 0

    /// Stehende Lasso-Auswahl von PencilKit beenden, BEVOR das Programm die Zeichnung setzt (Schritt zurueck / vor,
    /// neu geladener Stand, eigenes Lasso).
    ///
    /// Meldungen des Inhabers 21.11.2026 (iPad A16, Stift): "Den Zurueck-Pfeil kann man nach Lasso-Aenderungen nur
    /// einmal benutzen" und "mit dem Lasso Verschobenes geht nach ein paar Sekunden ab und zu von selber zurueck".
    /// Ablauf vom Geraet (`StiftSpur`): drei Mal verschoben, drei Mal "zurueck" - jeder Schritt wurde richtig auf die
    /// Zeichnung angewendet (-48 +48, -49 +49, -50 +50), aber der Fokus blieb die ganze Zeit bei `PKSelectionView`:
    /// Die Auswahl von PencilKit blieb stehen und zeigte weiter ihr eigenes Bild der Striche am verschobenen Platz,
    /// ueber der schon zurueckgesetzten Zeichnung. Zu sehen war darum nichts ("geht nicht"), und sobald die Auswahl
    /// spaeter verschwand (Tipp daneben, neues Einkreisen), sprang alles "von selbst" zurueck. Im Simulator endet die
    /// Auswahl beim Setzen der Zeichnung von allein, darum war es dort nicht nachzustellen.
    ///
    /// PencilKit hat keinen Aufruf "Auswahl aufheben"; ein Werkzeugwechsel hebt sie auf (wie beim Antippen des
    /// Stifts in der Leiste). Darum kurz ein anderes Werkzeug und sofort zurueck zum Lasso - solange die Zeichnung noch
    /// der Stand der Auswahl ist, aendert das Aufheben nichts an ihr. Meldungen von PencilKit dabei zaehlen nicht als
    /// Aenderung des Nutzers. Der Fokus geht zurueck an den Editor.
    private func endInkSelection(on overlay: PageInkView) {
        guard PencilTuning.endInkSelectionBeforeSettingDrawing, overlay.canvas.tool is PKLassoTool else { return }
        let canvas = overlay.canvas
        let focus = UIResponder.uf_current as? UIView
        let held = focus.map { $0 !== canvas && $0.isDescendant(of: canvas) } ?? false
        let lasso = canvas.tool
        let was = overlay.isApplyingDrawing
        overlay.isApplyingDrawing = true
        canvas.tool = PKInkingTool(.pen, color: .black, width: 1)
        canvas.tool = lasso
        overlay.isApplyingDrawing = was
        inkSelectionsEnded += 1
        // haelt die Auswahl den Fokus noch, gibt sie ihn ab; der Anker uebernimmt (Tastenbefehle, Rueckgaengig)
        if held, let f = UIResponder.uf_current as? UIView, f !== canvas, f.isDescendant(of: canvas) {
            if ownsToolPicker, pickerWanted, anchor.window != nil { anchor.becomeFirstResponder() } else { f.resignFirstResponder() }
        }
        StiftSpur.log("Lasso-Auswahl beendet vor dem Setzen: Fokus vorher \(focus.map { String(describing: type(of: $0)) } ?? "-"), nachher \(StiftSpur.focus)")
    }

    /// Zeichnung einer Seite aus dem Verlauf setzen: auf der gebundenen Canvas oder, ohne Overlay, nur im Store
    /// (ein spaeter angelegtes Overlay laedt dann diesen Stand). Ist die Seite nicht im Bild, springt die Ansicht
    /// hin, damit man sieht, was zurueckgenommen wurde.
    private func setDrawing(_ drawing: PKDrawing, forKey key: String) {
        store.canvasChanged(pageKey: key, drawing: drawing)
        if let overlay = boundOverlay(forKey: key) {
            if overlay.loaded {
                overlay.lastShrinkAllowed = CACurrentMediaTime()            // Rueckgaengig/Wiederholen: weniger Striche sind gewollt
                endInkSelection(on: overlay)
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

    /// Handschrift einer Seite ersetzen (Lasso fuer Handschrift und Objekte, Einfuegen, Zoom-Fenster) als EIN
    /// Rueckgaengig-Schritt von `before` nach `after`. Ohne gebundenes, geladenes Overlay nur im Store.
    func replaceInk(key: String, before: PKDrawing, after: PKDrawing) {
        guard canEdit else { return }
        StiftSpur.log("Handschrift ersetzt (eigenes Lasso, Einfuegen): \(before.strokes.count) -> \(after.strokes.count) Striche")
        if let overlay = boundOverlay(forKey: key), overlay.loaded {
            commitPendingUndo(overlay)
            endInkSelection(on: overlay)
            overlay.isApplyingDrawing = true
            overlay.canvas.drawing = after
            overlay.isApplyingDrawing = false
            overlay.undoBase = after
            overlay.undoPending = false
        }
        store.canvasChanged(pageKey: key, drawing: after)
        registerUndo(key: key, restore: before, redo: after)
    }

    /// Handschrift einer Seite (geladenes Overlay, sonst gespeicherter Stand)
    func inkDrawing(forKey key: String) async -> PKDrawing {
        if let overlay = boundOverlay(forKey: key), overlay.loaded { return overlay.canvas.drawing }
        return await store.drawing(forPageKey: key)
    }

    // MARK: PKCanvasViewDelegate

    private func overlay(of canvasView: PKCanvasView) -> PageInkView? {
        canvasView.superview?.superview as? PageInkView
    }

    /// Nur Tests: Ablauf der Meldungen von PencilKit mitschreiben (Fehlersuche "Strich geht verloren")
    var inkTrace: ((String) -> Void)?

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        inkTrace?("Zeichnung geaendert (\(canvasView.drawing.strokes.count) Striche\(overlay(of: canvasView)?.isApplyingDrawing == true ? ", vom Programm" : ""))")
        if StiftSpur.isOn {
            let o = overlay(of: canvasView)
            StiftSpur.log("Zeichnung geaendert: \(canvasView.drawing.strokes.count) Striche, Werkzeug \(type(of: canvasView.tool)), vomProgramm \(o?.isApplyingDrawing == true), liegtAuf \(o?.isDrawing == true), geladen \(o?.loaded == true), zurueck/vor laeuft \(documentUndo.isUndoing)/\(documentUndo.isRedoing), Fokus \(StiftSpur.focus)")
        }
        guard let overlay = overlay(of: canvasView), !overlay.isApplyingDrawing else { return }
        defer { reloadIfDeferred(overlay) }                         // der Strich ist da: ein verschobenes Laden kann laufen
        // Laden laeuft noch: `apply` uebernimmt die frueh gezeichneten Striche und sichert sie
        guard overlay.loaded else {
            // der gemeldete Strich ist nicht mehr "unterwegs" (das Laden wartet auf ihn, `apply`)
            if PencilTuning.liftBelongsToItsStroke, canvasView.tool is PKInkingTool {
                StiftZaehler.bump(.gemeldet)
                overlay.lifts.removeAll { !$0.isRecent }
                if !overlay.lifts.isEmpty { overlay.lifts.removeFirst() } else if overlay.isDrawing { overlay.reportedWhileDrawing = true }
            }
            return
        }
        // Welcher Strich wird hier gemeldet? Steht ein Absetzen aus, gehoert die Meldung zum aeltesten (`lifts`):
        // jetzt Form erkennen bzw. aus Rohpunkten bauen (gleicher Schritt) - aber nur, wenn kein weiterer Strich
        // unterwegs ist (laeuft schon oder ist abgesetzt und noch nicht gemeldet): Neu-Setzen der Zeichnung braeche
        // ihn ab oder verloere ihn. Dann bleibt der Strich, wie PencilKit ihn gezeichnet hat.
        if canvasView.tool is PKInkingTool {
            StiftZaehler.bump(.gemeldet)
            if !PencilTuning.liftBelongsToItsStroke {
                // Gegenprobe, wie bis 17.11.2026: ein gemerktes Absetzen, egal zu welchem Strich
                if !overlay.isDrawing, let lift = overlay.lifts.first {
                    overlay.lifts = []
                    if lift.isRecent, !documentUndo.isUndoing, !documentUndo.isRedoing { finishStroke(on: overlay, lift) }
                }
            } else {
                let stale = overlay.lifts.filter { !$0.isRecent }.count
                if stale > 0 {
                    StiftZaehler.bump(.ohneMeldung, by: stale)
                    overlay.lifts.removeAll { !$0.isRecent }
                }
                if !overlay.lifts.isEmpty {
                    let lift = overlay.lifts.removeFirst()
                    // nicht, wenn der Stift schon wieder aufliegt: der naechste Strich hat dann schon begonnen
                    if !overlay.isDrawing, overlay.lifts.isEmpty, !overlay.touchCouldDraw, !documentUndo.isUndoing, !documentUndo.isRedoing {
                        finishStroke(on: overlay, lift)
                    } else {
                        strokesLeftAsDrawn += 1
                        StiftZaehler.bump(.nichtNachbearbeitet)
                    }
                } else if overlay.isDrawing {
                    overlay.reportedWhileDrawing = true             // der laufende Strich selbst, kurz vor dem Absetzen
                }
            }
        } else {
            overlay.lastShrinkAllowed = CACurrentMediaTime()        // Radierer, Lasso: weniger Striche sind gewollt
            StiftZaehler.bump(.ohneStiftGeaendert)
            if overlay.isDrawing { StiftZaehler.bump(.ohneStiftGeaendertBeimAufliegen) }
        }
        // Stift liegt noch auf (Radierer, Lasso; beim Stift kommt die Meldung kurz vor dem Absetzen): einmal beim
        // Absetzen sichern statt bei jeder Zwischenmeldung (`PencilTuning.saveOnLift`)
        if overlay.isDrawing, PencilTuning.saveOnLift { overlay.storePending = true } else { saveCanvas(overlay) }
        guard canEdit else { return }                        // ohne Schreiben im Tarif: kein Rueckgaengig-Schritt
        guard !documentUndo.isUndoing, !documentUndo.isRedoing else { return }
        // waehrend der Stift aufliegt (Radierer, Lasso) erst beim Absetzen einen Schritt anlegen
        if overlay.isDrawing { overlay.undoPending = true } else { registerStep(overlay) }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // ein Absetzen, dessen Meldung noch aussteht, bleibt gemerkt (`PageInkView.lifts`)
        inkTrace?("Werkzeug an")
        if !(canvasView.tool is PKInkingTool) { StiftZaehler.bump(.ohneStiftAn) }
        StiftSpur.log("Werkzeug an: \(type(of: canvasView.tool)), \(canvasView.drawing.strokes.count) Striche")
        if !PencilTuning.liftBelongsToItsStroke { overlay(of: canvasView)?.lifts = [] }
        overlay(of: canvasView)?.reportedWhileDrawing = false
        overlay(of: canvasView)?.endTranslucentHole()            // der neue Strich muss ueberall zu sehen sein
        overlay(of: canvasView)?.isDrawing = true
        reclaimFocusForWriting()
    }

    /// PencilKit hat den Stand fertig gezeichnet: Deckbilder ueber ersetzten Strichen koennen weg
    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        overlay(of: canvasView)?.inkRendered()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let overlay = overlay(of: canvasView) else { return }
        inkTrace?("Werkzeug aus")
        if !(canvasView.tool is PKInkingTool) { StiftZaehler.bump(.ohneStiftAus) }
        StiftSpur.log("Werkzeug aus: \(type(of: canvasView.tool)), \(canvasView.drawing.strokes.count) Striche, Sichern offen \(overlay.storePending), Schritt offen \(overlay.undoPending)")
        overlay.isDrawing = false
        overlay.setRenderScale(currentRenderScale, screen: screenScale)     // ein Zoom waehrend des Strichs wird nachgeholt
        let lift = StrokeLift(samples: overlay.rawRecorder.take(), inking: canvasView.tool is PKInkingTool, ruler: canvasView.isRulerActive)
        // Form erkannt: `snapShape` sichert die ersetzte Zeichnung selbst (ein Mal statt Strich + Form)
        var snapped = false
        if lift.inking {
            StiftZaehler.bump(.abgesetzt)
            let expected = canvasView.drawing.strokes.count + (overlay.reportedWhileDrawing ? 0 : 1)
            if !PencilTuning.liftBelongsToItsStroke {
                // Gegenprobe, wie bis 17.11.2026 (nur auf geladenen Seiten)
                if overlay.loaded {
                    if overlay.undoPending { snapped = finishStroke(on: overlay, lift) } else { overlay.lifts = [lift] }
                }
            } else if overlay.reportedWhileDrawing {
                // DIESER Strich ist schon gemeldet. Steht noch die Meldung eines frueheren aus, bleibt er, wie er ist.
                if overlay.loaded, overlay.lifts.isEmpty, !overlay.touchCouldDraw { snapped = finishStroke(on: overlay, lift) } else { strokesLeftAsDrawn += 1 }
            } else {
                // Meldung kommt gleich. Auch auf einer Seite, die noch laedt: das Laden wartet dann auf den Strich.
                overlay.lifts.append(lift)
            }
            checkStrokeArrived(on: overlay, expected: expected)
        }
        overlay.reportedWhileDrawing = false
        if overlay.storePending, !snapped { saveCanvas(overlay) }
        overlay.storePending = false
        if overlay.loaded { commitPendingUndo(overlay) }
        if overlay.deferredReload {
            if PencilTuning.liftBelongsToItsStroke, overlay.hasOpenLift {
                // der eben abgesetzte Strich ist noch nicht gemeldet: erst danach neu laden (`reloadIfDeferred`)
                scheduleDeferredReload(overlay)
            } else {
                overlay.deferredReload = false
                loadContent(into: overlay, remote: true)
            }
        }
        if layoutWaitsForPencil, !live.values.contains(where: \.isDrawing) { showLayout() }
    }

    /// Zeichnung der Canvas an den Store (sichert sofort, `DocumentStore.canvasChanged`); zaehlt fuer die Messung
    private func saveCanvas(_ overlay: PageInkView) {
        overlay.storePending = false
        canvasSaves += 1
        store.canvasChanged(pageKey: overlay.pageKey, drawing: overlay.canvas.drawing)
    }

    /// Strich fertig (Stift abgesetzt UND Zeichnung gemeldet, in welcher Reihenfolge auch immer): Form erkennen,
    /// sonst Glaettung "Leicht"/"Aus" aus den Rohpunkten (nicht mit Lineal). Beides im selben Rueckgaengig-Schritt.
    /// - Returns: true, wenn eine Form erkannt (und schon gesichert) wurde
    @discardableResult
    func finishStroke(on overlay: PageInkView, _ lift: StrokeLift) -> Bool {
        guard lift.inking else { return false }
        // Zweite Sicherung: Die Messpunkte muessen zu dem Strich passen, der ersetzt wuerde (gleiche Stelle). Passen sie
        // nicht (PencilKit hat einen Strich verworfen oder anders gemeldet als erwartet), bleibt der Strich, wie er ist.
        if PencilTuning.liftBelongsToItsStroke, !lift.samples.isEmpty, let last = overlay.canvas.drawing.strokes.last,
           !RawStroke.fits(last, samples: lift.samples) {
            strokesLeftAsDrawn += 1
            StiftZaehler.bump(.nichtNachbearbeitet)
            return false
        }
        let hold = RawStroke.heldDuration(lift.samples, radius: ShapeRecognizer.holdRadius)
        if snapShape(on: overlay, endedAt: lift.endedAt, held: hold) != nil { return true }
        if !lift.ruler { rebuildFromRawPoints(on: overlay, samples: lift.samples, smoothing: PencilSmoothing.current) }
        return false
    }

    /// Messung: Striche, die nicht nachbearbeitet wurden, weil ein weiterer Strich unterwegs war oder die Messpunkte
    /// nicht zum Strich passten (sie bleiben, wie PencilKit sie gezeichnet hat)
    private(set) var strokesLeftAsDrawn = 0
    /// Messung: Laden einer Seite, das auf die Meldung eines abgesetzten Strichs gewartet hat
    private(set) var reloadsDeferredForLift = 0

    /// Ein Laden, das auf einen Strich gewartet hat, laeuft jetzt - wenn kein Strich mehr unterwegs ist
    private func reloadIfDeferred(_ overlay: PageInkView) {
        guard overlay.deferredReload, !overlay.isDrawing, !overlay.hasOpenLift, !overlay.touchCouldDraw else { return }
        // geladene Seite: erst in einer Schreibpause (`apply`); sonst spaeter noch einmal nachsehen
        if overlay.loaded, overlay.touchTracker.quiet < PencilTuning.reloadQuietSeconds {
            scheduleDeferredReload(overlay, counted: false)
            return
        }
        overlay.deferredReload = false
        loadContent(into: overlay, remote: true)
    }

    /// Sicherheitsnetz: Kommt die Meldung zu einem abgesetzten Strich nie (PencilKit hat ihn verworfen), laeuft das
    /// verschobene Laden, sobald das Absetzen nicht mehr frisch ist (`StrokeLift.isRecent`, 1 s)
    private func scheduleDeferredReload(_ overlay: PageInkView, counted: Bool = true) {
        if counted {
            reloadsDeferredForLift += 1
            StiftZaehler.bump(.neuLadenVerschoben)
        }
        guard !overlay.reloadCheckScheduled else { return }
        overlay.reloadCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            overlay.reloadCheckScheduled = false
            self.reloadIfDeferred(overlay)
        }
    }

    /// Pruefung fuer den Zaehler auf dem Geraet (`StiftZaehler`): 2 s nach dem Absetzen muessen mindestens `expected`
    /// Striche in der Zeichenflaeche liegen - ausser es wurde seitdem radiert, zurueckgenommen oder neu geladen.
    private func checkStrokeArrived(on overlay: PageInkView, expected: Int) {
        let lifted = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak overlay] in
            guard let overlay, overlay.window != nil, overlay.lastShrinkAllowed < lifted else { return }
            if overlay.canvas.drawing.strokes.count < expected { StiftZaehler.bump(.fehltNachAbsetzen) }
        }
    }

    /// Formerkennung "zeichnen und halten" (`ShapeRecognizer`): Der eben beendete Strich (genau einer seit dem letzten
    /// Rueckgaengig-Stand) wird durch die ideale Form ersetzt, wenn der Stift am Ende still stand. Der Tausch landet im
    /// selben Rueckgaengig-Schritt wie der Strich (`commitPendingUndo` folgt), das Speicherformat bleibt ein Strich.
    /// - Returns: die erkannte Form (fuer Tests), sonst nil
    @discardableResult
    func snapShape(on overlay: PageInkView, endedAt: Date, held: TimeInterval? = nil) -> ShapeRecognizer.Shape? {
        // Formen erkennt nur ein Stift-Werkzeug; der Textmarker nur die gerade Linie (`ShapeRecognizer.lineOnly`)
        guard canEdit, shapeSnapEnabled, ShapeRecognizer.snaps(overlay.canvas.tool) else { return nil }
        var drawing = overlay.canvas.drawing
        guard drawing.strokes.count == overlay.undoBase.strokes.count + 1, let stroke = drawing.strokes.last, stroke.mask == nil else { return nil }
        // Halten am Ende: Gibt es Rohpunkte, entscheiden NUR deren Zeitstempel (vom Stift selbst, `heldDuration`).
        // Der Weg ueber PencilKit (`heldStill` mit `endedAt`) misst das Absetzen erst, wenn der Editor davon erfaehrt:
        // War das iPad gerade beschaeftigt (volle Seite sichern, Abgleich), sah ein schnell abgesetzter Strich aus wie
        // gehalten und wurde ersetzt - jedes Ersetzen setzt die Zeichnung neu und kann den naechsten Strich kosten
        // (18.11.2026: Datensicherheit vor Formerkennung). Ohne Rohpunkte (Finger, Messung fehlt) wie bisher.
        let still = held.map { $0 >= ShapeRecognizer.holdDuration } ?? ShapeRecognizer.heldStill(stroke.path, endedAt: endedAt)
        ShapeLog.log.debug("Formerkennung: gehalten \(held ?? -1, privacy: .public) s, still \(still, privacy: .public)")
        guard still else { return nil }
        let points = stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
        guard let shape = ShapeRecognizer.recognize(points, lineOnly: ShapeRecognizer.lineOnly(stroke.ink)) else { return nil }
        inkTrace?(String(format: "Form %@ ersetzt (gehalten %.3f s)", shape.name, held ?? -1))
        let ideal = ShapeRecognizer.idealStroke(shape, like: stroke)
        drawing.strokes[drawing.strokes.count - 1] = ideal
        overlay.isApplyingDrawing = true
        overlay.replaceLastStroke(with: ideal)              // mit Deckbild: die Tinte fehlt in keinem Bild
        overlay.isApplyingDrawing = false
        overlay.storePending = false
        canvasSaves += 1
        store.canvasChanged(pageKey: overlay.pageKey, drawing: drawing)
        return shape
    }

    /// Formerkennung an (Standard); Schalter "Formen erkennen" in den Einstellungen (`ShapeSnapSetting`)
    var shapeSnapEnabled: Bool { ShapeSnapSetting.enabled }

    /// Glaettung "Leicht"/"Aus" (`PencilSmoothing`): der eben beendete Strich (genau einer seit dem letzten
    /// Rueckgaengig-Stand) wird aus den Rohpunkten des Stifts neu gebaut, im selben Rueckgaengig-Schritt; gesichert
    /// wird beim Absetzen wie sonst auch (`storePending`).
    /// - Returns: true, wenn der Strich ersetzt wurde
    @discardableResult
    func rebuildFromRawPoints(on overlay: PageInkView, samples: [RawPencilSample], smoothing: PencilSmoothing) -> Bool {
        // abgeschaltet: jedes Neu-Setzen nach einem Strich kann den naechsten Strich kosten (`PencilTuning`)
        guard PencilTuning.rebuildFromRawPointsAfterLift else { return false }
        guard canEdit, smoothing != .normal else { return false }
        let drawing = overlay.canvas.drawing
        guard drawing.strokes.count == overlay.undoBase.strokes.count + 1, let stroke = drawing.strokes.last,
              let rebuilt = RawStroke.rebuild(stroke, samples: samples, smoothing: smoothing) else { return false }
        overlay.isApplyingDrawing = true
        overlay.replaceLastStroke(with: rebuilt)            // mit Deckbild: die Tinte fehlt in keinem Bild
        overlay.isApplyingDrawing = false
        overlay.storePending = true
        rawRebuilds += 1
        return true
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
            registerPageInsertUndo(added)
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
        registerPageInsertUndo(change?.focusKey)
        return change?.focusKey
    }

    /// Seite (Standard: aktuelle) in den Papierkorb legen (`deletedPages`, wiederherstellbar). Die letzte Seite bleibt.
    /// - `undoable`: "Seite in den Papierkorb" als Schritt im gemeinsamen Verlauf (Rueckgaengig holt sie zurueck,
    ///   Wiederholen legt sie wieder hinein); die Verlaufsschritte "Seite einfuegen" rufen ohne.
    @discardableResult
    func trashPage(key: String? = nil, undoable: Bool = false) async -> Bool {
        guard writable else { return false }
        guard let editor = pageEditor, let key = key ?? currentPageKey, let layout = shownLayout,
              let i = layout.index(ofKey: key), layout.entries.count > 1 else { return false }
        if let v = boundOverlay(forKey: key), v.loaded { store.canvasChanged(pageKey: key, drawing: v.canvas.drawing) }
        pendingFocusKey = layout.key(at: i + 1) ?? layout.key(at: i - 1)
        let change = await editor.applyPageStructure { doc in PageOrder.trash(&doc, key: key) }
        // Verlauf der Seite verwerfen: er wuerde unsichtbar auf die geloeschte Seite wirken
        if change != nil { dropUndo(forKey: key) }
        finishPageChange(change)
        if undoable, change != nil { registerPageTrashUndo(key) }
        return change != nil
    }

    /// "Seite in den Papierkorb" merken (Seitenleiste): Rueckgaengig holt die Seite zurueck, Wiederholen legt sie
    /// wieder hinein; derselbe Verlauf wie Striche, Objekte und eingefuegte Seiten
    private func registerPageTrashUndo(_ key: String) {
        guard writable else { return }
        documentUndo.registerUndo(withTarget: pageUndoTarget) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.writable else { return }
                self.registerPageTrashRedo(key)
                Task { await self.restorePage(key: key) }
            }
        }
        documentUndo.setActionName("Seite in den Papierkorb")
    }

    private func registerPageTrashRedo(_ key: String) {
        documentUndo.registerUndo(withTarget: pageUndoTarget) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.writable else { return }
                self.registerPageTrashUndo(key)
                Task { await self.trashPage(key: key) }
            }
        }
        documentUndo.setActionName("Seite in den Papierkorb")
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

    // MARK: Seitenwerkzeuge (Editor-Schritt 5, P1-1/P1-2; Regeln in `PageOrder`, gleich wie im Web-Editor)

    /// Seitenoperation ueber den Store: vorher die Striche der betroffenen Seite einsammeln, danach neu aufbauen und
    /// die Seite zeigen, die die Operation nennt (`Change.focusKey`).
    @discardableResult
    private func changePages(flushing key: String?, _ op: @escaping (inout AnnotationDocument) -> PageOrder.Change?) async -> PageOrder.Change? {
        guard writable, let editor = pageEditor else { return nil }
        if let key, let v = boundOverlay(forKey: key), v.loaded { store.canvasChanged(pageKey: key, drawing: v.canvas.drawing) }
        var focus: String?
        let change = await editor.applyPageStructure { doc in
            let c = op(&doc)
            focus = c?.focusKey
            return c
        }
        pendingFocusKey = focus
        finishPageChange(change)
        return change
    }

    /// Seite kopieren (dahinter), danach die Kopie zeigen
    @discardableResult
    func duplicatePage(key: String? = nil) async -> Bool {
        guard let key = key ?? currentPageKey else { return false }
        let change = await changePages(flushing: key) { PageOrder.duplicate(&$0, key: key) }
        registerPageInsertUndo(change?.focusKey)
        return change != nil
    }

    /// Seite um `delta` Plaetze verschieben (-1 nach vorn, +1 nach hinten) bzw. an den Anfang/ans Ende
    @discardableResult
    func movePage(key: String? = nil, to target: PageTarget) async -> Bool {
        guard let key = key ?? currentPageKey, let layout = shownLayout, let i = layout.index(ofKey: key) else { return false }
        let to: Int
        switch target {
        case .forward: to = i - 1
        case .backward: to = i + 1
        case .first: to = 0
        case .last: to = layout.entries.count - 1
        }
        // Ziel ist der Platz der angezeigten Seite dort (in pageOrder koennen nicht angezeigte Eintraege dazwischen stehen)
        guard to != i, let neighbor = layout.key(at: to) else { return false }
        return await changePages(flushing: nil) { doc in
            guard let target = doc.pageOrder.firstIndex(where: { $0["key"]?.string == neighbor }) else { return nil }
            return PageOrder.move(&doc, key: key, to: target)
        } != nil
    }

    enum PageTarget { case forward, backward, first, last }

    /// Alle Notizen der Seite entfernen (Rueckgaengig der Canvas gilt dafuer nicht mehr)
    @discardableResult
    func clearPage(key: String? = nil) async -> Bool {
        guard let key = key ?? currentPageKey else { return false }
        let change = await changePages(flushing: key) { PageOrder.clear(&$0, key: key) }
        if change != nil { dropUndo(forKey: key) }
        return change != nil
    }

    /// Vorlage einer Leerseite wechseln
    @discardableResult
    func setTemplate(_ template: String, key: String? = nil) async -> Bool {
        guard let key = key ?? currentPageKey else { return false }
        return await changePages(flushing: nil) { PageOrder.setTemplate(&$0, key: key, template: template) } != nil
    }

    /// Format einer Leerseite aendern
    @discardableResult
    func setFormat(_ size: CGSize, key: String? = nil) async -> Bool {
        guard let key = key ?? currentPageKey else { return false }
        let w = Double(size.width), h = Double(size.height)
        return await changePages(flushing: nil) { PageOrder.setFormat(&$0, key: key, width: w, height: h) } != nil
    }

    /// Leerseite vor der Seite einfuegen (Groesse wie diese Seite ohne Drehung, sonst A4)
    @discardableResult
    func insertBlankPage(before key: String, template: String = "blank") async -> String? {
        let size = shownLayout?.index(ofKey: key).flatMap { shownLayout?.baseSize(at: $0) } ?? CGSize(width: 595, height: 842)
        let t = PaperTemplate.isKnown(template) ? template : "blank"
        let w = Double(size.width), h = Double(size.height)
        let added = await changePages(flushing: nil) { PageOrder.insertBlank(&$0, before: key, template: t, width: w, height: h) }?.focusKey
        registerPageInsertUndo(added)
        return added
    }

    /// Leerseite am Ende einfuegen
    @discardableResult
    func appendBlankPage(template: String = "blank") async -> String? {
        let size = shownLayout.flatMap { l in l.baseSize(at: l.entries.count - 1) } ?? CGSize(width: 595, height: 842)
        let t = PaperTemplate.isKnown(template) ? template : "blank"
        let w = Double(size.width), h = Double(size.height)
        let added = await changePages(flushing: nil) { PageOrder.insertBlank(&$0, after: nil, template: t, width: w, height: h) }?.focusKey
        registerPageInsertUndo(added)
        return added
    }

    // MARK: Rueckgaengig fuer eingefuegte Seiten (im selben Verlauf wie Striche und Objekte, also auch ueber die Leiste)

    /// "Seite eingefuegt" merken: Rueckgaengig legt sie in den Papierkorb (wie im Web wiederherstellbar), Wiederholen
    /// holt sie an ihren Platz zurueck. Der Gegenschritt wird im Handler sofort angemeldet (nach einem `await` zaehlte
    /// er als neuer Schritt).
    private func registerPageInsertUndo(_ key: String?) {
        guard let key, writable else { return }
        documentUndo.registerUndo(withTarget: pageUndoTarget) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.writable else { return }
                self.registerPageRestoreRedo(key)
                Task { await self.trashPage(key: key) }
            }
        }
        documentUndo.setActionName("Seite einfügen")
    }

    private func registerPageRestoreRedo(_ key: String) {
        documentUndo.registerUndo(withTarget: pageUndoTarget) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.writable else { return }
                self.registerPageInsertUndo(key)
                Task { await self.restorePage(key: key) }
            }
        }
        documentUndo.setActionName("Seite einfügen")
    }

    /// Seite zur Gliederung hinzufuegen
    @discardableResult
    func addOutline(title: String, key: String? = nil) async -> Bool {
        guard let key = key ?? currentPageKey else { return false }
        return await changePages(flushing: nil) { PageOrder.addOutline(&$0, key: key, title: title) } != nil
    }

    /// Gliederungspunkt entfernen
    @discardableResult
    func removeOutline(at position: Int) async -> Bool {
        await changePages(flushing: nil) { PageOrder.removeOutline(&$0, at: position) } != nil
    }

    /// Gliederung zum Anzeigen (Titel und Anzeige-Index der Seite; Seiten ausserhalb der Anzeige ohne Index)
    func outlineEntries() async -> [(title: String, key: String, index: Int?)] {
        guard let editor = pageEditor else { return [] }
        let doc = await editor.pageStructureDocument()
        return PageOrder.outline(doc).map { ($0.title, $0.key, shownLayout?.index(ofKey: $0.key)) }
    }

    /// Zahl der angezeigten Seiten (Gehe zu Seite)
    var pageCount: Int { shownLayout?.entries.count ?? 0 }

    /// Eintrag der Seite in `pageOrder` (Leerseite? Format?), fuer die Menues
    func pageEntry(key: String?) -> DisplayLayout.Entry? {
        guard let key, let i = shownLayout?.index(ofKey: key) else { return nil }
        return shownLayout?.entry(at: i)
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
        // aufgeschoben, weil die Ansicht noch scrollt: der Fokus gilt dann beim Nachholen
        defer { if !layoutWaitsForGesture { pendingFocusKey = nil } }
        guard let change else { return }
        let alreadyShown = shownLayoutVersion == store.layoutVersion
        showLayout()
        if alreadyShown, let key = change.focusKey, key != currentPageKey, let i = shownLayout?.index(ofKey: key) {
            goToPage(i)
        }
    }

    // MARK: Steuerung von aussen

    /// Fixiert (`freezeMode`): kein Seitenwechsel, die Seite verrutscht nicht (Seitenleiste, Suche, Gehe zu Seite)
    func goToPage(_ index: Int) {
        guard freezeMode == .off, let page = pdfView.document?.page(at: index) else { return }
        show(page: page)
    }

    // MARK: Reiter (Stelle merken, nie waehrend einer Geste wechseln)

    /// Liegt der Stift auf einer Seite (laufender Strich)?
    var pencilDown: Bool { live.values.contains(where: \.isDrawing) }

    /// Darf das Dokument jetzt gegen ein anderes getauscht werden? Nicht, solange der Stift schreibt oder der Finger
    /// scrollt, zoomt oder die Ansicht ausrollt (wie `showLayout`)
    var readyToLeave: Bool { !pencilDown && !scrollGestureActive }

    /// Wartet, bis Stift und Finger ruhen (hoechstens `timeout` Sekunden); true, wenn die Ansicht steht
    @discardableResult
    func waitUntilSettled(timeout: Double = 3) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !readyToLeave, Date() < end {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        // Stift lag bis zum Ende der Wartezeit auf: Zwischenstand trotzdem sichern (`PencilTuning.saveOnLift`)
        for v in allOverlays where v.storePending { saveCanvas(v) }
        for v in allOverlays where v.loaded { commitPendingUndo(v) }
        return readyToLeave
    }

    /// Stelle der Ansicht: Seite, Punkt oben links in Seitenkoordinaten, Zoom relativ zur eingepassten Breite
    func currentSpot() -> DocumentViewSpot? {
        guard let doc = pdfView.document, let dest = pdfView.currentDestination, let page = dest.page else { return nil }
        let i = doc.index(for: page)
        guard i >= 0, i < doc.pageCount else { return nil }
        func finite(_ v: CGFloat) -> Double { v.isFinite && abs(v) < 1e6 ? Double(v) : 0 }
        return DocumentViewSpot(pageKey: shownLayout?.key(at: i), pdfPage: store.entry(forPageIndex: i)?.pdfIndex,
                                x: finite(dest.point.x), y: finite(dest.point.y),
                                zoom: lastFit > 0 ? Double(pdfView.scaleFactor / lastFit) : 1)
    }

    /// Gemerkte Stelle wieder zeigen (Reiterwechsel); fixiert bleibt die Ansicht, wo sie ist
    func restore(_ s: DocumentViewSpot, zoom: Bool = true) {
        guard freezeMode == .off, let layout = shownLayout, let doc = pdfView.document else { return }
        let index = s.pageKey.flatMap { layout.index(ofKey: $0) }
            ?? s.pdfPage.flatMap { p in layout.entries.firstIndex { $0.pdfIndex == p } }
        guard let index, let page = doc.page(at: index) else { return }
        if zoom, lastFit > 0, s.zoom.isFinite, s.zoom > 0 {
            let scale = min(max(lastFit * CGFloat(s.zoom), pdfView.minScaleFactor), pdfView.maxScaleFactor)
            pdfView.scaleFactor = scale
            userZoomed = ZoomPolicy.isUserZoom(scale: scale, fitScale: lastFit)
        }
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: s.x, y: s.y)))
        if mixedFormatFactor > 1.001, !userZoomed { centerHorizontally() }
    }

    func show(_ selection: PDFSelection) {
        pdfView.highlightedSelections = [selection]
        guard freezeMode == .off else { return }
        pdfView.go(to: selection)
        centerHorizontally()
    }

    func undo() {
        if correction != nil { correctionUndo.undo(); return }      // Korrektur-Modus: nur die Korrektur
        StiftSpur.log("PFEIL ZURUECK: schreibbar \(writable), kannZurueck \(documentUndo.canUndo), kannVor \(documentUndo.canRedo), Gruppe \(documentUndo.groupingLevel), offene Schritte \(allOverlays.filter(\.undoPending).count), liegtAuf \(allOverlays.filter(\.isDrawing).count), Fokus \(StiftSpur.focus)")
        guard writable else { return }                      // ausgeblendet oder ohne Schreiben im Tarif: nur ansehen
        allOverlays.forEach(commitPendingUndo)
        documentUndo.undo()
        StiftSpur.log("Pfeil zurueck fertig: kannZurueck \(documentUndo.canUndo), kannVor \(documentUndo.canRedo), Gruppe \(documentUndo.groupingLevel)")
    }

    func redo() {
        if correction != nil { correctionUndo.redo(); return }
        StiftSpur.log("PFEIL VOR: schreibbar \(writable), kannZurueck \(documentUndo.canUndo), kannVor \(documentUndo.canRedo), Gruppe \(documentUndo.groupingLevel), Fokus \(StiftSpur.focus)")
        guard writable else { return }
        documentUndo.redo()
        StiftSpur.log("Pfeil vor fertig: kannZurueck \(documentUndo.canUndo), kannVor \(documentUndo.canRedo), Gruppe \(documentUndo.groupingLevel)")
    }

    func fitWidth() {
        guard lastFit > 0, freezeMode == .off else { return }
        userZoomed = false
        pdfView.scaleFactor = lastFit
    }

    /// Feste Leiste zeigen oder ausblenden (Name aus der Zeit von Apples Palette): nur der Editor, der sie fuehrt
    func showToolPicker(_ visible: Bool) {
        guard ownsToolPicker else { return }
        pickerWanted = visible
        publishToolbar()
        if visible { anchor.becomeFirstResponder() }
    }

    /// Stand der Leiste fuer `DocumentView`: sichtbar, wenn geschrieben werden darf (auch im Korrektur-Modus, dort nur
    /// Tinte); nicht beim Abpausen, nicht in der Praesentation, nicht ohne Plus (`pickerAllowed`)
    var toolbarMode: EditorToolbarMode {
        EditorToolbarMode(visible: ownsToolPicker && pickerWanted && pickerAllowed, inkOnly: correction != nil)
    }

    func publishToolbar() {
        guard ownsToolPicker else { return }
        onToolbarChange?(toolbarMode)
        updateFloatingPalette()
    }

    /// "Schwebend" gewaehlt und Werkzeuge erlaubt (wie die feste Leiste: Schreiben im Tarif, nicht beim Abpausen, nicht in
    /// der Praesentation); am Mac nie
    var floatingPaletteWanted: Bool {
        ownsToolPicker && !Self.isMac && toolbarPlacement == .floating && toolbarMode.visible
    }

    /// Apples Palette zeigen oder verbergen (Anker und Zeichenflaechen); ohne Plus erscheint sie nie, die Dokumentansicht
    /// zeigt dann den Hinweis mit Schloss
    func updateFloatingPalette() {
        guard ownsToolPicker, !Self.isMac else { return }
        let want = floatingPaletteWanted
        if want, floatingPalette == nil {
            let f = EditorFloatingPalette(tools: tools)
            f.onAskAI = { [weak self] in self?.askAIFromToolbar() }
            f.onHidden = { [weak self] in
                guard let self, self.floatingPaletteWanted else { return }
                self.restorePickerSoon()
            }
            floatingPalette = f
        }
        guard let f = floatingPalette else { return }
        if want {
            f.reflect()
            f.setVisible(true, for: [anchor] + allOverlays.map(\.canvas))
            f.updateAccessory(aiAvailable: aiAvailable)
            if view.window != nil, !anchor.isFirstResponder, !editorHoldsFocus, !hasPDFSelection,
               !Self.isTypingField(UIResponder.uf_current) {
                anchor.becomeFirstResponder()
            }
        } else {
            f.setVisible(false, for: [anchor] + allOverlays.map(\.canvas))
        }
        applyCanvasTool()
    }

    // MARK: Fokus bleibt beim Editor

    /// Die Leiste steht fest und braucht keinen Fokus. Tastenbefehle und Rueckgaengig ueber die Responder-Kette brauchen
    /// ihn aber beim Editor (Erstantwortgeber `anchor`, eine Zeichenflaeche oder ein Textfeld auf der Seite). Nimmt ihn
    /// ein anderes Element (Textfeld, Blatt, Menue), wartet der Editor auf das Ereignis, das das Hindernis beendet
    /// (`EditorPalette.Blocker`): Tastatur zu bzw. Textfeld fertig, Blatt hat den Bildschirm verlassen
    /// (`WindowExitSentinel`), Menuefenster verborgen, Fenster wieder vorn. Beim Markieren von PDF-Text bleibt der Fokus
    /// bei der PDF-Ansicht.
    /// Anker oder eine Zeichenflaeche des Editors (dort stand frueher auch Apples Palette). Textfelder auf der Seite und
    /// die Textauswahl von PDFKit zaehlen nicht: sie halten den Fokus nur voruebergehend (`EditorPalette.Blocker`).
    var editorHoldsFocus: Bool {
        if anchor.isFirstResponder { return true }
        // eine Zeichenflaeche oder ein Teil davon: die Lasso-Auswahl von PencilKit haelt den Fokus selbst (Kopieren,
        // Einfuegen, Loeschen erreichen sie nur so). Vorher zaehlte nur die Zeichenflaeche, und der Anker nahm der Auswahl
        // den Fokus, sobald sich die Tastatur oder ein Fenster meldete (Meldung 20.11.2026)
        guard let v = UIResponder.uf_current as? UIView, v.isDescendant(of: view) else { return false }
        var cur: UIView? = v
        while let c = cur {
            if c is PKCanvasView { return true }
            cur = c.superview
        }
        return false
    }

    /// Im naechsten Durchlauf zurueckholen (UIKit hat den Fokuswechsel dann abgeschlossen)
    func restorePickerSoon() {
        guard ownsToolPicker, pickerWanted else { return }
        DispatchQueue.main.async { [weak self] in self?.restorePicker() }
    }

    /// PDF-Text ist ausgewaehlt (Finger gedrueckt halten): der Text geht an die KI-Hilfe, die Auswahl muss stehen bleiben
    var hasPDFSelection: Bool { !(pdfView.currentSelection?.string ?? "").isEmpty }

    /// PDFKit haelt mit einer eigenen Ansicht den Fokus (beim Auswaehlen von Text, kurz nach dem Neuaufbau der Seiten);
    /// Zeichenflaechen und Textfelder unserer Objekte zaehlen nicht
    var pdfKitHoldsFocus: Bool {
        guard let v = UIResponder.uf_current as? UIView, v.isDescendant(of: pdfView) else { return false }
        return !(v is PKCanvasView) && !(v is UITextView) && !(v is UITextField)
    }

    var paletteBlocker: EditorPalette.Blocker {
        EditorPalette.blocker(wanted: ownsToolPicker && pickerWanted && pickerAllowed, inWindow: view.window != nil,
                              markup: objects.isActive && objects.tool == .markup,
                              pdfSelection: hasPDFSelection,
                              textInput: Self.isTypingField(UIResponder.uf_current),
                              presenting: blockingPresentation() != nil,
                              otherWindow: Self.otherWindowOpen(over: view.window))
    }

    /// true: der Fokus ist beim Editor (oder soll gerade nicht dorthin); false: er kommt mit dem passenden Ereignis zurueck
    @discardableResult
    func restorePicker() -> Bool {
        guard ownsToolPicker, pickerWanted, pickerAllowed, view.window != nil else { return true }
        if editorHoldsFocus { restoreFallbacks = 0; return true }
        switch paletteBlocker {
        case .notWanted, .markup:
            return true
        case .pdfSelection, .textInput, .otherWindow:
            // Auswahl aufgehoben, Tastatur/Textfeld fertig bzw. Menuefenster zu melden sich (Mitteilungen oben); den
            // Fokus hier zu nehmen loeschte die PDF-Auswahl, und der markierte Text kam nicht mehr in der KI-Hilfe an
            // (Geraetetest 03.11.2026)
            return false
        case .presentation:
            watchPresentation()
            return false
        case .none:
            // PDFKit hat den Fokus, aber (noch) keine Auswahl: ein langes Druecken auf Text ist vielleicht gerade im Gang;
            // zweimal kurz warten (dann steht die Auswahl und `.pdfSelection` wartet weiter), sonst den Fokus holen
            if pdfKitHoldsFocus, restoreFallbacks < 2 {
                restoreFallbacks += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restorePicker() }
                return false
            }
            anchor.becomeFirstResponder()
            if editorHoldsFocus { restoreFallbacks = 0; return true }
            // ohne erkennbares Hindernis nicht zurueck (z. B. ein Element gibt den Fokus nicht ab): hoechstens zwei
            // Ersatzversuche
            if restoreFallbacks < 2 {
                restoreFallbacks += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restorePicker() }
            }
            return false
        }
    }

    /// Blatt oder Hinweis, der ueber diesem Editor liegt (nicht eines, in dem der Editor selbst steht)
    func blockingPresentation() -> UIViewController? {
        var next = view.window?.rootViewController?.presentedViewController
        while let p = next {
            if !view.isDescendant(of: p.view) {
                return p.isBeingDismissed || p.view.window == nil ? nil : p
            }
            next = p.presentedViewController
        }
        return nil
    }

    /// Markierung in das Blatt setzen; verlaesst es den Bildschirm, kommt der Fokus zurueck
    private func watchPresentation() {
        guard presentationSentinel?.window == nil, let p = blockingPresentation(),
              let host = p.presentationController?.containerView ?? p.view else { return }
        let s = WindowExitSentinel()
        s.onLeave = { [weak self] in self?.restorePicker() }
        host.addSubview(s)
        presentationSentinel = s
    }

    /// Der Stift setzt auf der Seite auf, waehrend ein Eingabefeld ausserhalb des Editors den Fokus haelt (KI-Frage,
    /// Chat, Suche): der Nutzer schreibt wieder, das Feld gibt den Fokus ab (die Tastatur geht weg) und der Fokus kommt
    /// zum Editor zurueck (Meldung 11.11.2026, damals fuer Apples Palette). Waehrend des Tippens selbst nimmt der Editor
    /// den Fokus nie; ein Textobjekt auf der Seite behaelt ihn. Am Mac nichts erzwingen. In der geteilten Ansicht gibt
    /// das Feld den Fokus auch beim Schreiben im Dokument daneben ab; den Fokus holt dann der Editor, der die Leiste
    /// fuehrt (`textDidEndEditing`).
    func reclaimFocusForWriting() {
        guard !Self.isMac, pickerAllowed, let r = UIResponder.uf_current, Self.isTypingField(r) else { return }
        if let v = r as? UIView, Self.isInsideEditor(v) { return }
        guard r.resignFirstResponder() else { return }
        restorePickerSoon()
    }

    /// Eine Zeichenflaeche verlaesst die Anzeige (Scrollen, Neuaufbau nach Seite einfuegen): hatte sie den Fokus, geht
    /// er an den Anker (sonst ginge er ins Leere, Tastenbefehle und Rueckgaengig erreichten den Editor nicht)
    private func keepPaletteFocus(leaving overlay: PageInkView) {
        guard ownsToolPicker, pickerWanted,
              overlay.canvas.isFirstResponder || overlay.correctionView?.ink.isFirstResponder == true else { return }
        anchor.becomeFirstResponder()
    }

    /// Ein weiteres sichtbares Fenster ueber dem der App (Menue, Popover, Kontextmenue); Tastatur und Fenster von PencilKit
    /// selbst zaehlen nicht
    static func otherWindowOpen(over window: UIWindow?) -> Bool {
        guard let window, let scene = window.windowScene else { return false }
        return scene.windows.contains { w in
            guard w !== window, !w.isHidden, w.alpha > 0, w.windowLevel > window.windowLevel else { return false }
            let name = String(describing: type(of: w))
            return !name.contains("Keyboard") && !name.contains("TextEffects") && !name.contains("ToolPicker") && !name.contains("PK")
        }
    }
}

// MARK: - Werkzeuge der festen Leiste (Zeichenflaeche, Objektmodus, Farben, Apple Pencil)

extension PDFEditorController: UIPencilInteractionDelegate {
    /// Startargument `-UFPaletteProbe 1` (Xcode: Schema → Run → Arguments): eine Sekunde nach dem Erscheinen den Stand
    /// der Werkzeuge ins Protokoll (Konsole, jede Zeile mit "[Probe]"). Dasselbe liefert `EditorDeviceProbeTests`.
    /// Nur Debug-Builds (wie alle -UF-Startargumente); im Release gibt es keine Probe-Zeilen im Protokoll.
    func logPaletteProbeIfRequested() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "UFPaletteProbe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            for line in EditorPalette.describe(editor: self) { NSLog("[Probe] %@", line) }
        }
        #endif
    }

    /// Werkzeug fuer die Zeichenflaechen: das der Leiste; bei einem Objektwerkzeug das letzte der Zeichenflaeche (die
    /// nimmt dann keine Eingabe an)
    var canvasTool: PKTool {
        // "Schwebend": genau das Werkzeug der Palette (auch Apples weitere Stifte), solange es dort gewaehlt ist
        if floatingPaletteWanted, tools.tool.drawsOnCanvas, let t = floatingPalette?.appleTool, Self.canvasKnows(t) { return t }
        return tools.canvasTool
    }


    nonisolated static func canvasKnows(_ t: PKTool) -> Bool { t is PKInkingTool || t is PKEraserTool || t is PKLassoTool }

    /// Werkzeug und Lineal auf alle Zeichenflaechen (eigene Notizen und Korrektur) und die Schreiblupe
    func applyCanvasTool() {
        let tool = canvasTool
        let ruler = tools.ruler
        for v in allOverlays {
            v.canvas.tool = tool
            if v.canvas.isRulerActive != ruler { v.canvas.isRulerActive = ruler }
            if let ink = v.correctionView?.ink {
                ink.tool = tool
                if ink.isRulerActive != ruler { ink.isRulerActive = ruler }
            }
        }
        magnifier?.syncTool()
    }

    /// Meldung der Leiste (`EditorToolState.changes`):
    /// - Stift, Fineliner, Textmarker, Radierer, Lasso: Werkzeug aller Zeichenflaechen, Objektmodus aus.
    /// - Objektwerkzeug: Objektmodus mit diesem Werkzeug, Farbe und Staerke aus der Leiste (Text und Form anfangs in der
    ///   Farbe des Stifts). Wo Objekte nicht gehen (Korrektur-Modus, nur ansehen, ohne Plus), springt die Leiste zum
    ///   letzten Stift zurueck; "Bereich an KI" geht immer (schreibt nichts).
    /// - `initial`: beim Oeffnen steht die Leiste nie auf einem Objektwerkzeug.
    func toolsChanged(_ change: EditorToolState.Change, initial: Bool = false) {
        // Wahl aus Leiste, Tastatur oder Apple Pencil: die schwebende Palette zeigt sie (kam sie aus der Palette, nicht)
        if ownsToolPicker, let f = floatingPalette, !f.isApplying { f.reflect() }
        noteStyles()
        applyCanvasTool()
        guard change != .ruler else { return }
        let t = tools.tool
        if let object = t.objectTool {
            if initial && ownsToolPicker { tools.selectLastInk(); return }
            objectToolChosen(t, tool: object)
        } else {
            leavePaletteObjectTool()
        }
    }

    /// Farben und Staerken der Stifte fuer Objekte und "Text markieren" merken
    private func noteStyles() {
        if let pen = tools.inkingTool(tools.lastPen) { paletteSync.note(pen, itemID: tools.lastPen.rawValue) }
        if let marker = tools.inkingTool(.marker) { paletteSync.note(marker) }
    }

    private func objectToolChosen(_ t: EditorToolState.Tool, tool: ObjectEditing.Tool) {
        setPaletteObjectToolActive(true)
        guard ownsToolPicker else { return }                // andere Haelfte der geteilten Ansicht: nur nicht schreiben
        guard writable || tool == .area else {
            DispatchQueue.main.async { [weak self] in self?.tools.selectLastInk() }
            return
        }
        if t == .text || t == .shape, let id = t.paletteID {
            var style = tools.style(t)
            if let hex = paletteSync.adoptInkColor(item: id, current: style.hex) {
                style.hex = hex                             // Text und Formen in der Farbe, mit der man gerade schreibt
                tools.setStyle(style, for: t, silently: true)
            }
            objects.color = style.hex
        }
        if t == .shape { objects.lineWidth = Double(tools.style(.shape).width) }
        if !objects.isActive { objects.setActive(true) }
        if objects.tool != tool { objects.tool = tool }
        onObjectModeChange?(objects.isActive, objects.tool)
    }

    /// Ein Werkzeug der Zeichenflaeche ist gewaehlt: Objektmodus aus
    private func leavePaletteObjectTool() {
        setPaletteObjectToolActive(false)
        guard ownsToolPicker, objects.isActive else { return }
        objects.setActive(false)
        onObjectModeChange?(false, objects.tool)
    }

    private func setPaletteObjectToolActive(_ on: Bool) {
        guard paletteObjectToolActive != on else { return }
        paletteObjectToolActive = on
        if !ownsToolPicker { allOverlays.forEach(applyOwnNotes) }
    }

    /// Form- bzw. Auswahlart merken (die Leiste zeigt sie und waehlt sie beim naechsten Mal)
    private func rememberObjectChoice(_ t: ObjectEditing.Tool) {
        if EditorPalette.selectChoices.contains(t) { EditorPalette.selectTool = t }
        if EditorPalette.shapeChoices.contains(t) { EditorPalette.shapeTool = t }
    }

    /// Objektmodus von aussen (Menue "Bereich an KI …", Ausblenden der Notizen). Objekte nehmen dann Farbe und Staerke des
    /// zuletzt benutzten Stifts; die Leiste zeigt das Werkzeug.
    func setObjectMode(_ on: Bool) {
        if on {
            if !objects.isActive {
                objects.color = paletteSync.inkHex
                objects.lineWidth = paletteSync.shapeWidth
            }
            rememberObjectChoice(objects.tool)
            tools.select(EditorToolState.Tool.forObject(objects.tool))
        } else if tools.tool.objectTool != nil || objects.isActive {
            tools.selectLastInk()
            if objects.isActive { leavePaletteObjectTool() }
        }
    }

    /// Objektwerkzeug von aussen gewaehlt (z. B. "Bereich an KI" waehrend des Objektmodus)
    func setObjectTool(_ t: ObjectEditing.Tool) {
        rememberObjectChoice(t)
        tools.select(EditorToolState.Tool.forObject(t))
    }

    /// Der Editor hat das Objektwerkzeug selbst gewechselt (nach dem Anlegen eines Textes, nach dem Lasso): die Leiste
    /// zeigt es
    func objectToolChangedInternally(_ t: ObjectEditing.Tool) {
        rememberObjectChoice(t)
        if ownsToolPicker { tools.reflect(EditorToolState.Tool.forObject(t)) }
        onObjectModeChange?(objects.isActive, t)
    }

    /// "Fertig" in der Objektleiste, Esc: zurueck zum letzten Stift
    func finishObjectTools() {
        if tools.tool.objectTool != nil { tools.selectLastInk() }
        if objects.isActive { leavePaletteObjectTool() }
    }

    // MARK: Apple Pencil: Doppeltippen (Pencil 2, Pro) und Druecken (Pro)

    /// Nur der Editor, der die Leiste fuehrt (sonst wirkte ein Doppeltippen in der geteilten Ansicht zweimal); am Mac
    /// gibt es keinen Pencil
    func installPencilInteraction() {
        guard !Self.isMac else { return }
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        view.addInteraction(interaction)
    }

    /// iPadOS 17.0 bis 17.4
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        pencilGesture(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        pencilGesture(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        pencilGesture(UIPencilInteraction.preferredSqueezeAction)
    }

    /// Einstellung des Nutzers (iPadOS-Einstellungen → Apple Pencil): Radierer hin und zurueck, vorheriges Werkzeug oder
    /// Farbe und Staerke zeigen. Nur, solange die Leiste steht (Schreiben erlaubt).
    func pencilGesture(_ preferred: UIPencilPreferredAction) {
        guard toolbarMode.visible else { return }
        tools.perform(EditorToolState.pencilAction(preferred), inkOnly: correction != nil)
    }
}

// MARK: - "Als Karteikarte" im Bearbeitungsmenue (Schritt K) und markierter Text fuer die KI-Hilfe

extension PDFEditorController {
    /// "KI fragen" in der festen Leiste (frueher am Rand von Apples Palette, Schritt F; nur mit verbundener KI): die
    /// KI-Hilfe oeffnen (ueber die Bruecke in SwiftUI); markierter PDF-Text geht als Anhang mit
    func askAIFromToolbar() { onAskAI?(selectionAttachment()) }

    /// Markierter PDF-Text mit seiner PDF-Seite als Anhang fuer die KI-Hilfe; nil ohne Auswahl
    func selectionAttachment() -> TutorAttachment? {
        guard let sel = pdfView.currentSelection, let text = Self.tutorText(sel.string) else { return nil }
        var page: Int?
        if let p = sel.pages.first, let doc = pdfView.document { page = store.entry(forPageIndex: doc.index(for: p))?.pdfIndex }
        return TutorAttachment(kind: .selection, text: text, page: page)
    }

    /// "In KI-Hilfe einfügen" angetippt: Auswahl als Anhang in die KI-Hilfe
    func tutorFromSelection() {
        guard let a = selectionAttachment() else { return }
        onAskAI?(a)
    }

    static let tutorTitle = "In KI-Hilfe einfügen"

    /// Text fuer die KI: ohne Leerraum aussen, hoechstens `TutorAttachment.maxText` Zeichen; nil, wenn leer
    nonisolated static func tutorText(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(TutorAttachment.maxText))
    }

    /// Menuepunkt "In KI-Hilfe einfügen" zum markierten Text; nil ohne Auswahl oder ohne Empfaenger
    func tutorAction() -> UIAction? {
        guard Self.tutorText(pdfView.currentSelection?.string) != nil, onAskAI != nil else { return nil }
        return UIAction(title: Self.tutorTitle, image: UIImage(systemName: "sparkles")) { [weak self] _ in self?.tutorFromSelection() }
    }

    /// Eintraege fuer das Bearbeitungsmenue der Textauswahl, in dieser Reihenfolge
    func selectionMenuActions() -> [UIAction] { [tutorAction(), flashcardAction()].compactMap { $0 } }

    /// Bearbeitungsmenue der PDF-Textauswahl (langes Druecken auf Text): hinter Kopieren und Nachschlagen stehen
    /// "In KI-Hilfe einfügen" und "Als Karteikarte" (nur mit Auswahl; Karteikarte nicht in alten Fassungen)
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let actions = selectionMenuActions()
        guard builder.system == .context, !actions.isEmpty else { return }
        let menu = UIMenu(options: .displayInline, children: actions)
        if builder.menu(for: .standardEdit) != nil { builder.insertSibling(menu, afterMenu: .standardEdit) }
        else if builder.menu(for: .lookup) != nil { builder.insertSibling(menu, afterMenu: .lookup) }
        else { builder.insertChild(menu, atEndOfMenu: .root) }
    }

    /// Menuepunkt "Als Karteikarte" zum markierten Text; nil ohne Auswahl, ohne Empfaenger oder in alten Fassungen
    func flashcardAction() -> UIAction? {
        guard Self.flashcardText(pdfView.currentSelection?.string) != nil, onFlashcardFromSelection != nil, !store.isOldVersion else { return nil }
        return UIAction(title: Self.flashcardTitle, image: UIImage(systemName: "rectangle.on.rectangle")) { [weak self] _ in
            self?.flashcardFromSelection()
        }
    }

    /// "Als Karteikarte" angetippt: den markierten Text weitergeben (Blatt "Karte anlegen")
    func flashcardFromSelection() {
        guard let text = Self.flashcardText(pdfView.currentSelection?.string) else { return }
        onFlashcardFromSelection?(text)
    }

    static let flashcardTitle = "Als Karteikarte"

    /// Vorderseite aus der Auswahl: ohne Leerraum aussen, Zeilenumbrueche der PDF zu Leerzeichen; nil, wenn leer
    nonisolated static func flashcardText(_ selection: String?) -> String? {
        let t = (selection ?? "").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - "Bereich an KI" (05.11.2026)

/// Text oder Ausschnitt fuer die KI-Hilfe: markierter PDF-Text, ein eingekreister Bereich der Seite als Bild (PDF, Tinte,
/// Textfelder) mit erkanntem Text, oder die ganze Seite. Steht in der KI-Hilfe als Anhang im Eingabefeld (entfernbar)
/// und geht beim Senden als `selection` (Text) und `image` (JPEG, Base64) mit.
struct TutorAttachment: Equatable, Identifiable {
    enum Kind: String { case selection, area, page }
    let id = UUID()
    let kind: Kind
    var text: String
    /// PDF-Seite (1-basiert); nil auf eingefuegten Seiten
    let page: Int?
    /// Ausschnitt als JPEG (Bereich, ganze Seite)
    var image: Data? = nil

    /// so viel Text geht hoechstens mit (der Prompt kuerzt die Markierung ebenso)
    static let maxText = 4000

    /// Ueberschrift im Eingabefeld: "Markierter Text · Seite 3", "Bereich · Seite 3"
    var title: String {
        let what: String
        switch kind {
        case .selection: what = "Markierter Text"
        case .area: what = "Bereich"
        case .page: what = "Ganze Seite"
        }
        return what + (page.map { " · Seite \($0)" } ?? "")
    }
}

extension PDFEditorController {
    /// Laengste Bildseite des Ausschnitts in Pixeln (genug fuer die KI, klein genug fuer die Anfrage)
    static let areaMaxPixels: CGFloat = 1600
    /// Hoechstens so stark vergroessern (kleine Bereiche bleiben scharf)
    static let areaMaxScale: CGFloat = 4
    static let areaJPEGQuality: CGFloat = 0.8

    /// Faktor Seitenpunkte -> Pixel: mindestens 2 (wenn die Grenze es zulaesst), hoechstens `areaMaxScale`, laengste
    /// Seite hoechstens `areaMaxPixels`
    nonisolated static func areaScale(_ size: CGSize) -> CGFloat {
        let long = max(size.width, size.height, 1)
        return min(areaMaxScale, areaMaxPixels / long)
    }

    /// Bereich einer angezeigten Seite als Bild: Original-PDF bzw. Leerseite, Vorlage, Notizobjekte (Handschrift,
    /// Formen, Textfelder) wie im Export (`PageRenderer`), weisser Grund. `rect` in Punkten der angezeigten (gedrehten)
    /// Seite, Ursprung oben links, wird auf die Seite begrenzt.
    static func renderArea(page: PDFPage, entry: DisplayLayout.Entry, objects: [JSONValue], rect: CGRect) -> UIImage? {
        let full = CGRect(origin: .zero, size: PageRenderer.size(of: page))
        let area = rect.standardized.intersection(full)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let scale = areaScale(area.size)
        let px = CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: px, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: px))
            let cg = ctx.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -area.minX, y: -area.minY)
            cg.clip(to: area)
            PageRenderer.draw(page: page, entry: entry, objects: objects, images: [:], in: cg)
        }
    }

    /// Text im Bild mit Vision (Deutsch, Englisch; auch Handschrift), Zeilen von oben nach unten
    nonisolated static func recognizeText(_ image: CGImage) async -> String {
        let box = AreaImageBox(image)
        return await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = VisionPageOCR.languages
            do { try VNImageRequestHandler(cgImage: box.image, options: [:]).perform([request]) } catch { return "" }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    /// Ausschnitt einer Seite als Anhang: Bild (JPEG) und erkannter Text; offene Striche werden vorher gesichert
    func captureArea(pageIndex: Int, rect: CGRect?, kind: TutorAttachment.Kind = .area) async -> TutorAttachment? {
        guard let layout = shownLayout ?? store.layout, let page = layout.pdf.page(at: pageIndex),
              let entry = layout.entry(at: pageIndex) else { return nil }
        let doc = await store.pageStructureDocument()               // wartet auf ausstehende Striche
        let objects = doc.objects(page: entry.key)
        let r = rect ?? CGRect(origin: .zero, size: PageRenderer.size(of: page))
        guard let image = Self.renderArea(page: page, entry: entry, objects: objects, rect: r), let cg = image.cgImage,
              let jpeg = image.jpegData(compressionQuality: Self.areaJPEGQuality) else { return nil }
        let text = await Self.recognizeText(cg)
        return TutorAttachment(kind: kind, text: String(text.prefix(TutorAttachment.maxText)), page: entry.pdfIndex, image: jpeg)
    }

    /// "Bereich an KI": Rahmen bzw. Schleife auf einer Seite losgelassen -> Ausschnitt in die KI-Hilfe
    func sendArea(pageIndex: Int, rect: CGRect) {
        Task {
            guard let a = await captureArea(pageIndex: pageIndex, rect: rect) else { return }
            onAskAI?(a)
        }
    }

    /// "Bereich an KI" aus dem Menue (auch ohne Leiste, auch ohne Schreiben im Tarif): Werkzeug waehlen
    func startAreaCapture() {
        if objects.isActive { setObjectTool(.area); return }
        objects.tool = .area
        setObjectMode(true)
    }

    /// "Ganze Seite an KI" (auch fuer VoiceOver und Schaltersteuerung statt Einkreisen): die angezeigte Seite
    func sendVisiblePage() {
        let i = currentPageIndex
        Task {
            guard let a = await captureArea(pageIndex: i, rect: nil, kind: .page) else { return }
            onAskAI?(a)
        }
    }
}

private struct AreaImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

extension PDFEditorController {
    /// Ein Feld, in das gerade getippt wird (Tastatur): Textfeld, bearbeitbare Textansicht (auch unser Textobjekt) oder
    /// sonstige Texteingabe ausserhalb der PDF-Ansicht. Die Textauswahl von PDFKit zaehlt nicht: dort kommt keine
    /// Tastatur, also auch kein `keyboardDidHide`, und der Fokus darf sofort zurueck.
    static func isTypingField(_ r: UIResponder?) -> Bool {
        if let t = r as? UITextView { return t.isEditable }
        if r is UITextField { return true }
        guard r is UIKeyInput else { return false }                 // auch UITextInput
        if let v = r as? UIView, isInsideEditor(v) { return false }
        return true
    }

    /// Ansicht eines Editors: eine Zeichenflaeche oder etwas in einer PDF-Ansicht
    static func isInsideEditor(_ v: UIView) -> Bool {
        var cur: UIView? = v
        while let c = cur {
            if c is PKCanvasView || c is PDFView { return true }
            cur = c.superview
        }
        return false
    }
}

extension UIResponder {
    private static weak var ufFound: UIResponder?

    /// Aktueller Erstantwortgeber der App (nil, wenn keiner)
    static var uf_current: UIResponder? {
        ufFound = nil
        UIApplication.shared.sendAction(#selector(uf_capture), to: nil, from: nil, for: nil)
        return ufFound
    }

    @objc private func uf_capture() { UIResponder.ufFound = self }
}

extension UndoManager {
    /// Eigener Rueckgaengig-Schritt (Fehlerbericht des Inhabers 13.11.2026, Build 37/38: "Rueckgaengig holt frueher
    /// geloeschte Striche zurueck"). Mit `groupsByEvent` ist alles, was in EINEM Durchlauf der Hauptschleife
    /// angemeldet wird, ein Schritt. War das iPad kurz beschaeftigt (volle Seite sichern, Abgleich), arbeitet iOS die
    /// gestauten Beruehrungen in einem Durchlauf ab: Radieren und der naechste Strich wurden ein Schritt, Rueckgaengig
    /// nahm den Strich weg und holte die radierten Striche zurueck. Hier wird die offene Gruppe geschlossen und eine
    /// neue begonnen; die Hauptschleife schliesst sie wie sonst. Nicht waehrend Rueckgaengig/Wiederholen (dort gehoert
    /// der Gegenschritt in die laufende Gruppe). `groupsByEvent` bleibt an: Textfelder melden ihre Schritte ueber
    /// denselben Verlauf an und braeuchten sonst eigene Gruppen (`UndoStrokesAppTests`).
    func beginSeparateStep() {
        guard groupsByEvent, groupingLevel == 1, !isUndoing, !isRedoing else { return }
        endUndoGrouping()
        beginUndoGrouping()
    }
}

/// Sieht jede Beruehrung einer Zeichenflaeche in dem Moment, in dem sie aufsetzt - frueher als PencilKit einen Strich
/// meldet. Erkennt nie etwas, haelt keine Beruehrung zurueck und laesst sich nicht verdraengen (wie
/// `RawPencilRecorder`). Gezaehlt werden nur Beruehrungen, die noch aufliegen.
final class InkTouchTracker: UIGestureRecognizer {
    private var touches: Set<UITouch> = []
    private var lastEnded: CFTimeInterval = 0
    /// Alle Beruehrungen sind zu Ende
    var onAllEnded: (() -> Void)?
    /// Seit so vielen Sekunden liegt nichts mehr auf (0, solange etwas aufliegt)
    var quiet: CFTimeInterval { down.isEmpty ? CACurrentMediaTime() - lastEnded : 0 }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
    }

    convenience init() { self.init(target: nil, action: nil) }

    private var down: [UITouch] { touches.filter { $0.phase != .ended && $0.phase != .cancelled } }
    /// Stifte, die gerade aufliegen
    var pencilsDown: Int { down.filter { $0.type == .pencil }.count }
    /// Finger (und Zeiger), die gerade aufliegen
    var othersDown: Int { down.filter { $0.type != .pencil }.count }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches.formUnion(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    private func finish(_ ended: Set<UITouch>) {
        touches.subtract(ended)
        lastEnded = CACurrentMediaTime()
        guard touches.isEmpty else { return }
        state = .failed
        onAllEnded?()
    }

    override func reset() {
        super.reset()
        touches = []
    }
}

/// Stift abgesetzt: Rohpunkte, Werkzeug und Lineal in diesem Moment
struct StrokeLift {
    let samples: [RawPencilSample]
    let inking: Bool
    let ruler: Bool
    let endedAt = Date()
    private let uptime = CACurrentMediaTime()       // keine Startzeit-API mit Begruendungspflicht (PrivacyInfo)

    init(samples: [RawPencilSample], inking: Bool, ruler: Bool) {
        self.samples = samples
        self.inking = inking
        self.ruler = ruler
    }

    /// Die Meldung "Zeichnung geaendert" gehoert noch zu diesem Absetzen
    var isRecent: Bool { CACurrentMediaTime() - uptime < 1 }
}

/// Protokoll der Formerkennung (Konsole am Mac: Kategorie "Formerkennung")
enum ShapeLog {
    static let log = Logger(subsystem: "app.studinow.ipad", category: "Formerkennung")
}
