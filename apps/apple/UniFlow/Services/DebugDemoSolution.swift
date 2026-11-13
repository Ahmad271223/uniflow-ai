#if DEBUG
import Foundation
import PDFKit
import UniFlowCore

/// Nur Debug (UI-Tests, Bildvergleiche): `-UFDocPanel solution` legt zum offenen Dokument eine erfundene Loesung von
/// "Anonym" an (Strich auf Seite 1, karierte Notizseite dahinter), versiegelt mit der eigenen PDF, und importiert sie
/// in die Ablage dieses Geraets - wie eine geladene Community-Loesung. Nichts wird gesendet. Eine schon vorhandene
/// Loesung zu dieser PDF bleibt (kein Stapel bei jedem Start).
@MainActor
enum DebugDemoSolution {
    static func ensure(for store: DocumentStore) async {
        guard let pdf = store.originalPDF, let page = pdf.page(at: 0), let fp = await store.originalFingerprint(),
              let data = try? store.originalPDFData() else { return }
        if !(await store.solutionLayers()).layers.isEmpty { return }
        let box = page.bounds(for: .cropBox)
        func stroke(_ id: String, _ y: Double) -> JSONValue {
            let pts: [JSONValue] = (0..<20).flatMap { i -> [JSONValue] in [.number(60 + Double(i) * 14), .number(y + sin(Double(i) / 2) * 10)] }
            return .object(["id": .string(id), "type": "stroke", "points": .array(pts), "color": "#c0262d", "width": 4])
        }
        let pages = [
            SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: Double(box.width), height: Double(box.height),
                         rotation: page.rotation, objects: [stroke("s1", 200)]),
            SolutionPage(key: "bDemo", kind: .blank, pdfIndex: nil, width: 595, height: 842, rotation: 0, template: "grid",
                         objects: [stroke("s2", 300)]),
        ]
        let content = SolutionContent(solutionID: UUID().uuidString.lowercased(), createdAt: ISO8601DateFormatter().string(from: Date()),
                                      title: store.file.displayTitle, displayName: "", fingerprint: fp,
                                      pdfPageCount: pdf.pageCount, pages: pages)
        guard let sealed = try? SolutionSharing.package(content, originalPDF: data),
              let url = try? SolutionSharing.writeFile(sealed, title: "Demo-Loesung") else { return }
        _ = try? await store.importSolution(url)
    }
}
#endif
