# Anschreiben an die Hochschulen vor dem Start von StudiNow (Entwürfe, Stand 04.11.2026)

Zwei Entwürfe, die der Inhaber selbst verschickt: an die LUH (Stud.IP-Team ZQS/elsa) und an die Universität Hildesheim.
Nichts davon wurde verschickt. Alle Angaben zum Verhalten der App stammen aus dem Code und den Docs des Repos
(Belege in Klammern); Platzhalter `[[…]]` füllt der Inhaber. Ersetzt `docs/ANFRAGE-STUDIP-ZUGANG.md` (27.10.).

---

## 1. Leibniz Universität Hannover – Stud.IP-Team (ZQS/elsa)

**An:** elearning@uni-hannover.de
**CC:** [[LUIS IT-Service-Desk, falls QIS-Zugriff und WebSSO mit abgestimmt werden sollen]]
**Betreff:** Lern-App „StudiNow“ für Studierende der LUH: lesender Zugriff auf Stud.IP (JSON:API), QIS und Opencast – Bitte um Rückmeldung vor dem Start

Guten Tag,

ich studiere an der LUH ([[Studiengang, Semester]]) und veröffentliche in den nächsten Tagen die Lern-App
„StudiNow“ (iPad, Windows) meines Einzelunternehmens „IT solutions by Ahmad Fakih“. Die App holt die eigenen
Kursunterlagen, Termine und Ankündigungen aus Stud.IP auf das Gerät der Studierenden, damit sie dort offline lesen,
mit dem Stift bearbeiten und lernen können. Da nach dem Start möglicherweise viele Studierende der LUH die App nutzen,
möchte ich Ihnen vorher genau sagen, was die App an Ihren Systemen tut, und um Ihre Einschätzung bitten.

**Anmeldung.** Die App öffnet die echte Stud.IP-Anmeldeseite (WebSSO) in einer Webansicht. Die Studierenden geben
ihre Zugangsdaten nur dort ein; die App speichert nie ein Passwort (höchstens iOS-Passwort-Autofill). Gemerkt
werden die Sitzungs-Cookies von Stud.IP und der Anmeldeseite, im Schlüsselbund nur dieses Geräts (nicht in
Backups/iCloud), und auf dem Gerät der Benutzername, damit er bei einer erneuten Anmeldung schon eingetragen ist. Ist
die Sitzung abgelaufen, erneuert die App sie über die Anmeldeseite wie ein Browser; wie lange sie gilt, bestimmt
weiterhin Ihr Server. Auf Windows meldet sich die Person ebenso
selbst in einem sichtbaren Browserfenster an; die App behält nur die Sitzung.

**Was gelesen wird – nur mit dem eigenen Konto, nur GET, nie ein Schreibzugriff:**
- JSON:API: `users/me`, `users/{id}/courses`, `courses/{id}/folders`, `folders/{id}/folders`, `folders/{id}/file-refs`,
  `file-refs/{id}/content` (Dateien), `users/{id}/schedule`, `courses/{id}/events`, `users/{id}/events.ics`,
  `courses/{id}/news`, `studip/news`, `semesters`, `holidays`, `users/{id}/inbox` (nur die Liste, nie die Einzelansicht,
  nichts wird als gelesen markiert), `users/{id}/activitystream`, `users/{id}/consultation-bookings`, Courseware
  (`courseware-tasks`, `courseware-units`, `…-structural-elements`, `…-containers/{id}/blocks`), Wiki (`wiki-pages`) und
  Forum (`forum-categories`, `forum-entries`).
- Nicht per JSON:API erreichbar und deshalb als Seite gelesen: die Aufzeichnungstabelle des Opencast-Plugins
  (`plugins.php/opencastpluginluh/media/index?cid=…`, nur die Liste; Videos nur auf ausdrücklichen Wunsch) und die
  RSS-Feeds des Schwarzen Bretts (`plugins.php/schwarzesbrettplugin/rss/…`, höchstens alle 6 Stunden).
- Nie gelesen: Teilnehmendenlisten, Personenprofile, Blubber (bewusst abgeschaltet, weil `GET blubber-threads` in Stud.IP
  leere Threads aufräumt und das kein reines Lesen ist). Forenbeiträge werden ohne Autorennamen gespeichert.
- QIS: nur wenn die Studierenden „Noten abrufen“ einrichten, liest die App nach eigener Anmeldung den Notenspiegel
  (Mein Studium → Notenspiegel → Leistungen) und, ebenfalls nur lesend, „Info über angemeldete Prüfungen“; Stammdaten
  werden verworfen, Bescheinigungen nie aufgerufen. Prüfungsanmeldungen bleiben im QIS: Die App öffnet auf Wunsch nur
  „Mein Studium“ im eingebetteten Browser, anmelden und abmelden tun die Studierenden dort selbst.

**Wie oft.** Ein Abgleich läuft beim Öffnen der App höchstens alle 30 Minuten, dazu im Hintergrund frühestens um 8, 15
und 20 Uhr (ob überhaupt, entscheidet iOS); Noten höchstens alle 20 Stunden. Die Anfragen laufen nacheinander mit
250 ms Pause, höchstens 1 500 je Lauf (Courseware/Wiki/Forum zusammen höchstens 200). Dateien werden nur geladen, wenn
sich `chdate` geändert hat; standardmäßig nur die Kurse des laufenden Semesters, ältere nur auf Wunsch. Bei 429 oder
5xx wartet die App 1,5 bzw. 3 s und gibt nach drei Versuchen auf. In meiner Probe am 25.10. waren das 124 Anfragen
für 19 Kurse und 151 Dateien, Median 62 ms.

**Was das Gerät verlässt.** Die Unterlagen bleiben auf dem Gerät; es gibt keinen StudiNow-Server, der Dateien oder
Sitzungen erhält. Zwei Dinge möchte ich offen ansprechen:
1. Community über Apples iCloud (CloudKit, verschlüsselt): Studierende können **nur ihre eigenen Notizen** (Striche,
   Textfelder, eigene Bilder) als Ebene über einer Kursdatei, Kommentare, Likes und Korrekturvorschläge
   veröffentlichen – nie die Original-PDF, keine Folien, keine Aufgabenstellungen; die Nutzungsbedingungen verbieten
   Musterlösungen und fremde Texte. Sichtbar ist das nur für Studierende, die denselben Kurs bzw. dasselbe Modul
   (jetzt oder früher) in ihrem Stud.IP haben; lesbar nur mit derselben PDF. Außerdem werden KI-erzeugte Wochentests
   und je Seite eine strukturierte Einordnung (Zusammenfassung, Fachbegriffe, Aufgaben – kein Seitentext, kein Bild)
   für alle abgelegt, die dieselbe Datei haben (Schlüssel aus dem Datei-Hash, verschlüsselt).
2. KI: nur wenn die Studierenden ihr **eigenes ChatGPT-Konto** verbinden, gehen der Text der gerade geöffneten Seite
   bzw. Markierung, bei Wochentests die Texte der Unterlagen der Woche und bei Seiten mit Abbildungen ein gerendertes
   Seitenbild direkt vom Gerät an OpenAI (USA). Für eine spätere Fassung mit StudiNow-Konto ist vorgesehen, dass
   Dateien für eine einmalige Analyse an unseren Server gehen und dort spätestens nach 15 Minuten gelöscht werden;
   gespeichert bliebe nur der verschlüsselte Index.

**Meine Fragen:**
1. Ist diese Nutzung von Stud.IP, QIS und der Opencast-Seiten mit dem eigenen Konto aus Ihrer Sicht in Ordnung? Gibt es
   Grenzen für Häufigkeit oder Menge der Abrufe, die ich einhalten soll?
2. Könnten Sie für StudiNow einen OAuth2-Client in Stud.IP einrichten (öffentlicher Client mit PKCE, Scope `api`,
   Weiterleitung z. B. `uniflow://oauth/callback`)? Dann müsste die Anmeldung nicht mehr in einer eingebetteten
   Webansicht stattfinden.
3. Gibt es aus Ihrer Sicht urheberrechtliche Vorgaben (§ 60a UrhG) zu den Kursunterlagen, die ich zusätzlich beachten
   soll – etwa zur Verarbeitung durch einen KI-Anbieter oder zu den oben beschriebenen abgeleiteten Inhalten
   (Wochentests, Seiten-Einordnung)? Ist die Verarbeitung durch OpenAI auf Veranlassung der Studierenden für Sie
   akzeptabel?
4. Wer ist bei Ihnen Ansprechperson, falls die App einmal Last oder Fehler verursacht? Auf Zuruf drossle ich den
   Abgleich oder schalte einzelne Funktionen (Opencast, Schwarzes Brett, Forum, Community) per App-Update ab.

Gern zeige ich die App oder den Quelltext. Vielen Dank für Ihre Zeit.

Mit freundlichen Grüßen
Ahmad Fakih
IT solutions by Ahmad Fakih · Vahrenwalder Straße 30 · 30165 Hannover · support@studinow.app
[[Matrikelnummer/LUH-ID, falls gewünscht]]

---

## 2. Universität Hildesheim – Betrieb von Learnweb, LSF und CAS

**An:** [[Empfänger]] (in den Docs ist keine Ansprechperson genannt; vermutlich Rechenzentrum bzw. Learnweb-Team)
**Betreff:** Lern-App „StudiNow“ für Studierende der Universität Hildesheim: lesender Zugriff auf Learnweb und LSF – Bitte um Rückmeldung vor dem Start

Guten Tag,

ich veröffentliche in den nächsten Tagen die Lern-App „StudiNow“ (iPad, Windows) meines Einzelunternehmens
„IT solutions by Ahmad Fakih“ aus Hannover. Sie holt die eigenen Kursunterlagen, Termine, Fristen und Ankündigungen
aus dem Learnweb und dem LSF auf das Gerät der Studierenden, damit sie dort offline lesen, mit dem Stift arbeiten und
lernen können. Die App unterstützt neben der LUH die Universität Hildesheim [[getestet mit meinem eigenen Konto /
dem Konto von …]]. Bevor möglicherweise viele Ihrer Studierenden die App nutzen, möchte ich Ihnen sagen, was sie an
Ihren Systemen tut, und um Ihre Einschätzung bitten.

**Anmeldung.** Die App öffnet die CAS-Anmeldeseite (`www.uni-hildesheim.de/sso`) in einer Webansicht; die Studierenden
melden sich dort selbst an. Die App speichert nie ein Passwort (höchstens iOS-Passwort-Autofill), sondern die
Sitzungs-Cookies im Schlüsselbund dieses Geräts und auf dem Gerät den Benutzernamen, damit er bei einer erneuten
Anmeldung schon eingetragen ist. Für das Learnweb nutzt die App bevorzugt den
Moodle-Mobile-Dienst (`admin/tool/mobile/launch.php`, Schlüssel „Moodle mobile web service“ im Schlüsselbund), sonst
die CAS-Sitzung.

**Was gelesen wird – nur mit dem eigenen Konto, nie ein Schreibzugriff:**
- Learnweb mit Schlüssel (REST): `core_webservice_get_site_info`, `core_enrol_get_users_courses`,
  `core_course_get_contents`, Dateien über `pluginfile.php`; Ankündigungsforen (`mod_forum_get_forums_by_courses`,
  `mod_forum_get_forum_discussions`, höchstens 30 Beiträge je Forum); Fristen über
  `core_calendar_get_action_events_by_timesort` (gestern bis +200 Tage, überfällige 120 Tage zurück) und
  `core_calendar_get_calendar_upcoming_view`. Ohne Schlüssel dieselben Daten über die Sitzung
  (`core_course_get_enrolled_courses_by_timeline_classification`, `core_courseformat_get_state`, Dateilinks über
  `mod/resource/view.php?redirect=1`); Moodle zählt dann je Datei einen Aufruf wie bei einem Klick im Browser.
  Allgemeine Diskussionsforen, Teilnehmendenlisten und Namen werden nicht gelesen.
- LSF: Stundenplan über den iCal-Export der Planseite (`moduleCall=iCalendarPlan`), Notenspiegel über
  „Meine Funktionen → Studien-/Prüfungsleistungen“ nur, wenn die Studierenden „Noten abrufen“ einrichten. Stammdaten
  (Name, Anschrift, Matrikelnummer) werden verworfen. Die App klickt nie auf „Anmelden/abmelden“ oder
  Prüfungsanmeldungen.

**Wie oft.** Ein Abgleich läuft beim Öffnen der App höchstens alle 30 Minuten, dazu im Hintergrund frühestens um 8, 15
und 20 Uhr (ob überhaupt, entscheidet iOS); Noten höchstens alle 20 Stunden. Die Anfragen laufen nacheinander; bei
Netz- oder Serverfehlern höchstens drei Versuche mit 1,5 bzw. 3 s Pause. Dateien werden nur bei geänderter
`timemodified` bzw. Revision neu geladen; standardmäßig nur die Kurse des laufenden Semesters. In meinem Test am
25.10. waren das 9 Learnweb-Kurse mit 539 Dateien und 24 LSF-Stundenplan-Serien.

**Was das Gerät verlässt.** Die Unterlagen bleiben auf dem Gerät; es gibt keinen StudiNow-Server, der Dateien oder
Sitzungen erhält. Zwei Dinge möchte ich offen ansprechen:
1. Community über Apples iCloud (CloudKit, verschlüsselt): Studierende können **nur ihre eigenen Notizen** als Ebene
   über einer Kursdatei, Kommentare, Likes und Korrekturvorschläge veröffentlichen – nie die Original-PDF, keine
   Folien, keine Aufgabenstellungen; die Nutzungsbedingungen verbieten Musterlösungen und fremde Texte. Sichtbar nur
   für Studierende, die dasselbe Modul (jetzt oder früher) belegen; lesbar nur mit derselben PDF. Außerdem werden
   KI-erzeugte Wochentests und je Seite eine strukturierte Einordnung (Zusammenfassung, Fachbegriffe, Aufgaben – kein
   Seitentext, kein Bild) für alle abgelegt, die dieselbe Datei haben (Schlüssel aus dem Datei-Hash, verschlüsselt).
2. KI: nur wenn die Studierenden ihr **eigenes ChatGPT-Konto** verbinden, gehen der Text der gerade geöffneten Seite
   bzw. Markierung, bei Wochentests die Texte der Unterlagen der Woche und bei Seiten mit Abbildungen ein gerendertes
   Seitenbild direkt vom Gerät an OpenAI (USA). Für eine spätere Fassung mit StudiNow-Konto ist vorgesehen, dass
   Dateien für eine einmalige Analyse an unseren Server gehen und dort spätestens nach 15 Minuten gelöscht werden;
   gespeichert bliebe nur der verschlüsselte Index.

**Meine Fragen:**
1. Ist diese Nutzung von Learnweb, LSF und CAS mit dem eigenen Konto aus Ihrer Sicht in Ordnung? Gibt es Grenzen für
   Häufigkeit oder Menge der Abrufe? Ist Ihnen der Weg über den Moodle-Mobile-Dienst (eigener Schlüssel je Konto)
   lieber als die Sitzung – er erzeugt bei Ihnen keine Aufrufzählungen?
2. Gibt es eine offizielle Schnittstelle oder einen Weg, den Sie für Drittanbieter-Apps bevorzugen (z. B. ein
   für die App erzwungenes URL-Schema im Moodle-Mobile-Dienst oder ein eigener Webdienst)?
3. Gibt es urheberrechtliche Vorgaben (§ 60a UrhG) zu den Kursunterlagen, die ich zusätzlich beachten soll – etwa zur
   Verarbeitung durch einen KI-Anbieter oder zu den abgeleiteten Inhalten (Wochentests, Seiten-Einordnung)? Ist die
   Verarbeitung durch OpenAI auf Veranlassung der Studierenden für Sie akzeptabel?
4. Wer ist bei Ihnen Ansprechperson, falls die App einmal Last oder Fehler verursacht? Auf Zuruf drossle ich den
   Abgleich oder schalte einzelne Funktionen (Forum, Fristen, Noten, Community) per App-Update ab.

Gern zeige ich die App oder den Quelltext. Vielen Dank für Ihre Zeit.

Mit freundlichen Grüßen
Ahmad Fakih
IT solutions by Ahmad Fakih · Vahrenwalder Straße 30 · 30165 Hannover · support@studinow.app

---

## Hinweise für dich (nicht mitschicken)

**Platzhalter:** `[[Studiengang, Semester]]`, `[[Matrikelnummer/LUH-ID]]`, `[[LUIS …]]` (CC), `[[Empfänger]]` für
Hildesheim (weder `docs/HILDESHEIM.md` noch `docs/AUFTRAG-HILDESHEIM-IPAD.md` nennen eine Ansprechperson),
`[[getestet mit …]]` (der Live-Test vom 25.10.2026 lief mit einem echten Hildesheimer Konto, `docs/HILDESHEIM.md`;
wessen, steht nicht da).

**Was ich geprüft habe (Quellen):**
- Anmeldung, Cookies, kein Passwort: `apps/apple/UniFlow/Services/UniTransportSession.swift` (`UniWebSessions`,
  Sitzungs-Cookies im Schlüsselbund je Container), `Services/StudIPSync.swift` (`StudIPCookieStore`),
  `Services/KeychainStore.swift` (`AfterFirstUnlockThisDeviceOnly`), `Views/UniversityLoginViews.swift`
  (Hinweistext zu Passwörtern), seit 04.11.2026 `Services/UniSessionKeeper.swift` und `Services/UniLoginHelper.swift`
  (alle Cookies der Hochschul-Domains inkl. Anmeldeseite, Benutzername auf dem Gerät, stille Erneuerung,
  docs/IPAD-STUDIP-SYNC.md Abschnitt 13). Windows: `apps/windows/README.md`
  („Hochschul-Anmeldung ohne Passwort in der App“; Chromium merkt das Passwort DPAPI-verschlüsselt, nicht die App).
- Stud.IP-Routen und Nur-Lesen: `UniFlowCore/StudIPClient.swift`, `StudIPScheduleStore.swift`, `StudIPSchedule.swift`,
  `StudIPCalendar.swift`, `StudIPTerms.swift`, `StudIPExtras.swift` (Inbox nur Liste, nie Einzelansicht; Teilnehmende
  nie), `StudIPTexts.swift` (Courseware/Wiki/Forum, nur GET, max. 200 Anfragen), `StudIPBulletin.swift` (RSS, 6 h),
  `StudIPBlubber.swift` (`syncEnabled = false`, Begründung im Kopf), `Opencast/*.swift` (nur Listen; Videos nur auf
  Wunsch), `QISGrades.swift` (Stammdaten verworfen, Bescheinigungen nie geöffnet). Kein POST/PATCH/DELETE gegen
  Stud.IP im Swift-Kern oder in `app/studip_*.py` gefunden.
- Anfragemuster: `StudIPClient` (250 ms Pause, max. 1 500 Anfragen, Retry 3× mit 1,5 s/3 s bei 429/5xx),
  `StudIPSync.runIfDue` (30 Minuten), `BackgroundSync.swift` (8/15/20 Uhr), `QISConnection.swift` und
  `HildesheimConnection.swift` (Noten 20 h, Abgleich 30 min), `StudIPImport.selection` (jüngstes Semester vorausgewählt),
  `UniStore.versionStamp` (`chdate`/Revision). Probe-Zahlen: `docs/IPAD-STUDIP-SYNC.md` Abschnitt 7.
- Hildesheim: `UniFlowCore/Hildesheim/LearnwebAPI.swift`, `LearnwebDeadlines.swift`, `MoodleSSO.swift`,
  `HildesheimCAS.swift`, `LSFCalendar.swift`, `UniTransport.swift` (`UniRetry` 3 Versuche), `docs/HILDESHEIM.md`,
  `docs/AUFTRAG-HILDESHEIM-IPAD.md`. **Es gibt auf der Hildesheim-Seite keine feste Pause zwischen Anfragen** (anders
  als 250 ms bei Stud.IP); der Brief sagt deshalb nur „nacheinander“.
- Community/CloudKit: `docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md`, `docs/LOESUNGEN-TEILEN.md` (Abschnitte 1, 7:
  nur eigene Notizen, nie die Original-PDF; Zugriff über Kurs-/Modulschlüssel, „hat oder hatte das Modul“ über die
  Kurse früherer Semester in der lokalen DB, `StudIPSync.swift`), `docs/GEMEINSAME-WOCHENTESTS.md`,
  `docs/DOKUMENT-INDEX-2026-11-04.md`, `docs/release/DATENSCHUTZ.md` 8a/8b, `docs/release/NUTZUNGSBEDINGUNGEN.md` 6/7.
- KI-Anbieter: iPad = eigenes ChatGPT der Nutzer (`UniFlowCore/AI/ChatGPTSession.swift`, `LocalAI.swift`,
  `Services/ChatGPTLink.swift`, Datenschutz 8a); Dienst = OpenAI mit StudiNow-Schlüssel (`app/ai_backend.py`,
  `LERNAPP_AI_PROVIDER=openai`). Dokument-Index-Upload mit 15-Minuten-Löschung: `app/doc_index.py`
  (`RETENTION_MINUTES = 15`) – dort steht ausdrücklich **„Dienst-Seite für V2, Entwurf und Gerüst“**, `analyze_page()`
  ist nicht angeschlossen, und die iPad-App ruft `POST /api/index/file` nirgends auf. Darum steht das im Brief als
  „vorgesehen“. Wenn du das nicht ankündigen willst, den Satz streichen.

**Nicht verifizierbar / von dir zu prüfen:**
- OAuth2-Weiterleitung: Im Code gibt es keinen OAuth2-Client für Stud.IP; registriert ist nur das URL-Schema `uniflow`
  (`apps/apple/UniFlow/Info.plist`, Bundle-ID `de.uniflow.ai`). `uniflow://oauth/callback` ist ein Vorschlag, kein
  bestehender Code; das frühere `de.uniflow.ai:/oauth/callback` stand nirgends im Code.
- **Kein Kill-Switch:** Es gibt keine Remote-Konfiguration, kein Feature-Flag vom Server und keinen Schalter, mit dem du
  Funktionen auf allen Geräten aus der Ferne abschalten könntest (gesucht: remote config, feature flag, minVersion,
  forceUpdate, Status-Endpunkt; nur lokale Schalter wie `StudIPBlubber.syncEnabled` und `UFNoStudIPSync`). Der Brief
  verspricht daher nur „per App-Update“. Wenn die Unis schnelle Abschaltung erwarten, bräuchte es z. B. einen
  CloudKit-Datensatz oder eine Datei auf studinow.app, die die App beim Start liest.
- Ob LUIS für QIS/WebSSO ins CC gehört, ist deine Entscheidung (`docs/IPAD-STUDIP-SYNC.md` Abschnitt 8 nennt ZQS/elsa,
  LUIS-Service-Desk und den Datenschutzbeauftragten der LUH).

**Woran sich die Hochschulen stoßen könnten:**
- **Gehosteter Dienst mit gespeicherten Hochschul-Zugangsdaten:** `app/vault.py`, `app/jobs.py`, `app/server.py`
  (`put_credentials`, `UNI_CONSENT_AT`) und `docs/release/DATENSCHUTZ.md` Abschnitt 6 beschreiben, dass der Dienst
  Benutzername und Passwort verschlüsselt speichert und sich um 8 und 15 Uhr per Playwright selbst bei der Hochschule
  anmeldet (max. 2 gleichzeitig je Hochschule, 15 s Abstand). Laut deiner eigenen Recherche (`IPAD-STUDIP-SYNC.md`
  Abschnitt 8) wertet LUIS das Hinterlegen von Zugangsdaten auf Systemen Dritter als unzulässig. **Die Briefe erwähnen
  den Dienst bewusst nicht**, weil V1 ohne Server startet (`docs/RELEASE-VORBEREITUNG.md`, Hosting offen in
  `angaben.json`). Bevor du den Dienst mit Abgleich freischaltest, muss das gesondert mit beiden Hochschulen geklärt
  werden – oder der Server-Abgleich entfällt.
- Eingebettete Webansicht für die Anmeldung (RFC 8252 rät ab); darum die OAuth2-Frage. Beim Dienst ist zusätzlich der
  PC-Abgleich auf die HTML-Seite `dispatch.php/course/files/flat` angewiesen (`app/studip_sync.py`), nicht nur auf die
  JSON:API.
- Abgeleitete Inhalte aus Kursmaterial in CloudKit (Wochentests, Seiten-Einordnung mit Aufgaben, auf Wunsch auch
  Lösungen, `DOKUMENT-INDEX` „solutions“) und der Fingerabdruck (SHA-256) der Original-PDF in `Solution`-Datensätzen –
  § 60a UrhG, deshalb die Frage 3.
- Nachrichten aus dem Stud.IP-Posteingang werden mit vollem Text lokal gespeichert (`StudIPExtras`, Spalte `preview`),
  ebenso Forum, Wiki und Schwarzes Brett – nur auf dem Gerät, aber es sind Texte, die andere Personen geschrieben
  haben (ohne deren Namen).
- Ohne Moodle-Schlüssel zählt das Learnweb jeden Dateiabruf der App als Aufruf (Lehrende sehen verzerrte Statistiken).
- Opencast-Seite je Kurs bei jedem vollen Abgleich (serverseitig gerendert; Kurse ohne Plugin antworten mit 500).
- `docs/release/DATENSCHUTZ.md` Abschnitt 1 sagt „KI gibt es nur, wenn du dein eigenes ChatGPT verbindest“, während
  `app/ai_backend.py` und `app/jobs.py` eine StudiNow-KI über OpenAI für den Dienst beschreiben. Vor dem Dienst-Start
  angleichen.
