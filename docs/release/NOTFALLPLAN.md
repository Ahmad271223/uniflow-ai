# Notfallplan: Fehler nach einem Release, Rollback, Wiederherstellung (Stand 28.10.2026)

## 1. Kritischer Fehler entdeckt (1210)

1. **Einordnen:** Datenverlust oder Sicherheitslücke = sofort; Absturz oder falsche Anzeige = am selben Tag.
2. **Windows-App:** den letzten guten Installer (Artefakt `uniflow-windows` des Laufs davor, `apps/windows/src-tauri/target/installer-*`)
   bereitstellen. Ein älterer Installer über einer neueren Version installiert die alte Version; die Daten bleiben
   (Datenordner getrennt, Migrationen nur additiv, siehe 3).
3. **Dienst:** auf das vorige Image bzw. den vorigen Commit zurück (`git checkout <tag>`, `docker compose up -d --build`),
   siehe `BETRIEB.md` Abschnitt 8. Vorher ein Backup ziehen (Abschnitt 9).
4. **Nutzer informieren:** Hinweis in der App (Ankündigung), bei Datenverlust oder Sicherheitslücke E-Mail an alle
   betroffenen Konten; bei Datenschutzvorfällen innerhalb von 72 Stunden die Aufsichtsbehörde (Art. 33 DSGVO).
5. **Daten wiederherstellen:** Dienst aus dem nächtlichen Backup (`deploy/backup.sh`), je Konto eigene SQLite-Datei;
   Windows aus `%LOCALAPPDATA%\UniFlow-Sicherungen` (beim Start angelegt, die neuesten bleiben); Notizen zusätzlich
   aus `annotation_versions` (die letzten 30 Fassungen je Datei).
6. **Nachher:** Ursache, Test, der den Fehler zeigt, Fix, neuer Release; Eintrag in diesem Dokument.

## 2. Server-Rollback und Migrationen (1208, 1209)

- Migrationen sind **nur additiv**: neue Tabellen, neue Spalten mit Standardwert (`db.add_column`, `CREATE TABLE IF NOT
  EXISTS`). Es wird nie umbenannt oder gelöscht. Eine ältere Serverversion ignoriert neue Spalten und Tabellen und
  beschädigt nichts; nach dem erneuten Update sind die Daten der neuen Felder noch da.
- Zwei Prozesse, die gleichzeitig migrieren (Update mit mehreren API-Prozessen), sind kein Fehler.
- Reihenfolge beim Update: Backup → neue Version starten (migriert beim ersten Zugriff je Konto) → Prüfen → erst dann
  alte Images löschen.

## 3. Windows-Installer abgebrochen (1205)

Programm (`%LOCALAPPDATA%\UniFlow`) und Daten (`%LOCALAPPDATA%\de.uniflow.desktop`) sind getrennt; der Installer
schreibt nie in den Datenordner. Bricht die Installation ab, den Installer erneut starten. Die App legt beim Start
eine Sicherung der Datenbank an.

## 4. Gerät verloren (1204)

- Unter Konto → **Angemeldete Geräte** das verlorene Gerät abmelden (Windows: Community → Studora-Konto; Web:
  Konto-Menü). Das Gerät kann danach nichts mehr mit dem Konto abgleichen oder veröffentlichen.
- **Grenzen:** Was schon auf dem Gerät liegt (Notizen, heruntergeladene PDFs, Datenbank), bleibt dort lesbar, solange
  das Gerät entsperrt ist. Schutz gibt nur die Geräteverschlüsselung (Windows BitLocker bzw. Geräteverschlüsselung,
  iPad Code-Sperre). Das Hochschul-Passwort liegt nie in der App; das Studora-Passwort wird nicht gespeichert; das
  Sitzungs-Token wird mit dem Abmelden ungültig.
