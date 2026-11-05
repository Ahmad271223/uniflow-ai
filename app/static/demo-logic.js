// Demo nur für die Store-Prüfung (Windows/Einzelplatz, 05.11.2026), nach DemoViews.swift / FirstLoginFlow.swift der iPad-App
// (Commit 52b6101, Entscheidung des Inhabers 04.11.2026 "Nur für Prüfer"): normale Nutzer sehen die Demo nirgends. Der EINZIGE
// Weg ist der kleine Textlink "Ohne Hochschulkonto ansehen (Demo)" ganz unten auf der ersten Seite ohne Hochschulverbindung
// (Übersicht, solange nichts verbunden ist). Solange die Demo läuft, steht über jeder Seite eine schmale Leiste mit "Beenden";
// "Beenden" räumt alles weg, was die Demo angelegt hat, und führt zurück zur Übersicht mit dem Link. Reine Regeln und Texte,
// ohne DOM (tests/js/demo.test.mjs); die Oberfläche steht in demo-bar.js, der Inhalt der Demo in app/demo.py.
// Nur im Einzelplatz (Windows-App/PC): im gehosteten Dienst gibt es weder Link noch Leiste.

export const TEXTS = {
  link: "Ohne Hochschulkonto ansehen (Demo)",
  running: "Demo wird angelegt …",
  barTitle: "Demo-Inhalte – erfunden, ohne Hochschule",
  end: "Beenden",
  confirmEnd: "Demo beenden? Das Demo-Modul mit PDFs, Terminen, Lernpaketen und Notizen dazu verschwindet, danach kommt wieder die erste Seite mit der Hochschul-Verbindung.",
  ended: "Demo beendet",
  syncBlocked: "Demo-Inhalte aktiv: StudiNow gleicht nicht mit der Hochschule ab. Zum Anmelden die Demo oben mit „Beenden“ verlassen.",
  welcomeTitle: "Willkommen bei StudiNow",
  welcomeText: "Verbinde deine Hochschule, dann holt StudiNow deine Kurse, Dateien und Termine. Du meldest dich dafür selbst im Fenster deiner Hochschule an. Dein Passwort merkt sich StudiNow nur, wenn du es in den Einstellungen ausdrücklich möchtest.",
  connect: "Hochschule verbinden",
};

/** Meldung nach dem Anlegen: "Demo angelegt: 3 PDFs, 3 Termine, 3 Lernpakete" */
export const installedText = s => `Demo angelegt: ${s?.files ?? 0} ${s?.files === 1 ? "PDF" : "PDFs"}, ${s?.events ?? 0} ${s?.events === 1 ? "Termin" : "Termine"}, ${s?.packages ?? 0} ${s?.packages === 1 ? "Lernpaket" : "Lernpakete"}`;

/**
 * Erste Seite ohne Hochschulverbindung? Nur im Einzelplatz, ohne laufende Demo, ohne gemerkte Sitzung, ohne hinterlegte
 * Zugangsdaten und ohne ein einziges Modul (sonst ist längst etwas da). Fehlende Angaben (Abruf gescheitert) zählen als
 * "nicht anzeigen": lieber kein Link als ein falscher.
 * @param {{hosted?: boolean, demo?: boolean|null, session?: boolean|null, credentials?: boolean|null, modules?: number|null}} c
 */
export function firstStartVisible(c) {
  if (!c || c.hosted) return false;
  if (c.demo !== false || c.session !== false || c.credentials !== false) return false;
  return c.modules === 0;
}

/** Leiste über jeder Seite, solange die Demo läuft */
export function barHtml(icon = () => "") {
  return `<span class="demo-bar-in">${icon("sparkles", 15)}<span class="demo-bar-t">${TEXTS.barTitle}</span><span class="spacer"></span>`
    + `<button type="button" class="btn sm demo-end" id="demoEnd">${icon("log-out", 14)} ${TEXTS.end}</button></span>`;
}

/** Karte ganz unten auf der Übersicht: Verbinden-Hinweis, ganz unten klein der Textlink zur Demo (kein Knopf) */
export function firstStartHtml() {
  return `<section class="card first-start" id="firstStart" aria-labelledby="fsTitle">
    <h2 id="fsTitle">${TEXTS.welcomeTitle}</h2>
    <p>${TEXTS.welcomeText}</p>
    <div class="row"><a class="btn primary" href="#/settings?tab=account">${TEXTS.connect}</a></div>
    <div class="fs-demo"><button type="button" class="fs-demo-link" id="demoStart">${TEXTS.link}</button></div></section>`;
}
