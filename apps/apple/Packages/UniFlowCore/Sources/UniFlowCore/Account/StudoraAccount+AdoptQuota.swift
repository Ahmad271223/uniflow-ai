import Foundation

// Kontingent "Karteikarten-Stapel von StudiNow" (`card_stacks_adopted`, Plus 4 je Kalendermonat in Europe/Berlin) je
// StudiNow-Konto ueber alle Geraete (Entscheidung des Inhabers 08.11.2026, Audit P43-06). Die Community laeuft auf dem
// iPad ueber iCloud, die Stapel kennt der Dienst nicht: die App meldet jede Uebernahme mit einer Kennung, der Dienst
// zaehlt sie im vorhandenen Kontingent des Kontos (app/community_cards_api.py `count_adopt_quota_from_app`).
extension StudoraAccount {
    /// Stand des Kontingents laut Dienst; `limit` nil = unbegrenzt (Fair Use nur im Dienst)
    public struct AdoptQuota: Equatable, Sendable {
        /// noch erlaubt (bzw. beim Zaehlen: gezaehlt oder schon gezaehlt)
        public var ok: Bool
        /// in diesem Aufruf neu gezaehlt (derselbe Stapel zaehlt im Monat einmal)
        public var counted: Bool
        public var used: Int
        public var limit: Int?

        public init(ok: Bool, counted: Bool, used: Int, limit: Int?) {
            self.ok = ok
            self.counted = counted
            self.used = used
            self.limit = limit
        }
    }

    /// Stand ohne zu zaehlen (`quotas.card_stacks_adopted` aus GET /api/entitlements)
    public func adoptQuotaStatus() async throws -> AdoptQuota {
        let r = try await request("GET", "/api/entitlements")
        let q = (try? JSONValue.parse(r.body))?["quotas"]?["card_stacks_adopted"]
        let used = Int(q?["used"]?.double ?? 0)
        let limit = q?["unlimited"]?.bool == true ? nil : Int(q?["limit"]?.double ?? 0)
        return AdoptQuota(ok: limit.map { used < $0 } ?? true, counted: false, used: used, limit: limit)
    }

    /// Uebernahme zaehlen (POST /api/community/card-stacks/adopt-quota {ref}); `ok == false` = aufgebraucht
    public func countAdoptedStack(ref: String) async throws -> AdoptQuota {
        let r = try await request("POST", "/api/community/card-stacks/adopt-quota", body: ["ref": .string(ref)])
        let j = (try? JSONValue.parse(r.body)) ?? .null
        return AdoptQuota(ok: j["ok"]?.bool ?? false, counted: j["counted"]?.bool ?? false, used: Int(j["used"]?.double ?? 0),
                          limit: j["limit"]?.double.map { Int($0) })
    }
}
