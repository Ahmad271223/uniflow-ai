import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// Schreiblupe (Zoom-Fenster, Plan-Schritt I, 10.11.2026): unten ein breiter Streifen, der einen kleinen Rahmen der
/// Seite vergroessert zeigt. Was man im Streifen schreibt, landet verkleinert im Rahmen auf der Seite (ein
/// Rueckgaengig-Schritt je Strich). So passt Handschrift in enge Luecken von Uebungsblaettern.
/// - Rahmen auf der Seite: blau gestrichelt; Pfeile verschieben ihn, am rechten Rand rueckt er von selbst weiter und
///   springt am Zeilenende in die naechste Zeile.
/// - Im Streifen schreiben nur Stift und Textmarker (Radieren und Auswaehlen auf der Seite selbst).
@MainActor
final class WritingMagnifier: NSObject, PKCanvasViewDelegate {
    private weak var controller: PDFEditorController?
    let panel = UIView()
    let canvas = PKCanvasView()
    private let background = UIImageView()
    private let frameLayer = CAShapeLayer()
    private let hintLabel = UILabel()
    /// Seite und Rahmen in Seitenpunkten
    private(set) var key: String
    private(set) var region: CGRect
    static let panelHeight: CGFloat = 230
    /// Vergroesserung: Streifenbreite / Rahmenbreite
    static let zoom: CGFloat = 3
    /// So weit rechts (Anteil der Streifenbreite) beginnt das automatische Weiterruecken
    static let advanceAt: CGFloat = 0.82

    init(controller: PDFEditorController, key: String, region: CGRect) {
        self.controller = controller
        self.key = key
        self.region = region
        super.init()
        panel.backgroundColor = .secondarySystemBackground
        panel.layer.borderColor = UIColor.separator.cgColor
        panel.layer.borderWidth = 1
        panel.accessibilityIdentifier = "editor.magnifier"
        background.contentMode = .scaleToFill
        background.backgroundColor = .white
        background.layer.borderColor = UIColor.systemBlue.cgColor
        background.layer.borderWidth = 1.5
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.delegate = self
        canvas.drawingPolicy = PDFEditorController.isMac ? .anyInput : controller.drawingPolicy
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.text = "Schreiblupe: hier groß schreiben, es erscheint klein im blauen Rahmen."
        hintLabel.numberOfLines = 2
        frameLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        frameLayer.strokeColor = UIColor.systemBlue.cgColor
        frameLayer.lineDashPattern = [5, 3]
        frameLayer.lineWidth = 1.5

        let buttons = UIStackView(arrangedSubviews: [
            button("arrow.left", "Rahmen zurück") { [weak self] in self?.move(by: -1) },
            button("arrow.right", "Rahmen weiter") { [weak self] in self?.move(by: 1) },
            button("arrow.turn.down.left", "Nächste Zeile") { [weak self] in self?.nextLine() },
            button("xmark", "Schreiblupe schließen") { [weak controller] in controller?.setMagnifier(false) },
        ])
        buttons.axis = .vertical
        buttons.spacing = 6
        for v in [background, canvas, buttons, hintLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(v)
        }
        NSLayoutConstraint.activate([
            buttons.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            background.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            background.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -10),
            background.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            background.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -4),
            hintLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
            canvas.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: background.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        syncTool()
    }

    private func button(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(configuration: .gray(), primaryAction: UIAction(image: UIImage(systemName: icon)) { _ in action() })
        b.accessibilityLabel = label
        if PDFEditorController.isMac { b.toolTip = label }
        return b
    }

    // MARK: Rahmen

    /// Groesse des Rahmens: so breit wie der Streifen geteilt durch die Vergroesserung, im Seitenverhaeltnis des Streifens
    static func regionSize(stripSize: CGSize, zoom: CGFloat = zoom) -> CGSize {
        guard stripSize.width > 0, stripSize.height > 0 else { return CGSize(width: 200, height: 50) }
        let w = stripSize.width / zoom
        return CGSize(width: w, height: w * stripSize.height / stripSize.width)
    }

    /// Rahmen weiterruecken (`direction` +1 nach rechts, -1 nach links), um 70 % seiner Breite, innerhalb der Seite
    func move(by direction: CGFloat) {
        guard let page = pageSize else { return }
        var r = region
        r.origin.x += direction * r.width * 0.7
        if direction > 0, r.maxX > page.width + r.width * 0.3 { nextLine(); return }
        r.origin.x = min(max(0, r.origin.x), max(0, page.width - r.width))
        setRegion(r)
    }

    /// Naechste Zeile: links an den Rand, eine Rahmenhoehe tiefer (am Seitenende bleibt er unten)
    func nextLine() {
        guard let page = pageSize else { return }
        var r = region
        r.origin.x = min(Self.lineStart, max(0, page.width - r.width))
        r.origin.y = min(r.origin.y + r.height * 0.8, max(0, page.height - r.height))
        setRegion(r)
    }

    static let lineStart: CGFloat = 30

    private var pageSize: CGSize? { controller?.boundOverlay(forKey: key)?.geometry.pageSize }

    func setRegion(_ r: CGRect, key newKey: String? = nil) {
        if let newKey, newKey != key { frameLayer.removeFromSuperlayer(); key = newKey }
        region = r
        refresh()
        controller?.reveal(region: r, onKey: key)
    }

    /// Streifen und Rahmen neu zeichnen (nach jedem Strich, nach dem Verschieben, nach dem Layout)
    func refresh() {
        guard let c = controller, let overlay = c.boundOverlay(forKey: key) else { return }
        frameLayer.path = UIBezierPath(rect: region).cgPath
        if frameLayer.superlayer !== overlay.content.layer { overlay.content.layer.addSublayer(frameLayer) }
        let objects = overlay.objectsView.shownObjects.filter { $0["type"]?.string != "stroke" }
        guard let layout = c.shownLayout, let page = layout.pdf.page(at: overlay.pageIndex), let entry = layout.entry(at: overlay.pageIndex)
        else { return }
        let base = PDFEditorController.renderArea(page: page, entry: entry, objects: objects, rect: region)
        let ink = overlay.loaded ? overlay.canvas.drawing : PKDrawing()
        let size = base?.size ?? CGSize(width: region.width * 3, height: region.height * 3)
        background.image = UIGraphicsImageRenderer(size: size).image { _ in
            base?.draw(in: CGRect(origin: .zero, size: size))
            var picture: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent { picture = ink.image(from: region, scale: max(1, size.width / max(region.width, 1))) }
            picture?.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func close() {
        frameLayer.removeFromSuperlayer()
        panel.removeFromSuperview()
    }

    // MARK: Werkzeug

    /// Werkzeug der Palette, solange es schreibt (Stift, Textmarker); sonst nimmt der Streifen nichts an
    func syncTool() {
        guard let c = controller else { return }
        let tool = c.canvasTool
        let writes = tool is PKInkingTool && !c.objects.isActive
        if writes { canvas.tool = tool }
        canvas.isUserInteractionEnabled = writes && c.writable
        hintLabel.text = writes ? "Schreiblupe: hier groß schreiben, es erscheint klein im blauen Rahmen."
            : "Schreiblupe: zum Schreiben Stift oder Textmarker wählen. Radieren und Auswählen auf der Seite."
    }

    // MARK: Uebertragen

    /// Striche aus dem Streifen (Punkte des Streifens) in Seitenpunkte des Rahmens
    static func pageTransform(strip: CGSize, region: CGRect) -> CGAffineTransform {
        let s = strip.width > 0 ? region.width / strip.width : 1
        return CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: region.minX, y: region.minY))
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { transfer() }

    /// Alles im Streifen Geschriebene auf die Seite (ein Rueckgaengig-Schritt), Streifen leeren; am rechten Rand weiter
    func transfer() {
        guard let c = controller, !canvas.drawing.strokes.isEmpty else { return }
        let strokes = canvas.drawing.strokes
        let rightEdge = canvas.drawing.bounds.maxX
        let t = Self.pageTransform(strip: canvas.bounds.size, region: region)
        canvas.drawing = PKDrawing()
        let key = self.key
        Task {
            let before = await c.inkDrawing(forKey: key)
            var after = before
            after.strokes.append(contentsOf: strokes.map { s in
                var m = s
                m.transform = s.transform.concatenating(t)
                return m
            })
            c.replaceInk(key: key, before: before, after: after)
            if rightEdge > canvas.bounds.width * Self.advanceAt { move(by: 1) } else { refresh() }
        }
    }
}

extension PDFEditorController {
    /// Schreiblupe ein/aus (Menue "Mehr", Menueleiste "Dokument", Cmd-Option-Y)
    func setMagnifier(_ on: Bool) {
        if !on || !writable {
            magnifier?.close()
            magnifier = nil
            onMagnifierChange?(false)
            return
        }
        guard magnifier == nil, let key = currentPageKey, let overlay = boundOverlay(forKey: key) else { return }
        let stripWidth = max(320, view.bounds.width - 90)
        let size = WritingMagnifier.regionSize(stripSize: CGSize(width: stripWidth, height: WritingMagnifier.panelHeight - 40))
        // Rahmen links oben im sichtbaren Teil der Seite
        let visible = pdfView.convert(pdfView.bounds, to: overlay.content).intersection(overlay.content.bounds)
        let top = visible.isNull ? 40 : visible.minY + 40
        let region = CGRect(x: min(WritingMagnifier.lineStart, max(0, overlay.geometry.pageSize.width - size.width)), y: top,
                            width: size.width, height: size.height)
        let m = WritingMagnifier(controller: self, key: key, region: region)
        m.panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(m.panel)
        NSLayoutConstraint.activate([
            m.panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            m.panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            m.panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            m.panel.heightAnchor.constraint(equalToConstant: WritingMagnifier.panelHeight),
        ])
        magnifier = m
        view.layoutIfNeeded()
        m.refresh()
        onMagnifierChange?(true)
    }

    /// Rahmen der Schreiblupe sichtbar halten (ueber dem Streifen)
    func reveal(region: CGRect, onKey key: String) {
        guard let overlay = boundOverlay(forKey: key), let scroll = firstScrollView(in: pdfView) else { return }
        let r = overlay.content.convert(region, to: scroll)
        let bottomInset = magnifier == nil ? 0 : WritingMagnifier.panelHeight + 20
        let visible = CGRect(x: scroll.contentOffset.x, y: scroll.contentOffset.y,
                             width: scroll.bounds.width, height: scroll.bounds.height - bottomInset)
        guard !visible.contains(r) else { return }
        var offset = scroll.contentOffset
        if r.maxY > visible.maxY || r.minY < visible.minY { offset.y = max(0, r.minY - 80) }
        if r.minX < visible.minX || r.maxX > visible.maxX { offset.x = max(0, r.midX - scroll.bounds.width / 2) }
        scroll.setContentOffset(offset, animated: true)
    }
}
