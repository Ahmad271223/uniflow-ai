// Windows/Web (05.11.2026): Antworten auf Stud.IP-Nachrichten (message-reply-logic.js), "In Stud.IP abgeben"
// (studip-submit-logic.js) und Pruefungsanmeldung (exam-registration-logic.js) ohne Browser; gleiche Texte und Regeln
// wie die iPad-App (docs/NACHRICHTEN-ANTWORTEN, ABGEBEN-STUDIP, PRUEFUNGSANMELDUNG vom 05.11.2026).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as R from "../../app/static/message-reply-logic.js";
import * as S from "../../app/static/studip-submit-logic.js";
import * as X from "../../app/static/exam-registration-logic.js";
import * as M from "../../app/static/messages-logic.js";

const src = f => readFileSync(new URL(`../../app/static/${f}`, import.meta.url), "utf8");

test("Antworten: Betreff, Allen antworten, Systemnachricht, Knoepfe im Leser", () => {
  assert.equal(R.replySubject("Tutorium"), "RE: Tutorium");
  assert.equal(R.replySubject("Re: Tutorium"), "Re: Tutorium");
  assert.equal(R.replySubject("(ohne Betreff)"), "RE: ");
  assert.ok(R.offersReplyAll(2) && R.offersReplyAll(21));
  assert.ok(!R.offersReplyAll(1) && !R.offersReplyAll(22) && !R.offersReplyAll(null));
  assert.ok(R.isReplyable({ sender: "Lehrende" }) && !R.isReplyable({ sender: "Stud.IP" }) && !R.isReplyable({ sender: "" }));
  assert.equal(R.toLine({ sender: { name: "Prof. Test" }, others: [{ name: "Bob" }] }, "all"), "Prof. Test, Bob");
  assert.equal(R.toLine({ sender: { name: "Prof. Test" }, others: [{ name: "Bob" }] }, "sender"), "Prof. Test");
  assert.ok(!R.canSend("  ") && R.canSend("Danke"));
  assert.ok(R.offersWebFallback("reply_security_token") && !R.offersWebFallback("reply_offline") && !R.offersWebFallback("studip_login"));
  const html = R.readerReplyHtml({ sender: "Lehrende", recipients: 3, replies: [{ line: "Beantwortet am 05.11.2026, 14:30", text: "Danke <b>" }] });
  assert.match(html, /data-reply="sender"/); assert.match(html, /data-reply="all"/);
  assert.match(html, /Beantwortet am 05\.11\.2026, 14:30/); assert.match(html, /Danke &lt;b&gt;/);
  assert.doesNotMatch(R.readerReplyHtml({ sender: "Stud.IP", recipients: 3 }), /data-reply/, "Systemnachricht ohne Knopf");
  assert.doesNotMatch(R.readerReplyHtml({ sender: "Lehrende", recipients: 1 }), /data-reply="all"/);
  assert.match(R.draftRestored("2026-11-05T14:30:00"), /^Entwurf vom 05\.11\., 14:30 wiederhergestellt$/);
});

test("Liste zeigt beantwortete Nachrichten, die Seite bindet das Antworten ein", () => {
  const row = M.listHtml([{ id: "sp-msg-1", sender: "Lehrende", subject: "x", sent_at: "2026-11-02T08:15:00+01:00", replies: [{}] }], { mark: "z", today: "2026-11-05" });
  assert.match(row, /msg-replied/); assert.match(row, /Beantwortet/);
  assert.match(src("messages.js"), /import\("\.\/message-reply\.js\?v=\d+"\)/);
  assert.match(src("message-reply.js"), /\/reply\?all=/);
  assert.match(src("message-reply.js"), /\/draft/);
});

test("Abgeben: Dateiname, Groesse, Vorschau, Ordnerliste", () => {
  assert.equal(S.finalFileName(" Müller Blatt 3.pdf "), "Mueller_Blatt_3.pdf");
  assert.equal(S.finalFileName(" .pdf"), "");
  assert.equal(S.preview(6, 1.2 * 1024 * 1024), "6 Seiten · 1,2 MB");
  assert.equal(S.preview(1, 2048), "1 Seite · 0,0 MB");
  assert.equal(S.sizeNotice(1000), "");
  assert.equal(S.sizeNotice(8 * 1024 * 1024), "Die Datei ist 8,0 MB groß. Manche Stud.IP-Ordner nehmen nur bis 7 MB an.");
  assert.ok(!S.canSubmit({ folder: "f", name: "x", pdf: null }) && S.canSubmit({ folder: "f", name: "x", pdf: {} }));
  const f = { writable: [{ id: "hw", label: "Hausaufgaben", is_homework: true }, { id: "r", label: "Hauptordner" }], closed: [{ label: "Abgabe Blatt 1" }] };
  const html = S.foldersHtml(f, "hw");
  assert.match(html, /value="hw" checked/); assert.match(html, /Abgabeordner – nur du und die Lehrenden/);
  assert.match(html, /Derzeit geschlossen \(Frist vorbei oder noch nicht offen\): Abgabe Blatt 1/);
  const opts = S.courseOptions([{ id: "a", title: "Analysis Übung", in_module: true }, { id: "b", title: "Physik", module_name: "Physik" }], "a");
  assert.match(opts, /optgroup label="Dieses Modul"/); assert.match(opts, /value="a" selected/);
  assert.equal(S.doneText("Analysis I", "Hausaufgaben"), "Abgegeben – Datei liegt jetzt in Analysis I › Hausaufgaben");
});

test("Abgeben: Editor-Menue, PDF aus dem Export (mit Notizen und Blaettern), nie im Dienst", () => {
  const ed = src("editor.js");
  assert.match(ed, /data-exp="studip"/); assert.match(ed, /import\("\.\/studip-submit\.js\?v=\d+"\)/);
  assert.match(ed, /window\.__app\?\.state\?\.hosted \? ""/);
  assert.match(ed, /if \(opts\.bytes\)/);
  const sub = src("studip-submit.js");
  assert.match(sub, /exportPdf\(null, false, false, \{ bytes: true \}\)/); assert.match(sub, /_expNotes = withNotes/);
});

const RESP = {
  supported: true, term: "WiSe 26/27", qis_url: "https://qis.verwaltung.uni-hannover.de/qisserver/x", hint: "Tippe im QIS …", disclaimer: "Verbindlich …",
  window: { term: "WiSe 26/27", kind: "meldung", n: 1, start: "2026-11-09", end: "2026-11-22", phase: "open", days_left: 2, days_until: 0 },
  vbp_window: null, show_card: true, open_count: 1, registered_count: 1, warnings: [{ text: "Die Anmeldung endet in 2 Tagen." }],
  source: { url: "https://www.uni-hannover.de/x/termine", checked_at: "2026-11-05" },
  suggestions: [
    { id: "algorithmen", title: "Algorithmen und Datenstrukturen", reason: "laut deinem Plan im 3. Semester", registered: false, period: "meldung",
      exam_date: "2027-02-15", exam_time: "09:00", exam_room: "HS A", exam_source: "aus Stud.IP-Terminen", withdraw_until: "2027-02-08", app_module_ids: [1] },
    { id: "datenbanken", title: "Datenbanken", reason: "laut deinem Plan im 3. Semester", registered: true, registered_via: "notenspiegel", period: "meldung", app_module_ids: [] },
  ],
  reminders: [
    { id: "examreg.wise-26-27.meldung1.start", day: "2026-11-09", until: "2026-11-22", title: "Prüfungsanmeldung beginnt heute", body: "b", route: "#/studyplan" },
    { id: "examreg.wise-26-27.meldung1.d2", day: "2026-11-20", until: "2026-11-22", title: "Prüfungsanmeldung endet übermorgen", body: "b", route: "#/studyplan" },
  ],
};

test("Pruefungsanmeldung: Phase, Karte, Block am Modul, nie selbst anmelden", () => {
  assert.equal(X.phaseText(RESP.window), "Meldezeitraum WiSe 26/27 läuft bis So, 22.11. – noch 2 Tage");
  assert.equal(X.phaseText({ ...RESP.window, phase: "soon", days_until: 4 }), "Meldezeitraum WiSe 26/27 beginnt am Mo, 09.11. (in 4 Tagen)");
  assert.equal(X.phaseText({ ...RESP.window, days_left: 0 }), "Meldezeitraum WiSe 26/27 läuft bis So, 22.11. – endet heute");
  const card = X.cardHtml(RESP, { limit: 4 });
  assert.match(card, /Diese Prüfungen solltest du anmelden/); assert.match(card, /Prüfung am 15\.02\.2027, 09:00 · HS A/);
  assert.match(card, /Rücktritt bis 08\.02\.2027/); assert.match(card, /nicht angemeldet/); assert.match(card, />angemeldet</);
  assert.match(card, /target="_blank"/, "QIS im App-Fenster");
  assert.match(card, /Im QIS zur Prüfung anmelden/); assert.match(card, /Die Anmeldung endet in 2 Tagen/);
  assert.doesNotMatch(card, /<form/i, "kein Formular, nichts wird abgeschickt");
  assert.equal(X.cardHtml({ supported: false }), "");
  assert.ok(X.showCard(RESP) && !X.showCard({ ...RESP, show_card: false }));
  assert.equal(X.suggestionFor(RESP, { appModuleId: 1 }).id, "algorithmen");
  assert.equal(X.suggestionFor(RESP, { catalogId: "datenbanken" }).id, "datenbanken");
  assert.equal(X.suggestionFor(RESP, { catalogId: "x" }), null);
  assert.match(X.moduleBlockHtml(RESP, RESP.suggestions[0]), /Prüfung anmelden/);
  assert.equal(X.examStatus(RESP, { module_id: 1, date: "2027-02-15", title: "Klausur Algorithmen" }), "nicht angemeldet");
  assert.equal(X.examStatus(RESP, { module_id: 9, title: "x" }), null);
});

test("Pruefungsanmeldung Uni Hildesheim: LSF statt QIS, Start ohne Ende, Hinweis statt 'nicht sicher'", () => {
  const HI = {
    ...RESP, system: "LSF", open_label: "Im LSF zur Prüfung anmelden", qis_url: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0",
    hint: "Im LSF: Meine Funktionen → POS-Management …", warnings: [],
    period_note: "Die Uni Hildesheim hat keine einheitliche Anmeldefrist.",
    window: { term: "WiSe 26/27", kind: "meldung", n: 1, start: "2026-11-11", end: "2027-03-31", phase: "soon", days_left: 146, days_until: 6, open_end: true },
  };
  assert.equal(X.systemOf(HI), "LSF"); assert.equal(X.systemOf(RESP), "QIS");
  assert.equal(X.openLabel(HI), "Im LSF zur Prüfung anmelden"); assert.equal(X.openLabel(RESP), "Im QIS zur Prüfung anmelden");
  assert.equal(X.openLabel({ system: "LSF" }), "Im LSF zur Prüfung anmelden"); assert.equal(X.TEXTS.openQIS, "Im QIS zur Prüfung anmelden");
  assert.equal(X.phaseText(HI.window, "LSF"), "Anmeldung im LSF WiSe 26/27 beginnt am Mi, 11.11. (in 6 Tagen) – Fristen je Prüfung");
  assert.equal(X.phaseText({ ...HI.window, phase: "open", days_left: 1 }, "LSF"), "Anmeldung im LSF seit Mi, 11.11. – Fristen je Prüfung im LSF",
    "kein 'endet morgen' ohne bekanntes Ende");
  assert.equal(X.phaseText({ ...HI.window, phase: "later" }, "LSF"), "Nächste Anmeldung im LSF: ab 11.11.2026 (WiSe 26/27)");
  const card = X.cardHtml(HI);
  assert.match(card, /Im LSF zur Prüfung anmelden/); assert.doesNotMatch(card, /Im QIS/);
  assert.match(card, /lsf\.uni-hildesheim\.de/); assert.match(card, /keine einheitliche Anmeldefrist/);
  assert.doesNotMatch(card, /kennt StudiNow nicht sicher/);
  assert.match(X.cardHtml({ ...HI, window: null }), /keine einheitliche Anmeldefrist/);
  assert.match(X.moduleBlockHtml(HI, HI.suggestions[0]), /Anmeldung im LSF/);
  assert.match(X.cardHtml({ ...RESP, window: null }), /kennt StudiNow nicht sicher/, "LUH unveraendert");
});

test("Pruefungsanmeldung: Hinweis in der App an den Erinnerungstagen (statt Systemmitteilung)", () => {
  assert.equal(X.dueReminder(RESP, "2026-11-08"), null, "vor dem ersten Tag nichts");
  assert.equal(X.dueReminder(RESP, "2026-11-10").id, "examreg.wise-26-27.meldung1.start");
  assert.equal(X.dueReminder(RESP, "2026-11-21").id, "examreg.wise-26-27.meldung1.d2", "die juengste");
  assert.equal(X.dueReminder(RESP, "2026-11-21", new Set(["examreg.wise-26-27.meldung1.d2"])).id, "examreg.wise-26-27.meldung1.start");
  assert.equal(X.dueReminder(RESP, "2026-11-23"), null, "nach dem Ende nichts");
  assert.match(X.bannerHtml(X.dueReminder(RESP, "2026-11-21")), /href="#\/studyplan"/);
  assert.match(src("views-home.js"), /renderDashboard/); assert.match(src("study-plan.js"), /renderSection/);
  assert.match(src("study-plan.js"), /renderModuleBlock\(box, \{ catalogId: cur \}\)/); assert.match(src("views-misc.js"), /renderModuleBlock/);
});

test("Nie im Offline-Speicher: Abgeben und Pruefungsanmeldung", () => {
  const p = src("sw-policy.js");
  assert.match(p, /studip\\\/submit/); assert.match(p, /exam-registration/);
});
