# Abgeben aus der App: eigene Lösung in Stud.IP hochladen (05.11.2026)

Entscheidung des Inhabers (05.11.2026, wörtlich): „abgeben aus der app ja“. Ein Knopf „Abgeben“ lädt die eigene
Lösung – die PDF mit Notizen, Seitennotizen und Blättern daneben – in einen Ordner des Stud.IP-Kurses hoch. Wer
abgibt, muss nicht mehr exportieren und im Browser hochladen.

Bisher hat die App Stud.IP nur gelesen (`docs/IPAD-STUDIP-SYNC.md`). Die Anmeldung bleibt wie dort beschrieben: Cookies
der Hochschul-Domains im Schlüsselbund, stille Erneuerung, nie ein Passwort (§13). Das Hochladen ist die **einzige
schreibende Anfrage** der App an Stud.IP. Sie läuft nur, wenn der Mensch „Jetzt abgeben“ tippt, nie im Abgleich und nie
wiederholt.

## 1. Recherche: wie Stud.IP Dateien annimmt

Gelesen wurden nur öffentliche Dokumentationen, keine Anfrage an die LUH:
- [Stud.IP-Entwicklerdoku JSON:API, Dateibereich](https://docs.gitlab.studip.de/entwicklung/jsonapi/files/)
- [Stud.IP-Entwicklerdoku JSON:API, Start](https://docs.gitlab.studip.de/entwicklung/jsonapi/start/)
- [Stud.IP-Hilfe „Dateien hochladen“](https://docs.studip.de/help/6/en/Basis/DateienUpload)
- Anleitungen anderer Hochschulen zum Hausaufgabenordner (Hochschule RheinMain, Göttingen, Bremen)

Den Quelltext auf gitlab.studip.de ließ der Bot-Schutz (Anubis) nicht lesen. Er wurde nicht umgangen.

| Frage | Befund | Sicher? |
| --- | --- | --- |
| Ordner eines Kurses | `GET jsonapi.php/v1/courses/{id}/folders`: flache Liste, mit `page[limit]` (Standard 30). Jeder Ordner hat `folder-type`, `name`, `is-visible`, `is-readable`, `is-writable`, `is-editable`, `is-subfolder-allowed` und die Beziehung `parent`. | Doku |
| Wer hochladen darf | „Ob man eine Datei erstellen darf, entscheidet die Implementierung des Ordners.“ Ein `StandardFolder` erlaubt alles, alle anderen Typen entscheiden selbst. Die App verlässt sich nur auf `is-writable`. | Doku |
| Hochladen | `POST jsonapi.php/v1/folders/{id}/file-refs` mit `multipart/form-data`, Dateifeld `file` (Beispiel `curl -F 'file=@…'`). Der Name kommt aus dem Upload, eine Kopfzeile `Slug` überschreibt ihn. Bei Erfolg: **201** mit `Location` der neuen Datei. | Doku. Fehlercodes stehen nicht in der Doku. |
| Zweiter Weg | Erst die Datei als JSON:API-Objekt anlegen (`terms-of-use` ist dabei Pflicht), dann den Inhalt senden. Die App nutzt diesen Weg nicht. | Doku |
| Lizenz | Für jede Datei muss eine Lizenz gesetzt werden. `GET terms-of-use`, `PATCH file-refs/{id}/relationships/terms-of-use`. Die App setzt danach „Selbst verfasstes, nicht publiziertes Werk“ (`SELFMADE_NONPUB`). Gelingt das nicht, bleibt die Abgabe trotzdem bestehen. Welche Lizenz Stud.IP beim Multipart-Weg selbst setzt, ist **unbekannt**. | Doku / Annahme |
| Hausaufgabenordner | Typ `HomeworkFolder`. Studierende können hochladen, sehen aber nur ihre eigenen Dateien. Lehrende und Tutor:innen sehen alle (Anleitungen RheinMain und Göttingen). | Anleitungen |
| Zeitgesteuerter Ordner | Typ `TimedFolder`. Nimmt nur in einem Zeitraum Dateien an, oft mit Recht „w – nur schreiben“ (Bremen). Außerhalb des Zeitraums erwartet die App `is-writable: false`. Ob die JSON:API Beginn und Ende des Zeitraums liefert, ist **unbekannt**. | Anleitungen / Annahme |
| Anmeldung | Die JSON:API nimmt Basic-Auth, das Stud.IP-Sitzungs-Cookie oder OAuth2 an. Die App nutzt wie beim Abgleich das Sitzungs-Cookie. | Doku |
| CSRF / Sicherheits-Token | Die Doku schweigt dazu. Stud.IP-Formulare prüfen ein `security_token`. Ob die JSON:API bei schreibenden Anfragen mit Sitzungs-Cookie ein Token verlangt, ist **unbekannt**. Die App sendet `X-Requested-With: XMLHttpRequest`, für den Fall, dass Skript-Anfragen ausgenommen sind. Ein 403 mit „CSRF“ oder „token“ meldet die App eigens (siehe 2.4). | **unbekannt** |
| Größe | Die Doku nennt keine Grenze. Die Grenze legt die Hochschule je Rolle fest (`UPLOAD_TYPES`); in der Grundeinstellung sind es nach unserer Kenntnis 7 MB für Studierende. Dazu kommt die PHP-Grenze. Der Wert an der LUH ist **unbekannt**. | Annahme |

## 2. Ablauf auf dem iPad

### 2.1 Einstieg

Im Dokument: Menü **Teilen → Abschnitt „Abgeben“ → „In Stud.IP abgeben …“** (`doc.submitStudIP`).

- Nur auf dem Gerät (lokales Backend), nur an Hochschulen mit Stud.IP (LUH).
- Nicht in alten Fassungen und nicht nur zum Ansehen.
- Gab es schon eine Abgabe, steht darunter „Abgegeben am 05.11.2026, 14:30 in Analysis I Übung › Übungen/Abgabe Blatt 3“.

### 2.2 Blatt „In Stud.IP abgeben“ (`StudIPSubmitSheet`)

| Teil | Verhalten | Kennung |
| --- | --- | --- |
| Hinweis oben | „Die Datei wird an deine Hochschule hochgeladen (Stud.IP). Lehrende sehen sie; in normalen Ordnern auch andere Teilnehmende des Kurses.“ | `submit.warning` |
| Kurs | Auswahl aus den Stud.IP-Kursen des Containers (`/api/courses`, nur 32-stellige Stud.IP-Kennungen, nur aktive). Vorausgewählt wird der Kurs der Datei. Sonst die Übung des Moduls, sonst der einzige Kurs des Moduls. Die Kurse des Moduls stehen oben. | `submit.course` |
| Zielordner | **Nur** sichtbare Ordner mit `is-writable: true`. Abgabeordner stehen zuerst: zuerst der Hausaufgabenordner (hinterlegt, Unterzeile „Abgabeordner – nur du und die Lehrenden sehen deine Datei“), dann zeitgesteuerte Ordner und Ordner mit „Abgabe/Hausaufgabe/Einreichung“ im Namen, dann der Rest, der Hauptordner zuletzt. Vorausgewählt wird der erste Hausaufgabenordner, sonst der erste Abgabeordner, sonst nichts. Geschlossene Abgabeordner stehen in einer Fußzeile: „Derzeit geschlossen (Frist vorbei oder noch nicht offen): …“. | `submit.folder.<id>`, `submit.closedFolders` |
| Dateiname | Vorschlag „Nachname_Blatt3.pdf“. Der Nachname kommt aus `users/me` (`family-name`), die Blattnummer aus dem Titel (Übungsblatt, Blatt_03, Aufgabenblatt, Hausaufgabe, Übung, Sheet, Exercise). Ohne Nummer wird daraus „Nachname_Titel.pdf“. Umlaute werden umgeschrieben (ü → ue), erlaubt sind nur Buchstaben, Ziffern, `-`, `_` und `.`. Der Name ist änderbar. | `submit.fileName` |
| Schalter | „Notizen und Blätter mitschicken“, Standard **an**. Er steuert `NotesExport.Options.includeSideNotes`: Blattseiten stehen hinter ihrer Folie. Die eigene Tinte auf den Folien ist die Lösung und geht immer mit, ebenso nicht leere Seitennotizen (eingefügte Leerseiten). | `submit.withNotes` |
| Vorschau | „6 Seiten · 1,2 MB“ aus der fertigen PDF. Über 7 MB erscheint ein Hinweis „Manche Stud.IP-Ordner nehmen nur bis 7 MB an.“ (die Abgabe wird nicht gesperrt). | `submit.preview`, `submit.sizeNotice` |
| Knopf | **„Jetzt abgeben“**. Erst aktiv, wenn Ordner, Name und PDF da sind. | `submit.confirm` |
| Ergebnis | „Abgegeben – Datei liegt jetzt in Kurs › Ordner“. Darunter **„In Stud.IP öffnen“**: der Ordner im In-App-Browser (`dispatch.php/course/files/index/{ordner}?cid={kurs}`, angemeldet, `UniLinks`). | `submit.openInStudIP` |
| Verlauf | „Bisher abgegeben“ mit „Abgegeben am … in …“ und dem Dateinamen | `submit.history` |

Die PDF kommt aus **derselben Funktion wie „PDF exportieren“**: `NotesExport.pdf(for:api:options:)`
(`docs/NOTIZEN-MITSCHICKEN-2026-11-05.md` 4.2), mit `folder: "abgabe"`. Die App baut keinen eigenen Export.

### 2.3 Anmeldung

- Beim Öffnen des Blatts: `StudIPSync.ensureSession(.userAction)`. Diese Stelle prüft `users/me` und erneuert bei Ablauf
  still über das WebSSO (§13).
- Gelingt das nicht, zeigt das Blatt „Bitte bei Stud.IP anmelden“ mit Knopf „Bei Stud.IP anmelden“. Dahinter liegt
  dieselbe `StudIPLoginView` wie in den Einstellungen; iOS setzt das Passwort ein. Danach geht es im Blatt weiter.
- Meldet Stud.IP beim Laden der Ordner oder beim Hochladen „abgelaufen“ (401 oder Weiterleitung auf die Anmeldung),
  erneuert die App still und versucht es **genau einmal** neu. Das ist sicher, weil Stud.IP bei 401 nichts angenommen
  hat. Sonst folgt die Anmeldung im Blatt.
- Ist Stud.IP nicht verbunden (nie angemeldet, andere Hochschule), erscheint „Stud.IP ist nicht verbunden“.

### 2.4 Fehler

| Fall | Erkennung | Anzeige |
| --- | --- | --- |
| Abgelaufen | 401, Weiterleitung 302/303 auf die Anmeldung, Anmeldeseite statt JSON | still erneuern → einmal neu, sonst Anmeldung |
| Ordner nimmt nichts an | 403 | „Dieser Ordner nimmt gerade keine Dateien an. Vielleicht ist die Abgabefrist vorbei oder der Ordner noch nicht geöffnet.“ |
| Frist vorbei (vorab) | Abgabeordner mit `is-writable: false` | Fußzeile „Derzeit geschlossen …“, nicht wählbar |
| Zu groß | 413, oder 400/403/422 mit „zu groß/too large/maximal/filesize“ | „Die Datei ist zu groß für Stud.IP. Schicke sie ohne Notizen oder verkleinere eingefügte Bilder.“ |
| Sicherheits-Token | 403 mit „csrf/security token“ | „Stud.IP hat das Hochladen aus der App abgelehnt (Sicherheitsprüfung). Öffne den Ordner in Stud.IP und lade die Datei dort hoch.“ und Knopf „Ordner in Stud.IP öffnen“ |
| Anderes | anderer Status, kein Netz | „Stud.IP antwortet mit HTTP n. Die Datei wurde nicht abgegeben.“ bzw. „Keine Verbindung …“ |

Fehler werden nie still wiederholt. 5xx und 429 lösen kein zweites Hochladen aus, sonst läge die Abgabe doppelt da.

### 2.5 Verlauf

`StudIPSubmissionLog` liegt als JSON in den Einstellungen des Containers (`uniflow.studip.submissions`), nur auf
diesem Gerät, höchstens 300 Einträge, die neuesten zuerst. Je Eintrag gespeichert werden: Dokument, Zeitpunkt, Kurs,
Ordner, Dateiname, Link, mit/ohne Notizen und Seitenzahl. Die PDF selbst wird nicht gespeichert. „Daten dieser
Hochschule löschen“ entfernt den Verlauf mit dem Container.

## 3. Umsetzung

- **Kern** `UniFlowCore/StudIPSubmit.swift`:
  - `StudIPWritingTransport` (Protokoll nur fürs Schreiben)
  - `StudIPClient.ownName()`, `uploadFolders(courseID:)`, `upload(_:fileName:folder:)` mit Lizenz als bestem Versuch
  - `StudIPSubmit`: Dateiname, Multipart, Ordnerliste, Fehlerzuordnung, Lizenzwahl
  - `StudIPSubmissionRecord`, `StudIPSubmissionLog`
  - In `StudIPClient.swift`: `HTTPReply.location`; `perform` ist modulweit sichtbar.
- **App:**
  - `Services/StudIPSubmitter.swift`: `URLSessionStudIPWriter` (eigener schreibender Transport) und
    `StudIPSubmitModel` (Ablauf). Der Abgleich behält `URLSessionStudIPTransport`, der nicht schreiben kann.
  - `Views/StudIPSubmitSheet.swift`: Blatt und `StudIPSubmitEntry`.
  - `DocumentView`: Menüeintrag und Blatt.
  - `DebugUniStub`: Routen mit `method` und `location`, damit die Nachbildung das Abgeben spielen kann.
- **Tests:**
  - Kern `StudIPSubmitTests`: Ordnerfilter, Multipart-Koerper, Fehlerzuordnung, kein zweites POST, abgelaufene Sitzung,
    Lizenz, Name, Verlauf.
  - App `StudIPSubmitAppTests`: `URLProtocol`-Stub mit Cookie und Multipart, Weiterleitung auf die Anmeldung,
    Lesetransport kann nicht schreiben, Ablauf mit Vorauswahl, Neuanmeldung mit genau einem zweiten Versuch,
    geschlossener Ordner, Blatt über die Bedienungshilfe (Hinweis, Ordnerreihenfolge, geschlossener Ordner nicht wählbar, Absenden, Link).

## 4. Einmal echt prüfen (Inhaber, mit eigenem Konto)

Am besten in einem Kurs, in dem ein Test nicht stört: eigener Arbeitsbereich oder ein Übungskurs mit Hausaufgabenordner.

1. App auf dem iPad, bei Stud.IP angemeldet. Ein PDF-Blatt öffnen, etwas daraufschreiben, eine Seitennotiz einfügen.
2. Teilen → „In Stud.IP abgeben …“. Prüfen:
   - Ist der Kurs richtig vorausgewählt?
   - Stehen nur Ordner da, in die du im Browser hochladen darfst?
   - Ist der Hausaufgabenordner oben?
   - Stimmt der Name „Nachname_BlattN.pdf“?
3. „Jetzt abgeben“, dann „In Stud.IP öffnen“: Liegt die Datei im Ordner? Sind Notizen und Seitennotiz in der PDF?
   Welche Lizenz zeigt Stud.IP bei der Datei?
4. Kommt statt „Abgegeben“ die Meldung „Sicherheitsprüfung“: Stud.IP verlangt ein CSRF-Token. Dann muss die App das
   Token aus der Dateiseite lesen (Folgeauftrag).
5. Optional: eine Datei über 7 MB, um die Grenze der LUH zu sehen, und ein geschlossener Abgabeordner.
6. Die Datei in Stud.IP wieder löschen, falls es nur ein Test war.

Ergebnis bitte notieren: Status der Antwort (201?), Lizenz, CSRF ja/nein, Größengrenze.

## 5. Learnweb (Moodle, Uni Hildesheim) – später

Nicht umgesetzt. Mit dem vorhandenen Learnweb-Schlüssel (Dienst `moodle_mobile_app`, `docs/AUFTRAG-HILDESHEIM-IPAD.md`)
wären es drei Schritte ([Moodle: Dateien über Web-Services](https://moodledev.io/docs/apis/subsystems/external/files)):

1. `POST /webservice/upload.php?token=…` (multipart, `filepath=/`): legt die Datei im eigenen Entwurfsbereich ab und
   liefert die `itemid`. Der Dienst muss das Hochladen erlauben; ob er das an der Uni Hildesheim tut, ist zu prüfen.
2. `mod_assign_save_submission` (`assignmentid`, `plugindata[files_filemanager]=<itemid>`): legt die Abgabe als Entwurf an.
3. Falls die Aufgabe „Abgabe bestätigen“ verlangt: `mod_assign_submit_for_grading` (`acceptsubmissionstatement=1`, nur
   nach ausdrücklicher Bestätigung im Blatt).

Dazu kommt `mod_assign_get_assignments` bzw. `mod_assign_get_submission_status`, die Frist und Zustand liefern
(`duedate`, `cutoffdate`, `allowsubmissionsfromdate`, `cansubmit`). Damit wäre „Frist vorbei“ vor dem Hochladen
sicher erkennbar. Das Blatt bliebe dasselbe; statt Ordnern stünden dort die Aufgaben des Kurses. Aufwand etwa wie die
Stud.IP-Fassung, braucht aber einen Test mit einem Hildesheimer Konto.

## 6. Web und Windows

**Windows-App/Einzelplatz seit 05.11.2026 umgesetzt**; im gehosteten Dienst weiterhin nicht (`docs/IPAD-STUDIP-SYNC.md`
§8: keine Cookies auf eigenen Servern; der Menüpunkt fehlt dort). Im Web-Editor: Export-Menü → „In Stud.IP abgeben …“
(`app/static/studip-submit.js`). Die PDF baut derselbe Export wie „Exportieren“ (`Editor.exportPdf(…, { bytes: true })`,
Seitennotizen und Blätter über `side-notes.js`). Server `app/studip_submit.py` (gleiche Regeln wie `StudIPSubmit.swift`)
mit der gemerkten Stud.IP-Sitzung (`app/studip_live.py`, stille Erneuerung bei 401 genau einmal): `GET /api/studip/submit`,
`GET /api/studip/submit/folders`, `POST /api/studip/submit`; vor dem Hochladen prüft der Server, dass der Ordner
gerade beschreibbar ist. Verlauf `studip_submissions` (nur dieser PC). Ohne Abo gesperrt. Tests:
`tests/test_studip_submit.py`. Echt prüfen: wie Abschnitt 4, in der Windows-App.
