import { test } from "node:test";
import assert from "node:assert/strict";
import { gfMul, rsDivisor, rsRemainder, encode, toSvg, versionFor, dataCodewords } from "../../app/static/qr.js";

test("Reed-Solomon: Beispiel 1-M aus der Norm (HELLO WORLD)", () => {
  const data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17];
  assert.deepEqual(rsRemainder(data, rsDivisor(10)), [196, 35, 39, 119, 235, 215, 231, 226, 93, 23]);
  assert.equal(gfMul(0x80, 2), 0x1d);
  assert.equal(gfMul(7, 1), 7);
});

test("Version nach Länge, Byte-Modus mit Füllbytes", () => {
  assert.equal(versionFor(14), 1);
  assert.equal(versionFor(32), 3);            // https://studinow.app/i/<10 Zeichen>
  assert.equal(versionFor(213), 10);
  assert.equal(versionFor(214), null);
  const cw = dataCodewords([65], 1);
  assert.equal(cw.length, 16);
  assert.deepEqual(cw.slice(0, 3), [0x40, 0x14, 0x10]);
  assert.deepEqual(cw.slice(3, 5), [0xec, 0x11]);
});

test("Formatinformation (M, Maske 0) und Versionsinformation (7)", () => {
  const r = encode("A", { mask: 0 }), m = r.modules, bits = [];
  for (let i = 0; i <= 5; i++) bits.push(m[i][8]);
  bits.push(m[7][8], m[8][8], m[8][7]);
  for (let i = 9; i < 15; i++) bits.push(m[8][14 - i]);
  // Bit i von 101010000010010 (0x5412 ^ BCH): von hinten gelesen
  assert.equal(bits.map(b => (b ? 1 : 0)).reverse().join(""), "101010000010010");
  const v7 = encode("v".repeat(110));
  assert.equal(v7.version, 7);
  const vb = []; for (let i = 0; i < 18; i++) vb.push(v7.modules[Math.floor(i / 3)][v7.size - 11 + (i % 3)] ? 1 : 0);
  assert.equal(vb.reverse().join(""), "000111110010010100");
});

test("Einladungslink: feste Matrix (mit Apples QR-Leser gegengeprüft)", () => {
  const r = encode("https://studinow.app/i/ABCDEFGHJK");
  assert.equal(r.version, 3); assert.equal(r.size, 29);
  assert.deepEqual(r.modules.map(x => x.map(c => (c ? 1 : 0)).join("")), ["11111110101101110010101111111","10000010001100010110101000001","10111010110001000101101011101","10111010001110011011001011101","10111010001110011110001011101","10000010100101101000101000001","11111110101010101010101111111","00000000010111000011100000000","10100011001111011100100100101","01101101101010001001001100011","10110110001011101011110111101","00110101001010111000010101000","00100110100111101101001100001","11101001100001100001101100011","01100110101010010011100010001","01011100100101010010001100000","11000111110001001101001000001","01011000000010001001101100111","11100011000001111101000111001","00010000100100110000011100000","11111010110111101101111111010","00000000101101101000100011101","11111110101010011100101010001","10000010010011000011100010010","10111010001101001101111111011","10111010000001001000110111101","10111010100100010000000010011","10000010010001111000110111000","11111110100011011101100110001"]);
});

test("SVG mit Ruhezone und Beschriftung", () => {
  const svg = toSvg("https://studinow.app/i/ABCDEFGHJK", { label: "QR-Code für <Link>" });
  assert.match(svg, /^<svg [^>]*viewBox="0 0 37 37"/);
  assert.match(svg, /aria-label="QR-Code für &lt;Link&gt;"/);
  assert.ok(!svg.includes("<script"));
  assert.throws(() => encode("x".repeat(300)));
});
