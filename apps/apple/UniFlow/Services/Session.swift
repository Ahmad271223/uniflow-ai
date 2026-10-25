import Foundation
import Security

/// Verbindung zum UniFlow-Server: Adresse in UserDefaults, PIN im Schluesselbund.
@MainActor
final class Session: ObservableObject {
    @Published private(set) var api: APIClient?
    @Published var lastError: String?
    @Published var connecting = false

    private let urlKey = "uniflow.serverURL"

    init() {
        if let s = UserDefaults.standard.string(forKey: urlKey), let url = URL(string: s),
           let pin = Keychain.get("uniflow.pin") {
            api = APIClient(base: url, pin: pin)
        }
    }

    var savedURL: String { UserDefaults.standard.string(forKey: urlKey) ?? "http://192.168.0.10:8765" }

    func connect(urlString: String, pin: String) async {
        lastError = nil
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
                UserDefaults.standard.set(url.absoluteString, forKey: urlKey)
                Keychain.set(pin, for: "uniflow.pin")
                api = client
            case 401: lastError = "PIN ist falsch."
            case 429: lastError = "Zu viele falsche PIN-Eingaben. Bitte 10 Minuten warten."
            default: lastError = "Server antwortet mit Status \(response.statusCode)."
            }
        } catch {
            lastError = "Keine Verbindung: \(error.localizedDescription). Läuft Start-iPad.cmd am PC und seid ihr im selben WLAN?"
        }
    }

    func disconnect() {
        api = nil
        Keychain.delete("uniflow.pin")
    }
}

/// Nur Debug-Builds: Startargumente fuer Simulator und UI-Vergleiche.
///   -UFServer http://localhost:8765   verbindet ohne PIN (nur fuer einen lokalen Testserver, der keine PIN verlangt)
///   -UFDisconnect YES -UFServerHint <url>   trennt die Verbindung und traegt die Adresse vor; die PIN gibt der Inhaber ein
///   -UFRoute "#/plan?view=week"       oeffnet eine Ansicht wie die Hash-Route der Web-App
///   -UFAction "package:26"            oeffnet danach einen Drawer oder Dialog (package:<id>, event:<id>:<datum>,
///                                     add-package, generate, config, availability, event-new, move, task-menu:<id>)
/// Die Darstellung laesst sich ueber -theme dark|light|auto setzen (AppStorage liest Startargumente).
enum DebugLaunch {
    @MainActor
    static func apply(session: Session, router: UFRouter, overlay: UFOverlay, toast: UFToastCenter) async {
        #if DEBUG
        let d = UserDefaults.standard
        if d.bool(forKey: "UFDisconnect") {
            session.disconnect()
            if let hint = d.string(forKey: "UFServerHint") { d.set(hint, forKey: "uniflow.serverURL") }
            return
        }
        if let server = d.string(forKey: "UFServer"), session.api?.base.absoluteString != server {
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
