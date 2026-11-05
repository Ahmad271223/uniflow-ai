# Uni Hildesheim: Stand je Funktion (05.11.2026)

Auftrag des Inhabers (05.11.2026): „uni hildesheim einbinden“ – die Universität Hildesheim soll so weit unterstützt
sein wie die LUH, soweit die Systeme es zulassen. Geprüft wurde jede Funktion der App für Hildesheim; die Lücken sind
auf dem iPad und in Python/Web/Windows geschlossen, soweit das ohne echtes Konto geht. Gegen Learnweb, LSF und CAS
wurde **keine** Anfrage geschickt; alle Tests laufen mit erfundenen Antworten. Öffentliche Seiten von
uni-hildesheim.de wurden gelesen (Studienangebot, Verkündungsblatt, Prüfungsamt), Zwischenspeicher unter
`~/Studora-Builds/hildesheim/`. Der Aufbau der echten Seiten (angemeldet vom Inhaber gelesen, anonymisiert) steht in
`~/Studora-Builds/hildesheim/STRUKTUR-ECHT-2026-11-05.md` und ist eingearbeitet.

Der Marketing-Schalter `ipad_hildesheim` bleibt **aus**, bis der Inhaber mit einem echten Konto getestet hat
(Testliste unten). Vorbereitet hinter dem Schalter: der Satz im App-Store-Text
„• Universität Hildesheim: Kurse, Dateien, Fristen und Nachrichten aus dem Learnweb, Stundenplan und Noten aus dem LSF,
Studienverlauf mit den Modulen deines Studiengangs“ (`docs/release/APP-STORE.md`, `tools/rechtstexte-fuellen.py`), dazu
die bestehenden Satzteile „UND DER UNIVERSITÄT HILDESHEIM“ und „bzw. Learnweb“. Für die Website (`STARTSEITE.md`) gibt
es keinen Schalter; dort denselben Satz unter „Funktionen“ ergänzen, wenn der Schalter an ist.

Hinweis an den Inhaber: Im App-Store-Text steht noch „die App liest nur und schreibt nichts in die Hochschulsysteme“.
Seit Abgeben und Antworten (LUH 05.11., jetzt auch Hildesheim) stimmt das nicht mehr; der Satz sollte lauten
„… schreibt nur, wenn du selbst Abgeben oder Senden tippst“.

## Tabelle

Legende: **ja** gebaut und mit erfundenen Daten geprüft · **echt offen** braucht einen Test mit echtem Konto ·
**geht nicht, weil …** die Hochschule bietet es nicht oder es wäre unsicher.

| Funktion | LUH | Hildesheim vorher | Hildesheim nachher |
| --- | --- | --- | --- |
| Erster Start, Hochschulwahl, Anmeldung | Stud.IP (WebSSO), QIS | CAS für Learnweb (Moodle-SSO-Schlüssel oder Sitzung), LSF über dieselbe CAS-Sitzung | unverändert ja; echt offen: ob die Uni das Schema `moodlemobile` erlaubt |
| Angemeldet bleiben | Cookies im Schlüsselbund, stille Erneuerung | stille Erneuerung über die CAS-Anmeldung im Datenspeicher des Containers (`HildesheimSilentLogin`, `renewSilently`), Learnweb und LSF verbinden sich gegenseitig ohne Passwort | ja; neu: abgelaufene Learnweb-Sitzung beim Antworten/Abgeben stößt die Erneuerung an (`learnwebExpired`) |
| Kurse, Dateien, Lehrwoche | Stud.IP | Learnweb (REST mit Schlüssel, AJAX mit Sitzung), Abschnitt → „Woche N“ | ja (unverändert) |
| Reihenfolge des Abgleichs (aktuelles Semester zuerst) | `SyncOrder` | – | ja: Stundenplan → Learnweb aktuelles Semester → Fristen, Ankündigungen, **Nachrichten** → Noten → frühere Semester im Hintergrund (Vertrag `docs/SYNC-REIHENFOLGE-2026-11-05.md`) |
| Frühere Semester aus älteren Learnweb-Instanzen (learnweb2025, 2024) | Stud.IP-Semester | nicht gelesen | **geht noch nicht, weil** Kurs- und Datei-Kennungen (`lw-<moodle-id>`) je Instanz neu zählen und zwischen Instanzen kollidieren würden; nötig ist ein Präfix je Instanz (`lw2025-…`) in Python und Kern samt Umzug. Frühere Semester **in** der aktuellen Instanz (SoSe 2026 in learnweb2026) laufen wie bei der LUH im Hintergrund |
| Ankündigungen der Lehrenden | Stud.IP-News | Learnweb-Ankündigungsforen | ja (unverändert) |
| Fristen (Abgaben, Tests) | Stud.IP-Courseware, erkannte Fristen | Learnweb-Kalender | ja (unverändert) |
| Foren (Diskussionen der Studierenden) | Stud.IP-Forum als Lerntext | nur Ankündigungsforen | bewusst nur Ankündigungen (wie am PC); ungelesene Diskussionen zeigt das Learnweb selbst |
| **Nachrichten** lesen | Stud.IP-Posteingang | fehlte (Menüpunkt nie) | **ja**: Moodle-Unterhaltungen (`core_message_get_conversations`, AJAX-freigegeben, markiert nichts als gelesen) in derselben Liste, ohne Personennamen (Absender „Learnweb-Kontakt“/„Learnweb-Gruppe“); iPad `LearnwebMessages` im Abgleich, PC `hildesheim.sync_messages` |
| **Nachrichten** beantworten | Stud.IP-JSON:API | fehlte | **ja**: „Antworten“ in die Unterhaltung (`core_message_send_messages_to_conversation`, genau ein Versuch), Empfänger nur live; iPad über das gemeinsame Moodle-Antwortfenster (`MoodleReplySheet` mit Learnweb-Sitzung), Web/Windows über `/api/studip/messages/lw-msg-…/reply` mit Ausweg „Im Learnweb antworten“; echt offen |
| **Abgeben** | Stud.IP-Ordner (JSON:API) | fehlte | **ja**: „Im Learnweb abgeben …“ im Teilen-Menü (gemeinsames Moodle-Abgabeblatt der HsH: Entwurf hochladen, dann ausdrücklich „Jetzt abgeben“, Formulare der Aufgabe mit sesskey); Aufgaben aus den Learnweb-Fristen. API-Bedarf unten; echt offen. Web/Windows: noch nicht (siehe unten) |
| „Meine Arbeiten“ (elektronische Einreichung studentischer Arbeiten im LSF, `abgabe2`) | – | – | **echt offen**: Seite neu entdeckt (Spalten Aktion, Status, Titel, Dokumenttyp, Datei, Betreuer_in, Abgabe am, Veranstaltung); nur lesend anzeigen und verlinken ist der nächste Schritt, sobald eine echte Seite als Muster da ist |
| Wartungshinweise des LSF („+++ … +++“) | – | – | **ja**: als „LSF-Hinweis: …“ in der Statusleiste (iPad `LSFClient.maintenanceNotice`, PC `lsf.maintenance_notice`), versteckter „neues Layout“-Text zählt nie |
| Klausurtermine („Nächste Klausuren“) | Stud.IP-Termine, Notenspiegel „AN“, angemeldete Prüfungen | Modul-Klausurtermin, Learnweb-Fristen mit „Klausur/Prüfung“, Ankündigungen, Erkennung in Dateien | ja; neu: angemeldete Prüfungen mit Datum aus „Meine POS-Anmeldungen“ (Quelle `anmeldung`) |
| Stundenplan | Stud.IP | LSF-iCal (BYDAY, EXDATE) | ja (unverändert) |
| Noten | QIS | LSF-Notenspiegel | ja (unverändert) |
| Prüfungsanmeldung (Hilfe) | Meldezeiträume je Studiengang, QIS-Link, „Info über angemeldete Prüfungen“ | fehlte (`supported: false`) | **ja**: Daten `exam-registration-hildesheim.json` (71 Studiengänge, POS-Anmeldung ab 11.11.2026, offenes Ende laut Prüfungsamt), „Im LSF anmelden“ im In-App-Browser, „Meine POS-Anmeldungen“ nur lesend nach dem Notenspiegel; nie `prfAnmStudent` (Details `docs/PRUEFUNGSANMELDUNG-2026-11-05.md`) |
| Studienverlauf (Katalog, Wahlbereiche) | Register 234 Einträge, Grundstock `luh.json.gz` | fehlte (nur LUH-Register) | **ja**: Register 116 Einträge (57 Studiengänge, 53 Fächer), Grundstock `hildesheim.json.gz` + Verzeichnis mit 105 Katalogen und 2 050 Modulen (LP 96 %, Semester 86 %, Prüfung 97 %), Wahlbereiche aus 47 Prüfungsordnungen für 21 Kataloge, Leser der LSF-Zeile „Abschluss: …“, Texte im Studienverlauf sagen „LSF“. 11 Einträge ohne Katalog mit Grund („geht nicht, weil …“), Modellstudienpläne (`plan_slots`) noch nicht gelesen. Details und Qualitätsbericht `docs/STUDIENGAENGE-HILDESHEIM-2026-11-05.md` |
| Videos (Opencast) | Stud.IP-Plugin | Seite sagt ehrlich „gibt es nur über Stud.IP der LUH“ | **geht nicht, weil** das Learnweb kein Opencast anbietet; Video-Links in Learnweb-Dateien erkennt die App wie überall (Funktion „Videos & Links“ ist hochschulunabhängig) |
| KI, Karteikarten, Wochentests, Erklärungen | gleich | gleich | ja, hochschulunabhängig geprüft: Prompts und Endpunkte haben keine LUH-Sperre; nur der optionale Kurskontext (Kursbeschreibung, Sitzungsthemen) kommt aus Stud.IP und fehlt in Hildesheim |
| Gemeinsame Wochentests | Schlüssel Uni + Inhalts-Hash | ja | ja (unverändert) |
| Community je Modul | Schlüssel aus Modulname | ja | ja: Test `HildesheimAuditTests` – Vorlesung „9072 …“ und Übung „9073 … - Übung“ landen in derselben Community, getrennt von der LUH |
| Bescheinigungen | QIS | – | **geht nicht, weil** das LSF Hildesheim sie nicht im Menü hat |

## Abgeben im Learnweb: was Moodle verlangt

Moodle 4.4 (`mod/assign/db/services.php`, gelesen am 05.11.2026 auf GitHub):
- `mod_assign_get_assignments`, `mod_assign_get_submission_status`, `mod_assign_save_submission` und
  `mod_assign_submit_for_grading` haben **kein** `'ajax' => true`. Mit der Browsersitzung (sesskey) sind sie gesperrt,
  nur mit dem Schlüssel der Moodle-App (Dienst `moodle_mobile_app`) nutzbar. Datei dann über `webservice/upload.php`
  (Schlüssel im Körper) in den Entwurfsbereich; `save_submission` **ersetzt** die bisherigen Dateien.
- Ohne Schlüssel bleibt das Formular der Aufgabe (`mod/assign/view.php?id=<cmid>&action=editsubmission`, Upload über
  `repository/repository_ajax.php` mit sesskey). Diesen Weg geht das gemeinsame Moodle-Abgabeblatt (`MoodleAssign`, gebaut
  vom HsH-Agenten, für Hildesheim mitgenutzt): erst „Als Entwurf hochladen“, dann ausdrücklich „Jetzt abgeben“, genau ein
  Versuch je Schritt. Auf den echten Learnweb-Seiten ungeprüft.
- Web/Windows: am PC gibt es noch keinen Abgabe-Dialog für Moodle (auch nicht für die HsH). Nächster Schritt wäre
  derselbe Formular-Weg in Python mit `LEARNWEB_COOKIES`.

## Nachrichten: Moodle-Dienste

`core_message_get_conversations`, `core_message_get_conversation`, `core_message_send_messages_to_conversation` sind
in Moodle für AJAX freigegeben (lib/db/services.php). Die eigene Kennung liest die App aus `M.cfg.userId` bzw.
`data-userid` der angemeldeten Seite (mit Schlüssel aus `core_webservice_get_site_info`). Gemeinsame Fälle Python ↔ Swift:
`packages/shared-contracts/fixtures/learnweb/messages-cases.json` (`tools/gen-learnweb-messages-fixture.py --check`).
Die HsH nutzt für ihr Moodle die gleichen Dienste über `MoodleMessagesSync` (Kennung `moodle-…`); Hildesheim speichert
mit `lw-msg-…`, das Antwortfenster ist dasselbe.

## Dateien

- Python: `app/learnweb_messages.py` (neu), `app/hildesheim.py` (`sync_messages`, LSF-Hinweis), `app/lsf.py`
  (`maintenance_notice`), `app/studip_messages.py` (Menüpunkt für Learnweb), `app/studip_reply.py` (Antworten `lw-msg-…`).
- Web: `app/static/messages-logic.js`, `messages.js`, `message-reply.js`, `message-reply-logic.js`.
- Kern: `Hildesheim/LearnwebMessages.swift` (neu), `LearnwebAPI.swift` (Kennung aus der Seite, Senden ohne Wiederholung,
  `LSFClient.maintenanceNotice`), `HildesheimSync.swift` (Schritt Nachrichten, Hinweis), `ExamRegistration/QISRegistrations.swift`.
- App: `Services/HildesheimConnection.swift` (`moodleWeb`, `learnwebExpired`), `Services/MessagesInbox.swift`,
  `Views/Messages/MessagesPage.swift`, `Views/MoodleViews.swift` (Learnweb im Antwort- und Abgabeblatt),
  `Views/DocumentView.swift` („Im Learnweb abgeben …“).
- Studienverlauf und Prüfungsanmeldung: siehe die beiden Dokumente oben.
- Offen in Web/Windows: Texte in `app/static/study-plan-logic.js` sagen noch „QIS“ (iPad sagt für Hildesheim „LSF“).
- Tests: `tests/test_learnweb_messages.py`, `tests/js/messages-learnweb.test.mjs`, Kern `LearnwebMessagesTests`,
  `HildesheimAuditTests`, App `MessagesAppTests.testLearnwebMessagesOfHildesheim`,
  `StudyCatalogSyncTests.testAppBundleHildesheimSeedGivesHildesheimStudentAPlan`.

## Testliste für den Inhaber (echtes Hildesheim-Konto, iPad)

1. Erster Start → Universität Hildesheim → Learnweb verbinden: Kommt die Moodle-App-Anmeldung (Schlüssel) oder nur die
   Sitzung? Danach LSF ohne zweites Passwort?
2. Abgleich: Kurse und Dateien des aktuellen Semesters zuerst, Stundenplan mit Donnerstags-Kurs, Ausfall an Heiligabend,
   Notenspiegel (auch leer ok).
3. App 9 h liegen lassen, wieder öffnen: verbindet sich Learnweb/LSF still neu (kein Passwort)?
4. Nachrichten: Erscheint der Menüpunkt mit den Learnweb-Unterhaltungen? Stimmen Text und Zeit? Bleiben sie im Learnweb
   ungelesen?
5. Einer Testperson (z. B. eigenem Zweitkonto) im Learnweb schreiben, in StudiNow „Antworten“ → kommt die Antwort im
   Learnweb an, unter deinem Namen, ohne Doppel?
6. Im Learnweb eine Testaufgabe (oder eine echte mit Erlaubnis): Dokument → Teilen → „Im Learnweb abgeben …“ → „Als
   Entwurf hochladen“ → in Moodle prüfen → „Jetzt abgeben“ → Status in Moodle prüfen.
7. Wartungshinweis: steht im LSF „+++ … +++“, zeigt die Statusleiste „LSF-Hinweis: …“?
8. Prüfungsanmeldung ab 11.11.2026: Karte auf der Übersicht, „Im LSF anmelden“ öffnet Meine Funktionen, „Meine
   POS-Anmeldungen“ wird gelesen (Seitentitel, Spalten, Text bei keiner Anmeldung).
9. Studienverlauf: Wird der eigene Studiengang aus der LSF-Zeile „Abschluss: …“ erkannt? Passen Module, LP und
   Wahlbereiche zum Modulhandbuch?
10. „Meine Arbeiten“ im LSF: Seite einmal als Muster (anonymisiert) speichern, damit die App sie lesend anzeigen kann.
11. Danach `ipad_hildesheim` in `docs/release/angaben.json` auf `true` und die Store-Texte neu füllen.
