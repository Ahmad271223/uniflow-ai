import Foundation
import XCTest
@testable import UniFlowCore

// Eigene Vorlesungsaufnahmen (docs/VORLESUNG-AUFNEHMEN.md): Abschnitte aus erfundenen Erkennungsergebnissen (kein
// Mikrofon, keine Spracherkennung), Zuordnung zum laufenden Termin, Ablage und Endpunkte des lokalen Backends.

private let clock = UniFlowClock.fixed(berlin: "2026-11-10T10:20:00")!      // Dienstag

final class OwnRecordingTests: XCTestCase {

    // MARK: Abschnitte

    /// Woerter alle 0,5 s ohne Pausen, 150 s lang: Schnitt an der ersten Segmentgrenze nach 60 s -> 0-60, 60-120, 120-150
    func testSectionsEveryMinuteWithoutPauses() {
        let segs = (0..<300).map { TranscriptSegment(start: Double($0) * 0.5, duration: 0.4, text: "w\($0)") }
        let s = TranscriptSections.build(segs)
        XCTAssertEqual(s.map(\.start), [0, 60, 120])
        XCTAssertEqual(s.map(\.end), [59.9, 119.9, 149.9])
        XCTAssertTrue(s[0].text.hasPrefix("w0 w1 ") && s[0].text.hasSuffix(" w119"))
        XCTAssertTrue(s[1].text.hasPrefix("w120 ") && s[2].text.hasSuffix("w299"))
        XCTAssertEqual(s.reduce(0) { $0 + $1.text.split(separator: " ").count }, 300, "kein Wort verloren")
    }

    /// Sprechpause von 3 s nach 30 s schliesst den Abschnitt; eine Pause vor 20 s nicht
    func testPauseClosesSectionOnlyAfterMinimumLength() {
        var segs = (0..<20).map { TranscriptSegment(start: Double($0) * 0.5, duration: 0.4, text: "a") }     // 0-9.9
        segs += (0..<40).map { TranscriptSegment(start: 13 + Double($0) * 0.5, duration: 0.4, text: "b") }  // 13-32.9 (Pause 3 s bei 10 s: zu frueh)
        segs += (0..<10).map { TranscriptSegment(start: 36 + Double($0) * 0.5, duration: 0.4, text: "c") }  // Pause 3 s bei 33 s: Schnitt
        let s = TranscriptSections.build(segs)
        XCTAssertEqual(s.map(\.start), [0, 36])
        XCTAssertEqual(s[0].end, 32.9)
        XCTAssertEqual(s[0].text.split(separator: " ").count, 60)
        XCTAssertEqual(s[1].text, Array(repeating: "c", count: 10).joined(separator: " "))
    }

    /// Erkennung in mehreren Anlaeufen: Zeiten je Anlauf ab 0, `offset` schiebt sie an die richtige Stelle; leere
    /// Segmente und unsortierte Eingabe stoeren nicht, Leerraum im Text wird zu einem Leerzeichen
    func testOffsetEmptySegmentsAndOrder() {
        let segs = [TranscriptSegment(start: 2, duration: 1, text: "zwei"), TranscriptSegment(start: 0, duration: 1, text: " null "),
                    TranscriptSegment(start: 1, duration: 0, text: "   "), TranscriptSegment(start: 1, duration: 1, text: "eins\n")]
        let s = TranscriptSections.build(segs, offset: 120)
        XCTAssertEqual(s, [TranscriptSection(start: 120, end: 123, text: "null eins zwei")])
        XCTAssertEqual(TranscriptSections.build([]), [])
    }

    func testTimestampFormatAndTextRoundTrip() {
        XCTAssertEqual(TranscriptSections.timestamp(0), "00:00")
        XCTAssertEqual(TranscriptSections.timestamp(65.9), "01:05")
        XCTAssertEqual(TranscriptSections.timestamp(3725), "1:02:05")
        let sections = [TranscriptSection(start: 0, end: 61, text: "Guten Morgen, wir beginnen mit Grenzwerten."),
                        TranscriptSection(start: 61, end: 130, text: "Definition: eine Folge konvergiert ..."),
                        TranscriptSection(start: 3700, end: 3760, text: "Bis nächste Woche.")]
        let text = TranscriptSections.format(sections)
        XCTAssertEqual(text, "[00:00] Guten Morgen, wir beginnen mit Grenzwerten.\n\n[01:01] Definition: eine Folge konvergiert ...\n\n[1:01:40] Bis nächste Woche.\n")
        let back = TranscriptSections.parse(text, duration: 3760)
        XCTAssertEqual(back.map(\.start), [0, 61, 3700])
        XCTAssertEqual(back.map(\.end), [61, 3700, 3760])
        XCTAssertEqual(back.map(\.text), sections.map(\.text))
        XCTAssertEqual(TranscriptSections.parse("kein Transkript\n[xx] nein\n"), [])
        // JSON hin und zurueck
        XCTAssertEqual(TranscriptSections.sections(TranscriptSections.json(sections)), sections)
        XCTAssertNil(TranscriptSections.sections(.array([["start": 1, "text": "ohne Ende"]])))
        XCTAssertNil(TranscriptSections.sections(.string("x")))
        XCTAssertEqual(TranscriptSections.plainText(Array(sections.prefix(2))),
                       "[00:00] Guten Morgen, wir beginnen mit Grenzwerten.\n[01:01] Definition: eine Folge konvergiert ...")
    }

    // MARK: Termin

    private func occ(_ title: String, _ start: String, _ end: String, status: String = "teilnahme", module: Int = 1) -> JSONValue {
        ["title": .string(title), "start": .string(start), "end": .string(end), "status": .string(status), "module_id": .number(Double(module)),
         "event_id": 7, "date": "2026-11-10"]
    }

    func testCurrentEventWithToleranceAndFilters() {
        let day = [occ("Analysis I", "10:15", "11:45"), occ("Programmieren", "08:15", "09:45"), occ("Physik", "12:00", "13:30"),
                   occ("Abgewählt", "10:00", "12:00", status: "nicht_teilnahme"), occ("Fällt aus", "10:00", "12:00", status: "ausfall"),
                   occ("Verschoben", "10:00", "12:00", status: "verschoben")]
        XCTAssertEqual(RecordingEventSuggestion.current(day, minutesOfDay: 10 * 60 + 20)?["title"], "Analysis I")
        XCTAssertEqual(RecordingEventSuggestion.current(day, minutesOfDay: 10 * 60 + 2)?["title"], "Analysis I", "15 Minuten vor Beginn")
        // 11:55: Analysis (bis 15 Minuten nach Ende) und Physik (ab 15 Minuten vor Beginn) passen beide, der naechste Beginn gewinnt
        XCTAssertEqual(RecordingEventSuggestion.current(day, minutesOfDay: 11 * 60 + 55)?["title"], "Physik")
        XCTAssertEqual(RecordingEventSuggestion.current(day, minutesOfDay: 11 * 60 + 40)?["title"], "Analysis I", "Physik noch nicht in Reichweite")
        XCTAssertEqual(RecordingEventSuggestion.current(day, minutesOfDay: 9 * 60 + 50)?["title"], "Programmieren")
        XCTAssertNil(RecordingEventSuggestion.current(day, minutesOfDay: 7 * 60), "vor dem ersten Termin")
        XCTAssertNil(RecordingEventSuggestion.current([], minutesOfDay: 600))
        // Lueckenzeit 11:50: Analysis (Ende 11:45) und Physik (Beginn 12:00) passen beide, der naechste Beginn gewinnt
        XCTAssertEqual(RecordingEventSuggestion.current(day, minutesOfDay: 11 * 60 + 50)?["title"], "Physik")
        XCTAssertEqual(RecordingEventSuggestion.candidates(day).map { $0["title"]?.string ?? "" }, ["Programmieren", "Analysis I", "Physik"])
    }

    // MARK: Ablage und Endpunkte

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    /// Status einer Anfrage (XCTAssert kann nicht selbst warten)
    private func status(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> Int {
        await b.handle(request(method, path, body)).status
    }

    private func json(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> JSONValue? {
        await b.handle(request(method, path, body)).json
    }

    private func request(_ method: String, _ path: String, _ body: JSONValue? = nil) -> LocalRequest {
        let url = URL(string: "uniflow-local://device" + path)!
        return LocalRequest(method: method, url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body?.serialized())
    }

    /// Backend mit Modul "Analysis I", Kurs und einem Dienstagstermin 10:15-11:45; Dateien in einem Temp-Container
    private func backend(files: Bool = true) async throws -> (LocalBackend, URL) {
        let container = try tempContainer(self)
        let counter = Counter()
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                            files: files ? LocalFiles(container: container, dataDirectory: "") : nil,
                                            newHex: { String(repeating: "a", count: 31) + String(counter.next()) })
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (1, 'Analysis I', '#123456', ?)", [.text(clock.nowISO)])
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, created_at) VALUES ('c1', 'Analysis I', 'Analysis I', 'vorlesung', 1, ?)", [.text(clock.nowISO)])
            try c.execute("""
                INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, rrule, attend, source, created_at)
                VALUES (1, 'c1', 'Analysis I', 'vorlesung', 1, '10:15', '11:45', 'E001', 'weekly', 1, 'manual', ?)
                """, [.text(clock.nowISO)])
        }
        return (b, container)
    }

    func testSuggestUsesTimetableOfTheDay() async throws {
        let (b, _) = try await backend()
        let r = await b.handle(request("GET", "/api/recordings/own/suggest"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["date"], "2026-11-10")
        XCTAssertEqual(r.json?["event"]?["title"], "Analysis I")
        XCTAssertEqual(r.json?["event"]?["module_id"]?.int, 1)
        XCTAssertEqual(r.json?["candidates"]?.array?.count, 1)
        // andere Uhrzeit: kein laufender Termin, die Auswahl bleibt
        let later = await b.handle(request("GET", "/api/recordings/own/suggest?time=14:00"))
        XCTAssertEqual(later.json?["event"], .null)
        XCTAssertEqual(later.json?["candidates"]?.array?.count, 1)
        // Sonntag: keine Termine
        let sunday = await b.handle(request("GET", "/api/recordings/own/suggest?date=2026-11-15&time=10:30"))
        XCTAssertEqual(sunday.json?["candidates"]?.array?.count, 0)
        await XCTAssertEqualAsync(await status(b, "GET", "/api/recordings/own/suggest?time=25:00"), 422)
        await XCTAssertEqualAsync(await status(b, "GET", "/api/recordings/own/suggest?date=heute"), 422)
    }

    func testCreateListPatchTranscriptSearchAndDelete() async throws {
        let (b, container) = try await backend()
        // leer, auch ohne Tabelle
        await XCTAssertEqualAsync(await json(b, "GET", "/api/recordings/own"), .array([]))
        // eintragen: Kennung vom Backend, Titel aus Termin und Datum, Pfad der Aufnahme festgelegt
        let created = await b.handle(request("POST", "/api/recordings/own", ["module_id": 1, "course_id": "c1", "event_title": "Analysis I",
                                                                               "event_id": 7, "duration": 5400.5, "language": "de-DE"]))
        XCTAssertEqual(created.status, 201, String(decoding: created.body, as: UTF8.self))
        let id = try XCTUnwrap(created.json?["id"]?.string)
        XCTAssertEqual(id, String(repeating: "a", count: 31) + "1")
        XCTAssertEqual(created.json?["title"], "Analysis I · 10.11.2026")
        XCTAssertEqual(created.json?["audio_path"], .string("recordings/eigene/\(id).m4a"))
        XCTAssertEqual(created.json?["recorded_at"], "2026-11-10T10:20:00")
        XCTAssertEqual(created.json?["transcript_status"], "none")
        XCTAssertEqual(created.json?["sections"]?.int, 0)
        XCTAssertEqual(created.json?["module_name"], "Analysis I")
        // doppelt und unbekanntes Modul
        await XCTAssertEqualAsync(await status(b, "POST", "/api/recordings/own", ["id": .string(id)]), 409)
        await XCTAssertEqualAsync(await status(b, "POST", "/api/recordings/own", ["module_id": 99]), 404)
        await XCTAssertEqualAsync(await status(b, "POST", "/api/recordings/own", ["duration": "lang"]), 422)
        await XCTAssertEqualAsync(await status(b, "POST", "/api/recordings/own", ["recorded_at": "gestern"]), 422)
        await XCTAssertEqualAsync(await status(b, "POST", "/api/recordings/own", ["id": "../x"]), 422)
        // ohne Termin: Titel mit Datum
        let plain = await b.handle(request("POST", "/api/recordings/own", ["recorded_at": "2026-11-03T08:15"]))
        XCTAssertEqual(plain.json?["title"], "Vorlesung vom 03.11.2026")
        XCTAssertEqual(plain.json?["module_id"], .null)

        // Liste je Modul (neueste zuerst) und alle
        let mine = await b.handle(request("GET", "/api/recordings/own?module_id=1")).json?.array ?? []
        XCTAssertEqual(mine.map { $0["id"]?.string }, [id])
        await XCTAssertEqualAsync(await json(b, "GET", "/api/recordings/own")?.array?.count, 2)
        await XCTAssertEqualAsync(await status(b, "GET", "/api/recordings/own?module_id=x"), 422)

        // Transkript per PATCH: Abschnitte in der Datenbank, Textdatei neben der Aufnahme, Stand "done"
        let sections: JSONValue = [["start": 0, "end": 58.2, "text": "Heute geht es um Grenzwerte von Folgen."],
                                   ["start": 58.2, "end": 120, "text": "Eine Folge heißt konvergent, wenn"]]
        let patched = await b.handle(request("PATCH", "/api/recordings/own/\(id)", ["transcript": sections, "title": "  VL 5: Grenzwerte "]))
        XCTAssertEqual(patched.status, 200, String(decoding: patched.body, as: UTF8.self))
        XCTAssertEqual(patched.json?["title"], "VL 5: Grenzwerte")
        XCTAssertEqual(patched.json?["sections"]?.int, 2)
        XCTAssertEqual(patched.json?["transcript_status"], "done")
        XCTAssertEqual(patched.json?["transcript"]?.array?[1]["text"], "Eine Folge heißt konvergent, wenn")
        XCTAssertEqual(patched.json?["transcript_path"], .string("recordings/eigene/\(id).txt"))
        let txt = container.appendingPathComponent("recordings/eigene/\(id).txt")
        XCTAssertEqual(try String(contentsOf: txt, encoding: .utf8),
                       "[00:00] Heute geht es um Grenzwerte von Folgen.\n\n[00:58] Eine Folge heißt konvergent, wenn\n")
        await XCTAssertEqualAsync(await status(b, "PATCH", "/api/recordings/own/\(id)", ["transcript": "Text statt Liste"]), 422)
        await XCTAssertEqualAsync(await status(b, "PATCH", "/api/recordings/own/\(id)", ["transcript_status": "fertig"]), 422)
        await XCTAssertEqualAsync(await status(b, "PATCH", "/api/recordings/own/\(id)", ["title": "  "]), 422)
        await XCTAssertEqualAsync(await status(b, "PATCH", "/api/recordings/own/gibtsnicht", ["title": "x"]), 404)
        await XCTAssertEqualAsync(await json(b, "PATCH", "/api/recordings/own/\(id)", ["transcript_status": "partial"])?["transcript_status"], "partial")

        // Suche: Treffer im Transkript mit Abschnittsbeginn und Ausschnitt; ohne Treffer kein Schluessel (Antwort wie am PC)
        let hit = await b.handle(request("GET", "/api/search?q=konvergent")).json
        let rec = try XCTUnwrap(hit?["recordings"]?.array?.first)
        XCTAssertEqual(rec["id"]?.string, id)
        XCTAssertEqual(rec["title"], "VL 5: Grenzwerte")
        XCTAssertEqual(rec["module_name"], "Analysis I")
        XCTAssertEqual(rec["start"]?.double, 58.2)
        XCTAssertTrue(rec["snippet"]?.string?.contains("konvergent") == true)
        let none = await json(b, "GET", "/api/search?q=quantenmechanik")
        XCTAssertNil(none?["recordings"])
        await XCTAssertEqualAsync(await json(b, "GET", "/api/search?q=grenzwerte")?["recordings"]?.array?.first?["start"]?.double, 0,
                       "Treffer im Titel: erster Abschnitt")

        // einzeln lesen, loeschen (Zeile und Dateien), danach 404
        await XCTAssertEqualAsync(await json(b, "GET", "/api/recordings/own/\(id)")?["sections"]?.int, 2)
        let audio = container.appendingPathComponent("recordings/eigene/\(id).m4a")
        try Data([0, 1, 2]).write(to: audio)
        await XCTAssertEqualAsync(await json(b, "DELETE", "/api/recordings/own/\(id)")?["ok"], true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: txt.path))
        await XCTAssertEqualAsync(await status(b, "GET", "/api/recordings/own/\(id)"), 404)
        await XCTAssertEqualAsync(await status(b, "DELETE", "/api/recordings/own/\(id)"), 404)
        await XCTAssertEqualAsync(await json(b, "GET", "/api/recordings/own?module_id=1"), .array([]))
    }

    /// Ohne Dateiablage (Tests, Geraet ohne Speicherort) bleibt das Transkript in der Datenbank, ohne Textdatei
    func testTranscriptWithoutFilesStaysInDatabase() async throws {
        let (b, _) = try await backend(files: false)
        let created = await b.handle(request("POST", "/api/recordings/own", ["transcript": [["start": 0, "end": 3, "text": "Hallo"]]]))
        XCTAssertEqual(created.status, 201)
        XCTAssertEqual(created.json?["transcript_status"], "done")
        XCTAssertEqual(created.json?["transcript_path"], .null)
        XCTAssertEqual(created.json?["sections"]?.int, 1)
        let id = try XCTUnwrap(created.json?["id"]?.string)
        // Transkript entfernen
        let cleared = await b.handle(request("PATCH", "/api/recordings/own/\(id)", ["transcript": .null, "transcript_status": "failed"]))
        XCTAssertEqual(cleared.json?["sections"]?.int, 0)
        XCTAssertEqual(cleared.json?["transcript_status"], "failed")
    }

    /// Der Python-Dienst kennt die Pfade nicht: nur das lokale Backend registriert sie, ohne Konflikt mit anderen Modulen
    func testRoutesRegisteredWithoutConflict() async throws {
        let (b, _) = try await backend(files: false)
        XCTAssertEqual(b.route(method: "GET", path: "/api/recordings/own")?.module, "Eigene Aufnahmen")
        XCTAssertEqual(b.route(method: "GET", path: "/api/recordings/own/suggest")?.pattern.template, "/api/recordings/own/suggest")
        XCTAssertEqual(b.route(method: "GET", path: "/api/recordings/own/abc")?.pattern.template, "/api/recordings/own/{rec_id}")
        await XCTAssertEqualAsync(await status(b, "PUT", "/api/recordings/own"), 405)
    }
}

/// XCTAssertEqual mit wartendem Ausdruck (XCTAssert selbst kann in seiner Autoclosure nicht warten)
private func XCTAssertEqualAsync<T: Equatable>(_ a: @autoclosure () async -> T?, _ b: T?, _ message: String = "",
                                              file: StaticString = #filePath, line: UInt = #line) async {
    let got = await a()
    XCTAssertEqual(got, b, message, file: file, line: line)
}
