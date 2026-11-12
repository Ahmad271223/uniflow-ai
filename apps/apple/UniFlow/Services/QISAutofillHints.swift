import Foundation
import UniFlowCore
import WebKit

/// Autofill auf der QIS-Anmeldeseite (Wunsch des Inhabers 12.11.2026): Das HIS-QIS nennt seine Felder `asdf`
/// (Benutzername) und `fdsa` (Passwort) und sagt nicht, was sie sind; iPadOS bietet den gespeicherten Zugang aus
/// "Passwörter" dort deshalb nicht verlaesslich an. Ein kleines Skript kennzeichnet die beiden Felder:
/// `autocomplete="username"` bzw. `"current-password"`, dazu `autocapitalize="none"`, `autocorrect="off"`,
/// `spellcheck="false"`.
///
/// Was es nie tut: einen Wert lesen oder setzen (kein `.value`), ein Formular absenden, mit der App reden (kein Kanal).
/// Werte setzt hoechstens iOS (Passwort-Autofill nach Tippen des Menschen) oder der bestehende, vom Nutzer erlaubte Weg
/// `UniAutoLogin` (unveraendert). Nur Hauptrahmen, eigene Inhaltswelt, Entscheidung beim Start des Dokuments; nur ueber
/// HTTPS auf dem Rechner des QIS (`QISConnection.qisDomains`) und nur, wenn genau diese beiden Felder da sind und `fdsa`
/// ein Passwortfeld ist. Geprueft in UniversityLoginPolicyTests.
@MainActor
enum QISAutofillHints {
    static let world = WKContentWorld.world(name: "uniflow-qis-autofill")

    /// Quelltext (Rechner als JSON eingesetzt). Kennt nur Attribute, keine Werte.
    static func script(hosts: [String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: hosts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function () {
          'use strict';
          var hosts = \(json);
          var loc = window.location;
          if (loc.protocol !== 'https:' || (loc.port && loc.port !== '443')) return;
          if (hosts.indexOf(String(loc.hostname || '').toLowerCase()) < 0) return;
          function mark(el, kind) {
            el.setAttribute('autocomplete', kind);
            el.setAttribute('autocapitalize', 'none');
            el.setAttribute('autocorrect', 'off');
            el.setAttribute('spellcheck', 'false');
          }
          function apply() {
            var user = document.querySelector('input[name="asdf"]');
            var secret = document.querySelector('input[name="fdsa"]');
            if (!user || !secret || String(secret.type).toLowerCase() !== 'password') return;
            mark(user, 'username');
            mark(secret, 'current-password');
          }
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', apply); else apply();
        })();
        """
    }

    /// Skript in eine Konfiguration (eigene Inhaltswelt, nur Hauptrahmen, Start des Dokuments; kein Kanal)
    static func install(in config: WKWebViewConfiguration, hosts: [String]? = nil) {
        let hosts = hosts ?? QISConnection.qisDomains
        config.userContentController.addUserScript(WKUserScript(source: script(hosts: hosts), injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true, in: world))
    }
}
