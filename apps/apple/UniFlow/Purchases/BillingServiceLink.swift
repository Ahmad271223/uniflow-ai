import Foundation
import StoreKit

// Verknuepfung des Abos mit dem StudiNow-Dienst (docs/ABO-SYSTEM.md, Abschnitte 3 und 6b) – EINGESCHALTET seit 05.11.2026
// (Entscheidung des Inhabers: KI in 1.0 ueber Pro AI, dafuer muss der Dienst den Tarif kennen).
//
// Der Tarif auf dem iPad entsteht weiter aus Transaction.currentEntitlements (Entitlements.refresh); ein Fehler des
// Dienstes sperrt nie einen Kauf. Mit angemeldetem StudiNow-Konto zusaetzlich:
//   1. beim Kauf `appAccountToken` = UniFlow-ID als UUID (`apple_account_token` aus GET /api/entitlements,
//      `accountToken`, gesetzt von StudoraAccountLink), damit der Dienst den Kauf genau einem Konto zuordnet;
//   2. nach Kauf, Verlaengerung (Transaction.updates) und einmal je Anmeldung (Wiederherstellen) geht
//      Transaction.jwsRepresentation an POST /api/billing/apple/verify (`StudoraAccount.verifyApple`, als
//      `Entitlements.verifyOnServer`); 409 subscription_owned_by_other_account zeigt die Kontokarte, 503
//      apple_not_configured bleibt still (naechster Start versucht es erneut);
//   3. danach zeigt die App den Stand aus GET /api/entitlements (Credits, Probe des Kontos).
// Ohne Anmeldung: keine Anfrage, kein appAccountToken.
enum UFBillingServiceLink {
    /// Verknuepfung eingeschaltet (Kaufoption nur mit Konto-Token, Meldung nur mit Anmeldung)
    static let isEnabled = true

    /// `apple_account_token` des angemeldeten Kontos (nil ohne Anmeldung)
    @MainActor static var accountToken: String?

    /// Token fuer den Kauf: das vom Dienst gemeldete (`apple_account_token`), sonst die UniFlow-ID (32 Hex) des
    /// angemeldeten Kontos als UUID, wie `apple_store.account_token` im Dienst; ohne Konto nil (Audit P36-04)
    static func accountToken(service: String?, userID: String?) -> String? {
        if let service, UUID(uuidString: service) != nil { return service }
        guard let hex = userID?.lowercased(), hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let c = Array(hex)
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(c[$0]) }
        return UUID(uuidString: parts.joined(separator: "-"))?.uuidString
    }

    /// Pfad der Server-Pruefung im Dienst
    static let verifyPath = "/api/billing/apple/verify"

    /// Kaufoptionen fuer `Product.purchase(options:)`: mit Konto appAccountToken = UniFlow-ID als UUID
    /// (`apple_account_token` aus GET /api/entitlements), damit der Dienst den Kauf genau einem Konto zuordnet; ohne
    /// Konto leer. `enabled` nur fuer Tests.
    static func purchaseOptions(accountToken: String?, enabled: Bool = isEnabled) -> Set<Product.PurchaseOption> {
        guard enabled, let token = accountToken.flatMap(UUID.init(uuidString:)) else { return [] }
        return [.appAccountToken(token)]
    }

    /// Rumpf von POST /api/billing/apple/verify: {signed_transaction, signed_renewal?}
    struct VerifyBody: Encodable, Equatable {
        let signedTransaction: String
        let signedRenewal: String?

        enum CodingKeys: String, CodingKey {
            case signedTransaction = "signed_transaction"
            case signedRenewal = "signed_renewal"
        }
    }

    /// Form der Anfrage fuer die Server-Pruefung (Vertrag mit app/billing_api.py). Abgeschickt wird sie ueber
    /// `StudoraAccount.verifyApple` mit dem Sitzungs-Token. `enabled` nur fuer Tests.
    static func verifyRequest(base: URL, signedTransaction: String, signedRenewal: String? = nil,
                              enabled: Bool = isEnabled) -> URLRequest? {
        guard enabled, !signedTransaction.isEmpty,
              let body = try? JSONEncoder().encode(VerifyBody(signedTransaction: signedTransaction, signedRenewal: signedRenewal))
        else { return nil }
        var r = URLRequest(url: base.appendingPathComponent(String(verifyPath.dropFirst())))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return r
    }
}
