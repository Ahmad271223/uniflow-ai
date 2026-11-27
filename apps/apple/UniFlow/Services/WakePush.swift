import Combine
import Foundation
import os
import UIKit
import UniFlowCore

// Weck-Signal (Auftrag des Inhabers 17.11.2026, "mach das zu 100 %"; docs/WECK-SIGNAL-2026-11-17.md): Der StudiNow-
// Server schickt zwischen 8 und 18 Uhr (Ortszeit des Geraets) alle 30 Minuten eine stille Push-Nachricht
// (`{"aps":{"content-available":1}}`, nichts zu sehen, nichts zu hoeren). Die App wacht kurz auf und gleicht nach der
// Regel ab (`BackgroundSyncController.performWake`: dieselbe Regel 8 bis 18 Uhr, nur faellige Portale, im Zeitlimit von
// iOS). Der Server kennt keine Uni-Passwoerter und erfaehrt nicht, was die App abgleicht.
//
// Hier:
// - Registrierung bei Apple (`registerForRemoteNotifications`, ohne Frage an den Menschen: stille Nachrichten brauchen
//   keine Erlaubnis), solange "Im Hintergrund abgleichen" an ist und ein StudiNow-Konto angemeldet ist
// - Geraete-Token an den Server melden (`PUT /api/account/push-token`: nur Token, Plattform, App-Version, Zeitzone,
//   Umgebung) - nach der Anmeldung, bei jedem Start, bei neuem Token und bei neuer Zeitzone
// - "Im Hintergrund abgleichen" aus: Token am Server loeschen (`DELETE`) und bei Apple abmelden
// - Empfang: nur eine reine Weck-Nachricht (content-available, ohne Text) startet den Lauf
//
// Voraussetzung: Push in der App-ID `de.uniflow.ai` und das Entitlement `aps-environment` (UniFlowPush.entitlements,
// bewusst nicht Standard: solange die App-ID die Faehigkeit nicht hat, braeche es den Build mit Kabel; Abschnitt
// "Einschalten" der Unterlage). Ohne Entitlement meldet iOS einen Fehler bei der Registrierung - harmlos, dann gibt
// es kein Token und kein Weck-Signal.

/// Anschluss an `/api/account/push-token` (Sitzungs-Token des StudiNow-Kontos, nur https)
struct WakePushClient: Sendable {
    let base: String
    let http: ServiceHTTPTransport
    let tokens: AccountTokenStore

    private var url: String { (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/api/account/push-token" }

    /// Meldet das Geraet; true bei 200
    func register(_ r: WakePush.Registration) async -> Bool {
        guard let t = tokens.load() else { return false }
        let body: [String: JSONValue] = ["token": .string(r.token), "platform": .string(r.platform), "app_version": .string(r.appVersion),
                                         "timezone": .string(r.timeZone), "environment": .string(r.environment)]
        let req = AIHTTPRequest(method: "PUT", url: url, headers: ["Accept": "application/json", "Content-Type": "application/json",
                                                                   "Authorization": "Bearer \(t)"],
                                body: JSONValue.object(body).serialized())
        guard let resp = try? await http.send(req) else { return false }
        return resp.status == 200
    }

    /// Nimmt die Meldung zurueck (mit Token genau dieses, sonst das Geraet dieser Sitzung); true bei 200
    func unregister(token: String?) async -> Bool {
        guard let t = tokens.load() else { return false }
        let body = token.map { JSONValue.object(["token": .string($0)]).serialized() }
        var headers = ["Accept": "application/json", "Authorization": "Bearer \(t)"]
        if body != nil { headers["Content-Type"] = "application/json" }
        guard let resp = try? await http.send(AIHTTPRequest(method: "DELETE", url: url, headers: headers, body: body)) else { return false }
        return resp.status == 200
    }
}

@MainActor
final class WakePush {
    static let shared = WakePush()
    static let log = Logger(subsystem: "de.uniflow.ai", category: "wake-push")
    static let tokenKey = "uniflow.wakepush.token"

    /// Was die App dem Server meldet - nichts sonst
    struct Registration: Equatable, Sendable {
        let token: String
        let platform: String
        let appVersion: String
        let timeZone: String
        let environment: String
    }

    // Austauschbar fuer Tests
    /// Anschluss des angemeldeten StudiNow-Kontos (nil: nicht angemeldet, kein Dienst)
    var client: () -> WakePushClient? = { nil }
    /// "Im Hintergrund abgleichen" an?
    var enabled: () -> Bool = { BackgroundSyncSettings(defaults: .standard).enabled }
    /// Bei Apple anmelden bzw. abmelden (Tests: Mitschreiber)
    var registerWithApple: () -> Void = { UIApplication.shared.registerForRemoteNotifications() }
    var unregisterWithApple: () -> Void = { UIApplication.shared.unregisterForRemoteNotifications() }
    var timeZone: () -> TimeZone = { TimeZone.current }
    var defaults: UserDefaults = .standard
    /// automatisch erlaubt (nie unter XCTest; Tests setzen es)
    var allowed: () -> Bool = { !StudIPSync.isUnderTest() }
    /// Lauf nach dem Wecken (die App setzt `BackgroundSyncController.performWake`)
    var onWake: (@MainActor () async -> UIBackgroundFetchResult)?

    /// zuletzt erfolgreich gemeldet (in diesem Prozess; ein neuer Start meldet immer)
    private(set) var reported: Registration?
    /// wann zuletzt gemeldet (in diesem Prozess)
    private(set) var reportedAt: Date?
    /// Unveraendert meldet die App hoechstens so oft erneut, beim Oeffnen bzw. bei der Rueckkehr (26.11.2026, "Abruf
    /// schonen"): der Dienst weckt je Konto nur das zuletzt benutzte Geraet und erkennt es an dieser Meldung
    static let reportAgain: TimeInterval = 3600
    /// Uhr (Tests)
    var now: () -> Date = { Date() }
    private var accountWatch: AnyCancellable?

    /// Letztes Token von Apple (Hex). Kein Geheimnis (nur die Adresse des Geraets bei Apple), steht aber nie im Protokoll.
    var deviceToken: String? {
        get { defaults.string(forKey: Self.tokenKey) }
        set { defaults.set(newValue, forKey: Self.tokenKey) }
    }

    /// Plattform fuer den Server: "ipados", "macos" (Designed for iPad) oder "ios"
    static var platform: String {
        if ProcessInfo.processInfo.isiOSAppOnMac { return "macos" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
    }

    /// "1.0.6 (45)"
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        return String("\(v) (\(b))".prefix(40))
    }

    /// Testbuild aus Xcode: Sandbox von Apple; TestFlight und App Store: production
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Token als Hex (wie Apple es erwartet)
    nonisolated static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Konto beobachten: nach der Anmeldung gleich registrieren
    func attach(account: StudoraAccountLink) {
        client = { [weak account] in account?.wakePushClient }
        accountWatch = account.$user.map { $0 != nil }.removeDuplicates().sink { [weak self] signedIn in
            guard signedIn else { self?.reported = nil; return }
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Beim Start, nach der Anmeldung, beim Umschalten von "Im Hintergrund abgleichen" und bei neuer Zeitzone:
    /// an -> bei Apple registrieren (das Token kommt ueber `received`) und, falls schon bekannt, gleich melden;
    /// aus -> Meldung am Server zuruecknehmen und bei Apple abmelden.
    func refresh() {
        guard allowed() else { return }
        if enabled() {
            guard client() != nil else { return }
            registerWithApple()
            if deviceToken != nil { Task { await report() } }
        } else {
            Task { await withdraw() }
        }
    }

    /// Apple hat ein Token geliefert (bei jedem Start dasselbe oder ein neues)
    func received(token data: Data) async {
        let token = Self.hex(data)
        if deviceToken != token { reported = nil }
        deviceToken = token
        await report()
    }

    /// Meldet das Geraet, wenn sich etwas geaendert hat (Token, Zeitzone, Version) oder in diesem Prozess noch nicht
    /// gemeldet wurde. Rueckgabe: gemeldet.
    @discardableResult
    func report() async -> Bool {
        guard enabled(), let token = deviceToken, let client = client() else { return false }
        let r = Registration(token: token, platform: Self.platform, appVersion: Self.appVersion, timeZone: timeZone().identifier,
                             environment: Self.environment)
        if reported == r, let at = reportedAt, at <= now(), now().timeIntervalSince(at) < Self.reportAgain { return true }
        let ok = await client.register(r)
        if ok { reported = r; reportedAt = now() } else { Self.log.info("Weck-Signal: Meldung beim Dienst nicht angenommen") }
        return ok
    }

    /// "Im Hintergrund abgleichen" aus: Token am Server loeschen und bei Apple abmelden. Rueckgabe: am Server geloescht
    /// (oder nichts zu loeschen).
    @discardableResult
    func withdraw() async -> Bool {
        let token = deviceToken
        unregisterWithApple()
        reported = nil
        guard let client = client() else { return token == nil }
        let ok = await client.unregister(token: token)
        if ok { deviceToken = nil }
        return ok
    }

    /// Ist das eine reine Weck-Nachricht? Nur `aps.content-available == 1`, ohne Text, Ton oder Zahl am Symbol.
    nonisolated static func isWake(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = userInfo["aps"] as? [String: Any] else { return false }
        let flag = (aps["content-available"] as? NSNumber)?.intValue ?? (aps["content-available"] as? Int) ?? 0
        return flag == 1 && aps["alert"] == nil && aps["sound"] == nil && aps["badge"] == nil
    }

    /// Weck-Nachricht empfangen: Abgleich nach der Regel im Zeitlimit von iOS. Alles andere: nichts.
    func handle(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard Self.isWake(userInfo), let onWake else { return .noData }
        return await onWake()
    }
}

/// Empfang von Apple (Token, stille Nachricht). SwiftUI-App: ueber `@UIApplicationDelegateAdaptor` in `UniFlowApp`.
final class StudiNowAppDelegate: NSObject, UIApplicationDelegate {
    private final class Done: @unchecked Sendable {
        let call: (UIBackgroundFetchResult) -> Void
        init(_ call: @escaping (UIBackgroundFetchResult) -> Void) { self.call = call }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await WakePush.shared.received(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // z. B. ohne Entitlement `aps-environment` (App-ID noch ohne Push) oder im Simulator ohne Netz: kein Weck-Signal
        WakePush.log.info("Weck-Signal: keine Registrierung bei Apple (\(error.localizedDescription, privacy: .public))")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let done = Done(completionHandler)
        let wake = WakePush.isWake(userInfo)
        Task { @MainActor in
            done.call(wake ? await WakePush.shared.handle(["aps": ["content-available": 1]]) : .noData)
        }
    }
}
