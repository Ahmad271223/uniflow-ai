import Foundation

// Automatisch anmelden (Entscheidung des Inhabers 06.11.2026, ersetzt die vom 03.11.2026): Nach der ersten Anmeldung
// soll niemand mehr gefragt werden (Stud.IP, QIS/LSF, Uni-Mail/SOGo, Moodle, HISinOne/PLuS, Learnweb). Die App darf das
// Hochschul-Passwort merken, aber nur auf diesem Geraet (Schluesselbund, `ThisDeviceOnly`, nie iCloud) und nur, wenn
// der Mensch es beim Anmelden zulaesst; es geht nie an StudiNow-Server oder einen anderen Rechner als die Anmeldeseiten
// der eigenen Hochschule. Hier stehen die reinen Regeln (ohne Netz und WebKit testbar):
//
// - `UniLoginForm`/`UniLoginForms`: die Anmeldeformulare je Hochschule (Rechner, Pfad, Feldnamen, Absende-Knopf). Nur
//   auf diesen Seiten liest die App beim Absenden Benutzername und Passwort mit und nur dort fuellt sie sie wieder ein.
// - `captureScript`/`fillFunctionBody`: die beiden kleinen Seitenskripte (eigene Inhaltswelt). Das Passwort steht nie
//   im Quelltext eines Skripts; beim Einfuellen kommt es als Argument (`callAsyncJavaScript`).
// - `UniAutoLoginMachine`: wann still neu angemeldet wird (abgelaufen -> anmelden -> genau ein neuer Versuch), wann
//   nicht (falsches Passwort, Abmelden, Hintergrund, Ruecknahme nach Fehlschlaegen) - nie eine Schleife.
// Beschreibung fuer Menschen: docs/AUTOMATISCH-ANMELDEN-2026-11-06.md.

/// Ein Anmeldeformular einer Hochschule: genau dieser Rechner (HTTPS, Standard-Port) und Pfad, diese Felder.
public struct UniLoginForm: Sendable, Hashable, Identifiable {
    /// "luh-websso", "luh-qis", "hildesheim-cas" …
    public let id: String
    public let university: UniversityKey
    /// fuer Menschen ("WebSSO der LUH")
    public let name: String
    public let target: UniversityLoginTarget
    /// CSS-Selektoren des Benutzernamens bzw. Passworts (erster sichtbarer Treffer)
    public let userFields: [String]
    public let passwordFields: [String]
    /// Absende-Knopf (erster sichtbarer im Formular; sonst `requestSubmit`)
    public let submitButtons: [String]
    /// Bereiche, deren Felder nie zaehlen (HISinOne: verstecktes Dialogfeld "Sitzung abgelaufen" auf jeder Seite)
    public let ignoredContainers: [String]
    /// Woran der Seiteninhalt das Formular erkennt (Name/ID des Passwortfelds im HTML)
    public let markers: [String]
    /// Texte einer abgelehnten Anmeldung (zusaetzlich zur Regel "nach dem Absenden wieder dasselbe Formular")
    public let failureMarkers: [String]
    /// Feldnamen am echten Formular bzw. in vorhandenem Code bestaetigt (sonst: am Geraet pruefen)
    public let confirmed: Bool
    /// Knoepfe, die ein Mensch zuerst antippt, damit die Felder erscheinen (HISinOne: "Zur Anmeldung" blendet die
    /// Anmeldung ein); hoechstens einmal je Seite, nie ein Absenden
    public let openers: [String]

    public init(id: String, university: UniversityKey, name: String, target: UniversityLoginTarget, userFields: [String],
                passwordFields: [String], submitButtons: [String], ignoredContainers: [String] = [], markers: [String],
                failureMarkers: [String] = [], confirmed: Bool, openers: [String] = []) {
        self.id = id
        self.university = university
        self.name = name
        self.target = target
        self.userFields = userFields
        self.passwordFields = passwordFields
        self.submitButtons = submitButtons
        self.ignoredContainers = ignoredContainers
        self.markers = markers
        self.failureMarkers = failureMarkers
        self.confirmed = confirmed
        self.openers = openers
    }

    /// Gilt das Formular fuer diese Adresse? (HTTPS, Rechner exakt, Pfad-Praefix)
    public func matches(_ url: URL?) -> Bool { target.matches(url) }

    /// Steht das Formular im Seiteninhalt? (eines der Merkmale des Passwortfelds und ein Passwortfeld ueberhaupt)
    public func appears(in html: String) -> Bool {
        let h = html.lowercased()
        guard h.contains("type=\"password\"") || h.contains("type='password'") || h.contains("type=password") else { return false }
        return markers.contains { h.contains($0.lowercased()) }
    }

    /// Zeigt die Seite eine abgelehnte Anmeldung?
    public func showsFailure(in html: String) -> Bool {
        let h = html.lowercased()
        return failureMarkers.contains { h.contains($0.lowercased()) }
    }

    /// Beschreibung fuer die Seitenskripte (keine Geheimnisse)
    public var spec: [String: Any] {
        ["id": id, "host": target.host, "path": target.pathPrefix, "user": userFields, "pass": passwordFields,
         "submit": submitButtons, "hidden": ignoredContainers, "open": openers]
    }
}

public enum UniLoginForms {
    // Felder, wie sie die vorhandenen Abgleiche am PC benutzen (app/studip_sync.py, app/qis.py, app/cas.py,
    // app/sogo.py) bzw. wie die Formulare der Hochschulen aufgebaut sind. "confirmed: false": am Geraet pruefen
    // (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md, Testliste).
    static let hisQISUser = ["input[name=\"asdf\"]", "input#asdf"]
    static let hisQISPassword = ["input[name=\"fdsa\"]", "input#fdsa"]
    static let hisQISSubmit = ["input[type=\"submit\"][name=\"submit\"]", "button[name=\"submit\"]", "input[type=\"submit\"]", "button[type=\"submit\"]"]
    static let hisinoneHidden = ["#sessionTimeoutDialog", "[aria-hidden=\"true\"]"]
    static let sogoUser = ["input[ng-model=\"app.creds.username\"]", "input[name=\"userName\"]", "input#userName", "input[name=\"username\"]"]
    static let sogoPassword = ["input#passwordField", "input[ng-model=\"app.creds.password\"]", "input[name=\"password\"]"]
    static let sogoSubmit = ["button[type=\"submit\"]", "md-button[type=\"submit\"]", "input[type=\"submit\"]"]
    static let sogoMarkers = ["passwordField", "app.creds.password", "name=\"loginForm\""]
    static let generalFailure = ["Benutzername oder Passwort", "Passwort ist falsch", "falsches Passwort", "Anmeldung fehlgeschlagen",
                                 "Login failed", "invalid credentials", "Ungültige Anmeldedaten", "Ungültiger Benutzername"]

    public static let luhWebSSO = UniLoginForm(
        id: "luh-websso", university: .luh, name: "WebSSO der LUH (Stud.IP)",
        target: UniversityLoginTarget(host: UniversityProfile.luhSSOHost, pathPrefix: "/idp/"),
        userFields: ["input[name=\"loginname\"]", "input#loginname", "input[name=\"j_username\"]", "input#username"],
        passwordFields: ["input[name=\"password\"]", "input#password", "input[name=\"j_password\"]"],
        submitButtons: ["button[name=\"_eventId_proceed\"]", "button[type=\"submit\"]", "input[type=\"submit\"]"],
        markers: ["name=\"loginname\"", "name=\"j_password\"", "name=\"password\""],
        failureMarkers: generalFailure + ["output-message", "form-error"], confirmed: true)

    public static let luhQIS = UniLoginForm(
        id: "luh-qis", university: .luh, name: "QIS der LUH",
        target: UniversityLoginTarget(host: "qis.verwaltung.uni-hannover.de", pathPrefix: "/qisserver/"),
        userFields: hisQISUser, passwordFields: hisQISPassword, submitButtons: hisQISSubmit,
        markers: ["name=\"fdsa\"", "id=\"fdsa\""], failureMarkers: generalFailure, confirmed: true)

    public static let luhSOGo = UniLoginForm(
        id: "luh-sogo", university: .luh, name: "Uni-Mail der LUH (SOGo)",
        target: UniversityLoginTarget(host: SOGoSite.luh.host, pathPrefix: "/SOGo"),
        userFields: sogoUser, passwordFields: sogoPassword, submitButtons: sogoSubmit,
        markers: sogoMarkers, failureMarkers: generalFailure + ["Wrong username or password"], confirmed: false)

    public static let hildesheimCAS = UniLoginForm(
        id: "hildesheim-cas", university: .hildesheim, name: "CAS der Uni Hildesheim (Learnweb, LSF, PLuS)",
        target: UniversityLoginTarget(host: "www.uni-hildesheim.de", pathPrefix: "/sso/login"),
        userFields: ["input#username", "input[name=\"username\"]"],
        passwordFields: ["input#password", "input[name=\"password\"]"],
        submitButtons: ["button[name=\"submit\"]", "input[name=\"submit\"]", "button[type=\"submit\"]", "input[type=\"submit\"]"],
        markers: ["name=\"password\"", "id=\"password\""],
        failureMarkers: generalFailure + [HildesheimCAS.errorPanelID], confirmed: true)

    /// dasselbe CAS ohne "www." (`is_cas_page`)
    public static let hildesheimCASBare = UniLoginForm(
        id: "hildesheim-cas-bare", university: .hildesheim, name: hildesheimCAS.name,
        target: UniversityLoginTarget(host: "uni-hildesheim.de", pathPrefix: "/sso/login"),
        userFields: hildesheimCAS.userFields, passwordFields: hildesheimCAS.passwordFields,
        submitButtons: hildesheimCAS.submitButtons, markers: hildesheimCAS.markers,
        failureMarkers: hildesheimCAS.failureMarkers, confirmed: true)

    public static let hildesheimLSF = UniLoginForm(
        id: "hildesheim-lsf", university: .hildesheim, name: "LSF der Uni Hildesheim (eigenes Formular)",
        target: UniversityLoginTarget(host: "lsf.uni-hildesheim.de", pathPrefix: "/qisserver/"),
        userFields: hisQISUser, passwordFields: hisQISPassword, submitButtons: hisQISSubmit,
        markers: ["name=\"fdsa\"", "id=\"fdsa\""], failureMarkers: generalFailure, confirmed: false)

    public static let hildesheimPLuS = UniLoginForm(
        id: "hildesheim-plus", university: .hildesheim, name: "PLuS der Uni Hildesheim (eigenes Formular)",
        target: UniversityLoginTarget(host: "plus.uni-hildesheim.de", pathPrefix: "/qisserver/"),
        userFields: hisQISUser, passwordFields: hisQISPassword, submitButtons: hisQISSubmit,
        ignoredContainers: hisinoneHidden, markers: ["name=\"fdsa\"", "id=\"fdsa\""], failureMarkers: generalFailure,
        confirmed: false)

    public static let hildesheimSOGo = UniLoginForm(
        id: "hildesheim-sogo", university: .hildesheim, name: "Uni-Mail der Uni Hildesheim (SOGo)",
        target: UniversityLoginTarget(host: SOGoSite.hildesheim.host, pathPrefix: "/SOGo"),
        userFields: sogoUser, passwordFields: sogoPassword, submitButtons: sogoSubmit,
        markers: sogoMarkers, failureMarkers: generalFailure + ["Wrong username or password"], confirmed: false)

    public static let hshMoodle = UniLoginForm(
        id: "hsh-moodle", university: .hsh, name: "Moodle der HsH",
        target: UniversityLoginTarget(host: UniversityProfile.hshMoodle.host ?? "moodle.hs-hannover.de", pathPrefix: "/login/"),
        userFields: ["input#username", "input[name=\"username\"]"], passwordFields: ["input#password", "input[name=\"password\"]"],
        submitButtons: ["button#loginbtn", "input#loginbtn", "button[type=\"submit\"]", "input[type=\"submit\"]"],
        markers: ["name=\"password\"", "id=\"password\""],
        failureMarkers: generalFailure + ["loginerrormessage", "Ungültige Anmeldedaten"], confirmed: true)

    public static let hshIdP = UniLoginForm(
        id: "hsh-idp", university: .hsh, name: "SSO der HsH (Campusmanagement)",
        target: UniversityLoginTarget(host: UniversityProfile.hshIdPHost, pathPrefix: "/simplesaml/"),
        userFields: ["input#username", "input[name=\"username\"]"], passwordFields: ["input#password", "input[name=\"password\"]"],
        // echter Aufbau (07.11.2026 ohne Anmeldung gelesen): form#f, input#username/#password, ein <button> ohne type
        // ("Login", onclick: this.form.submit()); daher auch "form#f button"
        submitButtons: ["button#submit_button", "button#regularsubmit", "button[type=\"submit\"]", "input[type=\"submit\"]",
                        "form#f button", "form[name=\"f\"] button"],
        markers: ["name=\"password\"", "id=\"password\""],
        failureMarkers: generalFailure + ["Incorrect username or password", "Falscher Benutzername oder Passwort"], confirmed: true)

    /// Seit 07.11.2026 der Standardweg der HsH (der IdP zeigte auf jede SAML-Anfrage des Campusmanagements nur seine
    /// Fehlerseite): Anmeldung auf der Startseite von HISinOne mit dem SSO-Account (asdf/fdsa). Schmal steht das Formular
    /// `#mobileLoginForm` da, breit blendet "Zur Anmeldung" (`…:overlayShowButton`, JSF-Ajax) es ein.
    public static let hshCampus = UniLoginForm(
        id: "hsh-campus", university: .hsh, name: "Campusmanagement der HsH (eigenes Formular)",
        target: UniversityLoginTarget(host: UniversityProfile.hshCampus.host ?? "campusmanagement.hs-hannover.de", pathPrefix: "/qisserver/"),
        userFields: hisQISUser, passwordFields: hisQISPassword, submitButtons: hisQISSubmit,
        ignoredContainers: hisinoneHidden, markers: ["name=\"fdsa\"", "id=\"fdsa\""], failureMarkers: generalFailure,
        confirmed: true, openers: ["button[id$=\"overlayShowButton\"]", "button.login_overlay_button"])

    public static let all: [UniLoginForm] = [luhWebSSO, luhQIS, luhSOGo, hildesheimCAS, hildesheimCASBare, hildesheimLSF,
                                             hildesheimPLuS, hildesheimSOGo, hshMoodle, hshIdP, hshCampus]

    /// Formulare einer Hochschule (eine Zugangskennung fuer alle: LUH-ID, UNI-Account, SSO-Account)
    public static func forms(_ u: UniversityKey) -> [UniLoginForm] { all.filter { $0.university == u } }

    /// Formular zu dieser Adresse an dieser Hochschule; nil auf jedem anderen Rechner (auch einer anderen Hochschule)
    public static func form(for url: URL?, university: UniversityKey) -> UniLoginForm? {
        forms(university).first { $0.matches(url) }
    }

    /// Rechner, auf denen Anmeldedaten dieser Hochschule je eingefuellt oder mitgelesen werden
    public static func hosts(_ u: UniversityKey) -> Set<String> { Set(forms(u).map(\.target.host)) }

    /// Darf eine Meldung des Mitleseskripts aus diesem Rahmen kommen? Nur HTTPS, genau ein Formular-Rechner und -Pfad.
    public static func allowsCapture(scheme: String?, host: String?, port: Int?, path: String, university: UniversityKey) -> Bool {
        forms(university).contains { $0.target.matches(scheme: scheme, host: host, port: port, path: path) }
    }

    // MARK: Werte

    public static let maxUsernameLength = 128
    public static let maxPasswordLength = 256

    /// Taugt das als Benutzername (nicht leer, hoechstens 128 Zeichen, keine Leer- oder Steuerzeichen)?
    public static func isAcceptableUsername(_ s: String) -> Bool {
        !s.isEmpty && s.count <= maxUsernameLength
            && !s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    /// Taugt das als Passwort (nicht leer, hoechstens 256 Zeichen, keine Steuerzeichen; Leerzeichen erlaubt)?
    public static func isAcceptablePassword(_ s: String) -> Bool {
        !s.isEmpty && s.count <= maxPasswordLength && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    // MARK: Seitenskripte

    static func json(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Mitleseskript (Start des Dokuments, nur Hauptrahmen, eigene Inhaltswelt): nur auf einem Formular der Hochschule;
    /// beim Absenden (Formular, Absende-Knopf, Eingabetaste im Passwortfeld) meldet es Benutzername und Passwort genau
    /// dieses Formulars an `handler`. Sonst liest es nichts und veraendert nichts an der Seite.
    public static func captureScript(university: UniversityKey, handler: String) -> String {
        let specs = forms(university).map(\.spec)
        return """
        (function () {
          'use strict';
          var forms = \(json(specs));
          var loc = window.location;
          if (loc.protocol !== 'https:' || (loc.port && loc.port !== '443')) return;
          var host = String(loc.hostname || '').toLowerCase(), path = String(loc.pathname || ''), spec = null;
          for (var i = 0; i < forms.length; i++) {
            if (host === forms[i].host && path.indexOf(forms[i].path) === 0) { spec = forms[i]; break; }
          }
          if (!spec) return;
          function ignored(el) {
            for (var k = 0; k < spec.hidden.length; k++) { if (el.closest && el.closest(spec.hidden[k])) return true; }
            return false;
          }
          function pick(list, root) {
            for (var j = 0; j < list.length; j++) {
              var els = (root || document).querySelectorAll(list[j]);
              for (var n = 0; n < els.length; n++) { if (!ignored(els[n])) return els[n]; }
            }
            return null;
          }
          var last = 0;
          function report(root) {
            var p = pick(spec.pass, root), u = pick(spec.user, root);
            if (!p || !u || String(p.type || '').toLowerCase() !== 'password') return;
            var pv = String(p.value || ''), uv = String(u.value || '').trim();
            if (!pv || !uv || Date.now() - last < 800) return;
            last = Date.now();
            try { window.webkit.messageHandlers.\(handler).postMessage({ user: uv, pass: pv, form: spec.id }); } catch (e) {}
          }
          document.addEventListener('submit', function (e) { report(e.target && e.target.querySelectorAll ? e.target : null); }, true);
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest ? e.target.closest('button, input[type="submit"], md-button') : null;
            if (b && String(b.getAttribute('type') || (b.tagName === 'BUTTON' ? 'submit' : '')).toLowerCase() === 'submit') report(b.form || null);
          }, true);
          document.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' && e.target && String(e.target.type || '').toLowerCase() === 'password') report(e.target.form || null);
          }, true);
        })();
        """
    }

    /// Rumpf der Funktion zum Einfuellen und Absenden (`callAsyncJavaScript`, Argumente `spec`, `user`, `pass`; das
    /// Passwort steht nie im Quelltext). Prueft zuerst Rechner und Pfad der Seite selbst. Rueckgabe: "submitted",
    /// "nofield" (Formular nicht sichtbar, z. B. schon angemeldet), "opened" (Knopf "Zur Anmeldung" einmal angetippt,
    /// gleich noch einmal versuchen) oder "host" (falsche Seite: nichts eingefuellt).
    public static let fillFunctionBody = """
    var loc = window.location;
    if (loc.protocol !== 'https:' || (loc.port && loc.port !== '443')) return 'host';
    var host = String(loc.hostname || '').toLowerCase();
    if (host !== spec.host || String(loc.pathname || '').indexOf(spec.path) !== 0) return 'host';
    function ignored(el) {
      for (var k = 0; k < spec.hidden.length; k++) { if (el.closest && el.closest(spec.hidden[k])) return true; }
      return false;
    }
    function shown(el) {
      if (!el || el.disabled || ignored(el)) return false;
      var st = window.getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden') return false;
      return el.getClientRects().length > 0;
    }
    function first(list, root) {
      for (var j = 0; j < list.length; j++) {
        var els = (root || document).querySelectorAll(list[j]);
        for (var n = 0; n < els.length; n++) { if (shown(els[n])) return els[n]; }
      }
      return null;
    }
    var u = first(spec.user), p = first(spec.pass);
    if (!u || !p) {
      var o = first(spec.open || []);
      if (o && !window.__studinowOpened) { window.__studinowOpened = true; o.click(); return 'opened'; }
      return 'nofield';
    }
    if (String(p.type || '').toLowerCase() !== 'password') return 'nofield';
    if (u.form && p.form && u.form !== p.form) return 'nofield';
    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    function put(el, v) {
      el.focus();
      setter.call(el, v);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    put(u, user);
    put(p, pass);
    var boxes = (p.form || document).querySelectorAll('input[type="checkbox"]');
    for (var b = 0; b < boxes.length; b++) {
      var key = (boxes[b].name || '') + ' ' + (boxes[b].id || '');
      if (/donotcache|consent|revoke/i.test(key)) continue;
      if (/remember|angemeldet bleiben|rememberLogin/i.test(key)) boxes[b].checked = true;
    }
    var btn = first(spec.submit, p.form || document);
    if (btn) { btn.click(); return 'submitted'; }
    if (p.form) { if (p.form.requestSubmit) p.form.requestSubmit(); else p.form.submit(); return 'submitted'; }
    return 'nofield';
    """
}

// MARK: - Ablauf der stillen Anmeldung (unsichtbare Webansicht)

/// Ergebnis einer stillen Neuanmeldung
public enum UniAutoLoginOutcome: Equatable, Sendable {
    /// angemeldet (Erfolgsseite des Dienstes erreicht)
    case success
    /// die Hochschule hat das gespeicherte Passwort abgelehnt: Formular (Feldnamen bestaetigt) nach dem Absenden wieder
    /// da UND mit Fehlertext der Seite (`UniLoginForm.showsFailure`). Nur dann wird der Eintrag vergessen.
    case wrongPassword
    /// Zeitueberschreitung, kein Netz, Seite ohne bekanntes Formular
    case failed
    /// eine Weiterleitung wollte auf einen fremden Rechner: abgebrochen, nichts eingefuellt
    case blocked
}

/// Schritt der unsichtbaren Webansicht nach einer fertig geladenen Seite (rein, testbar)
public enum UniAutoLoginStep: Equatable, Sendable {
    /// Erfolgsseite: fertig
    case done
    /// Formular dieser Hochschule: einfuellen und absenden
    case fill(UniLoginForm)
    /// Formular nach dem eigenen Absenden wieder da, mit Fehlertext der Seite: Passwort abgelehnt
    case rejected
    /// Formular nach dem eigenen Absenden wieder da, aber ohne Fehlertext (oder unbestaetigtes Formular, oder schon
    /// `maxSubmits` Formulare): abbrechen wie eine Zeitueberschreitung (`.failed`), das Passwort bleibt (11.11.2026)
    case giveUp
    /// fremder Rechner oder http: abbrechen
    case abort
    /// weiter warten (Weiterleitung, Zwischenseite)
    case wait
}

/// Wie viele Formulare eine stille Anmeldung hoechstens absendet (SSO-Ketten: Dienst -> IdP; nie mehr)
public enum UniAutoLoginFlow {
    public static let maxSubmits = 3

    /// Gehoert die Adresse zur Hochschule (registrierbare Domain, HTTPS, Standard-Port) oder ist sie about:blank?
    public static func allowed(_ url: URL?, domains: [String]) -> Bool {
        guard let url else { return true }
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        if let p = url.port, p != 443 { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// - Parameters:
    ///   - submitted: Formulare (id), die diese Anmeldung schon abgesendet hat
    ///   - isDone: Erfolgsseite des Dienstes (z. B. QIS mit Abmelden-Link)
    public static func step(url: URL?, html: String, university: UniversityKey, domains: [String], submitted: [String],
                            isDone: Bool) -> UniAutoLoginStep {
        guard allowed(url, domains: domains) else { return .abort }
        if isDone { return .done }
        guard let form = UniLoginForms.form(for: url, university: university), form.appears(in: html) else { return .wait }
        if submitted.contains(form.id) { return rejects(form, html: html) ? .rejected : .giveUp }
        if submitted.count >= maxSubmits { return .giveUp }
        return .fill(form)
    }

    /// Gilt die Seite nach dem eigenen Absenden als echte Ablehnung? Nur bei einem Formular mit bestaetigten Feldnamen
    /// und einem Fehlertext der Seite (Befund 11.11.2026: ein langsames Formular galt nach 8 s als "falsches Passwort",
    /// das Passwort wurde geloescht und mit "überall gleich" stand jedes Portal still). SOGo & Co. (`confirmed: false`)
    /// nie: dort bleibt es bei `.failed` und der Ruecknahme nach Fehlschlaegen (hoechstens `maxFailures` Versuche).
    public static func rejects(_ form: UniLoginForm, html: String) -> Bool {
        form.confirmed && form.appears(in: html) && form.showsFailure(in: html)
    }

    /// Die Seite steht seit einigen Sekunden ohne neue Navigation (z. B. Fehler per Ajax ohne neue Seite, langsame
    /// Antwort): abgelehnt nur mit Fehlertext (`rejects`) eines schon abgesendeten Formulars, sonst `.failed`.
    public static func stalled(url: URL?, html: String, university: UniversityKey, submitted: [String]) -> UniAutoLoginOutcome {
        guard let form = UniLoginForms.form(for: url, university: university), submitted.contains(form.id),
              rejects(form, html: html) else { return .failed }
        return .wrongPassword
    }
}

// MARK: - Wann still angemeldet wird

/// Stand der automatischen Anmeldung einer Quelle (je Container und Dienst, nur im Arbeitsspeicher)
public struct UniAutoLoginState: Equatable, Sendable {
    /// gescheiterte stille Anmeldungen seit dem letzten Erfolg
    public var failures = 0
    public var lastAttempt: Date?
    /// die Hochschule hat das gespeicherte Passwort abgelehnt: bis zu einer neuen Anmeldung nie mehr damit versuchen
    public var rejected = false
    /// still angemeldet, der eine neue Versuch laeuft; meldet er wieder "abgelaufen", ist Schluss (keine Schleife)
    public var awaitingRetry = false

    public init() {}
}

public enum UniAutoLoginDecision: Equatable, Sendable {
    /// unsichtbar mit dem gespeicherten Passwort anmelden
    case relogin
    /// angemeldet: die gescheiterte Anfrage genau einmal wiederholen
    case retryOnce
    /// "Anmeldung nötig" zeigen (einmal), der Mensch meldet sich an bzw. aendert das Passwort
    case needsUser
    /// noch in der Ruecknahme nach Fehlschlaegen: "Anmeldung nötig" bleibt, spaeter wieder
    case wait(until: Date)
    /// jetzt nichts (Abmelden laeuft, App im Hintergrund: dort fehlt die unsichtbare Webansicht)
    case nothing
}

public enum UniAutoLoginMachine {
    /// nie zwei stille Anmeldungen derselben Quelle innerhalb dieser Zeit
    public static let minInterval: TimeInterval = 60
    /// so lange nach einer stillen Anmeldung gilt ein neues "abgelaufen" als gescheiterter neuer Versuch (danach ist es
    /// ein neuer Ablauf, z. B. am naechsten Tag)
    public static let retryWindow: TimeInterval = 10 * 60
    /// nach so vielen Fehlschlaegen in Folge nur noch auf Knopfdruck (Schutz vor einer Kontosperre durch Fehlversuche)
    public static let maxFailures = 3
    /// Ruecknahme nach Fehlschlaegen (ohne abgelehntes Passwort): 5, 10, 20 … Minuten, hoechstens 2 Stunden
    public static let baseBackoff: TimeInterval = 5 * 60
    public static let maxBackoff: TimeInterval = 2 * 3600

    public static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return minInterval }
        return min(baseBackoff * pow(2.0, Double(min(failures - 1, 16))), maxBackoff)
    }

    /// Eine Anfrage meldete "abgelaufen" (Anmeldeformular, 401/403, Weiterleitung zum SSO).
    /// - Parameters:
    ///   - enabled: "Automatisch anmelden" an
    ///   - hasCredential: Passwort dieser Hochschule im Schluesselbund
    ///   - appActive: App im Vordergrund (nur dann gibt es die unsichtbare Webansicht)
    ///   - signingOut: der Mensch meldet sich gerade ab (nie dann)
    ///   - userAction: der Mensch hat gerade selbst "Erneut anmelden" gewaehlt (ohne Ruecknahme)
    public static func expired(_ s: inout UniAutoLoginState, enabled: Bool, hasCredential: Bool, appActive: Bool,
                               signingOut: Bool, userAction: Bool = false, now: Date) -> UniAutoLoginDecision {
        if signingOut { return .nothing }
        guard enabled, hasCredential, !s.rejected else { s.awaitingRetry = false; return .needsUser }
        if s.awaitingRetry {
            s.awaitingRetry = false
            if let last = s.lastAttempt, now.timeIntervalSince(last) < retryWindow {
                // eben still angemeldet, und der eine neue Versuch ist wieder abgelaufen: keine zweite Runde
                s.failures += 1
                return .needsUser
            }
            s.failures = 0                                   // die stille Anmeldung hatte gehalten: neuer Ablauf
        }
        guard appActive else { return .nothing }
        if !userAction, s.failures >= maxFailures { return .needsUser }
        if !userAction, let last = s.lastAttempt {
            let until = last.addingTimeInterval(backoff(failures: s.failures))
            if now < until { return .wait(until: until) }
        }
        s.lastAttempt = now
        return .relogin
    }

    /// Ergebnis der unsichtbaren Anmeldung
    public static func finished(_ s: inout UniAutoLoginState, _ outcome: UniAutoLoginOutcome, signingOut: Bool = false) -> UniAutoLoginDecision {
        switch outcome {
        case .success:
            if signingOut { return .nothing }
            s.awaitingRetry = true
            return .retryOnce
        case .wrongPassword:
            s.rejected = true
            s.failures += 1
            s.awaitingRetry = false
            return .needsUser
        case .failed, .blocked:
            s.failures += 1
            s.awaitingRetry = false
            return .needsUser
        }
    }

    /// Eine Anfrage mit der Sitzung ist gelungen: alles zurueck
    public static func succeeded(_ s: inout UniAutoLoginState) {
        s.failures = 0
        s.awaitingRetry = false
    }

    /// Der Mensch hat sich selbst angemeldet (neues Passwort mitgelesen) oder das Passwort geloescht: frisch beginnen
    public static func reset(_ s: inout UniAutoLoginState) { s = UniAutoLoginState() }
}
