// Learnweb-Nachrichten der Uni Hildesheim auf der Seite "Nachrichten" (Windows/Web, 05.11.2026, app/learnweb_messages.py):
// Texte je Quelle, Ausweg "Im Learnweb antworten", Anmeldung beim Learnweb. Daten erfunden.
import test from "node:test";
import assert from "node:assert/strict";
import * as L from "../../app/static/messages-logic.js";
import * as R from "../../app/static/message-reply-logic.js";

const lw = { id: "lw-msg-12-345", sender: "Learnweb-Kontakt", subject: "Nachricht im Learnweb", text: "Hallo",
  sent_at: "2026-11-05T10:00:00+01:00", url: "https://www.uni-hildesheim.de/learnweb2026/message/index.php?convid=12", dates: [] };
const sp = { ...lw, id: "sp-msg-m1", sender: "Lehrende", url: "https://studip.uni-hannover.de/dispatch.php/messages/overview" };

test("Leser nennt das Learnweb statt Stud.IP", () => {
  assert.equal(L.isLearnweb(lw), true);
  assert.equal(L.isLearnweb(sp), false);
  const html = L.readerHtml(lw, { today: "2026-11-05" });
  assert.match(html, /Im Learnweb öffnen/);
  assert.match(html, /im Learnweb nicht als gelesen/);
  assert.doesNotMatch(html, /Stud\.IP/);
  assert.match(L.readerHtml(sp, { today: "2026-11-05" }), /In Stud\.IP öffnen/);
});

test("Antworten: Ausweg und Anmeldung beim Learnweb", () => {
  assert.equal(R.webFallbackLabel("lw-msg-12-345"), "Im Learnweb antworten");
  assert.equal(R.webFallbackLabel("sp-msg-m1"), "In Stud.IP antworten");
  assert.equal(R.needsLogin("learnweb_login"), true);
  assert.equal(R.offersWebFallback("learnweb_login"), false);
  assert.equal(R.offersWebFallback("reply_not_allowed"), true);
  assert.equal(R.isReplyable({ ...lw, replyable: undefined }), true, "Absender ist nie \"Stud.IP\"");
});
