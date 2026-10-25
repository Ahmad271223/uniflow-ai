import StoreKit
import SwiftUI

/// Abos ueber StoreKit 2 (Plus, Pro).
///
/// NUR TESTKONFIGURATION: Die Produkte existieren ausschliesslich in `UniFlow.storekit` (lokales StoreKit-Testen in
/// Xcode/Simulator). Echte Produkte in App Store Connect werden erst nach ausdruecklicher Freigabe angelegt.
/// Die App zeigt den Tarif an; verbindlich entscheidet spaeter der Server (signierte Transaktion -> Pruefung).
@MainActor
final class PurchaseStore: ObservableObject {
    static let productIDs = ["de.uniflow.plus.monthly", "de.uniflow.pro.monthly"]

    @Published private(set) var products: [Product] = []
    @Published private(set) var activePlan = "free"
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    /// Server-Pruefung der signierten Transaktion (JWS). Solange es keinen Server mit Konten gibt: nicht gesetzt.
    var verifyOnServer: ((String) async -> Bool)?

    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    deinit { updates?.cancel() }

    static func plan(forProductID id: String) -> String? {
        ["de.uniflow.plus.monthly": "plus", "de.uniflow.pro.monthly": "pro"][id]
    }

    static func rank(_ plan: String) -> Int { ["free": 0, "plus": 1, "pro": 2][plan] ?? 0 }

    func loadProducts() async {
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            lastError = products.isEmpty ? "Keine Produkte gefunden (nur in der StoreKit-Testkonfiguration vorhanden)." : nil
        } catch {
            lastError = "Produkte nicht geladen: \(error.localizedDescription)"
        }
    }

    func purchase(_ product: Product) async {
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = "Kauf fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// "Käufe wiederherstellen"
    func restore() async {
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = "Wiederherstellen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        var best = "free"
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            if let exp = t.expirationDate, exp < Date() { continue }
            if let plan = Self.plan(forProductID: t.productID), Self.rank(plan) > Self.rank(best) { best = plan }
        }
        activePlan = best
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else {
            lastError = "Kauf konnte nicht bestätigt werden."
            return
        }
        if let verify = verifyOnServer, !(await verify(result.jwsRepresentation)) {
            lastError = "Server hat den Kauf nicht bestätigt."
        }
        await transaction.finish()
        await refreshEntitlements()
    }
}

/// Tarifansicht (Testmodus).
struct SubscriptionView: View {
    @StateObject private var store = PurchaseStore()

    var body: some View {
        List {
            Section {
                LabeledContent("Aktueller Tarif", value: store.activePlan.capitalized)
            } footer: {
                Text("Testmodus: Käufe laufen nur über die lokale StoreKit-Testkonfiguration. Es wird nichts abgerechnet.")
            }
            Section("Tarife") {
                ForEach(store.products, id: \.id) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.displayName).bold()
                            Text(p.description).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(p.displayPrice) { Task { await store.purchase(p) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.busy)
                    }
                }
            }
            Section {
                Button("Käufe wiederherstellen") { Task { await store.restore() } }.disabled(store.busy)
            }
            if let e = store.lastError {
                Section { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .navigationTitle("Tarif")
        .task {
            await store.loadProducts()
            await store.refreshEntitlements()
        }
    }
}
