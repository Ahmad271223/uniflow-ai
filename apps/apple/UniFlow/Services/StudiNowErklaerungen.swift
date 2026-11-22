import SwiftUI
import UniFlowCore

/// Erklaerungen von StudiNow (Auftrag des Inhabers 22.11.2026): Zu einer Kursdatei gibt es ein fertiges PDF
/// „Erklärung Seite für Seite“ bzw. „Lösung Schritt für Schritt“. Pro AI sieht neben der Datei einen kleinen Kreis,
/// kauft einmal fuer 15 Credits, danach gehoert das PDF dauerhaft zur Datei: es liegt in der Bibliothek im Ordner
/// „StudiNow-Erklärungen“ des Moduls, der Kreis traegt ein Haekchen und oeffnet es.
///
/// Angebot, Kauf und Ablage macht der Kern (`ErklaerungShop`, Routen `/api/erklaerungen/*`); hier nur, was die Liste
/// zeigt, der Kauf aus der Oberflaeche und das Abholen von selbst (wie `ExamShopInbox`: Start, andere Datenquelle,
/// Vordergrund, hoechstens einmal je Minute). Ohne Pro AI fragt nichts und nichts ist zu sehen (keine Werbung). Unter
/// XCTest fragt nichts, ausser ein Test setzt `call` bzw. `collectOverride`.
enum ErklaerungText {
    static let title = "Erklärung von StudiNow"
    static let folderName = "StudiNow-Erklärungen"
    static let hint = "Es gibt eine Erklärung von StudiNow"
    static let open = "Erklärung von StudiNow öffnen"
    static let buy = "Kaufen"
    static let buying = "Wird gekauft …"
    static let cancel = "Abbrechen"
    static let menu = "Erklärung von StudiNow …"
    static let look = "Ansehen"
    static let keep = "Gehört danach dauerhaft zu dieser Datei. Du findest sie hier neben der Datei und in der Bibliothek im Ordner „StudiNow-Erklärungen“ dieses Moduls."
    static let notConnected = "Nicht mit dem Gerät verbunden."

    static func price(_ credits: Int) -> String { "\(credits) Credits" }
    static func pages(_ n: Int) -> String { n == 1 ? "1 Seite" : "\(n) Seiten" }

    /// „Erklärung Seite für Seite · 12 Seiten“
    static func kindLine(kind: String, pages: Int) -> String {
        [kind.isEmpty ? nil : kind, pages > 0 ? Self.pages(pages) : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// VoiceOver und Hilfetext des Kreises
    static func badgeLabel(owned: Bool) -> String { owned ? open : hint }

    /// Hinweis nach dem Abholen: „Erklärung von StudiNow ist da: Bibliothek, Modul „Analysis“, Ordner „StudiNow-Erklärungen“.“
    static func notice(_ added: [StudiNowErklaerungen.Added]) -> String? {
        guard !added.isEmpty else { return nil }
        let what = added.count == 1 ? "Erklärung von StudiNow ist da" : "\(added.count) Erklärungen von StudiNow sind da"
        let modules = Set(added.map(\.module).filter { !$0.isEmpty })
        let folder = "Ordner „\(folderName)“"
        if modules.count == 1, let m = modules.first { return "\(what): Bibliothek, Modul „\(m)“, \(folder)." }
        return "\(what): Bibliothek, \(folder) im jeweiligen Modul."
    }
}

@MainActor
final class StudiNowErklaerungen: ObservableObject {
    static let shared = StudiNowErklaerungen()
    static let minInterval: TimeInterval = 60

    /// Angebot zu einer Datei (Antwort von `POST /api/erklaerungen/offer`)
    struct Offer: Equatable, Identifiable {
        var fileID: String
        var sha256: String
        var title: String
        var kind: String
        var pages: Int
        var owned: Bool
        var price: Int
        /// abgelegte PDF auf dem Geraet (nil: noch nicht hier)
        var localFileID: String?
        var id: String { fileID }

        init(fileID: String, sha256: String = "", title: String, kind: String, pages: Int, owned: Bool = false, price: Int = 15,
             localFileID: String? = nil) {
            self.fileID = fileID; self.sha256 = sha256; self.title = title; self.kind = kind; self.pages = pages
            self.owned = owned; self.price = price; self.localFileID = localFileID
        }

        init?(json v: JSONValue) {
            guard let f = v.s("file_id") else { return nil }
            self.init(fileID: f, sha256: v.s("sha256") ?? "", title: v.s("title") ?? "", kind: v.s("kind") ?? "", pages: v.i("pages") ?? 0,
                      owned: v["owned"]?.bool == true, price: v.i("price") ?? 15, localFileID: v.s("local_file_id"))
        }
    }

    /// Neu abgelegt beim Abholen
    struct Added: Equatable {
        var fileID: String
        var localFileID: String
        var module: String
    }

    @Published private(set) var offers: [String: Offer] = [:]
    @Published private(set) var enabled = false
    /// „Mehr“ im Dokument bittet das Banner, das Kauf-Blatt dieser Datei zu oeffnen
    @Published var askFor: String?

    /// Tests: Antwort statt des lokalen Backends, Tarif, Uhr, Abholen
    var call: ((_ path: String, _ body: JSONValue) async throws -> JSONValue)?
    var allowed: () -> Bool = { UFLock.plan(.aiHelp, plan: Entitlements.shared.plan) == nil }
    var now: () -> Date = Date.init
    var collectOverride: (() async -> [Added]?)?

    private weak var router: UFRouter?
    private weak var toast: UFToastCenter?
    private var api: APIClient?
    private var lastCollect: Date?
    private var collecting: Task<[Added]?, Never>?

    /// Kreis an der Datei: nur mit Pro AI, eingeschaltetem Angebot und einem Angebot fuer genau diese Datei
    func badge(for fileID: String) -> Offer? {
        guard allowed(), enabled else { return nil }
        return offers[fileID]
    }

    private func send(_ path: String, _ body: JSONValue, api: APIClient?) async throws -> JSONValue {
        if let call { return try await call(path, body) }
        guard let api else { throw APIError(status: 0, message: ErklaerungText.notConnected, text: ErklaerungText.notConnected) }
        return try await api.value(path, method: "POST", body: body)
    }

    /// Angebot zu den Dateien einer Liste laden (der Kern merkt die Antwort des Dienstes 10 Minuten). Fehler bleiben
    /// still: dann gibt es eben keinen Kreis.
    func load(fileIDs: [String], api: APIClient?) async {
        guard allowed(), !fileIDs.isEmpty else { return }
        if call == nil {
            guard !StudIPSync.isUnderTest(), let api, api.isLocal else { return }
        }
        do {
            let v = try await send("/api/erklaerungen/offer", ["file_ids": .array(fileIDs.map(JSONValue.string))], api: api)
            enabled = v["enabled"]?.bool == true
            var next = offers
            for id in fileIDs { next[id] = nil }
            for item in v.list("items") { if let o = Offer(json: item) { next[o.fileID] = o } }
            if next != offers { offers = next }
        } catch {
            StiftSpur.log("Erklärungen: Angebot nicht geladen \(error.localizedDescription)")
        }
    }

    /// Kaufen (gekauft: kostet nichts mehr) und ablegen; liefert die abgelegte Datei zum Oeffnen
    func obtain(_ offer: Offer, api: APIClient?) async throws -> String {
        let v = try await send("/api/files/\(offer.fileID)/erklaerung/buy", .object([:]), api: api)
        guard let local = v.s("local_file_id") else { throw APIError(status: 502, message: "", text: StudiNowAIText.badAnswer) }
        var o = offers[offer.fileID] ?? offer
        o.owned = true
        o.localFileID = local
        offers[offer.fileID] = o
        return local
    }

    // MARK: Abholen von selbst

    /// Fenster verbinden (MainView, je Datenquelle neu) und einmal nachsehen
    func attach(router: UFRouter, toast: UFToastCenter, api: APIClient?) {
        if self.api?.base != api?.base { lastCollect = nil; offers = [:]; enabled = false }
        self.router = router
        self.toast = toast
        self.api = api
        refreshSoon()
    }

    func refreshSoon(force: Bool = false) { Task { await refresh(force: force) } }

    /// Gekauftes abholen, das noch nicht auf diesem Geraet liegt; nil = nicht gefragt oder Fehler
    @discardableResult
    func refresh(force: Bool = false) async -> [Added]? {
        if StudIPSync.isUnderTest(), collectOverride == nil { return nil }
        guard allowed() else { return nil }
        if let collecting { return await collecting.value }
        if !force, let last = lastCollect, now().timeIntervalSince(last) < Self.minInterval { return nil }
        lastCollect = now()
        let api = self.api, override = collectOverride
        let task = Task { () -> [Added]? in
            if let override { return await override() }
            guard let api, api.isLocal else { return nil }
            do {
                let v = try await api.value("/api/erklaerungen/collect", method: "POST", body: .object([:]))
                return v.list("added").compactMap { a in
                    guard let f = a.s("file_id"), let l = a.s("local_file_id") else { return nil }
                    return Added(fileID: f, localFileID: l, module: a.s("module") ?? "")
                }
            } catch {
                StiftSpur.log("Erklärungen abholen: Fehler \(error.localizedDescription)")
                return nil
            }
        }
        collecting = task
        let out = await task.value
        if collecting == task { collecting = nil }
        if let out, !out.isEmpty {
            StiftSpur.log("Erklärungen abholen: neu \(out.count)")
            for a in out where offers[a.fileID] != nil {
                offers[a.fileID]?.owned = true
                offers[a.fileID]?.localFileID = a.localFileID
            }
            if let text = ErklaerungText.notice(out) { toast?.show(text, seconds: 6) }
            router?.reload()
        }
        return out
    }
}

/// Haengt das Abholen an den Rahmen (MainView), mit denselben Anlaessen wie `ExamShopInboxHost`
struct ErklaerungInboxHost: ViewModifier {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var ent = Entitlements.shared

    func body(content: Content) -> some View {
        content
            .onAppear { StudiNowErklaerungen.shared.attach(router: router, toast: toast, api: session.api) }
            .onChange(of: session.api?.base) { _, _ in StudiNowErklaerungen.shared.attach(router: router, toast: toast, api: session.api) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { StudiNowErklaerungen.shared.refreshSoon() } }
            .onChange(of: ent.plan) { _, _ in StudiNowErklaerungen.shared.refreshSoon() }
    }
}
