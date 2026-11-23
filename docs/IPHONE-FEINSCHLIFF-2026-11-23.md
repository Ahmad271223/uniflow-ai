# iPhone-Feinschliff (Zweig `app/iphone-feinschliff`, 23.11.2026)

Auftrag des Inhabers 23.11.2026: das Handy-Design von StudGo (freie Stud.IP-App der LUH) ansehen und unsere
iPhone-Fassung verbessern. Nur Ideen übernommen, kein Code, kein Name, kein Logo. Alles gilt nur in der kompakten
Fassung (`ufCompact`: iPhone, iPad im schmalen Split View); iPad und Mac in voller Breite bleiben unverändert.

## Umgesetzt

| Was | Wo | Warum |
| --- | --- | --- |
| Terminzeilen in „Heute an der Uni“: Beginn fett, Ende klein, 4-pt-Balken in Modulfarbe, Titel bis 2 Zeilen, Raum darunter | `DashboardView.compactEventRow` | auf 402 pt wurde der Titel nach wenigen Zeichen gekürzt |
| Kopfzeile auf Unterseiten mit dem Namen des Bereichs (Modul → „Meine Module“, Einstellungs-Gruppe → „Einstellungen“); auf Bereichs-Startseiten weiter „StudiNow“ | `UFNavItem.compactTitle`, `UFHeader.compactBar` | nach dem Scrollen war nicht mehr zu sehen, wo man ist; auf Startseiten stünde der Name doppelt |
| Ziehen zum Aktualisieren auf jeder scrollenden Seite; auf der Übersicht derselbe Abgleich wie der Knopf „Sync“ | `UFPullToRefresh`, `UFSyncAction` (AppShell.swift) | Gewohnheit aus allen System-Apps; vorher nur an zwei Stellen |
| Offenen Reiter erneut antippen: Seite nach oben; leichter Tick beim Reiterwechsel; runde Markierung | `UFMobileNav`, `UFContent` (`.ufScrollToTop`) | wie die Tab-Leiste des Systems |
| Begrüßung kleiner (24 statt 30,4 pt, Unterzeile 13,5 pt), Wortlaut gleich | `UFPageHeadGreet` | rund 170 pt bis zum ersten Inhalt |
| Karten-Innenabstand 15 pt statt 17,6/19,2 pt | `UFCard` | mehr Platz für Inhalt auf schmalen Bildschirmen |

Nur Debug: `-UFScroll center` (Mitte der Seite für Bildvergleiche).

## Bewusst nicht umgesetzt (Entscheidung des Inhabers nötig)

- „läuft · noch 35 Min“ / „in 25 Min“ in der Zeile des laufenden bzw. nächsten Termins (innerhalb von „Heute an der
  Uni“, keine eigene Karte – die Startseite hat seit 13.11. keinen Termine-Block).
- Kennzahl-Zeile an leeren Tagen begründen („keine Uni-Termine heute“, Feiertag, vorlesungsfrei) – die Zeile ist
  vom Inhaber freigegeben.
- iPhone-Store-Bilder neu: die Bilder vom 14.11. zeigen noch Lernkalender und „Weiterlernen“.

## Prüfen

- iPhone-Suite nach docs/TESTLAEUFE.md (IPhone*Tests + LayoutWidthAuditTests).
- Vorher/Nachher im Simulator (iPhone 17 Pro, Demo + `-UFCalendarSample`).
- Am Gerät: per Kabel auf iPhone und iPad, erst dann in einen Build.
