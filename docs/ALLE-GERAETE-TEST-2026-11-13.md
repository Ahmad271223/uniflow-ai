# Testbericht: Ein Konto, alle Geräte (13.11.2026)

**Ziel des Inhabers:** Wer Pro AI hat und iPad, iPhone und einen Windows-Laptop nutzt, meldet sich einmal an, und
alles, was er auf einem Gerät bearbeitet, sehen alle anderen Geräte.

**Ergebnis in einem Satz:** Für Notizen auf Hochschul-PDFs, Lernkalender, Karteikarten und Module klappt das zwischen
Windows, iPad, iPhone und Web – geprüft mit echten Abgleichen über einen Testdienst. Es fehlen eigene Dokumente
(importierte PDFs, Notizbücher), die Grenze von 3 Geräten, eine gemeinsame Community, und iPad/iPhone gleichen nur beim
Öffnen der App ab, nicht direkt nach einer Änderung.

## Aufbau

Erstmals laufen alle Geräte-Arten gleichzeitig gegen denselben Dienst (vorher nur Windows-gegen-Windows bzw.
iPad-Code-gegen-iPad-Code, `tests/test_sync_client.py`, `DeviceSyncLiveTests`):

| Gerät | Was läuft | Anmeldung |
|---|---|---|
| Windows-Laptop | die echte Windows-App im Einzelplatzmodus (`LERNAPP_DESKTOP=1`), eigener Datenordner, Abgleich `app/sync_client.py` | E-Mail + Passwort über die Anmeldemaske der App (`account_mode.login_password`), danach Abo-Stand vom Dienst |
| iPad | Abgleich-Code der App (`DeviceSync`, `StudoraAccount` aus UniFlowCore), eigene Datenbank-Datei | eigene Sitzung, Gerät `ipad-…` |
| iPhone | derselbe Code (die iPhone-Fassung auf `iphone/universal` nutzt dieselbe Stelle `StudoraAccountLink.syncNow`) | eigene Sitzung, Gerät `iphone-…` |
| Web | die Web-Oberfläche des Dienstes über ihre Schnittstellen (`/api/files/…/annotations`, `/api/packages`, `/api/flashcards`) | eigene Sitzung |
| Dienst | `tools/g2-testdienst.py` (gehosteter Modus, Wegwerf-Daten im Temp-Ordner), Konto mit Tarif **Pro AI** nach der Probe | – |

Wiederholen (Dauer ca. 2 Minuten, nichts geht ins Netz):

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd apps/apple/Packages/UniFlowCore && swift build --build-tests)
.venv/bin/python tools/g2-geraete-rundgang.py --bericht /tmp/rundgang.json
```

Neu dafür: `tools/g2-geraete-rundgang.py` (Ablauf und Prüfungen), `tools/g2-windows-schritt.py` (ein Schritt der
Windows-App), `apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/GeraeteRundgangTests.swift` (ein Schritt eines
Apple-Geräts, ohne `G2_SCHRITT` übersprungen). `tools/g2-testdienst.py` liefert zusätzlich E-Mail und Passwort des
Testkontos, damit sich die Windows-App wie im Alltag selbst anmeldet.

Nicht gemacht: Bedienen der echten Oberfläche im Simulator. „Mit Apple anmelden“ lässt sich gegen einen lokalen
Testdienst nicht durchspielen, und das iPad des Inhabers bleibt unberührt. Geprüft ist deshalb der Abgleich-Code der
Apps, nicht das Antippen. Ein Gerätetest am echten iPad + Windows-Laptop bleibt vor der Freigabe nötig (siehe Plan,
Schritt 0).

## Ergebnis: 43 von 49 Prüfungen erfüllt

Die 6 nicht erfüllten sind genau die bekannten Lücken (Abschnitte 4–6). Alles, was heute abgleichen soll, kam auf
jedem Gerät an.

### 0. Erste Anmeldung (3/3)
Windows, iPad und iPhone haben vorher je dasselbe Modul „Mathe I“ aus Stud.IP angelegt. Nach dem ersten Abgleich gibt
es es auf jedem Gerät genau einmal (keine Doppelten).

### 1. Notizen auf einer Hochschul-PDF (14/14)
- iPad schreibt → Windows, iPhone und Web sehen den Strich.
- Windows schreibt → iPad und iPhone sehen ihn.
- iPad und iPhone schreiben **gleichzeitig** ohne Abgleich dazwischen → nach dem Abgleich haben alle drei Geräte beide
  Striche (das iPhone hat zusammengeführt, nichts ging verloren).
- Web speichert einen Strich → Windows, iPad und iPhone sehen ihn.

### 2. Lernkalender (13/13)
- Windows plant ein Lernpaket → iPad und iPhone sehen es am richtigen Tag beim richtigen Modul.
- iPad verschiebt es → Windows und iPhone sehen den neuen Tag.
- iPhone hakt es ab → Windows und iPad sehen „erledigt“.
- Web legt ein Lernpaket mit Aufgabe an → alle drei Geräte sehen es samt Aufgabe.
- Windows löscht es → auf iPad und iPhone verschwunden.

### 3. Karteikarten (13/13)
- iPhone legt Stapel und Karte an → Windows, iPad und Web sehen sie im richtigen Stapel.
- Windows lernt die Karte (Fach 3, neues Fälligkeitsdatum) → iPad und iPhone haben denselben Lernstand.
- Web legt eine zweite Karte in denselben Stapel → alle Geräte haben 2 Karten.
- iPad löscht eine Karte → auf Windows, iPhone und im Web verschwunden.

### 4. Eigene Dokumente (0/3) – fehlt
Auf dem iPad importierte PDF „Mitschrift.pdf“ und ein Notizbuch, beide mit Notizen: **kommen weder auf Windows noch
auf dem iPhone noch im Web an.** Grund: Der Abgleich überspringt alles in „Eigene Dokumente“ ausdrücklich
(`DeviceSync.fileInfo` liefert für `course_id='__user__'` nichts, „eigene Dokumente gleichen später ab“; ebenso
`app/sync_client.py` und `app/sync.py::_register_device_file`). Es werden weder die Datei noch die Notizen darauf
übertragen.

### 5. Mehr als drei Geräte (2/4) – Grenze fehlt
Ein 4. Gerät (zweites iPad) und ein 5. Gerät (zweiter Windows-PC) melden sich an und gleichen ohne Einschränkung ab
(beide bekommen alle Notizen). Das Konto hatte am Ende 7 Anmeldungen. Eine Grenze gibt es weder im Dienst noch in den
Apps.

Nebenbefund: In der Geräteliste heißen beide Windows-PCs gleich („StudiNow für Windows“); für eine Grenze mit
„Gerät abmelden“ braucht es unterscheidbare Namen.

### 6. Anmeldewege (2/3)
- Apple oder Google mit **derselben, bestätigten E-Mail** wie ein E-Mail-Konto → landet im selben Konto (der Dienst
  verknüpft automatisch, `accounts.login_with_provider`). Gut.
- Apple mit **„E-Mail verbergen“** (Adresse `…@privaterelay.appleid.com`) → **neues, getrenntes Konto.** Das ist der
  häufige Fall auf dem iPad: Wer dort beim ersten Start „E-Mail verbergen“ wählt und am Windows-Laptop mit seiner
  echten Adresse ein Konto anlegt, hat zwei Konten mit getrennten Daten (und Pro AI nur auf einem).

## Weitere Befunde aus dem Code (nicht im Rundgang, aber wichtig für das Ziel)

1. **iPad und iPhone gleichen nur beim Öffnen der App ab.** Einziger Auslöser ist der Wechsel in den Vordergrund
   (`UniFlowApp.swift`, `scenePhase == .active`, höchstens alle 3 Minuten) und der Knopf „Jetzt abgleichen“. Eine
   Notiz auf dem iPad geht also erst beim nächsten Öffnen der App los – wer danach direkt zum Laptop wechselt, sieht
   sie dort noch nicht. Ebenso holt ein iPad, das offen bleibt, neue Änderungen anderer Geräte nicht ab.
   Windows dagegen gleicht 4 Sekunden nach jeder Änderung und sonst alle 3 Minuten ab (`sync_client.start_background`).
   Das Web liest direkt im Dienst und ist immer aktuell. (Gleicher Stand auf `iphone/universal`.)
2. **Zwei getrennte Communitys.** Das iPad nutzt für die Community iCloud (CloudKit, `communityViaService = false`
   seit 07.11.2026), Windows und Web den Dienst. Was am iPad geteilt wird, sieht man am Laptop nicht und umgekehrt.
   Der Dienst kann inzwischen Lösungen, Fragen und Antworten je Modul, Korrekturen und geteilte Kartenstapel
   (`app/community_api.py`, `app/community_cards_api.py`); die iPad-Anbindung an den Dienst
   (`ServiceCommunity.swift`) kann bisher nur Lösungen.
3. **Tarif Plus:** Lernkalender, Karteikarten und Module gleichen ab, Notizen bleiben auf dem Gerät (gewollt, Pro AI;
   bestehende Tests `testFreePlanKeepsNotesLocalButSyncsPlans`).
4. **Windows 0.6.0** ist weiterhin unsigniert und nicht im Store (`docs/WINDOWS-LUECKEN-2026-11-05.md`); für Nutzer
   heißt das eine Warnung von Windows beim Installieren.
5. Ein Fehler im Testaufbau, kein Fehler der App: Meldet sich die Windows-App über den alten Weg
   `service_link.login` an (ohne Abo-Abruf), verweigert sie jeden Abgleich („Ohne aktives Abo …“). Die echte
   Anmeldemaske holt den Abo-Stand und gleicht dann ab; so läuft der Rundgang jetzt.

Plan mit Reihenfolge und Aufwand: `docs/ALLE-GERAETE-PLAN-2026-11-13.md`.
