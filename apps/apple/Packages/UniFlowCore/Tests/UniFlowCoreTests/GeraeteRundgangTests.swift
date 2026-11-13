import Foundation
import XCTest
@testable import UniFlowCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Ein Schritt eines Apple-Geraets (iPad oder iPhone) im Rundgang ueber alle Geraete (tools/g2-geraete-rundgang.py,
// 13.11.2026). Derselbe Abgleich-Code wie in der App (`DeviceSync`, `StudoraAccount`), mit einer Datenbank-Datei je
// Geraet, die zwischen den Schritten bestehen bleibt. Ohne G2_SCHRITT uebersprungen.
//
// G2_SCHRITT = Pfad zu {base, token, device, account, db, out, actions: [{sql, params?} | {sync: true} | {query, name}]}

private struct RundgangHTTP: ServiceHTTPTransport {
    func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
        var q = URLRequest(url: URL(string: r.url)!)
        q.httpMethod = r.method
        q.httpBody = r.body
        for (k, v) in r.headers { q.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await URLSession.shared.data(for: q)
        return ServiceHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: d)
    }
}

final class GeraeteRundgangTests: XCTestCase {
    private static func value(_ v: JSONValue) -> SQLiteValue {
        switch v {
        case .null: return .null
        case .bool(let b): return .integer(b ? 1 : 0)
        case .number(let d): return d == d.rounded() && abs(d) < 9e15 ? .integer(Int64(d)) : .real(d)
        case .string(let s): return .text(s)
        default: return .text(v.jsonString())
        }
    }

    func testSchritt() async throws {
        guard let path = ProcessInfo.processInfo.environment["G2_SCHRITT"] else { throw XCTSkip("G2_SCHRITT fehlt") }
        let cmd = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        let base = try XCTUnwrap(cmd["base"]?.string), token = try XCTUnwrap(cmd["token"]?.string)
        let device = try XCTUnwrap(cmd["device"]?.string), account = try XCTUnwrap(cmd["account"]?.string)
        let db = try SQLiteDatabase(path: try XCTUnwrap(cmd["db"]?.string))
        try await db.withConnection { c in try Migrations.migrate(c) }
        let acc = StudoraAccount(base: base, http: RundgangHTTP(), tokens: MemoryTokenStore(token), deviceID: device, deviceName: device)
        let sync = DeviceSync(database: db, transport: acc, device: device)
        var out: [JSONValue] = []
        for a in cmd["actions"]?.array ?? [] {
            if let sql = a["sql"]?.string {
                let params = (a["params"]?.array ?? []).map(Self.value)
                try await db.withConnection { c in try c.execute(sql, params) }
            } else if a["sync"] != nil {
                let r = await sync.run(account: account)
                out.append(.object(["sync": .object([
                    "ok": .bool(r.ok), "error": r.error.map { .string($0) } ?? .null, "pulled": .number(Double(r.pulled)),
                    "applied": .number(Double(r.applied)), "pushed": .number(Double(r.pushed)), "deleted": .number(Double(r.deleted)),
                    "conflicts": .number(Double(r.conflicts)), "pending": .number(Double(r.pending)),
                    "notes_merged": .number(Double(r.notesMerged)), "plan_required": .bool(r.planRequired),
                    "errors": .array(r.errors.map { .string($0) })])]))
            } else if let q = a["query"]?.string {
                let rows = try await db.rows(q)
                out.append(.object(["name": a["name"] ?? .null, "rows": .array(rows.map { .object($0) })]))
            }
        }
        let target = try XCTUnwrap(cmd["out"]?.string)
        try JSONValue.array(out).serialized().write(to: URL(fileURLWithPath: target))
    }
}
