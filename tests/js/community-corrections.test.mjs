// Korrekturvorschlaege im Browser (app/static/community-corrections.js) gegen die gemeinsamen Vektoren, die auch die
// Python-Referenz (app/community_corrections.py) erzeugt. Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as S from "../../app/static/solutions.js";
import * as C from "../../app/static/community-corrections.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const V = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/community/correction-vectors.json"), "utf8"));
const secret = Uint8Array.from(Buffer.from(V.secret, "hex"));
const text = u8 => new TextDecoder().decode(u8);

assert.equal(V.format, C.FORMAT);
assert.equal(V.contentVersion, C.CONTENT_VERSION);

for (const c of V.cases) {
  test(`oeffnen (Chiffrat aus Python): ${c.name}`, async () => {
    const opened = await C.open(c.payload, c.correction.id, V.solutionID, secret);
    assert.equal(S.canonical(opened), S.canonical(c.opened));
    assert.equal(text(C.keyInfo(V.solutionID)), c.info);
    assert.equal(text(C.aad(V.solutionID, c.correction.id)), c.aad);
  });
  test(`versiegeln: Klartext byte-gleich, hin und zurueck: ${c.name}`, async () => {
    const v = C.validated(c.correction);
    assert.equal(text(C.plaintext(v)), c.plaintext, "kanonischer Klartext wie Python (und Swift)");
    const payload = await C.seal(c.correction, secret, { salt: Uint8Array.from(Buffer.from(c.salt, "base64")), nonce: Uint8Array.from(Buffer.from(c.nonce, "base64")) });
    assert.equal(payload.slice(0, 2), c.payload.slice(0, 2), "Version und Anfang des Salzes");
    assert.equal(S.canonical(await C.open(payload, c.correction.id, V.solutionID, secret)), S.canonical(c.opened));
  });
  test(`Chiffrat ist an Loesung, Korrektur und Schluessel gebunden: ${c.name}`, async () => {
    const bad = (payload, id, sid, key) => assert.rejects(C.open(payload, id, sid, key), e => e.code === "decryptionFailed");
    await bad(c.payload, c.correction.id, V.solutionID, new Uint8Array(32));
    await bad(c.payload, "00000000-0000-4000-8000-0000000000ff", V.solutionID, secret);
    await bad(c.payload, c.correction.id, "6f1c1c0e-0000-4000-8000-0000000000ff", secret);
    const raw = Uint8Array.from(Buffer.from(c.payload, "base64")); raw[raw.length - 1] ^= 1;
    await bad(Buffer.from(raw).toString("base64"), c.correction.id, V.solutionID, secret);
    await bad("AAAA", c.correction.id, V.solutionID, secret);
    await bad(c.payload.slice(0, -4), c.correction.id, V.solutionID, secret);
  });
}

const base = { id: "c-1", solution_id: "SOL-1", pseudonym: "Lea", created_at: "2026-11-03T10:00:00Z", note: "  hallo  ",
               pages: [{ pdfIndex: 3, width: 595, height: 842, rotation: 0, strokes: [], notes: [{ id: "n1", x: 0.25, y: 0.75, text: " hier " }] }, { pdfIndex: 1, width: 595, height: 842, rotation: 90, strokes: [], notes: [] }] };

test("pruefen: getrimmt, leere Seiten weg, klein geschriebene Kennungen", () => {
  const v = C.validated(base);
  assert.equal(v.note, "hallo");
  assert.equal(v.id, "c-1"); assert.equal(v.solution_id, "sol-1");
  assert.deepEqual(v.pages.map(p => p.pdfIndex), [3]);
  assert.equal(v.pages[0].notes[0].text, "hier");
});

test("pruefen: leer, ungueltige Stelle, leere Randnotiz, zu lang, fremde Objekte, doppelte Seite", () => {
  const throwsCode = (c, code) => assert.throws(() => C.validated(c), e => e.code === code, code);
  throwsCode({ ...base, note: "  ", pages: [] }, "empty");
  throwsCode({ ...base, pages: [{ ...base.pages[0], notes: [{ id: "n", x: 1.5, y: 0.1, text: "x" }] }] }, "anchorInvalid");
  throwsCode({ ...base, pages: [{ ...base.pages[0], notes: [{ id: "n", x: 0.5, y: 0.1, text: "  " }] }] }, "noteEmpty");
  throwsCode({ ...base, note: "x".repeat(C.MAX_TEXT + 1) }, "textTooLong");
  throwsCode({ ...base, pages: [{ ...base.pages[0], strokes: [{ type: "image", src: "x.png" }] }] }, "unsupportedObjectType");
  throwsCode({ ...base, pages: [base.pages[0], base.pages[0]] }, "invalidContent");
  assert.doesNotThrow(() => C.validated({ ...base, pages: [] }), "nur Text ist erlaubt");
});

test("Zustand und Angebot wie auf dem iPad", () => {
  assert.deepEqual(C.groupInbox([{ status: "open" }, { status: "seen" }, { status: "ignored" }, {}]).open.length, 2);
  assert.equal(C.groupInbox([{ status: "seen" }, { status: "ignored" }]).seen.length, 1);
  assert.equal(C.offer({ own: true, canShare: true, localFile: { id: 1 } }), "hidden");
  assert.equal(C.offer({ own: false, supported: false, canShare: true, localFile: { id: 1 } }), "hidden");
  assert.equal(C.offer({ own: false, canShare: false, localFile: { id: 1 } }), "locked");
  assert.equal(C.offer({ own: false, canShare: true, localFile: undefined }), "checking");
  assert.equal(C.offer({ own: false, canShare: true, localFile: null }), "needsPDF");
  assert.equal(C.offer({ own: false, canShare: true, localFile: { id: 1 } }), "ready");
  assert.equal(C.badgeText(0), ""); assert.equal(C.badgeText(7), "7"); assert.equal(C.badgeText(100), "99+");
});

test("Texte", () => {
  assert.equal(C.inboxMessage({ pseudonym: "Ben" }, "Blatt 3"), "Deine Lösung „Blatt 3“ hat einen Korrekturhinweis von Ben bekommen");
  assert.equal(C.inboxMessage({ pseudonym: " " }), "Deine Lösung hat einen Korrekturhinweis von Anonym bekommen");
  assert.equal(C.summary({ pages: [{ strokes: [1, 2, 3], notes: [1] }] }), "3 Markierungen · 1 Randnotiz");
  assert.equal(C.editorHint(1), "1 Korrekturhinweis zu deiner Lösung");
  assert.equal(C.editorHint(2), "2 Korrekturhinweise zu deiner Lösung");
  assert.equal(C.discussionTab(2, 1), "Diskussion (3)");
  assert.equal(C.seenGroup(4), "Gesehen (4)");
});
