import StoreKit
import SwiftUI
import UniFlowCore

/// Blatt "Credits kaufen" (Auftrag des Inhabers vom 15.11.2026, docs/KI-CREDITS-2026-11-15.md). Zwei Anlaesse:
/// die Credits reichen nicht fuer eine KI-Anfrage ("Deine Credits sind aufgebraucht", statt einer Sackgasse) oder der
/// Eintrag "Credits kaufen" auf der Tarif-Karte. Zeigt den Stand beider Toepfe, die Pakete (Zahl der Credits vom
/// Dienst, Preis aus dem Store), den Satz "Gekaufte Credits verfallen nicht. ..." und "Nicht jetzt".
///
/// Wer kaufen darf, sagt der Dienst (`credits.can_buy`); ohne dieses Recht stehen hier keine Pakete, sondern ehrlich,
/// was gilt (ruhende Credits bleiben beim Konto). Oeffnen nur ueber `ufCreditShop` (das Blatt laeuft ueber `ufSheet`).
struct CreditShopSheet: View {
    enum Reason: Equatable {
        /// die Credits reichten nicht fuer eine Anfrage
        case exhausted
        /// "Credits kaufen" auf der Tarif-Karte
        case shop
    }

    let reason: Reason
    @ObservedObject var link: StudoraAccountLink
    @ObservedObject var store: CreditStore
    let close: () -> Void

    /// Hinweis unter den Paketen: einmaliger Kauf, kein Abo (Pflichtangabe vor dem Kauf)
    static let payNote = "Einmaliger Kauf über deine Apple-ID, kein Abo. Die Credits gehören zu deinem StudiNow-Konto und gelten auf allen deinen Geräten."
    static let unavailable = "Gerade nicht verfügbar"
    static let loading = "Preis wird geladen …"
    static let done = "Fertig"

    static func title(_ reason: Reason) -> String { reason == .exhausted ? CreditText.titleExhausted : CreditText.titleShop }

    /// VoiceOver eines Pakets: "100 Credits kaufen für 1,99 €" bzw. ohne Preis "100 Credits, gerade nicht verfügbar"
    static func packAccessibility(credits: Int, price: String?) -> String {
        guard let price else { return "\(CreditText.packLabel(credits)), gerade nicht verfügbar" }
        return "\(CreditText.packLabel(credits)) kaufen für \(price)"
    }

    /// Kennung eines Pakets fuer Tests: "credits.pack.klein"
    static func packIdentifier(_ productID: String) -> String { "credits.pack." + (productID.split(separator: ".").last.map(String.init) ?? productID) }

    private var balance: CreditPacks.Balance? { link.credits?.balance }
    private var canBuy: Bool { CreditPacks.offersShop(balance) }
    private var bought: Bool { store.notice != nil && store.message == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UFIcon("sparkles", size: 20).foregroundStyle(UF.accentFill).accessibilityHidden(true)
                    Text(Self.title(reason)).ufFont(20, 700, em: -0.01).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("credits.shop.title")
                }
                if let line = AICost.balanceLine(link.credits, trial: link.planStatus?.trialActive ?? false, labelled: false) {
                    Text(line).ufFont(14.5, 600).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("credits.shop.balance")
                }
                if canBuy {
                    VStack(spacing: 10) {
                        ForEach(link.creditPacks) { pack in packButton(pack) }
                    }
                    Text(CreditText.keepNote(balance)).ufFont(13.6).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("credits.shop.keep")
                    Text(Self.payNote).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(CreditText.dormantNote(balance) ?? CreditText.buyNeedsProAI).ufFont(14.5).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("credits.shop.blocked")
                }
                if let m = store.message {
                    Text(m).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("credits.shop.error")
                }
                if let n = store.notice {
                    Text(n).ufFont(13.6, 600).foregroundStyle(UF.okText).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("credits.shop.notice")
                }
                HStack {
                    Spacer(minLength: 0)
                    UFButton(bought ? Self.done : CreditText.notNow, kind: bought ? .primary : .ghost) { close() }
                        .accessibilityIdentifier("credits.shop.close")
                }
            }
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(UF.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            store.clearMessages()
            await store.loadProducts()
            await link.refreshCredits()
        }
    }

    /// Ein Paket: links "100 Credits", rechts der Preis aus dem Store; ohne Produkt deaktiviert
    private func packButton(_ pack: CreditPacks.Pack) -> some View {
        let product = store.product(for: pack)
        let price = product?.displayPrice
        return Button {
            guard let product else { return }
            Task { await store.purchase(product) }
        } label: {
            HStack(spacing: 12) {
                Text(CreditText.packLabel(pack.credits)).ufFont(16, 650).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(price ?? (store.loadingProducts ? Self.loading : Self.unavailable))
                    .ufFont(price == nil ? 13.12 : 16, price == nil ? 500 : 700)
                    .foregroundStyle(price == nil ? UF.muted : UF.accentFill)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UF.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UF.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(product == nil || store.busy)
        .opacity(product == nil ? 0.6 : 1)
        .accessibilityLabel(Self.packAccessibility(credits: pack.credits, price: price))
        .accessibilityIdentifier(Self.packIdentifier(pack.productID))
    }
}

/// Oeffnet das Blatt "Credits kaufen" an einer KI-Stelle: von selbst, sobald die Stelle nach einem Fehler die Handlung
/// `.credits` hat (Credits reichen nicht, das Konto darf kaufen), und ueber `isPresented` (Knopf unter der Meldung,
/// Eintrag auf der Tarif-Karte). Ohne Konto-Anschluss geschieht nichts.
private struct UFCreditShopHost: ViewModifier {
    @Binding var isPresented: Bool
    let reason: CreditShopSheet.Reason
    let action: StudiNowAIAction?
    @Environment(\.ufStudoraAccount) private var account

    func body(content: Content) -> some View {
        content
            .onChange(of: action) { _, now in
                if now == .credits, account != nil { isPresented = true }
            }
            .ufSheet(isPresented: $isPresented) {
                if let account {
                    CreditShopSheet(reason: reason, link: account, store: account.creditStore) { isPresented = false }
                }
            }
    }
}

extension View {
    /// Blatt "Credits kaufen" (`CreditShopSheet`). `opensFor`: Handlung zum letzten KI-Fehler der Stelle; wird sie
    /// `.credits`, oeffnet das Blatt von selbst.
    func ufCreditShop(isPresented: Binding<Bool>, reason: CreditShopSheet.Reason = .exhausted, opensFor action: StudiNowAIAction? = nil) -> some View {
        modifier(UFCreditShopHost(isPresented: isPresented, reason: reason, action: action))
    }
}

/// Eintrag "Credits kaufen" (Tarif-Karte der Einstellungen, Tarifseite): nur, wenn das Konto kaufen darf. Ruhen
/// gekaufte Credits (Pro AI vorbei), steht stattdessen ehrlich, dass sie beim Konto bleiben.
struct CreditShopEntry: View {
    @ObservedObject var link: StudoraAccountLink
    @State private var shop = false

    static let button = "Credits kaufen"

    var body: some View {
        let balance = link.credits?.balance
        if CreditPacks.offersShop(balance) {
            UFButton(Self.button, icon: "sparkles", size: .small) { shop = true }
                .accessibilityIdentifier("credits.buy")
                .ufCreditShop(isPresented: $shop, reason: .shop)
        } else if let note = CreditText.dormantNote(balance) {
            Text(note).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("credits.dormant")
        }
    }
}

/// Karte "KI-Credits" auf der Tarifseite (Einstellungen -> Tarif wechseln): Stand beider Toepfe und "Credits kaufen".
/// Nur mit Stand vom Dienst und nur, wenn es etwas zu sagen gibt (Konto darf kaufen oder hat gekaufte Credits).
struct CreditShopCard: View {
    @ObservedObject var link: StudoraAccountLink

    static let title = "KI-Credits"

    /// Zeigt die Tarifseite die Karte? Mit Kaufrecht oder mit gekauften Credits (auch ruhenden)
    static func shows(_ b: CreditPacks.Balance?) -> Bool {
        guard let b else { return false }
        return b.canBuy || b.purchased > 0
    }

    var body: some View {
        if Self.shows(link.credits?.balance) {
            UFCard(flat: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7.2) {
                        UFIcon("sparkles", size: 18).foregroundStyle(UF.accentFill).accessibilityHidden(true)
                        Text(Self.title).ufFont(15.2, 650).foregroundStyle(UF.text)
                    }
                    if let line = AICost.balanceLine(link.credits, trial: link.planStatus?.trialActive ?? false, labelled: false) {
                        Text(line).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("plans.credits.balance")
                    }
                    Text(CreditText.keep).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    CreditShopEntry(link: link)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("plans.credits")
        }
    }
}
