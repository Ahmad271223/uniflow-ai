import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import UniFlowCore
import UniformTypeIdentifiers

/// "Freunde einladen" (docs/EINLADUNGEN.md, Entscheidung des Inhabers 04.11.2026): in der Probewoche bis zu 20
/// Einladungslinks `https://studinow.app/i/<CODE>`; gezaehlt wird, wer darueber neu bei StudiNow anfaengt. Belohnungen
/// in Stufen (5/10/20) als Angebotscodes aus App Store Connect, eingeloest in Apples Dialog – die App schaltet nie
/// selbst einen Tarif frei und draengt nicht zum Teilen. Braucht das StudiNow-Konto (`StudoraAccountLink`).
enum InviteTexts {
    static let title = "Freunde einladen"
    static let noAccount = "Einladungen brauchen dein StudiNow-Konto"
    static let noAccountText = UFDevice.adapt("Melde dich beim StudiNow-Konto an. Deine Einladungslinks und Belohnungen hängen am Konto, nicht an diesem iPad.")
    static let intro = "Lade in deiner Probewoche bis zu 20 Leute ein. Es zählt, wer über deinen Link neu bei StudiNow anfängt und sich anmeldet – jede Person einmal, innerhalb von 30 Tagen nach dem Link."
    static let rewards = "Belohnungen sind Angebotscodes für den App Store: du löst sie in Apples Dialog ein. Niemand muss etwas kaufen oder teilen."
    static let newLink = "Neuer Einladungslink"
    static let windowClosed = "Neue Links gibt es nur in der Probewoche. Deine bestehenden Links gelten weiter."
    static let allUsed = "Alle 20 Links sind angelegt."
    static let claim = "Belohnung einlösen"
    static let claimed = "Eingelöst"
    static let reached = "Erreicht"
    static let openApple = "Bei Apple einlösen"
    static let copyCode = "Code kopieren"
    static let copied = "Kopiert."
    static let share = "Teilen"
    static let qr = "QR-Code"
    static let qrHint = "Mit der \(UFDevice.textName)-Kamera scannen: öffnet StudiNow, wenn es installiert ist, sonst die Einladungsseite."
    static let qrAppHint = "Nur für \(UFDevice.textName)s, auf denen StudiNow schon installiert ist (öffnet die App direkt)."
    static let shareText = "Ich nutze StudiNow fürs Studium – Skripte, Stundenplan und Lernkalender auf dem \(UFDevice.textName). Hier ist meine Einladung:"
    static let received = "Einladung gespeichert. Sie zählt, sobald du dein StudiNow-Konto angelegt und dich angemeldet hast."
    static let accepted = "Einladung angenommen – danke!"
    static let alreadyAccepted = "Diese Einladung war schon angenommen."
    static let claimTitle = "Dein Angebotscode"
    static let claimHint = "Apple zeigt dir das Angebot und bucht es auf dein Apple-Konto. StudiNow selbst ändert deinen Tarif nicht."
    static let claimNoURL = "Einlösen: App Store öffnen → dein Profilbild → „Code einlösen“ und den Code eingeben."
    static func counter(_ o: InviteOverview) -> String { InviteRewards.counterText(arrived: o.arrived, max: o.maxLinks) }
    static func nextTier(_ o: InviteOverview) -> String {
        guard let next = InviteRewards.next(after: o.arrived) else { return "Alle Stufen erreicht." }
        let missing = next.count - o.arrived
        return "Noch \(missing) \(missing == 1 ? "Person" : "Personen") bis \(next.count): \(next.rewards[.plus] ?? "")"
    }
    static func redemptions(_ n: Int) -> String { n == 1 ? "1 angekommen" : "\(n) angekommen" }
    static func tierTitle(_ t: InviteOverview.TierState) -> String { "\(t.count) Personen" }
    static func choiceLabel(_ c: InviteRewards.Choice) -> String { c == .plus ? "Plus gratis" : "Pro AI zum Plus-Preis" }
}

/// Die drei Aufrufe der Einladungsseite (App: `StudoraAccount`, Tests: Attrappe)
protocol InviteService: Sendable {
    func invites() async throws -> InviteOverview
    func createInvite() async throws -> InviteOverview
    func claimInvite(tier: Int, choice: InviteRewards.Choice) async throws -> InviteClaim
}

extension StudoraAccount: InviteService {}

/// Zustand der Einladungsseite: ohne Konto der Hinweis, sonst Stand vom Dienst
@MainActor
final class InviteModel: ObservableObject {
    enum State: Equatable {
        case noAccount
        case loading
        case loaded(InviteOverview)
        case failed(String)
    }

    @Published private(set) var state: State
    @Published private(set) var busy = false
    /// Fehler der letzten Aktion (Link anlegen, einloesen)
    @Published var message: String?
    /// zuletzt herausgegebener Angebotscode (Blatt mit Code und Apple-Link)
    @Published var lastClaim: InviteClaim?
    private let service: InviteService?

    init(service: InviteService?, signedIn: Bool) {
        self.service = signedIn ? service : nil
        state = (signedIn && service != nil) ? .loading : .noAccount
    }

    convenience init(link: StudoraAccountLink) {
        self.init(service: link.account, signedIn: link.user != nil)
    }

    var overview: InviteOverview? {
        if case .loaded(let o) = state { return o }
        return nil
    }

    static func text(_ error: Error) -> String {
        (error as? AccountError)?.userMessage ?? error.localizedDescription
    }

    func load() async {
        guard let service else { state = .noAccount; return }
        if overview == nil { state = .loading }
        do { state = .loaded(try await service.invites()) } catch { state = .failed(Self.text(error)) }
    }

    func createLink() async {
        guard let service else { return }
        busy = true
        message = nil
        defer { busy = false }
        do { state = .loaded(try await service.createInvite()) } catch { message = Self.text(error) }
    }

    /// Angebotscode holen; der Stand wird danach neu geladen (Stufe gilt als eingeloest)
    @discardableResult
    func claim(tier: Int, choice: InviteRewards.Choice) async -> InviteClaim? {
        guard let service else { return nil }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let c = try await service.claimInvite(tier: tier, choice: choice)
            lastClaim = c
            await load()
            return c
        } catch {
            message = Self.text(error)
            return nil
        }
    }
}

/// Code eines geoeffneten Einladungslinks, bis das StudiNow-Konto da ist; dann einmal `POST /api/invites/redeem`
enum PendingInvite {
    static let key = "uniflow.invite.pending"

    enum Outcome: Equatable {
        case none            // nichts gespeichert oder noch kein Konto
        case accepted
        case already
        case rejected(String)
        case retryLater
    }

    static func store(_ code: String, defaults: UserDefaults = .standard) { defaults.set(code, forKey: key) }
    static func current(defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: key) }
    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    /// Einmal einloesen, sobald ein angemeldetes Konto da ist. Netz- oder Sitzungsfehler lassen den Code liegen
    /// (naechster Versuch beim naechsten Laden), eine endgueltige Absage (unbekannt, eigener Link, abgelaufen) entfernt ihn.
    static func redeem(using service: InviteRedeeming?, signedIn: Bool, defaults: UserDefaults = .standard) async -> Outcome {
        guard let code = current(defaults: defaults), let service, signedIn else { return .none }
        do {
            let already = try await service.redeemInvite(code: code)
            clear(defaults: defaults)
            return already ? .already : .accepted
        } catch let e as AccountError {
            if e.status == 0 || e.status == 401 || e.status >= 500 || e.status == 429 { return .retryLater }
            clear(defaults: defaults)
            return .rejected(e.userMessage)
        } catch {
            return .retryLater
        }
    }

    static func toast(_ outcome: Outcome) -> String? {
        switch outcome {
        case .none: return InviteTexts.received
        case .accepted: return InviteTexts.accepted
        case .already: return InviteTexts.alreadyAccepted
        case .rejected(let text): return text
        case .retryLater: return nil
        }
    }
}

protocol InviteRedeeming: Sendable {
    @discardableResult
    func redeemInvite(code: String) async throws -> Bool
}

extension StudoraAccount: InviteRedeeming {}

/// QR-Code fuer einen Einladungslink (CoreImage, ohne Netz)
enum InviteQR {
    static func image(_ text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Karte in den Einstellungen

/// Einstellungen → Zugang & Darstellung → "Freunde einladen": kurzer Text und der Weg zur Seite; ohne Konto der Hinweis
struct InviteCard: View {
    @ObservedObject var link: StudoraAccountLink
    @State private var open = false

    var body: some View {
        UFCard {
            UFCardHead(InviteTexts.title, icon: "users")
            if link.user == nil {
                Text(InviteTexts.noAccount).ufFont(14.5, 600).foregroundStyle(UF.text)
                Text(InviteTexts.noAccountText).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("invite.noAccount")
            } else {
                Text(InviteTexts.intro).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                UFButton(InviteTexts.title, icon: "users", size: .small) { open = true }
                    .accessibilityIdentifier("invite.open")
            }
        }
        .sheet(isPresented: $open) { InviteSheet(link: link) }
    }
}

private struct InviteSheet: View {
    @ObservedObject var link: StudoraAccountLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InviteView(model: InviteModel(link: link))
                .navigationTitle(InviteTexts.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

// MARK: - Seite

struct InviteView: View {
    @StateObject var model: InviteModel
    @EnvironmentObject private var toast: UFToastCenter
    @State private var qrLink: InviteOverview.Link?

    init(model: InviteModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.state {
                case .noAccount:
                    UFCard {
                        UFEmpty(icon: "user", text: InviteTexts.noAccount)
                        Text(InviteTexts.noAccountText).ufFont(13.12).foregroundStyle(UF.muted).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("invite.noAccount")
                case .loading:
                    UFCard { ProgressView().frame(maxWidth: .infinity) }
                case .failed(let text):
                    UFCard {
                        Text(text).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                        UFButton("Erneut laden", icon: "refresh", size: .small) { Task { await model.load() } }
                    }
                case .loaded(let o):
                    progress(o)
                    tiers(o)
                    links(o)
                }
                if let m = model.message {
                    Text(m).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("invite.message")
                }
            }
            .padding(16)
        }
        .background(UF.bg)
        .task { await model.load() }
        .sheet(item: Binding(get: { model.lastClaim.map(ClaimItem.init) }, set: { if $0 == nil { model.lastClaim = nil } })) { item in
            ClaimSheet(claim: item.claim)
        }
        .sheet(item: $qrLink) { link in QRSheet(link: link) }
    }

    private func progress(_ o: InviteOverview) -> some View {
        UFCard {
            UFCardHead(InviteTexts.counter(o), icon: "users") {
                if let t = o.tier { UFBadge("Stufe \(t)", tone: .ok) }
            }
            UFProgress(value: Double(o.arrived) / Double(max(1, InviteRewards.tiers.last?.count ?? 20)), ok: o.tier != nil)
            Text(InviteTexts.nextTier(o)).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            Text(InviteTexts.intro).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("invite.progress")
    }

    private func tiers(_ o: InviteOverview) -> some View {
        UFCard {
            UFCardHead("Belohnungen", icon: "star")
            Text(InviteTexts.rewards).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(o.tiers.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { SettingsDivider() }
                    tierRow(t)
                }
            }
        }
    }

    @ViewBuilder private func tierRow(_ t: InviteOverview.TierState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(InviteTexts.tierTitle(t)).ufFont(14.5, 600).foregroundStyle(UF.text)
                    if let c = t.claimed {
                        UFBadge(InviteTexts.claimed, tone: .ok, icon: "check")
                        if t.choices.count > 1 { Text(InviteTexts.choiceLabel(c.choice)).ufFont(12.8).foregroundStyle(UF.muted) }
                    } else if t.reached {
                        UFBadge(InviteTexts.reached, tone: .accent)
                    }
                }
                ForEach(t.choices, id: \.rawValue) { c in
                    Text(t.rewards[c] ?? "").ufFont(13.12).foregroundStyle(t.reached ? UF.text : UF.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let c = t.claimed {
                UFButton(c.redeemURL == nil ? InviteTexts.copyCode : InviteTexts.openApple, size: .small) {
                    model.lastClaim = InviteClaim(tier: t.count, choice: c.choice, offerCode: c.offerCode, reward: t.rewards[c.choice] ?? "",
                                                  redeemURL: c.redeemURL, already: true)
                }
                .accessibilityIdentifier("invite.show.\(t.count)")
            } else if t.claimable {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(t.choices, id: \.rawValue) { c in
                        UFButton(t.choices.count > 1 ? InviteTexts.choiceLabel(c) : InviteTexts.claim, icon: "star", kind: .primary, size: .small) {
                            Task { await model.claim(tier: t.count, choice: c) }
                        }
                        .disabled(model.busy)
                        .accessibilityIdentifier("invite.claim.\(t.count).\(c.rawValue)")
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func links(_ o: InviteOverview) -> some View {
        UFCard {
            UFCardHead("Deine Einladungslinks", icon: "arrow") {
                Text("\(o.links.count) von \(o.maxLinks)").ufFont(12.8).foregroundStyle(UF.muted)
            }
            if o.canCreate {
                UFButton(InviteTexts.newLink, icon: "plus", kind: .primary, size: .small) { Task { await model.createLink() } }
                    .disabled(model.busy)
                    .accessibilityIdentifier("invite.create")
            } else {
                Text(o.links.count >= o.maxLinks ? InviteTexts.allUsed : InviteTexts.windowClosed)
                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("invite.windowClosed")
            }
            if o.links.isEmpty {
                UFEmpty(icon: "users", text: "Noch kein Link. Lege einen an und teile ihn per Nachricht, AirDrop oder QR-Code.", small: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(o.links.enumerated()), id: \.element.id) { i, l in
                        if i > 0 { SettingsDivider() }
                        linkRow(l)
                    }
                }
            }
        }
    }

    private func linkRow(_ l: InviteOverview.Link) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l.code).font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(l.expired ? UF.muted : UF.text)
                    .textSelection(.enabled)
                Text(l.expired ? "Abgelaufen · " + InviteTexts.redemptions(l.redemptions) : InviteTexts.redemptions(l.redemptions))
                    .ufFont(12.8).foregroundStyle(l.redemptions > 0 ? UF.okText : UF.muted)
            }
            Spacer(minLength: 8)
            if !l.expired {
                // Systemblatt: Nachrichten, Mail, AirDrop, Kopieren – nichts davon ist Pflicht
                ShareLink(item: URL(string: l.url) ?? InviteLink.url(code: l.code), subject: Text("Einladung zu StudiNow"),
                          message: Text(InviteTexts.shareText)) {
                    Label(InviteTexts.share, systemImage: "square.and.arrow.up").ufFont(13.12, 500)
                }
                .buttonStyle(UFButtonStyle(size: .small))
                .accessibilityIdentifier("invite.share.\(l.code)")
                UFButton(InviteTexts.qr, icon: "grid", size: .small) { qrLink = l }
                    .accessibilityIdentifier("invite.qr.\(l.code)")
            }
        }
        .frame(minHeight: 48)
        .padding(.vertical, 4)
    }

    private struct ClaimItem: Identifiable {
        let claim: InviteClaim
        var id: String { claim.offerCode }
    }
}

/// Blatt nach "Belohnung einlösen": der Code, Kopieren und Apples Einloese-Dialog (https, Systembrowser/App Store)
private struct ClaimSheet: View {
    let claim: InviteClaim
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                UFIcon("star", size: 32).foregroundStyle(UF.accent)
                Text(claim.reward).ufFont(16, 650).foregroundStyle(UF.text).multilineTextAlignment(.center)
                Text(claim.offerCode).font(.system(size: 28, weight: .bold, design: .monospaced)).foregroundStyle(UF.text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("invite.offerCode")
                Text(claim.redeemURL == nil ? InviteTexts.claimNoURL : InviteTexts.claimHint)
                    .ufFont(13.12).foregroundStyle(UF.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                UFFlexWrap(gap: 9.6, justify: .center) {
                    UFButton(copied ? InviteTexts.copied : InviteTexts.copyCode, icon: "copy", size: .small) {
                        UIPasteboard.general.string = claim.offerCode
                        copied = true
                    }
                    if let url = claim.redeemURL {
                        UFButton(InviteTexts.openApple, icon: "arrow-right", kind: .primary, size: .small) { openURL(url) }
                            .accessibilityIdentifier("invite.openApple")
                    }
                }
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UF.bg)
            .navigationTitle(InviteTexts.claimTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

/// QR-Code eines Links: als Universal Link (Kamera -> App oder Einladungsseite) oder als App-Code uniflow://invite/<CODE>
private struct QRSheet: View {
    let link: InviteOverview.Link
    @Environment(\.dismiss) private var dismiss
    @State private var form = "web"

    private var text: String { form == "app" ? InviteLink.schemeURL(code: link.code).absoluteString : link.url }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let img = InviteQR.image(text) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280)
                        .accessibilityLabel("QR-Code der Einladung \(link.code)")
                }
                Text(link.code).font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(UF.text)
                UFSegmented(options: [("web", "Link"), ("app", "App-Code")], selection: $form)
                Text(form == "app" ? InviteTexts.qrAppHint : InviteTexts.qrHint)
                    .ufFont(13.12).foregroundStyle(UF.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let img = InviteQR.image(text), let data = img.pngData() {
                    ShareLink(item: QRFile(data: data, name: "StudiNow-Einladung-\(link.code).png"), preview: SharePreview("Einladung \(link.code)", image: Image(uiImage: img))) {
                        Label("QR-Code teilen", systemImage: "square.and.arrow.up").ufFont(13.12, 500)
                    }
                    .buttonStyle(UFButtonStyle(size: .small))
                }
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UF.bg)
            .navigationTitle(InviteTexts.qr)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

/// PNG des QR-Codes fuer das Teilen-Blatt (AirDrop, Nachrichten)
private struct QRFile: Transferable {
    let data: Data
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .suggestedFileName { $0.name }
    }
}
