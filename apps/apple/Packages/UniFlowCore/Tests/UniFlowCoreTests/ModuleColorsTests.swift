import Foundation
import XCTest
@testable import UniFlowCore

/// Fachfarben (`ModuleColors`, app/colors.py): Vergabe der Reihe nach, zweite Stufe, einmalige Umstellung alter
/// Datenbanken und der Merker fuer selbst gewaehlte Farben. Die Gleichheit mit Python pruefen ausserdem die Fixtures
/// (schema/legacy.json, local-backend/*.json), die Farbwerte vergleicht tests/test_module_colors.py.
final class ModuleColorsTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-10-27T10:00:00")!

    func testPaletteShape() {
        XCTAssertEqual(ModuleColors.palette.count, 12)
        XCTAssertEqual(ModuleColors.palette2.count, 12)
        XCTAssertEqual(Set(ModuleColors.all).count, 24, "keine Farbe doppelt")
        XCTAssertTrue(Set(ModuleColors.all).isDisjoint(with: ModuleColors.oldPalette))
        XCTAssertEqual(LocalModules.palette, ModuleColors.palette)
    }

    func testEnsureModulesGivesUniqueColorsInOrder() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(c, clock: clock)
        for i in 0..<26 {
            let name = String(format: "Testfach %02d", i)
            try c.execute("INSERT INTO courses(id, title, subject, kind, created_at) VALUES (?,?,?, 'vorlesung', '2026-10-27')",
                          [.text("k\(i)"), .text(name), .text(name)])
        }
        try LocalModules.ensureModules(c, clock: clock)
        let got = try c.query("SELECT color FROM modules ORDER BY id").compactMap { $0[0].string }
        XCTAssertEqual(Array(got.prefix(24)), ModuleColors.all, "bis 24 Faecher keine Farbe doppelt")
        XCTAssertEqual(Array(got.suffix(2)), [ModuleColors.all[0], ModuleColors.all[1]], "danach reihum")
        XCTAssertFalse(zip(got, got.dropFirst()).contains { $0 == $1 }, "nie zwei gleiche nebeneinander")
    }

    func testNextSkipsColorsInUse() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(c, clock: clock)
        try c.execute("INSERT INTO modules(name, color, sort) VALUES ('A', ?, 0)", [.text(ModuleColors.palette[0].uppercased())])
        try c.execute("INSERT INTO modules(name, color, sort) VALUES ('B', ?, 1)", [.text(ModuleColors.palette[2])])
        XCTAssertEqual(try ModuleColors.next(c), ModuleColors.palette[1])
        try c.execute("INSERT INTO modules(name, color, sort) VALUES ('C', ?, 2)", [.text(ModuleColors.palette[1])])
        XCTAssertEqual(try ModuleColors.next(c), ModuleColors.palette[3])
    }

    /// Wie test_old_palette_is_replaced_once_and_own_colors_stay in Python
    func testOldPaletteIsReplacedOnceAndOwnColorsStay() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try c.executeScript("""
            CREATE TABLE modules (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, semester TEXT, color TEXT, icon TEXT,
                                  priority INTEGER DEFAULT 2, exam_date TEXT, sort INTEGER DEFAULT 0, created_at TEXT);
            INSERT INTO modules(name, color, sort) VALUES ('Testmathematik I', '#4f6df5', 0);
            INSERT INTO modules(name, color, sort) VALUES ('Testphysik', '#3b82c4', 1);
            INSERT INTO modules(name, color, sort) VALUES ('Eigenes Testfach', '#ff00aa', 2);
            INSERT INTO modules(name, color, sort) VALUES ('Testchemie', '#0ea5a0', 3);
            INSERT INTO modules(name, color, sort) VALUES ('Testbiologie', '#1aa39a', 4);
            INSERT INTO modules(name, color, sort) VALUES ('Testgeologie', '#4f6df5', 5);
            INSERT INTO modules(name, color, sort) VALUES ('Ohne Farbe', NULL, 6);
            """)
        try Migrations.migrate(c, clock: clock)
        let rows = try c.query("SELECT name, color, color_custom FROM modules ORDER BY id")
        XCTAssertEqual(rows[2][1].string, "#ff00aa", "selbst gesetzte Farbe bleibt")
        XCTAssertEqual(rows[2][2].int, 1, "mit Merker")
        XCTAssertEqual(rows.filter { $0[2].int == 0 }.compactMap { $0[1].string }, Array(ModuleColors.palette.prefix(6)))
        try c.execute("UPDATE modules SET color='#4f6df5' WHERE name='Testphysik'")
        try Migrations.migrate(c, clock: clock)
        XCTAssertEqual(try c.scalar("SELECT color FROM modules WHERE name='Testphysik'")?.string, "#4f6df5", "nur einmal")
    }

    /// Wie test_patch_marks_only_a_changed_color_as_own in Python
    func testPatchMarksOnlyAChangedColorAsOwn() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        func call(_ method: String, _ path: String, _ body: String) async -> LocalResponse {
            await backend.handle(LocalRequest(method: method, path: path, body: Data(body.utf8)))
        }
        let a = await call("POST", "/api/modules", #"{"name": "Testfach A"}"#)
        XCTAssertEqual(a.json?["color"]?.string, ModuleColors.palette[0])
        XCTAssertEqual(a.json?["color_custom"], 0)
        let same = await call("PATCH", "/api/modules/1", "{\"color\": \"" + ModuleColors.palette[0] + "\", \"priority\": 3}")
        XCTAssertEqual(same.json?["color_custom"], 0, "unveraenderte Farbe aus dem Dialog bleibt automatisch")
        let changed = await call("PATCH", "/api/modules/1", "{\"color\": \"" + ModuleColors.palette[5] + "\"}")
        XCTAssertEqual(changed.json?["color"]?.string, ModuleColors.palette[5])
        XCTAssertEqual(changed.json?["color_custom"], 1)
        let b = await call("POST", "/api/modules", #"{"name": "Testfach B"}"#)
        XCTAssertEqual(b.json?["color"]?.string, ModuleColors.palette[0], "frei gewordene Farbe")
        let own = await call("POST", "/api/modules", ##"{"name": "Testfach C", "color": "#123456"}"##)
        XCTAssertEqual(own.json?["color"], "#123456")
        XCTAssertEqual(own.json?["color_custom"], 1)
        let missing = await call("PATCH", "/api/modules/999", ##"{"color": "#000000"}"##)
        XCTAssertEqual(missing.status, 404)
    }
}
