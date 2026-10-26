import Foundation
import Security

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
    private let localAPI: APIClient

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
///   -UFOnboarding plan                Debug-Konto, Tarifwahl noch nicht gezeigt -> Tarifwahl
///                                     Ohne -UFOnboarding gilt bei -UFServer/-UFDisconnect/-UFRoute/-UFAction "skip"
///                                     (bisherige Bildvergleiche).
///   -UFPlan plus                      fester Tarif ohne Kauf (free|plus), z. B. fuer "Lösung teilen" im Simulator, wo
///                                     ohne Xcode keine StoreKit-Testkonfiguration laeuft
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
        case "plan":
            account.deleteAccount()
            account.notice = nil
            account.skipSignInForDebug()
        default: break
        }
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

/// Minimaler Schluesselbund-Zugriff (generic password).
enum Keychain {
    static func set(_ value: String, for key: String) {
        delete(key)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                    kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}
