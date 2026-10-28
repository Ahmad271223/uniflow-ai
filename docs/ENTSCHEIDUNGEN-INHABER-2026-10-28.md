# Entscheidungen des Inhabers und was daraus folgt (28.10.2026)

Antworten des Inhabers auf die offenen Fragen aus `docs/PRUEFKATALOG-ABGLEICH-2026-10-28.md`, Abschnitt 2. Die
Originaltexte der anderen KI, die er dazu eingefügt hat, stehen wortgetreu in `docs/uebergabe-mac/` (Teil 1: Punkte
1–535, Teil 2: Punkte 536–1150 mit seinen Wünschen zur Community). Plattformen: **Windows, iPad und Mac**. Android
kommt in einer späteren Version, iPhone ebenfalls nicht in V1.

## 1. Entscheidungen

| Frage | Entscheidung | Folge |
|---|---|---|
| Tarife | **bleiben die vier** (Free, Plus 1,99 €, Pro Connect 2,99 €, Pro AI 3,99 €, `app/plans.py`) | Preisangaben der anderen KI („0,99 / 3,99“) gelten nicht |
| Start | **in 5 Tagen** (um den 2.11.2026) | Abschnitt 3: was bis dahin realistisch ist |
| iPhone | **nicht in V1** | iPad bleibt `TARGETED_DEVICE_FAMILY: "2"` |
| Mac | gehört zu Apple (Inhaber: „Windows und Apple, also iPad und Mac“) | Empfehlung an die Mac-Sitzung: die iPad-App auf Apple-Silicon-Macs freigeben („Designed for iPad“), kein eigener Mac-Build in V1 |
| Android | spätere Version | Code bleibt, keine neuen Funktionen, kein Release-Blocker |
| Community | **über den Server, auf Windows und Apple**, mit einem Konto auf beiden | Abschnitt 4; die iPad-Community stellt von CloudKit auf den Dienst (G4) um |
| Lastziel | **30.000 gleichzeitig** zwischen 8 und 18 Uhr | Abschnitt 5: braucht eine andere, kostenpflichtige Architektur und Lasttests |
| Hochschul-PDFs | **Modell „Streaming bleibt, dazu optionale, berechtigungsgeschützte Cloud-Ablage mit lokalem Cache“** | Abschnitt 6; Urheberrecht vor dem Einschalten klären |
| Word | **erst nur anzeigen** | iPad: QuickLook (vorhanden); Windows/Web: Anzeige bauen, kein Bearbeiten |

## 2. Notenspiegel (Befund vom 28.10. mit echten LUH-Daten, gebaut)

Frage des Inhabers: „Ist das so richtig oder doppelt, und kann man den aktuellen Schnitt anzeigen?“

- **Es war beides:** 10 echte Doppelte (zweite QIS-Ansicht mit „Wintersemester 25/26“ statt „WiSe 25/26“) und
  scheinbare Doppelte (QIS zeigt Modul und darunter seine Prüfung). Der angezeigte Schnitt 4,06 war falsch: er
  zählte Module, Prüfungen, Doppelte und nicht bestandene Versuche (5,0).
- **Jetzt** (`app/grades_model.py`, `qis.summary`): Ebenen Bereich/Modul/Prüfung, Doppelte entfernt, aktueller
  Schnitt aus bestandenen benoteten Modulen, nach LP gewichtet, nach der ersten Nachkommastelle abgeschnitten, dazu
  der genaue Wert. Echte Daten: **3,4 (genau 3,47) aus 17 Modulen mit 99 LP, 105 LP aus 18 bestandenen Modulen**.
  Gegenprobe: für den Kompetenzbereich Mathematik/Naturwissenschaften ergibt dieselbe Regel 3,3, genau wie QIS.
- Oberfläche: Bereiche als Chips, Schalter „Module“ / „Alle Prüfungen und Versuche“. Gilt für gespeicherte Zeilen,
  ein neuer Abruf ist nicht nötig. Tests: `tests/test_grades_model.py`.
- **iPad (Mac-Sitzung):** `UniStore` braucht dieselben Regeln (Felder aus der Zeile, Ebenen, Doppelte, Schnitt).

## 3. Was in 5 Tagen realistisch ist – ehrlich

| Bereich | Bis zum Start möglich | Nicht bis zum Start |
|---|---|---|
| Windows-App | Einzelplatz wie heute (0.4.6+), Stud.IP, Kalender, Editor, KI am eigenen PC | Code-Signing (Zertifikat oder Microsoft Store), Auto-Update |
| iPad-App | V1 wie gebaut (Free/Plus, Stud.IP, Editor, Kalender), wenn das Apple-Team bis dahin da ist und die Prüfung durchgeht | Apple-Prüfung lässt sich nicht beschleunigen |
| Konto auf beiden Geräten | Dienst (Konten, Bestätigung, Export, Löschen) läuft, **wenn Server, Domain und Mail-Anbieter beschafft sind** | Notizen geräteübergreifend (G2-Client in Swift und im Web fehlen noch) |
| Community Windows ↔ iPad | Server fertig (Abschnitt 4); Windows-Client in 1–2 Tagen machbar; iPad-Umstellung ist Aufgabe der Mac-Sitzung | gleichzeitig fertig und auf echten Geräten geprüft ist eng |
| 30.000 gleichzeitig | nein | Abschnitt 5 |

Empfehlung: Start in zwei Stufen. Zuerst Windows-Einzelplatz und iPad V1 mit begrenzter Nutzerzahl, danach Konto,
Community und Geräteabgleich, sobald Dienst und Clients nachweislich zusammen funktionieren.

## 4. Community für Windows und Apple (gebaut: Dienst; offen: Clients)

Wunsch des Inhabers: Wer auf Windows eine Lösung teilt, dessen Lösung öffnet ein LUH-Student auf dem iPad, und
umgekehrt. Das Projizieren auf die eigene PDF muss immer klappen, dazu Kommentare in schöner Ansicht, Likes und für
den Inhaber eine Übersicht, wer die meisten Likes bekommen hat.

**Gebaut (Dienst, Vertrag G4 erweitert, `fixtures/community/contract.json`, `tests/test_community_social.py`):**
- **Geräte melden ihre PDFs:** `POST /api/community/claims {fingerprints, replace?}`. Windows-App und iPad gleichen
  auf dem Gerät ab; der Dienst kennt ihre PDFs sonst nicht. Danach finden, laden, liken und kommentieren sie
  Lösungen zu diesen PDFs. Die Meldung gilt je Hochschule. Sicherheit: das Paket ist mit der Original-PDF
  verschlüsselt, wer die PDF nicht hat, kann es nicht öffnen; er sieht nur Titel, Pseudonyme und Kommentare.
- **Likes:** `POST/DELETE /solutions/{id}/like`, nicht für die eigene Lösung, nur mit bestätigter E-Mail, 120 je
  Stunde. Suche liefert `likes`, `liked_by_me`, `comments` und sortiert die meistgelikten zuerst.
- **Kommentare wie in Word:** `GET/POST /solutions/{id}/comments {text, parent_id?, page_key?, anchor?: {x, y}}`
  (Stelle auf der Seite, 0..1 von links oben), Antworten eine Ebene, `PATCH/DELETE /comments/{id}`, melden
  (`POST /comments/{id}/report`, ab 3 Meldungen verborgen). Ab Studora Plus (`can_write_community_comments` jetzt
  `available`), bestätigte E-Mail, 30 je Stunde. Der Autor der Lösung darf Kommentare darunter entfernen. Gesperrte
  Autoren sieht man auch in Kommentaren nicht mehr.
- **Rangliste für den Inhaber:** `GET /api/community/admin/leaderboard` (nur Rolle `admin`): Autoren nach erhaltenen
  Likes mit E-Mail, Hochschule, Zahl der Lösungen, Downloads und erhaltenen Kommentaren. Öffentlich sieht niemand,
  wer hinter einem Pseudonym steht.
- Konto löschen nimmt Likes, Kommentare und Meldungen mit.

**Hochschulen:** LUH ↔ LUH und Hildesheim ↔ Hildesheim, jeweils plattformübergreifend. Zwischen LUH und Hildesheim
gibt es keine gemeinsamen PDFs, also auch keine gemeinsamen Lösungen; die Regel „gleiche Hochschule“ bleibt.

**Offen (nächste Schritte):**
1. **Windows-App mit dem Studora-Konto verbinden** (PC-Sitzung): Anmelden am Dienst aus der Windows-App, Token nur
   auf dem PC, Community-Aufrufe über den Dienst, Fingerabdrücke der eigenen PDFs melden.
2. **Community im Editor (Web/Windows, PC-Sitzung):** Leiste „Lösungen anderer“ zur offenen PDF (meistgelikte zuerst),
   Projizieren als eigene, schreibgeschützte Ebene über der eigenen PDF, Kommentar-Marker an der Stelle,
   Seitenleiste mit Antworten, Like-Knopf, „Lösung teilen“ mit Vorschau. Das Paket entsteht und öffnet sich mit
   WebCrypto (HKDF-SHA256 über die ganzen PDF-Bytes, Info `uniflow-solution/v1|<Lösungs-ID>`, AES-256-GCM, Kopf als
   AAD), genau wie `SolutionCrypto.swift`; gemeinsame Testvektoren nötig.
3. **iPad (Mac-Sitzung):** Community von CloudKit auf den Dienst umstellen (Anmeldung am Konto, Pakete hoch- und
   herunterladen, Fingerabdrücke melden, Likes, Kommentare mit Stelle, dieselbe Ansicht). Lerngruppen und
   Modul-Sichtbarkeit aus CloudKit später im Dienst nachbauen.

## 5. 30.000 gleichzeitig: was es braucht

Heute: ein Prozess, SQLite je Konto, ein VPS, Chromium je Hochschul-Abgleich auf dem Server, gemessen 20–30
Anfragen/s. Für das Ziel, in dieser Reihenfolge, jeweils mit Messung in einer Testumgebung:
1. Hochschul-Abgleich auf die Geräte verlagern (spart Chromium auf dem Server; Windows und iPad tun es schon).
2. Mehrere API-Prozesse hinter dem Proxy, Rate-Limits je Konto (vorhanden für Konto-Pfade), Schema-Arbeit nicht
   mehr je Anfrage.
3. PostgreSQL für Konten, Community und Abgleich-Metadaten; Daten je Konto bleiben getrennt.
4. Objektspeicher (S3-kompatibel) für eigene Dateien und Community-Pakete.
5. Warteschlange mit Workern für KI und Hintergrundaufträge.
6. Lasttests 1.000 → 5.000 → 10.000 → 30.000 Sitzungen; erst dann Server-Größe und Kosten festlegen.
Das kostet Geld (Server, Datenbank, Speicher) und braucht Wochen, nicht Tage.

## 6. Hochschul-PDFs: Streaming plus optionale Cloud-Ablage

Gewähltes Modell (wie von der anderen KI vorgeschlagen): Der Dienst streamt Hochschul-PDFs weiter (speichert nur
Fingerabdruck und Seitentext). Dazu kommt eine **optionale**, berechtigungsgeschützte Ablage: eine Datei, die ein
Konto aus seinem Abgleich hat, darf für genau dieses Konto in der Cloud zwischengespeichert werden, damit sie auf
einem neuen Gerät sofort da ist; jedes Gerät hält einen lokalen Cache. Gleiche Dateien nur innerhalb derselben
Berechtigung zusammenlegen. **Vor dem Einschalten:** Nutzungsrechte mit den Hochschulen klären (Urheberrecht),
Objektspeicher beschaffen. Bis dahin hinter einem Schalter (`LERNAPP_FILES=stream` bleibt Standard).
