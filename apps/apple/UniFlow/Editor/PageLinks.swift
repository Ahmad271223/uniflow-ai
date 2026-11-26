import PDFKit
import SwiftUI
import UIKit
import UniFlowCore

// Verweise auf Dokument + Seite (`PageLink` im Kern, Auftrag des Inhabers 25.11.2026): ein Punkt oder ein Bereich
// ueber einem Wort, der auf eine genaue Stelle zeigt. Antippen oeffnet das Dokument daneben auf der Seite bzw. springt
// dorthin und laesst die Stelle kurz aufleuchten. Verweise liegen wie die Klappkarten in der Schicht ueber der
// Handschrift (`PageObjectsView` der Art `.covers`).

enum LinkRender {
    static var tint: UIColor { UIColor(hex: PageLink.color) ?? .systemBlue }

    static func draw(_ o: JSONValue, size: CGSize, in ctx: CGContext) {
        guard size.width > 1, size.height > 1 else { return }
        let rect = CGRect(origin: .zero, size: size)
        let blue = tint
        func arrow(in r: CGRect, color: UIColor) {
            // Pfeil nach rechts oben (wie "oeffnen"), als Linien - bleibt auch im PDF scharf
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(max(1.2, r.width * 0.14))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let a = CGPoint(x: r.minX + r.width * 0.28, y: r.maxY - r.height * 0.28), b = CGPoint(x: r.maxX - r.width * 0.28, y: r.minY + r.height * 0.28)
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.move(to: CGPoint(x: b.x - r.width * 0.3, y: b.y)); ctx.addLine(to: b); ctx.addLine(to: CGPoint(x: b.x, y: b.y + r.height * 0.3))
            ctx.strokePath()
            ctx.restoreGState()
        }
        if PageLink.isPoint(o) {
            let side = min(size.width, size.height)
            let circle = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side).insetBy(dx: 1.5, dy: 1.5)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            ctx.setFillColor(blue.cgColor)
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: circle.insetBy(dx: 0.6, dy: 0.6))
            arrow(in: circle, color: .white)
        } else {
            // Bereich ueber einem Wort: zart blau hinterlegt und unterstrichen wie ein Link, kleiner Pfeil in der Ecke
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor(blue.withAlphaComponent(0.13).cgColor)
            ctx.fillPath()
            ctx.setStrokeColor(blue.cgColor)
            ctx.setLineWidth(1.4)
            ctx.move(to: CGPoint(x: 2, y: size.height - 1)); ctx.addLine(to: CGPoint(x: size.width - 2, y: size.height - 1))
            ctx.strokePath()
            let a = min(11, size.height * 0.6)
            let badge = CGRect(x: size.width - a - 1, y: 1, width: a, height: a)
            ctx.setFillColor(blue.cgColor)
            ctx.fillEllipse(in: badge)
            arrow(in: badge, color: .white)
        }
    }
}

/// Ein Verweis auf der Seite (in der Schicht ueber der Handschrift)
final class LinkView: UIView {
    var object: JSONValue { didSet { setNeedsDisplay(); describe() } }

    init(object: JSONValue, frame: CGRect) {
        self.object = object
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .link
        describe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    private func describe() {
        accessibilityLabel = "Verweis auf " + (PageLink.target(object)?.label ?? "eine Seite")
        accessibilityHint = "Antippen öffnet die Stelle"
        accessibilityIdentifier = "link.\(object["id"]?.string ?? "")"
    }

    override var contentScaleFactor: CGFloat {
        didSet { if contentScaleFactor != oldValue { setNeedsDisplay() } }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        LinkRender.draw(object, size: bounds.size, in: ctx)
    }
}

/// Laufendes Anlegen eines Verweises: Die Stelle im Dokument steht fest, als Naechstes wird das Ziel angetippt - im
/// Dokument daneben oder auf einer anderen Seite desselben Dokuments. Liegt beim gemeinsamen Werkzeugstand, damit beide
/// Haelften der geteilten Ansicht es sehen.
@MainActor
final class LinkPick {
    weak var source: PDFEditorController?
    let pageKey: String
    /// Punkt oder Bereich der Quelle (Seitenpunkte)
    let rect: CGRect
    let isArea: Bool

    init(source: PDFEditorController, pageKey: String, rect: CGRect, isArea: Bool) {
        self.source = source
        self.pageKey = pageKey
        self.rect = rect
        self.isArea = isArea
    }
}

/// Antippen des Ziels im Dokument daneben (dort ist kein Objektwerkzeug aktiv): nimmt Beruehrungen nur an, solange ein
/// Verweis auf sein Ziel wartet
@MainActor
final class LinkTargetPicker: NSObject, UIGestureRecognizerDelegate {
    private weak var controller: PDFEditorController?
    private(set) lazy var tap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        g.delegate = self
        return g
    }()

    init(controller: PDFEditorController) {
        self.controller = controller
        super.init()
    }

    func install(on view: UIView) {
        guard tap.view == nil else { return }
        view.addGestureRecognizer(tap)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let c = controller, let pick = c.tools.linkPick else { return false }
        // der Editor, in dem der Verweis begonnen wurde, ist zu (Spalte geschlossen): Der Entwurf ist hinfaellig -
        // sonst schluckte dieser Erkenner von nun an jeden Tipp
        guard pick.source != nil else { c.objects.dropLinkPick(); return false }
        // im Editor, der den Verweis anlegt, nimmt das Werkzeug selbst den zweiten Tipp (`ObjectEditing.tapped`)
        return pick.source !== c || !(c.objects.isActive && c.objects.tool == .link)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let c = controller, c.tools.linkPick != nil, let (overlay, p) = c.objects.locate(g) else { return }
        c.objects.finishLink(targetOn: overlay, at: p)
    }
}

extension ObjectEditing {
    static let linkLockedHint = "Verweise auf Dokument und Seite gibt es mit Pro AI."
    static let linkTargetHint = "Jetzt das Ziel antippen: im Dokument daneben oder auf einer anderen Seite."
    static let linkSameSpotHint = "Tippe auf die Stelle, auf die der Verweis zeigen soll – in einem anderen Dokument oder auf einer anderen Seite."
    static func linkMissingHint(_ t: PageLink.Target) -> String {
        t.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Das Ziel dieses Verweises ist auf diesem Gerät nicht vorhanden."
            : "Das Ziel „\(t.title)“ ist auf diesem Gerät nicht vorhanden."
    }

    /// Verweis-Entwurf ohne Quelle verwerfen
    func dropLinkPick() {
        controller?.tools.linkPick = nil
        onLinkPending?(false)
    }

    /// Ein Verweis wartet auf sein Ziel (Leiste im Objektmodus)
    var linkPending: Bool { controller?.tools.linkPick != nil }

    /// Schritt 1: Stelle des Verweises (Punkt beim Antippen, Bereich beim Ziehen). Danach wird das Ziel angetippt.
    func beginLink(on overlay: PageInkView, rect: CGRect, isArea: Bool) {
        guard let c = controller else { return }
        guard c.richNotes else { c.onHint?(Self.linkLockedHint); return }
        c.tools.linkPick = LinkPick(source: c, pageKey: overlay.pageKey, rect: rect, isArea: isArea)
        showLinkDraft(rect, on: overlay)
        c.onHint?(Self.linkTargetHint)
        onLinkPending?(true)
    }

    /// Schritt 2: Ziel angetippt (in diesem oder im anderen Editor) - der Verweis wird im Quelldokument angelegt
    func finishLink(targetOn overlay: PageInkView, at p: CGPoint) {
        guard let c = controller, let pick = c.tools.linkPick else { return }
        guard let source = pick.source else { dropLinkPick(); return }
        let store = c.store
        // dieselbe Seite desselben Dokuments ist kein Ziel (der zweite Tipp war wohl ein Versehen)
        if source === c, overlay.pageKey == pick.pageKey { c.onHint?(Self.linkSameSpotHint); return }
        let index = store.layout?.index(ofKey: overlay.pageKey) ?? overlay.pageIndex
        let target = PageLink.Target(file: store.file.id, title: store.file.displayTitle, pageKey: overlay.pageKey,
                                     pdfPage: store.entry(forKey: overlay.pageKey)?.pdfIndex, pageNumber: index + 1,
                                     x: Double(p.x), y: Double(p.y))
        let id = PageOrder.uid()
        let o = pick.isArea
            ? PageLink.area(id: id, x: Double(pick.rect.minX), y: Double(pick.rect.minY), width: Double(pick.rect.width), height: Double(pick.rect.height), target: target)
            : PageLink.point(id: id, x: Double(pick.rect.midX), y: Double(pick.rect.midY), target: target)
        source.objects.cancelLink()
        c.flash(at: p, on: overlay)
        Task {
            await source.objects.commit(pick.pageKey) { $0 + [o] }
            source.onHint?("Verweis auf „\(target.label)“ angelegt.")
        }
    }

    /// Anlegen abbrechen (anderes Werkzeug, "Abbrechen", Esc)
    func cancelLink() {
        guard let c = controller else { return }
        linkDraft.removeFromSuperlayer()
        guard let pick = c.tools.linkPick, pick.source === c || pick.source == nil else { return }
        c.tools.linkPick = nil
        onLinkPending?(false)
    }

    private func showLinkDraft(_ rect: CGRect, on overlay: PageInkView) {
        let s = Self.screenScale(of: overlay)
        linkDraft.path = CGPath(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerWidth: 4, cornerHeight: 4, transform: nil)
        linkDraft.fillColor = LinkRender.tint.withAlphaComponent(0.15).cgColor
        linkDraft.strokeColor = LinkRender.tint.cgColor
        linkDraft.lineWidth = 1.5 / s
        linkDraft.lineDashPattern = [NSNumber(value: Double(4 / s)), NSNumber(value: Double(3 / s))]
        overlay.content.layer.addSublayer(linkDraft)
    }
}

extension PDFEditorController {
    /// Einem Verweis folgen: im selben Dokument zur Seite blaettern, sonst das Dokument daneben oeffnen bzw. dort hinspringen
    func followLink(_ t: PageLink.Target) {
        if t.file == store.file.id { showLinkTarget(t); return }
        if ownsToolPicker {
            if let onOpenLink { onOpenLink(t) } else { onHint?(ObjectEditing.linkMissingHint(t)) }
        } else if let main = tools.otherEditor(than: self), main.store.file.id == t.file {
            main.showLinkTarget(t)                          // Verweis im Dokument daneben zeigt ins Hauptdokument
        } else {
            onHint?("Diesen Verweis öffnest du im Hauptdokument.")
        }
    }

    /// Seite (0-basiert) eines Ziels in diesem Dokument: ueber den Seitenschluessel, sonst die PDF-Seite, sonst die
    /// Seitenzahl von damals
    func pageIndex(for t: PageLink.Target) -> Int? {
        guard let layout = store.layout, !layout.entries.isEmpty else { return nil }
        if let i = layout.index(ofKey: t.pageKey) { return i }
        if let p = t.pdfPage, let i = layout.entries.firstIndex(where: { $0.pdfIndex == p }) { return i }
        return min(max(0, t.pageNumber - 1), layout.entries.count - 1)
    }

    /// Zur Stelle eines Verweises blaettern und sie kurz aufleuchten lassen. `false`: die Seite gibt es (noch) nicht.
    @discardableResult
    func showLinkTarget(_ t: PageLink.Target) -> Bool {
        guard let index = pageIndex(for: t), pdfView.document?.page(at: index) != nil else { return false }
        goToPage(index)
        let exact = store.layout?.index(ofKey: t.pageKey) == index
        // die Seite von damals gibt es nicht mehr: sagen, statt still eine andere zu zeigen
        if !exact { onHint?("Die Seite, auf die der Verweis zeigt, gibt es so nicht mehr. Das ist jetzt Seite \(index + 1).") }
        Task { @MainActor [weak self] in
            // warten, bis die Seite steht, dann genau zur Stelle und aufleuchten
            for _ in 0..<40 {
                guard let self else { return }
                if let overlay = self.allOverlays.first(where: { $0.pageIndex == index && $0.window != nil && $0.generation == self.shownLayoutVersion }) {
                    guard exact else { return }
                    let p = CGPoint(x: t.x, y: t.y)
                    if overlay.content.bounds.contains(p), let page = self.pdfView.document?.page(at: index), self.freezeMode == .off {
                        let inView = overlay.content.convert(CGRect(x: p.x - 60, y: p.y - 120, width: 120, height: 240), to: self.pdfView)
                        self.pdfView.go(to: self.pdfView.convert(inView, to: page), on: page)
                        self.flash(at: p, on: overlay)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return true
    }

    /// Stelle kurz aufleuchten lassen (Ziel eines Verweises)
    func flash(at p: CGPoint, on overlay: PageInkView) {
        let ring = CAShapeLayer()
        ring.name = "link.flash"
        let r: CGFloat = 16
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = p
        ring.fillColor = LinkRender.tint.withAlphaComponent(0.25).cgColor
        ring.strokeColor = LinkRender.tint.cgColor
        ring.lineWidth = 2
        overlay.content.layer.addSublayer(ring)
        guard !UIAccessibility.isReduceMotionEnabled else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { ring.removeFromSuperlayer() }
            return
        }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.5
        pulse.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [pulse, fade]
        group.duration = 0.8
        group.repeatCount = 2
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { ring.removeFromSuperlayer() }
    }
}
