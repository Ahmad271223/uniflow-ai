# Uni-Mail für die Universität Göttingen (Stand 27.11.2026)

Zweig `uni/goettingen-mail` (vom Stand `uni/goettingen` @ 7db2302e). **Nicht** in 1.0.8 / Build 51 (eingefroren),
sondern für ein Update danach. Nichts gepusht, nichts aufs iPad gespielt, kein Server geändert.

## 1. Kurz

- Göttingen hat Exchange bei der GWDG, kein SOGo. Webmail geht nur über die Academic Cloud mit zweitem Faktor, also
  nicht in einer Webansicht. Darum spricht StudiNow jetzt selbst **IMAP** (lesen) und **SMTP** (senden).
- Die Oberfläche ist dieselbe wie bei der Uni-Mail an LUH und Hildesheim: Menüpunkt „Uni-Mail“, Ordner, Liste mit
  Seiten, Suche, Lesen, Anhänge, Antworten, Allen antworten, Weiterleiten, Neue E-Mail, Entwurf sichern, Markieren,
  Papierkorb mit „Rückgängig“, Abzeichen mit ungelesenen, Mitteilung bei neuen Mails, Mail an Lehrende, PDF aus dem
  Dokument per Mail. Anders sind nur die Anmeldung (eigenes Formular statt Webseite) und der Kalender (gibt es hier nicht).
- Eigener Code, keine Fremdbausteine: Network.framework für IMAP, `URLSessionStreamTask` (Foundation) für SMTP mit
  STARTTLS (siehe 3.).
- Passwort: tippt nur der Mensch am Gerät. Erst wenn der Mail-Rechner es annimmt, kommt es in den Schlüsselbund dieses
  Geräts (derselbe Uni-Zugang wie für Stud.IP, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, nicht synchronisiert).
  Ohne „Passwort merken“ liegt es nur im Arbeitsspeicher bis zum Beenden der App. Nie auf einem Server.
- Getestet nur gegen eine **Nachbildung** des Mail-Rechners (kein echtes Netz in Tests). Mit einem echten Konto ist
  nichts geprüft – das ist der nächste Schritt des Inhabers (Abschnitt 6).

## 2. Was am echten Server nachgesehen wurde (27.11.2026, ohne Anmeldung)

Nur die Begrüßung und die Fähigkeiten gelesen (wie ein Mail-Programm vor der Anmeldung), keine Zugangsdaten gesendet:

| Dienst | Ergebnis |
|---|---|
| IMAP `email.gwdg.de:993` (TLS) | „The Microsoft Exchange IMAP4 service is ready.“ `CAPABILITY IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=NTLM AUTH=GSSAPI SASL-IR UIDPLUS UNSELECT CHILDREN IDLE NAMESPACE LITERAL+` – **kein MOVE**, kein SPECIAL-USE |
| SMTP `email.gwdg.de:587` | STARTTLS geht; danach `AUTH GSSAPI NTLM LOGIN` (**kein PLAIN**), `SIZE 367001600`, `SMTPUTF8` |
| SMTP `email.gwdg.de:465` | keine Antwort (nicht benutzt) |

Öffentliche Anleitungen (studIT, wiki.student.uni-goettingen.de/support/email/…): Benutzer `ug-student\<Kennung>`,
Adresse `<kennung>@stud.uni-goettingen.de`. Die Outlook-Anleitung nennt SMTP-Port 25, die Kontoseite 587/STARTTLS –
StudiNow nimmt **587 mit STARTTLS** (oben bestätigt). Die Thunderbird-Anleitung nennt `email.stud.uni-goettingen.de`;
StudiNow nimmt `email.gwdg.de` wie die iPhone/iPad-Anleitung (der andere Name steht nur als Hinweis in
`IMAPMailSite.alternativeHosts`).

## 3. Was gebaut ist

### Kern (`apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/IMAPMail/`)

| Datei | Inhalt |
|---|---|
| `IMAPMailSite.swift` | Rechner, Ports, `ug-student\`, Adresse; `SOGoSite.goettingen` (`isIMAP`), `SOGoSite.mailSites`. `SOGoSite.all` bleibt nur LUH + Hildesheim (Cookies/Webansicht). `SOGoSite.for(.goettingen)` liefert jetzt die Göttinger Uni-Mail. |
| `MailStream.swift` | Byte-Strom und Zeilenleser. Echt: `NWConnection` mit TLS ≥ 1.2 und Rechnernamen-Prüfung für IMAP 993; `URLSessionStreamTask` für SMTP 587, weil Network.framework eine laufende Verbindung nicht nachträglich auf TLS heben kann. Verbindungen **nur** zu `email.gwdg.de` (`SystemMailStreamOpener`, andere Rechner → abgelehnt). |
| `IMAP.swift` | Antworten zerlegen (Atome, Zeichenketten, Literale, Listen, `BODY[…]`), sichere Argumente (Anführungszeichen oder Literal, nie ein Zeilenumbruch), modifiziertes UTF-7 für Ordnernamen („Gel&APY-schte Elemente“), LIST/STATUS/SEARCH/FETCH, APPENDUID. |
| `IMAPSession.swift` | Befehle nacheinander, Literale (LITERAL+ ohne Warten), Anmeldung **ein Versuch je Verbindung**: `AUTHENTICATE PLAIN` mit SASL-IR (so bietet es Exchange an), sonst `LOGIN`. Nie `CLOSE`, nie `EXPUNGE` ohne UID. |
| `MailMIME.swift` | E-Mails lesen: Kopfzeilen, kodierte Wörter (RFC 2047), Zeichensätze (UTF-8, ISO-8859-1/-15/-2, Windows-1252/-1250, UTF-16), base64, quoted-printable, multipart (mixed/alternative/related), Dateinamen nach RFC 2231, Datum. |
| `MailCompose.swift` | E-Mails schreiben: Kopfzeilen ohne Steuerzeichen (kein Einschleusen über den Betreff), Nicht-ASCII als kodierte Wörter, Text UTF-8 quoted-printable, Anhänge base64; **Bcc steht nie im Kopf**; Re:/Fwd:, Zitat „Am … um … schrieb …:“. |
| `SMTPClient.swift` | Senden: EHLO → **STARTTLS (sonst Abbruch, nichts gesendet)** → EHLO → AUTH (PLAIN, sonst LOGIN) → MAIL/RCPT → DATA. Lehnt der Server einen Empfänger ab, geht nichts hinaus. Bricht die Verbindung nach dem Absenden ab, meldet es „unklar“ und versucht **nie** ein zweites Mal. |
| `IMAPMailClient.swift` | `UniMailBackend` (gemeinsame Schnittstelle, `SOGoClient` erfüllt sie auch) mit denselben JSON-Formen wie SOGo. Eine offene Verbindung, lesende Befehle nach Abbruch einmal neu, schreibende nie. Ordner wie SOGo (Posteingang, Entwürfe, Gesendet, Papierkorb, Spam zuerst; deutsche und englische Exchange-Namen; Kalender, Kontakte, Aufgaben, Notizen, Postausgang, Synchronisierungsprobleme usw. von Exchange ausgeblendet). Papierkorb = **verschieben**: ohne MOVE (Göttingen) `UID COPY` + `\Deleted` + `UID EXPUNGE` nur dieser UIDs (UIDPLUS); ohne UIDPLUS lehnt es ab. Entwürfe leben im Gerät, bis „Als Entwurf speichern“ (APPEND in „Entwürfe“, die vorige eigene Fassung wird ersetzt). Nach dem Senden: Kopie in „Gesendet“ (Exchange legt über SMTP Gesendetes nicht selbst ab), Quelle als beantwortet/weitergeleitet markiert, gespeicherter Entwurf weg. |

### App

- `UniMailConnection` (Services/UniMailConnection.swift): ein IMAP-Weg neben SOGo (`site.isIMAP`). `perform` nimmt jetzt
  `UniMailBackend`; alles andere (Liste, Lesen, Senden, Hintergrund, Abzeichen, Zwischenspeicher) bleibt gleich.
  Neu: `signInIMAP(username:password:remember:)`, `connectIMAPWithStoredLogin`, Merker `uniflow.imap.rejected`
  („<benutzer>|<gespeichert um>“, kein Geheimnis): ein vom Mail-Rechner abgelehnter gespeicherter Zugang geht nie wieder
  an ihn – der Eintrag bleibt aber für Stud.IP, bis der Mensch ein neues Passwort speichert. Kein Uni-Kalender,
  keine Webansicht, keine stille Webanmeldung.
- `ContainerManager`: Göttinger Container bekommt jetzt eine Uni-Mail (`SOGoSite.for`), Tests geben `uniMailOpener` an.
- `UniMailViews.swift`: neues Formular `UniMailIMAPLoginForm` (Kennung, Passwort mit `textContentType(.password)` –
  iOS darf es anbieten –, „Passwort merken“, Knopf „Anmelden“, Knopf „Mit gespeichertem Uni-Zugang verbinden“). Karte
  ohne „& Uni-Kalender“, Seite „E-Mails der Universität Göttingen (Exchange der GWDG)“, keine Kalender-Karte.
- Hinweis „neu in StudiNow“ (`UFUniversityScope.newNotice`): Uni-Mail steht jetzt unter „Schon dabei“, nicht mehr
  unter „Noch nicht dabei“. Einstellungen „Uni-Zugang“: „Stud.IP und Uni-Mail“.

## 4. Tests (27.11.2026)

- Kern: neu `IMAPMailTests` (21) gegen `IMAPFakeServer.swift` (Nachbildung Exchange-IMAP 993 und SMTP 587 mit
  STARTTLS im Arbeitsspeicher, Begrüßung und Fähigkeiten wie am echten Server). **Alle 1970 Kern-Tests grün** (20
  übersprungen wie immer). `GoettingenTests.testProfile` angepasst (Göttingen hat jetzt Uni-Mail über IMAP).
- App: neu `GoettingenMailAppTests` (8); `GoettingenAppTests` angepasst (Uni-Mail vorhanden, Sync-Knopf nennt
  Stud.IP und Uni-Mail, Hinweis). Läufe: siehe Abschnitt 7.
- Geprüft wird u. a.: ein Anmeldeversuch, abgelehntes Passwort nie zweimal, Passwort nie im Klartext auf der Leitung
  und nie in einer Meldung, Schlüsselbund nur dieses Gerät, Anmeldung beim Senden erst nach STARTTLS, kein Senden ohne
  STARTTLS, abgelehnter Empfänger → nichts gesendet, Abbruch nach DATA → „unklar“ ohne zweiten Versuch, genau eine
  Sendung je Knopf, Bcc nicht im Kopf, Papierkorb ohne endgültiges Löschen (eine fremde, als gelöscht markierte Mail
  bleibt), ohne UIDPLUS gar kein Verschieben, neu verbinden nach Abbruch, Umlaute/Zeichensätze, Ordner von Exchange.

## 5. Was nur gegen die Nachbildung geprüft ist (also **nicht** echt)

- Ob der Mail-Rechner das Passwort allein annimmt, obwohl die Uni für eCampus einen **zweiten Faktor** verlangt
  (offene Frage 16 der Recherche). Wenn nicht: die App sagt „Kennung oder Passwort wurden abgelehnt“ – dann bräuchte es
  ein App-Passwort der Academic Cloud oder OAuth (nicht gebaut).
- Benutzername-Form: `ug-student\kennung` für IMAP **und** SMTP (die App nimmt für beides dasselbe). Falls SMTP etwas
  anderes will (z. B. die Adresse), meldet „Senden“ „Anmeldung beim Senden abgelehnt“, ohne das Passwort als falsch zu
  markieren.
- Ob Exchange über SMTP Gesendetes selbst in „Gesendete Elemente“ ablegt. Die App legt eine Kopie ab
  (`IMAPMailSite.appendsSent`); falls dann doppelt: Schalter auf `false`.
- Echte Ordnernamen des Postfachs (deutsch/englisch) und ob Exchange Kalender/Kontakte als IMAP-Ordner zeigt.
- Suche mit Umlauten (`SEARCH CHARSET UTF-8`), Seiten bei sehr vollen Ordnern, große Anhänge (> 20 MB werden nicht
  geöffnet, wie bei SOGo), Mails mit exotischen Zeichensätzen.
- Wie lange Exchange eine ruhende Verbindung offen hält (die App verbindet bei Bedarf neu; vor schreibenden Befehlen
  nach 60 s Ruhe erst ein NOOP).
- Mitteilungen im Hintergrund mit echtem Postfach.
- Mac („Designed for iPad“): gebaut wie iPad, nicht eigens gelaufen (siehe 7).

## 6. Was der echte Test braucht (Inhaber, am Gerät)

1. Debug-Fassung dieses Zweigs (Göttingen ist nur im Debug-Build zur Wahl, `UF_SHIPPED_UNIVERSITIES`) in einem eigenen
   Simulator oder – nur mit seinem Okay – per Kabel aufs iPad.
2. Hochschule Göttingen, „Uni-Mail“ öffnen, „Bei Uni-Mail anmelden“, Kennung und Passwort **selbst** eintippen.
3. Prüfen: Posteingang und Ordner stimmen, eine Mail öffnen, Anhang öffnen, „Ungelesen“, „Markieren“, Papierkorb und
   „Rückgängig“.
4. Eine Test-Mail an sich selbst schreiben und nach der Rückfrage senden; danach in Outlook/Webmail prüfen: kam an?
   Liegt sie **einmal** (nicht doppelt) in „Gesendete Elemente“?
5. Bei „abgelehnt“: Bildschirmfoto der Meldung; dann klären, ob die Uni ein App-Passwort braucht.

## 7. Läufe

(wird nach den Simulator-Läufen ergänzt)

## 8. Einbinden

Nicht selbst in `release/1.0.8-alles` mischen. Fertigen Zweig, Freigabe-Zitat des Inhabers und Testzahlen an die
Build-Sitzung schicken – erst für das Update **nach** 1.0.8/Build 51 und erst nach dem echten Test (Abschnitt 6).

Mit der Veröffentlichung nachziehen (hier bewusst **nicht** geändert, weil die Mail noch nicht im Store ist):
- Website `site/index.html` (Kasten „Universität Göttingen“ nennt Uni-Mail unter „Noch nicht dabei“, geprüft in
  `tests/test_site.py`), Store-Texte, ggf. Datenschutztext (Verbindung direkt zum Mail-Rechner der GWDG, nichts über
  StudiNow-Server).
