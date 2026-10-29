# Wie Studora aufgebaut ist und aufgebaut sein wird – Geräte, Dienst, Datenbank, Cloud, Abgleich (29.10.2026)

Für den Inhaber geschrieben. Grundlage: der Code auf `develop`, die Verträge `docs/VERTRAEGE-KONTO-SYNC.md` (G1 Konto,
G2 Abgleich, G4 Community), `docs/release/BETRIEB.md`, die Entscheidungen vom 25.–29.10. und die Prüfpunkte 300–1150
der anderen KI (`docs/uebergabe-mac/`). Was davon heute schon läuft, steht jeweils dabei.

## 1. Das Bild in einem Satz

**Jedes Gerät hat alle seine Daten selbst und arbeitet auch ohne Internet. Der Studora-Dienst (Server) verbindet die
Geräte eines Kontos miteinander und mit anderen Studierenden.** Er ist nicht das Gehirn, ohne das nichts geht.

```
  iPad / Mac (eine App)          Windows-Laptop                 (später: Android, Web)
  ┌───────────────────────┐      ┌───────────────────────┐
  │ Oberfläche (SwiftUI)  │      │ Oberfläche (Web/Tauri)│
  │ lokales Backend       │      │ lokales Backend       │      Beide sprechen dieselbe
  │  (Swift, gleiche /api)│      │  (Python, gleiche /api)│     „Sprache“ (/api …), geprüft
  │ SQLite + Dateien      │      │ SQLite + Dateien      │      mit gemeinsamen Verträgen
  │ Schlüsselbund         │      │ Windows-Tresor        │
  └─────┬───────────┬─────┘      └─────┬───────────┬─────┘
        │           │                  │           │
        │ Stud.IP / Learnweb / LSF / QIS direkt vom Gerät (eigene Anmeldung je Gerät)
        │           │                  │           │
        │           └──── HTTPS ───────┼───────────┘
        │                              │
        ▼                              ▼
  ┌──────────────────────────────────────────────────────────┐
  │ Studora-Dienst (ein Server, später mehrere)               │
  │  Konto (G1) · Abgleich (G2) · Community (G4) · Kaufprüfung│
  │  Datenbanken: accounts.db, community.db, je Konto eine    │
  │  eigene Datenbank (später PostgreSQL), Dateiablage        │
  └──────────────────────────────────────────────────────────┘
        ▲
        │ nur wenn der Nutzer KI benutzt, direkt vom Gerät:
  OpenAI (sein eigenes ChatGPT-Abo)    ── Studora sieht weder Frage noch Antwort
```

## 2. Was wo gespeichert ist

| Daten | Auf dem Gerät | Beim Dienst | Bemerkung |
|---|---|---|---|
| Vorlesungsfolien, Übungsblätter (Hochschul-PDFs) | ja, jedes Gerät lädt selbst von der Hochschule | **nein** (nur Fingerabdruck SHA-256 und Seitentext für Suche/Community) | Entscheidung 28.10.: Streaming bleibt; eine optionale Cloud-Ablage je Konto kommt erst nach Klärung des Urheberrechts mit den Hochschulen (Schalter `LERNAPP_FILES`) |
| Eigene Notizen, Handschrift (Apple Pencil, Windows-Stift) | ja (Journal, übersteht Abstürze) | ja, ab Stufe 2 (Abgleich G2) | ein gemeinsames Notizformat (`annotations` v2) mit festen IDs je Strich; Apple-Daten (PencilKit) bleiben erhalten, auch wenn Windows sie nicht zeichnen kann |
| Stundenplan, Ausnahmen, Lernpakete, Aufgaben, Karteikarten, Module, Ordner, Einstellungen | ja | ja, ab Stufe 2 | Abgleich je Zeile mit Version |
| Noten (QIS, LSF) | ja | nein | bleiben auf dem Gerät |
| Hochschul-Passwörter | **nie in der App**, nur iOS/Windows-Kennwortverwaltung | nein (am PC/Dienst nur im verschlüsselten Tresor für den automatischen Abgleich, `app/vault.py`) | Entscheidung 27.10. |
| Learnweb-Schlüssel, Stud.IP-Sitzung | Schlüsselbund bzw. Windows-Tresor, je Konto und Hochschule | nein (V1) | |
| Studora-Konto (Anmeldung) | Token im Schlüsselbund | Konto, Sitzungen, Geräte | G1 |
| ChatGPT-Verbindung | Token im Schlüsselbund, je Apple-Nutzer | **nie** | Konto löschen entfernt sie |
| Community-Lösungen | Kopie bei Bedarf | ja, verschlüsseltes Paket (nur mit der Original-PDF lesbar) | G4; Likes, Kommentare, Rangliste für den Inhaber |
| KI-Fragen und -Antworten | Antworten im Gerät | nein | |

**Trennung:** Auf dem Gerät hat jede Kombination aus (Konto, Hochschule) einen eigenen Container (Datenbank, Dateien,
Anmeldungen). Beim Dienst hat jedes Konto eine eigene Datenbankdatei; es gibt keine Abfrage, die ein fremdes Konto
treffen könnte (Prüfpunkte 881–886).

## 3. Der Dienst (Server)

**Heute gebaut** (PC-Sitzung, `deploy/`, `docs/release/BETRIEB.md`): ein Linux-Server mit Docker, Python (FastAPI),
HTTPS über Caddy/nginx, `accounts.db` (Konten, Sitzungen, Tresor), `community.db`, je Konto `users/<id>/…` mit eigener
SQLite-Datenbank, Mailversand (Bestätigung, Passwort zurücksetzen), Jobs für den Hochschul-Abgleich im Dienst,
Löschfristen (14/90 Tage), tägliches Backup 03:30, Grenzen je Konto und IP, Datenexport als ZIP, Konto endgültig
löschen nach 30 Tagen.

**Was der Inhaber beschaffen muss:** Server (VPS), Domain, Mail-Anbieter, Backup-Ziel.

**Stufenplan bis 30.000 gleichzeitig** (Entscheidung 28.10., ENTSCHEIDUNGEN §5), jeweils erst nach Messung:
1. Hochschul-Abgleich auf den Geräten statt auf dem Server (iPad und Windows tun das schon) – spart Browser auf dem Server.
2. Mehrere API-Prozesse hinter dem Proxy, Grenzen je Konto.
3. **PostgreSQL** für Konten, Community und Abgleich-Daten (statt vieler SQLite-Dateien).
4. **Objektspeicher** (S3-kompatibel) für eigene Dateien und Community-Pakete.
5. Warteschlange mit Arbeitern für KI (Pro AI) und Hintergrundaufträge.
6. Lasttests 1.000 → 5.000 → 10.000 → 30.000; erst dann Servergröße und Kosten festlegen.

Die Prüfpunkte der anderen KI (Gateway, Sync-Service, Stud.IP-Worker, AI-Service, Redis) beschreiben dasselbe Ziel in
anderen Worten; die Geräte brauchen dafür keine Änderung, weil die Schnittstelle (`/api/...`) gleich bleibt.

## 4. Die Schnittstellen (API)

| Teil | Wofür | Stand |
|---|---|---|
| **G1 Konto** `/api/account/...` | registrieren, E-Mail bestätigen, anmelden (E-Mail, **Mit Apple**, Google), Passwort zurücksetzen, Geräte einzeln abmelden, Hochschule, Datenexport, Konto löschen | Dienst fertig, Windows fertig; **iPad in V1, sobald der Server steht** (Entscheidung 29.10., Plan ENTSCHEIDUNGEN-29.10 §3) |
| **G2 Abgleich** `/api/sync/changes`, `/api/sync/push` | Daten zwischen den Geräten eines Kontos | Dienst fertig, Windows fertig (0.4.8); **iPad in Stufe 2** |
| **G4 Community** `/api/community/...` | Lösungen teilen und projizieren, Likes, Kommentare an der Stelle, Fragen je Kurs, Lesezeichen, Mitteilungen, Melden, Sperren, Moderation, Rangliste (nur Admin) | Dienst fertig, Windows fertig (0.4.7–0.4.9); iPad heute über iCloud (CloudKit), **Umstellung auf den Dienst in Stufe 2** |
| Hochschule am Gerät | Gerät meldet nur Fingerabdruck und Seitentext seiner PDFs (`PUT …/fingerprint`, `…/pagetext`), nie die Datei | Dienst fertig |
| Kaufprüfung | App-Store- bzw. Microsoft-Kauf beim Dienst bestätigen, dann Pro-Tarife | Dienst vorbereitet, braucht Apple-Team |
| **KI** | auf dem iPad: direkt an OpenAI mit dem ChatGPT-Abo des Nutzers (gebaut 29.10.); Pro AI später über den Dienst mit günstigem Modell | ChatGPT gebaut (sichtbar im Debug-Build, für alle nach Freigabe durch OpenAI) |

## 5. Wie der Abgleich (G2) funktioniert

- **Jede Änderung wird zuerst auf dem Gerät gespeichert** (Datenbank bzw. Notiz-Journal), dann im Hintergrund
  gesendet. Ohne Internet läuft alles weiter; die Änderungen warten in der Warteschlange (Prüfpunkte 941–958).
- Ein Lauf ist immer **abrufen → senden → abrufen**. Abgerufen wird ab einem gespeicherten **Cursor** (Zeitstempel),
  seitenweise, bis nichts mehr nachkommt. So verpasst ein Gerät nach Neustart oder langer Pause nichts.
- Jede Änderung hat eine **Operations-ID**. Wird sie doppelt gesendet (Antwort ging verloren), wendet der Dienst sie
  nur einmal an (Prüfpunkte 888, 900, 926).
- **Versionen:** Jede Zeile zählt ihre Version hoch. Hat sich die Zeile inzwischen woanders geändert, entscheidet
  je Feld der spätere Stand; beide Stände werden gemeldet.
- **Löschen** hinterlässt einen Grabstein (Tombstone), damit eine gelöschte Zeile nicht von einem anderen Gerät
  zurückkommt; eine spätere Änderung gewinnt gegen ein älteres Löschen.
- **Notizen:** zusammengeführt **je Objekt** (Strich, Textfeld, Markierung), nicht „letztes Gerät gewinnt“. Neue
  Striche beider Geräte bleiben, gelöschte bleiben gelöscht (Grabstein). Nur wenn beide Geräte **dasselbe** Objekt
  verschieden geändert haben, wird ein Konflikt angezeigt. Unbekannte Apple-Daten werden von Windows nicht zerstört
  (Prüfpunkte 911–940). Heute wird je Datei das ganze Notizdokument mit Version gesendet und zusammengeführt; einzelne
  Strich-Operationen (Punkte 923–929) sind mit dem Journal des iPads vereinbar und werden mit der PC-Sitzung
  festgelegt (Punkt B6).
- **Was nicht abgeglichen wird:** Hochschul-PDFs (jedes Gerät lädt sie selbst), Noten, Zugangsdaten, Hochschul-Sitzungen,
  Geräte-Einstellungen wie die Stifteingabe, Wochentests.
- **Free und Plus:** Notizen gleichen ab Plus ab, alles andere in jedem Tarif (Vertrag G2, `plan_required`).

## 6. Was passiert, wenn … (mit einem Studora-Konto)

### iPad und Windows-Laptop
- **V1 (Start):** Auf beiden Geräten meldest du dich mit **demselben Studora-Konto** an (iPad: mit Apple oder E-Mail,
  sobald der Server steht). Jedes Gerät meldet sich **selbst** bei Stud.IP an und lädt die Folien selbst. Stundenplan,
  Dateien und Noten sind also auf beiden da, weil beide dieselbe Hochschule abgleichen. **Notizen, eigene Lernpakete
  und Einstellungen sind in V1 noch getrennt.** Die Community läuft am iPad noch über iCloud, am Laptop über den Dienst.
- **Stufe 2:** Was du auf dem Laptop markierst, erscheint ein paar Sekunden später auf dem iPad über derselben
  Folie, und umgekehrt. Lernplan, Module, Karteikarten und Ausnahmen im Stundenplan sind auf beiden gleich. Eine Lösung,
  die jemand auf Windows teilt, öffnet ein Studierender derselben Hochschule auf dem iPad und projiziert sie auf seine
  eigene PDF, mit Kommentaren und Likes.

### iPad und Mac
- Der Mac nutzt die **iPad-App** („Designed for iPad“ auf Apple-Silicon-Macs), kein eigenes Programm.
- Jedes Gerät hat seine eigenen Daten (eigener Container). **V1:** Mac und iPad gleichen untereinander noch nichts ab
  (außer Community über iCloud). **Stufe 2:** genau wie iPad + Windows über den Dienst. Mac, iPad und Windows sind dann
  drei Geräte desselben Kontos (Prüfpunkt 903, 938).

### Ein neues Gerät
Anmelden mit dem Konto, Hochschule wählen, bei der Hochschule anmelden → das Gerät lädt Folien und Stundenplan selbst;
ab Stufe 2 kommen Notizen, Lernplan und Einstellungen vom Dienst dazu (Punkt 959).

### Offline (Zug, Flugmodus)
Alles Gespeicherte bleibt nutzbar, Schreiben und Planen gehen weiter. Beim nächsten Netz wird nachgeholt; nichts wird
still überschrieben (Punkte 941–970).

### Zwei Geräte schreiben gleichzeitig auf derselben Seite
Beide Striche bleiben (Zusammenführung je Objekt). Nur dasselbe Objekt verschieden geändert → Hinweis.

### Gerät verloren
Auf einem anderen Gerät „Gerät abmelden“ (G1) → das verlorene Gerät kommt nicht mehr an den Dienst. Seine lokalen
Daten schützt die Gerätesperre (iPad) bzw. die Windows-Anmeldung.

### Konto wechseln oder löschen
Jedes Konto hat eigene Container; nach dem Wechsel sieht man nichts vom anderen. Konto löschen entfernt auf dem Gerät
alle Container, Anmeldungen, Schlüssel und die ChatGPT-Verbindung, beim Dienst das Konto nach 30 Tagen endgültig.

### Hochschulwechsel (LUH ↔ Hildesheim)
Jede Hochschule hat einen eigenen Container; die Daten der anderen bleiben erhalten. Community nur innerhalb derselben
Hochschule (es gibt keine gemeinsamen PDFs).

## 7. Was wann kommt

| | V1 (Start, Stufe 1) | Stufe 2 (mit Server) | später |
|---|---|---|---|
| iPad/Mac | lokal vollständig, Stud.IP/Learnweb/LSF/QIS direkt, Editor, Kalender, Noten, Community über iCloud, KI über ChatGPT (nach Freigabe durch OpenAI), Studora-Konto anmelden | Abgleich G2, Community über den Dienst, Pro-Tarife mit Kaufprüfung | iPhone, eigene Dokumente mit Inhalt im Abgleich |
| Windows | Einzelplatz (0.4.x), Studora-Konto, Community über den Dienst, KI über ChatGPT | Abgleich mit dem iPad | Code-Signierung, Auto-Update, Microsoft Store |
| Dienst | Konto, Community (sobald Server, Domain und Mail stehen) | Abgleich für alle Geräte | PostgreSQL, Objektspeicher, Warteschlange, Lasttests |
| Android | – | – | spätere Version |

## 8. Abgleich mit den Prüfpunkten der anderen KI (300–1150)

| Punkte | Thema | Stand |
|---|---|---|
| 466–505 | Folien lokal speichern, Cloud-Ablage, Duplikate | Streaming + Fingerabdruck gebaut; Cloud-Ablage hinter Schalter (Urheberrecht offen) |
| 506–511 | ein Konto auf allen Geräten, Geräteübersicht, abmelden, neues Gerät, Konto wechseln, Geräteverlust | Dienst fertig; iPad V1 (Konto) bzw. Stufe 2 (Abgleich) |
| 512–535 | Abgleich-Status, Offline-Warteschlange, Konflikte | Windows fertig, iPad-Journal fertig; iPad-Client Stufe 2 |
| 731–760 | Editor auf beiden Plattformen | Format gemeinsam; iPad-Editor Schritte 3–6 offen (Drehen, Speicherlast, Seiten, Objekte, PDF-Text markieren) |
| 761–790 | KI und Lernsystem | ChatGPT gebaut; Wochentests 15 Aufgaben (4/6/5) in Python fertig, iPad in Arbeit |
| 791–820 | Kalender und Hochschulen | Stundenplan wie Stud.IP-Kalender, Ausfälle ausgeblendet, Hildesheim gleichwertig – fertig |
| 821–850 | Community | Dienst + Windows fertig; iPad Stufe 2 |
| 851–880 | Abos und Rechte | vier Tarife, V1 verkauft Free + Plus; Kaufprüfung braucht das Apple-Team |
| 881–910 | Backend, Sicherheit, Wiederherstellung | Trennung je Konto, Operations-ID, Grenzen, Backups gebaut; Lasttests offen (kostenpflichtig) |
| 911–940 | PencilKit, Geometrie, Strich-Abgleich | feste Strich-IDs, Seitenkoordinaten, Journal; Drehen (Schritt 3) und Strich-Operationen (B6) offen |
| 941–970 | Offline-first, Absturz, Wiederherstellung | iPad-Journal mit Absturzsicherheit, Härtungen Schritt 2 fertig; Gerätetest mit dem Inhaber offen |
| 971–1150 | Gesamtaudit, Release | Prüfliste in `docs/UEBERGABE-MAC-NEUE-SITZUNG-2026-10-29.md` §6 |
