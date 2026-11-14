# Geräte-Abgleich je Uni-Konto (14.11.2026)

Zweig `fix/abgleich-uni-konto` (von `develop`, Build 42). Nichts gepusht, nichts ausgerollt.

## Der Fehler

Am echten iPhone stehen 15 Fächer: 7 eigene (mit Kursen und Dateien) und 8 leere, die am 11.11.2026 19:03 über den
Geräte-Abgleich kamen. Ein anderes Gerät war mit demselben StudiNow-Konto (gleiche Apple-ID), aber einem anderen
Uni-Zugang verbunden. Ein neuntes Fach („Mathematik für die Ingenieurwissenschaften …“) hatten beide: es wurde über
Name + Semester zu einer Zeile im Dienst zusammengelegt.

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

Ohne sichere Kennung schickt das Gerät keinen Schlüssel und die neue App gleicht Fächer und Pläne dort **nicht** ab
(vorsichtigste Lösung: nicht mischen); Hinweis in den Konto-Einstellungen. Lokale Daten bleiben unberührt.

**Dienst.** Drei kleine Tabellen in der Konto-Datenbank, keine neue Spalte an den Datentabellen (eine Spalte hätte
über die Trigger jede Zeile neu gestempelt):

- `sync_rooms(id, uni_key, studip_user)` – ein Raum je Uni-Konto. Alter Hash und neuer Schlüssel zeigen auf denselben Raum.
- `sync_devices(device_id, room)` – in welchem Raum ein Gerät zuletzt war.
- `sync_row_room(entity, entity_id, room, origin, assigned_at)` – Raum und Ursprungsgerät je Zeile.

Regeln (`app/sync.py`, Abschnitt „Räume“):

- Neue Zeile eines Geräts mit Raum gehört zu diesem Raum. Abruf: ein Gerät mit Raum bekommt nur Zeilen und
  Löschmarken seines Raums, dazu Zeilen ohne Raum und ohne Ursprungsgerät (Web), solange das Konto genau einen Raum hat.
- Ändern und Löschen nur im eigenen Raum. Fremde Zeile: Antwort `other_room` (neue App) bzw. für ältere Apps ein
  stilles „erledigt“ ohne Wirkung im Dienst – nie ein Fehler.
- Löschen einer Zeile, an der Zeilen eines anderen Raums hängen, wird nicht ausgeführt.
- Doppelte Fächer (gleicher Name) werden im Dienst nur noch innerhalb eines Raums zusammengelegt
  (`study.merge_duplicate_modules`).
- Kein 409 `studip_user_mismatch` mehr: das zweite Uni-Konto bekommt seinen eigenen Raum.

## Migration (automatisch, wiederholbar)

`sync.ensure_schema` (läuft je Konto-Datenbank beim ersten Kontakt nach dem Update, eine Transaktion):
legt die drei Tabellen an (`IF NOT EXISTS`), überspringt fehlende Datentabellen, trägt einmalig je vorhandener Zeile das
Ursprungsgerät ein: zuerst aus `sync_ops` („angelegt von“), sonst `sync_device` (letzter Schreiber). Ein Marker
(`~meta/backfill`) verhindert die Wiederholung. Es wird nichts gelöscht und keine Datenzeile angefasst.

**Altbestand.** Zeilen ohne Raum bleiben im Dienst. Meldet ein Gerät zum ersten Mal Schlüssel oder Hash, bekommen
alle Zeilen mit diesem Ursprungsgerät seinen Raum (`assigned_at` = jetzt; Geräte desselben Raums holen sie damit
nach, auch wenn ihr Zeitstempel schon weiter ist). Zeilen eines noch unbekannten Geräts gehen an kein Gerät mit Raum.

## Ältere Clients

| Client | schickt | Verhalten nach dem Dienst-Update |
|---|---|---|
| Apple 1.0.3, Builds 34–41 | `studip_user` | bekommt sofort einen Raum, sieht und ändert nur noch ihn; kein 409 mehr; kein Aufräumen |
| Apple bis 1.0.2, Windows-App alt, andere Hochschulen | nichts | Konto ohne Raum: alles wie bisher. Konto mit einem Raum: sieht weiter alles, darf Raum-Zeilen ändern, aber nicht löschen. Konto mit zwei Räumen: sieht und ändert nur Zeilen ohne Raum |
| Web | – | zeigt weiter alle Zeilen des Kontos (kein Uni-Zugang im Browser) |

Kein Fall liefert einen Fehler, keiner löscht Daten. Eine abgelehnte Löschung bleibt lokal gelöscht, im Dienst und
auf den Geräten des anderen Raums bleibt die Zeile.

## Aufräumen auf dem Gerät (neue App)

Beim ersten Abgleich mit Schlüssel holt die App einmal alles neu ab. Der Dienst nennt dabei unter `foreign` die
Zeilen, die nachweislich einem anderen Raum gehören. Für jede davon, die das Gerät kennt (`sync_link_map`):

1. Die Verknüpfung zum Dienst wird gelöst.
2. Die lokale Zeile verschwindet nur, wenn **alles** gilt: sie kam aus dem Dienst (`~dienst`), wurde hier nie
   geändert, und nichts auf dem Gerät hängt an ihr (kein Kurs, keine Datei, kein Lernpaket, keine Karte, keine Notiz,
   kein Termin … – geprüft über alle Tabellen mit Verweis). Die Löschmarke trägt `~dienst` und wird nie gesendet.
3. Sonst bleibt sie und wird beim nächsten Senden als neue Zeile im eigenen Raum angelegt (mit ihren Kindern).

Kinder zuerst, dann Eltern; im Zweifel bleibt alles.

**Das belegte iPhone:** die 8 leeren Fächer gehören dem Raum des anderen Geräts → sie verschwinden lokal, ohne
Löschmarke. Die 7 eigenen bleiben. Das gemeinsame Mathe-Fach hat hier Kurse und Dateien → bleibt, wird (falls der
Dienst es dem anderen Raum zuschlägt) als eigene Zeile neu angelegt. Auf dem anderen Gerät bleiben seine 8 Fächer; die
7 fremden, dort leeren Fächer verschwinden dort, sobald es die neue App hat.

## Web und Windows

- Windows (`app/sync_client.py`): merkt sich beim Stud.IP-Abgleich denselben Hash und schickt `studip_user` + `uni_key`;
  gleiches Aufräumen. Ohne Stud.IP-Abgleich unverändert (schickt nichts).
- Web: unverändert.
