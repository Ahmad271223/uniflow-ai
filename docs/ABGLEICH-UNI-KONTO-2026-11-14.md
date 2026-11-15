# Geräte-Abgleich je Uni-Konto (14.11.2026)

Zweig `fix/abgleich-uni-konto` (von `develop`, Build 42). Nichts gepusht, nichts ausgerollt.

## Der Fehler

Am echten iPhone stehen 15 Fächer: 7 eigene (mit Kursen und Dateien) und 8 leere, die am 11.11.2026 19:03 über den
Geräte-Abgleich kamen. Ein anderes Gerät war mit demselben StudiNow-Konto (gleiche Apple-ID), aber einem anderen
Uni-Zugang verbunden. Mit den Fächern kam dessen Stundenplan (23 Termine). Im selben Augenblick hat das fremde Gerät
auch eines der eigenen Fächer im Dienst geändert (Version 2, gleicher Zeitstempel): Der Abgleich ließ also nicht nur
Lesen, sondern auch Schreiben und Löschen über die Grenze zweier Uni-Konten zu.

## Ist-Zustand des Abgleichs (10 Zeilen)

1. Je StudiNow-Konto eine Datenbank im Dienst; zwölf Tabellen gleichen ab (`app/sync.py::ENTITIES`).
2. Jede Zeile trägt `sync_version`, `sync_updated_at`, `sync_device` (Gerät der letzten Änderung, leer = Web/Dienst).
3. Abruf `GET /api/sync/changes?since=…` liefert alle Zeilen und Löschmarken nach dem Zeitstempel – an jedes Gerät.
4. Senden `POST /api/sync/push`: neue Zeilen, Änderungen (je Feld gewinnt der spätere), Löschungen.
5. Das Gerät merkt sich je Zeile die Nummer im Dienst (`sync_link_map`); erster Abgleich über Name/Inhalt ohne Doppelte.
6. Was das Gerät aus dem Dienst übernimmt, trägt lokal `sync_device = '~dienst'` und wird nie zurückgesendet.
7. Seit 12.11.2026 schicken Apple-Apps (1.0.3, Builds 34–41) `studip_user`: Hash der Stud.IP-Kennung des Geräts.
8. Der Dienst merkt sich den ersten Hash je Konto; ein anderer bekommt 409 `studip_user_mismatch` (Abgleich hält an).
9. Die Sperre kam nach der Vermischung (11.11.), räumt nichts auf, und wer zuerst kommt, sperrt den anderen ganz aus.
10. Windows-App, Web und Apps bis 1.0.2 schicken nichts; Löschungen eines Geräts gelten für alle.

## Lösung: ein „Raum“ je Uni-Konto

**Uni-Schlüssel (Gerät).** `SHA-256("studinow-uni-konto|" + StudiNow-Konto-ID + "|" + Hochschule + "|" + Kennung)`.
Kennung ist bei der LUH der schon lokal gespeicherte Hash der Stud.IP-Nutzer-ID (`settings.studip_user_hash`,
`StudIPUserMark`); die Stud.IP-Kennung selbst liegt nirgends. An den Dienst gehen nur Hashes (`uni_key`, wie bisher
`studip_user`), kein Name, keine Matrikelnummer.

| Hochschule | Kennung | Stand |
|---|---|---|
| LUH | Stud.IP-Nutzer-ID (`users/me`), als Hash | sicher, schon auf jedem Gerät ab 1.0.3 |
| Hildesheim | Learnweb-Nutzer-ID gilt nur je Semester-Instanz (learnweb2026, learnweb2027 …) | **keine sichere Kennung** |
| HsH (nicht veröffentlicht) | Moodle-Nutzer-ID nur aus der Seite | **keine sichere Kennung** |

**Regel je Hochschule (Entscheidung des Inhabers vom 14.11.2026: „Ja, wie bisher“).**

- **LUH (sichere Kennung):** Abgleich nur mit dem Schlüssel des Uni-Kontos, Trennung wie unten beschrieben. Solange auf
  dem Gerät noch nie Stud.IP abgeglichen wurde, gibt es keinen Schlüssel und die App gleicht nicht zwischen Geräten ab
  (kurzer Hinweis in den Konto-Einstellungen). Lokale Daten bleiben unberührt.
- **Hildesheim, HsH (keine sichere Kennung):** Der Abgleich läuft **wie in 1.0.4 weiter**, auch für Notizen (Pro AI),
  ohne Hinweis. Die App schickt dort einen Schlüssel nur aus StudiNow-Konto und Hochschule
  (`UniAccountKey.universityOnly`, Kennung = `ohne-kennung`). Alle Geräte dieser Hochschule unter dem Konto teilen damit
  einen Raum. Der Dienst rechnet diesen Schlüssel für das Konto der Anfrage selbst nach (`sync.university_key`) und
  merkt ihn am Raum (`sync_rooms.plain`): Ist das der einzige Raum des Kontos, zählt er für die Regeln nicht – dann
  gilt für alle Geräte, auch für 1.0.4 ohne jeden Hash, alles wie vor den Räumen (Sehen, Ändern, Löschen, Notizen).

**Mischfall LUH + Hildesheim unter einem StudiNow-Konto** (sicher zwei verschiedene Uni-Konten), dreifach abgesichert:
1. Die App gleicht ein Gerät, dessen Hochschule nicht die des Kontos ist, gar nicht ab (`StudoraAccountLink.canSync`).
2. Der Dienst führt je Konto **und Hochschule** eine eigene Datenbank (`config.user_data_dir`).
3. Käme die Anfrage trotzdem in derselben Datenbank an: Der Hildesheimer Schlüssel enthält die Hochschule und ist
   deshalb nie ein LUH-Schlüssel → zwei Räume → getrennt, in beide Richtungen kein Ändern und kein Löschen
   (`tests/test_sync_rooms.py::test_luh_device_and_hildesheim_device_under_one_account_are_separated`).

**Verbleibende Lücke, bewusst:** Zwei verschiedene Hildesheimer Uni-Konten unter einem StudiNow-Konto (gleiche
Apple-ID) haben denselben Schlüssel und teilen weiter wie in 1.0.4.

**Offener Folgeschritt:** der Learnweb-Anmeldename als Kennung (`core_webservice_get_site_info`, nur bei Learnweb mit
Schlüssel vorhanden) – erst nach Prüfung am echten Testzugang. Dabei mitzudenken: Die Geräte wechseln dann vom
gemeinsamen Raum der Hochschule in den Raum ihres Uni-Kontos; der Dienst muss diesen Raum als Nachfolger übernehmen
(sonst gälten die bisherigen Zeilen als fremd).

**Dienst.** Drei kleine Tabellen in der Konto-Datenbank, keine neue Spalte an den Datentabellen (eine Spalte hätte
über die Trigger jede Zeile neu gestempelt):

- `sync_rooms(id, uni_key, studip_user, plain)` – ein Raum je Uni-Konto. Alter Hash und neuer Schlüssel zeigen auf
  denselben Raum. `plain` = 1: Raum einer Hochschule ohne sichere Kennung (Schlüssel ohne Nutzerkennung).
- `sync_devices(device_id, room)` – in welchem Raum ein Gerät zuletzt war.
- `sync_row_room(entity, entity_id, room, origin, assigned_at)` – Raum und Ursprungsgerät je Zeile.

Die drei Tabellen gibt es **nur im Dienst** (wie `sync_ops`); das Gerät kennt nur seinen eigenen Schlüssel
(`sync_link_state`). Der Schema-Vergleich „lokale Swift-Datenbank = Python init_db“ nimmt sie deshalb aus
(`SQLiteStoreTests`, `serviceOnlyTables`), und `testRoomTablesExistOnlyAtTheService` hält fest, dass sie im Dienst
stehen und auf dem Gerät nie entstehen.

Regeln (`app/sync.py`, Klasse `Rooms`):

- **Getrennt wird, sobald der Dienst zwei Uni-Konten unter dem StudiNow-Konto kennt** (zwei Räume). Solange es nur
  einen Raum gibt, sieht und ändert jedes Gerät alles wie bisher. Grund: Zeilen eines Geräts, das sich nie wieder meldet
  (App neu installiert, altes Handy), lassen sich keinem Uni-Konto zuordnen; wären sie ab dem ersten Tag unsichtbar,
  fehlten sie fast jedem Nutzer mit nur einem Uni-Konto.
- Ab zwei Räumen: Neue Zeilen gehören zum Raum des Geräts. Ein Gerät mit Raum bekommt nur Zeilen und Löschmarken
  seines Raums und ändert nur sie. Zeilen ohne Raum (Web, Geräte unbekannter Herkunft) gehen an kein Gerät mit Raum.
- **Löschen ist immer geschützt**, auch bei nur einem Raum: Löscht ein Gerät mit Raum eine Zeile ohne Raum, gehört
  die Löschung seinem Raum. Die Löschmarke geht nur an diesen Raum und nie an das Ursprungsgerät, solange dessen
  Uni-Konto offen ist. Gehört es später zu einem anderen Raum, erfährt es die Zeile als fremd, behält seine Fassung
  und legt sie in seinem Raum neu an. Gehört es zum selben Raum, holt es die Löschmarke dann nach.
- Was nicht erlaubt ist, bekommt je Eintrag eine Antwort ohne Wirkung im Dienst, nie einen Fehler: `other_room` (die
  Zeile gehört nachweislich einem anderen Raum) oder `room_pending` (Herkunft der Zeile noch offen – später noch
  einmal senden). Ältere Apps kennen beide nicht und tun nichts: die Änderung bleibt bei ihnen vorgemerkt und geht
  beim nächsten Abgleich wieder mit. (Ein stilles „übernommen“ wäre gefährlich: der Stand des Dienstes hätte die
  Änderung später überschrieben.)
- Löschen einer Zeile, an der Zeilen eines anderen Raums hängen, wird nicht ausgeführt.
- Doppelte Fächer (gleicher Name) werden im Dienst nur noch innerhalb eines Raums zusammengelegt
  (`study.merge_duplicate_modules`).
- Kein 409 `studip_user_mismatch` mehr: das zweite Uni-Konto bekommt seinen eigenen Raum.

## Migration (automatisch, wiederholbar)

`sync.ensure_schema` (läuft je Konto-Datenbank beim ersten Kontakt nach dem Update, eine Transaktion):
legt die drei Tabellen an (`IF NOT EXISTS`), überspringt fehlende Datentabellen, trägt einmalig je vorhandener Zeile das
Ursprungsgerät ein: zuerst aus `sync_ops` („angelegt von“), sonst `sync_device` (letzter Schreiber). Ein Marker
(`~meta/backfill`) verhindert die Wiederholung. Es wird nichts gelöscht und keine Datenzeile angefasst.
`sync_ops` reicht 90 Tage zurück (also über den 11.11.2026 hinaus). Wo der Eintrag fehlt und ein fremdes Gerät die
Zeile zuletzt geändert hat, kann der Rückfall falsch zuordnen; das Aufräumen behält dann auf dem eigenen Gerät alles
mit Inhalt und legt es als eigene Zeile neu an – schlimmstenfalls bleibt auf dem anderen Gerät ein leeres Fach stehen.

**Altbestand.** Zeilen ohne Raum bleiben im Dienst. Meldet ein Gerät zum ersten Mal Schlüssel oder Hash, bekommen
alle Zeilen mit diesem Ursprungsgerät seinen Raum (`assigned_at` = jetzt; Geräte desselben Raums holen sie damit
nach, auch wenn ihr Zeitstempel schon weiter ist). Ab zwei Räumen gehen Zeilen eines noch unbekannten Geräts an kein
Gerät mit Raum; Änderungen daran warten (`room_pending`) und kommen an, sobald sich das Gerät im selben Raum meldet.

## Ältere Clients

| Client | schickt | Verhalten nach dem Dienst-Update |
|---|---|---|
| Apple 1.0.3, Builds 34–41 | `studip_user` | bekommt sofort einen Raum, kein 409 mehr. Ein Uni-Konto im StudiNow-Konto: alles wie bisher. Zwei: sieht und ändert nur noch seinen Raum; kein Aufräumen (das kann erst die neue App) |
| Apple bis 1.0.2, Windows-App alt | nichts | Konto ohne Raum: genau wie bisher. Ein Raum: sieht und ändert weiter alles, löscht aber nur Eigenes und Web-Zeilen. Zwei Räume: sieht und ändert nur Zeilen ohne Raum |
| Hildesheim 1.0.4 | nichts | genau wie bisher, auch neben Geräten mit der neuen App (deren Raum zählt dort nicht) |
| Web | – | zeigt weiter alle Zeilen des Kontos (kein Uni-Zugang im Browser) |

Kein Fall liefert einen Fehler, keiner löscht Daten auf einem Gerät eines anderen Uni-Kontos. Eine nicht angenommene
Löschung bleibt lokal gelöscht; im Dienst und auf den anderen Geräten bleibt die Zeile.

Bewusste Grenze: Solange der Dienst nur ein Uni-Konto kennt, kann er ein stilles Gerät mit einem zweiten Uni-Konto
nicht erkennen. Was davon schon vermischt ist, bleibt bis dahin, wie es ist; neu mischen kann nur noch ein Gerät, das
gar keinen Hash schickt (App bis 1.0.2). Apple-Geräte ab 1.0.3 melden sich beim nächsten Öffnen der App von selbst.

## Aufräumen auf dem Gerät (neue App)

Beim ersten Abgleich mit Schlüssel holt die App einmal alles neu ab. Der Dienst nennt dabei unter `foreign` die
Zeilen, die nachweislich einem anderen Raum gehören. Für jede davon, die das Gerät kennt (`sync_link_map`):

1. Die Verknüpfung zum Dienst wird gelöst (ebenso bei der Antwort `other_room` auf eine eigene Änderung).
2. Die lokale Zeile verschwindet nur, wenn **alles** gilt: sie kam aus dem Dienst (`~dienst`), wurde hier nie
   geändert, und nichts auf dem Gerät hängt an ihr (kein Kurs, keine Datei, kein Lernpaket, keine Karte, keine Notiz,
   kein Termin … – geprüft über alle Tabellen mit Verweis). Die Löschmarke trägt `~dienst` und wird nie gesendet.
3. Sonst bleibt sie und wird beim nächsten Senden als neue Zeile im eigenen Raum angelegt (mit ihren Kindern).

Kinder zuerst, dann Eltern; im Zweifel bleibt alles.

**Das belegte iPhone** (Kopie vom 14.11.2026, nur Tabellen und Abgleich-Spalten angesehen): 15 Fächer, alle aus dem
Dienst übernommen. An den 8 fremden hängen 23 Termine mit 48 Ausnahmen (der Stundenplan des anderen Uni-Kontos) und
sonst nichts; an den 7 eigenen hängen 10 Kurse, die Dateien, 10 Lernpakete und 21 Termine. Nach dem Update von Dienst
und App: Sobald das andere Gerät einmal abgeglichen hat (ab App 1.0.3 genügt das Öffnen der App, es schickt seinen
Stud.IP-Hash schon), nennt der Dienst seine Zeilen als fremd → die 8 leeren Fächer samt Terminen verschwinden auf dem
iPhone, ohne Löschmarke. Die 7 eigenen bleiben. Auf dem anderen Gerät bleiben seine 8 Fächer; die 7 fremden, dort
leeren Fächer verschwinden dort, sobald es die neue App hat. **Meldet sich das andere Gerät nie wieder** (abgemeldet,
gelöscht, App bis 1.0.2), bleibt der Beweis aus und die 8 Fächer bleiben auf dem iPhone stehen. Sie von Hand zu
löschen ist dann gefahrlos: die Löschung gilt für die eigenen Geräte; das andere Gerät bekommt die Löschmarke nie,
behält seine Fächer und legt sie, falls es sich doch meldet, in seinem Raum neu an.

## Web und Windows

- Windows (`app/sync_client.py`): merkt sich beim Stud.IP-Abgleich denselben Hash und schickt `studip_user` + `uni_key`;
  gleiches Aufräumen. Ohne Stud.IP-Abgleich unverändert (schickt nichts, gilt beim Dienst als älterer Client).
- Web: unverändert. Bei zwei Uni-Konten unter einem StudiNow-Konto zeigt der Browser die Zeilen beider Räume; was im
  Browser angelegt wird, gehört zu keinem Raum und erreicht dann kein Gerät mit Raum (bei einem Raum wie bisher alle).

## Tests

- Dienst: `tests/test_sync_rooms.py` (Regeln, Altbestand, Migration alt/halb/leer, Schnittstelle),
  `tests/test_sync.py` (Vertrag `fixtures/sync/cases.json`, neuer Fall `raeume-je-uni-konto`).
- Aufräum-Fall mit erfundenen Daten: `tests/test_sync_rooms_cleanup.py` (Client wie Windows gegen den Dienst),
  `DeviceSyncUniRoomTests` (Swift-Kern, Schein-Dienst), `DeviceSyncLiveTests.testTwoUniAccountsUnderOneAccountAreSeparatedAgain`
  (Swift-Kern gegen den echten Dienst: `tools/g2-testdienst.py`).
- App: `AuditPaket40x45AppTests.testDeviceSyncWaitsForTheUniAccountAndThenSendsItsKey`,
  `testHildesheimKeepsSyncingWithoutASecureIdentity`, `testDeviceOfAnotherUniversityThanTheAccountDoesNotSync`.
- Hildesheim und Mischfall im Dienst: `tests/test_sync_rooms.py` (`…keeps_syncing_as_in_1_0_4`,
  `…luh_device_and_hildesheim_device…`, `…two_hildesheim_accounts…still_share`, `test_api_hildesheim_account…`).

## Server-Update

1. Reihenfolge: zuerst der Dienst, die App kann später kommen (und umgekehrt: die neue App läuft gegen den alten
   Dienst wie bisher, inklusive der alten 409-Meldung).
2. Migration läuft von selbst je Konto beim ersten Kontakt (Schema-Kennzahl ändert sich, `db.init_db(fast=True)`), in
   einer Transaktion; drei neue Tabellen, keine Änderung an Datenzeilen. Vorher wie üblich Sicherung der Kontodaten.
3. Rückweg: alten Code wieder ausrollen genügt. Die drei Tabellen bleiben liegen und stören nicht (der alte Code
   kennt sie nicht). Achtung: der alte Code sperrt dann wieder mit 409 nach `settings.studip_user_hash`, und Zeilen,
   die inzwischen in getrennten Räumen angelegt wurden, sieht dann wieder jedes Gerät.
