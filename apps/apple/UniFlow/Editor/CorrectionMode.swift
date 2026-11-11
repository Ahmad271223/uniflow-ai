import PDFKit
import PencilKit
import SwiftUI
import UIKit
import UniFlowCore

// Korrektur-Modus (03.11.2026, Wunsch des Inhabers): Auf einer fremden, geteilten Loesung markieren (Tinte, Marker)
// und Randnotizen an eine Stelle setzen, dann als Korrekturvorschlag an den Ersteller schicken. Die Ziel-Loesung liegt
// als fremde Ebene (nur Anzeige) ueber der eigenen PDF; die eigenen Notizen sind in diesem Modus ausgeblendet und nur
// lesbar (`ownNotesVisible = false` -> `store.ownNotesReadOnly`), die Korrektur hat je Seite eine eigene Zeichenflaeche
// (`CorrectionPageView`), die nie in den DocumentStore schreibt. Der Entwurf liegt lokal
// (`CommunityCorrectionDraftStore`), bis er gesendet oder verworfen ist.
//
// Anzeige beim Ersteller: eine empfangene Korrektur liegt als eigene Ebene in Warnfarbe ueber seinen Notizen, die
// Randnotizen als Stecknadeln (`PDFEditorController.shownCorrection`).

/// Seite, auf der korrigiert wird: PDF-Seite (1-basiert), CropBox ohne Drehung, angezeigte Drehung
struct CorrectionPageInfo: Equatable {
    let pdfIndex: Int
    let width: Double
    let height: Double
    /// Drehung der angezeigten Seite (`/Rotate` + eigene Drehung)
    let rotation: Int

    var displaySize: CGSize {
        let s = SolutionGeometry.displaySize(width: width, height: height, rotation: rotation)
        return CGSize(width: s.width, height: s.height)
    }

    /// Koordinaten einer Seite mit Drehung `from` -> angezeigte Seite
    func mapping(from: Int) -> CGAffineTransform {
        let t = SolutionGeometry.transform(width: width, height: height, from: from, to: rotation)
        return CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
    }

    /// Randnotiz (0...1 in der Drehung von `page`) -> Punkt der angezeigten Seite
    func point(_ note: CommunityCorrection.Note, on page: CommunityCorrection.Page) -> CGPoint {
        let src = SolutionGeometry.displaySize(width: page.width, height: page.height, rotation: page.rotation)
        return CGPoint(x: note.x * src.width, y: note.y * src.height).applying(mapping(from: page.rotation))
    }

    /// Punkt der angezeigten Seite -> 0...1
    func normalized(_ p: CGPoint) -> CGPoint {
        let s = displaySize
        return CGPoint(x: min(1, max(0, p.x / max(1, s.width))), y: min(1, max(0, p.y / max(1, s.height))))
    }
}

/// Ereignis einer Randnotiz fuer die Oberflaeche
enum CorrectionNoteEvent: Equatable {
    /// Stelle angetippt (Randnotiz setzen): Seite und Stelle 0...1
    case place(CorrectionPageInfo, x: Double, y: Double)
    /// Stecknadel angetippt
    case open(noteID: String)
}

// MARK: - Sitzung

/// Laufende Korrektur einer fremden Loesung: Entwurf, Seitenwechsel, Senden und Verwerfen. Schreibt nie in die eigenen
/// Notizen; jede Aenderung landet (entprellt) im lokalen Entwurf.
@MainActor
final class CorrectionSession: ObservableObject, Identifiable {
    let target: ForeignSolutionLayer
    let drafts: CommunityCorrectionDraftStore
    @Published private(set) var draft: CommunityCorrection
    /// Tippen setzt eine Randnotiz (statt zu zeichnen)
    @Published var placingNote = false { didSet { if placingNote != oldValue { onModeChange?() } } }
    @Published private(set) var sending = false

    /// Editor: Stecknadeln einer Seite neu zeigen (PDF-Seite)
    var onNotesChange: ((Int) -> Void)?
    /// Editor: Modus (Zeichnen / Randnotiz) gewechselt
    var onModeChange: (() -> Void)?
    private var saveTask: Task<Void, Never>?

    var id: String { target.id }

    /// Entwuerfe im Container (neben "Lösungen anderer"), nur auf dem Geraet
    nonisolated static var defaultDrafts: CommunityCorrectionDraftStore {
        CommunityCorrectionDraftStore(directory: SolutionSharing.library.root.appendingPathComponent("correction-drafts", isDirectory: true))
    }

    init(target: ForeignSolutionLayer, drafts: CommunityCorrectionDraftStore = CorrectionSession.defaultDrafts) {
        self.target = target
        self.drafts = drafts
        draft = drafts.load(solutionID: target.id) ?? CommunityCorrection(targetSolutionID: target.id, pseudonym: "")
    }

    /// Es gibt etwas zu schicken
    var canSend: Bool { !draft.isEmpty && !sending }
    /// Kurzbeschreibung fuer die Leiste ("3 Markierungen · 1 Randnotiz")
    var summary: String {
        let s = draft.strokeCount, n = draft.noteCount
        return "\(s) \(s == 1 ? "Markierung" : "Markierungen") · \(n) \(n == 1 ? "Randnotiz" : "Randnotizen")"
    }

    func note(id: String) -> CommunityCorrection.Note? {
        draft.pages.lazy.flatMap(\.notes).first { $0.id == id }
    }

    /// Seite im Entwurf anlegen bzw. auf die angezeigte Drehung bringen (Notizen umgerechnet; Striche setzt `setInk`
    /// aus der Zeichenflaeche, die sie schon in der angezeigten Drehung hat)
    private func update(_ info: CorrectionPageInfo, _ change: (inout CommunityCorrection.Page) -> Void) {
        var pages = draft.pages
        let i = pages.firstIndex { $0.pdfIndex == info.pdfIndex }
        var p = i.map { pages[$0] } ?? CommunityCorrection.Page(pdfIndex: info.pdfIndex, width: info.width, height: info.height,
                                                               rotation: info.rotation)
        if p.rotation != info.rotation {
            let old = p
            p.notes = old.notes.map { n in
                let q = info.normalized(info.point(n, on: old))
                return CommunityCorrection.Note(id: n.id, x: q.x, y: q.y, text: n.text)
            }
            p.rotation = info.rotation
        }
        change(&p)
        if let i { pages[i] = p } else { pages.append(p) }
        pages.removeAll(where: \.isEmpty)
        draft.pages = pages.sorted { $0.pdfIndex < $1.pdfIndex }
        scheduleSave()
    }

    /// Striche einer Seite (alle, in der angezeigten Drehung) uebernehmen
    func setInk(_ strokes: [JSONValue], on info: CorrectionPageInfo) {
        update(info) { $0.strokes = strokes }
    }

    @discardableResult
    func addNote(x: Double, y: Double, text: String, on info: CorrectionPageInfo) -> CommunityCorrection.Note? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let note = CommunityCorrection.Note(x: min(1, max(0, x)), y: min(1, max(0, y)), text: String(t.unicodeScalars.prefix(CommunityCorrections.maxText)))
        update(info) { $0.notes.append(note) }
        onNotesChange?(info.pdfIndex)
        return note
    }

    func updateNote(id: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { removeNote(id: id); return }
        guard let pi = draft.pages.firstIndex(where: { $0.notes.contains { $0.id == id } }),
              let ni = draft.pages[pi].notes.firstIndex(where: { $0.id == id }) else { return }
        draft.pages[pi].notes[ni].text = String(t.unicodeScalars.prefix(CommunityCorrections.maxText))
        onNotesChange?(draft.pages[pi].pdfIndex)
        scheduleSave()
    }

    func removeNote(id: String) {
        guard let pi = draft.pages.firstIndex(where: { $0.notes.contains { $0.id == id } }) else { return }
        let index = draft.pages[pi].pdfIndex
        draft.pages[pi].notes.removeAll { $0.id == id }
        draft.pages.removeAll(where: \.isEmpty)
        onNotesChange?(index)
        scheduleSave()
    }

    /// Begleittext an den Ersteller
    func setMessage(_ text: String) {
        draft.note = String(text.unicodeScalars.prefix(CommunityCorrections.maxText))
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Entwurf sofort sichern (vor dem Senden, beim Verlassen)
    func saveNow() {
        saveTask?.cancel()
        try? drafts.save(draft)
    }

    /// Entwurf verwerfen (lokal geloescht; nichts wurde geschickt)
    func discard() {
        saveTask?.cancel()
        try? drafts.remove(solutionID: target.id)
        draft = CommunityCorrection(targetSolutionID: target.id, pseudonym: "")
    }

    /// An den Ersteller schicken; danach ist der Entwurf weg
    func send(service: CommunityService) async throws -> CommunityCorrection {
        saveNow()
        sending = true
        defer { sending = false }
        let sent = try await service.sendCorrection(draft)
        try? drafts.remove(solutionID: target.id)
        return sent
    }
}

// MARK: - Ebene einer Seite

/// Korrektur auf einer Seite: Zeichenflaeche (bearbeitbar im Korrektur-Modus, sonst nur Anzeige in Warnfarbe) und
/// Randnotizen als Stecknadeln. Liegt im Overlay ueber den eigenen Notizen; ohne Eingabe ausser auf den Nadeln, wenn
/// sie nur anzeigt.
final class CorrectionPageView: UIView, PKCanvasViewDelegate {
    let info: CorrectionPageInfo
    let editable: Bool
    let ink = PKCanvasView()
    let pins = UIView()
    private let tint: UIColor?
    private var tap: UITapGestureRecognizer?
    private var isApplying = false
    private var pinScale: CGFloat = 1

    var onInkChange: ((CorrectionPageView) -> Void)?
    /// Stelle angetippt (nur im Modus "Randnotiz"), Punkt 0...1
    var onPlace: ((CorrectionPageView, CGPoint) -> Void)?
    var onNoteTap: ((String) -> Void)?

    static let pinSize: CGFloat = 26

    init(info: CorrectionPageInfo, pageSize: CGSize, editable: Bool, tint: UIColor? = nil) {
        self.info = info
        self.editable = editable
        self.tint = tint
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        backgroundColor = .clear
        isOpaque = false
        overrideUserInterfaceStyle = .light
        ink.frame = bounds
        ink.backgroundColor = .clear
        ink.isOpaque = false
        ink.overrideUserInterfaceStyle = .light
        ink.isScrollEnabled = false
        ink.minimumZoomScale = 1
        ink.maximumZoomScale = 1
        ink.contentInsetAdjustmentBehavior = .never
        ink.showsVerticalScrollIndicator = false
        ink.showsHorizontalScrollIndicator = false
        ink.isUserInteractionEnabled = editable
        ink.drawingGestureRecognizer.isEnabled = editable
        ink.delegate = self
        ink.accessibilityLabel = editable ? "Korrektur zeichnen" : "Korrekturhinweis"
        addSubview(ink)
        pins.frame = bounds
        pins.backgroundColor = .clear
        addSubview(pins)
        if editable {
            let t = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            t.isEnabled = false
            addGestureRecognizer(t)
            tap = t
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    /// Nur ansehen: Eingabe nur auf den Stecknadeln, alles andere geht an die Seite darunter (eigene Notizen)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if editable { return hit }
        return hit.isDescendant(of: pins) && hit !== pins ? hit : nil
    }

    /// Modus "Randnotiz": Tippen setzt eine Notiz, die Zeichenflaeche nimmt keinen Strich an
    func setPlacing(_ on: Bool) {
        guard editable else { return }
        tap?.isEnabled = on
        ink.isUserInteractionEnabled = !on
        ink.drawingGestureRecognizer.isEnabled = !on
    }

    var isPlacing: Bool { tap?.isEnabled ?? false }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        onPlace?(self, info.normalized(g.location(in: self)))
    }

    /// Seite des Entwurfs bzw. der empfangenen Korrektur zeigen (in die angezeigte Drehung umgerechnet)
    func show(_ page: CommunityCorrection.Page?) {
        var drawing = PKDrawing()
        if let page {
            drawing = ForeignLayerView.drawing(page.strokes).transformed(using: info.mapping(from: page.rotation))
            if let tint {
                drawing = PKDrawing(strokes: drawing.strokes.map { s in
                    PKStroke(ink: PKInk(s.ink.inkType, color: tint), path: s.path, transform: s.transform, mask: s.mask)
                })
            }
        }
        isApplying = true
        ink.drawing = drawing
        isApplying = false
        showPins(page)
    }

    func showPins(_ page: CommunityCorrection.Page?) {
        pins.subviews.forEach { $0.removeFromSuperview() }
        guard let page else { return }
        let color = tint ?? UIColor(UF.info)
        for note in page.notes {
            let p = info.point(note, on: page)
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: "text.bubble.fill"), for: .normal)
            b.tintColor = color
            b.backgroundColor = UIColor.white.withAlphaComponent(0.9)
            b.layer.cornerRadius = Self.pinSize / 2
            b.layer.borderColor = color.cgColor
            b.layer.borderWidth = 1
            b.frame = CGRect(x: 0, y: 0, width: Self.pinSize, height: Self.pinSize)
            b.center = p
            b.transform = CGAffineTransform(scaleX: pinScale, y: pinScale)
            b.accessibilityLabel = "Randnotiz: \(note.text)"
            b.accessibilityIdentifier = "correction.pin.\(note.id)"
            let id = note.id
            b.addAction(UIAction { [weak self] _ in self?.onNoteTap?(id) }, for: .touchUpInside)
            pins.addSubview(b)
        }
    }

    /// Striche der Zeichenflaeche als Objekte (Format der Loesungsseiten), in der angezeigten Drehung
    var currentStrokes: [JSONValue] {
        ink.drawing.strokes.flatMap { StrokeConverter.objects(for: $0, ids: [StrokeConverter.newID()]) }
    }

    /// Wie die eigene Canvas: PencilKit zoomt selbst (scharfe Striche), Nadeln bleiben gleich gross auf dem Bildschirm
    func setZoom(_ zoom: CGFloat) {
        PageInkView.zoom(ink, pageSize: bounds.size, to: zoom)
        pinScale = 1 / max(1, zoom)
        pins.subviews.forEach { $0.transform = CGAffineTransform(scaleX: pinScale, y: pinScale) }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplying, editable else { return }
        onInkChange?(self)
    }
}

// MARK: - Editor

extension PageInkView {
    /// Korrektur-Ebene setzen (ersetzt die bisherige): ueber der eigenen Zeichenflaeche
    func setCorrection(_ v: CorrectionPageView?) {
        correctionView?.removeFromSuperview()
        correctionView = v
        guard let v else { return }
        v.frame = CGRect(origin: .zero, size: geometry.pageSize)
        content.addSubview(v)
        v.setZoom(canvas.zoomScale)
    }
}

extension PDFEditorController {
    /// Palette zu sehen: eigene Notizen schreibbar oder Korrektur-Modus; nie beim Abpausen (`EditorFreezeLock.swift`)
    var pickerAllowed: Bool { (writable || correction != nil) && freezeMode != .trace && !presentationMode }

    /// Seite einer PDF-Seite fuer die Korrektur (nur Originalseiten, keine eingefuegten Seiten)
    func correctionInfo(_ overlay: PageInkView) -> CorrectionPageInfo? {
        guard overlay.generation == shownLayoutVersion, let layout = shownLayout, let entry = layout.entry(at: overlay.pageIndex),
              entry.key == overlay.pageKey, let pdfIndex = entry.pdfIndex, let page = layout.pdf.page(at: overlay.pageIndex) else { return nil }
        let box = page.bounds(for: .cropBox).size
        return CorrectionPageInfo(pdfIndex: pdfIndex, width: Double(box.width), height: Double(box.height), rotation: page.rotation)
    }

    /// Korrektur-Ebene eines Overlays: bearbeitbar im Korrektur-Modus, sonst die angezeigte empfangene Korrektur
    func applyCorrection(_ overlay: PageInkView) {
        if let old = overlay.correctionView { toolPicker.removeObserver(old.ink) }
        guard let info = correctionInfo(overlay) else { overlay.setCorrection(nil); return }
        if let session = correction {
            let v = CorrectionPageView(info: info, pageSize: overlay.geometry.pageSize, editable: true)
            v.show(session.draft.page(pdfIndex: info.pdfIndex))
            v.ink.drawingPolicy = drawingPolicy
            v.ink.tool = canvasTool
            toolPicker.addObserver(v.ink)
            v.onInkChange = { [weak session] v in session?.setInk(v.currentStrokes, on: v.info) }
            v.onPlace = { [weak self, weak session] v, p in
                // Striche der Seite zuerst uebernehmen (Drehung der Seite und der Notizen stimmen dann ueberein)
                if v.ink.drawing.strokes.isEmpty == false || session?.draft.page(pdfIndex: v.info.pdfIndex) != nil {
                    session?.setInk(v.currentStrokes, on: v.info)
                }
                self?.onCorrectionNote?(.place(v.info, x: p.x, y: p.y))
            }
            v.onNoteTap = { [weak self] id in self?.onCorrectionNote?(.open(noteID: id)) }
            v.setPlacing(session.placingNote)
            overlay.setCorrection(v)
        } else if let shown = shownCorrection, let page = shown.page(pdfIndex: info.pdfIndex) {
            let v = CorrectionPageView(info: info, pageSize: overlay.geometry.pageSize, editable: false, tint: UIColor(UF.warn))
            v.show(page)
            v.onNoteTap = { [weak self] id in self?.onCorrectionNote?(.open(noteID: id)) }
            overlay.setCorrection(v)
        } else {
            overlay.setCorrection(nil)
        }
    }

    /// Korrektur-Modus an, aus oder gewechselt
    func correctionModeChanged(from old: CorrectionSession?) {
        old?.saveNow()
        old?.onNotesChange = nil
        old?.onModeChange = nil
        if let session = correction {
            session.onNotesChange = { [weak self, weak session] pdfIndex in
                guard let self, let session else { return }
                for o in self.allOverlays where o.correctionView?.info.pdfIndex == pdfIndex {
                    o.correctionView?.showPins(session.draft.page(pdfIndex: pdfIndex))
                }
            }
            session.onModeChange = { [weak self, weak session] in
                guard let self, let session else { return }
                self.allOverlays.forEach { $0.correctionView?.setPlacing(session.placingNote) }
            }
        } else {
            correctionUndo.removeAllActions()
        }
        allOverlays.forEach(applyCorrection)
        showToolPicker(pickerAllowed)
    }
}

// MARK: - Einstieg von aussen

/// Oeffnet ein Dokument im Korrektur-Modus bzw. mit einer empfangenen Korrektur, auch ueber den Router: die Bitte
/// wartet hier, bis das Dokument (`DocumentView`) sie abholt.
@MainActor
final class CorrectionLaunch: ObservableObject {
    static let shared = CorrectionLaunch()

    enum Request: Equatable {
        /// fremde Loesung (Kennung beim Dienst) korrigieren
        case correct(solutionID: String)
        /// empfangene Korrektur ueber den eigenen Notizen zeigen
        case show(CommunityCorrection)
    }

    /// Datei-ID -> wartende Bitte
    @Published private(set) var pending: [String: Request] = [:]

    func request(_ r: Request, fileID: String) { pending[fileID] = r }

    func take(fileID: String) -> Request? { pending.removeValue(forKey: fileID) }

    /// Fremde Loesung in der eigenen PDF korrigieren (Datei aus dem eigenen Abgleich)
    func correct(solutionID: String, fileID: String, router: UFRouter) {
        request(.correct(solutionID: solutionID.lowercased()), fileID: fileID)
        router.go(.doc(fileID))
    }

    /// Empfangene Korrektur in der eigenen PDF ansehen ("Öffnen" im Posteingang)
    func show(_ correction: CommunityCorrection, fileID: String, router: UFRouter) {
        request(.show(correction), fileID: fileID)
        router.go(.doc(fileID))
    }

    /// Eigene Datei zu einer Loesung (Fingerabdruck) im aktiven Container; nil = diese PDF gibt es hier nicht
    static func localFile(fingerprint: String) async -> String? {
        guard let host = ActiveContainer.current?.host else { return nil }
        return await CommunityCourses.localFile(fingerprint: fingerprint, host: host)
    }

    /// Ziel-Loesung fuer den Korrektur-Modus laden: schon empfangene Ebene, sonst aus der Community (passt sie nicht
    /// zur eigenen PDF, wirft das)
    static func targetLayer(solutionID: String, known: [ForeignSolutionLayer], pdf: PDFDocument, fingerprint: String?,
                            service: CommunityService) async throws -> ForeignSolutionLayer {
        let sid = solutionID.lowercased()
        if var layer = known.first(where: { $0.id.lowercased() == sid }) {
            layer.visible = true
            return layer
        }
        let content = try await SolutionSharing.loadCommunity(sid, service: service)
        if let fingerprint, content.fingerprint != fingerprint {
            throw CommunityServiceError.service("Diese Lösung gehört zu einer anderen PDF.")
        }
        return try SolutionSharing.layer(content, visible: true, pdf: pdf)
    }
}
