import Foundation
import UniFlowCore
import WebKit

/// Merkt sich Benutzername und Passwort auf den bekannten Anmeldeseiten der gewaehlten Hochschule und fuellt sie
/// beim naechsten Oeffnen derselben Seite vor.
///
/// Entscheidung des Inhabers (25.10.2026): NUR vorausfuellen. Die App schickt kein Formular ab, klickt keinen
/// Knopf und loest kein Absenden aus; "Anmelden" tippt immer der Mensch. Einen Weg zum automatischen Anmelden gibt
/// es hier bewusst nicht (auch nicht vorbereitet).
///
/// Ablauf:
/// - Ein Skript in einer eigenen Inhaltswelt (`WKContentWorld` "UniFlowLogin", fuer die Seite unsichtbar) laeuft nur
///   im Hauptrahmen und nur auf `https://<Anmelde-Host><Pfad>` des Profils. Es meldet "ready", wenn ein
///   Passwortfeld da ist, und liest Benutzername und Passwort erst beim Absenden des Formulars.
/// - Die App prueft jede Nachricht erneut (Inhaltswelt, Hauptrahmen, Herkunft https + Host + Pfad). Gespeichert wird
///   nur, wenn der Schalter "Auf diesem iPad merken" an ist; dann im Schluesselbund (UniversityCredentialStore).
/// - Vorausfuellen: nach "ready" setzt die App die Felder ueber `callAsyncJavaScript` im selben Rahmen; das Skript
///   prueft Host und Pfad noch einmal und ueberschreibt nichts, was schon eingetippt ist.
/// Passwoerter werden nie geloggt und nie in Fehlermeldungen oder Adressen verwendet.
@MainActor
final class UniversityLoginAutofill: NSObject, ObservableObject, WKScriptMessageHandler {
    enum Event: Equatable {
        /// Seite mit Anmeldeformular erkannt
        case ready
        /// Felder vorausgefuellt (nicht abgeschickt)
        case filled
        /// beim Absenden gemerkt
        case saved
        /// beim Absenden nicht gemerkt (Schalter aus, leere Felder ...)
        case notSaved
        /// Nachricht verworfen (falsche Herkunft, Rahmen oder Inhalt)
        case rejected
    }

    static let worldName = "UniFlowLogin"
    static let handlerName = "uniflowLogin"
    static var world: WKContentWorld { .world(name: worldName) }

    let university: UniversityKey
    let service: UniversityLoginService
    private let store: UniversityCredentialStore

    /// Schalter "Auf diesem iPad merken" (Standard an); aus = gespeicherte Daten dieses Dienstes sofort entfernen
    @Published var remember: Bool {
        didSet { if remember != oldValue { store.setRemember(remember, university, service: service.key) } }
    }

    /// Ereignisse fuer Tests und Anzeige (nie mit Inhalten)
    var onEvent: ((Event) -> Void)?

    init(university: UniversityKey, service: UniversityLoginService, store: UniversityCredentialStore = .standard) {
        self.university = university
        self.service = service
        self.store = store
        self.remember = store.remember(university, service: service.key)
        super.init()
    }

    /// Fuer einen Dienst des Profils (z. B. `.luh`, "studip"); unbekannte Dienste gibt es nicht.
    convenience init?(university: UniversityKey, serviceKey: String, store: UniversityCredentialStore = .standard) {
        guard let s = university.profile.loginService(serviceKey) else { return nil }
        self.init(university: university, service: s, store: store)
    }

    var hasSavedCredential: Bool { store.hasCredential(university, service: service.key) }

    // MARK: Einbau in die Webansicht

    func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.captureScript(for: service), injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
        controller.add(WeakScriptHandler(self), contentWorld: Self.world, name: Self.handlerName)
    }

    static func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
    }

    // MARK: Nachrichten

    /// Herkunft einer Nachricht: Hauptrahmen, https, bekannter Anmelde-Host und -Pfad dieses Dienstes.
    func target(for frame: WKFrameInfo) -> UniversityLoginTarget? {
        guard frame.isMainFrame else { return nil }
        let origin = frame.securityOrigin
        guard let url = frame.request.url, url.host?.lowercased() == origin.host.lowercased() else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return service.targets.first { $0.matches(scheme: origin.protocol, host: origin.host, port: origin.port, path: path) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world.name == Self.worldName, let target = target(for: message.frameInfo),
              let body = message.body as? [String: Any], let type = body["type"] as? String else {
            emit(.rejected)
            return
        }
        switch type {
        case "ready":
            emit(.ready)
            fill(message.webView, frame: message.frameInfo, target: target)
        case "submit":
            guard remember, let user = body["user"] as? String, let password = body["password"] as? String else {
                emit(.notSaved)
                return
            }
            let c = UniversityCredential(user: user.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            emit(store.save(c, university, service: service.key) ? .saved : .notSaved)
        default:
            emit(.rejected)
        }
    }

    private func fill(_ webView: WKWebView?, frame: WKFrameInfo, target: UniversityLoginTarget) {
        guard let webView, let c = store.credential(university, service: service.key) else { return }
        let args: [String: Any] = ["user": c.user, "password": c.password, "host": target.host, "path": target.pathPrefix,
                                   "userSelectors": service.userSelectors, "passwordSelectors": service.passwordSelectors]
        webView.callAsyncJavaScript(Self.fillScript, arguments: args, in: frame, in: Self.world) { [weak self] result in
            if case .success(let v) = result, (v as? Bool) == true { self?.emit(.filled) }
        }
    }

    private func emit(_ e: Event) { onEvent?(e) }

    // MARK: Skripte

    /// Felder finden: zuerst die Selektoren des Profils, sonst `input[type=password]` und das Text-/E-Mail-Feld
    /// davor. Das Passwortfeld muss wirklich vom Typ password sein (nie ein sichtbares Textfeld befuellen).
    static let fieldsFunction = """
    function ufFields(root, userSel, passSel) {
      function first(list) {
        for (var i = 0; i < list.length; i++) {
          var el = null;
          try { el = root.querySelector(list[i]); } catch (e) { el = null; }
          if (el && el.tagName === 'INPUT') return el;
        }
        return null;
      }
      var pw = first(passSel) || root.querySelector('input[type="password"]');
      if (!pw || String(pw.type).toLowerCase() !== 'password') return null;
      var user = first(userSel);
      var ut = user ? String(user.type).toLowerCase() : '';
      if (!user || (ut !== 'text' && ut !== 'email')) {
        user = null;
        var inputs = (pw.form || document).querySelectorAll('input');
        for (var i = 0; i < inputs.length && inputs[i] !== pw; i++) {
          var t = String(inputs[i].type || 'text').toLowerCase();
          if (t === 'text' || t === 'email') user = inputs[i];
        }
      }
      return user ? { user: user, password: pw } : null;
    }
    """

    /// Laeuft auf jeder Seite der Webansicht, tut aber nur auf den Anmeldeseiten des Dienstes etwas. Liest die Felder
    /// erst beim Absenden durch den Menschen (submit-Ereignis bzw. Klick auf den Absende-Knopf).
    static func captureScript(for service: UniversityLoginService) -> String {
        let cfg: [String: Any] = ["handler": handlerName,
                                  "targets": service.targets.map { ["host": $0.host, "path": $0.pathPrefix] },
                                  "user": service.userSelectors, "password": service.passwordSelectors]
        let json = (try? JSONSerialization.data(withJSONObject: cfg)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        (function () {
          'use strict';
          var cfg = \(json);
          function allowed() {
            if (location.protocol !== 'https:' || (location.port && location.port !== '443')) return false;
            var h = location.hostname.toLowerCase(), p = location.pathname;
            for (var i = 0; i < cfg.targets.length; i++) {
              if (cfg.targets[i].host === h && p.indexOf(cfg.targets[i].path) === 0) return true;
            }
            return false;
          }
          if (window.top !== window || !allowed()) return;
          \(fieldsFunction)
          function post(msg) {
            try { window.webkit.messageHandlers[cfg.handler].postMessage(msg); } catch (e) {}
          }
          function report(root) {
            if (!allowed()) return;
            var f = ufFields(root || document, cfg.user, cfg.password);
            if (!f) return;
            var u = f.user.value, p = f.password.value;
            if (!u || !p) return;
            post({ type: 'submit', user: u, password: p });
          }
          document.addEventListener('submit', function (e) {
            report(e.target && e.target.tagName === 'FORM' ? e.target : null);
          }, true);
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest ? e.target.closest('button, input[type="submit"], input[type="image"]') : null;
            if (!b) return;
            var t = String(b.getAttribute('type') || 'submit').toLowerCase();
            if (t === 'submit' || t === 'image') report(b.form);
          }, true);
          if (ufFields(document, cfg.user, cfg.password)) post({ type: 'ready' });
        })();
        """
    }

    /// Koerper fuer `callAsyncJavaScript` (Argumente user, password, host, path, userSelectors, passwordSelectors):
    /// setzt nur leere Felder und gibt true zurueck. Kein Absenden, kein Klick.
    static let fillScript = """
    if (location.protocol !== 'https:' || (location.port && location.port !== '443')) return false;
    if (location.hostname.toLowerCase() !== host || location.pathname.indexOf(path) !== 0) return false;
    \(fieldsFunction)
    var f = ufFields(document, userSelectors, passwordSelectors);
    if (!f) return false;
    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    function put(el, v) {
      if (el.value) return;
      setter.call(el, v);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    put(f.user, user);
    put(f.password, password);
    return true;
    """
}

/// Haelt den eigentlichen Empfaenger nur schwach (WKUserContentController haelt Handler stark).
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: UniversityLoginAutofill?
    init(_ target: UniversityLoginAutofill) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
