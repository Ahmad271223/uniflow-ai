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

for (const c of V.cases) {
  test(`oeffnen: ${c.name}`, async () => {
    const pdf = bytes(c.pdf);
    assert.equal(await S.sha256Hex(pdf), c.sha256);
    const content = await S.openPackage(c.package, pdf);
    assert.equal(S.canonical(content), c.plaintext);
    assert.equal(new TextDecoder().decode(S.aadBytes(c.package.header)), c.aad);
    assert.equal(new TextDecoder().decode(S.keyInfo(c.content.solutionId)), c.info);
  });
  test(`versiegeln byte-gleich: ${c.name}`, async () => {
    const pkg = await S.seal(c.content, bytes(c.pdf), { salt: bytes(c.salt), nonce: bytes(c.nonce) });
    assert.equal(S.encodePackage(pkg), c.package_text);
    assert.equal(S.canonical(c.content), c.plaintext, "kanonisches JSON wie Swift und Python");
  });
}

for (const n of V.negative) {
  test(`abweisen: ${n.name}`, async () => {
    await assert.rejects(S.openPackage(n.package, bytes(V.cases[n.pdf_of].pdf)), e => e.code === n.error);
  });
}

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
