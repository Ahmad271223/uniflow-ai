import Foundation
import Security
import UniFlowCore

/// Woher die Daten kommen: lokales Backend des Geraets (Standard, App Store) oder der eigene UniFlow-Server
/// (nur Entwicklung, Einstellungen -> Entwicklung, nur in Debug-Builds).
enum BackendMode: String {
    case local
    case ownServer
}

/// Datenquelle der App. Im lokalen Modus ist `api` immer gesetzt (lokales Backend, `uniflow-local://device/`);
/// mit eigenem Server: Adresse in UserDefaults, PIN im Schluesselbund. Im Release-Build gibt es nur den lokalen Modus.
@MainActor
final class Session: ObservableObject {
    @Published private(set) var mode: BackendMode = .local
    @Published private(set) var api: APIClient?
    @Published var lastError: String?
    @Published var connecting = false

    nonisolated static let urlKey = "uniflow.serverURL"
    nonisolated static let modeKey = "uniflow.backendMode"
    private let defaults: UserDefaults
    /// lokales Backend des aktiven Containers (Apple-Nutzer, Hochschule); wechselt mit der Hochschule
    private var localAPI: APIClient

    /// Ist der eigene Server in diesem Build erreichbar? (Release: nie)
    static var ownServerAvailable: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    init(local: APIClient = .local(), defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.localAPI = local
        api = local
        #if DEBUG
        // -UFNoServer YES: wie ein App-Store-Nutzer lokal starten, die gespeicherte Verbindung bleibt erhalten
        if defaults.bool(forKey: "UFNoServer") { return }
        // eigener Server nur, wenn er zuletzt gewaehlt war (aeltere Builds kannten keinen Modus: Adresse + PIN genuegen)
        let saved = defaults.string(forKey: Self.modeKey).flatMap(BackendMode.init(rawValue:))
        if saved != .local, let s = defaults.string(forKey: Self.urlKey), let url = URL(string: s), let pin = Keychain.get("uniflow.pin") {
            api = APIClient(base: url, pin: pin)
            mode = .ownServer
        }
        #endif
    }

    /// zuletzt verwendete oder per -UFServerHint vorgetragene Adresse; leer, wenn noch keine bekannt ist
    var savedURL: String { defaults.string(forKey: Self.urlKey) ?? "" }

    var isOwnServer: Bool { mode == .ownServer }

    func connect(urlString: String, pin: String) async {
        lastError = nil
        guard Self.ownServerAvailable else {
            lastError = "Der eigene UniFlow-Server ist nur in Entwicklungsversionen verfügbar."
            return
        }
        connecting = true
        defer { connecting = false }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            lastError = "Ungültige Adresse. Beispiel: http://192.168.0.10:8765"
            return
        }
        let client = APIClient(base: url, pin: pin.trimmingCharacters(in: .whitespaces))
        do {
            let (_, response) = try await client.data("/api/settings")
            switch response.statusCode {
            case 200..<300:
                defaults.set(url.absoluteString, forKey: Self.urlKey)
                defaults.set(BackendMode.ownServer.rawValue, forKey: Self.modeKey)
                Keychain.set(pin, for: "uniflow.pin")
                api = client
                mode = .ownServer
            case 401: lastError = "PIN ist falsch."
            case 429: lastError = "Zu viele falsche PIN-Eingaben. Bitte 10 Minuten warten."
            default: lastError = "Server antwortet mit Status \(response.statusCode)."
            }
        } catch {
            lastError = "Keine Verbindung: \(error.localizedDescription). Läuft Start-iPad.cmd am PC und seid ihr im selben WLAN?"
        }
    }

    /// Anderer Container (Hochschule gewechselt, anderes Konto): ab sofort dessen lokales Backend; mit eigenem Server
    /// (nur Entwicklung) bleibt die Verbindung, das lokale Backend gilt nach "Verbindung trennen"
    func useLocal(_ api: APIClient) {
        guard api !== localAPI else { return }
        localAPI = api
        if mode == .local { self.api = api }
    }

    /// Zurueck zum lokalen Backend (PIN geloescht, Adresse bleibt als Vorschlag)
    func disconnect() {
        api = localAPI
        mode = .local
        defaults.set(BackendMode.local.rawValue, forKey: Self.modeKey)
        Keychain.delete("uniflow.pin")
    }
}

/// Nur Debug-Builds: Startargumente fuer Simulator und UI-Vergleiche.
///   -UFServer http://localhost:8765   verbindet ohne PIN (nur fuer einen lokalen Testserver, der keine PIN verlangt)
///   -UFDisconnect YES -UFServerHint <url>   trennt die Verbindung und traegt die Adresse vor; die PIN gibt der Inhaber ein
///   -UFNoServer YES                   startet lokal (wie im App Store), ohne die gespeicherte PIN zu loeschen
///                                     (Einstellungen -> Entwicklung -> Mit eigenem UniFlow-Server verbinden).
///                                     -UFServer wird dann nicht verbunden, -UFRoute/-UFAction gelten weiter, z. B.
///                                     -UFDisconnect YES -UFRoute "#/settings?tab=dev" zeigt das Verbindungsformular.
///   -UFOnboarding reset               Konto und Merker "Tarifwahl gezeigt" loeschen -> Begruessung wie nach Neuinstallation
///   -UFOnboarding skip                Debug-Konto ohne Apple-ID, Tarifwahl gilt als gezeigt -> direkt die Oberflaeche
///   -UFOnboarding plan                Debug-Konto, Tarifwahl noch nicht gezeigt -> Tarifwahl -> Hochschulwahl
///   -UFOnboarding university          Debug-Konto, Tarifwahl gezeigt, keine Hochschule -> Hochschulwahl
///   -UFOnboarding login               Debug-Konto, Tarifwahl gezeigt, Hochschule aus -UFUniversity (sonst LUH),
///                                     Anmeldeseiten noch nicht gezeigt -> Anmeldeseiten der Hochschule, Erstabgleich
///                                     Ohne -UFOnboarding gilt bei -UFServer/-UFDisconnect/-UFRoute/-UFAction "skip"
///                                     (bisherige Bildvergleiche); "skip" waehlt ohne -UFUniversity die LUH und
///                                     ueberspringt die Anmeldeseiten.
///   -UFLoginStub <ordner>             nur Debug: die Anmeldeansichten laden statt der Seiten der Hochschule lokale
///                                     Nachbildungen aus <ordner> (studip.html, qis.html, learnweb.html, lsf.html;
///                                     "<dienst>-angemeldet.html" gilt als angemeldet) und die Abgleiche antworten aus
///                                     <ordner>/routes.json (DebugUniStub) - nie eine echte Uni-Seite, nie ein Netz
///   -UFUniversity hildesheim          Hochschule des Kontos festlegen (luh|hildesheim), wie nach der Hochschulwahl;
///                                     nur Debug, z. B. fuer Simulator-Ablaeufe mit der Universitaet Hildesheim
///   -UFPlan plus                      fester Tarif ohne Kauf (free|plus|pro_connect|pro_ai, Schluessel wie in
///                                     plans.json), z. B. fuer "Loesung teilen" im Simulator, wo ohne Xcode keine
///                                     StoreKit-Testkonfiguration laeuft; unbekannte Werte gelten nicht
///   -UFRoute "#/plan?view=week"       oeffnet eine Ansicht wie die Hash-Route der Web-App
///   -UFAction "package:26"            oeffnet danach einen Drawer oder Dialog (package:<id>, event:<id>:<datum>,
///                                     add-package, generate, config, availability, event-new, move, task-menu:<id>,
///                                     timer:<stopwatch|countdown|pomodoro>[:run|:pill])
///   -UFNoStudIPSync YES               kein automatischer Stud.IP-Abgleich beim Oeffnen (ebenso bei -UFServer,
///                                     -UFDisconnect, -UFRoute, -UFAction und immer unter XCTest)
/// Die Darstellung laesst sich ueber -theme dark|light|auto setzen (AppStorage liest Startargumente).
enum DebugLaunch {
    /// Tarif aus -UFPlan (nur Debug); nil = Tarif aus StoreKit
    static func forcedPlan(defaults d: UserDefaults = .standard) -> UFPlan? {
        #if DEBUG
        return d.string(forKey: "UFPlan").flatMap(UFPlan.init(rawValue:))
        #else
        return nil
        #endif
    }

    /// Hochschule aus -UFUniversity (nur Debug); nil = Wahl des Nutzers
    static func forcedUniversity(defaults d: UserDefaults = .standard) -> UniversityKey? {
        #if DEBUG
        return d.string(forKey: "UFUniversity").flatMap(UniversityKey.init(rawValue:))
        #else
        return nil
        #endif
    }

    /// vor dem ersten Bild (UniFlowApp.init), damit die Begruessung nicht kurz aufblitzt
    /// Startargumente, bei denen ohne -UFOnboarding die Anmeldung uebersprungen wird
    static let skipTriggers = ["UFServer", "UFDisconnect", "UFRoute", "UFAction"]

    /// `defaults` nur fuer Tests (eigene Suite); in der App liegen die Startargumente in UserDefaults.standard
    @MainActor
    static func prepare(account: AccountStore, defaults d: UserDefaults = .standard) {
        #if DEBUG
        let mode = d.string(forKey: "UFOnboarding")
            ?? (skipTriggers.contains { d.object(forKey: $0) != nil } ? "skip" : nil)
        switch mode {
        case "reset":
            account.deleteAccount()
            account.notice = nil
        case "skip":
            if account.account == nil { account.skipSignInForDebug() }
            account.markPlanShown()
            if account.university == nil { account.chooseUniversity(forcedUniversity(defaults: d) ?? .luh) }
        case "login":
            if account.account == nil { account.skipSignInForDebug() }
            account.markPlanShown()
            account.chooseUniversity(forcedUniversity(defaults: d) ?? .luh)
            account.resetLoginStep()
        case "plan":
            account.deleteAccount()
            account.notice = nil
            account.skipSignInForDebug()
        case "university":
            if account.account == nil { account.skipSignInForDebug() }
            account.markPlanShown()
            account.clearUniversity()
        default: break
        }
        if let u = forcedUniversity(defaults: d), account.account != nil { account.chooseUniversity(u) }
        // "skip" (auch die Bildvergleiche ohne -UFOnboarding): direkt die Oberflaeche, ohne die Anmeldeseiten
        if mode == "skip" { account.markLoginDone() }
        #endif
    }

    @MainActor
    static func apply(session: Session, router: UFRouter, overlay: UFOverlay, toast: UFToastCenter, timer: StudyTimer) async {
        #if DEBUG
        let d = UserDefaults.standard
        let disconnect = d.bool(forKey: "UFDisconnect")
        if disconnect {
            session.disconnect()
            if let hint = d.string(forKey: "UFServerHint") { d.set(hint, forKey: "uniflow.serverURL") }
        }
        if !disconnect, !d.bool(forKey: "UFNoServer"), let server = d.string(forKey: "UFServer"), session.api?.base.absoluteString != server {
            await session.connect(urlString: server, pin: "")
        }
        if let route = d.string(forKey: "UFRoute") { router.go(hash: route) }
        guard let action = d.string(forKey: "UFAction") else { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let a = PlanActions(api: session.api, overlay: overlay, toast: toast, router: router)
        let p = action.split(separator: ":").map(String.init)
        switch p.first {
        case "package": a.openPackage(Int(p[safe: 1] ?? "") ?? 0)
        case "event": a.openEvent(Int(p[safe: 1] ?? "") ?? 0, date: p[safe: 2] ?? UFFmt.todayISO())
        case "add-package": a.addPackage(date: UFFmt.todayISO())
        case "generate": a.generatePlan(UFFmt.todayISO())
        case "config": a.config()
        case "availability": a.availability()
        case "event-new": a.eventDialog(nil)
        case "move": a.move(title: "Aufgabe verschieben") { _ in }
        case "task-menu": overlay.modal { TaskMenuDialog(id: Int(p[safe: 1] ?? "") ?? 0, title: "Aufgabe", refresh: {}) }
        case "free": a.useFreeWindow(date: UFFmt.todayISO(), start: 630, end: 735)
        case "tt-import": overlay.modal { TimetableImportDialog() }
        case "timer":
            timer.toggle(true)
            if let m = StudyTimer.Mode(rawValue: p[safe: 1] ?? "") { timer.setMode(m) }
            if p.contains("run") || p.contains("pill") { timer.startPause() }
            if p.contains("pill") { timer.toggle(false) }
        case "tt-import-ics":
            // ICS aus dem Testbundle/Startargument UFFile, sonst ein kleines Beispiel
            let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Testkurs Physik – Vorlesung\nDTSTART:20261021T081500\nDTEND:20261021T094500\nRRULE:FREQ=WEEKLY\nLOCATION:P 101\nEND:VEVENT\nEND:VCALENDAR\n"
            TimetableImport.run(source: "ics", file: ("test.ics", "text/calendar", Data(ics.utf8)), session: session, overlay: overlay, toast: toast, router: router)
        default: break
        }
        #endif
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Konto (Apple-Benutzerkennung, Name, E-Mail) und Server-PIN im Schluesselbund: eigener Dienst, nur dieses Geraet
/// (`AfterFirstUnlockThisDeviceOnly`, nicht in Backups auf andere Geraete). Eintraege von vor dem 26.10.2026 lagen
/// ohne Dienst und mit Backup; sie ziehen beim ersten Lesen hierher um.
enum Keychain {
    static let store = KeychainStore(service: "de.uniflow.ai.app")

    /// Schreibt den Wert; false, wenn der Schluesselbund ihn nicht annahm (vorher still verworfen)
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        KeychainStore.removeLegacy(account: key)
        return (try? store.write(value, account: key)) != nil
    }

    static func get(_ key: String) -> String? {
        if let v = store.string(key) { return v }
        guard let old = KeychainStore.legacyData(account: key), let v = String(data: old, encoding: .utf8) else { return nil }
        if (try? store.write(old, account: key)) != nil { KeychainStore.removeLegacy(account: key) }
        return v
    }

    static func delete(_ key: String) {
        store.remove(key)
        KeychainStore.removeLegacy(account: key)
    }
}
