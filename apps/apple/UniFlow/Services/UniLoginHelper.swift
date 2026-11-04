import Foundation
import UniFlowCore
import WebKit

/// Hilfe auf den Anmeldeseiten der Hochschule (Wunsch des Inhabers 04.11.2026: "beim naechsten Mal direkt angemeldet
/// sein, man muss nicht neu eintippen"). Nur auf den Seiten des Identitaetsanbieters: WebSSO der LUH
/// (sso.idm.uni-hannover.de/idp/...) und CAS der Uni Hildesheim (www.uni-hildesheim.de/sso/login). Nie auf Stud.IP,
/// Learnweb, LSF oder QIS selbst, nie auf fremden Rechnern, nie ueber http.
///
/// Was das kleine Skript dort tut (und sonst nichts):
/// - "Angemeldet bleiben"/"Remember me" ankreuzen, falls die Seite so ein Kaestchen hat (Shibboleth: "Anmeldung nicht
///   speichern" (`donotcache`) bleibt aus; Kaestchen zur Einwilligung werden nie angefasst);
/// - den gemerkten Benutzernamen ins leere Feld des Benutzernamens setzen (`loginname`, `j_username`, `username`);
/// - beim Absenden den Benutzernamen an die App melden, damit er beim naechsten Mal schon dasteht.
///
/// Das Passwortfeld liest, fuellt und beruehrt das Skript nie (es sucht nur Textfelder mit diesen Namen); das Passwort
/// setzt weiter nur iOS ein (Passwort-Autofill, Schluessel-Symbol ueber der Tastatur). Feste Entscheidung des Inhabers
/// (03.11.2026): nie ein Hochschul-Passwort in der App. Der Benutzername ist kein Geheimnis; er liegt nur in den
/// Einstellungen des Containers (UserDefaults-Suite des Apple-Nutzers und der Hochschule, nicht im Schluesselbund) und
/// geht mit "Abmelden" bzw. "Daten dieser Hochschule löschen".
///
/// Das Skript laeuft in einer eigenen Inhaltswelt (`world`): die Seite sieht weder das Skript noch den Kanal zur App.
/// Ob es arbeitet, entscheidet es beim Start des Dokuments (vor jedem Skript der Seite), damit eine Seite desselben
/// Rechners (z. B. eine hochgeladene Learnweb-Datei) ihre Adresse nicht nachtraeglich auf den Anmeldepfad umschreiben
/// kann. Die App nimmt Meldungen nur aus dieser Welt, aus dem Hauptrahmen und von einem Rechner des Anbieters an.
@MainActor
final class UniLoginHelper: NSObject, WKScriptMessageHandler {
    /// Eintrag in den Einstellungen des Containers
    nonisolated static let usernameKey = "uniflow.login.username"
    nonisolated static let handlerName = "uniflowUsername"
    static let world = WKContentWorld.world(name: "uniflow-login-helper")
    /// Felder des Benutzernamens: WebSSO der LUH (`loginname`, Shibboleth-Standard `j_username`), CAS (`username`)
    nonisolated static let userFields = ["loginname", "j_username", "username"]
    nonisolated static let maxUsernameLength = 128

    let university: UniversityKey
    private let defaults: UserDefaults

    init(university: UniversityKey, defaults: UserDefaults) {
        self.university = university
        self.defaults = defaults
    }

    // MARK: Regeln (rein, testbar)

    /// Anmeldeseiten des Identitaetsanbieters einer Hochschule: alle Anmeldeziele des Profils ausser Stud.IP selbst und
    /// dem QIS (eigenes Formular, kein Single Sign-on). LUH: WebSSO /idp/, Hildesheim: CAS /sso/login (mit und ohne www).
    nonisolated static func idpTargets(_ u: UniversityKey) -> [UniversityLoginTarget] {
        let p = u.profile
        let studipHost = p.studipBase?.host?.lowercased()
        return p.loginServices.filter { $0.key != "qis" }.flatMap(\.targets).filter { $0.host != studipHost }
    }

    /// Gilt die Hilfe fuer diese Adresse? Nur HTTPS, genau ein Rechner und Pfad des Anbieters.
    nonisolated static func applies(to url: URL?, university: UniversityKey) -> Bool {
        idpTargets(university).contains { $0.matches(url) }
    }

    /// Taugt der Wert als Benutzername (nicht leer, hoechstens 128 Zeichen, keine Leer- oder Steuerzeichen)?
    nonisolated static func isAcceptableUsername(_ s: String) -> Bool {
        !s.isEmpty && s.count <= maxUsernameLength
            && !s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    /// Wert fuer das Feld des Benutzernamens: der gemerkte, nur wenn das Feld leer ist (nie etwas Eingetipptes ersetzen)
    nonisolated static func prefill(stored: String?, current: String) -> String? {
        guard current.isEmpty, let s = stored, isAcceptableUsername(s) else { return nil }
        return s
    }

    nonisolated static func storedUsername(_ defaults: UserDefaults) -> String? {
        defaults.string(forKey: usernameKey).flatMap { isAcceptableUsername($0) ? $0 : nil }
    }

    /// Benutzernamen merken (getrimmt; Unbrauchbares wird nicht gemerkt). Rueckgabe: gemerkt.
    @discardableResult
    nonisolated static func remember(_ raw: String, defaults: UserDefaults) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAcceptableUsername(v) else { return false }
        defaults.set(v, forKey: usernameKey)
        return true
    }

    /// Abmelden: gemerkten Benutzernamen vergessen
    nonisolated static func forget(defaults: UserDefaults) { defaults.removeObject(forKey: usernameKey) }

    // MARK: Skript

    /// Quelltext des Skripts (Ziele und gemerkter Benutzername als JSON eingesetzt). Erwaehnt das Passwortfeld nicht.
    nonisolated static func script(university: UniversityKey, username: String?) -> String {
        let targets = idpTargets(university).map { ["host": $0.host, "path": $0.pathPrefix] }
        let json = { (v: Any) -> String in
            (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        let known = username.flatMap { isAcceptableUsername($0) ? json($0) : nil } ?? "null"
        return """
        (function () {
          'use strict';
          var targets = \(json(targets));
          var known = \(known);
          var fields = \(json(userFields));
          var loc = window.location;
          if (loc.protocol !== 'https:' || (loc.port && loc.port !== '443')) return;
          var host = String(loc.hostname || '').toLowerCase(), path = String(loc.pathname || ''), hit = false;
          for (var i = 0; i < targets.length; i++) {
            if (host === targets[i].host && path.indexOf(targets[i].path) === 0) { hit = true; break; }
          }
          if (!hit) return;
          var remember = /remember|angemeldet bleiben|eingeloggt bleiben|stay signed|keep me signed|stay logged|keep me logged/i;
          function labelText(box) {
            var t = '';
            if (box.labels) { for (var j = 0; j < box.labels.length; j++) t += ' ' + box.labels[j].textContent; }
            return t;
          }
          function apply() {
            var boxes = document.querySelectorAll('input[type="checkbox"]');
            for (var i = 0; i < boxes.length; i++) {
              var b = boxes[i], key = (b.name || '') + ' ' + (b.id || '');
              if (/donotcache/i.test(key)) { b.checked = false; continue; }
              if (/consent|revoke/i.test(key)) continue;
              if (remember.test(key + ' ' + labelText(b))) b.checked = true;
            }
            var field = null;
            for (var k = 0; k < fields.length && !field; k++) {
              var el = document.querySelector('input[name="' + fields[k] + '"]');
              if (el && (el.type === 'text' || el.type === 'email')) field = el;
            }
            if (!field) return;
            if (known && field.value === '') field.value = known;
            if (field.form) {
              field.form.addEventListener('submit', function () {
                var v = String(field.value || '').trim();
                if (v) { try { window.webkit.messageHandlers.\(handlerName).postMessage(v); } catch (e) {} }
              }, true);
            }
          }
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', apply); else apply();
        })();
        """
    }

    /// Skript und Kanal in eine Konfiguration (eigene Inhaltswelt, nur Hauptrahmen, Start des Dokuments)
    func install(in config: WKWebViewConfiguration) {
        let source = Self.script(university: university, username: Self.storedUsername(defaults))
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        ucc.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    /// Hilfe fuer die Webansichten eines Containers (nur Datenspeicher, die `UniWebSessions` mit Container kennt;
    /// andere, z. B. in Tests, bleiben ohne Skript). Rueckgabe: eingerichtet.
    @discardableResult
    static func install(in config: WKWebViewConfiguration, dataStore: WKWebsiteDataStore) -> Bool {
        guard let ctx = UniWebSessions.loginContext(dataStore) else { return false }
        UniLoginHelper(university: ctx.university, defaults: ctx.defaults).install(in: config)
        return true
    }

    /// Meldung des Skripts: nur aus der eigenen Welt, dem Hauptrahmen und von einem Rechner des Anbieters (HTTPS)
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world == Self.world, message.frameInfo.isMainFrame, let value = message.body as? String else { return }
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol.lowercased() == "https",
              Self.idpTargets(university).contains(where: { $0.host == origin.host.lowercased() }) else { return }
        Self.remember(value, defaults: defaults)
    }
}
