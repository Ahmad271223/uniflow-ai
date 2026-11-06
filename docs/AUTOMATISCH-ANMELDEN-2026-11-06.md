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
   - **falsches Passwort:** nichts wird gelöscht, „Anmeldung nötig“ erscheint (die bisherige Bitte, höchstens alle 6
     Stunden), das abgelehnte Passwort wird für keinen Dienst der Hochschule mehr benutzt, bis sich der Mensch neu
     anmeldet (das neue Passwort ersetzt das alte; Einstellungen zeigen „abgelehnt“);
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
6. **Einstellungen** (Studium → „Automatisch anmelden“, `UniAutoLoginCard`): Schalter, „Gespeichert für: <Benutzer>“,
   „Gespeichertes Passwort löschen“. Abmelden bei einem Dienst, „Daten dieser Hochschule löschen“ und „Konto löschen“
   löschen den Eintrag ebenfalls.

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
