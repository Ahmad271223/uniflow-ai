# Automatisch anmelden (iPad, 06.11.2026)

**Entscheidung des Inhabers (06.11.2026), ersetzt die vom 03.11.2026 (nur Cookies + iOS-Autofill):** Nach der ersten
Anmeldung werden Studierende nie wieder gefragt – Stud.IP, QIS/LSF, Uni-Mail (SOGo), Moodle, HISinOne/PLuS, Learnweb.
Die App darf das Hochschul-Passwort speichern, aber **nur auf diesem Gerät**: Schlüsselbund-Eintrag mit
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false` (kein iCloud-Schlüsselbund), je
Hochschul-Container ein Eintrag; **nie** an StudiNow-Server oder einen Rechner außerhalb der Hochschule.

## Was die App tut

1. **Zustimmung.** Unter jeder Anmeldeseite (erster Start und alle Anmeldeblätter: Stud.IP, QIS, Learnweb/LSF, Moodle,
   Campusmanagement, Uni-Mail) steht der Schalter „Passwort auf diesem iPad merken – du wirst nicht erneut gefragt“
   mit der Zeile „Nur auf diesem Gerät im Schlüsselbund, nie auf unseren Servern“ (Vorgabe an,
   `UniRememberPasswordToggle`). Aus löscht ein gemerktes Passwort sofort.
2. **Mitlesen nur beim eigenen Absenden.** Ein kleines Skript in eigener Inhaltswelt (`studinow-credential`, nur
   Hauptrahmen, Start des Dokuments) läuft nur auf den Formular-Rechnern der eigenen Hochschule
   (`UniLoginForms`, Tabelle unten). Beim Absenden (Formular, Absende-Knopf, Eingabetaste im Passwortfeld) meldet es
   Benutzername und Passwort genau dieses Formulars an die App. Die App prüft Welt, Hauptrahmen, Herkunft und Adresse
   des Rahmens (`UniCredentialCapture.accept`) und hält es höchstens 15 Minuten im Arbeitsspeicher; **in den
   Schlüsselbund kommt es erst, wenn die Anmeldung gelungen ist** (`signedIn` der Verbindung → `UniAutoLogin.signedIn`).
3. **Eine Zugangskennung je Hochschule.** LUH-ID für WebSSO (Stud.IP), QIS und SOGo; UNI-Account für CAS
   (Learnweb, LSF, PLuS), LSF-/PLuS-Formular und SOGo Hildesheim; SSO-Account für Moodle, IdP und Campusmanagement der
   HsH. Eintrag `uni-login.<container-uuid>` im Dienst `de.uniflow.ai.uni-login` (`UniCredentialStore`).
4. **Stille Neuanmeldung.** Meldet eine Verbindung „abgelaufen“ (Anmeldeformular, 401/403, Weiterleitung zum SSO),
   öffnet die App eine unsichtbare Webansicht mit dem Datenspeicher des Containers (`UniAutoLoginWeb`), lädt die
   Anmeldeseite, füllt auf einem bekannten Formular Benutzername und Passwort ein (Passwort als Argument von
   `callAsyncJavaScript`, nie im Skript-Quelltext; das Skript prüft Rechner und Pfad selbst noch einmal) und sendet ab.
   Erfolg = Erfolgsseite des Dienstes; dann **genau ein** neuer Versuch (Abruf bzw. die gescheiterte Aktion).
   - jede Weiterleitung des Hauptrahmens auf einen Rechner außerhalb der Hochschule oder auf http: Abbruch;
   - jedes Formular höchstens einmal, höchstens drei je Anmeldung; erscheint es nach dem Absenden wieder: „Passwort
     abgelehnt“;
   - **falsches Passwort:** „Anmeldung nötig“ erscheint (die bisherige Bitte, höchstens alle 6 Stunden), das
     abgelehnte Passwort wird für keinen Dienst der Hochschule mehr benutzt. Seit 1.0.2 (Abschnitt unten) wird der
     dabei benutzte Eintrag dafür **vergessen** (vorher blieb er liegen und galt nur bis zum Neustart als abgelehnt);
     die Einstellungen zeigen „abgelehnt“, bis ein neues Passwort gespeichert ist oder sich der Mensch neu anmeldet;
   - **keine Schleife:** läuft der eine neue Versuch innerhalb von 10 Minuten wieder ab, ist Schluss; nie zwei stille
     Anmeldungen derselben Quelle innerhalb einer Minute; nach Fehlschlägen 5, 10, 20 … Minuten Pause, höchstens 2
     Stunden, nach drei Fehlschlägen in Folge nur noch auf Knopfdruck „Erneut anmelden“ (Schutz vor einer Kontosperre;
     `UniAutoLoginMachine`); steht nach dem Absenden ohne neue Seite noch dasselbe Formular da (SOGo), gilt das Passwort
     als abgelehnt; nie zwei unsichtbare Anmeldungen zugleich im selben Datenspeicher;
   - nie während des Abmeldens (Abmelden löscht den Eintrag zuerst, ein laufender Versuch wird verworfen), nie im
     Hintergrund (dort fehlt das Fenster), nie unter XCTest oder mit dem Debug-Stub.
5. **Wann.** Beim Wechsel in den Vordergrund (`ContainerManager.renewExpiredSessions`: Stud.IP, Learnweb/LSF, QIS,
   Uni-Mail, Moodle, Campusmanagement), nach einem Abgleich mit „abgelaufen“, bei Uni-Mail direkt in der Aktion (Mail
   öffnen, senden …). Stud.IP und Learnweb/LSF versuchen zuerst wie bisher die SSO-Sitzung ohne Passwort
   (`StudIPSilentLogin`, `HildesheimSilentLogin`); erst wenn das WebSSO bzw. CAS das Passwort will, wird eingefüllt und
   danach der bisherige Weg noch einmal gegangen.
6. **Einstellungen** (bis 1.0.1: Studium → „Automatisch anmelden“, `UniAutoLoginCard`): Schalter, „Gespeichert für:
   <Benutzer>“, „Gespeichertes Passwort löschen“. Seit 1.0.2 die Karte „Uni-Zugang“ (Abschnitt unten). Abmelden bei
   einem Dienst, „Daten dieser Hochschule löschen“ und „Konto löschen“ löschen die Einträge ebenfalls.

## 1.0.2: Uni-Zugang einmal speichern (Vorgabe des Inhabers 10.11.2026)

„Man muss nur einmal in den Einstellungen das Passwort speichern, mehr nicht.“

**Einstellungen → Zugang & Darstellung → Studium → „Uni-Zugang“** (`UniAutoLoginCard`, erste Karte der Gruppe):

- Schalter **„Benutzername und Passwort sind überall gleich“** (Vorgabe an, `UniAutoLogin.sameEverywhere`, UserDefaults
  `uniLogin.sameEverywhere`, kein Geheimnis).
  - **An:** ein Formular (Benutzername, Passwort) für Stud.IP, QIS und Uni-Mail (SOGo) – der gemeinsame Eintrag
    `uni-login.<container-uuid>`.
  - **Aus** (nur an der LUH): Stud.IP, QIS und Uni-Mail (SOGo) untereinander, jedes mit Benutzername, Passwort,
    „Speichern“, Status (gespeichert / fehlt / abgelehnt) und „Entfernen“. Je Portal ein eigener Eintrag
    `uni-login.<container-uuid>.<studip|qis|sogo>` im selben Dienst, gleiche Schutzklasse (`ThisDeviceOnly`, nicht
    synchronisiert). Fehlt der Eintrag eines Portals, gilt der gemeinsame (`UniAutoLogin.credential(for:)`).
- Unter der Karte: „Dein Passwort liegt nur im Schlüsselbund dieses iPads – nie auf unseren Servern.“
- **„Speichern“** legt den Eintrag ab (Speichern heißt zustimmen: „Automatisch anmelden“ an) und ruft gleich
  `ContainerManager.connectWithStoredLogin(userAction: true)` auf; die Karte zeigt kurz das Ergebnis
  („Verbunden: Stud.IP, QIS, Uni-Mail.“ / „Anmeldung nötig: …“ / „Passwort abgelehnt (…)“). Das Passwortfeld ist
  danach wieder leer; das Passwort steht nie in Bedienungshilfen-Werten.

**Verbinden** (`connectWithStoredLogin`, Services/StoredLoginConnect.swift): Reihenfolge **Stud.IP (WebSSO), QIS,
Uni-Mail (SOGo)**, auch beim ersten Mal (vorher konnte die stille Anmeldung nur eine bestehende Verbindung erneuern):

| Stand des Dienstes | was passiert |
| --- | --- |
| verbunden | nichts, zählt als „verbunden“ |
| abgelaufen | wie bisher still erneuern (`renewSilently`, `QISConnection.autoLogin`, `UniMailConnection.autoLogin`) |
| noch nie verbunden | unsichtbar auf dem Formular anmelden (`UniAutoLogin.handleExpiry`), dann wie nach einer Anmeldung von Hand: Stud.IP prüft die Cookies mit `users/me` und gleicht ab (`signedIn(cookies:)`), QIS ruft Noten ab (`signedIn()`), Uni-Mail liest das Konto aus der Adresse `/SOGo/so/<benutzer>/` und den Posteingang (`signedIn(user:)`) |
| bewusst abgemeldet | nichts (kein stilles Wiederverbinden), bis sich der Mensch dort anmeldet oder in den Einstellungen neu speichert |

Regeln: nur im Vordergrund; nie in einer Schleife (`UniAutoLoginMachine` unverändert); nie zwei Läufe zugleich; nie mit
Demo-Inhalten. **Abgelehnt:** der benutzte Eintrag wird vergessen, dazu jeder andere Eintrag mit genau demselben
Benutzernamen und Passwort – ein abgelehntes Passwort geht nie ein zweites Mal hinaus, auch nicht an ein anderes Portal
oder nach einem Neustart. Mit dem gemeinsamen Zugang stoppt eine Ablehnung damit alle Portale, mit getrennten Zugängen
nur dieses. `StoredLoginReport` meldet `connected`, `needsLogin`, `rejected`, `noCredential` und `rejectedPortals`.

**Sync:** Ein Tipp auf „Sync“ (Kopfzeile) gleicht an der LUH Stud.IP, QIS (Noten, Prüfungen, angemeldete Prüfungen,
Bescheinigungsliste, nur lesend) und Uni-Mail ab; ohne gespeicherten Zugang sagt er „Zuerst den Uni-Zugang in den
Einstellungen speichern“ und öffnet die Einstellungen (Zugang & Darstellung, Karte „Uni-Zugang“). Beim Öffnen der App
verbindet sie mit dem gespeicherten Zugang ebenso selbst (Teil „Sync“, `Services/OpenSync.swift`).

Tests: `StoredLoginConnectTests` (gemeinsam, getrennt, Rückfall auf den gemeinsamen, Ablehnung eines Portals gegen
alle, kein zweites Senden – auch nicht an ein anderes Portal –, Abmelden-Sperre, Hintergrund, Löschen aller Einträge),
`UniAutoLoginCardTests` (beide Schalterstellungen im Fenster, Texte, Ergebnis), `UniAutoLoginAppTests` (abgelehnter
Eintrag wird vergessen statt behalten).

**Testliste für den Inhaber (1.0.2, am iPad, echte Konten):**
13. Neu installieren, anmelden, LUH wählen, nichts verbinden. Einstellungen → „Uni-Zugang“: LUH-ID und Passwort
    eingeben, „Speichern“ → nach kurzer Zeit „Verbunden: Stud.IP, QIS, Uni-Mail.“; Dateien, Noten und Posteingang kommen.
14. Schalter „überall gleich“ aus: drei Formulare; nur QIS mit falschem Passwort speichern → „Passwort abgelehnt (QIS)“,
    Stud.IP und Uni-Mail bleiben verbunden; QIS zeigt „abgelehnt“, kein zweiter Versuch beim nächsten „Sync“.
15. QIS „Abmelden“ → App schließen und öffnen, „Sync“ → QIS bleibt abgemeldet.

## Formulare (`UniLoginForms`)

| Hochschule | Formular | Rechner, Pfad | Felder | Absenden | Feldnamen |
| --- | --- | --- | --- | --- | --- |
| LUH | WebSSO (Stud.IP) | `sso.idm.uni-hannover.de/idp/` | `loginname` (`j_username`), `password` | `_eventId_proceed` | aus app/studip_sync.py |
| LUH | QIS | `qis.verwaltung.uni-hannover.de/qisserver/` | `asdf`, `fdsa` | `submit` | aus app/qis.py |
| LUH | Uni-Mail | `kalender.uni-hannover.de/SOGo` | `app.creds.username`/`userName`, `#passwordField` | `type=submit` | Marker aus app/sogo.py, Felder **am Gerät prüfen** |
| Hildesheim | CAS (Learnweb, LSF, PLuS) | `www.uni-hildesheim.de/sso/login` (auch ohne www) | `username`, `password` | `submit` | aus app/cas.py |
| Hildesheim | LSF eigenes Formular | `lsf.uni-hildesheim.de/qisserver/` | `asdf`, `fdsa` | `submit` | HIS-Standard, **am Gerät prüfen** |
| Hildesheim | PLuS eigenes Formular | `plus.uni-hildesheim.de/qisserver/` | `asdf`, `fdsa` (nie im versteckten Dialog) | `submit` | **am Gerät prüfen** |
| Hildesheim | Uni-Mail | `webmail.uni-hildesheim.de/SOGo` | wie LUH | | **am Gerät prüfen** |
| HsH | Moodle | `moodle.hs-hannover.de/login/` | `username`, `password` | `#loginbtn` | Moodle-Standard |
| HsH | SSO (IdP) | `idp.hs-hannover.de/simplesaml/` | `username`, `password` | `type=submit` | SimpleSAMLphp-Standard, **am Gerät prüfen** |
| HsH | Campusmanagement eigenes Formular | `campusmanagement.hs-hannover.de/qisserver/` | `asdf`, `fdsa` (nie `#sessionTimeoutDialog`) | `submit` | Fixture hsh |

Nachgebaute Seiten: `packages/shared-contracts/fixtures/autologin/` (NACHGEBAUT).

## Tests

- Kern (`swift test`): `UniAutoLoginTests` – Formulare je Rechner und Hochschule, keine fremden/ähnlichen Rechner,
  http, andere Ports; Fixtures erkannt, Fehlerseiten; Skripte ohne Netz und ohne Geheimnis; Schritte der unsichtbaren
  Webansicht (einmal einfüllen, abgelehnt, fremder Rechner); Ablauf (abgelaufen → anmelden → ein Versuch, keine
  Schleife, falsches Passwort, Abmelden, Hintergrund, Ruecknahme).
- App (iPad-Simulator): `UniAutoLoginAppTests` – Schlüsselbund `ThisDeviceOnly` und nicht synchronisiert; Mitlesen in
  echter `WKWebView` nur auf dem Formular-Rechner, erst nach Erfolg gespeichert, nicht mit Schalter aus, Seite sieht
  keinen Kanal; Einfüllen in alle Formular-Fixtures (Werte, `input`-Ereignisse, `donotcache` bleibt aus), nie auf
  fremdem Rechner, nie im versteckten HISinOne-Dialog; QIS: Wiederanmeldung + genau ein Abruf, keine Schleife, falsches
  Passwort löscht nichts, kein Versuch ohne Passwort/im Hintergrund/nach Abmelden; Löschen über Einstellungen,
  Schalter, „Daten dieser Hochschule löschen“, „Konto löschen“. `UniversityLoginPolicyTests` angepasst (zweite erlaubte
  Stelle mit Skript: `UniAutoLogin.swift`).

## Testliste für den Inhaber (am iPad, echte Konten)

Allgemein: einmal anmelden mit Schalter an → Einstellungen → „Automatisch anmelden“ zeigt „Gespeichert für: …“.
Dann jeweils die Sitzung ablaufen lassen (Stunden warten oder im In-App-Browser abmelden) und die App öffnen bzw.
„Jetzt abgleichen“: **es darf keine Anmeldeseite erscheinen**, der Stand wird „ok“.

**LUH**
1. Stud.IP: Anmeldung im ersten Start (WebSSO). Am nächsten Tag (WebSSO-Sitzung abgelaufen) App öffnen → Abgleich
   ohne Frage. Prüfen: WebSSO-Formular wird gefüllt und abgesendet (Felder `loginname`/`password`).
2. QIS: „Noten abrufen“ nach > 30 min Pause → ohne Anmeldeseite. Prüfen: Felder `asdf`/`fdsa`, Absende-Knopf.
3. Uni-Mail: nach Ablauf eine Mail öffnen → öffnet sich ohne Anmeldung. **Prüfen:** SOGo-Feldnamen (Angular),
   „Angemeldet bleiben“.
4. Falsches Passwort: in den Einstellungen nichts ändern, aber das LUH-Passwort im IDM ändern → genau einmal
   „Anmeldung nötig“, Einstellungen zeigen „abgelehnt“; neu anmelden → wieder automatisch.

**Uni Hildesheim**
5. Learnweb und LSF: CAS-Sitzung ablaufen lassen → App öffnen → beide wieder verbunden, ohne Frage.
6. PLuS (Bescheinigungen): „Anmelden mit Single Sign-On“ → CAS füllt sich selbst; zusätzlich prüfen, ob PLuS ein
   eigenes Formular zeigt (Feldnamen `asdf`/`fdsa`?) und ob nach 30 min Inaktivität die Wiederanmeldung klappt.
7. Uni-Mail (webmail.uni-hildesheim.de): wie LUH Punkt 3.

**HsH**
8. Moodle: nach Ablauf „Jetzt abgleichen“ → ohne Anmeldeseite (Felder `username`/`password`, Knopf `#loginbtn`).
9. Campusmanagement: „Anmelden mit SSO Hochschule Hannover“ → IdP füllt sich selbst. **Prüfen:** IdP-Feldnamen und
   Absende-Knopf (SimpleSAMLphp), ob eine Zwischenseite (Attributfreigabe) kommt – dann bricht die stille Anmeldung
   nach 8 s ab („Anmeldung nötig“, Meldung an den Koordinator).

**Datenschutz**
10. Schalter unter der Anmeldeseite aus → anmelden → Einstellungen zeigen „Noch kein Passwort gespeichert“.
11. Abmelden (Stud.IP/QIS/Uni-Mail/…) → Eintrag weg; „Konto löschen“ → Eintrag weg.
12. Neues iPad / Backup wiederherstellen: es darf **kein** Passwort mitkommen (ThisDeviceOnly).

**Noch offen:** Die Website-Startseite sagt „Kein Uni-Passwort gespeichert.“ (gemeint: nicht bei uns). Mit dieser
Entscheidung besser „Kein Uni-Passwort auf unseren Servern.“ – Text und tests/test_site.py bitte gemeinsam ändern.
