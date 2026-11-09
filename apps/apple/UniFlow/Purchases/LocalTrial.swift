import Foundation
import UniFlowCore

// Probe auf dem iPad ohne Dienst (Entscheidung des Inhabers vom 04.11.2026, docs/ABO-SYSTEM.md Abschnitt 3b; ersetzt
// das Apple-Einfuehrungsangebot "1 Woche gratis" vom 25.10.2026): jede Person bekommt ab dem ersten Start 7 Tage alles
// wie StudiNow Pro AI, ohne Zahlungsdaten, einmal je Apple-ID; danach gilt Free, es sei denn StoreKit meldet Plus oder
// Pro AI. Alles, was in der Probe entsteht, bleibt; gesperrte Funktionen zeigen danach das Schloss mit dem Weg zur
// Tarifwahl. Werte wie plans.TRIAL im Dienst (packages/shared-contracts/fixtures/plans/plans.json, PlanContractTests).
//
// Gespeichert wird nur der Beginn der Probe, geschluesselt mit einem Hash der Apple-Nutzer-ID
// (`DataContainerKey.userScope`): im Schluesselbund dieses Geraets (ueberlebt eine Neuinstallation) und im
// iCloud-Schluessel-Wert-Speicher (zweites iPad derselben Apple-ID). Gelesen werden beide, der fruehere Beginn gilt;
// ohne iCloud zaehlt der Schluesselbund allein. Der Dienst (StudoraAccountLink.planStatus) hat Vorrang, sobald ein
// StudiNow-Konto verbunden ist (UFPlanPrecedence).
//
// Dazu je Geraet hoechstens eine Probe (Inhaber 07.11.2026, "jede iCloud maximal 1 Probe, besser noch jedes Geraet"):
// beim Beginn jeder Probe setzt die App eine Marke im Schluesselbund, die an keiner Apple-ID haengt
// (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, nicht synchronisiert, ueberlebt die Neuinstallation). Eine weitere
// Apple-ID auf demselben iPad bekommt keine neue Probe ("Auf diesem iPad wurde die Probe schon genutzt"). Das Zuruecksetzen
// des Geraets loescht die Marke; staerker waere spaeter Apple DeviceCheck (zwei Bits je Geraet bei Apple, ueberlebt das
// Zuruecksetzen, braucht einen Schluessel und eine Abfrage im StudiNow-Dienst).

enum UFLocalTrial {
    /// Dauer in Tagen und Tarif waehrend der Probe, wie `plans.TRIAL` im Dienst
    static let days = 7
    static let plan: UFPlan = .proAI
    static var length: TimeInterval { TimeInterval(days * 86_400) }

    /// Stand der Probe zu einem Zeitpunkt
    struct State: Equatable {
        let startedAt: Date
        let endsAt: Date
        /// Resttage, aufgerundet wie `billing.trial_info` im Dienst; 0 = vorbei
        let daysLeft: Int

        /// keine eigene Probe: auf diesem Geraet lief schon eine (andere Apple-ID); bleibt vorbei
        var deviceUsed = false

        var isActive: Bool { daysLeft > 0 }
        var isExpired: Bool { !isActive }

        /// Stand zu einer neuen Zeit (Tageswechsel, Vordergrund); "auf diesem Geraet schon genutzt" und eine vorbei
        /// Probe bleiben, wie sie sind (Uhr zurueckgestellt holt sie nicht zurueck, Audit P44-12)
        func updated(now: Date) -> State { deviceUsed || isExpired ? self : UFLocalTrial.state(startedAt: startedAt, now: now) }

        /// "schon genutzt": Beginn der Probe auf diesem Geraet, ohne Resttage
        static func usedOnDevice(since start: Date) -> State {
            State(startedAt: start, endsAt: start, daysLeft: 0, deviceUsed: true)
        }
    }

    /// Stand aus dem Beginn und der aktuellen Zeit (reine Rechnung, Uhr von aussen)
    static func state(startedAt: Date, now: Date) -> State {
        let ends = startedAt.addingTimeInterval(length)
        // Beginn in der Zukunft (Uhr eines anderen Geraets): hoechstens 7 Resttage, nie "noch 372 Tage" (Audit P44-12)
        let left = min(ends.timeIntervalSince(now), length)
        let days = left > 0 ? Int((left + 86_399) / 86_400) : 0
        return State(startedAt: startedAt, endsAt: ends, daysLeft: days)
    }

    /// Welcher Beginn gilt und wo er nachzutragen ist: der fruehere von Schluesselbund und iCloud (eine Neuinstallation
    /// oder ein zweites iPad startet die Probe nicht neu); fehlt beides, beginnt sie jetzt.
    struct Resolution: Equatable {
        let start: Date
        let writeKeychain: Bool
        let writeCloud: Bool
        /// kein frueherer Eintrag: die Probe beginnt mit diesem Aufruf
        let isNew: Bool
    }

    static func resolve(keychain: Date?, cloud: Date?, now: Date) -> Resolution {
        let known = [keychain, cloud].compactMap { $0 }
        let start = known.min() ?? now
        return Resolution(start: start, writeKeychain: keychain != start, writeCloud: cloud != start, isNew: known.isEmpty)
    }

    /// Schluessel je Apple-ID (Hash, nie die ID selbst)
    static func scope(userID: String) -> String { DataContainerKey.userScope(userID) }

    /// Beginn ermitteln bzw. festhalten und den Stand liefern. Eine Apple-ID ohne eigene Probe bekommt keine, wenn auf
    /// diesem Geraet schon eine lief (Geraete-Marke); eine Apple-ID mit Probe behaelt ihren Stand und markiert das Geraet.
    @discardableResult
    static func begin(userID: String, records: any UFTrialRecording, now: Date = Date()) -> State {
        begin(scope: scope(userID: userID), records: records, now: now)
    }

    /// wie `begin(userID:)`, mit dem Schluessel der Apple-ID (Vordergrund, Tageswechsel: `Entitlements.refreshLocalTrial`).
    /// Uhr verstellt (Audit P44-12): ein Beginn in der Zukunft zaehlt ab jetzt und wird so gespeichert (Uhr beim ersten
    /// Start vorgestellt, danach richtig: vorher lief die Probe bis zum falschen Datum plus 7 Tage); ein einmal
    /// gesehenes Ende bleibt (Marke im Schluesselbund), auch wenn die Uhr danach zurueckgestellt wird.
    @discardableResult
    static func begin(scope: String, records: any UFTrialRecording, now: Date = Date()) -> State {
        let known = records.load(scope)
        var r = resolve(keychain: known.keychain, cloud: known.cloud, now: now)
        let device = records.deviceTrialStart()
        if r.isNew, let device { return .usedOnDevice(since: device) }
        if r.start > now { r = Resolution(start: now, writeKeychain: true, writeCloud: true, isNew: r.isNew) }
        if r.writeKeychain || r.writeCloud { records.save(start: r.start, scope: scope, keychain: r.writeKeychain, cloud: r.writeCloud) }
        if device == nil { records.markDeviceTrial(start: r.start) }
        if known.endedSeen { return State(startedAt: r.start, endsAt: r.start.addingTimeInterval(length), daysLeft: 0) }
        let s = state(startedAt: r.start, now: now)
        if s.isExpired { records.markEnded(scope) }
        return s
    }
}

// MARK: - Ablage

/// Gespeicherte Eintraege zu einer Apple-ID
struct UFTrialRecords: Equatable {
    var keychain: Date?
    var cloud: Date?
    /// "Bei Free bleiben" nach dem Ende der Probe wurde schon beantwortet (Hinweis nicht erneut zeigen)
    var choiceMade = false
    /// Ende der Probe wurde schon einmal gesehen: bleibt vorbei, auch mit zurueckgestellter Uhr (Audit P44-12)
    var endedSeen = false
}

/// Ablage des Probe-Beginns (Geraet: Schluesselbund und iCloud; Tests: Speicher)
protocol UFTrialRecording {
    func load(_ scope: String) -> UFTrialRecords
    func save(start: Date, scope: String, keychain: Bool, cloud: Bool)
    func markChoice(_ scope: String)
    /// Ende der Probe gesehen (Schluesselbund, ueberlebt die Neuinstallation)
    func markEnded(_ scope: String)
    /// Beginn der ersten Probe auf diesem Geraet, gleich fuer welche Apple-ID (nil = noch keine)
    func deviceTrialStart() -> Date?
    func markDeviceTrial(start: Date)
}

/// iCloud-Schluessel-Wert-Speicher (NSUbiquitousKeyValueStore), fuer Tests austauschbar
protocol UFCloudKeyValue {
    func number(forKey key: String) -> Double?
    func set(_ value: Double, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UFCloudKeyValue {
    /// nil statt 0, wenn kein Eintrag da ist (`double(forKey:)` liefert dann 0)
    func number(forKey key: String) -> Double? { object(forKey: key) as? Double }
}

/// Ablage auf dem Geraet: Schluesselbund (eigener Dienst, nur dieses Geraet, ueberlebt die Neuinstallation) und der
/// iCloud-Schluessel-Wert-Speicher (braucht die Berechtigung com.apple.developer.ubiquity-kvstore-identifier; ohne sie
/// oder ohne iCloud bleibt der Schluesselbund allein massgeblich). Die Wahl "Bei Free bleiben" liegt in den
/// UserDefaults. Werte: Beginn als Sekunden seit 1970, nie die Apple-ID.
struct UFTrialRecordStore: UFTrialRecording {
    static let service = "de.uniflow.ai.trial"
    /// Geraete-Marke: eigener Dienst und fester Schluessel, an keiner Apple-ID
    static let deviceAccount = "device"
    static func cloudKey(_ scope: String) -> String { "uniflow.trial." + scope }
    static func choiceKey(_ scope: String) -> String { "uniflow.trial.choice." + scope }

    let keychain: KeychainStore
    /// Geraete-Marke (Standard: Dienst des Schluesselbunds + ".device", ThisDeviceOnly, nicht synchronisiert)
    let deviceKeychain: KeychainStore
    let cloud: (any UFCloudKeyValue)?
    let defaults: UserDefaults

    init(keychain: KeychainStore = KeychainStore(service: UFTrialRecordStore.service), deviceKeychain: KeychainStore? = nil,
         cloud: (any UFCloudKeyValue)? = NSUbiquitousKeyValueStore.default, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.deviceKeychain = deviceKeychain ?? KeychainStore(service: keychain.service + ".device")
        self.cloud = cloud
        self.defaults = defaults
    }

    /// Ersatzablage in den UserDefaults, nur wenn der Schluesselbund ein Schreiben ablehnt (Liste 95 Nr. 26, 09.11.2026):
    /// vorher ging der Eintrag dann mit `try?` verloren, und ohne iCloud begann jeder Wechsel in den Vordergrund
    /// (`Entitlements.refreshLocalTrial`) und jeder Start die Probe neu. Die UserDefaults ueberleben keine
    /// Neuinstallation - dagegen schuetzen weiter Schluesselbund und iCloud, sobald sie schreiben.
    static func fallbackKey(service: String, account: String) -> String { "uniflow.trial.fallback.\(service).\(account)" }

    private func write(_ value: String, account: String, in store: KeychainStore) {
        do {
            try store.write(value, account: account)
        } catch {
            defaults.set(value, forKey: Self.fallbackKey(service: store.service, account: account))
        }
    }

    private func read(_ account: String, in store: KeychainStore) -> String? {
        store.string(account) ?? defaults.string(forKey: Self.fallbackKey(service: store.service, account: account))
    }

    func deviceTrialStart() -> Date? {
        read(Self.deviceAccount, in: deviceKeychain).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    func markDeviceTrial(start: Date) {
        write(String(start.timeIntervalSince1970), account: Self.deviceAccount, in: deviceKeychain)
    }

    func load(_ scope: String) -> UFTrialRecords {
        let k = read(scope, in: keychain).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        cloud?.synchronize()
        let c = cloud?.number(forKey: Self.cloudKey(scope)).map { Date(timeIntervalSince1970: $0) }
        // Wahl nach der Probe: UserDefaults oder Schluesselbund (ueberlebt die Neuinstallation, 07.11.2026)
        let choice = defaults.bool(forKey: Self.choiceKey(scope)) || read(Self.choiceAccount(scope), in: keychain) == "1"
        return UFTrialRecords(keychain: k, cloud: c, choiceMade: choice, endedSeen: read(Self.endedAccount(scope), in: keychain) == "1")
    }

    func save(start: Date, scope: String, keychain writeKeychain: Bool, cloud writeCloud: Bool) {
        let value = start.timeIntervalSince1970
        if writeKeychain { write(String(value), account: scope, in: keychain) }
        if writeCloud, let cloud {
            cloud.set(value, forKey: Self.cloudKey(scope))
            cloud.synchronize()
        }
    }

    /// Wahl nach der Probe ("Bei Free bleiben" bzw. Kauf) auch im Schluesselbund: nach einer Neuinstallation erscheint
    /// der Entscheidungs-Bildschirm (TrialDecisionCover) nicht noch einmal
    func markChoice(_ scope: String) {
        defaults.set(true, forKey: Self.choiceKey(scope))
        write("1", account: Self.choiceAccount(scope), in: keychain)
    }

    /// Ende der Probe gesehen: nur im Schluesselbund dieses Geraets (nicht iCloud: ein zweites iPad rechnet selbst)
    func markEnded(_ scope: String) {
        guard read(Self.endedAccount(scope), in: keychain) != "1" else { return }
        write("1", account: Self.endedAccount(scope), in: keychain)
    }

    /// Schluessel der Marke "Ende gesehen" im Schluesselbund (je Apple-ID, Hash)
    static func endedAccount(_ scope: String) -> String { "ended." + scope }

    /// Schluessel der Wahl im Schluesselbund (je Apple-ID, Hash)
    static func choiceAccount(_ scope: String) -> String { "choice." + scope }

    /// nur Tests: Eintraege einer Apple-ID entfernen
    func remove(_ scope: String) {
        keychain.remove(scope)
        keychain.remove(Self.choiceAccount(scope))
        keychain.remove(Self.endedAccount(scope))
        defaults.removeObject(forKey: Self.choiceKey(scope))
        for account in [scope, Self.choiceAccount(scope), Self.endedAccount(scope)] {
            defaults.removeObject(forKey: Self.fallbackKey(service: keychain.service, account: account))
        }
    }

    /// nur Tests: Geraete-Marke entfernen
    func removeDeviceMark() {
        deviceKeychain.remove(Self.deviceAccount)
        defaults.removeObject(forKey: Self.fallbackKey(service: deviceKeychain.service, account: Self.deviceAccount))
    }
}

/// Ablage im Speicher (Tests, Vorschauen)
final class UFMemoryTrialRecords: UFTrialRecording {
    var records: [String: UFTrialRecords] = [:]
    /// iCloud nicht verfuegbar: Schreiben dorthin geht verloren
    var cloudAvailable = true
    /// Geraete-Marke (wie der Schluesselbund: bleibt bei Neuinstallation)
    var device: Date?

    init(keychain: Date? = nil, cloud: Date? = nil, scope: String? = nil) {
        if let scope { records[scope] = UFTrialRecords(keychain: keychain, cloud: cloud) }
    }

    func load(_ scope: String) -> UFTrialRecords { records[scope] ?? UFTrialRecords() }

    func save(start: Date, scope: String, keychain: Bool, cloud: Bool) {
        var r = records[scope] ?? UFTrialRecords()
        if keychain { r.keychain = start }
        if cloud && cloudAvailable { r.cloud = start }
        records[scope] = r
    }

    func markChoice(_ scope: String) {
        var r = records[scope] ?? UFTrialRecords()
        r.choiceMade = true
        records[scope] = r
    }

    func markEnded(_ scope: String) {
        var r = records[scope] ?? UFTrialRecords()
        r.endedSeen = true
        records[scope] = r
    }

    func deviceTrialStart() -> Date? { device }
    func markDeviceTrial(start: Date) { device = start }
}

// MARK: - Vorrang der Quellen

/// Woher der Tarif der App kommt: Dienst (laufende Probe des StudiNow-Kontos) > App Store (gekaufter Tarif aus
/// Transaction.currentEntitlements) > Probe auf dem iPad > Free. Wer Plus kauft, hat Plus; wer Pro AI kauft, Pro AI.
enum UFPlanPrecedence {
    static func effective(service: UFPlan?, purchased: UFPlan, localTrial: UFLocalTrial.State?) -> UFPlan {
        if let service, service != .free { return service }
        if purchased != .free { return purchased }
        if let localTrial, localTrial.isActive { return UFLocalTrial.plan }
        return .free
    }
}

// MARK: - Hinweis auf der Uebersicht

/// Was die Probe-Karte zeigt (TrialBanner), ohne Ansicht: Dienst vor iPad; nach der Probe nur, solange kein Tarif
/// gekauft und "Bei Free bleiben" nicht beantwortet ist
enum UFTrialBannerContent: Equatable {
    enum Source: Equatable { case service, device }
    case running(daysLeft: Int, source: Source)
    case over(source: Source)
    /// keine Probe fuer diese Apple-ID: auf diesem iPad lief schon eine (Geraete-Marke)
    case usedOnDevice

    static func make(service: StudoraAccount.PlanStatus?, local: UFLocalTrial.State?, purchased: UFPlan,
                     choiceMade: Bool) -> UFTrialBannerContent? {
        if let s = service {
            if s.trialActive { return .running(daysLeft: s.trialDaysLeft, source: .service) }
            if s.needsPlanChoice { return .over(source: .service) }
            return nil
        }
        guard let local, purchased == .free else { return nil }
        if local.deviceUsed { return choiceMade ? nil : .usedOnDevice }
        if local.isActive { return .running(daysLeft: local.daysLeft, source: .device) }
        return choiceMade ? nil : .over(source: .device)
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .running(let days, _): return UFTrialTexts.running(days)
        case .over: return UFTrialTexts.overTitle
        case .usedOnDevice: return UFTrialTexts.usedOnDeviceTitle
        }
    }

    var text: String {
        switch self {
        case .running(_, .service): return UFTrialTexts.runningTextService
        case .running: return UFTrialTexts.runningText
        case .over: return UFTrialTexts.overText
        case .usedOnDevice: return UFTrialTexts.usedOnDeviceText
        }
    }
}

// MARK: - Ablauf bei offener App

/// Wann sich der Tarif ohne ein Ereignis von aussen aendert (Audit P44-11): Resttage der Probe (Tageswechsel), Ende der
/// Probe, Ende des Abos bzw. seiner Kulanzfrist. Apple schickt beim Ablauf eines gekuendigten Abos keine Transaktion,
/// die App blieb vorher im Vordergrund im alten Tarif, bis zum naechsten Wechsel in den Vordergrund bzw. Neustart.
enum UFPlanExpiry {
    /// naechster Zeitpunkt nach `now`, nil = keiner
    static func next(localTrial: UFLocalTrial.State?, rightsEnd: Date?, now: Date) -> Date? {
        var at: [Date] = []
        if let t = localTrial, t.isActive, !t.deviceUsed {
            at.append(t.endsAt.addingTimeInterval(-Double(t.daysLeft - 1) * 86_400))
        }
        if let rightsEnd { at.append(rightsEnd) }
        return at.filter { $0 > now }.min()
    }
}
