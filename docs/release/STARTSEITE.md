<!-- Startseite von https://studinow.app (tools/gen-site.py baut daraus site/index.html).
     Aufbau wie eine Lernplattform-Startseite (Auftrag des Inhabers vom 05.11.2026): Einstieg, Vertrauensleiste, Uni-Anbindung,
     Funktionen mit Bildschirmfotos (Demo-Inhalte, docs/release/website-img/), drei Schritte, Tarife, Fragen, Abschluss.
     Nur Inhalte, die es in der App wirklich gibt; keine Zahlen über Nutzer, keine Stimmen, keine Hochschul-Logos.
     Seit 05.11.2026 (Wunsch des Inhabers): für Studierende in ganz Deutschland, aber ehrlich – angebunden ist heute nur
     die LUH (nie "alle Hochschulen", Richtlinie 2.3); Abschnitt Mensa. Entscheidung des Inhabers 07.11.2026: Version 1.0
     nur mit der LUH, Hochschule Hannover und Universität Hildesheim folgen "in Kürze" mit 1.0.1 (dann hier wieder als
     angebunden nennen; tests/test_site.py). Seit 16.11.2026 (Version 1.0.4 im App Store, Okay des Inhabers "Ja, Website
     anpassen"): Universität Hildesheim angebunden, iPhone-Fassung da, Knopf führt in den App Store; Hochschule Hannover
     weiter "in Kürze".
     Zahlen im Studienverlauf aus apps/apple/UniFlow/Resources/StudyCatalogSeed/*-index.json (306 Studiengänge und Fächer,
     12 894 Module; docs/STUDIENGAENGE-*.md).
     Bilder in website-img/: Querformat der Store-Bilder (docs/release/SCREENSHOTS.md), sips -Z 1400 -s format jpeg
     -s formatOptions 70 (1400 x 1050).
     26.11.2026 (Auftrag des Inhabers): ausdrücklich "iPad-App, auch auf dem iPhone; Mac, Android und Windows kommen
     demnächst" im Einstieg, in den Fragen und im Abschluss; Abschnitt "Neu in StudiNow".
     26.11.2026 nachmittags (Auftrag des Inhabers "korrigiere selber alles"): Tarife, Funktionen und Fragen wie im
     Release-Zweig (ohne Lernkalender, ohne eigenes ChatGPT, 80 Credits); Probe "einmal je Person".
     :i-name: setzt ein Symbol ein (ICONS in tools/gen-site.py). -->

<details class="news">
<summary><span class="wrap news-head"><span class="news-tag">Neu</span> <span>Die erste Testphase ist abgeschlossen: StudiNow ist jetzt für alle offen.</span> <span class="news-more"><span class="news-open">Mehr dazu</span><span class="news-close">Schließen</span></span></span></summary>
<div class="wrap news-body">
<p>StudiNow ist ein Studentenprojekt, von Studenten für Studenten. Gerade am Anfang kommen regelmäßig System- und
Sicherheitsupdates, weil wir die App ständig verbessern wollen, und die Studienverlaufspläne werden nach und nach
aktualisiert. Fehlt bei deinem Studiengang etwas oder hast du eine Idee? Über Feedback freuen wir uns jederzeit:
<a href="mailto:support@studinow.app">support@studinow.app</a>. Was zuletzt neu war und was als Nächstes kommt,
steht unter <a href="#neu">Neu in StudiNow</a>.</p>
</div>
</details>

<section class="hero" aria-labelledby="hero-title">
<div class="wrap hero-grid">
<div class="hero-text">
<p class="eyebrow">Lernmanagementsystem für Hochschulen in ganz Deutschland</p>
<h1 id="hero-title">Dein Studium an einem Ort.</h1>
<p class="hand-line"><span>Mitschreiben, verstehen, üben.</span></p>
<p class="lead">StudiNow ist ein Lernmanagementsystem für Hochschulen in ganz Deutschland. Es holt Skripte, Übungsblätter, Termine und Nachrichten aus den Systemen deiner Hochschule auf dein
iPad und iPhone. Du schreibst mit dem Apple Pencil, lässt dir ganze Vorlesungen erklären und übst mit Wochentests und Karteikarten.</p>
<p class="unis">:i-tablet: <span><strong>StudiNow ist eine iPad-App</strong> und läuft auch auf dem iPhone.
Mac, Android und Windows kommen demnächst dazu.</span></p>
<p class="unis">:i-cap: <span>Heute angebunden: <strong>Leibniz Universität Hannover</strong> und
<strong>Universität Hildesheim</strong>. Neu: <strong>Universität Göttingen</strong> mit Stud.IP und Mensa. Weitere Hochschulen folgen. Deine fehlt?
<a href="mailto:support@studinow.app">Schreib uns</a>.</span></p>
<div class="cta" id="laden">
<a class="btn btn-store" href="https://apps.apple.com/de/app/id6830632088" aria-describedby="store-note">:i-download: Im App Store laden</a>
<a class="btn btn-ghost" href="#funktionen">Funktionen ansehen</a>
</div>
<p class="note" id="store-note"><strong>Jetzt im App Store</strong> für iPad und iPhone. 7 Tage alles
testen, ohne Zahlungsdaten.</p>
</div>
<figure class="hero-shot">
<div class="device">
<div class="desk" aria-hidden="true">
<p class="idx"><span>13 = 1101<sub>2</sub></span><span>= D<sub>16</sub></span><svg class="doodle doodle-check" viewBox="0 0 40 40"><path d="M5 22l9 11L35 6"/></svg></p>
<div class="bon"><p><strong>Mensa heute</strong><span>Gemüse-Curry</span><span>vegan <b>2,50 €</b></span></p></div>
<p class="acts"><span class="act act-1">:i-book: Erklären</span><span class="act act-2">:i-cards: Karteikarten</span><span class="act act-3">:i-check: Test</span></p>
</div>
<picture><source media="(prefers-color-scheme: dark)" srcset="img/uebersicht-dunkel.jpg"><img src="img/uebersicht-hell.jpg" width="1400" height="1050" alt="StudiNow auf dem iPad: Übersicht mit Begrüßung, der Prüfungsanmeldung, der Karte Heute in der Mensa und dem Lernplan für heute (Demo-Inhalte)"></picture>
</div>
<figcaption><svg class="scribble" viewBox="0 0 64 40" aria-hidden="true" focusable="false"><path d="M4 34c14 0 30-6 42-18 4-4 7-8 9-12M55 4l-11 2M55 4l1 11"/></svg>Deine Übersicht: Prüfungen, Termine und Mensa</figcaption>
</figure>
<svg class="doodle doodle-sum" viewBox="0 0 40 46" aria-hidden="true" focusable="false"><path d="M31 7H10l11 13-11 13h21"/><path d="M6 42c4-3 7 3 11 0s7 3 11 0"/></svg>
<svg class="doodle doodle-curl" viewBox="0 0 48 30" aria-hidden="true" focusable="false"><path d="M3 22c5-13 13-14 13-5s-9 5-5-3 12-11 17-2-4 11-5 2 7-11 13-6 6 9 9 6"/></svg>
</div>
</section>

<div class="ticker" aria-hidden="true">
<ul class="ticker-track"><li>:i-folder: Skripte</li><li>:i-pen: Apple Pencil</li><li>:i-clock: Stundenplan</li><li>:i-mail: Nachrichten</li><li>:i-sparkle: KI-Hilfe</li><li>:i-check: Wochentests</li><li>:i-cards: Karteikarten</li><li>:i-utensils: Mensa</li><li>:i-route: Studienverlauf</li><li>:i-calendar: Prüfungsanmeldung</li><li>:i-upload: Abgeben in Stud.IP</li>
<li>:i-folder: Skripte</li><li>:i-pen: Apple Pencil</li><li>:i-clock: Stundenplan</li><li>:i-mail: Nachrichten</li><li>:i-sparkle: KI-Hilfe</li><li>:i-check: Wochentests</li><li>:i-cards: Karteikarten</li><li>:i-utensils: Mensa</li><li>:i-route: Studienverlauf</li><li>:i-calendar: Prüfungsanmeldung</li><li>:i-upload: Abgeben in Stud.IP</li></ul>
</div>

<section class="trust" aria-label="Was StudiNow verspricht">
<ul class="wrap trust-list">
<li>:i-lock: <span><strong>Kein Uni-Passwort auf unseren Servern.</strong> Du meldest dich bei deiner Hochschule an, nicht bei uns. Wenn du willst, merkt sich nur dein iPad das Passwort.</span></li>
<li>:i-tablet: <span><strong>Deine Daten auf deinem iPad.</strong> Unterlagen, Notizen und Termine liegen lokal.</span></li>
<li>:i-eye-off: <span><strong>Kein Tracking, keine Werbung.</strong> Keine Analyse-Werkzeuge Dritter.</span></li>
<li>:i-cap: <span><strong>Heute für die Leibniz Universität Hannover und die Universität Hildesheim, neu auch für die Universität Göttingen.</strong> Weitere Hochschulen in Deutschland folgen.</span></li>
</ul>
</section>

<section class="section" id="uni" aria-labelledby="uni-title">
<div class="wrap">
<div class="section-head">
<h2 id="uni-title">Alles aus der Uni, ohne fünf Tabs</h2>
<p>Melde dich einmal wie gewohnt an. StudiNow gleicht deine Kurse ab und ordnet alles nach Modulen, das aktuelle
Semester zuerst.</p>
<ul class="systems" aria-label="Angebundene Hochschulsysteme"><li>Stud.IP</li><li>QIS</li><li>Learnweb</li><li>LSF</li></ul>
</div>
<ul class="tiles">
<li>:i-folder: <h3>Unterlagen kommen von selbst</h3><p>Neue Skripte, Folien und Übungsblätter landen im richtigen Modulordner. Erst das aktuelle Semester, ältere folgen im Hintergrund.</p></li>
<li>:i-mail: <h3>Nachrichten beantworten</h3><p>Nachrichten aus Stud.IP lesen und direkt aus der App antworten (Moodle in Kürze).</p></li>
<li>:i-upload: <h3>Abgeben in Stud.IP</h3><p>Deine bearbeitete Übung als PDF dort abgeben, wo der Kurs sie erwartet. Abgeschickt wird erst, wenn du es bestätigst (Moodle in Kürze).</p></li>
<li>:i-clock: <h3>Stundenplan</h3><p>Vorlesungen und Übungen im Wochenraster, am iPhone als Tage oder ganze Woche, mit Hinweisen zu Ausfällen, Fristen und Klausuren.</p></li>
</ul>
<p class="fine" id="goettingen"><strong>Universität Göttingen – neu in StudiNow.</strong> Schon dabei: Stud.IP mit Kursen,
Dateien, Stundenplan, Terminen, Nachrichten, Ankündigungen und Lehrenden, dazu das Schwarze Brett und der Speiseplan der
Mensen (noch ohne Preise). Alle Lernfunktionen von StudiNow gehen wie an jeder anderen Hochschule. Noch nicht dabei: Noten
und Prüfungsanmeldung (FlexNow), Bescheinigungen und Vorlesungsverzeichnis (eCampus), Uni-Mail und
Vorlesungsaufzeichnungen. Wir prüfen gerade, wie wir sie technisch anbinden können, und ergänzen sie, sobald das möglich
ist.</p>
</div>
</section>

<section class="section feature tint" id="funktionen" aria-labelledby="f-ki">
<div class="wrap feature-grid">
<div class="feature-text">
<h2 id="f-ki">Schreib ins Skript, frag die KI daneben</h2>
<p>Mit dem Apple Pencil markierst und rechnest du direkt in Skript und Übungsblatt. Daneben sitzt die KI-Hilfe: Frag zur
offenen Seite oder nimm das ganze Dokument, zum Beispiel „Erkläre die ganze Vorlesung“ oder „Erkläre alle Aufgaben“.</p>
<ul class="checks">
<li>Stift und Textmarker, Übung und Skript nebeneinander, Notizen als PDF</li>
<li>Ein Block je Abschnitt oder je Aufgabe, mit Seitenangabe zum Hinspringen</li>
<li>Bevor ein großer Lauf startet, siehst du, was er kostet</li>
</ul>
<p class="fine">Die KI-Hilfe ist freiwillig. Nur was du ihr schickst, verlässt dein iPad.</p>
</div>
<figure class="shot">
<div class="device">
<picture><source media="(prefers-color-scheme: dark)" srcset="img/ki-dokument-dunkel.jpg"><img src="img/ki-dokument-hell.jpg" width="1400" height="1050" loading="lazy" decoding="async" alt="Skript mit Handschrift im Editor, links die KI-Hilfe mit „Ganze Vorlesung erklären“ und einer Erklärung je Abschnitt mit Seitenangabe (Demo-Inhalte)"></picture>
</div>
</figure>
</div>
</section>

<section class="section feature alt" aria-labelledby="f-verlauf">
<div class="wrap feature-grid">
<div class="feature-text">
<h2 id="f-verlauf">Studienverlauf und Prüfungsanmeldung im Blick</h2>
<p>StudiNow bringt die Modulkataloge von über 300 Studiengängen und Fächern mit: an der Leibniz Universität Hannover
und der Universität Hildesheim. Du siehst deine Leistungspunkte, was in deinem
Plan als Nächstes kommt und welche Prüfungen du im Meldezeitraum anmelden solltest.</p>
<ul class="checks">
<li>Leistungspunkte und Semesterplan aus deinem Modulkatalog</li>
<li>Melde- und Prüfungszeiträume mit Erinnerung, Klausurtermine im Kalender</li>
<li>Ein Tipp öffnet die Anmeldung im Prüfungssystem deiner Hochschule, bestätigen tust du dort selbst</li>
</ul>
<p class="fine">Verbindlich sind immer die Prüfungsordnung und die Systeme deiner Hochschule.</p>
</div>
<figure class="shot">
<div class="device">
<picture><source media="(prefers-color-scheme: dark)" srcset="img/studienverlauf-dunkel.jpg"><img src="img/studienverlauf-hell.jpg" width="1400" height="1050" loading="lazy" decoding="async" alt="Studienverlauf Informatik B.Sc. mit 59 von 180 Leistungspunkten und der Karte Prüfungsanmeldung mit Meldezeiträumen und vier Prüfungen (Demo-Inhalte)"></picture>
</div>
</figure>
</div>
</section>

<section class="section feature tint" aria-labelledby="f-karten">
<div class="wrap feature-grid">
<div class="feature-text">
<h2 id="f-karten">Wochentests und Karteikarten, die mitlernen</h2>
<p>Jede Vorlesungswoche ein kurzer Test, mit Erklärung zu jeder Antwort. Karteikarten sortierst du in Stapel je Modul,
StudiNow fragt fällige Karten zuerst ab: richtig heißt seltener, falsch heißt morgen wieder.</p>
<ul class="checks">
<li>Lernstand je Modul aus deinen Tests und Karteikarten</li>
<li>Stapel je Lernwoche teilen und die anderer übernehmen</li>
<li>Lösungen zu Übungsblättern mit anderen aus dem Kurs vergleichen</li>
</ul>
</div>
<figure class="shot">
<div class="device">
<picture><source media="(prefers-color-scheme: dark)" srcset="img/wochentest-dunkel.jpg"><img src="img/wochentest-hell.jpg" width="1400" height="1050" loading="lazy" decoding="async" alt="Ergebnis eines Wochentests zu Zahlensystemen: 75 Prozent, drei von vier Aufgaben richtig, mit Erklärung zur Lösung (Demo-Inhalte)"></picture>
</div>
</figure>
</div>
</section>

<section class="section try" id="ausprobieren" aria-labelledby="try-title">
<div class="wrap">
<div class="section-head">
<h2 id="try-title">Probier es gleich hier aus</h2>
<p>Eine Karteikarte und eine Testfrage zum Antippen, mit Beispiel-Inhalten aus einer Vorlesung über Zahlensysteme.</p>
</div>
<div class="try-grid">
<details class="flip">
<summary><span class="try-label">Karteikarte</span><span class="flip-q">Was ist 13 im Dualsystem?</span><span class="flip-hint">:i-flip: Antippen zum Umdrehen</span></summary>
<div class="flip-back">
<p class="try-label">Antwort</p>
<p class="flip-a">1101</p>
<p>8 + 4 + 0 + 1 = 13. In der App gilt: richtig heißt seltener, falsch heißt morgen wieder.</p>
</div>
</details>
<div class="quiz" role="group" aria-labelledby="quiz-q">
<p class="try-label">Wochentest</p>
<p class="quiz-q" id="quiz-q">Welche Zahl ist D im Hexadezimalsystem?</p>
<details class="opt no" name="quiz"><summary>11</summary><p>Noch nicht. 11 ist B. Zähl von A = 10 weiter.</p></details>
<details class="opt yes" name="quiz"><summary>13</summary><p>Richtig. A = 10, B = 11, C = 12, D = 13.</p></details>
<details class="opt no" name="quiz"><summary>15</summary><p>Noch nicht. 15 ist F, die letzte Ziffer.</p></details>
</div>
</div>
</div>
</section>

<section class="section feature alt" id="mensa" aria-labelledby="f-mensa">
<div class="wrap feature-grid">
<div class="feature-text">
<h2 id="f-mensa">Was gibt’s heute in der Mensa?</h2>
<p>Der Speiseplan deiner Mensa steht in StudiNow, mit den Preisen für deine Gruppe: Studierende, Bedienstete oder Gäste.
Auf der Übersicht zeigt dir die Karte „Heute in der Mensa“ die Hauptgerichte des Tages.</p>
<ul class="checks">
<li>Heute, morgen oder die ganze Woche, Mensa wechseln und Favoriten merken</li>
<li>Nährwerte, Allergene und Kennzeichen zu jedem Gericht</li>
<li>Filter für vegan, vegetarisch und ohne bestimmte Allergene</li>
</ul>
<p class="fine">Speisepläne vom Studentenwerk Hannover, vom Studierendenwerk OstNiedersachsen und vom Studierendenwerk Göttingen,
für die Mensen in Hannover, Hildesheim und Göttingen (Göttingen noch ohne Preise). Angaben ohne Gewähr, verbindlich ist der Aushang vor Ort. In jedem Tarif frei.</p>
</div>
<figure class="shot">
<div class="device">
<picture><source media="(prefers-color-scheme: dark)" srcset="img/mensa-dunkel.jpg"><img src="img/mensa-hell.jpg" width="1400" height="1050" loading="lazy" decoding="async" alt="Mensa-Seite mit dem Speiseplan von heute: Gerichte mit Preis für Studierende, Kennzeichen wie vegan und Nährwerten (Demo-Inhalte)"></picture>
</div>
</figure>
</div>
</section>

<section class="section tint" id="neu" aria-labelledby="neu-title">
<div class="wrap">
<div class="section-head">
<h2 id="neu-title">Neu in StudiNow</h2>
<p>StudiNow bekommt regelmäßig Updates. Hier steht, was zuletzt dazugekommen ist, was wir behoben haben und woran wir
gerade arbeiten.</p>
<p><strong>Über 500 Downloads – danke!</strong> Schön, dass du dabei bist.</p>
</div>
<div class="updates">
<article class="update" aria-labelledby="u-jetzt">
<p class="update-tag update-live">Jetzt im App Store</p>
<h3 id="u-jetzt">Version 1.0.8</h3>
<p class="when">Erschienen am [[DATUM]]</p>
<h4>Neu dabei</h4>
<ul class="checks">
<li><strong>Neue Tarife:</strong> StudiNow Plus für 1,99 € im Monat, Pro AI für 3,99 € im Monat oder 39,99 € im Jahr
mit 120 KI-Credits jeden Monat – und als Special das <strong>Bachelor+Master-Paket</strong>: Plus für 5 Jahre, einmal
39,99 €, ohne Abo</li>
<li><strong>Universität Göttingen</strong> ist angebunden: Stud.IP mit Kursen, Dateien und Stundenplan, dazu das
Schwarze Brett und die Mensa. Weitere Funktionen folgen, sobald sie technisch möglich sind.</li>
<li><strong>Mitschrift für Vorlesungsvideos:</strong> Aufzeichnungen deiner Uni und eigene Aufnahmen werden direkt auf
dem Gerät zu Text. Du suchst darin und springst an die passende Stelle im Video.</li>
<li><strong>Tippen wie in Word:</strong> Textblöcke mit Schriftarten und Formatleiste, auf linierten Seiten immer genau
auf der Zeile</li>
<li><strong>Notizzettel, Klappkarten und Verweise</strong> direkt auf der Seite</li>
<li><strong>Abgleich zweimal am Tag</strong> von selbst, die Uni-Mail alle 30 Minuten – das schont dein Uni-Konto</li>
</ul>
<h4>Behoben und verbessert</h4>
<ul class="checks">
<li>Schreiben bei starkem Zoom: Die Schrift zittert nicht mehr</li>
<li>Die aufgelegte Hand verschiebt die Seite beim Schreiben nicht mehr</li>
<li>Studienverlauf: Leistungspunkte werden richtig gezählt</li>
<li>Universität Hildesheim: klarer Hinweis, wenn dein LSF-Konto als Gastkonto keinen Stundenplan und keine Noten hat</li>
<li>Auf manchen Geräten ließ sich nach dem Start kein Fenster mehr öffnen – behoben</li>
</ul>
<p class="fine">Du hast StudiNow schon? Dann hol dir das Update im
<a href="https://apps.apple.com/de/app/id6830632088">App Store</a>.</p>
</article>
<article class="update update-next" aria-labelledby="u-bald">
<p class="update-tag">In Arbeit</p>
<h3 id="u-bald">Das nächste Update</h3>
<p class="when">Daran arbeiten wir gerade</p>
<h4>Neue Funktionen</h4>
<ul class="checks planned">
<li><strong>Tabellen</strong> direkt im Dokument, mit Pro AI</li>
<li><strong>Universität Göttingen:</strong> Uni-Mail und deine Prüfungsanmeldungen aus FlexNow</li>
</ul>
<p class="fine">Das ist eine Vorschau. Bis zur Veröffentlichung kann sich noch etwas ändern, auch in welchem Tarif eine
Funktion enthalten ist. Fehlt dir etwas? Schreib uns an <a href="mailto:support@studinow.app">support@studinow.app</a>.</p>
</article>
<article class="update update-next" aria-labelledby="u-hochschulen">
<p class="update-tag">Geplant</p>
<h3 id="u-hochschulen">Weitere Hochschulen</h3>
<p class="when">Als Nächstes</p>
<ul class="checks planned">
<li><strong>TU Hamburg, Universität Hamburg, TU Braunschweig und TU Berlin</strong> im kommenden Monat</li>
</ul>
<p class="fine">StudiNow ist ein unabhängiges Angebot und keine offizielle App der Hochschulen. Deine Hochschule fehlt?
Schreib uns an <a href="mailto:support@studinow.app">support@studinow.app</a>.</p>
</article>
</div>
</div>
</section>

<section class="section steps-band" id="so-gehts" aria-labelledby="steps-title">
<div class="wrap">
<div class="section-head">
<h2 id="steps-title">In drei Schritten startklar</h2>
</div>
<ol class="steps">
<li><h3>StudiNow laden</h3><p>Die App aus dem App Store aufs iPad holen. Die ersten 7 Tage ist alles frei.</p></li>
<li><h3>Bei der Uni anmelden</h3><p>Das Anmeldefenster deiner Hochschule öffnet sich. Dein Passwort gibst du dort ein, StudiNow speichert es nicht.</p></li>
<li><h3>Loslernen</h3><p>Kurse, Unterlagen und Termine sind da. Plan deine Woche, schreib ins Skript, üb mit Karten.</p></li>
</ol>
</div>
</section>

<section class="section tint" id="preise" aria-labelledby="preise-title">
<div class="wrap">
<div class="section-head">
<h2 id="preise-title">Preise</h2>
<p>Zum Start testest du 7 Tage alles wie StudiNow Plus, dazu 25 Credits für die KI, ohne Zahlungsdaten (einmal je iPad). Danach wählst du: Free bleibt kostenlos, oder Plus bzw. Pro AI – deine Daten bleiben.</p>
</div>
<div class="plans plans-solo">
<article class="plan plan-special" aria-labelledby="p-paket">
<p class="special-badge">Unser Special</p>
<h3 id="p-paket">Bachelor+Master-Paket</h3>
<p class="special-sub">StudiNow Plus für 5 Jahre</p>
<p class="price"><span class="amount">39,99 €</span> <span class="per">einmalig</span></p>
<p class="save save-big">Du sparst 79,41 € (67 %)</p>
<p class="save-detail">gegenüber 60 × 1,99 € = 119,40 € mit dem normalen Plus – das sind nur 0,67 € im Monat</p>
<ul class="checks">
<li>Alle Funktionen von Plus, 5 Jahre lang</li>
<li>Einmal zahlen – kein Abo, verlängert sich nicht, endet von selbst</li>
<li>Reicht für Bachelor und Master</li>
<li>KI von StudiNow mit Credits, die du dazukaufst</li>
</ul>
</article>
</div>
<p class="plans-group">Monatlich</p>
<div class="plans">
<article class="plan" aria-labelledby="p-free">
<h3 id="p-free">StudiNow Free</h3>
<p class="price"><span class="amount">0 €</span></p>
<p class="tagline">Studium organisieren und Unterlagen lesen</p>
<ul class="checks">
<li>Abgleich mit deiner Hochschule: Kurse, Ordner, neue Dateien</li>
<li>PDFs öffnen, lesen und durchsuchen</li>
<li>Module und Stundenplan mit Hinweisen zu Terminen, Fristen und Klausuren</li>
<li>Uni-Mail, Noten, Mensa und Raumfinder (je nach Hochschule)</li>
<li>Lernblöcke selbst planen, Zeitmesser</li>
<li>Notizen ansehen und als PDF exportieren</li>
<li>Widgets für den nächsten Termin und die Mensa</li>
</ul>
</article>
<article class="plan" aria-labelledby="p-plus">
<h3 id="p-plus">StudiNow Plus</h3>
<p class="price"><span class="amount">1,99 €</span> <span class="per">im Monat</span></p>
<p class="tagline">Alles aus Free, dazu alle Funktionen ohne KI:</p>
<ul class="checks">
<li>Schreiben mit dem Apple Pencil</li>
<li>Text wie in Word, Notizzettel, Klappkarten, Tabellen</li>
<li>Übung und Skript nebeneinander</li>
<li>Lesezeichen setzen, Seiten einfügen und ordnen</li>
<li>Eigene Karteikarten mit Stapeln und Lernstand je Modul</li>
<li>Community deines Kurses: lesen, fragen, Lösungen teilen</li>
<li>Geteilte Tests und Karteikarten-Stapel ohne Monatsgrenze</li>
<li>Notizen auf deinen Hochschul-PDFs auf allen deinen Geräten</li>
<li>Erinnerungen an Abgaben und Klausuren</li>
<li>KI von StudiNow mit Credits, die du dazukaufst</li>
</ul>
</article>
<article class="plan plan-top" aria-labelledby="p-pro">
<h3 id="p-pro">StudiNow Pro AI</h3>
<p class="price"><span class="amount">3,99 €</span> <span class="per">im Monat</span></p>
<p class="tagline">Alles aus Plus, dazu jeden Monat Credits für die KI:</p>
<ul class="checks">
<li>120 Credits jeden Monat neu, weitere zum Nachkaufen</li>
<li>KI-Erklärungen, auch für das ganze Dokument</li>
<li>Zusammenfassungen und Lernfragen zu deinen Unterlagen</li>
<li>Wochentests aus deinen Unterlagen: bis zu 20 neue KI-Tests im Monat</li>
<li>Karteikarten aus deinen Unterlagen erstellen lassen</li>
<li>Uni-Mails mit KI verbessern</li>
</ul>
</article>
</div>
<div class="plans plans-solo">
<article class="plan" aria-labelledby="p-pro-jahr">
<p class="plans-group in-card">Jährlich</p>
<h3 id="p-pro-jahr">StudiNow Pro AI</h3>
<p class="price"><span class="amount">39,99 €</span> <span class="per">pro Jahr</span></p>
<p class="save">Du sparst 7,89 € (16 %) gegenüber 12 × 3,99 € = 47,88 €</p>
<p class="tagline">Alles aus Pro AI monatlich – nur rund 3,33 € im Monat:</p>
<ul class="checks">
<li>Alle Funktionen von Plus</li>
<li>120 Credits jeden Monat neu, auch im Jahresabo</li>
<li>Alle KI-Funktionen von StudiNow</li>
</ul>
</article>
</div>
<p class="fine">Preise inkl. USt. Die KI von StudiNow funktioniert nur mit Credits: Pro AI bringt jeden Monat 120 mit, mit Plus kaufst du
sie in der App dazu (in Free nicht). Plus und Pro AI im Monat verlängern sich um einen Monat, Pro AI im Jahr um ein Jahr, wenn du
das Abo nicht mindestens 24 Stunden vor Ablauf in den Einstellungen deines Apple-Kontos kündigst. Das Bachelor+Master-Paket zahlst du
einmal; es endet 5 Jahre nach dem Kauf von selbst. Nach dem Ende bleiben alle Notizen lesbar und exportierbar. „Ohne Monatsgrenze“
heißt faire Nutzung, höchstens 300 im Monat. StudiNow arbeitet nicht mit der LUH oder einer anderen Hochschule zusammen; die
Anbindung an Hochschulsysteme ist nicht zugesichert. Einzelheiten in den <a href="https://studinow.app/nutzungsbedingungen">Nutzungsbedingungen</a>.</p>
</div>
</section>

<section class="section faq" id="fragen" aria-labelledby="faq-title">
<div class="wrap faq-grid">
<div class="section-head">
<h2 id="faq-title">Häufige Fragen</h2>
<p>Mehr Antworten auf der <a href="https://studinow.app/support">Support-Seite</a> oder per E-Mail an
<a href="mailto:support@studinow.app">support@studinow.app</a>.</p>
</div>
<div class="faq-list">
<details>
<summary>Speichert StudiNow mein Uni-Passwort?</summary>
<p>Nicht auf unseren Servern. Du gibst es im Anmeldefenster deiner Hochschule ein. Lässt du „Passwort auf diesem iPad
merken“ an, liegt es nur im Schlüsselbund dieses iPads (nicht in iCloud), damit StudiNow dich nach Ablauf einer Sitzung
wieder anmeldet – abschaltbar und jederzeit löschbar.</p>
</details>
<details>
<summary>Wo liegen meine Daten?</summary>
<p>Auf deinem iPad. Dateien, Termine, Notizen und Stundenplan speichert die App lokal. Die Systeme deiner
Hochschule liest das iPad direkt. Was die KI-Hilfe bekommt, steht in der <a href="https://studinow.app/datenschutz">Datenschutzerklärung</a>.</p>
</details>
<details>
<summary>Was passiert nach den 7 Tagen?</summary>
<p>Dann wählst du einmal: „Bei Free bleiben“ (kostenlos, ohne Kauf) oder Plus bzw. Pro AI. Die Probe wird nie von selbst kostenpflichtig, und alles, was
du angelegt hast, bleibt da.</p>
</details>
<details>
<summary>Für welche Hochschulen ist StudiNow?</summary>
<p>StudiNow ist ein Lernmanagementsystem für Hochschulen in ganz Deutschland – zum Start mit voller Anbindung an die Leibniz Universität Hannover
(Stud.IP, QIS) und die Universität Hildesheim (Learnweb, LSF), mit den Modulkatalogen der Studiengänge und dem Speiseplan
der Mensen. Weitere Hochschulen folgen. Deine
fehlt? Schreib uns an <a href="mailto:support@studinow.app">support@studinow.app</a>.</p>
<p>StudiNow ist ein unabhängiges Angebot und arbeitet nicht mit der Leibniz Universität Hannover (LUH) oder einer anderen
Hochschule zusammen. Ändert oder sperrt eine Hochschule ihre Systeme, kann die Anbindung wegfallen; die Funktionen der
App bleiben. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.</p>
</details>
<details>
<summary>Gibt es StudiNow fürs iPhone?</summary>
<p>Ja. Am iPhone liest du Unterlagen und siehst Stundenplan, Nachrichten, Uni-Mail,
Noten und Mensa. Geschrieben wird mit dem Apple Pencil weiter am iPad. StudiNow Free gilt für ein Gerät; mit Plus oder
Pro AI nutzt du iPhone und iPad zusammen.</p>
</details>
<details>
<summary>Gibt es StudiNow für Mac, Android oder Windows?</summary>
<p>Noch nicht. StudiNow ist heute eine iPad-App, die du auch auf dem iPhone nutzen kannst. Mac, Android und Windows
kommen demnächst dazu.</p>
</details>
<details>
<summary>Wie kündige ich ein Abo?</summary>
<p>In den Abo-Einstellungen deines Apple-Kontos. Rechnungen und Rückerstattungen laufen über Apple. Wie du dein
StudiNow-Konto löschst, steht unter <a href="https://studinow.app/konto-loeschen">Konto löschen</a>.</p>
</details>
</div>
</div>
</section>

<section class="closing" aria-labelledby="closing-title">
<div class="wrap closing-inner">
<h2 id="closing-title">Hol dir dein Semester aufs iPad.</h2>
<div class="cta">
<a class="btn btn-store btn-invert" href="https://apps.apple.com/de/app/id6830632088" aria-describedby="closing-note">:i-download: Im App Store laden</a>
</div>
<p class="note" id="closing-note">Für iPad und iPhone. Mac, Android und Windows kommen demnächst. Fragen vorab: support@studinow.app</p>
</div>
</section>
