// Loesungspakete im Browser (app/static/solutions.js) gegen die gemeinsamen Testvektoren, die auch die Python-Referenz
// und Swift (iPad) pruefen. Ausfuehren: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as S from "../../app/static/solutions.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const V = JSON.parse(readFileSync(join(root, "packages/shared-contracts/fixtures/solutions/vectors.json"), "utf8"));
const bytes = b64 => S.b64decode(b64);

assert.equal(V.formatVersion, S.FORMAT_VERSION);
assert.deepEqual(V.readVersions, S.READ_VERSIONS);

for (const c of [...V.cases, ...V.legacy]) {
  test(`oeffnen (Version ${c.formatVersion}): ${c.name}`, async () => {
    const pdf = bytes(c.pdf);
    assert.equal(await S.sha256Hex(pdf), c.sha256);
    const content = await S.openPackage(c.package, pdf);
    assert.equal(S.canonical(content), S.canonical(c.opened));
    assert.equal(new TextDecoder().decode(S.aadBytes(c.package.header, c.formatVersion)), c.aad);
    assert.equal(new TextDecoder().decode(S.keyInfo(c.content.solutionId, c.formatVersion)), c.info);
  });
}
for (const c of V.cases) {
  test(`versiegeln, Klartext byte-gleich, hin und zurueck: ${c.name}`, async () => {
    assert.equal(new TextDecoder().decode(S.plaintextBytes(c.content)), c.plaintext, "kanonischer Klartext von Version 2 wie Python und Swift");
    const pdf = bytes(c.pdf);
    const pkg = await S.seal(c.content, pdf, { salt: bytes(c.salt), nonce: bytes(c.nonce) });
    assert.equal(pkg.formatVersion, 2);
    const e = pkg.header.encryption, pe = c.package.header.encryption;
    assert.deepEqual({ ...pkg.header, encryption: { ...e, compressedBytes: 0 } }, { ...c.package.header, encryption: { ...pe, compressedBytes: 0 } }, "Kopf wie Python bis auf die gepackte Groesse");
    assert.equal(e.plaintextBytes, pe.plaintextBytes);
    assert.ok(e.compressedBytes < e.plaintextBytes, "gepackt kleiner");
    assert.equal(S.canonical(await S.openPackage(JSON.parse(S.encodePackage(pkg)), pdf)), S.canonical(c.opened));
  });
}

test("Striche: Ganzzahlen und Differenzen wie Python", () => {
  for (const c of V.stroke_cases) {
    assert.equal(S.canonical(S.encodeObject(c.object)), S.canonical(c.wire));
    assert.equal(S.canonical(S.decodeObject(c.wire)), S.canonical(c.opened));
  }
  assert.throws(() => S.encodeObject({ type: "stroke", pointsDelta: [1] }), e => e.code === "invalidContent");
  assert.throws(() => S.decodeObject({ type: "stroke", pointsDelta: [1.5] }), e => e.code === "invalidContent");
  assert.throws(() => S.decodeObject({ type: "stroke", pointsDelta: [1e10, 0, 1] }), e => e.code === "invalidContent");
});

test("raw DEFLATE: harte Obergrenze beim Entpacken", async () => {
  const big = new Uint8Array(100000).fill(97);
  const packed = await S.deflateRaw(big);
  assert.ok(packed.length < 1000);
  assert.equal((await S.inflateRaw(packed, 100000)).length, 100000);
  await assert.rejects(S.inflateRaw(packed, 99999), e => e.code === "tooLarge");
  await assert.rejects(S.inflateRaw(packed.subarray(0, packed.length - 3), 100000), e => e.code === "invalidContent");
  // Angehaengte Bytes hinter dem Ende des Stroms weist DecompressionStream laut Spezifikation ab (Chrome, Firefox, Safari);
  // Node 22.x tut das noch nicht. Ohne diese Pruefung der Laufzeit gilt der Schutz durch AES-GCM (das Paket wird vor dem
  // Entpacken auf Aenderungen geprueft), der Test springt dann nur diese eine Zeile.
  const probe = new DecompressionStream("deflate-raw");
  const w = probe.writable.getWriter(); w.write(new Uint8Array([...packed, 1, 2, 3])).catch(() => {}); w.close().catch(() => {});
  let runtimeRejectsTrailing = false;
  try { const r = probe.readable.getReader(); for (;;) { const { done } = await r.read(); if (done) break; } } catch { runtimeRejectsTrailing = true; }
  if (runtimeRejectsTrailing) {
    await assert.rejects(S.inflateRaw(new Uint8Array([...packed, 1, 2, 3]), 100000), e => e.code === "invalidContent");
  } else {
    console.log("# Hinweis: diese Node-Laufzeit weist angehaengte Bytes nicht ab; Pruefung uebersprungen");
  }
});

for (const n of V.negative) {
  test(`abweisen: ${n.name}`, async () => {
    await assert.rejects(S.openPackage(n.package, bytes(V.cases[n.pdf_of].pdf)), e => e.code === n.error);
  });
}

test("Community-Paket: mit dem Schluessel der Community, ohne die PDF", async () => {
  const c = V.community;
  const secret = await S.communitySecret("course", c.university, c.course_id);
  assert.equal(Buffer.from(secret).toString("hex"), c.secret_hex);
  assert.equal(Buffer.from(await S.communitySecret("group", c.university, c.code)).toString("hex"), c.group_secret_hex);
  assert.equal(S.canonical(await S.openPackage(c.package, null, null, secret)), S.canonical(c.opened));
  const pkg = await S.seal(c.content, null, { salt: bytes(c.salt), nonce: bytes(c.nonce), secret });
  assert.equal(pkg.header.encryption.keyMaterial, "community-secret");
  assert.equal(S.canonical(await S.openPackage(pkg, null, null, secret)), S.canonical(c.opened));
  await assert.rejects(S.openPackage(c.package, null), e => e.code === "decryptionFailed");
  for (const m of c.module_cases) {
    const name = m.module.toLowerCase().replace(/ä/g, "ae").replace(/ö/g, "oe").replace(/ü/g, "ue").replace(/ß/g, "ss").replace(/[^\p{L}\p{N}]+/gu, " ").trim();
    assert.equal(Buffer.from(await S.communitySecret("module", c.university, name)).toString("hex"), m.secret_hex);
  }
  const other = await S.communitySecret("course", c.university, "anderer-kurs");
  await assert.rejects(S.openPackage(c.package, null, null, other), e => e.code === "decryptionFailed");
});

test("Zahlen wie Swift (JSONValue.format)", () => {
  const cases = [[0, "0"], [-0, "0"], [595, "595"], [595.28, "595.28"], [0.25, "0.25"], [1e-5, "1e-05"], [1.5e-7, "1.5e-07"],
                 [0.0001, "0.0001"], [1234.5678, "1234.5678"], [-12.5, "-12.5"], [1e16, "1e+16"], [123456789012345.6, "123456789012345.6"]];
  for (const [d, s] of cases) assert.equal(S.swiftNumber(d), s, String(d));
  assert.equal(S.canonical({ b: "a\u0001\n\"/ü", a: [1, 2.5, null, true] }), '{"a":[1,2.5,null,true],"b":"a\\u0001\\n\\"/ü"}');
});

test("Drehung wie SolutionGeometry", () => {
  const W = 612, H = 792;
  assert.deepEqual(S.applyT(S.transform(W, H, 0, 90), 10, 20), [H - 20, 10]);
  assert.deepEqual(S.applyT(S.transform(W, H, 90, 0), H - 20, 10), [10, 20]);
  assert.deepEqual(S.applyT(S.transform(W, H, 0, 180), 10, 20), [W - 10, H - 20]);
  assert.deepEqual(S.applyT(S.transform(W, H, 270, 270), 5, 6), [5, 6]);
  const p = S.applyT(S.transform(W, H, 90, 270), 100, 200); const q = S.applyT(S.transform(W, H, 0, 270), ...S.applyT(S.transform(W, H, 90, 0), 100, 200));
  assert.deepEqual(p.map(v => Math.round(v * 1e9) / 1e9), q.map(v => Math.round(v * 1e9) / 1e9));
});

test("bauen aus dem Notizmodell des Editors, Pruefung gegen die eigene PDF", async () => {
  const pdf = bytes(V.cases[0].pdf); const fp = await S.sha256Hex(pdf);
  const png = bytes(V.cases[0].content.images["/api/files/abc/assets/bild.png"].data);
  const model = { pageOrder: [{ key: "p1", type: "pdf", index: 1 }, { key: "a1", type: "asset", index: 1 }, { key: "p2", type: "pdf", index: 2, rotation: 90 },
                              { key: "b1", type: "blank", template: "grid", w: 400, h: 600 }],
                  pages: { p1: { objects: [{ id: "x", type: "stroke", points: [1, 2, 3, 4] }, { id: "im", type: "image", src: "/a.png" }] }, a1: { objects: [] },
                           p2: { objects: [] }, b1: { objects: [{ id: "t", type: "text", text: "hi" }] } } };
  const sizes = { 1: { width: 595, height: 842, rotation: 0 }, 2: { width: 842, height: 595, rotation: 90 }, 3: { width: 595, height: 842, rotation: 0 } };
  const c = S.buildContent({ model, selectedKeys: ["p1", "p2", "b1"], pdfPageCount: 3, pdfPage: i => sizes[i] || null, images: { "/a.png": { mime: "image/png", data: png } },
                             fingerprint: fp, title: " Blatt ", displayName: "Ahmad", solutionId: "6F1C2B9E-4D3A-4E8B-9C7D-2A1B3C4D5E6F", createdAt: new Date("2026-10-28T09:30:00.123Z") });
  assert.equal(c.solutionId, "6f1c2b9e-4d3a-4e8b-9c7d-2a1b3c4d5e6f");
  assert.equal(c.createdAt, "2026-10-28T09:30:00Z");
  assert.deepEqual(c.pages.map(p => [p.key, p.kind, p.rotation, p.extraRotation]), [["p1", "pdf", 0, 0], ["p2", "pdf", 180, 90], ["b1", "blank", 0, 0]]);
  assert.equal(c.pages[2].template, "grid"); assert.equal(c.pages[2].width, 400);
  assert.deepEqual(Object.keys(c.images), ["/a.png"]); assert.equal(c.title, "Blatt");
  const pkg = await S.seal(c, pdf);
  const back = await S.openPackage(JSON.parse(S.encodePackage(pkg)), pdf);
  assert.equal(S.canonical(back), S.canonical(c));
  const local = { pageCount: 3, page: i => sizes[i] };
  assert.equal(S.mismatch(back, local), null);
  assert.match(S.mismatch(back, { pageCount: 3, page: i => ({ ...sizes[i], width: sizes[i].width + 1 }) }), /passt nicht/);
  assert.match(S.mismatch(back, { pageCount: 4, page: i => sizes[i] }), /anderen PDF/);
  assert.throws(() => S.buildContent({ model, selectedKeys: ["p2"], pdfPageCount: 3, pdfPage: i => sizes[i], fingerprint: fp }), e => e.code === "noOwnNotes");
  assert.throws(() => S.buildContent({ model, selectedKeys: ["a1"], pdfPageCount: 3, pdfPage: i => sizes[i], fingerprint: fp }), e => e.code === "invalidContent");
  const bad = JSON.parse(JSON.stringify(model)); bad.pages.p1.objects.push({ type: "image", src: "data:application/pdf;base64,JVBERi0x" });
  assert.throws(() => S.buildContent({ model: bad, selectedKeys: ["p1"], pdfPageCount: 3, pdfPage: i => sizes[i], fingerprint: fp }), e => e.code === "containsPDFData");
});

test("Notizen ohne PDF: Striche und Text landen auf dem Canvas", async () => {
  const calls = [];
  const ctx = new Proxy({}, { get: (t, k) => (k in t ? t[k] : (...a) => { calls.push(k); }), set: (t, k, v) => { t[k] = v; return true; } });
  S.drawObjects(ctx, { objects: [{ type: "stroke", points: [0, 0, 5, 5], color: "#000", width: 2 }, { type: "text", text: "a\nb", fontSize: 10 }] });
  assert.ok(calls.includes("stroke"));
  assert.equal(calls.filter(c => c === "fillText").length, 2);
  assert.equal(S.normalizedCode("abcd-efgh"), "ABCDEFGH");
  assert.equal(S.normalizedCode("ABCDEFG0"), null);
});
