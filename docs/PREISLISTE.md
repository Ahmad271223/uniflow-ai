# StudiNow – Preisliste und wer was darf (Stand 04.11.2026)

Entscheidungen des Inhabers vom 04.11.2026. Die eine Quelle im Code ist `app/plans.py` (daraus
`packages/shared-contracts/fixtures/plans/plans.json`; die iPad-App prüft ihre Tabelle `Purchases/Plans.swift` dagegen).
Jeder Tarif enthält alles aus dem Tarif darunter.

## Preise

| Tarif | Preis | Für wen | Wo kaufbar |
| --- | --- | --- | --- |
| **StudiNow Free** | 0 € | Studium organisieren und Unterlagen lesen | überall |
| **StudiNow Plus** | **1,99 € / Monat**, 1 Woche gratis | Schreiben, teilen, Karteikarten, Tests mit dem eigenen ChatGPT – **je Gerät, ohne Notizen-Abgleich** | iPad (App Store), später Web/Windows (Stripe) |
| **StudiNow Pro AI** | **3,99 € / Monat** | Die StudiNow-KI macht die Arbeit: Karteikarten, fertige Fragen, Erklärungen | **erst mit dem Online-Dienst** (Version 2) |

Alle Preise sind Endkundenpreise inklusive Mehrwertsteuer. Pro Connect (2,99 €) steht weiter im Code, wird aber nicht
verkauft und nirgends angezeigt; ob es wegfällt, ist noch offen.

## Was jeder Tarif kann

**Plus gilt je Gerät** (Entscheidung vom 04.11.2026): Das Abo schaltet auf jedem Gerät mit derselben Apple-ID frei
(Apple verlangt „Käufe wiederherstellen“), aber Notizen wandern erst mit Pro AI zwischen iPad, PC und Web. Wer nur
im Browser arbeitet, hat seine Notizen im Dienst und sieht sie in jedem Browser, in dem er angemeldet ist.


| Funktion | Free | Plus | Pro AI |
| --- | :-: | :-: | :-: |
| PDFs öffnen und lesen, Suche im Skript | ✅ | ✅ | ✅ |
| Kurse, Module, Abgleich mit Stud.IP/Learnweb, frühere Semester | ✅ | ✅ | ✅ |
| Stundenplan, Lernkalender, Neuigkeiten, Schwarzes Brett | ✅ | ✅ | ✅ |
| Community lesen (nach Beitritt zum eigenen Kurs) | ✅ | ✅ | ✅ |
| Eigenes ChatGPT verbinden und die KI-Hilfe damit nutzen ¹ | ✅ | ✅ | ✅ |
| Stift, Textmarker, Notizen, Apple Pencil | – | ✅ | ✅ |
| **Notizen auf allen Geräten** (Abgleich zwischen iPad, PC und Web) | – | – (Plus gilt je Gerät) | ✅ |
| Kommentieren, Fragen stellen, Lösungen teilen, Korrekturen vorschlagen | – | ✅ | ✅ |
| **Karteikarten selbst anlegen und lernen** | – | ✅ | ✅ |
| **Karteikarten teilen und die anderer nutzen** (je Lernwoche oder fürs ganze Modul) | – | ✅ | ✅ |
| Tests aus der StudiNow-Bibliothek | – | 4 / Monat | unbegrenzt ² |
| **Neue KI-Tests** | – | **4 / Monat** (mit eigenem ChatGPT) | **20 / Monat** (StudiNow-KI) |
| **KI erstellt Karteikarten** („Fach, Lernwoche 5, 30 Karten“) | – | – | ✅ ³ |
| **Fertige Fragen zu jeder Vorlesungswoche** (2–3 Sätze à 15 Fragen, Lösungen und Erklärungen schon da) | – | – | ✅ |
| KI-Erklärungen, Lernfragen, Zusammenfassungen ohne eigenes ChatGPT | – | – | 150 / Monat ³ |
| Lernstatistiken, Wiederholung falscher Antworten, Lernempfehlungen | – | – | ✅ |

¹ Die Nutzung des **eigenen** ChatGPT-Abos stellen wir nicht hinter eine Bezahlschranke (laut den Regeln von OpenAI für
„Sign in with ChatGPT“, siehe `docs/KI-CHATGPT-PLAN.md`; vor dem Start vom Inhaber selbst nachlesen). Für andere Nutzer
braucht es außerdem noch die Freigabe von OpenAI. Plus verkauft die Tests, Karteikarten und das Teilen, nicht den
ChatGPT-Zugang.
² Fair-Use-Grenze 300 im Monat (Schutz vor Skripten).
³ Zählt auf das Kontingent „KI-Erklärungen, Lernfragen und Zusammenfassungen“ (150 / Monat); zusätzlich gilt das
KI-Budget je Konto (`LERNAPP_AI_USER_BUDGET_EUR`, Standard 2 €).

## So funktioniert die KI in Pro AI („sehr schlau“)

1. **Die Bibliothek arbeitet vor.** Sobald ein Modul im Dienst bekannt ist, kennt die StudiNow-KI je Vorlesungswoche
   die Themen, Hinweise aus Ankündigungen und die Aufgaben der Übungsblätter und hat die Lösungen samt Erklärung schon
   erarbeitet. Das passiert **einmal je Inhalt** (gleiche PDF = gleiche Arbeit) und gilt für alle Pro-AI-Nutzer.
2. **Fertige Fragen je Woche:** Zu jeder Vorlesungswoche entstehen 2–3 Sätze à 15 Fragen. Pro AI öffnet sie sofort,
   ohne ein Test-Kontingent zu verbrauchen. Nur wer eine Woche als Erster öffnet, wartet einmal ein bis zwei Minuten,
   danach ist sie für alle sofort da.
3. **Karteikarten auf Auftrag:** „Analysis I, Lernwoche 5, 30 Karten“ – die KI nimmt dafür das Material genau dieser
   Woche. Die Karten kann man bearbeiten, lernen und teilen.
4. **Teilen:** Karteikarten-Stapel gibt es je Vorlesungswoche oder fürs ganze Modul in der Community des Kurses
   (nur für Leute, die den Kurs haben oder hatten). Wer Plus hat, kann sie übernehmen.

Damit es bezahlbar bleibt, entstehen Wochenfragen und Lösungen **erst, wenn der erste Pro-AI-Nutzer das Modul öffnet**,
und werden dann für alle gespeichert. Kosten grob: 1–4 Cent je Fragensatz einmalig (je nach Modell); bei 1.000 aktiven
Modulen × 14 Wochen × 3 Sätzen also etwa 400–1.700 € pro Semester, verteilt auf alle Pro-AI-Kunden (Schätzung, siehe
`docs/SKALIERUNG-GROSS.md`).

## Was bei dir ankommt (je Kunde und Monat, geschätzt)

| | Plus 1,99 € | Pro AI 3,99 € |
| --- | --- | --- |
| nach 19 % MwSt | 1,67 € | 3,35 € |
| nach Apple (15 %) | **1,42 €** | **2,85 €** |
| nach Stripe (Web, ca. 1,5 % + 0,25 €) | **1,39 €** | **3,04 €** |
| deine KI-Kosten | 0 € (eigenes ChatGPT) | ca. 0,20–2,00 € (gedeckelt durch das Budget je Konto) |

## Wo was heute steht

| Teil | Stand |
| --- | --- |
| Tarife, Kontingente (Plus 4, Pro AI 20), Notizen-Abgleich erst mit Pro AI | **umgestellt** in `app/plans.py`, Prüfdaten neu; iPad (`Plans.swift`) muss die Mac-Sitzung nachziehen |
| Karteikarten selbst anlegen | gebaut (iPad, Web, Windows) |
| Karteikarten teilen / nutzen | **im Bau** (Status `coming_soon` bis fertig) |
| KI-Karteikarten nach Fach/Woche/Anzahl | **im Bau** (aus einem Dokument gibt es sie schon) |
| Fertige Wochenfragen mit Erklärungen | **gebaut** im Dienst und in der Web-/Windows-Oberfläche (Status `available`, `docs/BIBLIOTHEK-WOCHENFRAGEN.md`); iPad zieht die Mac-Sitzung nach |
| Pro AI im App Store | erst mit dem Online-Dienst; bis dahin auf der Tarifseite „kommt mit dem StudiNow-Dienst“, ohne Kaufknopf |
