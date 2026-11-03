import Foundation

/// Klartext von Formatversion 2 (docs/LOESUNGEN-TEILEN.md 3a): Striche als ganze Zahlen statt Dezimalzahlen.
///
/// - `points` (Seitenpunkte, x/y abwechselnd) -> `pointsDelta`: jede Koordinate x 10, gerundet mit
///   `(v * 10 + 0.5).rounded(.down)` (0,1 Punkt genau), dann Differenz zum Wert zwei Stellen davor (x zu x, y zu y);
///   die ersten beiden Werte absolut.
/// - `widths` (Breite je Punkt) -> `widthsDelta`: x 100 (0,01 Punkt), Differenz zum Vorgaenger.
/// - Nur Objekte mit `type` = "stroke"; Listen mit anderen Werten als endlichen Zahlen oder mit |Wert x Faktor| ueber
///   1e10 bleiben unveraendert unter `points`/`widths`. Alle anderen Felder bleiben wie sie sind.
///
/// Nach dem Oeffnen stehen wieder `points`/`widths` als Zahlenliste im Objekt (Wert / Faktor), Editor, Leser und Ebenen
/// sehen dieselben Objekte wie bei Version 1, nur auf 0,1 Punkt gerundet. Gleiche Regeln: `app/solution_format.py`,
/// `app/static/solutions.js`.
public enum SolutionWire {
    struct Field {
        let field: String, delta: String, scale: Double, step: Int
    }

    static let fields = [Field(field: "points", delta: "pointsDelta", scale: 10, step: 2),
                         Field(field: "widths", delta: "widthsDelta", scale: 100, step: 1)]
    static let maxQuant = 1e10

    /// tooLarge, wenn eine Strichliste mehr als `maxStrokeValues` Zahlen hat oder alle zusammen mehr als
    /// `maxStrokeNumbers` (wie `check_stroke_sizes` in app/solution_format.py); zaehlt nur, baut nichts auf.
    public static func checkStrokeSizes(_ content: JSONValue) throws {
        var total = 0
        for page in content["pages"]?.array ?? [] {
            for o in page["objects"]?.array ?? [] where o["type"]?.string == "stroke" {
                for f in ["points", "pointsDelta", "widths", "widthsDelta"] {
                    guard let n = o[f]?.array?.count else { continue }
                    guard n <= SolutionLimits.maxStrokeValues else { throw SolutionError.tooLarge }
                    total += n
                }
            }
        }
        guard total <= SolutionLimits.maxStrokeNumbers else { throw SolutionError.tooLarge }
    }

    static func quantize(_ v: Double, _ scale: Double) -> Int { Int((v * scale + 0.5).rounded(.down)) }

    /// Strich im Speicher -> Version 2.
    public static func encodeObject(_ o: JSONValue) throws -> JSONValue {
        guard case .object(var out) = o, o["type"]?.string == "stroke" else { return o }
        if fields.contains(where: { out[$0.delta] != nil }) { throw SolutionError.invalidContent("reserviertes Feld") }
        for f in fields {
            guard let list = out[f.field]?.array else { continue }
            var values: [Double] = []
            values.reserveCapacity(list.count)
            for v in list {
                guard let d = v.double, d.isFinite, abs(d) * f.scale <= maxQuant else { break }
                values.append(d)
            }
            guard values.count == list.count else { continue }
            let q = values.map { quantize($0, f.scale) }
            out[f.delta] = .array(q.indices.map { .number(Double(q[$0] - ($0 >= f.step ? q[$0 - f.step] : 0))) })
            out[f.field] = nil
        }
        return .object(out)
    }

    /// Strich aus Version 2 -> Punkte als Zahlenliste in Seitenpunkten.
    public static func decodeObject(_ o: JSONValue) throws -> JSONValue {
        guard case .object(var out) = o, o["type"]?.string == "stroke" else { return o }
        for f in fields {
            guard let raw = out[f.delta] else { continue }
            guard out[f.field] == nil, let list = raw.array else { throw SolutionError.invalidContent("Strich") }
            var q: [Int] = []
            q.reserveCapacity(list.count)
            for (i, v) in list.enumerated() {
                // ganze Zahl, nie eine Umwandlung, die abbrechen kann (fremde Daten)
                guard let d = v.double, d.isFinite, d == d.rounded(), abs(d) <= 2 * maxQuant else { throw SolutionError.invalidContent("Strich") }
                let value = Int(d) + (i >= f.step ? q[i - f.step] : 0)
                guard Double(abs(value)) <= maxQuant else { throw SolutionError.invalidContent("Strich") }
                q.append(value)
            }
            out[f.field] = .array(q.map { .number(Double($0) / f.scale) })
            out[f.delta] = nil
        }
        return .object(out)
    }

    private static func mapObjects(_ content: JSONValue, version: Int, _ fn: (JSONValue) throws -> JSONValue) throws -> JSONValue {
        guard case .object(var o) = content else { return content }
        o["formatVersion"] = .number(Double(version))
        if let pages = o["pages"]?.array {
            o["pages"] = .array(try pages.map { page in
                guard case .object(var p) = page, let objects = p["objects"]?.array else { return page }
                p["objects"] = .array(try objects.map(fn))
                return .object(p)
            })
        }
        return .object(o)
    }

    /// Inhalt im Speicher (`SolutionContent.json`, Version 1) -> Klartext von Version 2.
    public static func encodeContent(_ content: JSONValue) throws -> JSONValue {
        try mapObjects(content, version: 2, encodeObject)
    }

    /// Was der Empfaenger nach dem Oeffnen eines Version-2-Pakets erhaelt (Striche auf 0,1 Punkt gerundet).
    public static func normalized(_ content: SolutionContent) throws -> SolutionContent {
        let wire = try JSONValue.parse(try encodeContent(content.json).serialized(sortedKeys: true))
        return try SolutionContent(json: try decodeContent(wire))
    }

    /// Klartext von Version 2 -> Inhalt im Speicher (Version 1), danach prueft `SolutionContent(json:)` alles.
    public static func decodeContent(_ wire: JSONValue) throws -> JSONValue {
        guard case .object = wire, wire["format"]?.string == SolutionContent.format else { throw SolutionError.invalidContent("Formatkennung") }
        guard let v = SolutionValidator.exactInt(wire["formatVersion"]) else { throw SolutionError.invalidContent("Formatversion") }
        guard v == 2 else { throw SolutionError.unsupportedVersion(v) }
        return try mapObjects(wire, version: SolutionContent.formatVersion, decodeObject)
    }
}
