# Dienst-Update 21.11.2026 – ausgerollt 13:41 (Wissensbank)

Stand: `55ac3f3f` (Zweig `release/1.0.7`, Merge von `server/wissensbank`). Auf dem Server lief vorher `2a238f0f`.
Ausgerollt auf Freigabe des Inhabers vom 21.11.2026 im Chat („Ja, Server-Update“ auf die Frage, ob der Server auf den
neuen Stand gebracht und die Wissensbank dort eingeschaltet werden darf). Anlass: Der Inhaber will die Wissensbank
selbst am iPad testen (Testfassung per Kabel, Build 46 noch nicht hochgeladen).

## Was sich im Dienst-Code ändert (`2a238f0f` → `55ac3f3f`)

| Datei | Was |
|---|---|
| `app/wissensbank.py`, `app/wissensbank_pruefen.py` | neu: StudiNow-Wissensbank (nur LUH, Pro AI), Prüf-Werkzeug |
| `app/ai_relay.py` | KI-Hilfe fragt zuerst die Wissensbank (nur wenn die App Angaben zur Stelle schickt) |
| `app/billing_api.py`, `app/credits.py` | Feld `wissensbank` in den Berechtigungen, Zweck `tutor:wissensbank` (1 Credit) |
| `app/account_export.py`, `app/accounts.py` | Export und Löschen umfassen die neuen Tabellen |
| `app/server.py` | Router eingebunden |
| `deploy/.env.example`, `tools/wissensbank-hochladen.sh` | Schalter, Upload-Skript |

- Datenbank: neue Tabellen `wissensbank_*` in `accounts.db` (werden beim ersten Zugriff angelegt).
- `deploy/.env` auf dem Server: `LERNAPP_WISSENSBANK=1` ergänzt (Kopie des Stands davor:
  `.env.vor-wissensbank-2026-11-21`). Aktiv ist die Wissensbank erst, wenn `katalog.json` in `/data/wissensbank` liegt
  (Upload durch den Inhaber mit `tools/wissensbank-hochladen.sh`).
- Wirkung für die App im Store (1.0.6, Build 45): keine. Sie schickt keine Angaben zur Stelle (`wissensbank` in der
  Anfrage); Antworten aus der Wissensbank bekommt nur eine App mit dem Stand von 1.0.7.

## Tests (auf `55ac3f3f`)

- Python voll: **4007 bestanden**, 4 übersprungen, 2 erwartet rot, 0 Fehler (7:12 min).
- App im Simulator (Auswahl): `WissensbankAppTests`, `CreditsDisplayAppTests`, `PageExplainAppTests`,
  `UndoStrokesAppTests`, `EditorDeviceFixesTests`: 38 Tests, 0 Fehler. Auf dem Zweig `server/wissensbank` davor: 25
  Klassen der KI-Hilfe, 180 Tests, 0 Fehler; Swift-Kern 1770 Tests, 0 Fehler (Stand `a4640600`).
- Der volle App-Lauf für Build 46 steht noch aus.

## Ablauf

1. Backup: `uniflow-2026-11-21_1334.tar.gz` (190 MB, 25 Datenbanken).
2. Code übertragen und neu gebaut (`git archive 55ac3f3f | ssh … 'tar -x -C /srv/uniflow/app && cd … && docker compose up -d --build'`).
3. Geprüft: `uniflow-app` und `uniflow-jobs` healthy, `dienst-check.sh --no-mail --verbose`: alle Prüfungen bestanden.
4. Schalter gesetzt, Dienst neu gestartet: „Schalter True, aktiv False“ (Bibliothek noch nicht hochgeladen).
5. **Zurück, falls etwas nicht geht:** Schalter in `deploy/.env` auf 0 und `docker compose up -d`; ganz zurück:
   Schritt 2 mit `2a238f0f`.
6. Bibliothek hochgeladen (14:00, `tools/wissensbank-hochladen.sh`, auf Wunsch des Inhabers „Mach du das“ von der
   Hauptsitzung ausgeführt): 2 266 Dateien im Volume; Prüfung im Container: „Stand 2026-11-20: 29 Fächer, 1065
   Einheiten, 26571 Abschnitte, davon 12788 mit Folien-/Aufgabentext. Schalter an.“ Danach „Schalter True, aktiv True“.
7. Erster Test des Inhabers am iPad (14:08): normale KI-Antwort statt Wissensbank. Zwei Gründe: (a) Das Konto, mit dem
   das iPad angemeldet ist (Apple-Anmeldung), stand im Dienst auf Hochschule „hildesheim“, die App selbst auf „luh“
   (auf dem Gerät geprüft: die Konto-Kennung der App ist die des Kontos); die Wissensbank gilt nur für LUH-Konten.
   Mit Okay des Inhabers („Ja, auf LUH“) per `accounts.set_university` auf „luh“ gestellt; danach meldet der Dienst
   die Wissensbank für das Konto. Wann und wodurch das Konto auf Hildesheim kam, ist nicht protokolliert (nur über
   „Hochschule wechseln“ möglich). (b) Die Anfrage trug ein Bild („Bereich an KI“ bzw. „Ganze Seite an KI“); mit Bild
   wird die Wissensbank bisher bewusst nicht gefragt (App und Dienst). Ob das geändert wird, entscheidet der Inhaber.
8. Zweites Update 14:38 auf `bffe510f` (Freigabe des Inhabers „Ja, ausrollen“): einzige Dienst-Änderung gegenüber
   `55ac3f3f` ist `app/wissensbank.py` – ein Bild („Bereich an KI“) schließt die Wissensbank nicht mehr aus; die App
   schickt dann nur den im Ausschnitt erkannten Text. Vorher: Python voll 4008 bestanden, 0 Fehler; Backup
   `uniflow-2026-11-21_1430.tar.gz`. Danach: Container healthy, `dienst-check.sh`: alle Prüfungen bestanden,
   Wissensbank aktiv. Zurück: Schritt 2 mit `55ac3f3f`.
9. Drittes Update 20:50 auf `89cf11db` (Freigabe des Inhabers „Ja, ausrollen“): einzige Dienst-Änderung gegenüber
   `bffe510f` ist `app/wissensbank.py` – Abgleich mit Text aus echten PDFs (getrennte Umlaute, eigener Weg für
   eingekreiste Ausschnitte, Sperren gegen gleiche Aufgaben anderer Jahre); Messung in `docs/WISSENSBANK-STAND.md`.
   Anlass: Am iPad kam auch mit Angaben der App („Anhang area, 299 Zeichen“) nie ein Treffer. Vorher: Python voll 4025
   bestanden, 0 Fehler; Backup `uniflow-2026-11-21_2049.tar.gz`. Danach: Container healthy, `dienst-check.sh`: alle
   Prüfungen bestanden, Wissensbank aktiv mit dem neuen Abgleich. Zurück: Schritt 2 mit `bffe510f`.
10. Viertes Update 22.11.2026 10:55 auf `cdda3e89` (Freigabe des Inhabers „Ja, ausrollen“): einzige Dienst-Änderung
    gegenüber `89cf11db` ist `app/ai_relay.py` – Vorab-Frage `POST /api/ai/wissensbank` (Treffer wie eine
    Wissensbank-Lieferung, 1 Credit; ohne Treffer keine Kosten). Anlass: „Seite erklären“ kam am iPad immer aus dem
    Erklärungsspeicher der App und erreichte die Wissensbank nie; die App (ab `203cd8fc`) fragt jetzt zuerst nach.
    Vorher: Python voll 4032 bestanden, 0 Fehler; Backup `uniflow-2026-11-22_1054.tar.gz`. Danach: Container healthy,
    `dienst-check.sh`: alle Prüfungen bestanden, Wissensbank aktiv; die Route steht im Router von `ai_relay` neben
    `/api/ai/relay` (im Container nachgesehen; ein Aufruf mit Anmeldung wurde nicht gemacht – Bestätigung durch den Test
    des Inhabers am iPad). Zurück: Schritt 2 mit `89cf11db`.
11. Fünftes Update 22.11.2026 12:14 auf `07e26fea` (Freigabe des Inhabers „Ja, beides an“ auf die Frage, ob das Update
    ausgerollt und beide neuen Teile eingeschaltet werden dürfen): `app/wissensbank_ki.py` neu (KI mit Auszügen aus der
    Wissensbank; gemerkte KI-Antworten), dazu Haken in `app/ai_relay.py`, `app/wissensbank.py`,
    `app/wissensbank_pruefen.py`. In `deploy/.env` ergänzt: `LERNAPP_WISSENSBANK_KONTEXT=1`,
    `LERNAPP_WISSENSBANK_MERKEN=sofort` (Kopie davor: `.env.vor-wissensbank-ki-2026-11-22`). Entscheidungen des Inhabers
    zum Merken: nur dieselbe Stelle (gleiches Fach, Übungsblatt, Aufgabe), dann direkt, 1 Credit für den Nächsten.
    Vorher: Python voll 4046 bestanden, 0 Fehler; Backup `uniflow-2026-11-22_1213.tar.gz`. Danach: Container healthy,
    `dienst-check.sh`: alle Prüfungen bestanden, beide Schalter im Container gesetzt.
    Nicht geprüft: ob die KI unpassende Auszüge ignoriert (nur mit echten Anfragen möglich – Test des Inhabers).
    Vor der Veröffentlichung von 1.0.7: Datenschutz/AGB um die gemerkten Antworten ergänzen (Textvorschlag im Bericht
    des Helfers, `docs/WISSENSBANK-STAND.md`). Zurück: beide Zeilen aus `.env` nehmen und `docker compose up -d`;
    ganz zurück: Schritt 2 mit `cdda3e89`.
12. Sechstes Update 22.11.2026 13:57 auf `12aa93b0` (Freigabe des Inhabers „Ja, ausrollen“): einzige Dienst-Änderung
    gegenüber `07e26fea` sind `app/wissensbank.py` und `app/wissensbank_ki.py` (Formel-Aufgaben als Auszug an die KI,
    Verweise auf Aufgaben-Abschnitte, bei gleichem Inhalt die neueste Einheit; `52258f1b`, eingemischt mit `f8292e11`).
    Keine neuen Schalter, App unverändert. Davor: schneller Python-Lauf auf `12aa93b0` 4046 bestanden, 0 rot (node 472);
    Backup `uniflow-2026-11-22_1356.tar.gz` (232 MB, 27 Datenbanken). Danach: `uniflow-app` und `uniflow-jobs` healthy,
    `dienst-check.sh`: alle Prüfungen bestanden. Im Container nachgestellt (ohne KI-Aufruf): der Fall des Inhabers
    (Aufgabe 4.1.5, Seite 25) gibt jetzt einen Auszug an die KI, mit anderer Seite keinen. Die KI-Antwort selbst ist
    nicht geprüft. Beim Backup gesehen: Platte 301 GB, 15 GB belegt (6 %). Zurück: `git archive 07e26fea` wie oben.

13. Siebtes Update 22.11.2026 14:46 auf `32356351` (Zweig `fix/probeklausur-abholen` = `release/1.0.7` @ `1f968244` +
    ein Commit; Freigabe des Inhabers „Ja, ausrollen“ auf die Frage, ob die Behebung auf den Dienst und per Kabel auf
    sein iPad darf). Anlass: Seine Probeklausur (Klausur-Generator) war beim Dienst fertig und bezahlt, kam aber nie
    aufs iPad, weil nur das offene Kauf-Blatt abholte. Einzige Dienst-Änderung gegenüber `12aa93b0`: `app/exam_shop.py`
    und `app/exam_shop_api.py` – neue Route `GET /api/exam-shop/mine` (nur lesen: Probeklausuren des Kontos mit
    Fingerabdrücken der Unterlagen, keine Namen). Keine Schalter, `.env` unverändert. Davor: Python voll 4051
    bestanden, 0 rot; Stand auf dem Server per Prüfsumme gleich `12aa93b0`; Hauptsitzung informiert (deployte nicht).
    Backup `uniflow-2026-11-22_1445.tar.gz` (235 MB, 27 Datenbanken). Danach: `uniflow-app` und `uniflow-jobs` healthy,
    `dienst-check.sh`: alle Prüfungen bestanden; Route im Router `exam_shop_api` vorhanden, `exam_shop.mine` liefert
    für das Konto des Inhabers seine eine Probeklausur (fertig, bezahlt). **Vor dem nächsten Deploy aus
    `release/1.0.7` den Zweig `fix/probeklausur-abholen` einmischen**, sonst fällt die Route weg (die App bliebe dann
    still beim alten Weg). Zurück: `git archive 12aa93b0` wie oben.
    iPad des Inhabers (Kabel, Release, Build 46, nicht bei Apple): zuerst `32356351`; dort fiel das erste Abholen aus,
    weil die App beim Start den Tarif noch nicht kannte. Nachgebessert in `264f0c79` (fragt auch, sobald der Tarif
    geladen ist; Zeile „Probeklausuren abholen: …“ im Protokoll `StiftSpur`), App-Tests 12 bestanden, neu installiert.
    Danach am Gerät (14:57): „neu 2 Dateien, beim Dienst in Arbeit 0“; im Modul „Grundlagen digitaler Systeme“, Ordner
    „Probeklausuren“, liegen „Probeklausur 1 – Aufgaben“ (1 Seite) und „– Lösungen“ (3 Seiten).

14. Achtes Update 22.11.2026 16:14 auf `648489bb` (Zweig `app/erklaerung-shop` = `release/1.0.7` @ `16ef0214` + ein
    Commit; Freigabe des Inhabers „Ja, ausrollen“ auf die Frage, ob der Server aktualisiert, die 59 PDFs hochgeladen und
    das Angebot eingeschaltet werden darf). Neu: StudiNow-Erklärungen zum Kaufen – `app/erklaerung_shop.py`,
    `app/erklaerung_shop_api.py` (`POST /api/erklaerungen/offer`, `/buy`, `GET /mine`, `GET /{sha256}/pdf`; nur Pro AI,
    15 Credits je PDF), Tabelle `erklaerung_kaeufe` in `accounts.db` (beim Löschen des Kontos mit gelöscht, im Export),
    Router in `app/server.py`. Stand auf dem Server vorher per Prüfsumme aller `app/*.py` gleich `32356351` und gleich
    `16ef0214`. Davor: Python voll 4055 bestanden, 0 rot. Backup `uniflow-2026-11-22_1614.tar.gz` (245 MB, 27 Datenbanken).
    Danach: `uniflow-app` und `uniflow-jobs` healthy, `dienst-check.sh`: alle Prüfungen bestanden.
    PDFs: `tools/erklaerungen-pdf-hochladen.sh` → `/data/erklaerungen-pdf` (59 PDFs, 210 Seiten, Mathe I WiSe 2026/27,
    erzeugt aus der Wissensbibliothek ohne wörtliche Folientexte). `deploy/.env`: `LERNAPP_ERKLAERUNGEN=1` ergänzt (Kopie
    davor: `.env.vor-erklaerungen-2026-11-22`), Preis Standard 15. Im Container geprüft: Schalter an, 59 PDFs im Angebot,
    PDF lesbar, die vier Routen im Router, 0 Käufe; von außen ohne Anmeldung 401. Ein Kauf mit Anmeldung ist nicht
    gemacht (geht nur mit einer App ab diesem Stand, Test des Inhabers per Kabel). Wirkung für die App im Store (1.0.6): keine.
    **Vor dem nächsten Deploy aus `release/1.0.7` den Zweig `app/erklaerung-shop` einmischen**, sonst fallen die Routen
    weg. Zurück: Zeile aus `.env` nehmen und `docker compose up -d`; ganz zurück: Schritt 2 mit `32356351`.

15. Neuntes Update 22.11.2026 23:23 auf `a555406a` (Zweig `app/formelblatt` = `release/1.0.7` @ `16ef0214` +
    `app/probeklausuren-auf-karte` + Formelblätter `75d51549` + Merge von `app/erklaerung-shop` @ `3aed9c57`; Freigabe des
    Inhabers „Ja, ausrollen“ auf die Frage, ob Dienst-Update, Formelblatt-Upload und iPad-Installation gemacht werden
    dürfen). Neu: Formelblätter – `app/formelblatt.py`, `app/formelblatt_api.py` (`POST /api/formelblatt/offer`,
    `/{id}/buy`, `GET /{id}/pdf`; nur Pro AI, Festpreis aus dem Katalog), Tabelle `formelblatt_purchases` in `accounts.db`
    (Export, Löschen). Vorher auf dem Server das achte Update (`648489bb`, Erklärungen) einer anderen Sitzung; per
    Prüfsumme alle `app/*.py` gleich `648489bb`/`3aed9c57`, deshalb eingemischt (die Erklärungen bleiben). Davor auf dem
    gemischten Stand: Python voll 4059 bestanden, Swift-Kern 1785 bestanden. Backup `uniflow-2026-11-22_2323.tar.gz`
    (260 MB). Danach: `uniflow-app` und `uniflow-jobs` healthy, `dienst-check.sh`: alle Prüfungen bestanden; Routen der
    Formelblätter und der Erklärungen im Router; von außen ohne Anmeldung 401.
    Formelblatt: `tools/formelblatt-hochladen.sh` → `/data/formelblatt` (`katalog.json` + `luh-gds-kurzklausur.pdf`, ein
    Eintrag: LUH „Grundlagen digitaler Systeme“, 3 Credits, 2 Seiten, Fassung 2026-11-22; Quelle auf dem Mac
    `~/Studora-Builds/formelblaetter/`, nicht im Repo). Im Container: Angebot für das Konto des Inhabers vorhanden, noch
    nicht gekauft, PDF lesbar. Ein Kauf mit Anmeldung ist nicht gemacht (Test des Inhabers per Kabel). Wirkung für die App
    im Store (1.0.6): keine. **Vor dem nächsten Deploy aus `release/1.0.7` den Zweig `app/formelblatt` einmischen.**
    Zurück: Schritt 2 mit `648489bb`; nur das Angebot weg: `/data/formelblatt/katalog.json` entfernen.
