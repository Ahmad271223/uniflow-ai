import StoreKit
import SwiftUI

/// Abo ueber StoreKit 2: Produkte laden, kaufen, wiederherstellen. V1 bietet nur Studora Plus an
/// (`UFPlanCatalog.sellable`, Entscheidung des Inhabers vom 28.10.2026); Pro Connect und Pro AI kommen mit dem
/// Studora-Dienst in dieselbe Abo-Gruppe (docs/ABO-SYSTEM.md). Upgrade und Downgrade innerhalb der Gruppe regelt Apple:
/// hoeher gilt sofort, kleiner ab der naechsten Verlaengerung (Logik in PlanSwitchPurchaseTests geprueft).
///
/// NUR TESTKONFIGURATION: Die Produkte existieren ausschliesslich in `UniFlow.storekit` (lokales StoreKit-Testen in
/// Xcode/Simulator). Echte Produkte in App Store Connect werden erst nach ausdruecklicher Freigabe angelegt.
/// Den Tarif fuehrt `Entitlements` (Transaction.currentEntitlements, Transaction.updates).
@MainActor
final class PurchaseStore: ObservableObject {
    /// in V1 nur Plus (`UFPlanCatalog.sellableProductIDs`); Free hat kein Produkt
    static let productIDs = UFPlanCatalog.sellableProductIDs

    /// Ergebnis eines Kaufs; nur bei `.success` geht die Tarifwahl weiter
    enum Outcome: Equatable { case success, cancelled, pending, failed }

    @Published private(set) var products: [Product] = []
    /// Anspruch auf das Einfuehrungsangebot je Produkt-ID (Apple merkt sich die Nutzung je Abo-Gruppe und Apple ID)
    @Published private(set) var introEligible: [String: Bool] = [:]
    @Published private(set) var loadingProducts = false
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    let entitlements: Entitlements
    /// abgefragte Produkte (Tests: unbekannte Kennungen, als waere der Store nicht erreichbar)
    private let requestedProductIDs: [String]

    /// `nil` = gemeinsamer Tarif der App (`Entitlements.shared`). Aufgeloest erst hier im MainActor-Kontext, weil
    /// Standardargumente in Swift 5 nicht isoliert ausgewertet werden (in Swift 6 ein Fehler).
    init(entitlements: Entitlements? = nil, productIDs: [String] = PurchaseStore.productIDs) {
        self.entitlements = entitlements ?? .shared
        requestedProductIDs = productIDs
    }

    func product(for plan: UFPlan) -> Product? {
        products.first { $0.id == plan.productID }
    }

    /// Produkte laden. Kommt nichts (kein Netz, Store nicht erreichbar), bleibt der Tarif, wie StoreKit ihn zuletzt
    /// kannte (currentEntitlements aus dem Geraete-Zwischenspeicher); die Seite nennt den Grund, "Erneut versuchen".
    func loadProducts() async {
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            products = try await Product.products(for: requestedProductIDs).sorted { $0.price < $1.price }
            await refreshEligibility()
            lastError = products.isEmpty ? "Die Tarife konnten nicht geladen werden. Prüfe die Verbindung und versuche es erneut." : nil
        } catch {
            lastError = "Die Tarife konnten nicht geladen werden: \(error.localizedDescription)"
        }
    }

    /// Anspruch auf das Einfuehrungsangebot fuer alle geladenen Produkte neu lesen. Apple fuehrt ihn je Abo-Gruppe:
    /// Nach einem Kauf, Wiederherstellen oder einer Aktualisierung (Transaction.updates) entfaellt er fuer die ganze
    /// Gruppe. Ohne neues Lesen wuerde die Seite weiter mit "1 Woche gratis" werben (Richtlinie 3.1.2).
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
            // V1 ohne Konto beim Dienst: keine Kaufoptionen (kein appAccountToken, BillingServiceLink.swift)
            let result = try await product.purchase(options: UFBillingServiceLink.purchaseOptions(accountToken: nil))
            guard case .success(let verification) = result else { return Self.outcome(of: result) }
            guard await entitlements.handle(verification) else {
                lastError = "Der Kauf konnte nicht bestätigt werden."
                return .failed
            }
            await refreshEligibility()
            return .success
        } catch {
            let f = Self.failure(error)
            lastError = f.message
            return f.outcome
        }
    }

    /// Ergebnis des Kaufdialogs ohne Transaktion: Abbruch im Apple-Dialog (`.userCancelled`) ist kein Fehler (keine
    /// Meldung, nichts freigeschaltet); `.pending` z. B. "Kaufanfrage" in der Familienfreigabe, die Freischaltung kommt
    /// spaeter ueber Transaction.updates. `.success` behandelt `purchase` selbst.
    nonisolated static func outcome(of result: Product.PurchaseResult) -> Outcome {
        switch result {
        case .success: return .success
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: return .cancelled
        }
    }

    /// Geworfener Fehler: ein als Fehler gemeldeter Abbruch (`StoreKitError.userCancelled`) bleibt ohne Meldung, alles
    /// andere nennt den Grund
    nonisolated static func failure(_ error: Error) -> (outcome: Outcome, message: String?) {
        if case StoreKitError.userCancelled = error { return (.cancelled, nil) }
        return (.failed, "Kauf fehlgeschlagen: \(error.localizedDescription)")
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

    /// Beschriftung des Kaufknopfs ohne laufendes Abo: "Studora Plus – 1 Woche gratis" bzw.
    /// "Studora Plus fuer 1,99 €/Monat"
    static func button(plan: UFPlan, price: String, period: (Int, Product.SubscriptionPeriod.Unit),
                       freeTrial: (Int, Product.SubscriptionPeriod.Unit)?, eligible: Bool) -> String {
        if eligible, let t = freeTrial { return "\(plan.name) – \(self.period(value: t.0, unit: t.1)) gratis" }
        return "\(plan.name) für \(price)\(per(value: period.0, unit: period.1))"
    }

    /// Kaufknopf bei laufendem Abo (Wechsel innerhalb der Abo-Gruppe); der Preis steht darueber auf der Karte
    static func switchButton(to plan: UFPlan) -> String { "Zu \(plan.name) wechseln" }

    /// Hinweis unter dem Knopf: wann der Wechsel gilt (Apple: Upgrade sofort, Downgrade ab der naechsten Verlaengerung)
    static func switchNote(to plan: UFPlan, from current: UFPlan) -> String {
        plan > current
            ? "Gilt sofort. Apple verrechnet den bisherigen Tarif anteilig."
            : "Gilt ab der nächsten Verlängerung, bis dahin bleibt \(current.name)."
    }

    /// Vorgemerkter Wechsel (Downgrade): "Wechsel zu Studora Plus vorgemerkt ab 27. November."
    static func pendingNote(_ next: UFPlan, at date: Date?) -> String {
        guard let date else { return "Wechsel zu \(next.name) zur nächsten Verlängerung vorgemerkt." }
        return "Wechsel zu \(next.name) vorgemerkt ab \(day(date))."
    }

    /// Gekuendigtes Abo: "Gekuendigt – Studora Plus endet am 27. November, danach gilt Studora Free."
    static func cancelledNote(_ plan: UFPlan, endsAt date: Date?) -> String {
        guard let date else { return "Gekündigt – danach gilt \(UFPlan.free.name)." }
        return "Gekündigt – \(plan.name) endet am \(day(date)), danach gilt \(UFPlan.free.name)."
    }

    /// "27. November"
    static func day(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "de_DE")))
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
