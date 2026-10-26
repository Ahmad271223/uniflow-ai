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
/// - Die App prueft jede Nachricht erneut (Inhaltswelt, Hauptrahmen, Herkunft https + Host + Pfad) und bindet sie an
///   die letzte echte Navigation im Hauptrahmen: Die Adresse der Server-Antwort (`WKNavigationResponse`; ohne Antwort
///   die Adresse beim Uebernehmen des Dokuments, nie aus dem Zurueck-Zwischenspeicher) muss ein Anmeldeziel sein, und
///   `webView.url` sowie die Adresse des Rahmens duerfen seitdem nicht per `history.replaceState`/`pushState`
///   geaendert worden sein. Location und Rahmen-Adresse allein reichen nicht:
///   Eine Seite desselben Ursprungs (z. B. eine hochgeladene Learnweb-Datei auf www.uni-hildesheim.de) kann sie ohne
///   Navigation auf den Anmeldepfad umschreiben. Die Grenze ist der Ursprung; der Pfad zaehlt nur zusammen mit dieser
///   Bindung. Die Webansicht meldet dazu ihre Navigationen (`navigationStarts`, `navigationResponds`,
///   `navigationCommitted`); ohne diese Meldungen wird nie etwas vorausgefuellt oder gemerkt.
/// - Verlaesst der Hauptrahmen die Anmeldeseiten, nachdem er dort war, entfernt die App Skript und Kanal fuer den Rest
///   dieser Webansicht (`disarmed`): Inhalte der Hochschule werden nie mit eingebautem Vorausfuellen angezeigt.
/// - Gespeichert wird nur, wenn der Schalter "Auf diesem iPad merken" an ist; dann im Schluesselbund
///   (UniversityCredentialStore).
/// - Vorausfuellen: nach "ready" setzt die App die Felder ueber `callAsyncJavaScript` im selben Rahmen; das Skript
///   prueft Host, Pfad und die Kennung des Dokuments, das "ready" gemeldet hat (nicht eines, das spaeter in denselben
///   Rahmen geladen wurde), und ueberschreibt nichts, was schon eingetippt ist.
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
        /// Nachricht verworfen (falsche Herkunft, Rahmen, Inhalt oder nicht das Dokument der letzten echten Navigation)
        case rejected
        /// Hauptrahmen hat die Anmeldeseiten verlassen: Skript und Kanal entfernt, nichts mehr merken oder vorausfuellen
        case disarmed
    }

    static let worldName = "UniFlowLogin"
    static let handlerName = "uniflowLogin"
    static var world: WKContentWorld { .world(name: worldName) }

    let university: UniversityKey
    let service: UniversityLoginService
    private let store: UniversityCredentialStore
    private weak var controller: WKUserContentController?
    private var script: WKUserScript?

    /// Adresse des Dokuments der zuletzt angezeigten echten Navigation im Hauptrahmen (kein Seitenskript kann sie
    /// aendern); nil zwischen zwei Navigationen und fuer Dokumente aus dem Zurueck-Zwischenspeicher
    private(set) var documentURL: URL?
    /// laufende Navigation im Hauptrahmen: Zurueck/Vor? Adresse der Server-Antwort (falls es eine gab)
    private var pending: (backForward: Bool, response: URL?)?
    /// Hauptrahmen war schon auf einer Anmeldeseite dieses Dienstes
    private var reachedTarget = false
    /// false nach `disarmed`
    private(set) var isArmed = true

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

    /// Name des Dienstes derselben Hochschule, dessen Zugangsdaten ohne eigene vorausgefuellt werden (LUH-QIS:
    /// "Stud.IP"), sonst nil
    var fallbackLoginName: String? {
        service.prefillFallback.flatMap { university.profile.loginService($0)?.name }
    }

    // MARK: Einbau in die Webansicht

    /// Nur in eine reine Anmelde-Webansicht einbauen, deren WKNavigationDelegate die Navigationen meldet.
    func install(into controller: WKUserContentController) {
        let s = WKUserScript(source: Self.captureScript(for: service), injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                             in: Self.world)
        controller.addUserScript(s)
        controller.add(WeakScriptHandler(self), contentWorld: Self.world, name: Self.handlerName)
        self.controller = controller
        script = s
    }

    static func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
    }

    // MARK: Echte Navigationen des Hauptrahmens (aus dem WKNavigationDelegate der Webansicht)

    /// decidePolicyFor navigationAction: eine neue Navigation im Hauptrahmen beginnt; das bisherige Dokument gilt ab
    /// jetzt nicht mehr als Anmeldeseite (auch wenn die Navigation abgebrochen wird).
    func navigationStarts(_ action: WKNavigationAction) {
        navigationStarts(mainFrame: action.targetFrame?.isMainFrame == true, backForward: action.navigationType == .backForward)
    }

    func navigationStarts(mainFrame: Bool, backForward: Bool) {
        guard mainFrame else { return }
        documentURL = nil
        pending = (backForward, nil)
    }

    /// decidePolicyFor navigationResponse: Adresse der Server-Antwort fuer den Hauptrahmen vormerken.
    func navigationResponds(_ response: WKNavigationResponse) {
        navigationResponds(mainFrame: response.isForMainFrame, url: response.response.url)
    }

    func navigationResponds(mainFrame: Bool, url: URL?) {
        guard mainFrame, pending != nil else { return }
        pending?.response = url
    }

    /// didCommit: Das neue Dokument steht.
    func navigationCommitted(in webView: WKWebView) { navigationCommitted(shownURL: webView.url) }

    /// Die Adresse des neuen Dokuments ist die der Server-Antwort (muss mit der angezeigten uebereinstimmen). Ohne
    /// Antwort (loadHTMLString/loadData; die Anmeldeansicht laedt nur aus dem Netz) gilt die angezeigte Adresse in
    /// diesem Moment: Die App verarbeitet die Uebernahme, bevor ein Skript des neuen Dokuments sie umschreiben kann.
    /// Zurueck/Vor ohne Antwort (Zwischenspeicher) und Uebernahmen ohne gemeldeten Beginn bekommen kein Vertrauen; ein
    /// Verlaufseintrag kann eine per replaceState gesetzte Adresse tragen. Hat der Hauptrahmen die Anmeldeseiten
    /// verlassen, nachdem er dort war: Skript und Kanal entfernen.
    func navigationCommitted(shownURL: URL?) {
        let p = pending
        pending = nil
        switch p {
        case let (_, response?)?: documentURL = Self.sameDocument(response, shownURL) ? response : nil
        case (false, nil)?: documentURL = shownURL
        default: documentURL = nil
        }
        if service.allows(documentURL) {
            reachedTarget = true
        } else if reachedTarget {
            disarm()
        }
    }

    /// Danach wird in dieser Webansicht nichts mehr gemerkt oder vorausgefuellt (eine neue Anmeldeansicht baut neu ein).
    private func disarm() {
        guard isArmed else { return }
        isArmed = false
        documentURL = nil
        if let controller {
            // nur das eigene Skript entfernen (eine Entfernung je Skript gibt es nicht): alle weg, fremde wieder hinzu
            let others = controller.userScripts.filter { $0 !== script }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            Self.uninstall(from: controller)
        }
        script = nil
        emit(.disarmed)
    }

    /// Gleiche Adresse ohne Anker (ein Anker wechselt nie Rechner oder Pfad)
    static func sameDocument(_ a: URL?, _ b: URL?) -> Bool {
        func strip(_ u: URL?) -> String? {
            guard let u, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
            c.fragment = nil
            return c.string
        }
        guard let x = strip(a), let y = strip(b) else { return false }
        return x == y
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

    /// Wie `target(for:)`, aber nur fuer das Dokument der letzten echten Navigation: Die Antwort-Adresse ist dasselbe
    /// Ziel, und weder `webView.url` noch die Adresse des Rahmens wurden seitdem im Dokument umgeschrieben.
    func trustedTarget(for frame: WKFrameInfo, in webView: WKWebView?) -> UniversityLoginTarget? {
        guard isArmed, let doc = documentURL, let webView, Self.sameDocument(webView.url, doc),
              Self.sameDocument(frame.request.url, doc), let t = target(for: frame), t.matches(doc) else { return nil }
        return t
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world.name == Self.worldName, let target = trustedTarget(for: message.frameInfo, in: message.webView),
              let body = message.body as? [String: Any], let type = body["type"] as? String else {
            emit(.rejected)
            return
        }
        switch type {
        case "ready":
            guard let doc = body["doc"] as? String, doc.count >= 16 else {
                emit(.rejected)
                return
            }
            emit(.ready)
            fill(message.webView, frame: message.frameInfo, target: target, doc: doc)
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

    private func fill(_ webView: WKWebView?, frame: WKFrameInfo, target: UniversityLoginTarget, doc: String) {
        guard let webView, let c = store.prefillCredential(university, service: service.key) else { return }
        let args: [String: Any] = ["user": c.user, "password": c.password, "host": target.host, "path": target.pathPrefix,
                                   "doc": doc, "userSelectors": service.userSelectors,
                                   "passwordSelectors": service.passwordSelectors]
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
    /// erst beim Absenden durch den Menschen (submit-Ereignis bzw. Klick auf den Absende-Knopf). Die eigentliche
    /// Pruefung macht die App (`trustedTarget`); location allein ist innerhalb desselben Ursprungs faelschbar.
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
          // Kennung dieses Dokuments, nur in dieser Inhaltswelt sichtbar: vorausgefuellt wird nur hier
          var doc = '';
          try {
            var r = new Uint8Array(16);
            window.crypto.getRandomValues(r);
            for (var k = 0; k < r.length; k++) doc += ('0' + r[k].toString(16)).slice(-2);
          } catch (e) { doc = ''; }
          window.__uniflowLoginDoc = doc;
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
          if (doc && ufFields(document, cfg.user, cfg.password)) post({ type: 'ready', doc: doc });
        })();
        """
    }

    /// Koerper fuer `callAsyncJavaScript` (Argumente user, password, host, path, doc, userSelectors, passwordSelectors):
    /// setzt nur leere Felder und gibt true zurueck. Kein Absenden, kein Klick.
    static let fillScript = """
    if (typeof doc !== 'string' || !doc || window.__uniflowLoginDoc !== doc) return false;
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
