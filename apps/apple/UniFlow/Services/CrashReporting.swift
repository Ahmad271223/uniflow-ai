import MetricKit
import os
import SwiftUI
import UIKit
import UniFlowCore

// Absturzmeldung (25.11.2026, docs/ABSTURZMELDUNG-2026-11-25.md): Der Inhaber will sehen, wie viele Abstuerze es je
// Tag, App-Version und Geraeteart gab. Apple gibt der App ueber MetricKit, was auf diesem Geraet passiert ist; die App
// kuerzt das auf wenige Angaben (`MetricKitReports` im Kern) und schickt es beim naechsten Start an den Dienst
// (`POST /api/diagnose/crashes`, app/crash_reports.py).
//
// Ohne Konto: die Meldung geht ohne Anmeldung und ohne Sitzung. Ein Absturz in der Begruessung passiert, bevor es ein
// Konto gibt, und die Zahlen brauchen keinen Bezug zu einer Person.
//
// Schalter: Einstellungen -> Hilfe & Rechtliches -> "Absturzberichte an StudiNow senden". Von selbst AN (wie der
// Datei-Eingang: Grundlage ist der Absatz in der Datenschutzerklaerung, Ausschalten = Widerspruch); AUS loescht die
// wartenden Meldungen und die Kennung der Installation und meldet die App bei MetricKit ab.
// ENTSCHEIDUNG DES INHABERS OFFEN: "von selbst an" (`CrashReportSetting.onByDefault`) und der Datenschutz-Absatz.
//
// Debug-Builds (Xcode, Simulator) und Tests schicken nie etwas (`CrashReporter.buildSends`, XCTest).
// MetricKit liefert nur auf echten Geraeten, meist erst beim naechsten Start oder am Folgetag; im Simulator kommt nie
// etwas an.

enum CrashReportSetting {
    static let key = "studinow.crashReports.v1"
    /// Zufaellige Kennung nur fuer diese Meldungen (nicht die Geraete-Kennung des Kontos): der Dienst begrenzt damit
    /// die Menge je Geraet und Tag und speichert nur einen Tages-HMAC davon. Aus -> geloescht, wieder an -> neue.
    static let installKey = "studinow.crashReports.install"
    /// Ohne Eintrag: an. Diese eine Stelle aendern, wenn der Inhaber "erst fragen" will.
    static let onByDefault = true

    static func isOn(_ d: UserDefaults = .standard) -> Bool { (d.object(forKey: key) as? Bool) ?? onByDefault }

    static func set(_ on: Bool, _ d: UserDefaults = .standard) {
        d.set(on, forKey: key)
        if !on { d.removeObject(forKey: installKey) }
    }

    static func installID(_ d: UserDefaults = .standard) -> String {
        if let s = d.string(forKey: installKey), s.count == 32 { return s }
        let s = CrashReport.newID()
        d.set(s, forKey: installKey)
        return s
    }

    static let cardTitle = "Absturzberichte"
    static let title = "Absturzberichte an StudiNow senden"
    /// Abgeglichen mit dem, was wirklich geht (`CrashReport.json`, app/crash_reports.py)
    static let short = "Stürzt StudiNow ab oder bleibt hängen, schickt die App beim nächsten Start einen kurzen Bericht: App-Version, Gerätemodell, Systemversion, Zeitpunkt und die Stelle im Programm. Ohne deinen Namen, ohne dein Konto und ohne Inhalte aus deinen Dokumenten. Ausschalten geht jederzeit hier."
}

final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()
    static let log = Logger(subsystem: "de.uniflow.ai", category: "crash-report")

    /// Wartende Meldungen: ausserhalb der Datenbereiche der Konten (gilt fuer das Geraet), neben dem Ablauf-Protokoll
    static var file: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Diagnose", isDirectory: true).appendingPathComponent("absturzmeldungen.json")
    }

    /// Schickt dieser Build ueberhaupt? Debug (Xcode, Simulator) nie.
    static var buildSends: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    // Austauschbar fuer Tests
    var defaults: UserDefaults = .standard
    /// automatisch erlaubt (nie im Debug-Build, nie unter XCTest; Tests setzen es)
    var allowed: () -> Bool = { CrashReporter.buildSends && !StudIPSync.isUnderTest() }
    /// Anschluss an den Dienst (nil: keine Dienst-Adresse)
    var client: () -> CrashReportClient? = {
        StudoraAccountLink.serviceURL.map { CrashReportClient(base: $0, http: URLSessionServiceTransport(session: CrashReporter.session, timeout: 30)) }
    }

    /// Eigene Verbindung nur fuer die Meldungen: ohne Cookies, ohne gespeicherte Anmeldungen, ohne Zwischenspeicher.
    /// Der Dienst setzt bei der Anmeldung des Kontos ein Sitzungs-Cookie; ueber `URLSession.shared` ginge es bei jeder
    /// Meldung mit - dann waere "ohne Konto" nicht mehr wahr.
    static let session: URLSession = URLSession(configuration: sessionConfiguration())

    static func sessionConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCredentialStorage = nil
        c.urlCache = nil
        return c
    }
    var outbox = CrashReportOutbox(file: CrashReporter.file)
    /// Bei MetricKit an- und abmelden (Tests: Mitschreiber)
    var subscribe: (MXMetricManagerSubscriber) -> Void = { MXMetricManager.shared.add($0) }
    var unsubscribe: (MXMetricManagerSubscriber) -> Void = { MXMetricManager.shared.remove($0) }

    private let lock = NSLock()
    private var subscribed = false
    private var known: MetricKitReports.Context?

    /// Was die App ueber sich selbst weiss; einmal beim Start ermittelt (Tests setzen es)
    var context: MetricKitReports.Context? {
        get { lock.withLock { known } }
        set { lock.withLock { known = newValue } }
    }

    var isSubscribed: Bool { lock.withLock { subscribed } }

    // MARK: Start und Schalter

    /// Beim Start der App und nach dem Umschalten: an -> bei MetricKit anmelden und Wartendes schicken;
    /// aus -> abmelden, wartende Meldungen und die Kennung der Installation loeschen.
    @MainActor
    func refresh() {
        guard allowed() else { return }
        if CrashReportSetting.isOn(defaults) {
            if context == nil { context = Self.currentContext() }
            let first = lock.withLock { () -> Bool in
                defer { subscribed = true }
                return !subscribed
            }
            if first { subscribe(self) }
            Task { await flush() }
        } else {
            let was = lock.withLock { () -> Bool in
                defer { subscribed = false }
                return subscribed
            }
            if was { unsubscribe(self) }
            CrashReportSetting.set(false, defaults)                           // Kennung der Installation weg
            Task { await outbox.clear() }
        }
    }

    // MARK: Empfang von MetricKit (kommt auf einem Hintergrundfaden)

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let items = payloads.map { ($0.jsonRepresentation(), Self.date($0, "timeStampEnd")) }
        Task { await take(diagnostics: items) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Beginn des Zeitraums (iOS zaehlt von Mitternacht bis Mitternacht): der Tag, an dem es passiert ist
        let items = payloads.map { ($0.jsonRepresentation(), Self.date($0, "timeStampBegin")) }
        Task { await take(metrics: items) }
    }

    /// Zeitstempel eines Pakets, ohne dass ein fehlender Wert die App zu Fall bringt (die Eigenschaft ist als "nie
    /// leer" erklaert; waere sie es doch einmal, stuerzte der direkte Zugriff ab - ausgerechnet im Absturzmelder)
    static func date(_ payload: NSObject, _ key: String) -> Date {
        (payload.value(forKey: key) as? Date) ?? Date()
    }

    /// Diagnose-Pakete (Apples JSON, Zeitstempel des Pakets): kuerzen, merken, schicken
    func take(diagnostics items: [(json: Data, at: Date)]) async {
        guard let context = usableContext() else { return }
        await keep(items.flatMap { MetricKitReports.diagnostics(json: $0.json, at: $0.at, context: context) })
    }

    /// Messwerte-Pakete (Tageszaehlung "von iOS beendet")
    func take(metrics items: [(json: Data, at: Date)]) async {
        guard let context = usableContext() else { return }
        await keep(items.flatMap { MetricKitReports.exits(json: $0.json, at: $0.at, context: context) })
    }

    private func usableContext() -> MetricKitReports.Context? {
        guard allowed(), CrashReportSetting.isOn(defaults) else { return nil }
        return context
    }

    private func keep(_ reports: [CrashReport]) async {
        guard !reports.isEmpty else { return }
        await outbox.add(reports)
        Self.log.info("Absturzmeldung: \(reports.count, privacy: .public) Eintrag/Eintraege von iOS gemerkt")
        await flush()
    }

    /// Wartende Meldungen an den Dienst; liefert, wie viele die Warteschlange verlassen haben
    @discardableResult
    func flush() async -> Int {
        guard allowed(), CrashReportSetting.isOn(defaults), let client = client() else { return 0 }
        guard !(await outbox.pending()).isEmpty else { return 0 }
        return await outbox.flush(install: CrashReportSetting.installID(defaults), client: client)
    }

    // MARK: Angaben der App

    @MainActor
    static func currentContext() -> MetricKitReports.Context {
        let info = Bundle.main.infoDictionary ?? [:]
        let hasProfile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        var debug = false
        #if DEBUG
        debug = true
        #endif
        return MetricKitReports.Context(appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
                                        appBuild: info["CFBundleVersion"] as? String,
                                        deviceClass: deviceClass(isMac: ProcessInfo.processInfo.isiOSAppOnMac, idiom: UIDevice.current.userInterfaceIdiom),
                                        channel: channel(debug: debug, receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent,
                                                         hasProvisioningProfile: hasProfile),
                                        appBinaries: [Bundle.main.executableURL?.lastPathComponent ?? "UniFlow"])
    }

    /// "mac" (Designed for iPad), "ipad" oder "iphone"
    static func deviceClass(isMac: Bool, idiom: UIUserInterfaceIdiom) -> String {
        if isMac { return "mac" }
        return idiom == .pad ? "ipad" : "iphone"
    }

    /// "store" nur fuer die Fassung aus dem App Store. Xcode, Kabel-Fassungen (mit Entwickler-Profil im Bundle) und
    /// TestFlight (Beleg heisst "sandboxReceipt") zaehlen als "test", damit die eigenen Testgeraete die Zahlen der
    /// Nutzer nicht verfaelschen.
    static func channel(debug: Bool, receiptName: String?, hasProvisioningProfile: Bool) -> String {
        if debug || hasProvisioningProfile { return "test" }
        return receiptName == "sandboxReceipt" ? "test" : "store"
    }
}

/// Karte in Einstellungen -> Hilfe & Rechtliches: der Schalter mit einem ehrlichen Satz, was geschickt wird
struct CrashReportCard: View {
    var reporter: CrashReporter = .shared
    @State private var on = CrashReportSetting.isOn()

    var body: some View {
        UFCard {
            UFCardHead(CrashReportSetting.cardTitle, icon: "info")
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(get: { on }, set: { want in
                    CrashReportSetting.set(want, reporter.defaults)
                    on = CrashReportSetting.isOn(reporter.defaults)
                    reporter.refresh()                                        // an: anmelden; aus: Wartendes loeschen
                })) {
                    Text(CrashReportSetting.title).ufFont(14.5, 600).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(UF.accent)
                .accessibilityIdentifier("crashReports.toggle")
                Text(CrashReportSetting.short).ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { on = CrashReportSetting.isOn(reporter.defaults) }
    }
}
