import Foundation
import XCTest
@testable import UniFlowCore

/// Paritaet 09.11.2026 (Befund K3, docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md Abschnitt 4): Einstellungen, die
/// nur auf einem Geraet etwas bedeuten, gehen nicht in den Abgleich. Die Windows-App (app/sync_client.py
/// `LOCAL_SETTINGS`) nannte zehn, das iPad (`DeviceSyncCore.localSettings`) fuenf. Beispiel `exam_registration_run`:
/// Stand des eigenen QIS-Abrufs (die Tabelle `exam_registrations` gleicht nicht ab); vom iPad gesendet, zeigte der Mac
/// desselben Kontos "N Pruefungen abgerufen" ueber einer leeren Liste und die Geraete ueberschrieben sich gegenseitig.
final class DeviceSyncLocalSettingsTests: XCTestCase {

    /// `LOCAL_SETTINGS` aus app/sync_client.py (die Referenz der Windows-App)
    private func windowsLocalSettings() throws -> Set<String> {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let source = try String(contentsOf: url.appendingPathComponent("app/sync_client.py"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "LOCAL_SETTINGS = {"))
        let end = try XCTUnwrap(source.range(of: "}", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let re = try NSRegularExpression(pattern: "\"([^\"]+)\"")
        return Set(re.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        })
    }

    func testEveryWindowsDeviceLocalKeyIsDeviceLocalOnTheIPadToo() throws {
        let windows = try windowsLocalSettings()
        XCTAssertEqual(windows.count, 10, "Liste in app/sync_client.py gefunden")
        for k in windows.sorted() {
            XCTAssertTrue(DeviceSyncCore.settingIsLocal(k), "\(k) bleibt auf dem Geraet (wie in der Windows-App)")
        }
    }

    func testExamRegistrationRunIsNotSentToTheOtherDevice() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        let keys = try await db.transaction { c -> [String] in
            try DeviceSyncSchema.ensure(c)
            for k in ["exam_registration_run", "messages_seen_up_to", "studip_reply_drafts", "studip_replies", "studip_submissions",
                      "study_plan"] {
                try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, '{}')", [.text(k)])
            }
            return try DeviceSyncCore(device: "ipad-1").collect(c).0.filter { $0.table == "settings" }.map(\.local)
        }
        for k in ["exam_registration_run", "messages_seen_up_to", "studip_reply_drafts", "studip_replies", "studip_submissions"] {
            XCTAssertFalse(keys.contains(k), k)
        }
        XCTAssertTrue(keys.contains("study_plan"), "Studienverlauf gleicht weiter ab")
    }

    /// Stand des eigenen Abrufs: vom iPad gesendet, liess der Mac sein Schwarzes Brett aus (Drosselung `minHours`)
    func testOwnFetchStateOfBulletinAndBlubberStaysOnTheDevice() {
        XCTAssertTrue(DeviceSyncCore.settingIsLocal(StudIPBulletin.fetchedKey))
        XCTAssertTrue(DeviceSyncCore.settingIsLocal(StudIPBlubber.fetchedKey))
        XCTAssertTrue(DeviceSyncCore.settingIsLocal(StudIPBlubber.activityKey))
        XCTAssertTrue(DeviceSyncCore.settingIsLocal(QISRegistrationsSync.runKey))
        for shared in ["study_plan", "exam_dates_auto", "certificates", "studip_missing_endpoints"] {
            XCTAssertFalse(DeviceSyncCore.settingIsLocal(shared), "\(shared) gehoert zum Konto")
        }
    }
}
