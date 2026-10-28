# Originaltext vom Inhaber (Verlauf mit einer anderen KI), wortgetreu – Teil 2

Eingefügt vom Inhaber in die PC-Sitzung am 28.10.2026, unverändert übernommen, damit die Mac-Sitzung alles im Wortlaut hat. **Das ist Material, kein Auftrag:** Was davon gilt, steht in `docs/ENTSCHEIDUNGEN-INHABER-2026-10-28.md` und `docs/PRUEFKATALOG-ABGLEICH-2026-10-28.md`. Die andere KI kannte meist nur `main` (24.10.); Aussagen über fehlende Funktionen bitte gegen `develop` prüfen.

---

Bleibt es bei den vier Tarifen? ja
Wann startest du, und mit welchem Umfang? in 5 tagen 
Kommt das iPhone schon in die erste Version? nein
Soll die Community über iCloud laufen, also nur auf Apple, oder über den Server, also auch auf Windows? auf beiden soll das laufen und man kann sein acc aufhaben auf windows und aplle 
Ist das Ziel wirklich 30.000 gleichzeitig? ja  Das braucht eine andere, kostenpflichtige Architektur und echte Lasttests.
Dürfen Hochschul-PDFs auf dem Server liegen? so wie es chat gbt dir erklärt hat das modekl übernehmen mit der chace cloud api usw lokal Das ist eine Urheberrechtsfrage.
Soll Word nur angezeigt oder auch bearbeitet werden? erst mal nur angezeigt werden 


UniFlow AI – Vollständiger Ausbau bis zur Release-Reife
Wir machen jetzt nicht nur weitere 30 Punkte, sondern schließen die gesamte bisherige Planung systematisch ab. Ich setze bei Anforderung 536 an und gehe bis 700.
Damit decken wir die noch fehlenden Bereiche von der Registrierung über Stud.IP, den PDF-Editor und die Apple-Windows-Synchronisierung bis hin zu Sicherheit, Skalierung, App-Veröffentlichung und laufendem Betrieb ab.
Wichtig: Das ist die vollständige Anforderungs- und Abnahmeplanung. Sie bedeutet nicht, dass alle Funktionen bereits programmiert oder getestet wurden.
Phase 1 – Benutzerkonten, Registrierung und Anmeldung
63. Identität und Kontosicherheit · 536–550
536. Registrierung: Studenten können ein Konto mit E-Mail und Passwort erstellen; doppelte Konten werden verhindert.
537. E-Mail-Verifizierung: Ein zeitlich begrenzter Bestätigungslink aktiviert die E-Mail-Adresse.
538. Passwortregeln: Sichere Passwortverarbeitung mit Argon2id, Prüfung bekannter kompromittierter Passwörter und Schutz gegen automatisierte Anmeldeversuche.
539. Passwort vergessen: Einmalige Reset-Links ohne Preisgabe, ob eine E-Mail-Adresse registriert ist.
540. Passkeys: Plattformübergreifende Anmeldung mit WebAuthn, soweit vom Gerät unterstützt.
541. Zwei-Faktor-Authentifizierung: TOTP oder Passkeys, inklusive sicherer Wiederherstellung.
542. Apple-Anmeldung: Sign in with Apple, sofern angeboten, mit korrekter Kontoverknüpfung.
543. Kontoverknüpfung: Unterschiedliche Anmeldemethoden dürfen nicht versehentlich zwei getrennte Benutzerkonten erzeugen.
544. Sitzungsverwaltung: Jedes Gerät erhält eine eigene widerrufbare Sitzung.
545. Token-Rotation: Kurzlebige Zugriffstoken, rotierende Refresh-Tokens und Schutz gegen Wiederverwendung.
546. Geräteverlust: Studenten können ein verlorenes Gerät remote abmelden.
547. Kontowiederherstellung: Sichere Wiederherstellung ohne Umgehung der Mehrfaktor-Authentifizierung.
548. E-Mail-Wechsel: Neue Adresse bestätigen; sicherheitsrelevante Benachrichtigung an die alte Adresse.
549. Kontosperren: Missbrauchsschutz ohne unnötige dauerhafte Sperren legitimer Nutzer.
550. Mandantentrennung: Jeder Zugriff wird gegen die konkrete Benutzer-, Hochschul- und Kursberechtigung geprüft.
Phase 2 – Onboarding und Hochschulverbindung
64. Ersteinrichtung · 551–565
551. Begrüßungsbildschirm: Drei kurze Schritte erklären die Kernfunktionen.
552. Hochschulsuche: Hochschule nach Name oder Ort auswählen.
553. Hochschulverfügbarkeit: Sichtbar machen, welche Integrationen tatsächlich unterstützt werden.
554. Stud.IP-Verbindung: Sichere, autorisierte Anmeldung mit möglichst offiziellen Schnittstellen.
555. Keine Passwortweitergabe: Zugangsdaten nicht unnötig auf UniFlow-Servern speichern.
556. Verbindungsprüfung: Erreichbarkeit, Berechtigungen und Ablauf von Anmeldesitzungen testen.
557. Kursimport: Aktuelle Veranstaltungen automatisch erkennen.
558. Kursauswahl: Studenten können einzelne Veranstaltungen importieren oder ausblenden.
559. Modulzuordnung: Mehrere Veranstaltungen können einem Studienmodul zugeordnet werden.
560. Vorlesung und Übung: Veranstaltungstypen erkennen und manuell korrigierbar machen.
561. Erstimport: Dateien mit Fortschrittsanzeige und nachvollziehbaren Fehlermeldungen importieren.
562. Mehrere Hochschulen: Ein Konto kann mehrere zulässige Hochschulverbindungen besitzen.
563. Manuelle Einrichtung: UniFlow muss auch ohne Stud.IP nutzbar sein.
564. Onboarding fortsetzen: Abgebrochene Einrichtung beim nächsten Start wieder aufnehmen.
565. Importabschluss: Eine Übersicht zeigt Kurse, Dateien und noch offene Probleme.
Phase 3 – Dashboard und Navigation
65. Einheitliche Benutzeroberfläche · 566–580
566. Persönliches Dashboard: Heutige Aufgaben, Kurse und zuletzt verwendete Dokumente anzeigen.
567. Kursübersicht: Einheitliche Kurskarten mit Semester, Fach und Fortschritt.
568. Globale Suche: Kurse, Dateinamen, Notizen und Aufgaben durchsuchen.
569. Zuletzt geöffnet: Dokumente geräteübergreifend fortsetzen.
570. Favoriten: Kurse und Dokumente anheften.
571. Windows-Navigation: Seitenleiste, Tastatursteuerung und mehrere Fenster.
572. iPad-Navigation: Adaptive Seitenleiste und Split View.
573. iPhone-Navigation: Kompakte Tab-Navigation mit sinnvollen Unterseiten.
574. macOS-Navigation: Desktopgerechte Menübefehle und Fensterverwaltung.
575. Deep Links: Dokumente und Aufgaben über interne Links direkt öffnen.
576. Zurück-Navigation: Konsistentes Verhalten nach Suche, Benachrichtigungen und Deep Links.
577. Ladezustände: Skeletons und Fortschrittsanzeigen statt leerer Bildschirme.
578. Fehlerzustände: Verständliche Meldungen mit Wiederholen- oder Wiederherstellen-Aktion.
579. Offline-Anzeige: Deutlich unterscheiden, was lokal und was nur online verfügbar ist.
580. Synchronisierungsstatus: Anzeigen, ob Änderungen lokal gespeichert, übertragen oder bestätigt sind.
Phase 4 – Dokumentbibliothek und PDF-Editor
66. Dokumente und Dateiverwaltung · 581–595
581. Einheitliche Bibliothek: Dateien aus Stud.IP, eigenen Uploads und Notizbüchern zusammenführen.
582. Ordnerstruktur: Semester, Module, Unterordner und eigene Sammlungen.
583. Dateiversionen: Geänderte Originaldateien erkennen und frühere Versionen wiederherstellen.
584. Duplikaterkennung: Identische Inhalte anhand von Hashes erkennen, ohne Zugriffsrechte zu umgehen.
585. Dateivorschau: PDF-Vorschaubilder effizient erzeugen und zwischenspeichern.
586. Offline-Download: Einzelne Dokumente oder ganze Kurse lokal verfügbar machen.
587. Cacheverwaltung: Speicherverbrauch anzeigen und nicht benötigte Dateien entfernen.
588. Dateiintegrität: Prüfsummen nach Upload und Download kontrollieren.
589. Unterbrochene Downloads: Große Dateien zuverlässig fortsetzen.
590. Papierkorb: Gelöschte Dateien innerhalb einer definierten Frist wiederherstellen.
591. Dokumentverschiebung: Kurs- und Ordnerzuordnung ändern, ohne Annotationen zu verlieren.
592. Importformate: PDF, Bilder und unterstützte Office-Dokumente sicher verarbeiten.
593. Export: Dokumente mit oder ohne Annotationen exportieren.
594. Dateiberechtigungen: Zugriff nach Benutzer und Kursmitgliedschaft begrenzen.
595. Urheberrecht: Hochschulmaterialien nur im zulässigen Rahmen speichern und bereitstellen.
67. Plattformübergreifender Editor · 596–610
596. Gemeinsames Seitenmodell: Identische Seiten-IDs auf Apple und Windows.
597. Gemeinsames Koordinatensystem: Annotationen bleiben bei Zoom, Rotation und unterschiedlichen Displays korrekt.
598. Stifteingabe: Apple Pencil, Windows Pen und Touch unterstützen.
599. Druckempfindlichkeit: Verfügbare Druckdaten erhalten und korrekt darstellen.
600. Textmarker: Transparenz und Farbüberlagerung konsistent halten.
601. Radierer: Objekt- und Pixelradierung klar unterscheiden.
602. Lasso: Objekte auswählen, verschieben und skalieren.
603. Textfelder: Einheitliche Schrift- und Positionsdaten.
604. Formen: Linien, Pfeile, Rechtecke und Kreise plattformübergreifend darstellen.
605. Bilder: Bilder als versionierte Dokumentobjekte einfügen.
606. Seiten hinzufügen: Leere, linierte und karierte Seiten ergänzen.
607. Seitenreihenfolge: Verschieben und Löschen als konfliktfähige Operationen speichern.
608. Undo/Redo: Eigene Aktionen rückgängig machen, ohne fremde Änderungen zu zerstören.
609. Split View: PDF und Notizfläche unabhängig scrollen und zoomen.
610. Exporttreue: Annotationen nach PDF-Export visuell und inhaltlich prüfen.
Phase 5 – Cloud-Synchronisierung ohne stillen Datenverlust
68. Geräteübergreifende Zusammenarbeit · 611–625
611. Dauerhafte Offline-Warteschlange: Jede Änderung wird vor der Übertragung lokal gespeichert.
612. Eindeutige Änderungs-IDs: Wiederholte Uploads dürfen keine doppelten Striche erzeugen.
613. Versionskontrolle: Jede Dokumentänderung basiert auf einer bekannten Revision.
614. Serverbestätigung: Nur ausdrücklich bestätigte Änderungen werden als synchronisiert markiert.
615. Änderungen während Uploads: Neue Bearbeitungen dürfen nicht durch ältere Upload-Antworten gelöscht werden.
616. Konflikterkennung: Gleichzeitige Bearbeitungen desselben Objekts erkennen.
617. Konfliktlösung: Unabhängige Änderungen zusammenführen und echte Konflikte nachvollziehbar anzeigen.
618. WebSocket-Ereignisse: Andere Online-Geräte zeitnah über Änderungen informieren.
619. Nachsynchronisierung: Verpasste Ereignisse über einen gespeicherten Cursor nachholen.
620. Wiederverbindung: Unterbrochene Übertragungen mit begrenzten Wiederholungsversuchen fortsetzen.
621. App-Absturz: Nach Neustart sämtliche dauerhaft lokal gesicherten Änderungen wiederherstellen.
622. Gerätewechsel: Dokument, Seite und letzte Bearbeitungsposition übernehmen.
623. Native PencilKit-Daten: Apple-spezifische Informationen bei Windows-Bearbeitungen erhalten.
624. Schema-Upgrades: Alte und neue App-Versionen kontrolliert miteinander kompatibel halten.
625. Synchronisierungsdiagnose: Fehler anhand technischer IDs untersuchen, ohne private Dokumentinhalte zu protokollieren.
Phase 6 – Lernkalender und KI
69. Lernplanung · 626–640
626. Semesterkalender: Veranstaltungen, Prüfungen und persönliche Termine darstellen.
627. Automatischer Lernplan: Lernaufgaben aus Modulen, Prüfungsdaten und verfügbarer Zeit erstellen.
628. Tagesplanung: Sinnvolle Anzahl an Fächern und Aufgaben pro Tag berücksichtigen.
629. Wochenansicht: Lernbelastung und freie Zeit übersichtlich anzeigen.
630. Nicht erledigte Aufgaben: Automatisch zur Neuplanung anbieten, ohne Termine ungefragt zu verschieben.
631. Prüfungspriorität: Nahe Prüfungen und Wissenslücken stärker gewichten.
632. Aufgabentypen: Lesen, Zusammenfassen, Rechnen, Wiederholen und Testen unterscheiden.
633. Zeitaufwand: Geschätzte und tatsächlich benötigte Lernzeit erfassen.
634. Wiederholungsintervalle: Spaced Repetition für geeignete Lerninhalte verwenden.
635. Kalendersynchronisierung: Änderungen auf Apple und Windows konsistent halten.
636. Benachrichtigungen: Einstellbare Erinnerungen für Prüfungen und Lernaufgaben.
637. Ruhezeiten: Benachrichtigungen nachts und während festgelegter Zeiten unterdrücken.
638. Ausfalltage: Krankheit, Urlaub oder andere Pausen berücksichtigen.
639. Lernstatistik: Fortschritt und offene Aufgaben verständlich auswerten.
640. Planerklärung: Studenten nachvollziehbar zeigen, warum eine Aufgabe vorgeschlagen wurde.
70. KI-Tutor und Tests · 641–655
641. Kursbezogener KI-Tutor: Antworten auf ausgewählte Kursunterlagen stützen.
642. Quellenverweise: Verwendete Dokumente und Seiten angeben.
643. Unsicherheit: Fehlende Belege oder unklare Antworten offen kennzeichnen.
644. Schrittweise Erklärungen: Schwierigkeit an den Kenntnisstand anpassen.
645. Übungsmodus: Hilfestellungen geben, ohne sofort die gesamte Lösung vorwegzunehmen.
646. Automatische Tests: Fragen aus zugelassenen Kursmaterialien erzeugen.
647. Fragetypen: Multiple Choice, Freitext, Rechenaufgaben und Zuordnung.
648. Antwortauswertung: Lösungen anhand nachvollziehbarer Kriterien prüfen.
649. Fehleranalyse: Wiederkehrende Wissenslücken erkennen.
650. Gezielte Wiederholung: Passende Übungen zu Fehlern empfehlen.
651. Testhistorie: Ergebnisse über alle Geräte hinweg verfügbar halten.
652. KI-Nutzungslimits: Tarifberechtigungen serverseitig prüfen.
653. Kostenkontrolle: Token-, Modell- und Anfragekosten überwachen.
654. Datenschutz: Persönliche Inhalte nur entsprechend den geltenden Einwilligungen und Verträgen verarbeiten.
655. KI-Qualitätstests: Fachliche Fehler, falsche Quellen und instabile Bewertungen regelmäßig prüfen.
Phase 7 – Community und Zusammenarbeit
71. Kursgemeinschaften · 656–670
656. Kursgruppen: Studenten können zulässigen Kursgemeinschaften beitreten.
657. Beiträge: Fragen, Diskussionen und Hinweise veröffentlichen.
658. Kommentare: Antworten mit stabilen IDs und nachvollziehbarer Reihenfolge.
659. Dateianhänge: Eigene Lösungen und Bilder sicher hochladen.
660. PDF-bezogene Diskussionen: Kommentare an Dokumentseiten oder Stellen verankern.
661. Lösungen teilen: Eigene Annotationen getrennt vom geschützten Original-PDF freigeben.
662. Privatsphäre: Vor dem Teilen persönliche Daten und Metadaten prüfen.
663. Meldesystem: Unangemessene Inhalte melden.
664. Moderation: Beiträge nach transparenten Regeln prüfen und entfernen.
665. Missbrauchsschutz: Spam, Massenuploads und automatisierte Angriffe begrenzen.
666. Benachrichtigungen: Antworten und relevante Diskussionen melden.
667. Suche: Community-Beiträge kursbezogen durchsuchen.
668. Berechtigungen: Private Kursinhalte nicht versehentlich öffentlich zugänglich machen.
669. Löschfunktionen: Eigene Inhalte und personenbezogene Daten kontrolliert entfernen.
670. Community-Tests: Rollen, Rechte, Moderation und Dateizugriff automatisiert prüfen.
Phase 8 – Datenschutz, Sicherheit und Zahlungen
72. Datenschutz und Nutzerrechte · 671–680
671. Datenschutzerklärung: Tatsächliche Datenverarbeitung verständlich und vollständig beschreiben.
672. Datenminimierung: Nur notwendige personenbezogene Daten erheben.
673. Datenexport: Benutzer können ihre Daten in geeigneten Formaten herunterladen.
674. Kontolöschung: Löschprozess einschließlich Backups, Aufbewahrungsfristen und gesetzlichen Pflichten definieren.
675. Einwilligungsverwaltung: Freiwillige KI- und Analysefunktionen getrennt steuern.
676. Zugriffsprotokolle: Sicherheitsrelevante Ereignisse datensparsam protokollieren.
677. Auftragsverarbeitung: Verträge und Drittanbieter für Hosting, E-Mail und KI prüfen.
678. Datenschutzvorfälle: Melde-, Untersuchungs- und Reaktionsprozess vorbereiten.
679. Sicherheitsprüfung: Authentifizierung, API, Dateiuploads und Mandantentrennung testen.
680. Wiederherstellbarkeit: Verschlüsselte Backups und tatsächliche Restore-Tests durchführen.
73. Abonnements und Abrechnung · 681–690
681. Tarifverwaltung: Preise und Leistungsgrenzen zentral konfigurieren.
682. Berechtigungsprüfung: Premiumfunktionen ausschließlich serverseitig freischalten.
683. Apple-Abonnements: App-Store-Regeln für digitale Funktionen berücksichtigen.
684. Windows/Web-Zahlungen: Geeigneten Zahlungsanbieter und Plattformregeln berücksichtigen.
685. Plattformübergreifende Freischaltung: Ein bezahltes Konto erhält die vertraglich vorgesehenen Funktionen auf allen Geräten.
686. Kaufwiederherstellung: Bestehende App-Store-Käufe zuverlässig erkennen.
687. Webhook-Verarbeitung: Zahlungsereignisse idempotent und signaturgeprüft verarbeiten.
688. Kündigung: Zugriffsrechte nach dem tatsächlichen Abonnementstatus steuern.
689. Rückerstattung: Berechtigungen bei Rückerstattungen korrekt aktualisieren.
690. Abrechnungstests: Testkäufe, Verlängerungen, Kündigungen und Zahlungsfehler simulieren.
Phase 9 – Veröffentlichung und laufender Betrieb
74. Release und Skalierung · 691–700
691. Windows-Installer: Signiertes Installationspaket und kontrollierte Updates.
692. iPad- und iPhone-Builds: Reproduzierbare Xcode-Builds und Tests auf echten Geräten.
693. macOS-Build: Signierung, Notarisierung und Updateverfahren.
694. App-Store-Einreichung: Datenschutzangaben, Screenshots und Review-Anforderungen erfüllen.
695. Microsoft-Store-Veröffentlichung: Paketierung und Store-Anforderungen prüfen.
696. CI/CD: Automatisierte Tests, Builds und Sicherheitsprüfungen vor jedem Release.
697. Stufenweiser Rollout: Neue Versionen zunächst für begrenzte Nutzergruppen freigeben.
698. Monitoring: Verfügbarkeit, API-Latenz, Synchronisierungsfehler und Kosten beobachten.
699. Lasttests: 30.000 gleichzeitige Sitzungen mit realistischen Downloads und Bearbeitungen simulieren.
700. Go-live-Freigabe: Veröffentlichung erst nach bestandenen Funktions-, Sicherheits-, Wiederherstellungs- und Belastungstests.
Phase 10 – Was vor einem echten Release zwingend nachgewiesen werden muss
Die 700 Anforderungen bilden einen umfassenden Plan. Für eine reale Veröffentlichung ist entscheidend, dass nicht nur Funktionen existieren, sondern die folgenden Szenarien tatsächlich funktionieren.
Release-Abnahmecheckliste
0 von 12 bestätigt
0 %
Ein Konto funktioniert auf Windows, iPad und iPhone
Neue Stud.IP-Folien erscheinen automatisch auf berechtigten Geräten
Apple-Pencil-Notizen erscheinen korrekt auf Windows
Windows-Änderungen erscheinen korrekt auf Apple
Offline-Änderungen überstehen App-Abstürze
Gleichzeitige Bearbeitungen verursachen keinen stillen Datenverlust
Fremde Benutzer können keine privaten Dateien abrufen
Zahlungen und Premiumrechte stimmen auf allen Plattformen
Backups lassen sich vollständig wiederherstellen
30.000 aktive Sitzungen bestehen den definierten Lasttest
App-Store- und Microsoft-Store-Anforderungen sind erfüllt
Monitoring, Support und Incident-Prozesse sind betriebsbereit
Diese Checkliste dient der manuellen Projektplanung. Das Ankreuzen führt keine technischen Tests aus.
Master-Prompt 19 – Alle 700 Anforderungen umsetzen und prüfen
UniFlow AI – Vollständiger Entwicklungs- und Releaseauftrag
Repository: Ahmad271223/uniflow-ai
Auftrag
Entwickle UniFlow AI zu einer sicheren, stabilen und plattformübergreifenden Lernanwendung für Windows, iPad, iPhone und macOS.
Arbeite sämtliche bisher definierten Anforderungen 1–700 ab. Berücksichtige insbesondere die neuen Anforderungen 536–700 sowie die Cloud-Synchronisierungsarchitektur.
Vorgehensweise
1. Bestandsaufnahme
Untersuche den gesamten aktuellen Repository-Zustand.
Erstelle eine Anforderungsmatrix mit:

* Anforderungsnummer
* Funktionsbeschreibung
* Vorhandener Implementierung
* Fehlenden Komponenten
* Priorität P0/P1/P2
* Betroffenen Plattformen
* Teststatus
* Nachweis durch Code und Tests

Markiere jede Anforderung als:

* Nicht begonnen
* In Arbeit
* Implementiert, nicht getestet
* Getestet
* Blockiert

2. Kritische Grundlage zuerst
Implementiere vor zusätzlichen Komfortfunktionen:

* Sichere Benutzerkonten
* Mehrbenutzerfähiges Cloud-Backend
* PostgreSQL
* Privaten Dateispeicher
* Stabile Dokument- und Objekt-IDs
* Dauerhafte lokale Änderungswarteschlangen
* Idempotente Synchronisierung
* Versions- und Konfliktbehandlung
* Geräteübergreifende Berechtigungen
* Sichere Datenmigration

3. Apple-Windows-Parität
Stelle sicher, dass Dokumente, Seiten, Stifte, Markierungen, Bilder, Texte und Kommentare auf allen unterstützten Geräten konsistent sind.
Erhalte native Apple-Pencil-Daten und vermeide stille Konvertierungsverluste.
Teste echte Gerätewechsel und gleichzeitige Bearbeitung.
4. Vollständige Produktfunktionen
Implementiere und teste:

* Registrierung und Onboarding
* Hochschul- und Stud.IP-Verbindung
* Automatischen Kurs- und Dokumentimport
* Dashboard
* Bibliothek
* PDF-Editor
* Offline-Modus
* Lernkalender
* KI-Tutor
* KI-Tests
* Community
* Einstellungen
* Datenschutzfunktionen
* Abonnements
* Benachrichtigungen

5. Qualität und Sicherheit
Erstelle automatisierte Unit-, Integrations-, End-to-End-, Sicherheits- und Wiederherstellungstests.
Teste alle kritischen Gerätewechsel, Netzwerkausfälle, App-Abstürze, Synchronisierungskonflikte und Zugriffsrechte.
Führe Lasttests für das Ziel von 30.000 gleichzeitig aktiven Sitzungen aus.
6. Release-Vorbereitung
Erstelle:

* Reproduzierbare Windows-Builds
* Reproduzierbare Apple-Builds
* CI/CD
* Monitoring
* Backup- und Restore-Prozesse
* Datenschutz- und Sicherheitsdokumentation
* Store-Checklisten
* Rollout- und Rollback-Plan
* Technischen Betriebsleitfaden

7. Arbeitsweise
Arbeite in kleinen, überprüfbaren Änderungen auf Feature-Branches.
Führe nach jeder Änderung passende Tests aus.
Behebe nachgewiesene Regressionen, bevor du weitere Funktionen ergänzt.
Erstelle Pull Requests mit nachvollziehbaren Änderungen.
Keine Änderungen an produktiven Systemen, keine kostenpflichtigen Deployments und keine Veröffentlichung ohne ausdrückliche Freigabe.
Wenn ein Schritt durch fehlende Zugangsdaten, externe Freigaben, Plattformhardware oder technische Grenzen blockiert ist, dokumentiere den Blocker präzise und arbeite an unabhängigen Aufgaben weiter.
8. Abschlusskriterium
Beende den Entwicklungsauftrag erst, wenn jede Anforderung entweder nachweislich implementiert und getestet oder mit einem konkreten Blocker dokumentiert ist.
Liefere einen Abschlussbericht mit:

* Erfüllten Anforderungen
* Fehlenden Anforderungen
* Testergebnissen
* Plattformstatus
* Sicherheitsbefunden
* Lasttestergebnissen
* Verbleibenden Risiken
* Release-Empfehlung

Behaupte niemals, dass Funktionen fertig, Tests bestanden oder Lastziele erreicht sind, wenn dafür keine überprüfbaren Nachweise vorliegen.
Gesamtstand der Planung
Anforderungen
700
Master-Prompts
19
Lastziel
30.000
Damit ist die grundlegende Produkt- und Releaseplanung umfassend abgedeckt. Es lassen sich immer weitere Detailanforderungen finden, aber zusätzliche Nummern bringen jetzt weniger als die tatsächliche Implementierung.
Der nächste sinnvolle Schritt ist deshalb, die 700 Anforderungen gegen den echten GitHub-Code zu prüfen, alle fehlenden Funktionen nach Priorität umzusetzen und jeden abgeschlossenen Punkt durch Tests nachzuweisen. Besonders die Cloud-Synchronisierung zwischen Apple und Windows bleibt ein P0-Bereich: Ohne zuverlässige Datensicherung und Konfliktbehandlung sollte UniFlow nicht öffentlich starten.


     das ist etwas aus der app grade :

[Hier stand der persönliche Notenspiegel des Inhabers aus der App – aus Datenschutzgründen nicht übernommen. Befund dazu: `docs/ENTSCHEIDUNGEN-INHABER-2026-10-28.md`, Abschnitt Notenspiegel.]

	  ist das so richig oder doppelt und kann man notenspeigel hinzufügen also schnitt aktuell???      


## Aktueller Vergleich: Was `develop` tatsächlich schon hat

Ich habe weitere Dateien direkt aus `develop` gelesen. Dabei ergeben sich mehrere wichtige Korrekturen.

| Bereich                       | Tatsächlicher Befund auf `develop`                                                                                             | Konsequenz                                                                                |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| Windows                       | Tauri-Version 0.4.6, NSIS-Installer konfiguriert, Content Security Policy vorhanden                                            | Nicht neu aufbauen, sondern vorhandene Windows-App testen und verbessern                  |
| Benutzerkonten                | `accounts.py` und `account_api.py` enthalten Registrierung, Anmeldung, Apple-/Google-Identitäten, Sitzungen und Passwort-Reset | Keine zweite Kontoverwaltung entwickeln                                                   |
| Community                     | Verschlüsselte Lösungspakete, Pseudonyme, Meldungen, Sperren und Moderation vorhanden                                          | Vorhandene Community erweitern                                                            |
| Apple-Pencil-Synchronisierung | Annotationsschema v2 enthält stabile Objekt-IDs und `pkdrawing-v2` mit Signaturen einzelner Striche                            | Strichweise Synchronisierung passt bereits zum Datenmodell                                |
| Hochschuldateien              | `filestream.py` bietet einen gehosteten Streamingmodus mit begrenztem Zwischenspeicher                                         | Cloudspeicherung ist eine Architekturentscheidung, kein vollständig fehlendes Dateisystem |
| Geräteübergreifende Anmeldung | Ein UniFlow-Konto für alle Geräte ist bereits ausdrücklich vorgesehen                                                          | Bestehende Authentifizierung weiterverwenden                                              |

Besonders interessant ist `pkdrawing-v2`: Hier wird nicht mehr nur eine vollständige Apple-Pencil-Zeichnung betrachtet. Das Format kann einzelne Striche anhand ihrer IDs und Signaturen unterscheiden. Das ist bereits eine wichtige Voraussetzung für die von dir gewünschte Synchronisierung pro Strich.

Aber: Ein strichfähiges Datenformat beweist noch nicht, dass jeder Netzwerk-Upload bereits ausschließlich die geänderten Striche überträgt. Das müssen wir gesondert am Synchronisierungsprotokoll prüfen.

## Die wichtigsten verbleibenden Lücken

Der aktuelle Stand ist deutlich weiter als meine ursprüngliche Einschätzung. Die folgenden Punkte verdienen jetzt die höchste Aufmerksamkeit:

P0

1\. Apple-Windows-Synchronisierung auf echten Geräten nachweisen

Der G2-Synchronisierungsvertrag, die Versionsverwaltung und die Zusammenführung sind dokumentiert. Offen ist der vollständige Nachweis, dass die aktuellen Windows- und Apple-Versionen unter realen Netzwerkunterbrechungen, gleichzeitiger Bearbeitung und App-Abstürzen zuverlässig zusammenarbeiten.

P0

2\. Strichweise Netzwerk-Synchronisierung prüfen

`annotations.schema.json` unterstützt stabile Strich-IDs und native Apple-Daten. Jetzt muss geprüft werden, ob die vorhandenen Endpunkte tatsächlich einzelne Strichoperationen übertragen oder weiterhin vollständige Seiten- beziehungsweise Dokumentzustände senden. Erst danach lässt sich ein sinnvoller Patch planen.

P1

3\. Hochschuldateien: Streaming oder dauerhafte Cloudablage

`develop` nutzt bereits einen Streamingmodus: Der Dienst speichert Dateimetadaten, Fingerabdrücke und Seitentext; Originaldateien werden bei Bedarf von der Hochschule abgerufen. Das spart Speicher, kann aber bei abgelaufenen Hochschulsitzungen den sofortigen Zugriff erschweren. Dein Wunsch nach Cloud-first würde eine bewusste Änderung dieser Architektur bedeuten.

P1

4\. Windows-Release und Installation absichern

Windows 0.4.6 besitzt bereits ein mitgeliefertes Backend, Installer-Konfiguration, Startprüfungen und lokale Backups. Laut Projektdokumentation fehlen noch Code-Signing, ein vollständiger Updater und Tests auf fremden Rechnern.

P1

5\. Öffentlichen Cloudbetrieb vorbereiten

E-Mail-Verifizierung, vollständiger Datenexport, verifizierte Store-Käufe, produktive Backups, Monitoring und belastbare Skalierungstests sind in der vorhandenen Dokumentation noch als offene Punkte beschrieben.

## Meine Empfehlung für den nächsten Entwicklungsschritt

Nicht sofort eine neue PostgreSQL-Architektur, Community oder Synchronisierungsengine bauen. `develop` hat dafür bereits umfangreiche Grundlagen.

Ich würde als Erstes die tatsächlichen Implementierungen von `GET /api/sync/changes`, `POST /api/sync/push`, dem Swift-Sync-Client, dem Windows-Editor und den gemeinsamen Merge-Tests vollständig gegeneinander prüfen. Danach gezielt entscheiden, ob die Übertragung pro Strich schon existiert oder ergänzt werden muss.

Bei den Hochschulfolien würde ich den vorhandenen Streamingmodus zunächst behalten und eine optionale, berechtigungsgeschützte Cloud-Dateiablage ergänzen – statt das funktionierende Importsystem zu ersetzen.

Fazit: UniFlow ist auf `develop` bereits eine erheblich fortgeschrittenere Anwendung. Die größte Aufgabe ist jetzt nicht, Hunderte neue Funktionen zu erfinden, sondern die bestehenden Komponenten zuverlässig zusammenzuführen, geräteübergreifend zu testen und die verbleibenden Release-Blocker zu schließen.


  auch vorallem kommuikation muss klappen zwischen windows luh und uni uni hildeswheim undbei apple auch und untereinander windows und luh bsp einer teilt seien lösung auf windows und luh student willdas öffne das muss klappen ohne probleme alles bzw das projezieren  uss klappen immer udn alles wietere we kommentare schreben zur lösung mit schöner ansicht überlge wie man das lösne kann und achso bau eine funktion ein man kann lösungen liken ich als chefkann sehen welcher nutzer die meisten likes bekommen hat .......weiter
UniFlow AI – 30 weitere Prüfpunkte (731–760)
Wir machen mit dem aktuellen develop-Branch weiter. Diesmal konzentrieren wir uns auf PDF-Editor, Apple Pencil, Windows-Stifteingabe, Offline-Nutzung und schnelle Synchronisierung.

Wichtig: Diese Punkte sind gezielte Prüf- und Verbesserungsaufträge, keine bereits bestätigten Fehler. Vor jeder Änderung muss die vorhandene Implementierung geprüft werden.

80. Apple Pencil und Windows Pen – identische Bearbeitung
Nr.

Prüfpunkt

Anforderung

731

Druckempfindlichkeit

Apple-Pencil-Druckdaten dürfen beim Öffnen auf Windows nicht verloren gehen.

732

Neigungswinkel

PencilKit-Neigungsinformationen müssen erhalten bleiben, auch wenn Windows sie nicht unterstützt.

733

Stiftgeschwindigkeit

Schnelle Striche müssen ohne sichtbare Unterbrechungen verarbeitet werden.

734

Handballenerkennung

Handflächen dürfen beim Schreiben keine unbeabsichtigten Striche erzeugen.

735

Stiftwechsel

Der Wechsel zwischen Kugelschreiber, Füller, Marker und Radierer muss korrekt gespeichert werden.

736

Strichfarben

Farben und Transparenzen müssen auf allen Geräten möglichst identisch dargestellt werden.

81. PDF-Editor – Stabilität und Bedienung
Nr.

Prüfpunkt

Anforderung

737

Unabhängiger Zoom

PDF und Notizbereich lassen sich getrennt vergrößern und verkleinern.

738

Scrollposition

Beim Wechsel zwischen Schreiben und Scrollen darf die Ansicht nicht springen.

739

Seitenrotation

Annotationen bleiben bei gedrehten PDF-Seiten an der richtigen Position.

740

Lasso-Auswahl

Mehrere Striche können ausgewählt, verschoben und skaliert werden.

741

Rückgängig/Wiederholen

Eigene Änderungen bleiben auch bei eingehenden Cloud-Updates korrekt rückgängig machbar.

742

Große Dokumente

Auch PDFs mit mehreren Hundert Seiten sollen ohne vollständiges Laden aller Seiten bedienbar bleiben.

82. Cloud-Synchronisierung – weitere Fehlerfälle
Nr.

Prüfpunkt

Anforderung

743

Synchronisierung während Schreiben

Neue Striche dürfen nicht blockiert werden, während ältere übertragen werden.

744

Upload-Abbruch

Ein unterbrochener Upload wird ohne doppelte Änderungen fortgesetzt.

745

Gleichzeitiger Seitenwechsel

Seitenoperationen dürfen nicht mit Strichoperationen verwechselt werden.

746

Unterschiedliche App-Versionen

Ältere Clients dürfen neue Dokumentformate nicht beschädigen.

747

Große Änderungswarteschlange

Tausende Offline-Operationen müssen in kontrollierten Paketen synchronisiert werden.

748

Konfliktwiederherstellung

Bei unauflösbaren Konflikten bleiben beide Bearbeitungsstände verfügbar.

83. Gerätewechsel und Offline-Nutzung
Nr.

Prüfpunkt

Anforderung

749

iPad zu Windows

Nach erfolgreichem Sync erscheinen alle bestätigten Änderungen auf Windows.

750

Windows zu iPad

Windows-Annotationen werden auf dem iPad korrekt angezeigt und bearbeitet.

751

Gerät ohne Internet

Bereits heruntergeladene Dokumente bleiben vollständig nutzbar.

752

App-Absturz

Lokal gespeicherte Änderungen werden nach Neustart wiederhergestellt.

753

Speicherplatz knapp

UniFlow warnt rechtzeitig und löscht keine ungesicherten Notizen.

754

Neues Gerät

Bibliothek und synchronisierte Notizen werden nach Anmeldung automatisch geladen.

84. Performance und Qualitätssicherung
Nr.

Prüfpunkt

Anforderung

755

Stiftlatenz

Zielwert für sichtbare Eingabeverzögerung definieren und auf echten Geräten messen.

756

PDF-Rendering

Seiten sollen beim Scrollen ohne unnötige vollständige Neuberechnung dargestellt werden.

757

Arbeitsspeicher

Große Dokumente und Zeichnungen dürfen keinen unkontrollierten Speicheranstieg verursachen.

758

Akkubelastung

Synchronisierung und PDF-Rendering müssen Hintergrundaktivität begrenzen.

759

Synchronisierungsgeschwindigkeit

Online-Änderungen sollen unter normalen Bedingungen innerhalb weniger Sekunden sichtbar sein.

760

Automatisierte Regressionstests

Alle kritischen Editor- und Synchronisierungsfälle müssen wiederholbar geprüft werden.

Master-Prompt 21 – Apple-/Windows-Editor vollständig prüfen
UniFlow AI – Cross-Platform Editor Audit 731–760
Repository: Ahmad271223/uniflow-ai

Ausgangsbranch: develop

Ziel
Prüfe und verbessere den vorhandenen PDF-Editor und die geräteübergreifende Synchronisierung zwischen Apple, Windows und Android.

Arbeite die Prüfpunkte 731–760 ab.

Verbindliche Regeln
Ermittle den neuesten Commit von develop.

Lies die tatsächlich vorhandenen Implementierungen.

Berücksichtige bestehende PencilKit-, PDFKit-, Web-Editor-, Kotlin- und G2-Synchronisierungskomponenten.

Entwickle keine zweite Editor- oder Synchronisierungsarchitektur.

Unterscheide bestätigte Fehler, fehlende Tests und Verbesserungswünsche.

Erhalte alle vorhandenen Funktionen.

Arbeite auf einem separaten Branch.

Erstelle Pull Requests ausschließlich gegen develop.

Prüfung A – Eingabe
Untersuche Apple Pencil, Windows Pen, Druckempfindlichkeit, Neigung, Strichidentität, Handballenerkennung und Radierer.

Prüfe, ob plattformspezifische Informationen beim Speichern und Synchronisieren erhalten bleiben.

Prüfung B – Dokumentdarstellung
Teste Zoom, Scrollen, Rotation, Seitenwechsel, Lasso, Undo/Redo und große PDFs.

Erstelle Tests für Koordinatentransformationen und unterschiedliche Displaygrößen.

Prüfung C – Synchronisierung
Prüfe:

Offline-Operationen

Wiederholte Uploads

Konflikte

App-Abstürze

Gleichzeitige Bearbeitung

Versionsunterschiede

Große Änderungswarteschlangen

Änderungen während laufender Uploads

Bestätigte Fehler mit möglichst kleinen, gezielten Änderungen beheben.

Prüfung D – Performance
Miss:

Stiftlatenz

Renderingzeiten

Arbeitsspeicher

Synchronisierungsverzögerung

Akkubelastung, soweit messbar

Dokumentiere Hardware, Betriebssystem, Testdaten und Messergebnisse.

Abschluss
Erstelle eine Matrix für 731–760 mit Status, Datei, Zeile, Testnachweis, Risiko und gegebenenfalls Fix.

Führe vorhandene Tests und neue Regressionstests aus.

Erstelle einen Draft-Pull-Request gegen develop.

Keine Änderungen direkt auf main oder develop, keine Veröffentlichung und keine produktiven Datenmigrationen.

Aktueller Planungsstand

760 Prüfpunkte
Nächste Runde 761–790: KI-Tutor, automatische Tests, Lernplanung, intelligente Dokumentanalyse und Kostenkontrolle bei vielen gleichzeitig aktiven Studenten.

weiter
UniFlow AI – 30 weitere Prüfpunkte (761–790)
Diesmal konzentrieren wir uns auf KI-Tutor, automatische Lernkontrollen, intelligente Lernplanung, Dokumentanalyse und KI-Kostenkontrolle.

Alle Anforderungen werden gegen den neuesten develop-Branch geprüft. Bereits vorhandene Funktionen sollen verbessert und nicht neu entwickelt werden.

85. KI-Tutor und intelligente Erklärungen
Nr.

Prüfpunkt

Anforderung

761

Kursbezogener KI-Tutor

Die KI verwendet bevorzugt Unterlagen aus dem ausgewählten Modul.

762

Quellenangaben

Jede dokumentgestützte Antwort verweist auf konkrete PDF-Seiten.

763

Schrittweise Erklärungen

Studenten können zwischen einfachen, ausführlichen und mathematischen Erklärungen wählen.

764

Keine erfundenen Inhalte

Die KI unterscheidet nachweisbare Aussagen von Vermutungen.

765

Kontext über mehrere Fragen

Die KI versteht Rückfragen, ohne Inhalte aus anderen Kursen zu vermischen.

766

Fehlererkennung

Die KI erkennt Rechenfehler und erklärt den ersten falschen Schritt.

86. Automatische KI-Tests
Nr.

Prüfpunkt

Anforderung

767

Wöchentliche Tests

Für ausgewählte Module können automatisch Wochentests erstellt werden.

768

Schwierigkeitsstufen

Leicht, mittel und schwer anhand definierter Kriterien.

769

Unterschiedliche Fragetypen

Multiple Choice, Freitext, Rechnen und Verständnisfragen.

770

Individuelle Fehleranalyse

Wiederkehrende Wissenslücken erkennen und passende Übungen empfehlen.

771

Testfortsetzung

Unterbrochene Tests werden ohne Verlust bisheriger Antworten fortgesetzt.

772

Geräteübergreifende Ergebnisse

Testergebnisse erscheinen nach Synchronisierung auf allen Geräten.

87. Intelligente Lernplanung
Nr.

Prüfpunkt

Anforderung

773

Prüfungsorientierter Lernplan

Prüfungsdatum, Themenumfang und verfügbare Lernzeit berücksichtigen.

774

Automatische Neuplanung

Nicht erledigte Aufgaben werden sinnvoll neu verteilt.

775

Lernschwächen priorisieren

Häufig falsch beantwortete Themen erhalten zusätzliche Übungszeit.

776

Realistische Tagesplanung

Lernzeit und Pausen berücksichtigen, Überplanung vermeiden.

777

Wiederholungsintervalle

Spaced Repetition mit nachvollziehbaren Regeln einsetzen.

778

Lernfortschritt

Fortschritt anhand bearbeiteter Inhalte und Testergebnisse darstellen.

88. Intelligente Dokumentanalyse
Nr.

Prüfpunkt

Anforderung

779

PDF-Texterkennung

Textbasierte PDFs auslesen und bei Scans optional OCR verwenden.

780

Kapitelstruktur

Überschriften und Themen automatisch erkennen.

781

Übung mit Skript verknüpfen

Zu einer Aufgabe passende Erklärungsseiten im Skript finden.

782

Formelerkennung

Mathematische Ausdrücke möglichst strukturiert erfassen.

783

Zusammenfassungen

Kurze und ausführliche Zusammenfassungen ausgewählter Seiten erstellen.

784

Neue Folien analysieren

Neue Dokumente nach dem Import für Suche und Lernplanung aufbereiten.

89. KI-Kosten, Datenschutz und Skalierung
Nr.

Prüfpunkt

Anforderung

785

Modell-Routing

Einfache Aufgaben an günstigere, geeignete Modelle weiterleiten.

786

Token-Kontrolle

Eingabe- und Ausgabelimits pro Anfrage definieren.

787

KI-Kosten pro Nutzer

Verbrauch pro Konto und Tarif erfassen.

788

Monatliche Kontingente

Free-, Plus- und Pro-Grenzen serverseitig und atomar durchsetzen.

789

Datenschutz

Dokumentinhalte nur für die angeforderte Funktion an berechtigte KI-Dienste senden.

790

KI-Lasttests

Gleichzeitige Testgenerierung, Warteschlangen und Kostenobergrenzen prüfen.

Master-Prompt 22 – KI und Lernsystem gegen develop prüfen
UniFlow AI – KI- und Lernsystem-Audit 761–790
Repository: Ahmad271223/uniflow-ai
Basisbranch: develop

Ziel
Prüfe und verbessere die vorhandenen KI-, Lernplanungs-, Dokumentanalyse- und Testfunktionen.

Arbeite die Prüfpunkte 761–790 vollständig ab.

Vorgehensweise
Ermittle den aktuellen HEAD von develop.

Prüfe app/ai.py, app/ai_backend.py, bestehende KI-APIs, Lernplanungsdienste, Dokumentindizierung, Tests und Apple-/Windows-/Android-Clients.

Erstelle eine Bestandsmatrix: vorhanden, teilweise vorhanden, fehlt, Fehler bestätigt oder nicht verifizierbar.

Erhalte bestehende Funktionen und Datenformate.

Behebe nachgewiesene Fehler mit kleinen Änderungen.

Ergänze fehlende Regressionstests.

Arbeite ausschließlich auf einem Feature-Branch mit Draft-PR gegen develop.

A – KI-Tutor
Prüfe Kursisolation, Dokumentquellen, Seitenverweise, Kontextverwaltung, Rechenaufgaben und Fehlererklärungen.

Verhindere, dass unbelegte Antworten als dokumentgestützte Tatsachen ausgegeben werden.

B – KI-Tests
Prüfe Testgenerierung, Fragetypen, Schwierigkeitsgrade, Antwortauswertung, Wiederaufnahme, Speicherung und Synchronisierung.

C – Lernplanung
Prüfe automatische Neuplanung, Prüfungstermine, Lernzeit, Wiederholungsintervalle und Fortschrittsberechnung.

D – Dokumentanalyse
Prüfe PDF-Textextraktion, Kapitelzuordnung, Übungs-Skript-Verknüpfung, mathematische Formeln und Dokumentaktualisierungen.

E – Kosten und Sicherheit
Prüfe Tarifkontingente, gleichzeitige Anfragen, Tokenlimits, Modellkosten, sensible Dokumentinhalte und API-Fehlerbehandlung.

Führe keine echten kostenpflichtigen KI-Anfragen ohne ausdrückliche Freigabe aus. Verwende für Tests Mock-Provider und festgelegte Testdaten.

Abschluss
Liefere für jeden Punkt 761–790:

Status

Fundstelle im Code

Vorhandene Tests

Fehlende Tests

Bestätigte Fehler

Kleinste sichere Verbesserung

Priorität

Führe alle relevanten Tests aus und dokumentiere die Ergebnisse.

Erstelle einen Draft-Pull-Request gegen develop, falls tatsächliche Codeänderungen erforderlich sind.

Keine Änderungen direkt an main oder develop.

Gesamtplanung

790 Prüfpunkte
Nächste Runde 791–820: Lernkalender, Stundenplan, Prüfungstermine, automatische Stud.IP-Aktualisierung, Benachrichtigungen und intelligente Semesterorganisation.

weiter
UniFlow AI – 30 weitere Prüfpunkte (791–820)
Schwerpunkt: Lernkalender, Stundenplan, Prüfungen, Stud.IP-Synchronisierung und Benachrichtigungen.

Alle Punkte müssen mit dem aktuellen develop-Branch verglichen werden. Bereits vorhandene Funktionen sollen verbessert, nicht neu entwickelt werden.

90. Intelligenter Lernkalender
Nr.

Prüfpunkt

Anforderung

791

Automatische Lernplanung

Lernaufgaben nach Prüfungsdatum und verfügbarer Zeit einplanen

792

Kalenderansichten

Tages- und Wochenansicht auf iPad, Windows und Android

793

Drag-and-drop

Lernblöcke verschieben, ohne Modulzuordnung zu verlieren

794

Überfällige Aufgaben

Deutlich markieren und Neuplanung anbieten

795

Lernzeitbegrenzung

Maximale Lernstunden pro Tag festlegen

796

Priorisierung

Prüfungsnähe, Schwierigkeit und Lernrückstand berücksichtigen

91. Stundenplan und Hochschultermine
Nr.

Prüfpunkt

Anforderung

797

Stud.IP-Stundenplan

Vorlesungen und Übungen korrekt Modulen zuordnen

798

Raumänderungen

Geänderte Räume und Zeiten erkennen

799

Veranstaltungsausfälle

Abgesagte Termine kennzeichnen

800

Hochschultrennung

LUH und Hildesheim getrennt verwalten

801

Eigene Termine

Private Termine und Lernblöcke ergänzen

802

ICS-Export

Stundenplan als Kalenderdatei exportieren

92. Prüfungen und Semesterorganisation
Nr.

Prüfpunkt

Anforderung

803

Prüfungstermine

Automatisch übernehmen oder manuell eintragen

804

Countdown

Verbleibende Tage im Dashboard anzeigen

805

Anmeldefristen

Getrennt von Prüfungsterminen speichern

806

Semesterübersicht

Module, Leistungen, Prüfungen und Aufgaben bündeln

807

ECTS-Fortschritt

Erworbene und geplante Leistungspunkte unterscheiden

808

Semesterarchiv

Alte Dokumente und Notizen zugänglich halten

93. Automatische Hochschul-Synchronisierung
Nr.

Prüfpunkt

Anforderung

809

Regelmäßiger Abgleich

Hochschulsysteme nach konfigurierbarem Zeitplan prüfen

810

Neue Dateien

Skripte und Übungsblätter automatisch erkennen

811

Geänderte Dateien

PDF-Aktualisierungen ohne Verlust vorhandener Notizen behandeln

812

Ankündigungen

Neue Hochschulmeldungen im Dashboard anzeigen

813

Sitzungsablauf

Erneute Anmeldung verständlich anfordern

814

Sync-Protokoll

Zeitpunkt, Ergebnis und Fehler anzeigen

94. Benachrichtigungen
Nr.

Prüfpunkt

Anforderung

815

Neue Unterlagen

Optionale Benachrichtigung bei neuen Dateien

816

Prüfungserinnerungen

Einstellbare Hinweise vor Prüfungen und Anmeldefristen

817

Lernerinnerungen

Lokale Hinweise für geplante Lernblöcke

818

Ruhezeiten

Benachrichtigungen zu festgelegten Zeiten unterdrücken

819

Geräteübergreifende Erledigung

Erledigte Aufgaben überall als abgeschlossen anzeigen

820

Mitteilungsübersicht

Neue, gelesene und erledigte Hinweise zentral verwalten

Master-Prompt 23 – Prüfung gegen develop
UniFlow AI – Kalender- und Hochschul-Audit 791–820
Repository: Ahmad271223/uniflow-ai
Basisbranch: develop

Auftrag
Prüfe die Anforderungen 791–820 anhand des neuesten develop-Commits.

Regeln
Vorhandenen Code und Tests zuerst untersuchen.

Bestätigte Fehler, fehlende Funktionen und ungeprüfte Anforderungen unterscheiden.

Bestehende Datenmodelle und Synchronisierung weiterverwenden.

Keine parallelen Datenbanken oder Kalenderdienste erstellen.

Nur auf separatem Feature-Branch arbeiten; main und develop nicht direkt ändern.

Prüfbereiche
Lernkalender: Automatische Planung, Drag-and-drop, überfällige Aufgaben, Lernzeitgrenzen, Priorisierung, Zeitzonen, Sommerzeit und gleichzeitige Bearbeitung.

Stundenplan: Hochschulimport, Modulzuordnung, Raumänderungen, Ausfälle, eigene Termine und ICS-Export. Hochschultermine nur bei sicherer Zuordnung ändern.

Prüfungen: Termine, Anmeldefristen, Countdown, ECTS und Semesterarchiv. Hochschuldaten von manuellen Einträgen unterscheiden.

Hochschulabgleich: Neue und geänderte Dateien, Ankündigungen, Sitzungsablauf, Fehlerbehandlung und Protokolle. Automatisierte Tests nur mit Testdaten und Mock-Diensten, niemals echten Hochschulzugangsdaten.

Benachrichtigungen: Erinnerungen, Ruhezeiten, Duplikate, geräteübergreifende Erledigung und Mitteilungsübersicht.

Ergebnis
Erstelle für jeden Punkt 791–820:

Status und Fundstelle

Vorhandene und fehlende Tests

Risiko und Priorität

Kleinste sichere Verbesserung

Behebe bestätigte kritische Fehler mit Regressionstests.

Falls Codeänderungen nötig sind, erstelle einen Draft-PR gegen develop. Nicht ausführbare Geräte- und Integrationstests ausdrücklich dokumentieren.

Gesamtplanung

820 Prüfpunkte
Nächster Bereich 821–850: Community, gemeinsames Lernen, handschriftliche Lösungen, Moderation, Datenschutz und Zusammenarbeit.

weiter
UniFlow AI – 30 weitere Prüfpunkte (821–850)
Schwerpunkt: Community, gemeinsames Lernen, handschriftliche Lösungen, Moderation, Datenschutz und Zusammenarbeit.

Grundlage bleibt der aktuelle develop-Branch. Die vorhandene Community mit verschlüsselten Lösungspaketen, PDF-Fingerabdrücken, Pseudonymen und Moderation wird erweitert – nicht ersetzt.

95. Community und Lösungsaustausch
Nr.

Prüfpunkt

Anforderung

821

Lösungen zuordnen

Geteilte Lösungen erscheinen ausschließlich beim passenden PDF-Fingerabdruck

822

Handschrift teilen

Nur ausgewählte eigene Striche und Annotationen veröffentlichen

823

Original-PDF schützen

Hochschulfolien dürfen nicht versehentlich mitveröffentlicht werden

824

Vorschau

Vor Veröffentlichung exakt anzeigen, welche Inhalte geteilt werden

825

Lösungen zurückziehen

Eigene Veröffentlichungen jederzeit entfernen

826

Versionswechsel

Bei geänderten Hochschul-PDFs keine falschen Lösungen zuordnen

96. Gemeinsames Lernen
Nr.

Prüfpunkt

Anforderung

827

Lerngruppen

Private Lerngruppen pro Modul ermöglichen

828

Einladungen

Gruppenbeitritt über zeitlich begrenzte Einladungen

829

Gemeinsame Aufgaben

Lernaufgaben innerhalb einer Gruppe verteilen

830

Lernfortschritt

Mitglieder entscheiden selbst, welche Fortschritte sichtbar sind

831

Gemeinsame Notizen

Freigegebene Notizen mit getrennten Bearbeitungsrechten

832

Gruppen verlassen

Zugriffsrechte nach Austritt zuverlässig entziehen

97. Qualität der Community
Nr.

Prüfpunkt

Anforderung

833

Lösungsbewertungen

Hilfreiche Lösungen positiv bewerten, Missbrauch begrenzen

834

Fehler melden

Fachlich falsche oder problematische Lösungen melden

835

Lösungsvarianten

Mehrere Lösungswege zur gleichen Aufgabe unterstützen

836

Qualitätskennzeichnung

Zwischen ungeprüften und fachlich geprüften Lösungen unterscheiden

837

Duplikate erkennen

Identische Lösungspakete nicht unnötig mehrfach speichern

838

Aktualisierte Lösungen

Autoren können korrigierte Versionen veröffentlichen

98. Datenschutz und Moderation
Nr.

Prüfpunkt

Anforderung

839

Anonyme Veröffentlichung

Pseudonyme statt Klarnamen verwenden

840

Persönliche Informationen

Vor dem Teilen auf mögliche Namen, Matrikelnummern und andere sensible Inhalte hinweisen

841

Nutzer blockieren

Inhalte blockierter Autoren zuverlässig ausblenden

842

Meldungen bearbeiten

Moderatoren können gemeldete Inhalte prüfen und Entscheidungen dokumentieren

843

Missbrauchsschutz

Veröffentlichungs- und Melderaten begrenzen

844

Datenlöschung

Beim Löschen eines Kontos Veröffentlichungen und personenbezogene Daten korrekt behandeln

99. Zusammenarbeit zwischen Geräten
Nr.

Prüfpunkt

Anforderung

845

Gruppen-Synchronisierung

Mitgliedschaften und Berechtigungen erscheinen auf allen Geräten

846

Offline-Gruppenarbeit

Eigene Änderungen offline vormerken, Berechtigungen beim Upload erneut prüfen

847

Gleichzeitige Bearbeitung

Konflikte bei freigegebenen Notizen ohne stillen Datenverlust behandeln

848

Benachrichtigungen

Neue Gruppenaufgaben und freigegebene Lösungen optional melden

849

Zugriff widerrufen

Entfernte Mitglieder verlieren auch über alte Links ihren Serverzugriff

850

Community-Lasttest

Veröffentlichungen, Downloads und Moderation unter paralleler Nutzung prüfen

Wichtige Architekturentscheidung
Die bestehende Community arbeitet mit verschlüsselten Lösungspaketen. Deshalb können wir nicht einfach voraussetzen, dass der Server deren handschriftlichen Inhalt analysieren, vergleichen oder fachlich bewerten kann.

Für die neuen Funktionen müssen wir sauber unterscheiden:

Serverseitig möglich: Fingerabdruck-Zuordnung, Berechtigungen, Bewertungen, Meldungen, Downloadzahlen und Paketgrößen.

Auf dem Gerät möglich: Vorschau, Auswahl eigener Striche, Erkennung möglicher persönlicher Informationen und Zusammenführung mit der eigenen PDF.

Nur mit zusätzlicher Freigabe möglich: Inhaltsanalyse durch einen KI-Dienst oder fachliche Prüfung durch andere Personen.

So bleibt das bisherige Datenschutzkonzept erhalten.

Master-Prompt 24 – Community-Audit 821–850
UniFlow AI – Community und Collaboration Audit 821–850
Repository: Ahmad271223/uniflow-ai
Basisbranch: develop

Ziel
Prüfe die Anforderungen 821–850 gegen die tatsächlich vorhandene Community-Implementierung und erweitere sie nur dort, wo nachweislich Funktionen fehlen.

Regeln
Aktuellen develop-HEAD ermitteln.

app/community.py, app/community_api.py, vorhandene Community-Clients, Berechtigungen, Tests und Dokumentation prüfen.

Die bestehende verschlüsselte Lösungspaket-Architektur beibehalten.

Keine zweite Community-Datenbank oder parallele Community-API entwickeln.

Bestehende Pseudonyme, PDF-Fingerabdrücke, Meldeverfahren und Moderation weiterverwenden.

Neue Gruppen- und Kollaborationsfunktionen als getrennte, kompatible Erweiterung planen.

Keine echten Nutzerdaten oder Hochschuldokumente in Tests verwenden.

A – Lösungsaustausch
Prüfe Paketvalidierung, PDF-Zuordnung, Veröffentlichung, Rücknahme, Berechtigungen, Versionswechsel und die Vorschau vor dem Teilen.

B – Zusammenarbeit
Prüfe die Möglichkeit, private Lerngruppen, Mitgliedschaften, Einladungen und freigegebene Aufgaben in die vorhandene Konten- und Synchronisierungsarchitektur zu integrieren.

C – Sicherheit
Untersuche:

Zugriff nach Gruppenaustritt

Missbrauch von Einladungslinks

Manipulierte Paketmetadaten

Übermäßig große Uploads

Wiederholte Veröffentlichungen

Unberechtigte Moderationsaktionen

Kontolöschung und Datenaufbewahrung

D – Verschlüsselung
Verhindere, dass neue Funktionen unbemerkt die bestehende Verschlüsselung umgehen.

Inhaltsanalysen dürfen nicht als serverseitig verfügbar behandelt werden, wenn der Server nur verschlüsselte Pakete besitzt.

E – Tests
Erstelle gezielte Regressionstests für Berechtigungen, Gruppenisolation, parallele Änderungen, Rücknahmen und Löschvorgänge.

Ergebnis
Liefere eine Matrix für alle Punkte 821–850 mit:

Status

Codefundstelle

Vorhandenen Tests

Fehlenden Tests

Sicherheitsrisiko

Priorität

Kleinster sicherer Verbesserung

Bestätigte kritische Fehler auf separatem Branch beheben und einen Draft-PR gegen develop erstellen.

Neue größere Produktfunktionen nicht ohne klare Abgrenzung in bestehende Community-Endpunkte hineinbauen.

Keine Änderungen direkt an main oder develop.

Gesamtplanung

850 Prüfpunkte
Nächste Runde 851–880: Abonnements, App Store, Microsoft Store, Google Play, Zahlungen, Berechtigungen und Umsatzsicherheit.

weiter ja und auch tiefer danach wieder
UniFlow AI – 30 weitere Prüfpunkte (851–880)
Schwerpunkt: Abonnements, Apple App Store, Google Play, Microsoft Store, Zahlungsabwicklung und Sicherheit.

Diesmal gehen wir bereits etwas tiefer: Nicht nur prüfen, ob ein Abo funktioniert, sondern auch, was bei Rückerstattungen, gleichzeitigen Anfragen, Gerätewechseln, Betrugsversuchen und Ausfällen passiert.

100. Abonnements und Tarifverwaltung
Nr.

Prüfpunkt

Technische Anforderung

851

Zentrale Tarifberechtigung

Ein Serverdienst entscheidet verbindlich, welche Funktionen ein Konto nutzen darf.

852

Plattformübergreifende Abos

Ein gültiges Abo wird nach Kontoverknüpfung auf Windows, iPad und Android erkannt, soweit Store-Regeln dies erlauben.

853

Tarifwechsel

Upgrade und Downgrade berücksichtigen den tatsächlichen Wirksamkeitszeitpunkt.

854

Abo-Kündigung

Nach Kündigung bleiben Leistungen bis zum Ende des bezahlten Zeitraums verfügbar.

855

Zahlungsfehler

Grace Period, Billing Retry und endgültiger Ablauf werden unterschieden.

856

Abo-Wiederherstellung

Nach Neuinstallation können vorhandene Käufe wiederhergestellt werden.

101. Apple App Store und StoreKit
Nr.

Prüfpunkt

Technische Anforderung

857

StoreKit 2

Kaufstatus und signierte Transaktionen werden korrekt verarbeitet.

858

Apple Server Notifications

Doppelte, verspätete und ungeordnete Ereignisse verursachen keine falschen Berechtigungen.

859

Transaktionsprüfung

Kaufnachweise werden serverseitig anhand vertrauenswürdiger Apple-Daten geprüft.

860

Rückerstattungen

Widerrufene Transaktionen entziehen betroffene Berechtigungen entsprechend ihrem Status.

861

Apple-ID-Wechsel

Ein fremder Kauf darf nicht automatisch einem anderen UniFlow-Konto zugeordnet werden.

862

Sandbox-Tests

Kauf, Verlängerung, Ablauf, Kündigung und Rückerstattung werden getestet.

102. Google Play und Android-Abonnements
Nr.

Prüfpunkt

Technische Anforderung

863

Play Billing

Aktuelle unterstützte Billing-Bibliothek und korrekter Kaufablauf.

864

Purchase Token

Jeder Kaufnachweis wird serverseitig überprüft und eindeutig zugeordnet.

865

Kaufbestätigung

Käufe werden rechtzeitig bestätigt, damit sie nicht unbeabsichtigt erstattet werden.

866

Play-Benachrichtigungen

Echtzeitbenachrichtigungen und regelmäßige Statusabgleiche ergänzen sich.

867

Pausierte Abos

Pausierte, ausgesetzte und abgelaufene Abos werden korrekt unterschieden.

868

Android-Gerätewechsel

Bestehende Berechtigungen werden nach Anmeldung wiederhergestellt.

103. Windows und direkte Zahlungen
Nr.

Prüfpunkt

Technische Anforderung

869

Windows-Vertriebskanal

Store-Version und Direktinstaller erhalten passende Zahlungsabläufe.

870

Zahlungsanbieter

Bei direkter Abrechnung werden signierte Webhooks geprüft.

871

Doppelbuchungen

Wiederholte Zahlungsereignisse dürfen keine doppelten Abos erzeugen.

872

Zahlungsrückbuchung

Chargebacks werden berücksichtigt und nachvollziehbar dokumentiert.

873

Rechnungen

Rechnungs- und Steuerdaten werden korrekt vom Zahlungsanbieter übernommen oder erstellt.

874

Zahlungsdaten

Keine vollständigen Kartendaten oder Zahlungsgeheimnisse in UniFlow speichern.

104. Sicherheit und Wirtschaftlichkeit
Nr.

Prüfpunkt

Technische Anforderung

875

KI-Kontingente

Testkontingente werden atomar reserviert, verbraucht oder bei Fehler freigegeben.

876

Gleichzeitige Geräte

Parallele Anfragen dürfen das monatliche Kontingent nicht überschreiten.

877

Tarifmanipulation

Clientseitige Änderungen am Tarif dürfen keine kostenpflichtigen Funktionen freischalten.

878

Zahlungsprovider-Ausfall

Ein temporärer Ausfall führt nicht automatisch zum Verlust gültiger Abos.

879

Kostenüberwachung

KI-Ausgaben, Einnahmen und Missbrauchsindikatoren werden nachvollziehbar erfasst.

880

Vollständiger Abrechnungstest

Kauf bis Ablauf einschließlich Gerätewechsel und Rückerstattung als End-to-End-Szenario prüfen.

Tieferer technischer Blick: So sollte die Abo-Architektur funktionieren

Empfohlene Zielarchitektur – keine Behauptung, dass alle Komponenten bereits implementiert sind.
Ein entscheidender Testfall: Ein Student kauft Plus auf dem iPad, meldet sich auf Windows an und startet gleichzeitig auf beiden Geräten KI-Tests. Der Server muss dieselbe Berechtigung erkennen und verhindern, dass das monatliche Kontingent doppelt ausgegeben wird.

Master-Prompt 25 – Tiefenaudit Abonnements
UniFlow AI – Deep Billing & Entitlements Audit 851–880
Repository: Ahmad271223/uniflow-ai
Basisbranch: develop

Ziel
Prüfe das gesamte Abrechnungssystem vom Kauf bis zur endgültigen Beendigung eines Abonnements.

1. Bestandsaufnahme
Untersuche den neuesten develop-HEAD.

Finde alle Implementierungen für:

Tarife und Berechtigungen

KI-Kontingente

Apple StoreKit

Google Play Billing

Windows-Zahlungen

Zahlungs-Webhooks

Abo-Datenbank

Rückerstattungen

Kontoverknüpfung

Unterscheide implementiert, teilweise implementiert, fehlend und nicht testbar.

2. Sicherheitsanalyse
Teste gezielt:

Gefälschte Kaufnachweise

Wiederholte Webhooks

Ungeordnete Ereignisse

Parallele KI-Anfragen

Abgelaufene Abonnements

Fremde Kauftransaktionen

Kontowechsel

Rückerstattungen

Provider-Ausfälle

Prüfe insbesondere, ob alle kostenpflichtigen Backend-Endpunkte serverseitige Berechtigungen kontrollieren.

3. Datenmodell
Bewerte, ob folgende Informationen eindeutig abgebildet werden:

Nutzerkonto

Zahlungsanbieter

Externe Transaktions-ID

Produkt-ID

Abo-Status

Beginn und Ende der Berechtigung

Letzte erfolgreiche Prüfung

Eindeutiger Ereignisschlüssel

Vermeide doppelte Abonnements und widersprüchliche Statusübergänge.

4. KI-Kontingente
Prüfe atomare Reservierung und Abrechnung.

Simuliere 50 gleichzeitige Anfragen eines Kontos mit nur einem verbleibenden KI-Test.

Erwartung: Höchstens eine Anfrage erhält die Berechtigung, diesen letzten Test zu verbrauchen.

5. Tests
Erstelle reproduzierbare Tests mit Mock-Providern.

Führe keine echten Käufe, Rückerstattungen oder kostenpflichtigen API-Aufrufe ohne Freigabe aus.

6. Ergebnis
Erstelle eine Tabelle für alle Anforderungen 851–880 mit Codefundstelle, Status, Testnachweis, Risiko und Priorität.

Behebe bestätigte kritische Fehler auf einem separaten Branch.

Erstelle einen Draft-PR gegen develop, nicht gegen main.

Keine produktiven Zahlungsdaten verändern.

Gesamtplanung

880 Prüfpunkte
Ab jetzt gehen wir noch tiefer: Die nächsten 30 Punkte (881–910) behandeln Backend-Sicherheit, Datenbanktransaktionen, Mandantentrennung, Angriffe auf APIs, Backup-Konsistenz und Wiederherstellung – einschließlich konkreter Angriffsszenarien und Testbedingungen.

erstmal android außen vor lassen es kann nur windows und apple also ipad mac geben android kommt dazu in der späteren version
Verstanden. Für UniFlow AI konzentrieren wir uns ab jetzt ausschließlich auf Windows, iPad und Mac. Android kommt erst in einer späteren Version.

Neue Plattformstrategie
Plattform

Priorität

Status

 Windows

P0

Aktive Entwicklung und vollständige Tests

 iPadOS

P0

Aktive Entwicklung, Apple Pencil und PDF-Editor

 macOS

P0

Aktive Entwicklung und vollständige Tests

Android

Spätere Version

Keine neuen Funktionen oder Release-Blocker

Das gilt auch rückwirkend für die bisherigen 880 Prüfpunkte. Android-spezifische Anforderungen werden zurückgestellt und nicht als Fehler oder fehlende Funktionen der ersten Veröffentlichung gewertet.

Wir achten aber darauf, dass die gemeinsame Backend- und Synchronisierungsarchitektur später Android unterstützen kann, ohne alles umbauen zu müssen.

Für die nächsten 30 Punkte (881–910) gehen wir tiefer in Backend-Sicherheit, Datenbanken, Kontentrennung, Cloud-Synchronisierung und Wiederherstellung – ausschließlich für Windows, iPad und Mac.

Die vorhandene Android-Implementierung bleibt unangetastet. Wir löschen sie nicht und investieren vorerst keine zusätzliche Entwicklungszeit hinein.


UniFlow AI – 30 weitere Prüfpunkte (881–910)
Schwerpunkt: Backend-Sicherheit, Datenbank, Cloud-Synchronisierung, Datenschutz und Wiederherstellung.

Ab jetzt gehen wir technisch tiefer. Jeder Punkt bekommt eine konkrete Fehlerkonstellation und eine überprüfbare Erwartung.
Windows
iPadOS
macOS

Android bleibt für die spätere Version zurückgestellt. Die folgenden Punkte sind neue Prüfanweisungen, keine bereits bestätigten Sicherheitslücken.
105. Kontensicherheit und Datenisolation
Nr.	Prüfpunkt	Konkreter Test und erwartetes Ergebnis
881	Fremde Dokument-IDs	Benutzer A fordert mit gültiger Sitzung die Dokument-ID von B an. Ergebnis: Zugriff verweigert, keine Metadaten preisgegeben.
882	Fremde Annotationen	Benutzer A sendet Annotationen für eine PDF von B. Ergebnis: Server lehnt Änderung ab, ohne B-Daten zu verändern.
883	Hochschul-Mandantentrennung	Identische Kurs-IDs zweier Hochschulen dürfen niemals vermischt werden.
884	Sitzungswiderruf	Eine auf dem Mac widerrufene Windows-Sitzung darf danach keine neuen Serveroperationen ausführen.
885	Kontowechsel am Gerät	Nach Abmeldung von A und Anmeldung von B dürfen keine lokalen A-Daten angezeigt oder hochgeladen werden.
886	Verknüpfte Apple-Konten	Ein Apple-Login darf nur nach sicherer Prüfung mit einem bestehenden UniFlow-Konto verbunden werden.

106. Datenbanktransaktionen und Integrität
Nr.	Prüfpunkt	Konkreter Test und erwartetes Ergebnis
887	Atomare Änderungen	Stürzt der Server während einer Änderung ab, wird sie vollständig übernommen oder vollständig zurückgerollt.
888	Doppelte Sync-Operation	Dieselbe Operation wird zehnmal gesendet. Ergebnis: Genau eine fachliche Änderung.
889	Gleichzeitige Schreibzugriffe	Windows und iPad ändern dieselbe Notiz gleichzeitig. Keine stillschweigende Überschreibung.
890	Revisionskonflikte	Veraltete Versionsnummern werden erkannt und kontrolliert zusammengeführt oder zurückgewiesen.
891	Tombstones	Gelöschte Striche, Notizen und Aufgaben dürfen nach einem späteren Offline-Sync nicht wieder auftauchen.
892	Datenbankmigration	Eine Migration erhält Konten, Dokumentzuordnungen, Annotationen und Änderungsverlauf.

107. API-Sicherheit und Angriffsszenarien
Nr.	Prüfpunkt	Konkreter Test und erwartetes Ergebnis
893	Manipulierte API-Anfragen	Zusätzliche Felder wie is_admin oder plan=pro dürfen keine Rechte verändern.
894	Replay-Angriffe	Alte Änderungs- oder Zahlungsereignisse dürfen keine unberechtigten neuen Aktionen auslösen.
895	Rate-Limiting	Tausende Login- oder KI-Anfragen eines Kontos werden begrenzt, ohne andere Nutzer unnötig zu blockieren.
896	Upload-Manipulation	Ungültige PDF-, JSON- und Annotation-Dateien werden sicher abgelehnt.
897	Größenlimits	Übergroße Anfragen dürfen nicht den gesamten Arbeitsspeicher des Servers belegen.
898	Fehlerausgaben	API-Fehler dürfen keine Sitzungstoken, Datenbankpfade, Zugangsdaten oder internen Geheimnisse enthalten.

108. Cloud-Synchronisierung unter Extrembedingungen
Nr.	Prüfpunkt	Konkreter Test und erwartetes Ergebnis
899	10.000 Offline-Striche	Das iPad erstellt 10.000 Striche ohne Internet. Nach dem Abgleich sind alle eindeutig und korrekt gespeichert.
900	Abbruch nach Serverbestätigung	Server speichert eine Änderung, aber die Antwort geht verloren. Wiederholung erzeugt keine Duplikate.
901	Geräteuhr falsch	Eine um zwei Stunden verstellte Windows-Uhr darf die Konfliktlösung nicht beschädigen.
902	Reihenfolge vertauscht	Operationen kommen ungeordnet an. Abhängigkeiten werden korrekt berücksichtigt.
903	Drei Geräte gleichzeitig	iPad, Mac und Windows bearbeiten ein Dokument. Alle bestätigten Änderungen bleiben erhalten.
904	Veralteter Client	Ein älterer Windows-Client darf neue Apple-Annotationsformate nicht zerstören.

109. Backups, Wiederherstellung und Betrieb
Nr.	Prüfpunkt	Konkreter Test und erwartetes Ergebnis
905	Konsistentes Backup	Datenbank und benötigte Dateimetadaten werden in einem zusammenpassenden Zustand gesichert.
906	Vollständige Wiederherstellung	Testumgebung aus Backup aufbauen und Konten, Kurse, Notizen sowie Berechtigungen überprüfen.
907	Defektes Backup	Beschädigte Sicherungen werden erkannt und nicht als erfolgreich wiederherstellbar gemeldet.
908	Verlorenes Gerät	Nach Geräteverlust können Sitzungen widerrufen und synchronisierte Daten auf einem neuen Gerät geladen werden.
909	Serverausfall	Lokales Schreiben bleibt möglich; nach Wiederverbindung erfolgt kontrollierter Abgleich.
910	Notfall-Wiederherstellung	Dokumentierte Wiederanlaufzeiten, Datenverlustgrenzen und ein tatsächlich getesteter Wiederherstellungsablauf.


Technische Vertiefung: Drei besonders kritische Tests

Test A – Konten dürfen sich niemals vermischen

Zwei Testkonten mit ähnlichen Kurs-IDs, aber unterschiedlichen Dokumenten erstellen. Anschließend IDs und Hochschulzuordnungen in API-Anfragen gezielt austauschen. Jeder unberechtigte Lese- und Schreibzugriff muss abgewiesen werden.




Test B – Gleichzeitiges Schreiben auf drei Geräten

Windows erstellt 50 Striche, iPad erstellt 70 weitere, Mac löscht 10 bereits bekannte Striche. Nach vollständigem Abgleich muss auf allen Geräten derselbe korrekte Dokumentzustand entstehen. Unbekannte PencilKit-Daten müssen erhalten bleiben.




Test C – Kompletter Serververlust

Eine isolierte Testumgebung mit realistischen Testkonten, Kursen und Annotationen aufbauen, sichern und aus der Sicherung wiederherstellen. Danach Integrität, Berechtigungen und Synchronisierung überprüfen. Ein vorhandenes Backup allein gilt nicht als bestandener Test.



Master-Prompt 26 – Tiefenaudit Backend und Synchronisierung
UniFlow AI – Deep Backend, Security & Recovery Audit 881–910
Repository: Ahmad271223/uniflow-ai
Ausgangsbranch: develop
Plattformumfang
Aktiver Release:
- Windows
- iPadOS
- macOS
Android ausdrücklich zurückstellen. Vorhandenen Android-Code nicht löschen oder absichtlich beschädigen.
Ziel
Prüfe 881–910 anhand des tatsächlichen neuesten develop-Commits.

Identifiziere bestätigte Sicherheitsfehler, Datenverlustrisiken, Synchronisierungsprobleme und Wiederherstellungslücken.
Phase 1 – Codeinventur
Ermittle den aktuellen develop-HEAD und prüfe:
- Konto- und Session-Implementierung
- Autorisierung sämtlicher Datenendpunkte
- Hochschul- und Benutzerisolation
- SQLite-Transaktionen und Migrationen
- G2-Synchronisierung und Revisionsmodell
- PencilKit-/Annotations-Verträge
- Windows- und Apple-Sync-Clients
- Backup- und Wiederherstellungsverfahren
- Bestehende Regressionstests
Verlasse dich nicht allein auf ältere Statusdokumente.
Phase 2 – Sicherheitsprüfung
Erstelle automatisierte Negativtests für:
1. IDOR/BOLA durch fremde Dokument-IDs.
2. Unberechtigte Schreiboperationen.
3. Kontowechsel mit vorhandenen lokalen Caches.
4. Manipulierte Rollen- und Tarifparameter.
5. Ungültige Sitzungen und widerrufene Tokens.
6. Übergroße und fehlerhafte Anfragen.
7. Wiederholte und ungeordnete Sync-Operationen.
Alle Tests ausschließlich mit lokalen oder isolierten Testdaten durchführen.
Phase 3 – Synchronisierungsprüfung
Teste die tatsächlichen Endpunkte und Datenformate.

Simuliere:
- Offline-Erstellung von 10.000 Strichen
- Parallele Bearbeitung auf drei Clients
- Netzwerkabbruch vor und nach Commit
- Wiederholung identischer Operationen
- Veraltete Revisionen
- Löschen und Wiederherstellen
- Falsche Gerätezeit
- Unbekannte PencilKit-Daten
Beweise anhand von Tests, ob die Implementierung tatsächlich operationenweise synchronisiert oder vollständige Dokumentzustände überträgt.

Bei Konflikten dürfen keine bestätigten Änderungen stillschweigend verloren gehen.
Phase 4 – Datenbank und Backup
Prüfe Transaktionsgrenzen, WAL-Verhalten, Migrationen, Backup-Konsistenz und Wiederherstellung.

Erstelle einen Restore-Test in einer isolierten Umgebung.

Keine produktiven Datenbanken verändern.
Phase 5 – Fehlerbehebung
Behebe bestätigte P0-Probleme zuerst.

Für jede Änderung:
- Minimaler Patch
- Regressionstest
- Keine neue Parallelarchitektur
- Keine unnötige Datenmigration
- Rückwärtskompatibilität prüfen
Phase 6 – Ergebnis
Erstelle eine vollständige Audit-Matrix für 881–910:
- Status
- Exakte Codefundstelle
- Reproduktionsschritte
- Erwartetes und tatsächliches Ergebnis
- Schweregrad
- Testnachweis
- Fix oder begründete Zurückstellung
Führe relevante Tests aus und dokumentiere deren tatsächliche Ergebnisse.

Erstelle bei notwendigen Änderungen einen Draft-Pull-Request gegen develop.

Nicht auf main mergen.
Keine produktiven Sicherheits- oder Belastungstests ohne ausdrückliche Freigabe.
Keine ungetesteten Behauptungen als bestandene Prüfungen ausgeben.




Gesamtplanung
910 Prüfpunkte



Nächste Runde 911–940: Noch tiefer in Apple Pencil, PencilKit, PDFKit, Windows-Zeichenengine, Speicherverwaltung und Synchronisierung einzelner Stiftoperationen – bis hin zu konkreten Datenstrukturen, Race Conditions und Performance-Grenzen.

















weiter













UniFlow AI – 30 weitere Prüfpunkte (911–940)
Schwerpunkt: Apple Pencil, PencilKit, PDFKit, Windows-Zeichenengine, Strich-Synchronisierung und Performance.

Diesmal gehen wir auf die Ebene einzelner Striche, Koordinaten, Speicheroperationen und Synchronisierungsereignisse. Ziel ist, dass UniFlow beim Schreiben möglichst flüssig bleibt und Notizen beim Wechsel zwischen iPad, Mac und Windows zuverlässig erhalten bleiben.
iPadOS
macOS
Windows

Android bleibt zurückgestellt. Die Punkte sind technische Anforderungen und Testfälle, keine bestätigten Fehler im aktuellen Code.
110. PencilKit und native Stiftinformationen
Nr.	Prüfpunkt	Konkrete technische Anforderung
911	Stabile Stroke-IDs	Jeder Strich erhält eine dauerhaft eindeutige ID, die beim Speichern und Synchronisieren erhalten bleibt.
912	PencilKit-Roundtrip	PKDrawing wird gespeichert, geladen und erneut gespeichert, ohne unterstützte native Strichinformationen zu verlieren.
913	Druck und Neigung	Druck, Azimut, Neigung und zeitliche Informationen bleiben erhalten, soweit PencilKit sie bereitstellt.
914	Unterschiedliche Stiftwerkzeuge	Marker, Stift, Radierer und ihre Eigenschaften werden korrekt rekonstruiert.
915	Apple-Pencil-Pro-Eingaben	Zusätzliche Eingabeereignisse wie Squeeze werden auf unterstützten Geräten korrekt behandelt, ohne ältere Geräte zu beeinträchtigen.
916	Unbekannte Apple-Daten	Windows darf native PencilKit-Daten, die es nicht interpretieren kann, nicht zerstören.

111. Koordinaten und PDF-Geometrie
Nr.	Prüfpunkt	Konkrete technische Anforderung
917	Dokumentkoordinaten	Striche werden in stabilen Seitenkoordinaten statt Bildschirm-Pixeln gespeichert.
918	Unterschiedliche Zoomstufen	Ein bei 250 % Zoom erstellter Strich liegt bei 100 % an exakt derselben Dokumentposition.
919	PDF-Rotation	Rotation um 90°, 180° oder 270° verändert die fachliche Position der Annotation nicht.
920	CropBox und MediaBox	PDFs mit abweichenden Seitenrahmen werden korrekt behandelt.
921	Display-Skalierung	Retina-Displays, Windows-DPI-Skalierung und externe Monitore verschieben keine Striche.
922	Seitenformatwechsel	Hoch- und Querformat sowie Split View verändern nur die Darstellung, nicht die gespeicherten Koordinaten.

112. Einzelne Strichoperationen synchronisieren
Nr.	Prüfpunkt	Konkrete technische Anforderung
923	Stroke-Add	Ein neuer Strich wird als eindeutig identifizierbare Änderung übertragen.
924	Stroke-Delete	Löschen referenziert eine konkrete Stroke-ID und bleibt nach Offline-Sync erhalten.
925	Stroke-Update	Verschieben, Skalieren oder Ändern eines Strichs erzeugt eine nachvollziehbare Änderung.
926	Idempotenz	Dieselbe Operation kann mehrfach ankommen, ohne mehrfach angewendet zu werden.
927	Kausalität	Eine Änderung darf nicht vor dem Strich wirksam werden, auf den sie sich bezieht.
928	Konfliktauflösung	Gleichzeitige Änderungen werden deterministisch behandelt; keine stillen Überschreibungen.

113. Speicherverwaltung und Geschwindigkeit
Nr.	Prüfpunkt	Konkrete technische Anforderung
929	Inkrementelles Speichern	Ein zusätzlicher Strich soll nicht jedes Mal das gesamte Dokument neu serialisieren müssen.
930	Änderungsjournal	Noch nicht synchronisierte Operationen werden dauerhaft und absturzsicher gespeichert.
931	Batch-Verarbeitung	Große Änderungsmengen werden in begrenzten Paketen übertragen.
932	Speicherfreigabe	Nicht sichtbare PDF-Seiten und Render-Caches werden bei Bedarf freigegeben.
933	Hintergrundverarbeitung	Netzwerk- und Speicherarbeit darf den Eingabe-Thread nicht blockieren.
934	Crash-Recovery	Nach einem Absturz werden alle bereits dauerhaft bestätigten lokalen Änderungen rekonstruiert.

114. Präzise Qualitäts- und Belastungstests
Nr.	Prüfpunkt	Konkrete technische Anforderung
935	Stiftlatenz	Eingabe-zu-Anzeige-Latenz auf echten Geräten messen, einschließlich p50, p95 und p99.
936	Strichgenauigkeit	Positionsabweichungen nach Export, Import und Synchronisierung quantitativ prüfen.
937	50.000 Striche	Große Zeichnungen ohne Datenverlust laden, bearbeiten und speichern.
938	Drei Geräte parallel	iPad, Mac und Windows führen konkurrierende Strichoperationen aus und erreichen denselben Endzustand.
939	Netzwerkchaos	Offline, Wiederverbindung, Duplikate, Verzögerung und vertauschte Pakete simulieren.
940	Versionskompatibilität	Alte Clients dürfen neue Annotationen weder unbemerkt beschädigen noch unzulässig überschreiben.


Technische Vertiefung 1: Wie einzelne Striche synchronisiert werden sollten
Das vorhandene pkdrawing-v2-Format enthält bereits Informationen zur Identifizierung einzelner Striche. Entscheidend ist jetzt, ob die Netzwerk-Synchronisierung diese Informationen tatsächlich nutzt.
Empfohlene Prüfrichtung für das bestehende Synchronisierungssystem, nicht als bereits implementierte Architektur bestätigt.
Eine mögliche Operation könnte so aussehen:

{
  "operationId": "op-123",
  "documentId": "doc-456",
  "pageId": "page-2",
  "strokeId": "stroke-789",
  "type": "stroke.add",
  "baseRevision": 41,
  "payload": {
    "format": "pkdrawing-v2",
    "strokeData": "..."
  }
}



Das ist ein Beispiel für einen möglichen Vertrag, kein nachgewiesenes Format der vorhandenen API. Vor einer Umsetzung müssen das bestehende Annotationsschema und die G2-Sync-Endpunkte geprüft werden.
Technische Vertiefung 2: Was bei gleichzeitiger Bearbeitung passiert
Konkretes Testszenario
1. iPad und Windows öffnen dieselbe PDF bei Revision 41.
2. Das iPad fügt Strich A hinzu, während Windows Strich B hinzufügt.
3. Der Mac löscht einen älteren Strich C.
4. Alle drei Geräte synchronisieren in unterschiedlicher Reihenfolge.
5. Erwarteter Endzustand: A und B vorhanden, C gelöscht – auf allen Geräten identisch.

Schwieriger wird es, wenn Windows denselben Strich verschiebt, den das iPad gleichzeitig löscht. Hier muss die Architektur eine eindeutige Regel besitzen, beispielsweise einen Konflikt ausweisen oder eine deterministische Löschpriorität anwenden. Einfach den zuletzt empfangenen Gesamtzustand zu speichern, wäre für solche Fälle riskant.
Technische Vertiefung 3: Messbare Qualitätsziele
Die folgenden Werte sind zunächst vorgeschlagene Abnahmekriterien, keine gemessenen Ergebnisse.
Messgröße	Vorgeschlagenes Ziel
Strichverlust nach erfolgreichem Sync	0
Doppelte Anwendung identischer Operationen	0
Unterschiedliche Endzustände nach abgeschlossenem Sync	0
Positionsabweichung nach Koordinaten-Roundtrip	≤ 0,5 PDF-Punkte
Sichtbare Online-Sync-Verzögerung	p95 ≤ 3 Sekunden unter definierten Testbedingungen
Absturz nach dauerhaftem lokalem Commit	Keine bestätigten lokalen Änderungen verlieren
50.000-Striche-Test	Erfolgreicher Roundtrip ohne Datenverlust; Laufzeit separat messen


Master-Prompt 27 – Tiefenprüfung der Zeichenengine
UniFlow AI – Deep PencilKit, PDF Geometry & Stroke Sync Audit 911–940
Repository: Ahmad271223/uniflow-ai
Basisbranch: develop
Release-Plattformen
Windows, iPadOS und macOS.

Android ist ausdrücklich nicht Bestandteil dieses Audits. Vorhandenen Android-Code nicht löschen.
Ziel
Prüfe, ob der vorhandene PDF-Editor und die Synchronisierung einzelne Stiftoperationen zuverlässig speichern, übertragen, zusammenführen und wiederherstellen können.
Phase 1 – Tatsächliche Architektur rekonstruieren
Ermittle den neuesten develop-HEAD.

Untersuche:
- PencilKit-Integration
- PKDrawing-Serialisierung
- PDFKit-Koordinatentransformationen
- Windows-Editor und Canvas
- annotations.schema.json / pkdrawing-v2
- G2-Sync-Endpunkte
- Lokale Änderungsjournale
- Merge- und Konfliktlogik
- Vorhandene Tests
Dokumentiere den tatsächlichen Datenfluss vom Stifteingabeereignis bis zum anderen Gerät.

Keine Implementierung allein aufgrund einer Architekturzeichnung oder Statusdatei als vorhanden bewerten.
Phase 2 – Strichidentität
Prüfe:
1. Werden Strich-IDs dauerhaft gespeichert?
2. Bleiben sie beim Export und Import erhalten?
3. Sind IDs über Geräte hinweg eindeutig?
4. Können einzelne Striche gelöscht oder geändert werden?
5. Werden native PencilKit-Daten verlustfrei aufbewahrt?
6. Was passiert, wenn Windows einen Apple-spezifischen Strich nicht vollständig versteht?
Erstelle Roundtrip-Tests mit realistischen Testzeichnungen.
Phase 3 – PDF-Geometrie
Teste Transformationen zwischen:
- PDF-Seitenkoordinaten
- PencilKit-Koordinaten
- Windows-Canvas-Koordinaten
- Bildschirmkoordinaten
Berücksichtige Zoom, Rotation, CropBox, MediaBox, DPI und Split View.

Erstelle automatisierte Tests mit bekannten Referenzpunkten.
Phase 4 – Synchronisierung
Prüfe anhand des Codes, ob einzelne Stroke-Operationen oder vollständige Dokumentzustände übertragen werden.

Teste:
- Add/Add
- Add/Delete
- Update/Update
- Update/Delete
- Delete/Delete
- Wiederholte Operationen
- Vertauschte Operationen
- Offline-Änderungen
- Veraltete Clients
- Abgebrochene Übertragungen
Definiere und teste eine deterministische Konfliktstrategie.

Keine zweite Sync-Engine entwickeln, wenn die bestehende sicher erweitert werden kann.
Phase 5 – Performance
Erstelle reproduzierbare Benchmarks für:
- 1.000 Striche
- 10.000 Striche
- 50.000 Striche
- Große PDFs
- Mehrere gleichzeitig geöffnete Dokumente
- Hintergrund-Synchronisierung
Miss Speicherbedarf, Ladezeit, Serialisierung, Merge-Zeit und Rendering.

Stiftlatenz nur auf echten Geräten als gemessen ausweisen.
Phase 6 – Sicherheit und Datenverlust
Teste Abstürze:
- Vor lokalem Commit
- Nach lokalem Commit
- Während Upload
- Nach Server-Commit, vor Antwort
- Während Merge
- Während Gerätewechsel
Nach einem erfolgreich bestätigten dauerhaften Commit dürfen die entsprechenden Änderungen nicht verloren gehen.
Phase 7 – Ergebnis
Erstelle für alle Anforderungen 911–940 eine Audit-Matrix mit:
- Status
- Exakter Codefundstelle
- Reproduktionsschritten
- Erwartetem Ergebnis
- Tatsächlichem Ergebnis
- Testnachweis
- Schweregrad
- Minimalem Fix
Behebe bestätigte kritische Fehler zuerst.

Arbeite auf einem separaten Feature-Branch und erstelle bei Codeänderungen einen Draft-PR gegen develop.

Keine direkten Änderungen an main oder develop.
Keine produktiven Daten verändern.
Keine nicht ausgeführten Tests als erfolgreich darstellen.




Gesamtplanung
940 Prüfpunkte



Nächste Runde 941–970: Noch tiefer in die tatsächliche Offline-Architektur: lokale Datenbanken, Verschlüsselung, Sync-Journale, Gerätewechsel, Datenmigrationen, Wiederherstellung nach Abstürzen und Schutz vor dauerhaft verlorenen Notizen.

















weiter













UniFlow AI – 30 weitere Prüfpunkte (941–970)
Schwerpunkt: Offline-First, lokale Datenbanken, Verschlüsselung, Synchronisierungsjournale, Gerätewechsel und Schutz vor Datenverlust.

Diesmal gehen wir noch tiefer in die Architektur. Ziel ist, dass Studierende auf dem iPad, Mac und Windows-Laptop auch ohne Internet arbeiten können und ihre Notizen selbst bei Abstürzen, Gerätewechseln oder fehlerhaften Synchronisierungen erhalten bleiben.
Windows
iPadOS
macOS

Android bleibt außerhalb der aktuellen Releaseplanung.
115. Lokale Datenbanken und Offline-Speicherung
Nr.	Prüfpunkt	Konkrete Anforderung
941	Dauerhafte Offline-Speicherung	Neue Notizen werden lokal gespeichert, auch ohne Internetverbindung.
942	Atomarer lokaler Commit	Notizänderung und zugehöriger Sync-Eintrag werden in einer Transaktion gespeichert.
943	SQLite-WAL-Sicherheit	Schreibvorgänge, Checkpoints und Wiederherstellung werden bei Abstürzen geprüft.
944	Mehrere offene Dokumente	Parallele Schreibvorgänge dürfen lokale Datenbanken nicht beschädigen.
945	Offline-Kursbibliothek	Bereits heruntergeladene PDFs bleiben ohne Hochschulverbindung verfügbar.
946	Speicherplatzmangel	Bei vollem Datenträger werden ungesicherte Änderungen nicht stillschweigend verworfen.

116. Verschlüsselung und lokale Datensicherheit
Nr.	Prüfpunkt	Konkrete Anforderung
947	Schutz lokaler Tokens	Sitzungs- und Hochschultokens in Windows Credential Manager bzw. Apple Keychain schützen.
948	Lokale Datenverschlüsselung	Schutzbedarf und geeignete Verschlüsselung für lokale Notizen und Metadaten prüfen.
949	Schlüsselverwaltung	Schlüssel dürfen nicht fest im Quellcode oder in Konfigurationsdateien hinterlegt sein.
950	Kontowechsel	Lokal gespeicherte Daten müssen eindeutig einem UniFlow-Konto zugeordnet sein.
951	Geräteverlust	Nach Sitzungswiderruf darf das verlorene Gerät keine neuen Cloud-Daten abrufen.
952	Sichere Protokolle	Logs dürfen keine Zugangsdaten, Tokens oder privaten Notizinhalte enthalten.

117. Sync-Journal und zuverlässige Übertragung
Nr.	Prüfpunkt	Konkrete Anforderung
953	Persistente Outbox	Jede noch nicht bestätigte Änderung bleibt dauerhaft in einer lokalen Warteschlange.
954	Eindeutige Operations-ID	Jede Änderung besitzt eine stabile ID für Wiederholungen.
955	Wiederholungsstrategie	Fehlgeschlagene Uploads werden mit begrenztem exponentiellem Backoff wiederholt.
956	Bestätigungsgrenze	Eine Operation wird erst nach nachweisbarer Serverbestätigung als synchronisiert markiert.
957	Download-Cursor	Empfangene Änderungen werden mit einem dauerhaft gespeicherten Cursor nachvollzogen.
958	Cursor und Anwendung	Cursor-Fortschritt und lokale Anwendung empfangener Änderungen müssen atomar erfolgen.

118. Gerätewechsel und Versionsmigration
Nr.	Prüfpunkt	Konkrete Anforderung
959	Neues Gerät einrichten	Nach Anmeldung werden synchronisierte Kurse, Notizen und Einstellungen geladen.
960	Lokale ungesicherte Änderungen	Vor Abmeldung oder Gerätewechsel auf nicht synchronisierte Daten hinweisen.
961	Datenbankschema-Upgrade	Neue App-Versionen migrieren vorhandene Daten ohne Verlust.
962	Downgrade-Schutz	Ältere App-Versionen dürfen neuere Datenbanken nicht beschädigen.
963	Verschiedene Clientversionen	Windows und Apple können unterschiedliche Versionen verwenden, ohne Daten zu verlieren.
964	Geräteübergreifende Wiederherstellung	Wiederhergestellte Daten dürfen keine alten gelöschten Inhalte erneut aktivieren.

119. Absturzsicherheit und Datenrettung
Nr.	Prüfpunkt	Konkrete Anforderung
965	Absturz während Speicherung	Nach Neustart bleibt der letzte vollständig bestätigte lokale Zustand erhalten.
966	Absturz während Upload	Wiederholte Übertragung erzeugt keine doppelten Striche oder Notizen.
967	Absturz während Download	Änderungen werden nach Neustart korrekt fortgesetzt.
968	Beschädigte lokale Datenbank	Beschädigung erkennen und sichere Wiederherstellungsoptionen anbieten.
969	Backup-Retention	Lokale Sicherungen dürfen nicht unkontrolliert anwachsen oder die einzige brauchbare Kopie verdrängen.
970	End-to-End-Datenrettung	Simulierter Geräte- und Serverausfall mit überprüfbarer Wiederherstellung aller gesicherten Änderungen.


Technische Vertiefung 1: Der wichtigste Offline-Speichervorgang
Wenn ein Student einen Strich zeichnet, sollten die dauerhafte Speicherung und die Registrierung für die Synchronisierung zusammengehören.
Empfohlener Ablauf. Ob UniFlow bereits alle Schritte atomar umsetzt, muss anhand des Codes geprüft werden.
Der entscheidende Fehler wäre, einen Strich lokal zu speichern, aber beim Absturz den dazugehörigen Sync-Eintrag zu verlieren. Dann erscheint die Notiz zwar auf dem ursprünglichen Gerät, wird aber niemals auf die anderen Geräte übertragen.

Eine lokale Transaktion kann dieses Risiko vermeiden:

BEGIN IMMEDIATE;

INSERT INTO strokes (
    stroke_id, document_id, payload
) VALUES (
    :stroke_id, :document_id, :payload
);

INSERT INTO sync_outbox (
    operation_id, document_id, operation_type,
    payload, status
) VALUES (
    :operation_id, :document_id,
    'stroke.add', :operation_payload, 'pending'
);

COMMIT;



Das ist ein Architekturbeispiel, keine Behauptung über das bestehende UniFlow-Datenbankschema.
Technische Vertiefung 2: Drei gefährliche Absturzzeitpunkte
Absturzzeitpunkt	Erwartetes Verhalten
Vor lokalem Commit	Nicht bestätigte Änderung darf fehlen; bestehende Daten bleiben intakt.
Nach lokalem Commit, vor Serverantwort	Operation bleibt in der Outbox und kann sicher erneut gesendet werden.
Nach Server-Commit, vor Empfang der Antwort	Wiederholung wird über dieselbe Operations-ID erkannt und nicht doppelt angewendet.

Zusätzlich muss der Download-Cursor erst dann fortgeschrieben werden, wenn die zugehörigen Änderungen lokal dauerhaft angewendet wurden.
Technische Vertiefung 3: Gerätewechsel ohne Datenverlust
Beispiel: Student wechselt von Windows auf ein neues MacBook.
1. Windows besitzt 120 lokal gespeicherte neue Striche.
2. Davon wurden 100 bereits erfolgreich synchronisiert.
3. UniFlow zeigt deutlich an, dass noch 20 Änderungen nur lokal vorhanden sind.
4. Auf dem MacBook werden zunächst die 100 bestätigten Cloud-Änderungen geladen.
5. Sobald Windows wieder online ist und die restlichen 20 Änderungen bestätigt wurden, erscheinen auch diese auf dem MacBook.
Wichtig: UniFlow darf nicht behaupten, dass alle 120 Striche in der Cloud gesichert sind, solange 20 davon nur lokal existieren.


Master-Prompt 28 – Offline-First und Datenverlustprüfung
UniFlow AI – Deep Offline-First, Local Storage & Recovery Audit 941–970
Repository: Ahmad271223/uniflow-ai
Basisbranch: develop
Aktive Plattformen
- Windows
- iPadOS
- macOS
Android für eine spätere Version zurückstellen. Vorhandenen Android-Code nicht löschen.
Ziel
Prüfe die Anforderungen 941–970 anhand der tatsächlichen Implementierung.

Fokus: Keine dauerhaft gespeicherte Änderung darf durch Synchronisierung, Abstürze, Migrationen oder Gerätewechsel unbemerkt verloren gehen.
Phase 1 – Architektur und Datenfluss
Ermittle den aktuellen develop-HEAD.

Untersuche:
- Lokale SQLite-Datenbanken und andere Speichermechanismen
- Apple-Pencil- und Windows-Editor-Speicherung
- Lokale Sync-Journale
- G2-Synchronisierung
- Account-Isolation
- Schlüsselverwaltung
- Datenbankmigrationen
- Backup- und Wiederherstellungscode
- Bestehende Tests
Rekonstruiere den vollständigen Weg einer Änderung vom Editor bis zur Cloud und zum zweiten Gerät.
Phase 2 – Atomare Speicherung
Prüfe, ob lokale Änderungen und Outbox-Einträge konsistent gespeichert werden.

Simuliere einen Prozessabsturz an jeder relevanten Transaktionsgrenze.

Prüfe:
- Keine bestätigten Änderungen verlieren
- Keine Outbox-Einträge ohne zugehörige Daten
- Keine lokalen Änderungen dauerhaft ohne Synchronisierungsweg
- Keine doppelte Anwendung nach Wiederholung
Phase 3 – Sicherheit
Prüfe:
- Windows Credential Manager
- Apple Keychain
- Token-Lebensdauer
- Kontowechsel
- Lokale Datenisolation
- Protokollierung
- Verschlüsselungsbedarf
Verändere keine produktiven Schlüssel oder Tokens.
Phase 4 – Synchronisierung
Teste:
- Offline-Bearbeitung
- Netzwerkunterbrechung
- Wiederholte Operationen
- Vertauschte Operationen
- Serverbestätigung ohne Clientantwort
- Atomare Cursor-Fortschreibung
- Mehrere gleichzeitig aktive Geräte
Nutze die vorhandene G2-Architektur und erweitere sie nur bei nachgewiesener Notwendigkeit.
Phase 5 – Migration und Wiederherstellung
Teste:
- Schema-Upgrades
- Veraltete Clientversionen
- Datenbankbeschädigung
- Voller Datenträger
- Gerätewechsel
- Wiederherstellung aus Backups
- Erneute Synchronisierung nach Restore
Führe destruktive Tests ausschließlich mit isolierten Testdaten aus.
Phase 6 – Ergebnis
Erstelle für jeden Punkt 941–970:
- Status
- Exakte Codefundstelle
- Reproduktionsschritte
- Testnachweis
- Datenverlustrisiko
- Priorität
- Kleinster sicherer Fix
Behebe bestätigte P0-Fehler zuerst.

Führe die relevanten Tests tatsächlich aus und dokumentiere ihre Ergebnisse.

Arbeite auf einem separaten Feature-Branch und erstelle bei Codeänderungen einen Draft-PR gegen develop.

Keine direkten Änderungen an main oder develop.
Keine produktiven Daten verändern.
Keine ungetesteten Behauptungen als erfolgreiche Prüfungen ausgeben.




Gesamtplanung
970 Prüfpunkte



Nächste Runde 971–1000: Produktionsreife mit konkreten Release-Gates für Windows, iPad und Mac: CI/CD, Code-Signing, App-Store-Prüfung, automatische Updates, Crash-Reporting, Datenschutz und ein vollständig testbarer Go-live-Prozess.

















weiter  bis es nichts mehr gibt













UniFlow AI – Abschluss der großen Prüfplanung
Wir machen weiter, diesmal nicht nur mit 30 Punkten. Ich ergänze die noch offenen Bereiche bis zur technischen Produktionsreife von Windows, iPad und Mac.

Eine wichtige Grenze: Bei Software kann man theoretisch unendlich viele Sonderfälle formulieren. Deshalb ist das sinnvollere Ziel, irgendwann keine neuen Prüfpunkte mehr zu erfinden, sondern alle wesentlichen Risiken durch konkrete Tests abzudecken.

Die folgenden Punkte sind Anforderungen und Prüfaufträge, keine nachgewiesenen Fehler. Maßgeblich bleibt der neueste develop-Branch.
120. Release, Installation und Updates (971–990)
Nr.	Prüfpunkt	Konkrete Abnahmebedingung
971	Reproduzierbare Builds	Derselbe Commit erzeugt nachvollziehbare Release-Artefakte.
972	Windows-Code-Signing	Installer und ausführbare Dateien werden korrekt signiert.
973	Apple-Code-Signing	iPad- und Mac-Builds verwenden gültige Zertifikate und Provisioning-Profile.
974	Notarisierung	Außerhalb des Mac App Store vertriebene macOS-Builds bestehen die erforderliche Notarisierung.
975	Windows-Installer	Installation auf einem sauberen Windows-System funktioniert.
976	macOS-Installation	Installation auf einem unterstützten Mac funktioniert ohne manuelle Entwicklerkonfiguration.
977	iPad-Installation	TestFlight-Build startet auf einem echten iPad.
978	Automatische Updates	Unterstützte Vertriebskanäle erhalten Updates über einen verifizierten Mechanismus.
979	Update-Signaturen	Manipulierte Update-Pakete werden abgelehnt.
980	Update-Rollback	Bei einem fehlerhaften Update bleiben Benutzerdaten erhalten.
981	Datenmigration beim Update	Vorhandene Notizen überstehen Versionswechsel.
982	Alte App-Versionen	Inkompatible Clients werden kontrolliert behandelt.
983	Release-Kanäle	Development, Beta und Production sind eindeutig getrennt.
984	Release-Konfiguration	Test- und Produktionsendpunkte können nicht versehentlich vertauscht werden.
985	CI-Pflichtprüfungen	Kritische Tests müssen vor Freigabe bestehen.
986	Abhängigkeiten	Veraltete oder verwundbare Pakete werden erkannt und bewertet.
987	Software-Stückliste	Abhängigkeiten können für einen Release nachvollzogen werden.
988	Release-Artefakte	Prüfsummen und Versionen sind eindeutig zuordenbar.
989	Changelog	Relevante Änderungen und Migrationen sind dokumentiert.
990	Go-live-Freigabe	Veröffentlichung erfolgt nur nach dokumentierter Prüfung aller P0-Blocker.

121. Cloud-Betrieb und Beobachtbarkeit (991–1010)
Nr.	Prüfpunkt	Konkrete Abnahmebedingung
991	Healthchecks	Dienstverfügbarkeit wird zuverlässig erkannt.
992	Readiness	Server nimmt erst nach erfolgreicher Initialisierung Anfragen an.
993	Strukturierte Logs	Fehler lassen sich ohne Offenlegung privater Daten untersuchen.
994	Request-IDs	Zusammengehörige API-Ereignisse können verfolgt werden.
995	Fehlerraten	Erhöhte HTTP-5xx-Raten lösen Warnungen aus.
996	Synchronisierungsmetriken	Rückstände, Konflikte und fehlgeschlagene Sync-Vorgänge sind messbar.
997	Datenbankmetriken	Sperren, Speicherverbrauch und langsame Abfragen werden überwacht.
998	KI-Kostenalarme	Ungewöhnlich hohe Ausgaben werden erkannt.
999	Backup-Überwachung	Fehlgeschlagene Sicherungen werden gemeldet.
1000	Restore-Überwachung	Regelmäßige Wiederherstellungstests werden dokumentiert.
1001	Kapazitätsgrenzen	CPU, RAM, Speicher und Datenbankverbindungen besitzen definierte Grenzen.
1002	Lastspitzen	Der Server begrenzt Überlastung kontrolliert.
1003	Graceful Shutdown	Laufende Transaktionen werden korrekt abgeschlossen oder zurückgerollt.
1004	Neustartverhalten	Warteschlangen werden nach Neustart zuverlässig fortgesetzt.
1005	Secret-Rotation	Zugangsschlüssel können ohne Datenverlust gewechselt werden.
1006	TLS	Externe Verbindungen sind angemessen abgesichert.
1007	Datenbankzugriff	Produktionsdatenbanken sind nicht unnötig öffentlich erreichbar.
1008	Notfallkontakte	Zuständigkeiten für Ausfälle und Sicherheitsvorfälle sind dokumentiert.
1009	Incident-Prozess	Fehler können erkannt, eingegrenzt und behoben werden.
1010	Betriebsdokumentation	Deployment und Wiederherstellung sind reproduzierbar beschrieben.

122. Datenschutz, Konten und Nutzerrechte (1011–1030)
Nr.	Prüfpunkt	Konkrete Abnahmebedingung
1011	Datenschutzerklärung	Tatsächliche Datenverarbeitung vollständig und verständlich beschreiben.
1012	Datenminimierung	Nur für Funktionen erforderliche Daten speichern.
1013	Datenexport	Nutzer können eigene Notizen, Aufgaben und Kontodaten exportieren.
1014	Kontolöschung	Löschvorgang umfasst alle relevanten Systeme.
1015	Backup-Löschfristen	Gelöschte Daten bleiben nicht unbegrenzt in Sicherungen.
1016	Aufbewahrungsfristen	Datenarten besitzen dokumentierte Löschregeln.
1017	KI-Datenweitergabe	Nutzer erfahren, welche Inhalte an KI-Anbieter übertragen werden.
1018	Hochschulzugangsdaten	Hochschulpasswörter und Sitzungen werden besonders geschützt.
1019	Hochschulnutzungsbedingungen	Import- und Abrufverfahren werden rechtlich geprüft.
1020	Datenverarbeitungsverträge	Erforderliche Vereinbarungen mit Dienstleistern sind vorhanden.
1021	Drittlandtransfers	Internationale Datenübertragungen werden geprüft und dokumentiert.
1022	Community-Freigabe	Veröffentlichungen erfolgen nur durch ausdrückliche Nutzeraktion.
1023	Recht auf Berichtigung	Fehlerhafte Kontodaten können korrigiert werden.
1024	Auskunftsanfragen	Nutzeranfragen können vollständig bearbeitet werden.
1025	Datenschutzvorfälle	Meldepflichten und Reaktionsabläufe sind geklärt.
1026	Minderjährige	Altersbezogene Anforderungen werden berücksichtigt, soweit relevant.
1027	Telemetrie	Optionale Nutzungsanalyse respektiert geltende Einwilligungsregeln.
1028	Crash-Reports	Fehlerberichte enthalten keine unnötigen Dokumentinhalte.
1029	Supportzugriffe	Mitarbeiter erhalten nur erforderliche Berechtigungen.
1030	Datenlebenszyklus	Erstellung, Speicherung, Weitergabe und Löschung sind dokumentiert.

123. Bedienbarkeit, Barrierefreiheit und Gerätequalität (1031–1050)
Nr.	Prüfpunkt	Konkrete Abnahmebedingung
1031	VoiceOver	Wichtige iPad- und Mac-Funktionen sind zugänglich.
1032	Windows-Screenreader	Wesentliche Funktionen funktionieren mit unterstützten Screenreadern.
1033	Tastaturnavigation	Kernfunktionen sind ohne Maus bedienbar.
1034	Kontrast	Texte und Bedienelemente sind ausreichend erkennbar.
1035	Schriftvergrößerung	Größere Systemschriften zerstören keine wichtigen Ansichten.
1036	Reduzierte Bewegung	Animationen respektieren Systemeinstellungen.
1037	Linkshänder-Modus	Werkzeugleisten können sinnvoll angeordnet werden.
1038	Apple Pencil	Werkzeugwechsel und Handballenerkennung sind zuverlässig.
1039	Windows-Stifte	Stift- und Touchbedienung funktionieren nebeneinander.
1040	Externe Displays	Fensterwechsel und Skalierung verursachen keine Positionsfehler.
1041	Split View	PDF und Notizen bleiben auf dem iPad sinnvoll bedienbar.
1042	Mehrfensterbetrieb	Gleichzeitige Fenster beschädigen keine Dokumentzustände.
1043	Dunkelmodus	Alle Ansichten bleiben lesbar.
1044	Leere Zustände	Neue Nutzer erkennen den nächsten sinnvollen Schritt.
1045	Fehlermeldungen	Fehler nennen eine verständliche Handlungsmöglichkeit.
1046	Ladezustände	Nutzer können zwischen Laden, Offline und Fehler unterscheiden.
1047	Speicherstatus	Lokal gespeichert und cloudgesichert werden eindeutig unterschieden.
1048	PDF-Druck	Eigene Annotationen können bei Bedarf korrekt mitgedruckt werden.
1049	Exportqualität	Notizen behalten bei PDF-Export Position und Lesbarkeit.
1050	Nutzertests	Reale Studierende bearbeiten definierte Aufgaben ohne Entwicklerhilfe.

124. Hochschulintegration und Datenkonsistenz (1051–1070)
Nr.	Prüfpunkt	Konkrete Abnahmebedingung
1051	Kursidentität	Kurs-IDs sind eindeutig einer Hochschule zugeordnet.
1052	Modulzuordnung	Vorlesungen und Übungen können einem Modul zugeordnet werden.
1053	Mehrere Semester	Gleichnamige Kurse unterschiedlicher Semester bleiben getrennt.
1054	Dateiidentität	Umbenannte Dateien werden nicht unnötig dupliziert.
1055	Dateiänderungen	Geänderte Inhalte werden anhand geeigneter Versionierungsmerkmale erkannt.
1056	Annotationserhalt	Dokumentaktualisierungen überschreiben keine Notizen.
1057	Entfernte Hochschuldateien	Lokale Kopien werden nach definierten Regeln behandelt.
1058	Session-Ablauf	Erneute Anmeldung erfolgt sicher und nachvollziehbar.
1059	Hochschulwartung	Vorübergehende Ausfälle führen nicht zu Datenverlust.
1060	Import-Wiederholung	Derselbe Import erzeugt keine unkontrollierten Duplikate.
1061	Dateinamen	Unicode und Sonderzeichen werden korrekt verarbeitet.
1062	PDF-Validierung	Defekte Dateien können sicher behandelt werden.
1063	Große Kurse	Hunderte Dateien bleiben auffindbar und performant.
1064	Kursarchiv	Alte Semester bleiben bei Bedarf lokal verfügbar.
1065	Manuelle Dateien	Eigene Dokumente funktionieren unabhängig vom Hochschulsystem.
1066	Importberechtigungen	Nur autorisierte Hochschulinhalte werden abgerufen.
1067	Hintergrundabgleich	Betriebssystemgrenzen werden eingehalten.
1068	Zeitplan	Geplante Synchronisierung verhindert unnötige Hochschulanfragen.
1069	Importprotokoll	Nutzer sehen letzte erfolgreiche Aktualisierung und Fehler.
1070	Anbieteränderungen	Änderungen an Hochschulsystemen können isoliert behoben werden.

125. KI-Zuverlässigkeit, Missbrauchsschutz und Wirtschaftlichkeit (1071–1090)
Nr.	Prüfpunkt	Konkrete Abnahmebedingung
1071	Kursisolation	KI-Anfragen erhalten nur berechtigte Kursinhalte.
1072	Quellenprüfung	Seitenverweise zeigen tatsächlich die verwendeten Inhalte.
1073	Prompt Injection	Anweisungen in PDFs dürfen Systemregeln nicht überschreiben.
1074	Kostenobergrenzen	KI-Ausgaben sind pro Nutzer und insgesamt begrenzbar.
1075	Atomare Kontingente	Gleichzeitige Anfragen können Limits nicht umgehen.
1076	Abbruch	Abgebrochene Anfragen werden korrekt abgerechnet.
1077	Wiederholung	Netzwerkfehler führen nicht unkontrolliert zu mehrfachen Kosten.
1078	Modellwechsel	Fallbacks erfüllen definierte Qualitäts- und Datenschutzregeln.
1079	Antwortqualität	Referenzaufgaben werden reproduzierbar ausgewertet.
1080	Rechenaufgaben	Mathematische Ergebnisse werden soweit möglich unabhängig geprüft.
1081	Fehlerfeedback	Die KI erklärt nachweisbare Fehler statt Lösungen zu erfinden.
1082	Prüfungsmodus	Lernhilfen und vollständige Lösungen können unterschiedlich gesteuert werden.
1083	Testgenerierung	Fragen beziehen sich auf tatsächlich verfügbare Kursinhalte.
1084	Antwortbewertung	Freitextbewertungen sind nachvollziehbar und überprüfbar.
1085	Datenschutz	Sensible Dokumente werden nicht unnötig an Modelle übertragen.
1086	Kontextbegrenzung	Große Dokumente werden gezielt statt vollständig verarbeitet.
1087	Zwischenspeicherung	Wiederholte Anfragen vermeiden unnötige Kosten, ohne Konten zu vermischen.
1088	Anbieterfehler	KI-Ausfälle beeinträchtigen nicht den normalen PDF-Editor.
1089	Kostenbericht	Tatsächliche Kosten pro Funktion und Tarif sind messbar.
1090	Wirtschaftlichkeitstest	Definierte Nutzungsprofile überschreiten nicht unbemerkt das geplante Budget.

126. Finale Qualitätssicherung und Produktionsfreigabe (1091–1120)
Nr.	Prüfpunkt	Konkrete Abnahmebedingung
1091	Windows-Neuinstallation	Frische Installation auf einem unabhängigen Rechner bestanden.
1092	Windows-Update	Update von einer älteren unterstützten Version bestanden.
1093	macOS-Neuinstallation	Installation auf einem echten Mac bestanden.
1094	macOS-Update	Daten bleiben beim Versionswechsel erhalten.
1095	iPad-TestFlight	Installation und Kernfunktionen auf echtem iPad bestanden.
1096	Apple-Pencil-Test	Schreiben, Radieren, Lasso und Speichern auf echter Hardware geprüft.
1097	Windows-Stifttest	Stifteingabe auf geeigneter Hardware geprüft, sofern offiziell unterstützt.
1098	Cross-Device-Sync	Windows, iPad und Mac erreichen denselben Dokumentzustand.
1099	Offline-Test	Alle zugesagten Offline-Funktionen funktionieren ohne Internet.
1100	Crash-Test	Bestätigte Änderungen überstehen erzwungene Prozessabbrüche.
1101	Kontoisolation	Fremde Dokumente und Notizen sind nicht zugänglich.
1102	Abonnementprüfung	Berechtigungen und Kontingente werden serverseitig erzwungen.
1103	Hochschulimport	Reale Integrationen wurden mit autorisierten Testkonten geprüft.
1104	PDF-Kompatibilität	Unterschiedliche Seitenformate, Rotation und große PDFs geprüft.
1105	Community-Sicherheit	Geteilte Lösungen enthalten keine ungewollten Originaldokumente.
1106	Datenexport	Nutzer können ihre Daten in brauchbaren Formaten sichern.
1107	Kontolöschung	Löschablauf wurde mit Testkonten vollständig geprüft.
1108	Backup-Restore	Wiederherstellung wurde praktisch durchgeführt.
1109	Lasttest	Definierte gleichzeitige Nutzerlast wurde erreicht.
1110	Kostenkontrolle	Maximale KI- und Infrastrukturkosten sind überwacht.
1111	Barrierefreiheit	Kritische Bedienabläufe wurden geprüft.
1112	Store-Metadaten	Beschreibung, Screenshots und Datenschutzangaben sind korrekt.
1113	Store-Richtlinien	Apple- und Microsoft-Anforderungen wurden für den jeweiligen Vertrieb geprüft.
1114	Sicherheitsprüfung	Kritische Authentifizierungs- und Autorisierungsfälle bestanden.
1115	Abhängigkeitsprüfung	Bekannte kritische Schwachstellen wurden bewertet und behoben.
1116	Produktionskonfiguration	Secrets, Datenbanken und externe Dienste sind korrekt konfiguriert.
1117	Monitoring	Kritische Fehler und Ausfälle werden erkannt.
1118	Rollback-Plan	Rücknahme eines fehlerhaften Releases ist dokumentiert und getestet.
1119	Release-Protokoll	Commit, Version, Tests und Freigabeentscheidung sind nachvollziehbar.
1120	Endgültige Freigabe	Kein offener P0-Blocker; verbleibende Risiken sind dokumentiert und akzeptiert.


Jetzt sind wir an einem sinnvollen Abschluss der Anforderungssammlung
Gesamtumfang
1.120
Nummerierte Prüfpunkte
Diese Runde
150
Zusätzliche Prüfpunkte


Was diese Zahl nicht bedeutet: 1.120 Fehler, 1.120 fehlende Funktionen oder 1.120 notwendige Codeänderungen. Viele Punkte überschneiden sich, und etliche Funktionen sind auf develop bereits vorhanden.

Master-Prompt 29 – Alle 1.120 Anforderungen abschließend prüfen
UniFlow AI – Finaler Gesamtaudit und Release-Plan
Repository: Ahmad271223/uniflow-ai
Basisbranch: develop
Auftrag
Prüfe die vollständige Anforderungssammlung 1–1120 gegen den tatsächlichen neuesten develop-Stand.

Aktive Plattformen:
- Windows
- iPadOS
- macOS
Android ist ausdrücklich für eine spätere Version zurückgestellt und darf nicht als aktueller Release-Blocker bewertet werden.
Phase 1 – Vollständige Bestandsaufnahme
1. Aktuellen develop-HEAD ermitteln.
2. Vorhandene Komponenten, Tests und CI-Konfiguration erfassen.
3. Historische Dokumentation nicht mit aktuellem Implementierungsstand verwechseln.
4. Alle 1120 Anforderungen erfassen, soweit ihre ursprünglichen Beschreibungen verfügbar sind.
5. Fehlende Anforderungstexte ausdrücklich melden, statt sie zu erfinden.
6. Doppelte oder inhaltlich gleiche Anforderungen zusammenführen, ohne ihre ursprünglichen Nummern zu verlieren.
Phase 2 – Klassifikation
Jeden Punkt genau einer Kategorie zuordnen:
- Vollständig implementiert und getestet
- Implementiert, aber nicht ausreichend getestet
- Teilweise implementiert
- Tatsächlich fehlend
- Bestätigter Fehler
- Für später zurückgestellt
- Nicht verifizierbar
Für jeden Punkt Codefundstellen und nachvollziehbare Belege angeben.
Phase 3 – Priorisierung
P0: Sicherheitslücken, Datenverlust, Kontenvermischung, kritische Zahlungsfehler und nicht nutzbare Kernfunktionen.

P1: Wesentliche Fehler bei PDF-Editor, Synchronisierung, Offline-Nutzung, Installation und Hochschulimport.

P2: Verbesserungen bei Geschwindigkeit, Bedienung, Lernplanung und KI.

P3: Optionale Erweiterungen und Komfortfunktionen.
Phase 4 – Technische Prüfung
Prüfe besonders gründlich:
- Windows 0.4.6 und den tatsächlichen aktuellen Versionsstand
- iPadOS/macOS und PencilKit
- PDF-Editor und Annotationen
- G2-Synchronisierung
- Strichweise Übertragung
- Offline-Datenbanken und Journale
- Konto- und Hochschulisolation
- KI-Testkontingente
- Community und Datenschutz
- Store-Abonnements
- Backups und Wiederherstellung
- Release-Builds und Updates
Phase 5 – Teststrategie
Führe vorhandene Tests aus und ergänze gezielte Regressionstests.

Unterscheide:
- Automatisch bestanden
- Manuell auf echter Hardware bestanden
- Fehlgeschlagen
- Nicht ausführbar
- Nicht getestet
Keine Testergebnisse erfinden.
Phase 6 – Sichere Umsetzung
Behebe bestätigte P0-Fehler zuerst.

Danach P1-Fehler nach Datenverlustrisiko und Nutzerwirkung priorisieren.

Keine parallelen Architekturen entwickeln.
Keine bereits funktionierenden Komponenten unnötig ersetzen.
Keine produktiven Daten verändern.
Keine kostenpflichtigen externen Aktionen ohne Freigabe.

Arbeite auf separaten Feature-Branches.
Erstelle nachvollziehbare Draft-Pull-Requests gegen develop.
Phase 7 – Abschlussbericht
Liefere:
1. Vollständige Anforderungsmatrix
2. Liste tatsächlich bestätigter Fehler
3. Übersicht bereits fertiger Funktionen
4. Liste fehlender Tests
5. P0/P1-Release-Blocker
6. Konkrete Umsetzungsschritte
7. Testnachweise
8. Restrisiken
9. Windows-Freigabestatus
10. iPad-Freigabestatus
11. macOS-Freigabestatus
Fertigstellungskriterium
Die Planung ist abgeschlossen, wenn alle wesentlichen Funktionsbereiche abgedeckt, doppelte Anforderungen konsolidiert und offene Risiken priorisiert sind.

Die App ist erst releasebereit, wenn sämtliche P0-Blocker nachweislich behoben und die definierten Freigabetests bestanden sind.

Nicht mit der bloßen Anzahl erfüllter Anforderungen argumentieren.




# UniFlow AI – Deep Audit Level 2 (1121–1150)

Wir gehen jetzt eine Ebene tiefer als bisher: weg von allgemeinen Funktionen, hin zu konkreten Datenverlustszenarien, Race Conditions, Transaktionsgrenzen und überprüfbaren Invarianten.

Der Fokus bleibt auf Windows, iPad und Mac. Android bleibt für eine spätere Version zurückgestellt.

Die folgenden Punkte sind zusätzliche technische Prüfungen, keine bestätigten Fehler im aktuellen `develop`-Code.

## 127. Strichweise Synchronisierung – kritische Grenzfälle

| Nr.  | Tiefenprüfung                                                  | Exaktes Erfolgskriterium                                                                      |
| ---- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| 1121 | Zwei Geräte erzeugen dieselbe Stroke-ID                        | Eine ID-Kollision darf nicht dazu führen, dass ein Strich stillschweigend überschrieben wird. |
| 1122 | Strich wird gelöscht, während ein anderes Gerät ihn verschiebt | Beide Operationen müssen nach einer definierten Konfliktregel behandelt werden.               |
| 1123 | Operationen treffen rückwärts ein                              | `stroke.update` vor `stroke.add` darf keine beschädigte Zeichnung erzeugen.                   |
| 1124 | Strich wird 100-mal übertragen                                 | Dieselbe `operationId` darf fachlich nur einmal angewendet werden.                            |
| 1125 | Serverantwort geht nach Commit verloren                        | Der Client muss sicher wiederholen können, ohne Duplikate zu erzeugen.                        |
| 1126 | Strich enthält unbekannte PencilKit-Daten                      | Ein Windows-Roundtrip darf die unbekannten Daten nicht zerstören.                             |

## 128. Datenbank – atomare Speicherung und Migration

| Nr.  | Tiefenprüfung                             | Exaktes Erfolgskriterium                                                           |
| ---- | ----------------------------------------- | ---------------------------------------------------------------------------------- |
| 1127 | Absturz zwischen Notiz und Outbox-Eintrag | Beide werden gemeinsam gespeichert oder gemeinsam zurückgerollt.                   |
| 1128 | Datenbankmigration bricht bei 50 % ab     | Die alte Datenbank bleibt nutzbar oder die Migration wird sicher fortgesetzt.      |
| 1129 | Zwei Prozesse schreiben gleichzeitig      | Keine verlorenen Updates oder unkontrollierten Datenbanksperren.                   |
| 1130 | Speicherplatz geht während Commit aus     | Bereits bestätigte Daten bleiben konsistent.                                       |
| 1131 | SQLite-WAL wird während Backup verändert  | Das Backup enthält einen konsistenten Datenbankzustand.                            |
| 1132 | Server-Restore mit alten Tombstones       | Gelöschte Inhalte dürfen nach Wiederherstellung nicht ungewollt wieder auftauchen. |

## 129. Apple Pencil und PDF-Geometrie

| Nr.  | Tiefenprüfung                                        | Exaktes Erfolgskriterium                                            |
| ---- | ---------------------------------------------------- | ------------------------------------------------------------------- |
| 1133 | PDF besitzt unterschiedliche CropBox und MediaBox    | Striche liegen nach Gerätewechsel an derselben Dokumentposition.    |
| 1134 | PDF-Seite wird um 270° gedreht                       | Annotationen behalten ihre korrekte Position und Ausrichtung.       |
| 1135 | iPad nutzt Split View und 300 % Zoom                 | Keine Koordinatenverschiebung beim Schreiben oder Exportieren.      |
| 1136 | Mac nutzt externen Bildschirm mit anderer Skalierung | Strichgeometrie bleibt unverändert.                                 |
| 1137 | PDF wird nach Annotation aktualisiert                | Alte Striche werden nicht ohne Prüfung auf falsche Inhalte gelegt.  |
| 1138 | PencilKit-Zeichnung wird mehrfach serialisiert       | Native Daten und unterstützte Stricheigenschaften bleiben erhalten. |

## 130. Sicherheit – tatsächliche Angriffsgrenzen

| Nr.  | Tiefenprüfung                                               | Exaktes Erfolgskriterium                                                    |
| ---- | ----------------------------------------------------------- | --------------------------------------------------------------------------- |
| 1139 | Fremde Dokument-ID in Sync-Payload                          | Server verweigert die Änderung vor dem Datenbank-Commit.                    |
| 1140 | Konto A meldet sich ab, Konto B meldet sich an              | Keine ausstehende A-Operation wird unter B hochgeladen.                     |
| 1141 | Apple-Login liefert andere E-Mail, aber gleiche Provider-ID | Kontozuordnung bleibt korrekt, ohne E-Mail als alleinigen Identitätsbeweis. |
| 1142 | Manipulierte Tarifangabe im Client                          | Backend ignoriert unberechtigte Tarifänderungen.                            |
| 1143 | Abgelaufene Sitzung während laufendem Upload                | Keine unautorisierte Folgeoperation nach Ablauf oder Widerruf.              |
| 1144 | PDF enthält bösartige Anweisungen an KI                     | Dokumentinhalt darf keine System- oder Werkzeugberechtigungen verändern.    |

## 131. Release und Wiederherstellung

| Nr.  | Tiefenprüfung                                   | Exaktes Erfolgskriterium                                                                                |
| ---- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| 1145 | Windows-Update wird unterbrochen                | Vorhandene Nutzerdaten bleiben erhalten.                                                                |
| 1146 | macOS-App wird neu installiert                  | Lokal erhaltene und cloudgesicherte Daten werden korrekt unterschieden.                                 |
| 1147 | iPad-App wird während Speicherung beendet       | Bereits dauerhaft gespeicherte Änderungen bleiben erhalten.                                             |
| 1148 | Cloud fällt während Gerätewechsel aus           | Lokal verfügbare Daten bleiben nutzbar; fehlende Cloud-Daten werden nicht als synchronisiert angezeigt. |
| 1149 | Restore aus Backup mit älterem Schema           | Migration und Wiederherstellung funktionieren in der korrekten Reihenfolge.                             |
| 1150 | Release enthält eine fehlerhafte Sync-Migration | Rollback verhindert weiteren Datenverlust und dokumentiert nicht rückgängig machbare Schemaänderungen.  |

## Noch tiefer: Fünf technische Invarianten

Diese Regeln sollten unabhängig von Gerät, App-Version und Netzwerkzustand gelten.

Invariant 1 – Keine fremden Daten

Eine Operation darf nur Daten lesen oder verändern, für die das authentifizierte Konto tatsächlich berechtigt ist. Die Prüfung muss serverseitig erfolgen.

Invariant 2 – Kein verlorener Commit

Nach bestätigtem dauerhaftem lokalem Commit muss die Änderung nach einem Prozessabsturz rekonstruierbar sein.

Invariant 3 – Idempotente Wiederholung

Dieselbe Operation mit derselben ID und demselben Inhalt darf bei erneuter Übertragung keine zweite fachliche Wirkung erzeugen. Unterschiedliche Inhalte mit derselben ID müssen als Konflikt erkannt werden.

Invariant 4 – Konvergente Synchronisierung

Wenn alle Geräte dieselben gültigen Operationen verarbeitet haben, müssen sie denselben fachlichen Dokumentzustand erreichen.

Invariant 5 – Keine stille Formatzerstörung

Ein Client darf Daten, die er nicht versteht, nicht unbemerkt entfernen oder überschreiben.

## Konkreter Test: 100 zufällige Synchronisierungsabläufe

Ein besonders sinnvoller nächster Schritt ist ein modellbasierter Test: Wir definieren einen kleinen, unabhängigen Referenzzustand und lassen zufällige Operationen gegen die tatsächliche Sync-Implementierung laufen.

```

# Pseudocode: an echte UniFlow-Sync-API anpassen

for seed in range(100):
    scenario = generate_scenario(
        seed=seed,
        devices=["windows", "ipad", "mac"],
        operations=500,
        failures=[
            "offline",
            "duplicate",
            "reorder",
            "disconnect",
            "restart"
        ]
    )

    expected = reference_model(scenario)

    actual = run_against_test_server(scenario)

    assert actual.no_unauthorized_access
    assert actual.no_lost_committed_operations
    assert actual.all_devices_converged
    assert actual.document_state == expected

```

Wichtig: Das ist ein Testentwurf, kein bereits ausführbarer UniFlow-Test. Für eine belastbare Aussage müssen Referenzmodell, Konfliktregeln und die echten Sync-Endpunkte konkret implementiert werden.

## Master-Prompt 30 – Invariantenbasierter Tiefenaudit

# UniFlow AI – Deep Audit Level 2: Invariants, Race Conditions & Fault Injection

Repository: Ahmad271223/uniflow-ai\
Basisbranch: develop

Aktive Plattformen: Windows, iPadOS, macOS.\
Android zurückgestellt.

## Ziel

Prüfe die Anforderungen 1121–1150 und die fünf zentralen Invarianten anhand des aktuellen Codes.

Keine neue Architektur erfinden, bevor die bestehende Implementierung vollständig verstanden wurde.

## 1. Codeanalyse

Ermittle den aktuellen develop-HEAD.

Rekonstruiere:

- Persistenz einer einzelnen Stiftoperation
- Lokale und serverseitige Transaktionsgrenzen
- Synchronisierungsprotokoll
- Konfliktregeln
- Identität und Autorisierung
- PDF-Koordinatenmodelle
- Versions- und Migrationsregeln

## 2. Modellbasierte Tests

Entwickle ein unabhängiges Referenzmodell für unterstützte Strichoperationen.

Teste deterministisch mit festen Seeds:

- 3 Geräte
- 500 Operationen pro Durchlauf
- Mindestens 100 unterschiedliche Seeds
- Offline-Phasen
- Duplikate
- Vertauschte Nachrichten
- Prozessneustarts
- Gleichzeitige Änderungen
- Kontowechsel

Prüfe Konvergenz, Idempotenz, Autorisierung und Erhalt bestätigter Änderungen.

Wenn die bestehende API keine einzelnen Strichoperationen unterstützt, dokumentiere diese Einschränkung zuerst. Implementiere keinen parallelen Sync-Stack.

## 3. Fault Injection

Simuliere kontrollierte Fehler:

- Vor und nach lokalem Commit
- Vor und nach Server-Commit
- Während Migration
- Während Backup
- Während Restore
- Bei vollem Datenträger
- Bei Netzwerkunterbrechung

Nur isolierte Testdaten verwenden.

## 4. PDF- und PencilKit-Roundtrips

Prüfe:

- Native Zeichnungsdaten
- Stroke-IDs
- Zoom
- Rotation
- CropBox/MediaBox
- Display-Skalierung
- Unbekannte Formatfelder

Unterscheide reine Unit-Tests von Tests auf echter Apple-Hardware.

## 5. Sicherheitsprüfung

Teste fremde Dokument-IDs, Kontowechsel, Sitzungswiderruf und manipulierte Tarifparameter.

Keine produktiven Angriffe durchführen.

## 6. Ergebnis

Für 1121–1150:

- Status
- Codefundstelle
- Testfall
- Tatsächliches Ergebnis
- Schweregrad
- Minimaler Fix

Zusätzlich:

- Übersicht verletzter Invarianten
- Reproduzierbare Test-Seeds
- Fehlerhafte Operationstraces
- P0/P1-Priorisierung
- Dokumentierte Restrisiken

Bestätigte kritische Fehler auf separatem Feature-Branch beheben und mit Regressionstests absichern.

Draft-PR gegen develop.\
Keine direkten Änderungen an main oder develop.\
Keine produktiven Daten verändern.\
Keine erfundenen Testergebnisse.

Gesamtplanung

# 1.150 Prüfpunkte

Nächste technische Ebene: Nicht noch mehr allgemeine Anforderungen, sondern formale Zustandsmaschinen für Synchronisierung, property-based Tests, reproduzierbare Crash-Simulationen und konkrete Beweise für die fünf Invarianten.   mac wieder alles geben was er wissen muss und alles wichtige am besten kopeie paste das selber auch vorhingib ihm alle sachen die er braucht die ich dir hier gebe wort für wort
