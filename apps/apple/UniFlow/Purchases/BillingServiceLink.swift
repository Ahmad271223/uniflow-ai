import Foundation
import StoreKit

// Verknuepfung des Abos mit dem Studora-Dienst (docs/ABO-SYSTEM.md, Abschnitt 3) – VORBEREITET, IN V1 ABGESCHALTET.
//
// Das iPad laeuft in V1 ohne Konto beim Dienst. Der Tarif entsteht nur auf dem Geraet aus
// Transaction.currentEntitlements (Entitlements.refresh); diese Schicht ruft nichts auf, schickt nichts und setzt beim
// Kauf keine Kennung. Sie haelt nur die Form fest, die der Dienst erwartet (app/billing_api.py, app/apple_store.py),
// damit V2 sie einschalten kann, ohne den Kaufweg umzubauen.
//
// TODO(V2, Konto beim Dienst): `isEnabled` erst einschalten, wenn die App angemeldet ist, dann
//   1. `apple_account_token` aus GET /api/entitlements lesen und beim Kauf als appAccountToken mitgeben
//      (`purchaseOptions(accountToken:)`, PurchaseStore.purchase);
//   2. nach Kauf, Verlaengerung (Transaction.updates) und Wiederherstellen Transaction.jwsRepresentation und die
//      JWS der RenewalInfo an POST /api/billing/apple/verify schicken (`verifyRequest`, ueber den API-Client der App,
//      als `Entitlements.verifyOnServer`); Antworten 409 subscription_owned_by_other_account und 503
//      apple_not_configured verstaendlich zeigen;
//   3. danach den Stand aus GET /api/entitlements zeigen (der Dienst ist dann die Quelle, auch fuer Web/Windows), und
//      die "in Vorbereitung"-Zeilen (UFEntitlement.onDevice == .needsService) nach dem Stand des Dienstes freigeben.
enum UFBillingServiceLink {
    /// V1: aus. Kein Konto beim Dienst, keine Anfrage, kein appAccountToken.
    static let isEnabled = false

    /// Pfad der Server-Pruefung im Dienst
    static let verifyPath = "/api/billing/apple/verify"

    /// Kaufoptionen fuer `Product.purchase(options:)`. In V1 leer. Mit Konto (V2): appAccountToken = UniFlow-ID als
    /// UUID (`apple_account_token` aus GET /api/entitlements), damit der Dienst den Kauf genau einem Konto zuordnet.
    /// `enabled` nur fuer Tests.
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

    /// Anfrage fuer die Server-Pruefung. In V1 nil: es wird nichts gebaut und nichts geschickt. Abschicken (mit
    /// Sitzung) uebernimmt in V2 der API-Client der App. `enabled` nur fuer Tests.
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
