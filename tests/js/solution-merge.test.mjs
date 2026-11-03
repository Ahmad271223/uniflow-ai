// Zusammenfuehren beim erneuten Teilen zu derselben PDF (03.11.2026): mergeContent gegen die gemeinsamen Faelle (auch
// Python und Swift), dazu der Ablauf shareToCommunity gegen einen nachgebildeten Dienst (fragen, laden, zusammenfuehren,
// PUT). Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as S from "../../app/static/solutions.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const M = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/solutions/merge-cases.json"), "utf8"));

for (const c of M.cases) {
  test(`zusammenfuehren: ${c.name}`, () => {
    if (c.error) { assert.throws(() => S.mergeContent(c.previous, c.new), e => e.code === c.error); return; }
    const m = S.mergeContent(c.previous, c.new);
    assert.deepEqual(m.pages.map(p => p.key), c.keys);
    assert.equal(S.canonical(m), S.canonical(c.merged), "wie die Python-Referenz");
  });
}

test("Notizblatt-Schluessel wie im Kern", () => {
  assert.ok(S.isNotebookKey("nb-p1") && S.isNotebookKey("nb12-x"));
  assert.ok(!S.isNotebookKey("nb") && !S.isNotebookKey("nbx-1") && !S.isNotebookKey("p1") && !S.isNotebookKey("nb2"));
});

/** Dienst im Speicher: /mine, POST (409 bei Doppel), GET und PUT einer Loesung */
function fakeService(fp, key) {
  const store = new Map(), log = [];
  const call = async (path, { method = "GET", body } = {}) => {
    log.push(`${method} ${path}`);
    if (path === "/mine") return { solutions: [...store.values()].map(s => s.summary) };
    if (path === "/solutions" && method === "POST") {
      const dup = [...store.values()].find(s => s.summary.fingerprint === body.package.header.document.sha256 && s.summary.community_key === body.community_key);
      if (dup) throw Object.assign(new Error(S.UPDATE_QUESTION), { code: "already_published", status: 409, data: { code: "already_published", solution_id: dup.summary.solution_id } });
      const id = body.package.header.solutionId;
      store.set(id, { pkg: body.package, summary: { solution_id: id, fingerprint: fp, community_key: body.community_key, status: "active", published_at: "2026-11-03T10:00:00Z" } });
      return { solution_id: id };
    }
    const id = path.split("/")[2];
    if (method === "GET") return { package: store.get(id).pkg };
    if (method === "PUT") { assert.equal(body.package.header.solutionId, id, "Kopf-ID bleibt"); assert.equal(body.community_key, key); store.get(id).pkg = body.package; return { solution_id: id }; }
    throw new Error("unerwartet " + path);
  };
  return { store, log, call };
}

test("erneut teilen: fragen, bei Ja zusammenfuehren und das Paket der eigenen Loesung ersetzen", async () => {
  const c = M.cases.find(x => x.name.startsWith("Leerseiten"));
  const space = { key: "1".repeat(64), name: "Analysis", secret: await S.communitySecret("course", "luh", "kurs-1") };
  const svc = fakeService(c.previous.document.sha256, space.key);
  const first = await S.shareToCommunity({ content: c.previous, space, call: svc.call, confirmUpdate: async () => assert.fail("nicht fragen") });
  assert.ok(first.published);
  // zweites Mal: Nein laesst alles, wie es ist
  let asked = 0;
  const no = await S.shareToCommunity({ content: c.new, space, call: svc.call, confirmUpdate: async () => { asked++; return false; } });
  assert.deepEqual([no.cancelled, asked, svc.log.includes("PUT /solutions/" + first.solutionId)], [true, 1, false]);
  assert.equal(svc.log.filter(l => l === "POST /solutions").length, 1, "vorher gefragt: kein zweites Veroeffentlichen");
  // Ja: zusammengefuehrt mit der bisherigen ID
  const yes = await S.shareToCommunity({ content: c.new, space, call: svc.call, confirmUpdate: async () => true });
  assert.deepEqual([yes.updated, yes.solutionId, yes.pages], [true, first.solutionId, c.keys.length]);
  assert.equal(svc.store.size, 1);
  const opened = await S.openPackage(svc.store.get(first.solutionId).pkg, null, null, space.secret);
  assert.deepEqual(opened.pages.map(p => p.key), c.keys);
  assert.equal(S.canonical(opened), S.canonical(S.mergeContent(c.previous, c.new)));
});

test("409 already_published ohne Eintrag in /mine fuehrt ebenfalls zur Frage", async () => {
  const c = M.cases[0];
  const space = { key: "2".repeat(64), name: "Gruppe", secret: await S.communitySecret("group", "luh", "ABCDEFGH") };
  const svc = fakeService(c.previous.document.sha256, space.key);
  await S.shareToCommunity({ content: c.previous, space, call: svc.call, confirmUpdate: async () => true });
  const hidden = { ...svc, call: (p, o) => (p === "/mine" ? Promise.resolve({ solutions: [] }) : svc.call(p, o)) };
  let asked = false;
  const r = await S.shareToCommunity({ content: c.new, space, call: hidden.call, confirmUpdate: async () => (asked = true) });
  assert.ok(asked && r.updated);
  assert.equal(svc.store.size, 1);
});
