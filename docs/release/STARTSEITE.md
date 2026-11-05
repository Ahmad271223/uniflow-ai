<!-- Startseite von https://studinow.app (tools/gen-site.py baut daraus site/index.html).
     Aufbau wie eine Lernplattform-Startseite (Auftrag des Inhabers vom 05.11.2026): Einstieg, Vertrauensleiste, Uni-Anbindung,
     Funktionen mit Bildschirmfotos (Demo-Inhalte, docs/release/website-img/), drei Schritte, Tarife, Fragen, Abschluss.
     Nur Inhalte, die es in der App wirklich gibt; keine Zahlen über Nutzer, keine Stimmen, keine Hochschul-Logos.
     :i-name: setzt ein Symbol ein (ICONS in tools/gen-site.py). -->

<section class="hero" aria-labelledby="hero-title">
<div class="wrap hero-grid">
<div class="hero-text">
<h1 id="hero-title">Dein Studium an einem Ort.</h1>
<p class="lead">StudiNow holt Skripte, Übungsblätter, Termine und Nachrichten aus Stud.IP und QIS auf dein iPad. Du schreibst
mit dem Apple Pencil, lässt dir ganze Vorlesungen erklären und übst mit Wochentests und Karteikarten.</p>
<div class="cta" id="laden">
<a class="btn btn-store" href="#" aria-describedby="store-note">:i-download: Im App Store laden</a>
<a class="btn btn-ghost" href="#funktionen">Funktionen ansehen</a>
</div>
<p class="note" id="store-note"><strong>Bald verfügbar</strong> für das iPad, die iPhone-Version kommt bald. 7 Tage alles
testen, ohne Zahlungsdaten.</p>
</div>
<figure class="hero-shot">
<div class="device">
<picture><source media="(prefers-color-scheme: dark)" srcset="img/uebersicht-dunkel.jpg"><img src="img/uebersicht-hell.jpg" width="1400" height="1050" alt="StudiNow auf dem iPad: Übersicht mit der Prüfungsanmeldung, dem Lernplan für heute und den nächsten Terminen (Demo-Inhalte)"></picture>
</div>
<figcaption><svg class="scribble" viewBox="0 0 64 40" aria-hidden="true" focusable="false"><path d="M4 34c14 0 30-6 42-18 4-4 7-8 9-12M55 4l-11 2M55 4l1 11"/></svg>Deine Übersicht: Prüfungen, Lernplan und Termine</figcaption>
</figure>
</div>
</section>

<section class="trust" aria-label="Was StudiNow verspricht">
<ul class="wrap trust-list">
<li>:i-lock: <span><strong>Kein Uni-Passwort gespeichert.</strong> Du meldest dich bei deiner Hochschule an, nicht bei uns.</span></li>
<li>:i-tablet: <span><strong>Deine Daten auf deinem iPad.</strong> Unterlagen, Notizen und Termine liegen lokal.</span></li>
<li>:i-eye-off: <span><strong>Kein Tracking, keine Werbung.</strong> Keine Analyse-Werkzeuge Dritter.</span></li>
<li>:i-cap: <span><strong>Zuerst für die Leibniz Universität Hannover.</strong> Weitere Hochschulen folgen.</span></li>
</ul>
</section>

<section class="section" id="uni" aria-labelledby="uni-title">
<div class="wrap">
<div class="section-head">
<h2 id="uni-title">Alles aus der Uni, ohne fünf Tabs</h2>
<p>Melde dich einmal wie gewohnt an. StudiNow gleicht deine Kurse ab und ordnet alles nach Modulen.</p>
<ul class="systems" aria-label="Angebundene Hochschulsysteme"><li>Stud.IP</li><li>QIS</li></ul>
</div>
<ul class="tiles">
<li>:i-folder: <h3>Unterlagen kommen von selbst</h3><p>Neue Skripte, Folien und Übungsblätter aus deinen Kursen landen im richtigen Modulordner.</p></li>
<li>:i-mail: <h3>Stud.IP-Nachrichten</h3><p>Nachrichten lesen und direkt aus der App antworten.</p></li>
<li>:i-upload: <h3>Abgeben in Stud.IP</h3><p>Deine bearbeitete Übung als PDF dort abgeben, wo der Kurs sie erwartet.</p></li>
<li>:i-clock: <h3>Stundenplan und Lernkalender</h3><p>Vorlesungen und Übungen im Wochenraster, Lernpakete in deinen freien Zeitfenstern.</p></li>
</ul>
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
<p>StudiNow kennt die Modulkataloge aller Studiengänge der LUH. Du siehst deine Leistungspunkte, was in deinem Plan als
Nächstes kommt und welche Prüfungen du im Meldezeitraum anmelden solltest.</p>
<ul class="checks">
<li>Leistungspunkte und Semesterplan aus deinem Modulkatalog</li>
<li>Melde- und Prüfungszeiträume mit Erinnerung, Klausurtermine im Kalender</li>
<li>Ein Tipp öffnet die Anmeldung im QIS, bestätigen tust du dort selbst</li>
</ul>
<p class="fine">Verbindlich sind immer die Prüfungsordnung und die Systeme deiner Hochschule.</p>
</div>
<figure class="shot">
<div class="device">
<picture><source media="(prefers-color-scheme: dark)" srcset="img/studienverlauf-dunkel.jpg"><img src="img/studienverlauf-hell.jpg" width="1400" height="1050" loading="lazy" decoding="async" alt="Studienverlauf Informatik B.Sc. mit 49 von 180 Leistungspunkten und der Karte Prüfungsanmeldung mit Meldezeiträumen und vier Prüfungen (Demo-Inhalte)"></picture>
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
<li>Lernstand je Modul aus Tests, Karten und Aufgaben</li>
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
<p>Zum Start testest du 7 Tage alles wie StudiNow Pro AI, ohne Zahlungsdaten. Danach gilt Free, deine Daten bleiben.</p>
</div>
<div class="plans">
<article class="plan" aria-labelledby="p-free">
<h3 id="p-free">StudiNow Free</h3>
<p class="price"><span class="amount">0 €</span></p>
<p class="tagline">Studium organisieren und Unterlagen lesen</p>
<ul class="checks">
<li>Abgleich mit Stud.IP und QIS</li>
<li>PDFs lesen, durchsuchen, Lesezeichen</li>
<li>Stundenplan, Lernkalender und Lernplanung</li>
<li>Lernstand je Modul</li>
<li>Community lesen</li>
</ul>
</article>
<article class="plan" aria-labelledby="p-plus">
<h3 id="p-plus">StudiNow Plus</h3>
<p class="price"><span class="amount">1,99 €</span> <span class="per">pro Monat</span></p>
<p class="tagline">Alles aus Free, dazu:</p>
<ul class="checks">
<li>Schreiben mit dem Apple Pencil</li>
<li>Übung und Skript nebeneinander</li>
<li>Eigene Karteikarten mit Stapeln</li>
<li>Wochentests</li>
<li>Lösungen teilen, in der Community schreiben</li>
</ul>
</article>
<article class="plan plan-top" aria-labelledby="p-pro">
<h3 id="p-pro">StudiNow Pro AI</h3>
<p class="price"><span class="amount">3,99 €</span> <span class="per">pro Monat</span></p>
<p class="tagline">Alles aus Plus, dazu die KI von StudiNow, ohne eigenes ChatGPT-Konto:</p>
<ul class="checks">
<li>KI-Erklärungen, auch für das ganze Dokument</li>
<li>Fertige Fragen zu jeder Vorlesungswoche</li>
<li>Karteikarten aus deinen Unterlagen erstellen lassen</li>
<li>Notizen auf allen deinen Geräten</li>
</ul>
</article>
</div>
<p class="fine">Preise inkl. USt. Ein Abo verlängert sich automatisch um einen Monat, wenn du es nicht mindestens 24 Stunden
vor Ende des laufenden Zeitraums in den Einstellungen deines Apple-Kontos kündigst. Nach dem Ende eines Abos bleiben alle
Notizen lesbar und exportierbar. Einzelheiten in den <a href="https://studinow.app/nutzungsbedingungen">Nutzungsbedingungen</a>.</p>
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
<p>Nein. Du gibst es im Anmeldefenster deiner Hochschule ein. StudiNow behält nur die Sitzung, bis du dich abmeldest
oder die Hochschule sie beendet. Auf Wunsch merkt sich iOS das Passwort im Schlüsselbund.</p>
</details>
<details>
<summary>Wo liegen meine Daten?</summary>
<p>Auf deinem iPad. Dateien, Termine, Notizen, Stundenplan und Lernkalender speichert die App lokal. Die Systeme deiner
Hochschule liest das iPad direkt. Was die KI-Hilfe bekommt, steht in der <a href="https://studinow.app/datenschutz">Datenschutzerklärung</a>.</p>
</details>
<details>
<summary>Was passiert nach den 7 Tagen?</summary>
<p>Dann gilt StudiNow Free, ohne dass du etwas tun musst. Die Probe wird nie von selbst kostenpflichtig, und alles, was
du angelegt hast, bleibt da.</p>
</details>
<details>
<summary>Für welche Hochschulen ist StudiNow?</summary>
<p>Zuerst für die Leibniz Universität Hannover mit Stud.IP und QIS, inklusive der Modulkataloge aller Studiengänge.
StudiNow ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und
Noten sind immer die Systeme deiner Hochschule.</p>
</details>
<details>
<summary>Gibt es StudiNow fürs iPhone?</summary>
<p>Bald. Die App startet auf dem iPad, die iPhone-Version folgt.</p>
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
<a class="btn btn-store btn-invert" href="#" aria-describedby="closing-note">:i-download: Im App Store laden</a>
</div>
<p class="note" id="closing-note">Bald verfügbar. Fragen vorab: support@studinow.app</p>
</div>
</section>
