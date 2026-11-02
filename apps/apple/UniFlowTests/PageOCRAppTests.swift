import PDFKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Texterkennung im lokalen Backend der App: Seite ohne Textebene (Bild-PDF wie ein Scan) -> PDFKit liefert keinen
/// Text, Vision erkennt ihn beim Abruf des Seitentextes (`/pagetext`), gespeichert fuer den naechsten Abruf.
final class PageOCRAppTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-02T12:00:00")!

    /// Einseitige PDF, deren Inhalt nur ein Bild mit Text ist (keine Textebene)
    private static func imagePDF(_ lines: [String]) -> Data {
        let size = CGSize(width: 1240, height: 1754)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 56), .foregroundColor: UIColor.black]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 100, y: 200 + CGFloat(i) * 110), withAttributes: attrs)
            }
        }
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            ctx.beginPage()
            image.draw(in: page)
        }
    }

    func testImagePageIsRecognizedWithVision() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let layout = DataContainerLayout(base: base, key: DataContainerKey(userID: "001234.erfunden.ocr", university: .luh))
        try layout.prepare(clock: Self.clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: Self.clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        XCTAssertTrue(backend.context.ocr.provider is VisionPageOCR, "App setzt Vision als Texterkennung")

        let data = Self.imagePDF(["Kirchhoffsche Maschenregel", "Die Summe aller Spannungen ist null."])
        XCTAssertEqual(PDFDocument(data: data)?.page(at: 0)?.string ?? "", "", "Bild-PDF ohne Textebene")
        let rel = "files/ET/scan.pdf"
        let url = layout.root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let db = backend.context.database
        try await db.execute("INSERT INTO courses(id, title) VALUES ('k-et', 'Elektrotechnik')")
        try await db.execute("INSERT INTO files(id, course_id, name, chdate, local_path) VALUES ('f-scan', 'k-et', 'scan.pdf', 7, ?)", [.text(rel)])

        let started = Date()
        let r = await host.handle(LocalRequest(method: "GET", path: "/api/files/f-scan/pagetext", query: [.init("page", "1")]))
        let seconds = Date().timeIntervalSince(started)
        let text = r.json?["text"]?.string ?? ""
        XCTAssertTrue(text.contains("Maschenregel"), text)
        XCTAssertTrue(text.contains("Kirchhoffsche"), text)
        print("OCR einer Seite im Simulator: \(String(format: "%.2f", seconds)) s")
        // gespeichert: der zweite Abruf erkennt nicht neu (Zeile in page_ocr, Text in page_texts)
        let rows = try await db.rows("SELECT page, text FROM page_ocr WHERE file_id='f-scan'")
        XCTAssertEqual(rows.count, 1)
        let stored = try await db.scalar("SELECT text FROM page_texts WHERE file_id='f-scan' AND page=1")?.string
        XCTAssertEqual(stored, text)
    }
}
