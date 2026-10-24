import StoreKit
import StoreKitTest
import XCTest
@testable import UniFlow

/// Abo-Kauf nur in der lokalen StoreKit-Testsitzung (keine echten Produkte, keine Abrechnung).
final class PurchaseTests: XCTestCase {

    @MainActor
    func testPlusPurchaseAndRestoreInTestSession() async throws {
        let session = try SKTestSession(configurationFileNamed: "UniFlow")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let store = PurchaseStore()
        await store.loadProducts()
        XCTAssertEqual(store.products.map(\.id).sorted(), PurchaseStore.productIDs.sorted())
        await store.refreshEntitlements()
        XCTAssertEqual(store.activePlan, "free")

        let plus = try XCTUnwrap(store.products.first { $0.id == "de.uniflow.plus.monthly" })
        await store.purchase(plus)
        await store.refreshEntitlements()
        XCTAssertEqual(store.activePlan, "plus", store.lastError ?? "")
    }

    func testPlanMapping() {
        XCTAssertEqual(PurchaseStore.plan(forProductID: "de.uniflow.pro.monthly"), "pro")
        XCTAssertNil(PurchaseStore.plan(forProductID: "fremd"))
        XCTAssertGreaterThan(PurchaseStore.rank("pro"), PurchaseStore.rank("plus"))
    }
}
