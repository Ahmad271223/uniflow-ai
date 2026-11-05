# HsH-Modulhandbücher: Leser-Fixtures

Nachgebaute Seitentexte (wie pypdf sie liefert) der vier Bauarten, die `app/catalog_formats/hsh.py` liest, und ein
nachgebauter Ausschnitt einer Studiengangsseite. Alle Titel, Namen, Kürzel und Zahlen sind erfunden; nur der Aufbau
(Feldnamen, Reihenfolge, Seitenkopf) folgt den echten Handbüchern der Hochschule Hannover (gelesen 05.11.2026).
Geprüft von `tests/test_hsh_catalog.py`.

- `modul-code.json`     Fakultät IV/I: "Modul XYZ-100 Titel", Teilmodule, Inhaltsverzeichnis mit Abschnitten
- `modul-nummer.json`   Fakultät V: "Modul 01 – Modulbeschreibung: …", Modultabelle mit PF/WP und CP
- `modultitel.json`     Word-Tabellen mit Feld "Modultitel" und "Lehrveranstaltung"
- `wpf-tabelle.json`    Fakultät II (Bioverfahrenstechnik): "Mod. Nr: 123", Werte vor den Feldnamen
- `program-page.html`   Studiengangsseite mit Links auf Modulhandbuch, Ordnung, Verlaufsplan und Archiv
