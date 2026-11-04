import Foundation

/// Eigene Vorlesungsaufnahmen (`/api/recordings/own…`, docs/VORLESUNG-AUFNEHMEN.md). Nur im lokalen Backend des
/// iPads: Aufnahme und Transkript entstehen auf dem Geraet und bleiben dort, der Python-Dienst kennt diese Pfade
/// nicht. Die App schreibt die m4a-Datei selbst unter `recordings/eigene/<id>.m4a` (`OwnRecordingFiles`) und traegt
/// die Aufnahme danach hier ein; das Transkript kommt per PATCH als Abschnittsliste und wird zusaetzlich als Textdatei
/// neben die Aufnahme gelegt (ohne Dateiablage, z. B. in Tests, nur in die Datenbank).
///
/// - GET  /api/recordings/own?module_id=        Liste (neueste zuerst), ohne module_id alle
/// - POST /api/recordings/own                   eintragen {id?, module_id?, course_id?, title?, event_title?, event_id?,
///                                              recorded_at?, duration?, language?, transcript?, transcript_status?}
/// - GET  /api/recordings/own/suggest?date=&time=  laufender Termin des Stundenplans und die Termine des Tages
/// - GET  /api/recordings/own/{id}              eine Aufnahme mit Abschnitten
/// - PATCH /api/recordings/own/{id}             Felder aendern (Titel, Modul, Termin, Dauer, Transkript, Stand)
/// - DELETE /api/recordings/own/{id}            Aufnahme, Transkript und Zeile entfernen
public enum OwnRecordingEndpoints: LocalEndpointModule {
    public static let name = "Eigene Aufnahmen"

    static func bad(_ message: String) -> LocalHTTPError { LocalHTTPError(status: 422, message: message) }

    /// ganze Zahl oder null (auch "12" als Text); 422 bei anderem
    static func intOrNull(_ v: JSONValue?, _ field: String) throws -> SQLiteValue {
        guard let v, !v.isNull else { return .null }
        if let i = v.int { return .integer(Int64(i)) }
        if let s = v.string, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return .integer(Int64(i)) }
        throw bad("\(field): ganze Zahl erwartet")
    }

    static func textOrNull(_ v: JSONValue?, _ field: String, maxLength: Int = 500) throws -> SQLiteValue {
        guard let v, !v.isNull else { return .null }
        guard let s = v.string else { throw bad("\(field): Text erwartet") }
        return .text(String(s.unicodeScalars.prefix(maxLength)))
    }

    static func secondsOrNull(_ v: JSONValue?, _ field: String) throws -> SQLiteValue {
        guard let v, !v.isNull else { return .null }
        guard let d = v.double, d.isFinite, d >= 0 else { throw bad("\(field): Sekunden als Zahl erwartet") }
        return .real(d)
    }

    /// Werte aus dem Rumpf fuer INSERT bzw. UPDATE (nur die gegebenen Schluessel)
    static func values(_ b: [String: JSONValue], ctx: LocalContext) throws -> [String: SQLiteValue] {
        var out: [String: SQLiteValue] = [:]
        if b.keys.contains("module_id") { out["module_id"] = try intOrNull(b["module_id"], "module_id") }
        if b.keys.contains("event_id") { out["event_id"] = try intOrNull(b["event_id"], "event_id") }
        for k in ["course_id", "event_title", "language"] where b.keys.contains(k) { out[k] = try textOrNull(b[k], k) }
        if b.keys.contains("title") {
            let t = try textOrNull(b["title"], "title")
            guard let s = t.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { throw bad("title: darf nicht leer sein") }
            out["title"] = .text(s)
        }
        if b.keys.contains("duration") { out["duration"] = try secondsOrNull(b["duration"], "duration") }
        if b.keys.contains("transcript") {
            if let v = b["transcript"], v.isNull {
                out["transcript"] = .null
            } else {
                guard let sections = TranscriptSections.sections(b["transcript"]) else { throw bad("transcript: Liste von {start, end, text} erwartet") }
                out["transcript"] = .text(TranscriptSections.json(sections).jsonString(sortedKeys: true))
            }
        }
        if b.keys.contains("transcript_status") {
            guard let s = b["transcript_status"]?.string, OwnRecordingStore.statuses.contains(s) else {
                throw bad("transcript_status: " + OwnRecordingStore.statuses.sorted().joined(separator: " | "))
            }
            out["transcript_status"] = .text(s)
        }
        return out
    }

    /// Transkript als Textdatei neben die Aufnahme schreiben (nur mit Dateiablage); Rueckgabe: gespeicherter Pfad
    static func writeTranscript(_ sections: [TranscriptSection], id: String, files: LocalFiles?) -> String? {
        guard let files else { return nil }
        let path = OwnRecordingFiles.transcriptPath(id)
        guard (try? files.write(Data(TranscriptSections.format(sections).utf8), to: path)) != nil else { return nil }
        return path
    }

    public static func register(on router: LocalRouter) {
        router.get("/api/recordings/own") { req, ctx in
            var module: Int?
            if let raw = req.query("module_id"), !raw.isEmpty {
                guard let m = Int(raw) else {
                    throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", "module_id"],
                                                    msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
                }
                module = m
            }
            let wanted = module
            return .json(.array(try await ctx.database.withConnection { try OwnRecordingStore.list($0, moduleID: wanted) }))
        }

        // laufender Termin (Vorschlag) und alle Termine des Tages (Auswahl); date/time wie "2026-11-10" und "10:15",
        // ohne Angabe heute und jetzt nach der Uhr des Backends
        router.get("/api/recordings/own/suggest") { req, ctx in
            let day: Int
            if let raw = req.query("date"), !raw.isEmpty {
                guard let d = BerlinClock.parseISODate(raw) else { throw bad("date: YYYY-MM-DD erwartet") }
                day = d
            } else {
                day = LocalTimetable.today(ctx.clock)
            }
            let minutes: Int
            if let raw = req.query("time"), !raw.isEmpty {
                guard TimetableEndpoints.isTime(raw), let m = RecordingEventSuggestion.minutes(.string(raw)) else { throw bad("time: HH:MM erwartet") }
                minutes = m
            } else {
                minutes = ctx.clock.minutesOfDay
            }
            let occ = try await ctx.database.withConnection { try LocalTimetable.occurrences($0, from: day, to: day) }
            return .json(["date": .string(LocalTimetable.iso(day)),
                          "event": RecordingEventSuggestion.current(occ, minutesOfDay: minutes) ?? .null,
                          "candidates": .array(RecordingEventSuggestion.candidates(occ))])
        }

        router.post("/api/recordings/own") { req, ctx in
            let b = try req.objectBody()
            var vals = try values(b, ctx: ctx)
            let id: String
            if let given = b["id"]?.string, !given.isEmpty {
                guard given.count <= 64, given.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" }) else {
                    throw bad("id: nur Buchstaben, Ziffern und Bindestrich")
                }
                id = given
            } else {
                id = ctx.newHex()
            }
            let now = ctx.clock.nowISO
            if let r = b["recorded_at"], !r.isNull {
                guard let s = r.string, BerlinClock.utcSeconds(localISO: s) != nil else { throw bad("recorded_at: YYYY-MM-DDTHH:MM[:SS] erwartet") }
                vals["recorded_at"] = .text(s)
            } else {
                vals["recorded_at"] = .text(now)
            }
            if vals["title"] == nil {
                let day = String((vals["recorded_at"]?.string ?? now).prefix(10))
                let event = vals["event_title"]?.string ?? ""
                vals["title"] = .text(event.isEmpty ? "Vorlesung vom \(UFDate.german(day))" : "\(event) · \(UFDate.german(day))")
            }
            vals["audio_path"] = .text(OwnRecordingFiles.audioPath(id))
            if vals["transcript_status"] == nil { vals["transcript_status"] = .text(vals["transcript"] == nil ? "none" : "done") }
            if let t = vals["transcript"]?.string, let sections = TranscriptSections.sections(try? JSONValue.parse(t)),
               let path = writeTranscript(sections, id: id, files: ctx.files) {
                vals["transcript_path"] = .text(path)
            }
            let values = vals
            return .json(try await ctx.database.transaction { c -> JSONValue in
                try OwnRecordingStore.ensureTables(c)
                guard try c.queryOne("SELECT 1 FROM own_recordings WHERE id=?", [.text(id)]) == nil else {
                    throw LocalHTTPError(status: 409, message: "Diese Aufnahme ist schon eingetragen.")
                }
                if let m = values["module_id"]?.int, try c.queryOne("SELECT 1 FROM modules WHERE id=?", [.integer(Int64(m))]) == nil {
                    throw LocalHTTPError.notFound("Modul nicht gefunden")
                }
                try OwnRecordingStore.insert(c, id: id, values: values, now: now)
                return try OwnRecordingStore.get(c, id: id) ?? .null
            }, status: 201)
        }

        router.get("/api/recordings/own/{rec_id}") { req, ctx in
            let id = req.param("rec_id")
            guard let r = try await ctx.database.withConnection({ try OwnRecordingStore.get($0, id: id) }) else {
                throw LocalHTTPError.notFound("Aufnahme nicht gefunden")
            }
            return .json(r)
        }

        router.patch("/api/recordings/own/{rec_id}") { req, ctx in
            let id = req.param("rec_id")
            let b = try req.objectBody()
            var vals = try values(b, ctx: ctx)
            if let t = vals["transcript"]?.string, let sections = TranscriptSections.sections(try? JSONValue.parse(t)) {
                if let path = writeTranscript(sections, id: id, files: ctx.files) { vals["transcript_path"] = .text(path) }
                if vals["transcript_status"] == nil { vals["transcript_status"] = .text("done") }
            } else if vals.keys.contains("transcript") {
                ctx.files?.remove(stored: OwnRecordingFiles.transcriptPath(id))
                vals["transcript_path"] = .null
            }
            let now = ctx.clock.nowISO
            let values = vals
            return .json(try await ctx.database.transaction { c -> JSONValue in
                if let m = values["module_id"]?.int, try c.queryOne("SELECT 1 FROM modules WHERE id=?", [.integer(Int64(m))]) == nil {
                    throw LocalHTTPError.notFound("Modul nicht gefunden")
                }
                guard try OwnRecordingStore.update(c, id: id, values: values, now: now) else { throw LocalHTTPError.notFound("Aufnahme nicht gefunden") }
                return try OwnRecordingStore.get(c, id: id) ?? .null
            })
        }

        router.delete("/api/recordings/own/{rec_id}") { req, ctx in
            let id = req.param("rec_id")
            guard let paths = try await ctx.database.transaction({ try OwnRecordingStore.delete($0, id: id) }) else {
                throw LocalHTTPError.notFound("Aufnahme nicht gefunden")
            }
            for p in paths { ctx.files?.remove(stored: p) }
            return .json(["ok": true])
        }
    }
}

/// Datum fuer Titel eigener Aufnahmen ("10.11.2026" aus "2026-11-10")
enum UFDate {
    static func german(_ iso: String) -> String {
        let p = iso.split(separator: "-")
        guard p.count == 3 else { return iso }
        return "\(p[2]).\(p[1]).\(p[0])"
    }
}
