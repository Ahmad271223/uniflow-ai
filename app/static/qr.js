// QR-Code als inline SVG, ohne fremden Dienst und ohne Bibliothek (Einladungen, invites.js; 05.11.2026).
// Byte-Modus (UTF-8), Fehlerkorrektur M (15 %), Versionen 1 bis 10 (bis 213 Bytes; ein Einladungslink hat 32).
// Aufbau nach ISO/IEC 18004: Datenbits, Reed-Solomon je Block, Verschraenkung, Funktionsmuster, Platzierung im Zickzack,
// die Maske mit der kleinsten Strafpunktzahl, Formatinformation (BCH 15,5) und ab Version 7 Versionsinformation.
// Reine Funktionen (tests/js/qr.test.mjs; dort auch die Pruefung gegen bekannte Werte).

// je Version 1..10 fuer Stufe M: Codewoerter gesamt, Fehlerkorrektur-Codewoerter je Block, Bloecke
const TOTAL = [0, 26, 44, 70, 100, 134, 172, 196, 242, 292, 346];
const ECC_PER_BLOCK = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
const BLOCKS = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
const ALIGN = [[], [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];
const FORMAT_BITS_M = 0;                       // L=1, M=0, Q=3, H=2
export const MAX_VERSION = 10;

const bit = (x, i) => ((x >>> i) & 1) !== 0;

/** Multiplikation in GF(256) mit dem Polynom 0x11D */
export function gfMul(x, y) {
  let z = 0;
  for (let i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11d); z ^= ((y >>> i) & 1) * x; }
  return z & 0xff;
}

/** Erzeugerpolynom fuer `degree` Fehlerkorrektur-Codewoerter (ohne fuehrende 1) */
export function rsDivisor(degree) {
  const r = new Array(degree).fill(0); r[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < r.length; j++) { r[j] = gfMul(r[j], root); if (j + 1 < r.length) r[j] ^= r[j + 1]; }
    root = gfMul(root, 0x02);
  }
  return r;
}

/** Rest der Polynomdivision = die Fehlerkorrektur-Codewoerter eines Blocks */
export function rsRemainder(data, divisor) {
  const r = divisor.map(() => 0);
  for (const b of data) {
    const f = b ^ r.shift(); r.push(0);
    divisor.forEach((d, i) => { r[i] ^= gfMul(d, f); });
  }
  return r;
}

export const utf8 = s => Array.from(new TextEncoder().encode(String(s)));

/** kleinste Version, in die `n` Bytes passen; null, wenn zu lang */
export function versionFor(n) {
  for (let v = 1; v <= MAX_VERSION; v++) {
    const cap = (TOTAL[v] - ECC_PER_BLOCK[v] * BLOCKS[v]) * 8;
    if (4 + (v < 10 ? 8 : 16) + 8 * n <= cap) return v;
  }
  return null;
}

/** Datencodewoerter: Modus, Laenge, Bytes, Abschluss, Fuellbytes 0xEC/0x11 */
export function dataCodewords(bytes, v) {
  const cap = (TOTAL[v] - ECC_PER_BLOCK[v] * BLOCKS[v]) * 8, bits = [];
  const put = (val, len) => { for (let i = len - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
  put(0b0100, 4); put(bytes.length, v < 10 ? 8 : 16); bytes.forEach(b => put(b, 8));
  put(0, Math.min(4, cap - bits.length));
  while (bits.length % 8) bits.push(0);
  for (let pad = 0xec; bits.length < cap; pad ^= 0xec ^ 0x11) put(pad, 8);
  const out = [];
  for (let i = 0; i < bits.length; i += 8) out.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));
  return out;
}

/** Bloecke bilden, Fehlerkorrektur anhaengen, verschraenken */
export function withEcc(data, v) {
  const nb = BLOCKS[v], ecLen = ECC_PER_BLOCK[v], raw = TOTAL[v];
  const nShort = nb - (raw % nb), shortLen = Math.floor(raw / nb);
  const div = rsDivisor(ecLen), blocks = [];
  for (let i = 0, k = 0; i < nb; i++) {
    const dat = data.slice(k, k + shortLen - ecLen + (i < nShort ? 0 : 1)); k += dat.length;
    const ecc = rsRemainder(dat, div);
    blocks.push([...dat, ...(i < nShort ? [0] : []), ...ecc]);
  }
  const out = [];
  for (let i = 0; i < blocks[0].length; i++) blocks.forEach((b, j) => { if (i !== shortLen - ecLen || j >= nShort) out.push(b[i]); });
  return out;
}

const MASKS = [
  (x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, x => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => (x * y) % 2 + (x * y) % 3 === 0,
  (x, y) => ((x * y) % 2 + (x * y) % 3) % 2 === 0, (x, y) => ((x + y) % 2 + (x * y) % 3) % 2 === 0,
];

/** Strafpunkte nach den vier Regeln der Norm (Reihen, 2x2-Bloecke, Suchmuster-Folgen, Anteil dunkel) */
export function penalty(m) {
  const n = m.length; let p = 0, dark = 0;
  const line = get => {
    let s = 0, run = 1;
    for (let i = 1; i <= n; i++) {
      if (i < n && get(i) === get(i - 1)) run++;
      else { if (run >= 5) s += 3 + (run - 5); run = 1; }
    }
    const seq = Array.from({ length: n }, (_, i) => (get(i) ? 1 : 0)).join("");
    for (const pat of ["10111010000", "00001011101"]) for (let i = seq.indexOf(pat); i >= 0; i = seq.indexOf(pat, i + 1)) s += 40;
    return s;
  };
  for (let y = 0; y < n; y++) p += line(x => m[y][x]);
  for (let x = 0; x < n; x++) p += line(y => m[y][x]);
  for (let y = 0; y < n - 1; y++) for (let x = 0; x < n - 1; x++) { const c = m[y][x]; if (c === m[y][x + 1] && c === m[y + 1][x] && c === m[y + 1][x + 1]) p += 3; }
  for (const row of m) for (const c of row) if (c) dark++;
  p += 10 * Math.floor(Math.abs(dark * 100 / (n * n) - 50) / 5);
  return p;
}

/** Matrix (Zeilen von true = dunkel) fuer einen Text; `mask` erzwingt eine Maske (0..7, nur fuer Tests) */
export function encode(text, { mask = -1 } = {}) {
  const bytes = utf8(text), v = versionFor(bytes.length);
  if (!v) throw new Error("Text zu lang für den QR-Code");
  const n = v * 4 + 17;
  const mod = Array.from({ length: n }, () => new Array(n).fill(false));
  const fn = Array.from({ length: n }, () => new Array(n).fill(false));
  const set = (x, y, d) => { mod[y][x] = d; fn[y][x] = true; };
  for (let i = 0; i < n; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
  for (const [cx, cy] of [[3, 3], [n - 4, 3], [3, n - 4]]) {
    for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
      const x = cx + dx, y = cy + dy, d = Math.max(Math.abs(dx), Math.abs(dy));
      if (x >= 0 && x < n && y >= 0 && y < n) set(x, y, d !== 2 && d !== 4);
    }
  }
  const al = ALIGN[v];
  al.forEach((a, i) => al.forEach((b, j) => {
    if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) return;
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(a + dx, b + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }));
  const drawFormat = msk => {
    const data = (FORMAT_BITS_M << 3) | msk; let rem = data;
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    const b = ((data << 10) | rem) ^ 0x5412;
    for (let i = 0; i <= 5; i++) set(8, i, bit(b, i));
    set(8, 7, bit(b, 6)); set(8, 8, bit(b, 7)); set(7, 8, bit(b, 8));
    for (let i = 9; i < 15; i++) set(14 - i, 8, bit(b, i));
    for (let i = 0; i < 8; i++) set(n - 1 - i, 8, bit(b, i));
    for (let i = 8; i < 15; i++) set(8, n - 15 + i, bit(b, i));
    set(8, n - 8, true);
  };
  drawFormat(0);
  if (v >= 7) {
    let rem = v;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const b = (v << 12) | rem;
    for (let i = 0; i < 18; i++) { const a = n - 11 + (i % 3), c = Math.floor(i / 3); set(a, c, bit(b, i)); set(c, a, bit(b, i)); }
  }
  const cw = withEcc(dataCodewords(bytes, v), v);
  let k = 0;
  for (let right = n - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < n; vert++) for (let j = 0; j < 2; j++) {
      const x = right - j, up = ((right + 1) & 2) === 0, y = up ? n - 1 - vert : vert;
      if (!fn[y][x] && k < cw.length * 8) { mod[y][x] = bit(cw[k >>> 3], 7 - (k & 7)); k++; }
    }
  }
  const apply = msk => { for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (!fn[y][x] && MASKS[msk](x, y)) mod[y][x] = !mod[y][x]; };
  let best = mask;
  if (best < 0) {
    let min = Infinity;
    for (let msk = 0; msk < 8; msk++) {
      apply(msk); drawFormat(msk);
      const p = penalty(mod); if (p < min) { min = p; best = msk; }
      apply(msk);                               // zuruecknehmen (XOR)
    }
  }
  apply(best); drawFormat(best);
  return { version: v, mask: best, size: n, modules: mod };
}

/** SVG mit Ruhezone (4 Module), ein Pfad fuer alle dunklen Module; `label` fuer Bildschirmleser */
export function toSvg(text, { label = "QR-Code", border = 4 } = {}) {
  const { size, modules } = encode(text), dim = size + 2 * border;
  let d = "";
  modules.forEach((row, y) => row.forEach((on, x) => { if (on) d += `M${x + border} ${y + border}h1v1h-1z`; }));
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${dim} ${dim}" role="img" aria-label="${esc(label)}" shape-rendering="crispEdges"><rect width="${dim}" height="${dim}" fill="#fff"/><path d="${d}" fill="#000"/></svg>`;
}
