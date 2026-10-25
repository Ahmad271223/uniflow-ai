import StoreKit
import SwiftUI

/// Abos ueber StoreKit 2 (Plus, Pro): Produkte laden, kaufen, wiederherstellen.
///
/// NUR TESTKONFIGURATION: Die Produkte existieren ausschliesslich in `UniFlow.storekit` (lokales StoreKit-Testen in
/// Xcode/Simulator). Echte Produkte in App Store Connect werden erst nach ausdruecklicher Freigabe angelegt.
/// Den Tarif fuehrt `Entitlements` (Transaction.currentEntitlements, Transaction.updates).
@MainActor
final class PurchaseStore: ObservableObject {
    static let productIDs = UFPlan.allCases.compactMap(\.productID)

    /// Ergebnis eines Kaufs; nur bei `.success` geht die Tarifwahl weiter
    enum Outcome: Equatable { case success, cancelled, pending, failed }

    @Published private(set) var products: [Product] = []
    /// Anspruch auf das Einfuehrungsangebot je Produkt-ID (Apple merkt sich die Nutzung je Abo-Gruppe und Apple ID)
    @Published private(set) var introEligible: [String: Bool] = [:]
    @Published private(set) var loadingProducts = false
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    let entitlements: Entitlements

    /// `nil` = gemeinsamer Tarif der App (`Entitlements.shared`). Aufgeloest erst hier im MainActor-Kontext, weil
    /// Standardargumente in Swift 5 nicht isoliert ausgewertet werden (in Swift 6 ein Fehler).
    init(entitlements: Entitlements? = nil) {
        self.entitlements = entitlements ?? .shared
    }

    /// aktueller Tarif als Text ("free"/"plus"/"pro"), wie bisher
    var activePlan: String { entitlements.plan.rawValue }

    func product(for plan: UFPlan) -> Product? {
        products.first { $0.id == plan.productID }
    }

    func loadProducts() async {
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            await refreshEligibility()
            lastError = products.isEmpty ? "Die Tarife konnten nicht geladen werden. Prüfe die Verbindung und versuche es erneut." : nil
        } catch {
            lastError = "Die Tarife konnten nicht geladen werden: \(error.localizedDescription)"
        }
    }

    /// Anspruch auf das Einfuehrungsangebot fuer alle geladenen Produkte neu lesen. Apple fuehrt ihn je Abo-Gruppe:
    /// Nach einem Kauf, Wiederherstellen oder einer Aktualisierung (Transaction.updates) entfaellt er auch fuer die
    /// anderen Tarife der Gruppe. Ohne neues Lesen wuerde die Seite weiter mit "1 Woche gratis" werben (Richtlinie 3.1.2).
    func refreshEligibility() async {
        var eligible: [String: Bool] = [:]
        for p in products {
            if let sub = p.subscription { eligible[p.id] = await sub.isEligibleForIntroOffer }
        }
        introEligible = eligible
    }

    /// Apple-Kaufdialog. Bei Abbruch bleibt alles, wie es war.
    @discardableResult
    func purchase(_ product: Product) async -> Outcome {
        busy = true
        defer { busy = false }
        lastError = nil
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard await entitlements.handle(verification) else {
                    lastError = "Der Kauf konnte nicht bestätigt werden."
                    return .failed
                }
                await refreshEligibility()
                return .success
            case .userCancelled:
                return .cancelled
            case .pending:
                // z. B. "Kaufanfrage" in der Familienfreigabe: Freischaltung kommt spaeter ueber Transaction.updates
                return .pending
            @unknown default:
                return .cancelled
            }
        } catch {
            lastError = "Kauf fehlgeschlagen: \(error.localizedDescription)"
            return .failed
        }
    }

    /// "Käufe wiederherstellen"
    func restore() async {
        busy = true
        defer { busy = false }
        lastError = nil
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            lastError = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
        }
        await entitlements.refresh()
        await refreshEligibility()
    }

    func refreshEntitlements() async {
        await entitlements.refresh()
    }
}

// MARK: - Texte vor dem Kauf (Richtlinie 3.1.2)

/// Angebotstexte aus den Produktdaten; Preise kommen immer aus `Product.displayPrice`, nie fest aus dem Code.
enum UFOfferText {
    /// "1 Woche", "2 Wochen", "3 Tage", "1 Monat", "1 Jahr"
    static func period(value: Int, unit: Product.SubscriptionPeriod.Unit) -> String {
        "\(value) \(unitName(unit, plural: value != 1))"
    }

    /// "/Monat" bzw. "/3 Monate"
    static func per(value: Int, unit: Product.SubscriptionPeriod.Unit) -> String {
        value == 1 ? "/" + unitName(unit, plural: false) : "/" + period(value: value, unit: unit)
    }

    private static func unitName(_ unit: Product.SubscriptionPeriod.Unit, plural: Bool) -> String {
        switch unit {
        case .day: return plural ? "Tage" : "Tag"
        case .week: return plural ? "Wochen" : "Woche"
        case .month: return plural ? "Monate" : "Monat"
        case .year: return plural ? "Jahre" : "Jahr"
        @unknown default: return ""
        }
    }

    /// "monatlich kündbar" (bei Monatsabos), sonst "jederzeit kündbar"
    static func cancelNote(value: Int, unit: Product.SubscriptionPeriod.Unit) -> String {
        if value == 1 && unit == .month { return "monatlich kündbar" }
        if value == 1 && unit == .year { return "jährlich kündbar" }
        return "jederzeit kündbar"
    }

    /// Text unter dem Preis: bei Anspruch "1 Woche gratis, danach 1,99 €/Monat, monatlich kündbar", sonst
    /// "1,99 €/Monat, monatlich kündbar". `freeTrial` = Dauer des kostenlosen Einfuehrungsangebots.
    static func summary(price: String, period: (Int, Product.SubscriptionPeriod.Unit),
                        freeTrial: (Int, Product.SubscriptionPeriod.Unit)?, eligible: Bool) -> String {
        let regular = price + per(value: period.0, unit: period.1)
        let note = cancelNote(value: period.0, unit: period.1)
        if eligible, let t = freeTrial {
            return "\(self.period(value: t.0, unit: t.1)) gratis, danach \(regular), \(note)"
        }
        return "\(regular), \(note)"
    }

    /// Beschriftung des Kaufknopfs: "Plus – 1 Woche gratis" bzw. "Plus für 1,99 €/Monat"
    static func button(plan: UFPlan, price: String, period: (Int, Product.SubscriptionPeriod.Unit),
                       freeTrial: (Int, Product.SubscriptionPeriod.Unit)?, eligible: Bool) -> String {
        if eligible, let t = freeTrial { return "\(plan.title) – \(self.period(value: t.0, unit: t.1)) gratis" }
        return "\(plan.title) für \(price)\(per(value: period.0, unit: period.1))"
    }
}

extension Product {
    /// Dauer des kostenlosen Einfuehrungsangebots (paymentMode free), sonst nil
    var ufFreeTrial: (Int, Product.SubscriptionPeriod.Unit)? {
        guard let o = subscription?.introductoryOffer, o.paymentMode == .freeTrial else { return nil }
        return (o.period.value * max(1, o.periodCount), o.period.unit)
    }

    /// Abrechnungszeitraum, Standard ein Monat
    var ufPeriod: (Int, Product.SubscriptionPeriod.Unit) {
        guard let p = subscription?.subscriptionPeriod else { return (1, .month) }
        return (p.value, p.unit)
    }
}

/// Tarif in den Einstellungen: dieselbe Tarifwahl wie beim ersten Start, mit "Abo verwalten"
struct SubscriptionView: View {
    var body: some View {
        // Ueberschrift kommt aus der Seite (UFPageHead), die Leiste traegt nur "Fertig"
        PlanPickerView(context: .settings, onDone: {})
            .navigationBarTitleDisplayMode(.inline)
    }
}
