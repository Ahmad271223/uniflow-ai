import PencilKit
import UIKit

/// Bild einer Ansicht ohne Fenster, mit den Zeichnungen ihrer PencilKit-Canvas. `CALayer.render(in:)` nimmt den
/// Inhalt einer PKCanvasView nicht mit (PencilKit zeichnet in eigene Kacheln); hier zeichnet PencilKit dieselbe
/// Zeichnung (`PKDrawing.image`, hell) an die Stelle der Canvas, ueber alle Transformationen dazwischen
/// (Drehungsabbildung der fremden Ebene, Zoom des Overlays). Ausgeblendete Canvas zaehlen nicht.
@MainActor
enum InkSnapshot {
    static func image(_ root: UIView, size: CGSize, scale: CGFloat = 1, opaque: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            root.layer.render(in: ctx.cgContext)
            for canvas in canvases(in: root) { draw(canvas, of: root, scale: scale, in: ctx.cgContext) }
        }
    }

    private static func canvases(in view: UIView) -> [PKCanvasView] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        return (view as? PKCanvasView).map { [$0] } ?? view.subviews.flatMap(canvases)
    }

    private static func draw(_ canvas: PKCanvasView, of root: UIView, scale: CGFloat, in cg: CGContext) {
        let o = canvas.convert(CGPoint.zero, to: root)
        let x = canvas.convert(CGPoint(x: 1, y: 0), to: root), y = canvas.convert(CGPoint(x: 0, y: 1), to: root)
        let t = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
        let zoom = sqrt(abs(t.a * t.d - t.b * t.c))
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = canvas.drawing.image(from: canvas.bounds, scale: max(1, scale * zoom))
        }
        cg.saveGState()
        cg.concatenate(t)
        image.draw(in: canvas.bounds)
        cg.restoreGState()
    }
}
