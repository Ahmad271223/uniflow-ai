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
