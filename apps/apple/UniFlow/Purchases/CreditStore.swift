import StoreKit
import SwiftUI
import UniFlowCore

/// Credit-Pakete ueber StoreKit 2 (Auftrag des Inhabers vom 15.11.2026, docs/KI-CREDITS-2026-11-15.md): zwei
/// Verbrauchskaeufe (`CreditPacks.productIDs`). Gekaufte Credits verfallen nicht und liegen beim StudiNow-Konto.
///
/// Ablauf: Kaufdialog von Apple -> die signierte Transaktion geht an den Dienst (`book`, `POST
/// /api/billing/credits/apple`) -> erst wenn der Dienst sie verbucht hat, wird sie abgeschlossen (`finish`). Ohne
/// Antwort des Dienstes bleibt der Kauf offen; `processUnfinished` holt ihn beim naechsten Start bzw. nach der Anmeldung
/// nach, und `Transaction.updates` (ueber `Entitlements.handle`) bringt freigegebene Kaufanfragen und Erstattungen.
/// Der Dienst verbucht jede Transaktion genau einmal, darum darf dieselbe beliebig oft gemeldet werden.
///
/// Preise kommen immer aus `Product.displayPrice`, die Zahl der Credits vom Dienst (`CreditPacks.Pack`).
@MainActor
final class CreditStore: ObservableObject {
    static let shared = CreditStore()

    /// Ergebnis eines Kaufs
    enum Outcome: Equatable {
        /// vom Dienst verbucht (oder schon bekannt) und abgeschlossen
        case booked(CreditPacks.PurchaseResult)
        /// bezahlt, aber noch nicht verbucht (Dienst nicht erreichbar, nicht angemeldet): bleibt offen, wird nachgeholt
        case waiting
        /// wartet auf eine Freigabe (Kaufanfrage in der Familienfreigabe)
        case pending
        case cancelled
        case failed
    }

    /// Kein Konto angemeldet: der Kauf bleibt offen, bis eines angemeldet ist
    struct NotSignedIn: Error {}

    @Published private(set) var products: [Product] = []
    @Published private(set) var loadingProducts = false
    @Published private(set) var busy = false
    /// Fehler des letzten Versuchs
    @Published private(set) var message: String?
    /// Rueckmeldung des letzten Kaufs ("100 Credits gutgeschrieben.")
    @Published private(set) var notice: String?

    /// Verbuchen beim Dienst mit der signierten Transaktion (setzt `StudoraAccountLink`); wirft bei jedem Fehler.
    /// nil: kein Konto-Anschluss - dann wird nichts gekauft und nichts abgeschlossen.
    var book: ((String) async throws -> CreditPacks.PurchaseResult)?

    private let requestedProductIDs: [String]
    /// Transaktionen, die gerade gemeldet werden (Kauf und `Transaction.updates` liefern dieselbe)
    private var inFlight: Set<UInt64> = []

    static let signInFirst = "Melde dich zuerst mit deinem StudiNow-Konto an. Die Credits gehören zu deinem Konto."
    static let unconfirmed = "Der Kauf konnte nicht bestätigt werden."
    static let askToBuy = "Der Kauf wartet auf eine Freigabe. Danach kommen die Credits von selbst."
    static let loadFailed = "Die Pakete konnten nicht geladen werden. Prüfe die Verbindung und versuche es erneut."

    init(productIDs: [String] = CreditPacks.productIDs) {
        requestedProductIDs = productIDs
    }

    /// Produkt des Pakets; nil, wenn StoreKit es nicht geliefert hat
    func product(for pack: CreditPacks.Pack) -> Product? { products.first { $0.id == pack.productID } }

    func loadProducts() async {
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            products = try await Product.products(for: requestedProductIDs).sorted { $0.price < $1.price }
            if products.isEmpty { message = Self.loadFailed } else if message == Self.loadFailed { message = nil }
        } catch {
            message = Self.loadFailed
        }
    }

    /// Meldungen des letzten Versuchs wegnehmen (Blatt oeffnet neu)
    func clearMessages() {
        message = nil
        notice = nil
    }

    /// Apple-Kaufdialog fuer ein Paket. Bei Abbruch bleibt alles, wie es war.
    @discardableResult
    func purchase(_ product: Product) async -> Outcome {
        let accountToken: String? = UFBillingServiceLink.accountToken
        guard book != nil, let token = accountToken else {
            message = Self.signInFirst
            return .failed
        }
        busy = true
        defer { busy = false }
        clearMessages()
        do {
            // appAccountToken = StudiNow-Konto: der Dienst schreibt die Credits genau diesem Konto gut
            let result = try await product.purchase(options: UFBillingServiceLink.purchaseOptions(accountToken: token))
            switch result {
            case .success(let verification):
                let outcome = await handle(verification)
                switch outcome {
                case .booked(let r): notice = CreditText.purchaseNotice(r)
                case .waiting: notice = CreditText.pendingNotice
                default: message = Self.unconfirmed
                }
                return outcome
            case .pending:
                notice = Self.askToBuy
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            let f = PurchaseStore.failure(error)
            message = f.message
            return f.outcome == .cancelled ? .cancelled : .failed
        }
    }

    /// Eine Transaktion eines Pakets an den Dienst melden und danach - nur danach - abschliessen. Auch fuer
    /// `Transaction.updates` und offene Kaeufe. Nicht verifizierte Transaktionen und andere Produkte: `.failed`.
    @discardableResult
    func handle(_ result: VerificationResult<StoreKit.Transaction>) async -> Outcome {
        guard case .verified(let transaction) = result, CreditPacks.isPack(transaction.productID) else { return .failed }
        guard let book, inFlight.insert(transaction.id).inserted else { return .waiting }
        defer { inFlight.remove(transaction.id) }
        do {
            let booked = try await book(result.jwsRepresentation)
            await transaction.finish()               // erst jetzt: der Dienst hat den Kauf verbucht
            return .booked(booked)
        } catch {
            return .waiting                          // offen lassen, beim naechsten Start erneut
        }
    }

    /// Offene Kaeufe nachholen (Start, Anmeldung): alles, was bezahlt, aber noch nicht verbucht ist. Liefert, wie viele
    /// jetzt verbucht wurden.
    @discardableResult
    func processUnfinished() async -> Int {
        guard book != nil else { return 0 }
        var done = 0
        for await result in StoreKit.Transaction.unfinished {
            guard case .verified(let t) = result, CreditPacks.isPack(t.productID) else { continue }
            if case .booked = await handle(result) { done += 1 }
        }
        return done
    }
}
