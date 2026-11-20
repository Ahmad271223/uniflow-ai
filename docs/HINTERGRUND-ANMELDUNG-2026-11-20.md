# Anmeldung im Hintergrund (20.11.2026)

Entscheidung des Inhabers: „ja versuch, weil bei Studo geht das auch problemlos“. Ziel: Ist die App zu und die
Anmeldung bei der Uni abgelaufen, meldet sich der Hintergrund-Abgleich selbst neu an und gleicht dann weiter ab –
ohne dass jemand die App öffnen muss.

## Was jetzt im Hintergrund geht

| Portal | Wie | Ohne Webansicht? |
|---|---|---|
| QIS (LUH) | Startseite laden, Anmeldeformular (Felder `asdf`/`fdsa`) **einmal** per POST über die URLSession mit den Cookies des Containers. Danach Notenspiegel im selben Lauf. | ja |
| Stud.IP (LUH, WebSSO) | Zuerst **ohne Passwort**: WebSSO-Einstieg per URLSession; gilt die Uni-Anmeldung (IdP-Cookie) noch, reicht der Ablauf die Prüfseite des IdP und die SAML-Antwort weiter und kommt bei Stud.IP an. Will der IdP das Passwort: Formular (`loginname`/`password`) **einmal** per POST. Neue Cookies prüft Stud.IP (`users/me`), dann Abgleich. | ja (Webansicht nur, wenn eine Seite unbekannt ist und nichts gesendet wurde) |
| LSF (Uni Hildesheim, CAS) | Zuerst **ohne Passwort**: CAS-Einstieg des LSF; gilt das CAS-Cookie (TGC) noch, kommt das Ticket von selbst. Sonst CAS-Formular **einmal** per POST, danach LSF ohne Passwort. | ja |
| Learnweb (Uni Hildesheim) | Das Passwort (CAS) wie beim LSF per POST; die Learnweb-Anmeldung danach (Moodle-SSO mit App-Schema) weiter in der unsichtbaren Webansicht, ohne Passwort. | nur der Passwort-Teil |
| Uni-Mail, Moodle/Campusmanagement (HsH) | unverändert unsichtbare Webansicht (SOGo und HISinOne brauchen JavaScript) | nein |

Der Code: `UniFormLogin` (Kern, reine Regeln, ohne Netz testbar), `UniDirectLogin` (App: URLSession, Cookies zurück in
den Datenspeicher), eingebunden in `UniAutoLogin.handleExpiry(background: true)`, `QISConnection.reloginInBackground`,
`StudIPSync.renewInBackground`, `HildesheimConnection.reloginInBackground` und den Hintergrundlauf
`BackgroundSyncController.perform` (`reloginStep`).

Neu im Lauf: Läuft die Sitzung erst **mitten im Abgleich** ab (QIS beim Notenabruf, Stud.IP/Learnweb/LSF im Abgleich),
meldet sich der Lauf einmal an und gleicht danach im selben Lauf weiter ab. Vorher kam dann nur „Bitte anmelden“.

## Sicherungen (fest, mit Tests)

- **Nur ein Versuch je Portal und Lauf.** Das Passwort geht in einem Versuch höchstens einmal raus.
- **Nach einem Fehlschlag kein Hintergrund-Versuch mehr** (Passwort abgelehnt, Captcha, zweiter Faktor, unerwartete
  Seite, Zeit um, Weiterleitung zum Abmelden), bis die Anmeldung dieses Portals **bei offener App** gelungen ist.
  Vorher: 24 Stunden Pause. So kann das Uni-Konto nie durch wiederholte Versuche gesperrt werden.
- **Abgelehntes Passwort**: sofort aus dem Schlüsselbund gelöscht, nie ein zweites Mal gesendet (auch nicht von einem
  anderen Portal). Auch ein neu gespeichertes Passwort probiert der Hintergrund erst nach einer Anmeldung im Vordergrund.
- **Nur 8 bis 18 Uhr**, nur fällige und schon einmal verbundene Portale, nur mit „Passwort merken“ („Automatisch
  anmelden“), gespeichertem Uni-Zugang und dem Schalter „Im Hintergrund neu anmelden“. Nie nach bewusstem Abmelden.
- **iOS beendet die Zeit** (expirationHandler): die Anmeldung bricht sauber ab, kein weiterer Versuch in diesem Lauf,
  zählt **nicht** als abgelehnt oder Fehlschlag (nächster Lauf frühestens nach 30 Minuten). Nach 3 Abbrüchen in Folge
  gilt es doch als Fehlschlag (ein abgebrochener Versuch kann das Passwort schon gesendet haben).
- **QIS**: nie Abmelden, nie Prüfungsan-/abmeldung, nie Rücktritt, nie Bescheinigungen. Jede Weiterleitung wird vor
  dem Aufruf geprüft; Adressen mit `logout`, `abmeld`, `prfAnm`, `anmeldung`, `ruecktritt`, `storn`, `verpublish`,
  `hisreports` oder `state=user&type=4` werden nie aufgerufen. Keine Namen, Adressen, Geburtsdaten, Matrikelnummern.
- **Nur Rechner der eigenen Hochschule, nur HTTPS.** Passwort nur per POST an das echte Formular (Rechner und Pfad
  geprüft). Nie eine Zustimmungsseite des IdP, nie ein Formular mit Auswahl oder Eingabefeld außer Benutzer/Passwort.
- Umlaute im Passwort nur, wenn die Seite sicher UTF-8 spricht (sonst lieber die Webansicht, damit ein falsch
  kodiertes Passwort nie als „abgelehnt“ gilt und gelöscht wird).
- **Nichts Neues an StudiNow-Server.** Das Passwort bleibt im Schlüsselbund dieses Geräts.

## Tests

- `Packages/UniFlowCore/Tests/UniFlowCoreTests/UniFormLoginTests.swift`: QIS-POST genau einmal, abgelehnt nur mit
  Fehlertext, Weiterleitung zum Abmelden/zur Prüfungsanmeldung nie aufgerufen, fremder Rechner/HTTP blockiert, Captcha
  und zweiter Faktor, ohne Passwort nichts gesendet, Abbruch, Zeitlimit, Umlaute, Stud.IP still über Prüfseite und
  SAML-Antwort, Stud.IP-Formular, Zustimmungsseite nie gesendet, CAS-POST und CAS-Fehler.
- `UniFlowTests/HintergrundAnmeldungAppTests.swift`: abgelaufen → eine Anmeldung → Noten kommen im selben Lauf;
  abgelehnt → kein Versuch mehr bis zum Vordergrund-Erfolg; Fehlschlag ohne Ablehnung sperrt auch; außerhalb 8–18 Uhr
  und ohne „Passwort merken“ nichts; Ablauf der iOS-Zeit mitten in der Anmeldung → Abbruch ohne Ablehnung;
  Stud.IP still ohne Passwort und mit Passwort genau einmal.
- angepasst: `BackgroundReloginAppTests`, `BackgroundNewsAppTests` (keine 24-Stunden-Regel mehr).

## Was nur am echten Gerät geprüft werden kann

Getestet ist alles mit nachgebauten Seiten (keine echte Anmeldung bei der Uni). Am Gerät mit echter, abgelaufener
Anmeldung prüfen: QIS-Formular-POST (Feldnamen sind aus dem bestehenden Code bestätigt), Prüfseite des LUH-IdP und
SAML-Weiterleitung ohne JavaScript, CAS der Uni Hildesheim. Erkennt der Ablauf eine echte Seite nicht, sendet er nichts
und nimmt wie bisher die unsichtbare Webansicht.
