// Stud.IP-Inhalte der iPad-App auch im Web (Auftrag 03.11.2026): Karte "Neuigkeiten" (news.js), Schwarzes Brett
// (bulletin.js) und "Aus Stud.IP" im Modul (studip-texts.js), 1:1 nach NewsCard.swift, BulletinCard.swift und
// StudIPTextsCard.swift. Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

// core.js greift beim Laden auf document zu; die Module hier rendern nur Text
globalThis.document = { addEventListener() {}, querySelector: () => null, querySelectorAll: () => [], body: { classList: { toggle() {} } }, documentElement: {} };
globalThis.window = globalThis;
globalThis.location = { hash: "" };

const news = await import("../../app/static/news.js");
const bb = await import("../../app/static/bulletin.js");
const st = await import("../../app/static/studip-texts.js");

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const src = name => readFileSync(join(root, "app/static", name), "utf8");
const count = (s, re) => (s.match(re) || []).length;

// ---------------------------------------------------------------- Schwarzes Brett

const LONG = Array.from({ length: 300 }, (_, i) => `Wort${i + 1}`).join(" ") + "\nLetzter Absatz.";
const entry = (n, topic, over = {}) => ({ id: `sb-${n}`, topic, title: `${topic} ${n}`, text: `Text ${n}`, url: `https://studip.test/a/${n}`, posted_at: "2026-11-02T09:15:00", ...over });
const board = () => ({
  available: true, url: "https://studip.uni-hannover.de/plugins.php/schwarzesbrettplugin/category/list", new_count: 10, fetched_at: "2026-11-02T10:00:00",
  topics: [{ title: "Biete", count: 5, total: 120 }, { title: "Jobs an der Uni", count: 3, total: 9 }, { title: "Wohnliches", count: 4, total: 40 }],
  entries: [...[1, 2, 3, 4, 5].map(n => entry(n, "Biete")), ...[6, 7, 8].map(n => entry(n, "Jobs an der Uni")), ...[9, 10, 11, 12].map(n => entry(n, "Wohnliches"))],
});

test("Schwarzes Brett: Chips mit Anzahl, zuerst acht Zeilen, Knopf 'Alle 12 anzeigen'", () => {
  const h = bb.cardHtml(board());
  assert.match(h, /Alle 12</);
  assert.match(h, /Biete 5</);
  assert.match(h, /Jobs an der Uni 3</);
  assert.match(h, /Wohnliches 4</);
  assert.equal(count(h, /class="bb-entry"/g), bb.BULLETIN.shown);
  assert.equal(bb.BULLETIN.shown, 8);
  assert.match(h, /Alle 12 anzeigen/);
  assert.match(h, /In Stud\.IP öffnen/);
  assert.match(h, /Namen der Anbietenden holt StudiNow nicht/);
  assert.equal(count(bb.cardHtml(board(), { topic: "", expanded: true }), /class="bb-entry"/g), 12);
  assert.match(bb.cardHtml(board(), { topic: "", expanded: true }), /Weniger anzeigen/);
});

test("Schwarzes Brett: ein Thema filtert, dann kein 'Alle anzeigen'", () => {
  const h = bb.cardHtml(board(), { topic: "Jobs an der Uni", expanded: false });
  assert.equal(count(h, /class="bb-entry"/g), 3);
  assert.doesNotMatch(h, /id="bbMore"/);
  assert.match(h, /class="chip on" data-btopic="Jobs an der Uni"/);
  assert.deepEqual(bb.filterEntries(board().entries, "Wohnliches").map(e => e.id), ["sb-9", "sb-10", "sb-11", "sb-12"]);
  assert.equal(bb.filterEntries(board().entries, "").length, 12);
});

test("Schwarzes Brett: keine Karte ohne Brett oder ohne Anzeigen (Hildesheim, Dienst, leer)", () => {
  assert.equal(bb.cardHtml({ ...board(), available: false }), "");
  assert.equal(bb.cardHtml({ ...board(), entries: [] }), "");
  assert.equal(bb.cardHtml(null), "");
  assert.equal(bb.cardHtml({ available: true, entries: [], topics: [] }), "");
});

test("Schwarzes Brett: ganzer Titel und ganzer Text, nie '…'; Absaetze bleiben", () => {
  const e = entry(1, "Wohnliches", { title: "WG-Zimmer in der Nordstadt ab Dezember, 18 m², möbliert, mit Balkon und Blick auf den Welfengarten", text: LONG });
  const data = { ...board(), entries: [e], topics: [{ title: "Wohnliches", count: 1, total: 1 }] };
  const h = bb.cardHtml(data);
  assert.ok(h.includes(e.title) && h.includes("Wort300\nLetzter Absatz."), "ganzer Text in der Zeile");
  assert.ok(LONG.length > 1000);
  assert.doesNotMatch(h, /…/);
  const r = bb.readerHtml(e);
  assert.ok(r.includes(LONG) && !r.includes("…") && !/Gekürzt/.test(r), "ganzer Text im Leser");
  assert.match(r, /Antworten und Kontakt über die Anzeige in Stud\.IP\./);
  assert.match(bb.readerHtml(e), /Schließen/);
});

test("Schwarzes Brett: Fremdtext wird maskiert, nur http(s)-Links", () => {
  const evil = entry(1, "Biete", { title: "<img src=x onerror=alert(1)>", text: "<script>alert(1)</script>", url: "javascript:alert(1)" });
  const h = bb.cardHtml({ ...board(), entries: [evil], url: "javascript:alert(2)" });
  assert.doesNotMatch(h, /<img src=x|<script>/);
  assert.doesNotMatch(h, /href="javascript/);
  assert.doesNotMatch(bb.readerHtml(evil), /href="javascript|<script>/);
  assert.match(bb.readerHtml(entry(1, "Biete")), /href="https:\/\/studip\.test\/a\/1" target="_blank" rel="noopener"/);
});

test("Schwarzes Brett: Zeile in 'Neuigkeiten', Bedienungshilfe-Text", () => {
  assert.equal(bb.newLine(1), "Schwarzes Brett: 1 neue Anzeige");
  assert.equal(bb.newLine(10), "Schwarzes Brett: 10 neue Anzeigen");
  assert.equal(bb.accessibility(entry(1, "Biete", { title: "Fahrrad zu verkaufen" })), "Anzeige: Fahrrad zu verkaufen · Biete · Mo., 02.11.");
  assert.equal(bb.accessibility({ title: "A" }), "Anzeige: A");
});

test("Schwarzes Brett: laden und zeichnen; ohne Brett oder bei Fehler bleibt der Platz leer", async () => {
  const host = () => ({ innerHTML: "", isConnected: true, querySelectorAll: () => [], querySelector: () => null });
  const calls = [];
  const ok = host();
  await bb.mountBulletin(ok, async p => { calls.push(p); return board(); });
  assert.deepEqual(calls, ["/studip/bulletin"]);
  assert.match(ok.innerHTML, /Schwarzes Brett/);
  const none = host();
  await bb.mountBulletin(none, async () => ({ ...board(), available: false }));
  assert.equal(none.innerHTML, "");
  const broken = host();
  await bb.mountBulletin(broken, async () => { throw new Error("404"); });
  assert.equal(broken.innerHTML, "");
});

// ---------------------------------------------------------------- Neuigkeiten

const TODAY = "2026-11-02";
const item = (kind, over = {}) => ({ id: `${kind}-1`, kind, who: "Testmathematik", title: "Vorlesung entfällt", at: "2026-11-02T09:00:00", text: "Die Vorlesung am 12.11. fällt aus.",
  url: "https://studip.test/news/1", chips: [], source: "studip", color: null, ...over });

test("Neuigkeiten: Art, Ton und Bezeichnung wie NewsRow.style", () => {
  assert.deepEqual(news.newsStyle("nachricht"), ["note", "info", "Nachricht"]);
  assert.deepEqual(news.newsStyle("aenderung"), ["refresh", "ok", "Änderung"]);
  assert.deepEqual(news.newsStyle("blubber"), ["users", "warn", "Blubber"]);
  assert.deepEqual(news.newsStyle("ankuendigung"), ["bell", "accent", "Ankündigung"]);
  assert.deepEqual(news.newsStyle(undefined), ["bell", "accent", "Ankündigung"]);
  assert.equal(news.chipTone("ausfall"), "bad");
  assert.equal(news.chipTone("frist"), "warn");
  assert.equal(news.chipTone("verlegt"), "warn");
  assert.equal(news.chipTone("pruefung"), "");
});

test("Neuigkeiten: Zeit 'heute 09:15', 'gestern', sonst 'Sa., 31.10.'", () => {
  assert.equal(news.newsTime("2026-11-02T09:15:00", TODAY), "09:15");
  assert.equal(news.newsTime("2026-11-02", TODAY), "heute");
  assert.equal(news.newsTime("2026-11-01T23:00:00", TODAY), "gestern");
  assert.equal(news.newsTime("2026-10-31T12:00:00", TODAY), "Sa., 31.10.");
  assert.equal(news.newsTime("2026-10-31T12:00:00", "2026-11-01"), "gestern");
  assert.equal(news.newsTime("", TODAY), "");
  assert.equal(news.newsTime(undefined, TODAY), "");
});

test("Neuigkeiten: Text fuer Bedienungshilfen", () => {
  const n = item("nachricht", { who: "Lehrende", title: "Tutorium entfällt", at: "2026-11-02T08:15:00", chips: [{ label: "Ausfall? 12.11.", kind: "ausfall" }] });
  assert.equal(news.newsLabel(n, TODAY), "Nachricht: Tutorium entfällt · Lehrende · 08:15 · Ausfall? 12.11.");
});

test("Neuigkeiten: Zeile mit ganzem Betreff und ganzem Text, Chips, Link je Quelle", () => {
  const long = "Hallo zusammen,\n" + LONG;
  const title = "Sehr langer Betreff der Nachricht, der in einer Zeile niemals ganz Platz findet und trotzdem ganz bleibt";
  const h = news.newsRow(item("ankuendigung", { title, text: long, chips: [{ label: "Frist 12.11.", kind: "frist" }, { label: "Ausfall? 12.11.", kind: "ausfall" }] }), TODAY);
  assert.ok(h.includes(title) && h.includes(long));
  assert.doesNotMatch(h, /…/);
  assert.match(h, /<span class="badge warn">Frist 12\.11\.<\/span>/);
  assert.match(h, /<span class="badge bad">Ausfall\? 12\.11\.<\/span>/);
  assert.match(h, />In Stud\.IP öffnen</);
  assert.match(news.newsRow(item("ankuendigung", { source: "learnweb", url: "https://lw.test/x" }), TODAY), />Im Learnweb öffnen</);
  assert.match(h, /<details class="ann-item news-item"/, "aufklappbar");
  assert.match(h, /09:00/);
});

test("Neuigkeiten: Fremdtext maskiert, nur http(s)-Links, ohne Text kein Textblock", () => {
  const h = news.newsRow(item("nachricht", { title: "<b>x</b>", text: "<script>1</script>", who: "<i>y</i>", url: "javascript:alert(1)" }), TODAY);
  assert.doesNotMatch(h, /<b>x|<script>|<i>y|href="javascript/);
  const plain = news.newsRow(item("aenderung", { text: "", url: null }), TODAY);
  assert.doesNotMatch(plain, /class="body"|<a /);
});

test("Neuigkeiten: Karte zeigt hoechstens fuenf Zeilen und 'Alle anzeigen'; leer ohne Eintraege", () => {
  const items = Array.from({ length: 8 }, (_, i) => item("ankuendigung", { id: `a${i}`, title: `Titel ${i}` }));
  const h = news.newsCard(items, TODAY);
  assert.equal(count(h, /class="ann-item news-item"/g), 5);
  assert.match(h, /id="newsAll"[^>]*>Alle anzeigen</);
  assert.match(h, /<h2>[^]*Neuigkeiten<\/h2>/);
  assert.doesNotMatch(h, /news-bulletin/, "ohne neue Anzeigen keine Brett-Zeile");
  assert.equal(news.newsCard([], TODAY, 5), "", "ohne Neuigkeiten keine Karte, auch nicht fuer das Brett");
  assert.equal(news.newsCard(undefined, TODAY), "");
});

test("Neuigkeiten: Zeile 'Schwarzes Brett: N neue Anzeigen' fuehrt zu Uni & Noten", () => {
  const h = news.newsCard([item("ankuendigung")], TODAY, 10);
  assert.match(h, /<a class="news-bulletin" href="#\/services"/);
  assert.match(h, /Schwarzes Brett: 10 neue Anzeigen/);
  assert.match(news.newsCard([item("ankuendigung")], TODAY, 1), /Schwarzes Brett: 1 neue Anzeige</);
  assert.doesNotMatch(news.newsCard([item("ankuendigung")], TODAY, 0), /Schwarzes Brett/);
});

test("Neuigkeiten: Liste 'Alle anzeigen' mit Filter-Chips und Hinweis zu Nachrichten", () => {
  const items = [item("ankuendigung"), item("nachricht", { id: "m1" }), item("nachricht", { id: "m2" }), item("aenderung", { id: "c1" })];
  const all = news.listHtml(items, TODAY, "");
  assert.match(all, /data-nf="">Alle</);
  assert.match(all, /data-nf="ankuendigung">Ankündigungen 1</);
  assert.match(all, /data-nf="nachricht">Nachrichten 2</);
  assert.match(all, /data-nf="aenderung">Änderungen 1</);
  assert.doesNotMatch(all, /data-nf="blubber"/, "Blubber-Chip nur mit Blubber");
  assert.match(all, /StudiNow markiert sie in Stud\.IP nicht als gelesen/);
  assert.equal(count(all, /news-item"/g), 4);
  const only = news.listHtml(items, TODAY, "nachricht");
  assert.equal(count(only, /news-item"/g), 2);
  assert.match(only, /class="chip on" data-nf="nachricht"/);
  const changes = news.listHtml(items, TODAY, "aenderung");
  assert.doesNotMatch(changes, /markiert sie in Stud\.IP nicht/);
  assert.match(news.listHtml(items, TODAY, "blubber"), /Nichts Neues\./);
  assert.match(news.listHtml([...items, item("blubber", { id: "b1" })], TODAY, ""), /data-nf="blubber">Blubber 1</);
  assert.deepEqual(news.filterNews(items, "nachricht").map(i => i.id), ["m1", "m2"]);
});

// ---------------------------------------------------------------- Aus Stud.IP (Courseware, Wiki, Forum)

const groups = () => [
  { kind: "courseware", label: "Courseware", count: 3, changed: "2026-10-31", items: [{ id: "cw-1", title: "Grenzwerte und Folgen, ein sehr langer Seitentitel", course_title: "Analysis I", changed: "2026-10-31", url: "https://studip.test/cw" }] },
  { kind: "wiki", label: "Wiki", count: 2, changed: "2026-10-20", items: [{ id: "wiki-1", title: "Formelsammlung", course_title: "Analysis I", changed: null, url: null }] },
  { kind: "forum", label: "Forum", count: 1, changed: null, items: [] },
];

test("Aus Stud.IP: Zeilen und Kopfzeile wie StudIPTextsText", () => {
  assert.equal(st.groupLine(groups()[0]), "Courseware · 3 · geändert Sa., 31.10.");
  assert.equal(st.groupLine(groups()[2]), "Forum · 1");
  assert.equal(st.summary(groups()), "Courseware 3 · Wiki 2 · Forum 1");
  assert.equal(st.TEXTS.title, "Aus Stud.IP");
});

test("Aus Stud.IP: zugeklappt nur die Kopfzeile, aufgeklappt eine Zeile je Quelle, eine Quelle offen", () => {
  const closed = st.cardHtml(groups());
  assert.match(closed, /aria-expanded="false"/);
  assert.match(closed, /Courseware 3 · Wiki 2 · Forum 1/);
  assert.doesNotMatch(closed, /st-line/);
  const open = st.cardHtml(groups(), { expanded: true, open: null });
  assert.equal(count(open, /class="st-line"/g), 3);
  assert.doesNotMatch(open, /st-item/);
  assert.doesNotMatch(open, /Courseware 3 · Wiki/, "aufgeklappt steht die Summe nicht mehr in der Kopfzeile");
  const cw = st.cardHtml(groups(), { expanded: true, open: "courseware" });
  assert.match(cw, /data-stid="cw-1"/);
  assert.ok(cw.includes("Grenzwerte und Folgen, ein sehr langer Seitentitel"), "ganzer Titel");
  assert.doesNotMatch(cw, /data-stid="wiki-1"/);
  assert.doesNotMatch(cw, /…/);
  assert.equal(st.cardHtml([]), "", "ohne Eintraege kein Bereich");
});

test("Aus Stud.IP: Leser zeigt den ganzen Text und den Link nur mit http(s)", () => {
  const d = { id: "wiki-1", kind: "wiki", kind_label: "Wiki", title: "Formelsammlung", course_title: "Analysis I", changed: "2026-10-20", text: LONG, url: "https://studip.test/wiki" };
  const h = st.readerHtml(d);
  assert.ok(h.includes(LONG) && !h.includes("…"));
  assert.match(h, /Wiki · Analysis I · geändert Di\., 20\.10\./);
  assert.match(h, /In Stud\.IP öffnen/);
  assert.doesNotMatch(st.readerHtml({ ...d, url: "javascript:1", text: "<script>x</script>" }), /href="javascript|<script>/);
});

test("Aus Stud.IP: Blubber nur mit Threads (Abgleich vorerst aus), Zeile wie StudIPTextsText.threadDetail", () => {
  assert.equal(st.blubberGroup(null), null);
  assert.equal(st.blubberGroup({ threads: [] }), null);
  const g = st.blubberGroup({ threads: [{ id: "t1", course_title: "Analysis I", new_count: 3, changed: "2026-11-02", preview: "Lehrende: Klausurtermin steht" }, { id: "t2", course_title: "Stud.IP-weit", new_count: 0, changed: "2026-10-30", preview: "x" }] });
  assert.deepEqual([g.kind, g.label, g.count, g.changed], ["blubber", "Blubber", 2, "2026-11-02"]);
  assert.equal(st.threadDetail(g.items[0]), "Analysis I · 3 neu · Mo., 02.11.");
  assert.equal(st.threadDetail(g.items[1]), "Stud.IP-weit · Fr., 30.10.");
  assert.equal(st.commentHead({ role: "Lehrende", posted_at: "2026-11-02T09:30:00" }), "Lehrende · Mo., 02.11. 09:30");
  assert.match(st.cardHtml([g], { expanded: true, open: "blubber" }), /data-btid="t1"[^>]*aria-label="Blubber: Lehrende: Klausurtermin steht/);
});

test("Aus Stud.IP: laden mit allen Anfragen, Fehler einzelner Teile halten den Bereich nicht an", async () => {
  const host = () => ({ innerHTML: "", isConnected: true, querySelectorAll: () => [], querySelector: () => null });
  const calls = [];
  const h = host();
  await st.mountStudipTexts(h, 7, async p => { calls.push(p); if (p.includes("blubber")) throw new Error("404"); return { groups: groups(), total: 6 }; });
  assert.deepEqual(calls.sort(), ["/modules/7/studip", "/studip/blubber?module=7"]);
  assert.match(h.innerHTML, /Courseware 3 · Wiki 2 · Forum 1/);
  const empty = host();
  await st.mountStudipTexts(empty, 7, async () => { throw new Error("x"); });
  assert.equal(empty.innerHTML, "");
});

// ---------------------------------------------------------------- Einbau in die Seiten

test("Einbau: Uebersicht zeigt die Karte statt 'Ankuendigungen', Uni & Noten das Brett, Modul 'Aus Stud.IP'", () => {
  const home = src("views-home.js");
  assert.match(home, /import \{ newsCard, bindNews \} from "\.\/news\.js\?v=\d+"/);
  assert.match(home, /api\("\/news"\)\.catch\(\(\) => null\)/);
  assert.match(home, /api\("\/studip\/bulletin"\)\.catch\(\(\) => null\)/);
  // seit 05.11.2026 steht "Zuletzt benutzt" (recent.js, Weitermachen wie auf dem iPad) vor den Terminen
  assert.match(home, /const rest = \[recentCard\(recent\?\.items, \{ icon, esc \}\), termineCard\(d\), newsHtml, modulesCard\(d\), weekCard\(d\), newFilesCard\(d\)\]/);
  assert.match(home, /news \? newsCard\(news\.items, d\.today\.date, bulletin\?\.new_count \|\| 0\) : announcementsCard\(d\)/);
  const misc = src("views-misc.js");
  assert.match(misc, /<div id="bulletinHost"><\/div>\s*<div class="card-head" style="margin-top:1\.4rem"><h2>\$\{icon\("layers", 18\)\} Uni-Dienste/);
  assert.match(misc, /mountBulletin\(\$\("#bulletinHost", view\), api\)/);
  assert.match(misc, /<div id="stHost"><\/div>/);
  assert.match(misc, /mountStudipTexts\(\$\("#stHost", view\), id, api\)/);
});

test("Einbau: neue Dateien binden core.js in derselben Fassung ein wie die Seiten", () => {
  const v = /core\.js\?v=(\d+)/.exec(src("views-home.js"))[1];
  for (const f of ["news.js", "bulletin.js", "studip-texts.js"]) assert.match(src(f), new RegExp(`core\\.js\\?v=${v}"`), f);
});
