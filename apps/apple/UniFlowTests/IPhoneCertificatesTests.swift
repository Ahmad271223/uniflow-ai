import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bescheinigungen auf dem iPhone (develop Build 10; docs/IPHONE-STAND-2026-11-06.md): Liste nach Art, je Dokument
/// "Öffnen"/"Neu laden" bzw. "Herunterladen" in voller Breite, Semesterwahl breit, "Liste aktualisieren" unter dem Kopf;
/// Vorschau als ganzes Blatt mit "Teilen oder sichern". Karte "Bescheinigungen" unter Uni & Noten mit breitem Knopf.
/// Daten erfunden (Schein-Server), kein Portal, kein Netz.
final class IPhoneCertificatesTests: IPhoneLearnTestCase {

    static let list: JSONValue = [
        "portal": "QIS", "status": "ok", "checked_at": "2026-11-06T09:30:00",
        "note": "Erfundene Liste für den Test.",
        "offers": [
            ["id": "a", "title": "Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG", "kind": "immatrikulation",
             "kind_label": "Immatrikulations- / Studienbescheinigung", "semester": "WiSe 2026/27", "confirmed": true,
             "semesters": [["value": "20262", "label": "WiSe 2026/27"], ["value": "20261", "label": "SoSe 2026"]],
             "file": ["fetched_at": "2026-11-06T09:31:00", "semester": "WiSe 2026/27"]],
            ["id": "b", "title": "Notenspiegel (alle Leistungen) deutsch", "kind": "notenspiegel",
             "kind_label": "Notenspiegel / Leistungsübersicht (PDF)", "semester": .null, "confirmed": false, "file": .null],
        ],
        "kinds": [["kind": "immatrikulation", "label": "Immatrikulationsbescheinigung", "offered": true],
                  ["kind": "datenkontrollblatt", "label": "Datenkontrollblatt", "offered": false]],
        "documents": [],
    ]

    private func api() -> APIClient {
        let t = Canned()
        t.answer("/api/certificates", Self.list)
        return remote(t)
    }

    func testListWithWideButtons() throws {
        let env = try hostPhone(CertificatesPage(), api: api())
        XCTAssertTrue(env.wait(timeout: 15) { self.button(env, "Öffnen") != nil }, dump(env))
        let width = env.window.bounds.width
        let open = frame(button(env, "Öffnen")), reload = frame(button(env, "Neu laden"))
        XCTAssertEqual(open.midY, reload.midY, accuracy: 2, "Öffnen und Neu laden nebeneinander")
        XCTAssertGreaterThan(open.width + reload.width, width * 0.7, "zusammen volle Breite")
        XCTAssertGreaterThanOrEqual(open.height, 39.5)
        let download = frame(button(env, "Herunterladen"))
        XCTAssertGreaterThan(download.width, width * 0.7, "Herunterladen in voller Breite: \(download)")
        XCTAssertGreaterThan(frame(button(env, "Liste aktualisieren")).width, width * 0.7, "Liste aktualisieren in voller Breite")
        XCTAssertTrue(shows(env, "auf diesem \(UFDevice.name)"), "Geraetename im Text")
        assertFitsOnAllPhones(env, "Bescheinigungen")
        shoot(env, "iphone-bescheinigungen")
    }

    func testPreviewIsFullSheetWithShare() throws {
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-bescheinigung-\(UUID().uuidString).pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            ("Erfundene Bescheinigung" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        try data.write(to: pdf)
        addTeardownBlock { try? FileManager.default.removeItem(at: pdf) }
        struct Presenter: View {
            let preview: CertificatePreview
            @State private var shown: CertificatePreview?
            var body: some View {
                Color.clear
                    .sheet(item: $shown) { p in CertificatePreviewSheet(preview: p, reload: nil) }
                    .onAppear { shown = preview }
            }
        }
        let p = CertificatePreview(url: pdf, title: "Immatrikulationsbescheinigung", stand: "2026-11-06T09:31:00", offerID: "a")
        let env = try hostPhone(Presenter(preview: p), api: api())
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetOpen(env) && self.shows(env, "Teilen oder sichern") }, dump(env))
        let sheet = try XCTUnwrap(env.hosting.presentedViewController)
        XCTAssertEqual(sheet.sheetPresentationController?.detents.map(\.identifier) ?? [.large], [.large], "ganzes Blatt")
        XCTAssertTrue(shows(env, "Teilen oder sichern"))
        assertFits(env, "Vorschau")
        dismissSheet(env)
    }

    func testPadKeepsSmallButtons() throws {
        let env = try hostPad(CertificatesPage(), api: api())
        XCTAssertTrue(env.wait(timeout: 15) { self.button(env, "Herunterladen") != nil }, dump(env))
        XCTAssertLessThan(frame(button(env, "Herunterladen")).width, 300, "iPad: kleiner Knopf")
    }
}
