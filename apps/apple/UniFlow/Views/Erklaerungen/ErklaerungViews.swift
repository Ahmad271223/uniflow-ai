import SwiftUI
import UniFlowCore

// Erklaerungen von StudiNow in der Oberflaeche (22.11.2026): Kreis an der Datei (Modulseite), Kauf-Blatt, Hinweis und
// Eintrag „Mehr“ im geoeffneten Dokument. Zustand und Abfragen: `StudiNowErklaerungen`.

/// Ablauf hinter Kreis, Hinweis und Menue: gekauft und abgelegt -> oeffnen; gekauft, aber nicht hier -> (kostenlos)
/// holen und oeffnen; sonst das Kauf-Blatt
enum ErklaerungAction: Equatable {
    case open(String)
    case fetch
    case ask

    static func next(for o: StudiNowErklaerungen.Offer) -> ErklaerungAction {
        if let local = o.localFileID { return .open(local) }
        return o.owned ? .fetch : .ask
    }
}

/// Kleiner Kreis neben der Datei: Funken = „Es gibt eine Erklärung von StudiNow“, Haekchen = gekauft (oeffnet sie)
struct ErklaerungBadge: View {
    let fileID: String
    @ObservedObject private var shop = StudiNowErklaerungen.shared
    @ObservedObject private var ent = Entitlements.shared
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @State private var asking: StudiNowErklaerungen.Offer?
    @State private var busy = false

    var body: some View {
        if let o = shop.badge(for: fileID) {
            Button { tap(o) } label: {
                ZStack {
                    Circle().fill(o.owned ? UF.okSoft : UF.accentSoft)
                    Circle().strokeBorder(o.owned ? UF.ok.opacity(0.35) : UF.accent.opacity(0.35), lineWidth: 1)
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        UFIcon(o.owned ? "check" : "sparkles", size: 13).foregroundStyle(o.owned ? UF.okText : UF.accentText)
                    }
                }
                .frame(width: 26, height: 26)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(ErklaerungText.badgeLabel(owned: o.owned))
            .accessibilityLabel(ErklaerungText.badgeLabel(owned: o.owned))
            .accessibilityIdentifier("erklaerung.badge.\(fileID)")
            .ufSheet(item: $asking) { offer in
                ErklaerungBuySheet(offer: offer) { asking = nil }.ufSheetPresentation()
            }
        }
    }

    private func tap(_ o: StudiNowErklaerungen.Offer) {
        switch ErklaerungAction.next(for: o) {
        case .open(let local): router.go(.doc(local))
        case .ask: asking = o
        case .fetch:
            busy = true
            Task {
                defer { busy = false }
                do {
                    let local = try await shop.obtain(o, api: session.api)
                    router.reload()
                    router.go(.doc(local))
                } catch { toast.show(error.localizedDescription, seconds: 5) }
            }
        }
    }
}

/// Bestaetigen: Titel, Art, Seitenzahl, Preis, „gehört danach dauerhaft zu dieser Datei“; Kaufen / Abbrechen. Nach dem
/// Kauf liegt die PDF neben der Datei, die Seiten laden neu und sie oeffnet sich. Credits aufgebraucht: Text des
/// Dienstes und das Blatt „Credits kaufen“ wie beim Klausur-Generator.
struct ErklaerungBuySheet: View {
    let offer: StudiNowErklaerungen.Offer
    let close: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufStudoraAccount) private var account
    @State private var busy = false
    @State private var error: String?
    @State private var creditShop = false

    var body: some View {
        UFDialog(ErklaerungText.title, icon: "sparkles") {
            VStack(alignment: .leading, spacing: 8) {
                Text(offer.title).ufFont(15.2, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("erklaerung.buy.title")
                Text(ErklaerungText.kindLine(kind: offer.kind, pages: offer.pages)).ufFont(13.6).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ErklaerungText.price(offer.price)).ufFont(17.6, 700).foregroundStyle(UF.text).monospacedDigit()
                    .accessibilityIdentifier("erklaerung.buy.price")
                if let line = AICost.balanceLine(account?.credits, trial: account?.planStatus?.trialActive ?? false) {
                    Text(line).ufFont(13.12, 600).foregroundStyle(UF.text2)
                }
                Text(ErklaerungText.keep).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).ufFont(13.6, 600).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("erklaerung.buy.error")
                }
            }
        } foot: {
            UFButton(ErklaerungText.cancel, kind: .ghost) { close() }
                .accessibilityIdentifier("erklaerung.buy.cancel")
            UFButton(busy ? ErklaerungText.buying : ErklaerungText.buy, kind: .primary) { Task { await buy() } }
                .disabled(busy)
                .accessibilityIdentifier("erklaerung.buy.go")
        }
        .ufCreditShop(isPresented: $creditShop)
    }

    private func buy() async {
        busy = true
        defer { busy = false }
        do {
            let local = try await StudiNowErklaerungen.shared.obtain(offer, api: session.api)
            await account?.refreshCredits()
            close()
            router.reload()
            router.go(.doc(local))
        } catch let e as APIError {
            if e.code == "credits_exhausted" { creditShop = true }
            error = e.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Im geoeffneten Dokument: schmaler Hinweis oben („Es gibt eine Erklärung von StudiNow“ / gekauft: „Öffnen“), bis zum
/// Schliessen ausblendbar; oeffnet auch das Kauf-Blatt, wenn „Mehr“ darum bittet (`askFor`)
struct ErklaerungDocBanner: View {
    let fileID: String
    let api: APIClient?
    @ObservedObject private var shop = StudiNowErklaerungen.shared
    @ObservedObject private var ent = Entitlements.shared
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var toast: UFToastCenter
    @State private var dismissed = false
    @State private var asking: StudiNowErklaerungen.Offer?

    var body: some View {
        Group {
            if let o = shop.badge(for: fileID), !dismissed {
                HStack(spacing: 10) {
                    UFIcon(o.owned ? "check" : "sparkles", size: 15).foregroundStyle(o.owned ? UF.okText : UF.accentText)
                    Text(o.owned ? ErklaerungText.title : ErklaerungText.hint).font(.caption).bold().lineLimit(1)
                    Button(o.owned ? "Öffnen" : ErklaerungText.look) { act(o) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityIdentifier("erklaerung.doc.go")
                    Button { dismissed = true } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Hinweis ausblenden")
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: fileID) { await shop.load(fileIDs: [fileID], api: api) }
        .onChange(of: shop.askFor) { _, id in
            guard id == fileID else { return }
            shop.askFor = nil
            if let o = shop.badge(for: fileID) { act(o) }
        }
        .ufSheet(item: $asking) { offer in
            ErklaerungBuySheet(offer: offer) { asking = nil }.ufSheetPresentation()
        }
    }

    private func act(_ o: StudiNowErklaerungen.Offer) {
        switch ErklaerungAction.next(for: o) {
        case .open(let local): router.go(.doc(local))
        case .ask: asking = o
        case .fetch:
            Task {
                do { router.go(.doc(try await shop.obtain(o, api: api))) } catch { toast.show(error.localizedDescription, seconds: 5) }
            }
        }
    }
}

/// Eintrag im Menue „Mehr“ des Dokuments (nur mit Angebot)
struct ErklaerungMenuItem: View {
    let fileID: String
    @ObservedObject private var shop = StudiNowErklaerungen.shared

    var body: some View {
        if let o = shop.badge(for: fileID) {
            Button { shop.askFor = fileID } label: {
                Label(o.owned ? ErklaerungText.open : ErklaerungText.menu, systemImage: o.owned ? "checkmark.circle" : "sparkles")
            }
            .accessibilityIdentifier("doc.erklaerung")
        }
    }
}
