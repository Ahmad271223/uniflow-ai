// Seite "Nachrichten" (Windows, 05.11.2026) ohne Browser: dieselben Regeln und Texte wie MessagesPage.swift / MessagesInbox.swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as L from "../../app/static/messages-logic.js";

const icon = n => `<i data-i="${n}"></i>`;
const TODAY = "2026-11-05";

test("neu: ohne Marke alles, sonst nach Zeitpunkt (Zeitzonen), ohne Zeitpunkt nach Text", () => {
  assert.equal(L.isNew("2026-11-02T08:00:00+01:00", null), true);
  assert.equal(L.isNew("", "2026-11-02T08:00:00+01:00"), false);
  assert.equal(L.isNew("2026-11-02T07:30:00+00:00", "2026-11-02T08:00:00+01:00"), true, "07:30 UTC liegt nach 07:00 UTC");
  assert.equal(L.isNew("2026-11-02T08:00:00+01:00", "2026-11-02T07:00:00+00:00"), false, "gleicher Zeitpunkt");
  assert.equal(L.isNew("zzz", "aaa"), true);
  assert.equal(L.isNew("aaa", "zzz"), false);
  assert.equal(L.newCount([{ sent_at: "2026-11-04T10:00:00+01:00" }, { sent_at: "2026-10-01T10:00:00+02:00" }], "2026-11-01T00:00:00+01:00"), 1);
  assert.equal(L.instant("2026-11-02T08:15:00"), null, "ohne Zeitzone nicht vergleichbar");
  assert.notEqual(L.instant("2026-11-02T08:15:00+01:00"), null);
});

test("Zahl am Menüpunkt: leer bei 0, 99+ ab 100, Beschriftung Einzahl/Mehrzahl", () => {
  assert.equal(L.badgeText(0), "");
  assert.equal(L.badgeText(7), "7");
  assert.equal(L.badgeText(100), "99+");
  assert.equal(L.badgeLabel(1), "1 neue Nachricht");
  assert.equal(L.badgeLabel(3), "3 neue Nachrichten");
  assert.equal(L.countText(1), "1 Nachricht");
  assert.equal(L.countText(4), "4 Nachrichten");
});

test("Zeiten: heute Uhrzeit, gestern, sonst Wochentag; volles Datum mit Uhr", () => {
  assert.equal(L.listTime("2026-11-05T09:15:00+01:00", TODAY), "09:15");
  assert.equal(L.listTime("2026-11-04T09:15:00+01:00", TODAY), "gestern");
  assert.equal(L.listTime("2026-10-31T09:15:00+01:00", TODAY), "Sa., 31.10.");
  assert.equal(L.fullDate("2026-11-02T08:15:00+01:00"), "Mo., 02.11.2026, 08:15 Uhr");
  assert.equal(L.fullDate("2026-11-02"), "Mo., 02.11.2026");
  assert.equal(L.fullDate(null), "");
  assert.equal(L.syncLine(null), "Noch nicht mit Stud.IP abgeglichen");
  assert.equal(L.syncLine("2026-11-04T09:30:00+00:00"), "Zuletzt abgeglichen: 04.11.2026, 09:30 Uhr");
});

test("Chips: erkannte Tage mit Art, Uhrzeit, vergangene gedämpft, ohne Doppelte", () => {
  const m = { dates: [{ date: "2026-11-19", time: "12:00", kind: "frist" }, { date: "2026-11-19", time: "12:00", kind: "frist" },
    { date: "2026-11-03", time: null, kind: "ausfall" }, { date: "2026-11-25", kind: "pruefung" }, { date: "kaputt" }, null] };
  const cs = L.chips(m, TODAY);
  assert.deepEqual(cs.map(c => c.label), ["Frist 19.11., 12:00", "Ausfall? 03.11.", "Prüfung 25.11."]);
  assert.deepEqual(cs.map(c => c.tone), ["warn", "neutral", "bad"], "vergangen = neutral");
});

test("Liste: Betreff ganz, Punkt nur bei neuen, markierte Zeile, Beschriftung für Bedienungshilfen", () => {
  const msgs = [
    { id: "a", sender: "Lehrende", subject: "Tutorium entfällt am Donnerstag, bitte Blatt 3 allein bearbeiten und den Rest der Woche beachten", sent_at: "2026-11-05T08:15:00+01:00", dates: [{ date: "2026-11-12", kind: "ausfall" }] },
    { id: "b", sender: "", subject: "", sent_at: "2026-10-01T08:15:00+02:00", dates: [] },
  ];
  const html = L.listHtml(msgs, { selected: "a", mark: "2026-10-15T00:00:00+02:00", today: TODAY });
  assert.equal((html.match(/class="msg-row/g) || []).length, 2);
  assert.match(html, /msg-row on fresh" data-id="a"/);
  assert.match(html, /class="msg-row" data-id="b"/, "alt: kein Punkt, nicht gewählt");
  assert.match(html, /Rest der Woche beachten<\/span>/, "ganzer Betreff, nie abgeschnitten");
  assert.match(html, /\(ohne Betreff\)/);
  assert.match(html, /Stud\.IP<\/b>/, "ohne Absender: Stud.IP");
  assert.match(html, /Ausfall\? 12\.11\./);
  assert.equal(L.rowLabel(msgs[0], true, TODAY).startsWith("Neu, Tutorium entfällt"), true);
  assert.equal(L.rowLabel({ subject: "X", sender: "Lehrende", sent_at: "2026-11-05T08:15:00+01:00" }, false, TODAY), "X, von Lehrende, 08:15");
});

test("Lesebereich: ganzer Text escaped, Chips, nur http(s)-Link nach Stud.IP, Datenschutzhinweis", () => {
  const m = { id: "a", sender: "Verwaltung", subject: "A <b>fett</b> & \"zitiert\"", sent_at: "2026-11-02T08:15:00+01:00",
    text: "Zeile 1\nZeile 2 <script>alert(1)</script>", url: "https://studip.uni-hannover.de/dispatch.php/messages/overview",
    dates: [{ date: "2026-11-19", time: "12:00", kind: "pruefung" }] };
  const html = L.readerHtml(m, { today: TODAY, back: true, icon });
  assert.doesNotMatch(html, /<script>|<b>fett/, "alles escaped");
  assert.match(html, /Zeile 1\nZeile 2 &lt;script&gt;/, "Zeilenumbrüche bleiben im Text");
  assert.match(html, /Mo\., 02\.11\.2026, 08:15 Uhr/);
  assert.match(html, /Prüfung 19\.11\., 12:00/);
  assert.match(html, /href="https:\/\/studip\.uni-hannover\.de\/dispatch\.php\/messages\/overview" target="_blank" rel="noopener"/);
  assert.match(html, />In Stud\.IP öffnen /);
  assert.match(html, /Nachrichten bleiben nur auf diesem Gerät; StudiNow markiert sie in Stud\.IP nicht als gelesen\./);
  assert.match(html, /msg-back/, "schmal: Zurück");
  assert.doesNotMatch(L.readerHtml({ ...m, url: "javascript:alert(1)" }, { today: TODAY }), /href="javascript|In Stud\.IP öffnen/);
  assert.doesNotMatch(L.readerHtml({ ...m, url: "file:///C:/x" }, { today: TODAY }), /file:/);
  assert.doesNotMatch(L.readerHtml(m, { today: TODAY }), /msg-back/);
  assert.match(L.readerHtml({ id: "x", subject: "", text: "" }, { today: TODAY }), /Diese Nachricht hat keinen Text\./);
});

test("Texte wie auf dem iPad", () => {
  assert.equal(L.TEXTS.title, "Nachrichten");
  assert.equal(L.TEXTS.open, "In Stud.IP öffnen");
  assert.equal(L.TEXTS.empty, "Keine Nachrichten");
  assert.equal(L.TEXTS.searchPrompt, "Nachrichten durchsuchen");
  assert.equal(L.noHits("klausur"), "Keine Treffer für „klausur“");
});
