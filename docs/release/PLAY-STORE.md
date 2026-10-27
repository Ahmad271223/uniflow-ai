# Google Play Console – Texte und Angaben (Android, ab V2)

**Entwurf, Stand 26.10.2026, Sprache de-DE.** Felder in `text`-Blöcken mit Feldnamen; `tests/test_release_texts.py`
prüft Längen und dass kein Text KI-Funktionen verspricht. Die Android-App (`apps/android`) ist eine erste Fassung
(Konto, Dokumente, PDF mit Stift, Stundenplan, Lernkalender); Karteikarten, Noten und Community fehlen dort noch.
Die Texte gelten für den Stand, der eingereicht wird – Aussagen in `[[…]]` erst aufnehmen, wenn die Funktion in der
Android-App läuft.

## Store-Eintrag

```text title
UniFlow – Studium & Notizen
```

```text short
Stud.IP und Learnweb auf dem Tablet: Dateien, Stundenplan, Lernkalender, Stift.
```

```text full
UniFlow bringt dein Studium an einen Ort: die Dateien und Termine aus den Systemen deiner Hochschule, dein Stundenplan, dein Lernkalender und deine handschriftlichen Notizen – auf dem Tablet, mit dem Stift.

FÜR STUDIERENDE DER LEIBNIZ UNIVERSITÄT HANNOVER UND DER UNIVERSITÄT HILDESHEIM
Melde dich mit deinem UniFlow-Konto an und verbinde deine Hochschule. UniFlow holt neue Skripte, Übungsblätter und Folien aus deinen Kursen, ordnet sie nach Modulen und übernimmt Vorlesungs- und Übungstermine, Abgabefristen und Ankündigungen der Lehrenden. Die App liest nur und schreibt nichts in die Hochschulsysteme.

DOKUMENTE LESEN UND BESCHREIBEN
• Bibliothek mit Modulordnern und Dokumenten
• PDFs lesen und zoomen
• Mit Plus: Schreiben mit dem Stift (z. B. S Pen) – Stift, Marker, Radierer; Notizen werden mit deinen anderen Geräten abgeglichen

STUNDENPLAN UND LERNKALENDER
• Wochenraster mit deinen Vorlesungen und Übungen
• Lernkalender mit Lernpaketen je Modul und Lehrwoche in deinen freien Zeitfenstern
• Abgabefristen, Feiertage und vorlesungsfreie Zeit auf einen Blick
[[• Eigene Karteikarten mit Wiederholung (Plus)]]
[[• Lösungen zu Übungsblättern mit anderen vergleichen – verschlüsselt, unter Pseudonym, mit Melden und Sperren (Plus)]]

EIN KONTO FÜR ALLE GERÄTE
Mit deinem UniFlow-Konto zeigen Android-Tablet, iPad, Windows und Web denselben Stand: Dokumente, Notizen, Stundenplan und Lernkalender.

DEINE DATEN
• Kein Tracking, keine Werbung, keine Analyse-Werkzeuge Dritter.
• Hochschul-Zugangsdaten speicherst du nur, wenn du den automatischen Abgleich willst – verschlüsselt, jederzeit löschbar.
• Konto löschen direkt in der App.

UNIFLOW FREE UND PLUS
Free ist dauerhaft kostenlos: Abgleich mit der Hochschule, Lesen, Stundenplan, Lernkalender und Lernplanung. UniFlow Plus (1,99 € pro Monat, die erste Woche gratis) schaltet das Schreiben mit dem Stift und den Abgleich zwischen deinen Geräten frei[[, dazu Karteikarten und das Teilen von Lösungen]]. Das Abo verlängert sich automatisch um einen Monat, wenn du es nicht vor Ende des laufenden Zeitraums in Google Play kündigst. Nach dem Ende von Plus bleiben alle Notizen lesbar und exportierbar.

Nutzungsbedingungen: [[Domain]]/nutzungsbedingungen
Datenschutz: [[Domain]]/datenschutz

UniFlow ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.
```

## Weitere Angaben

| Feld | Wert |
|---|---|
| App-Kategorie | Bildung |
| Tags | Lernen, Produktivität, Notizen |
| Kontaktdaten | E-Mail [[E-Mail]], Telefon [[Telefon]], Website `[[Domain]]` (werden öffentlich angezeigt) |
| Datenschutzerklärung | `[[Domain]]/datenschutz` |
| Konto löschen (Pflicht bei Kontoerstellung) | in der App: Einstellungen → Konto → Konto löschen; URL `[[Domain]]/konto-loeschen` |
| Zielgruppe und Inhalte | nur „18 und älter“ (Studierende; keine Kinder-Zielgruppe, damit die Families-Richtlinien nicht greifen) |
| Werbung | enthält keine Werbung |
| App-Zugriff | „Alle Funktionen sind ohne besondere Zugangsdaten verfügbar“ gilt **nicht** – Anleitung hinterlegen: Konto anlegen in der App; Hochschulfunktionen brauchen ein Hochschulkonto; Prüfung mit den Demo-Inhalten (Einstellungen → Erweitert → „Demo-Inhalte anlegen“: Demo-Modul mit PDFs, Stundenplan, Lernkalender, Frist, Ankündigung) |
| Paketname | `de.uniflow.android` (`apps/android/app/build.gradle.kts`) |

## Inhaltseinstufung (IARC-Fragebogen)

Gewalt, sexuelle Inhalte, Sprache, kontrollierte Substanzen, Glücksspiel: jeweils **nein**. „Nutzer können
interagieren oder Inhalte austauschen“: **ja**, sobald die Community in der Android-App ist (Lösungen als
verschlüsselte Pakete, kein Chat), mit Moderation, Melden und Sperren; bis dahin **nein**. „Teilt den Standort“: nein.
„Käufe digitaler Güter“: ja (Abo). Erwartete Einstufung: USK 0 / PEGI 3.

## Datensicherheit (Formular „Data safety“)

| Frage | Antwort |
|---|---|
| Erhebt oder teilt die App Nutzerdaten? | Ja (erhebt), teilt nicht |
| Verschlüsselung bei der Übertragung | Ja (TLS) |
| Löschung anfordern | Ja – in der App und über `[[Domain]]/konto-loeschen` |
| Unabhängige Sicherheitsprüfung | Nein |

| Datentyp | Erhoben | Geteilt | Optional | Zweck |
|---|---|---|---|---|
| Persönliche Daten → E-Mail-Adresse, Nutzer-IDs | ja | nein | nein (Konto nötig) | App-Funktionen, Kontoverwaltung |
| Dateien und Dokumente (Dokumente, Notizen; Community-Pakete verschlüsselt) | ja | nein | ja (Geräteabgleich, Community) | App-Funktionen |
| Kalender (Stundenplan, Lernkalender – nur in der App, kein Gerätekalender) | ja | nein | ja | App-Funktionen |
| Finanzdaten → Kaufverlauf (Abo-Status) | ja | nein | ja | App-Funktionen |
| Standort, Kontakte, Fotos, Audio, Gesundheit, Aktivität, Browserverlauf, Geräte-IDs, Absturzprotokolle, Diagnose | nein | – | – | – |

Hochschul-Zugangsdaten für den automatischen Abgleich: vom Nutzer freiwillig hinterlegt, verschlüsselt gespeichert,
nur zur Erbringung der Funktion verwendet, jederzeit löschbar – in der Erklärung unter „Persönliche Daten → andere
Informationen“ angeben, [[mit der Google-Dokumentation zum Zeitpunkt der Einreichung abgleichen]].

## Abo-Produkt (Play Billing)

| Feld | Wert |
|---|---|
| Produkt-ID | `plus_monthly` |
| Name | UniFlow Plus |
| Beschreibung | Stift, Geräteabgleich, Karteikarten, Lösungen teilen |
| Basisplan | `monthly`, 1 Monat, automatisch verlängernd, 1,99 € |
| Angebot | `trial-7d`, 7 Tage gratis, einmal je Google-Konto |

Pflichttexte auf der Tarifseite in der App wie bei Apple: Preis und Laufzeit, automatische Verlängerung, Kündigung
in Google Play, Links zu Nutzungsbedingungen und Datenschutzerklärung.

## Bildschirmfotos (Tablet, 16:10 oder 16:9)

1. PDF mit Stift-Notizen · 2. Bibliothek nach Modulen · 3. Stundenplan · 4. Lernkalender · 5. Anmeldung mit
UniFlow-Konto. Nur echte App-Inhalte, keine Uni-Logos ohne Erlaubnis, keine echten Namen oder Noten.
