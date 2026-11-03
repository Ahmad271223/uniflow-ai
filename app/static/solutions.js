// Loesungspakete "uniflow-solution" im Browser (Windows-App, Web): Version 2 schreiben, Versionen 1 und 2 lesen, wie
// das iPad (apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Solutions/SolutionPackage.swift, SolutionCrypto.swift).
// Ohne DOM: laeuft auch unter Node (tests/js/solutions.test.mjs) gegen die gemeinsamen Testvektoren
// packages/shared-contracts/fixtures/solutions/vectors.json.
//
// - Schluessel: HKDF-SHA256 ueber die VOLLSTAENDIGEN Bytes der Original-PDF, Salz 32 Byte (Kopf),
//   Info "uniflow-solution/v<formatVersion>|<loesungs-id klein>"; AES-256-GCM, Nonce 12 Byte, Chiffrat + 16 Byte Tag.
// - AAD: {"format","formatVersion","header"} kanonisch (sortierte Schluessel, keine Leerzeichen, Zeichen wie
//   JSONValue.serialized in Swift: nur " \ \n \r \t und uebrige Steuerzeichen als \u00xx maskiert).
// - Version 2 (2.11.2026, docs/LOESUNGEN-TEILEN.md 3a): Striche als ganze Zahlen (`pointsDelta` = Koordinate x 10,
//   `widthsDelta` = Breite x 100, jeweils als Differenz), Klartext vor dem Verschluesseln mit raw DEFLATE gepackt
//   (CompressionStream "deflate-raw"); beim Entpacken nie mehr als `plaintextBytes`. Nach dem Oeffnen wieder
//   Objekte wie in Version 1 (Punkte als Zahlenliste), Editor und Leser bleiben unveraendert.
// - Inhalt: eigene Notizobjekte je Seite 1:1, nie PDF-Bytes. Empfaenger pruefen Seitenzahl, Seitengroesse und
//   /Rotate gegen die eigene PDF; passt etwas nicht, wird keine Ebene gezeigt (auch nicht teilweise).

export const FORMAT = "uniflow-solution";
export const CONTENT_FORMAT = "uniflow-solution-content";
export const FORMAT_VERSION = 2;            // geschrieben wird immer Version 2
export const READ_VERSIONS = [1, 2];
export const CONTENT_VERSION = 1;           // Inhalt nach dem Oeffnen (Punkte als Zahlenliste)
export const COMPRESSION = "deflate-raw";
export const TAG_BYTES = 16;
// Feld im Speicher, Feld in Version 2, Faktor, Abstand der Differenz (wie DELTA_FIELDS in app/solution_format.py)
const DELTA_FIELDS = [["points", "pointsDelta", 10, 2], ["widths", "widthsDelta", 100, 1]];
const MAX_QUANT = 1e10;
export const LIMITS = {
  maxPlaintextBytes: 48 << 20, maxPages: 2000, maxObjectsPerPage: 20000, maxObjects: 200000, maxImages: 200,
  maxImageBytes: 10 << 20, maxPDFPages: 100000, maxPageSide: 14400, maxDisplayName: 60, maxTitle: 200,
  // Zahlen je Strichliste und insgesamt (Speicherverstaerkung beim Oeffnen, Sicherheitspruefung 3.11.2026)
  maxStrokeValues: 100000, maxStrokeNumbers: 10000000,
};
/** tooLarge bei zu langen Strichlisten (vor dem Dekodieren; wie check_stroke_sizes in app/solution_format.py). */
export function checkStrokeSizes(c) {
  let total = 0;
  for (const p of (isObj(c) && Array.isArray(c.pages) ? c.pages : [])) {
    for (const o of (isObj(p) && Array.isArray(p.objects) ? p.objects : [])) {
      if (!isObj(o) || o.type !== "stroke") continue;
      for (const f of ["points", "pointsDelta", "widths", "widthsDelta"]) {
        if (!Array.isArray(o[f])) continue;
        if (o[f].length > LIMITS.maxStrokeValues) fail("tooLarge");
        total += o[f].length;
      }
    }
  }
  if (total > LIMITS.maxStrokeNumbers) fail("tooLarge");
}
export const TEMPLATES = ["blank", "lined", "grid", "dotted", "mm", "cornell"];
export const OBJECT_TYPES = ["stroke", "text", "shape", "image"];
const REFERENCE_FIELDS = new Set(["src", "data", "url", "href", "file", "asset", "uri"]);
const PROSE_FIELDS = new Set(["text"]);

export class SolutionError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const MSG = {
  tooLarge: "Die Lösung ist zu groß.",
  notASolution: "Die Datei ist keine StudiNow-Lösung.",
  fingerprintMismatch: "Diese Lösung gehört zu einer anderen PDF-Datei (oder einer anderen Fassung). Sie wird hier nicht angezeigt.",
  decryptionFailed: "Die Lösung lässt sich mit dieser PDF-Datei nicht öffnen – andere Fassung der Datei oder beschädigtes Paket.",
  containsPDFData: "Geteilt werden dürfen nur eigene Notizen – PDF-Inhalte sind nicht erlaubt.",
  nothingSelected: "Keine Seite ausgewählt.",
  noOwnNotes: "Auf den gewählten Seiten gibt es keine eigenen Notizen. Schreibe oder zeichne zuerst etwas – leere Lösungen werden nicht geteilt.",
  nonFiniteNumber: "Die Lösung enthält ungültige Zahlen.",
  pageNotInPDF: "Diese Seite gibt es in der PDF-Datei nicht (mehr), z. B. nach einer neuen Fassung mit weniger Seiten.",
};
const fail = (code, extra) => { throw new SolutionError(code, extra ? (code === "invalidHeader" ? `Die Lösung ist beschädigt (Kopf: ${extra}).` : code === "invalidContent" ? `Die Lösung ist beschädigt (Inhalt: ${extra}).` : code === "unsupportedVersion" ? `Diese Lösung hat Formatversion ${extra} – bitte StudiNow aktualisieren.` : code === "unsupportedObjectType" ? `Die Lösung enthält einen unbekannten Objekttyp („${extra}“).` : `${MSG[code] || code}: ${extra}`) : (MSG[code] || code)); };

// ---------------------------------------------------------------- kanonisches JSON (wie JSONValue.serialized)

/** Zahl wie JSONValue.format in Swift: ganze Zahlen ohne Nachkommastellen (|d| < 1e15), sonst Swifts kuerzeste
 *  Darstellung (Exponent ab e < -4 oder e >= 16, Exponent mit Vorzeichen und mindestens zwei Ziffern). */
export function swiftNumber(d) {
  if (!Number.isFinite(d)) return "null";
  if (d === Math.round(d) && Math.abs(d) < 1e15) return String(Object.is(d, -0) ? 0 : d);
  const [mant, expS] = d.toExponential().split("e"); const e = +expS;
  if (e < -4 || e >= 16) return `${mant}e${e < 0 ? "-" : "+"}${String(Math.abs(e)).padStart(2, "0")}`;
  const neg = mant.startsWith("-"); const digits = mant.replace("-", "").replace(".", "");
  let s;
  if (e >= 0) { const ip = digits.slice(0, e + 1).padEnd(e + 1, "0"); const fp = digits.slice(e + 1); s = fp ? `${ip}.${fp}` : `${ip}.0`; }
  else s = `0.${"0".repeat(-e - 1)}${digits}`;
  return (neg ? "-" : "") + s;
}

function swiftString(s) {
  let out = '"';
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (ch === '"') out += '\\"'; else if (ch === "\\") out += "\\\\"; else if (c === 10) out += "\\n"; else if (c === 13) out += "\\r";
    else if (c === 9) out += "\\t"; else if (c < 0x20) out += "\\u00" + c.toString(16).padStart(2, "0"); else out += ch;
  }
  return out + '"';
}

/** JSON-Text mit sortierten Schluesseln, genau wie `serialized(sortedKeys: true)` in Swift. */
export function canonical(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return swiftNumber(v);
  if (typeof v === "string") return swiftString(v);
  if (Array.isArray(v)) return "[" + v.map(canonical).join(",") + "]";
  const keys = Object.keys(v).filter(k => v[k] !== undefined).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return "{" + keys.map(k => swiftString(k) + ":" + canonical(v[k])).join(",") + "}";
}

// ---------------------------------------------------------------- Bytes, Base64, Hash

const enc = new TextEncoder();
export const utf8 = s => enc.encode(s);
export function b64encode(u8) {
  let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  return btoa(s);
}
/** Base64 streng wie Data(base64Encoded:) (Gross-/Kleinbuchstaben, Ziffern, + /, Auffuellung); sonst null. */
export function b64decode(s) {
  if (typeof s !== "string" || s.length % 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) return null;
  try { const bin = atob(s); const u8 = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i); return u8; } catch { return null; }
}
const subtle = () => { const c = globalThis.crypto?.subtle; if (!c) throw new SolutionError("noCrypto", "Verschlüsselung ist hier nicht verfügbar (nur in der App am PC oder über https)."); return c; };
const u8of = b => b instanceof Uint8Array ? b : new Uint8Array(b);
export async function sha256Hex(bytes) {
  const h = new Uint8Array(await subtle().digest("SHA-256", u8of(bytes)));
  return [...h].map(x => x.toString(16).padStart(2, "0")).join("");
}
export function randomBytes(n) { const u = new Uint8Array(n); globalThis.crypto.getRandomValues(u); return u; }
export const keyInfo = (id, version = FORMAT_VERSION) => utf8(`${FORMAT}/v${version}|${String(id).toLowerCase()}`);

/** Schluesselmaterial einer Community (1.11.2026): `scope` course (Kurs-ID) oder group (normalisierter Code). */
export async function communitySecret(scope, university, value) {
  return new Uint8Array(await subtle().digest("SHA-256", utf8(`uniflow.community.secret.v1\0${scope}\0${university}\0${value}`)));
}

async function aesKey(pdfBytes, salt, info) {
  const base = await subtle().importKey("raw", u8of(pdfBytes), "HKDF", false, ["deriveKey"]);
  return subtle().deriveKey({ name: "HKDF", hash: "SHA-256", salt, info }, base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

// ---------------------------------------------------------------- Pruefungen (wie SolutionValidator)

const isObj = v => v !== null && typeof v === "object" && !Array.isArray(v);
const exactInt = v => (typeof v === "number" && Number.isFinite(v) && v === Math.round(v) && Math.abs(v) < 9e15 ? v : null);
const isHex64 = s => typeof s === "string" && /^[0-9a-f]{64}$/.test(s);
const isUUID = s => typeof s === "string" && /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(s);
const isDate = s => typeof s === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(s) && !Number.isNaN(Date.parse(s));
const len = s => [...s].length;
export const normRot = d => ((Math.trunc(d / 90) * 90) % 360 + 360) % 360;

export function checkFinite(v) {
  if (typeof v === "number") { if (!Number.isFinite(v)) fail("nonFiniteNumber"); }
  else if (Array.isArray(v)) v.forEach(checkFinite);
  else if (isObj(v)) Object.values(v).forEach(checkFinite);
}
export function checkNoPDF(v, field = null) {
  if (typeof v === "string") {
    const f = (field || "").toLowerCase();
    if (PROSE_FIELDS.has(f)) return;
    if (REFERENCE_FIELDS.has(f)) { if (v.includes("%PDF-") || v.includes("JVBERi0") || v.toLowerCase().includes("application/pdf")) fail("containsPDFData"); }
    else { const t = v.replace(/^\s+/, ""); if (t.startsWith("%PDF-") || t.startsWith("JVBERi0") || t.toLowerCase().startsWith("data:application/pdf")) fail("containsPDFData"); }
  } else if (Array.isArray(v)) v.forEach(x => checkNoPDF(x, field));
  else if (isObj(v)) for (const [k, x] of Object.entries(v)) { if (k.includes("%PDF-")) fail("containsPDFData"); checkNoPDF(x, k); }
}
export function validateObject(o) {
  if (!isObj(o)) fail("invalidContent", "Objekt");
  if (typeof o.type !== "string") fail("invalidContent", "Objekttyp");
  if (!OBJECT_TYPES.includes(o.type)) fail("unsupportedObjectType", o.type);
  if ("id" in o && typeof o.id !== "string") fail("invalidContent", "Objekt-ID");
  checkFinite(o); checkNoPDF(o);
}
export function sniffImage(u8) {
  if (u8.length >= 4 && u8[0] === 0x89 && u8[1] === 0x50 && u8[2] === 0x4e && u8[3] === 0x47) return "image/png";
  if (u8.length >= 3 && u8[0] === 0xff && u8[1] === 0xd8 && u8[2] === 0xff) return "image/jpeg";
  return null;
}

function validatePage(p, pdfPageCount) {
  if (!isObj(p)) fail("invalidContent", "Seite");
  if (typeof p.key !== "string" || !p.key || len(p.key) > 64) fail("invalidContent", "Seitenschlüssel");
  if (p.kind !== "pdf" && p.kind !== "blank") fail("invalidContent", "Seitenart");
  const w = p.width, h = p.height;
  if (typeof w !== "number" || typeof h !== "number" || !(w > 0) || !(h > 0) || w > LIMITS.maxPageSide || h > LIMITS.maxPageSide) fail("invalidContent", "Seitengröße");
  const r = exactInt(p.rotation), er = exactInt(p.extraRotation);
  if (r === null || r % 90 || r < 0 || r >= 360 || er === null || er % 90 || er < 0 || er >= 360) fail("invalidContent", "Drehung");
  const out = { key: p.key, kind: p.kind, width: w, height: h, rotation: r, extraRotation: er, objects: null };
  if (p.kind === "pdf") { const i = exactInt(p.pdfIndex); if (i === null || i < 1 || i > pdfPageCount) fail("invalidContent", "PDF-Seite"); out.pdfIndex = i; }
  else { if ("pdfIndex" in p) fail("invalidContent", "Leerseite mit PDF-Seite"); if ("template" in p) { if (typeof p.template !== "string" || !TEMPLATES.includes(p.template)) fail("invalidContent", "Vorlage"); out.template = p.template; } }
  if (!Array.isArray(p.objects)) fail("invalidContent", "Objekte");
  if (p.objects.length > LIMITS.maxObjectsPerPage) fail("tooLarge");
  p.objects.forEach(validateObject); out.objects = p.objects;
  return out;
}

/** Inhalt lesen und vollstaendig pruefen (SolutionContent(json:)). Bilder bleiben Base64 ({mime, data}). */
export function validateContent(j) {
  if (!isObj(j) || j.format !== CONTENT_FORMAT) fail("invalidContent", "Formatkennung");
  const v = exactInt(j.formatVersion); if (v === null) fail("invalidContent", "Formatversion"); if (v !== CONTENT_VERSION) fail("unsupportedVersion", v);
  checkFinite(j);
  if (!isUUID(j.solutionId)) fail("invalidContent", "Lösungs-ID");
  if (!isDate(j.createdAt)) fail("invalidContent", "Erstellungsdatum");
  if (typeof j.title !== "string" || len(j.title) > LIMITS.maxTitle) fail("invalidContent", "Titel");
  if (typeof j.displayName !== "string" || len(j.displayName) > LIMITS.maxDisplayName) fail("invalidContent", "Anzeigename");
  if (!isHex64(j.document?.sha256)) fail("invalidContent", "Fingerabdruck");
  const count = exactInt(j.document?.pageCount); if (count === null || count < 1 || count > LIMITS.maxPDFPages) fail("invalidContent", "Seitenzahl");
  if (!Array.isArray(j.pages) || !j.pages.length) fail("invalidContent", "Seiten");
  if (j.pages.length > LIMITS.maxPages) fail("tooLarge");
  const keys = new Set(), idx = new Set(); let total = 0; const pages = [];
  for (const raw of j.pages) {
    const p = validatePage(raw, count);
    if (keys.has(p.key)) fail("invalidContent", "doppelte Seite"); keys.add(p.key);
    if (p.pdfIndex != null) { if (idx.has(p.pdfIndex)) fail("invalidContent", "doppelte PDF-Seite"); idx.add(p.pdfIndex); }
    total += p.objects.length; if (total > LIMITS.maxObjects) fail("tooLarge");
    pages.push(p);
  }
  if (!isObj(j.images)) fail("invalidContent", "Bilder");
  if (Object.keys(j.images).length > LIMITS.maxImages) fail("tooLarge");
  const images = {};
  for (const [src, img] of Object.entries(j.images)) {
    const data = isObj(img) && ["image/png", "image/jpeg"].includes(img.mime) ? b64decode(img.data) : null;
    if (!data) fail("invalidContent", "Bild");
    if (data.length > LIMITS.maxImageBytes) fail("tooLarge");
    if (sniffImage(data) !== img.mime) fail("invalidContent", "Bilddaten");
    images[src] = { mime: img.mime, data: img.data };
  }
  if (!Array.isArray(j.missingImages) || j.missingImages.some(s => typeof s !== "string")) fail("invalidContent", "fehlende Bilder");
  checkNoPDF(j.missingImages, "src"); checkNoPDF(Object.keys(images), "src");
  return { format: CONTENT_FORMAT, formatVersion: CONTENT_VERSION, solutionId: j.solutionId.toLowerCase(), createdAt: j.createdAt, title: j.title,
           displayName: j.displayName, document: { sha256: j.document.sha256, pageCount: count }, pages: pages.map(pageJSON), images, missingImages: j.missingImages.slice() };
}
function pageJSON(p) {
  const o = { key: p.key, kind: p.kind, width: p.width, height: p.height, rotation: normRot(p.rotation), extraRotation: normRot(p.extraRotation), objects: p.objects };
  if (p.pdfIndex != null) o.pdfIndex = p.pdfIndex;
  if (p.template != null) o.template = p.template;
  return o;
}

// ---------------------------------------------------------------- Version 2: Striche als ganze Zahlen, raw DEFLATE

/** Wie Python `math.floor(v * scale + 0.5)` und Swift `(v * scale + 0.5).rounded(.down)`. */
const quantize = (v, scale) => Math.floor(v * scale + 0.5);
const encodable = (a, scale) => Array.isArray(a) && a.every(x => typeof x === "number" && Number.isFinite(x) && Math.abs(x) * scale <= MAX_QUANT);

/** Strich im Speicher -> Version 2; andere Objekte und nicht kodierbare Listen bleiben unveraendert. */
export function encodeObject(o) {
  if (!isObj(o) || o.type !== "stroke") return o;
  if (DELTA_FIELDS.some(([, d]) => d in o)) fail("invalidContent", "reserviertes Feld");
  const out = { ...o };
  for (const [field, dfield, scale, step] of DELTA_FIELDS) {
    if (!(field in o) || !encodable(o[field], scale)) continue;
    const q = o[field].map(x => quantize(x, scale));
    out[dfield] = q.map((v, i) => v - (i >= step ? q[i - step] : 0)); delete out[field];
  }
  return out;
}
/** Strich aus Version 2 -> Punkte als Zahlenliste in Seitenpunkten. */
export function decodeObject(o) {
  if (!isObj(o) || o.type !== "stroke") return o;
  const out = { ...o };
  for (const [field, dfield, scale, step] of DELTA_FIELDS) {
    if (!(dfield in o)) continue;
    const a = o[dfield];
    if (field in o || !Array.isArray(a)) fail("invalidContent", "Strich");
    const q = [];
    for (let i = 0; i < a.length; i++) {
      const d = a[i];
      if (typeof d !== "number" || !Number.isInteger(d) || Math.abs(d) > 2 * MAX_QUANT) fail("invalidContent", "Strich");
      const v = d + (i >= step ? q[i - step] : 0);
      if (Math.abs(v) > MAX_QUANT) fail("invalidContent", "Strich");
      q.push(v);
    }
    out[field] = q.map(v => v / scale); delete out[dfield];
  }
  return out;
}
const mapObjects = (c, fn, version) => ({ ...c, formatVersion: version,
  ...(Array.isArray(c.pages) ? { pages: c.pages.map(p => (isObj(p) && Array.isArray(p.objects) ? { ...p, objects: p.objects.map(fn) } : p)) } : {}) });
/** Inhalt im Speicher (Version 1) -> Klartext von Version 2. */
export const encodeContent = c => mapObjects(c, encodeObject, 2);
/** Klartext von Version 2 -> Inhalt im Speicher (Version 1). */
export function decodeContent(j) {
  if (!isObj(j) || j.format !== CONTENT_FORMAT) fail("invalidContent", "Formatkennung");
  const v = exactInt(j.formatVersion); if (v === null) fail("invalidContent", "Formatversion"); if (v !== 2) fail("unsupportedVersion", v);
  return mapObjects(j, decodeObject, CONTENT_VERSION);
}
/** Kanonischer Klartext von Version 2 vor dem Packen (byte-gleich mit Python und Swift). */
export const plaintextBytes = content => utf8(canonical(encodeContent(content)));

/** Bytes durch einen (De-)Kompressionsstrom; mehr als `limit` Byte heraus: tooLarge (Schutz vor Zip-Bomben). */
async function pipe(u8, stream, limit) {
  const writer = stream.writable.getWriter(), reader = stream.readable.getReader();
  const written = writer.write(u8).then(() => writer.close()).catch(() => {});
  const parts = []; let total = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > limit) { reader.cancel().catch(() => {}); fail("tooLarge"); }
      parts.push(value);
    }
  } catch (e) { if (e instanceof SolutionError) throw e; fail("invalidContent", "Kompression"); }
  await written;
  const out = new Uint8Array(total); let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}
const needStreams = () => { if (typeof CompressionStream === "undefined" || typeof DecompressionStream === "undefined") throw new SolutionError("noCompression", "Packen ist in diesem Browser nicht verfügbar – bitte aktualisieren."); };
export async function deflateRaw(u8) { needStreams(); return pipe(u8, new CompressionStream(COMPRESSION), Infinity); }
export async function inflateRaw(u8, limit) { needStreams(); return pipe(u8, new DecompressionStream(COMPRESSION), limit); }

// ---------------------------------------------------------------- Kopf, Paket

function headerJSON(c, salt, nonce, plaintextBytes, compressedBytes) {
  const encryption = { cipher: "AES-256-GCM", kdf: "HKDF-SHA256", keyMaterial: "original-pdf-bytes", salt: b64encode(salt), nonce: b64encode(nonce), plaintextBytes };
  if (compressedBytes != null) Object.assign(encryption, { compression: COMPRESSION, compressedBytes });
  return { solutionId: c.solutionId, createdAt: c.createdAt, displayName: c.displayName,
           document: { sha256: c.document.sha256, pageCount: c.document.pageCount },
           contents: { pages: c.pages.length, images: Object.keys(c.images).length, missingImages: c.missingImages.length }, encryption };
}
export const aadBytes = (header, version = FORMAT_VERSION) => utf8(canonical({ format: FORMAT, formatVersion: version, header }));

/** Kopf pruefen wie SolutionPackage.decode (ohne PDF). Liefert {version, header, sealed, salt, nonce}. */
export function decodePackage(pkg) {
  if (typeof pkg === "string") { try { pkg = JSON.parse(pkg); } catch { fail("notASolution"); } }
  if (!isObj(pkg) || pkg.format !== FORMAT) fail("notASolution");
  const v = exactInt(pkg.formatVersion); if (v === null) fail("invalidHeader", "Formatversion"); if (!READ_VERSIONS.includes(v)) fail("unsupportedVersion", v);
  if (Object.keys(pkg).sort().join() !== "ciphertext,format,formatVersion,header") fail("invalidHeader", "unbekannte Felder");
  checkFinite(pkg);
  const h = pkg.header; if (!isObj(h)) fail("invalidHeader", "fehlt");
  if (!isUUID(h.solutionId)) fail("invalidHeader", "Lösungs-ID");
  if (!isDate(h.createdAt)) fail("invalidHeader", "Erstellungsdatum");
  if (typeof h.displayName !== "string" || len(h.displayName) > LIMITS.maxDisplayName) fail("invalidHeader", "Anzeigename");
  if (!isHex64(h.document?.sha256)) fail("invalidHeader", "Fingerabdruck");
  const count = exactInt(h.document?.pageCount); if (count === null || count < 1 || count > LIMITS.maxPDFPages) fail("invalidHeader", "Seitenzahl");
  const pages = exactInt(h.contents?.pages), images = exactInt(h.contents?.images), missing = exactInt(h.contents?.missingImages);
  if (pages === null || pages < 1 || pages > LIMITS.maxPages || images === null || images < 0 || images > LIMITS.maxImages || missing === null || missing < 0 || missing > LIMITS.maxObjects) fail("invalidHeader", "Inhaltsangaben");
  const e = h.encryption;
  if (e?.cipher !== "AES-256-GCM" || e?.kdf !== "HKDF-SHA256" || !["original-pdf-bytes", "community-secret"].includes(e?.keyMaterial)) fail("invalidHeader", "Verfahren");
  const salt = b64decode(e.salt); if (!salt || salt.length !== 32) fail("invalidHeader", "Salz");
  const nonce = b64decode(e.nonce); if (!nonce || nonce.length !== 12) fail("invalidHeader", "Nonce");
  const size = exactInt(e.plaintextBytes); if (size === null || size < 1 || size > LIMITS.maxPlaintextBytes) fail("invalidHeader", "Größe");
  let packed = size;
  if (v === 2) {
    if (e.compression !== COMPRESSION) fail("invalidHeader", "Kompression");
    packed = exactInt(e.compressedBytes); if (packed === null || packed < 1 || packed > LIMITS.maxPlaintextBytes) fail("invalidHeader", "Größe");
  }
  const header = { solutionId: h.solutionId.toLowerCase(), createdAt: h.createdAt, displayName: h.displayName, document: { sha256: h.document.sha256, pageCount: count },
                   contents: { pages, images, missingImages: missing }, encryption: { cipher: e.cipher, kdf: e.kdf, keyMaterial: e.keyMaterial, salt: b64encode(salt), nonce: b64encode(nonce), plaintextBytes: size } };
  if (v === 2) Object.assign(header.encryption, { compression: COMPRESSION, compressedBytes: packed });
  // Kopf genau in der Form seiner Version (die AAD wird aus dem geprueften Kopf gebildet)
  if (canonical(header) !== canonical(h)) fail("invalidHeader", "unbekannte Felder");
  const sealed = b64decode(pkg.ciphertext); if (!sealed) fail("invalidHeader", "Chiffrat");
  if (sealed.length !== packed + TAG_BYTES) fail("invalidHeader", "Größe");
  return { version: v, header, sealed, salt, nonce };
}

/** Inhalt mit der Original-PDF verschluesseln (SolutionPackage.seal). `salt`/`nonce` nur fuer Testvektoren. */
export async function seal(content, pdfBytes, { salt, nonce, secret } = {}) {
  if (!secret && await sha256Hex(pdfBytes) !== content.document.sha256) fail("fingerprintMismatch");
  checkStrokeSizes(content);
  const checked = validateContent(content);
  if (canonical(checked) !== canonical(content)) fail("invalidContent", "nicht verlustfrei");
  const plaintext = plaintextBytes(content);
  if (plaintext.length > LIMITS.maxPlaintextBytes) fail("tooLarge");
  const packed = await deflateRaw(plaintext);
  if (packed.length > LIMITS.maxPlaintextBytes) fail("tooLarge");
  salt = salt || randomBytes(32); nonce = nonce || randomBytes(12);
  const header = headerJSON(content, salt, nonce, plaintext.length, packed.length);
  if (secret) header.encryption.keyMaterial = "community-secret";
  const key = await aesKey(secret || pdfBytes, salt, keyInfo(header.solutionId));
  const ct = new Uint8Array(await subtle().encrypt({ name: "AES-GCM", iv: nonce, additionalData: aadBytes(header), tagLength: 128 }, key, packed));
  if (ct.length !== packed.length + TAG_BYTES) fail("invalidContent", "Verschlüsselung");
  return { format: FORMAT, formatVersion: FORMAT_VERSION, header, ciphertext: b64encode(ct) };
}
export const encodePackage = pkg => canonical(pkg);

/** Mit der eigenen PDF entschluesseln und pruefen (SolutionPackage.open). Fingerabdruck falsch: gar nicht erst. */
export async function openPackage(pkg, pdfBytes, fingerprint = null, secret = null) {
  const { version, header, sealed, salt, nonce } = decodePackage(pkg);
  const community = header.encryption.keyMaterial === "community-secret";
  if (community ? !secret : (fingerprint || await sha256Hex(pdfBytes)) !== header.document.sha256) fail(community ? "decryptionFailed" : "fingerprintMismatch");
  let plain;
  try {
    const key = await aesKey(community ? secret : pdfBytes, salt, keyInfo(header.solutionId, version));
    plain = new Uint8Array(await subtle().decrypt({ name: "AES-GCM", iv: nonce, additionalData: aadBytes(header, version), tagLength: 128 }, key, sealed));
  } catch { fail("decryptionFailed"); }
  // harte Obergrenze: nie mehr entpacken als der (authentifizierte) Kopf angibt
  if (version === 2) plain = await inflateRaw(plain, header.encryption.plaintextBytes);
  if (plain.length !== header.encryption.plaintextBytes) fail("invalidContent", "Größe");
  let j; try { j = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain)); } catch { fail("invalidContent", "JSON"); }
  checkStrokeSizes(j);
  const c = validateContent(version === 2 ? decodeContent(j) : j);
  if (c.solutionId !== header.solutionId || c.document.sha256 !== header.document.sha256 || c.document.pageCount !== header.document.pageCount ||
      c.createdAt !== header.createdAt || c.displayName !== header.displayName || c.pages.length !== header.contents.pages ||
      Object.keys(c.images).length !== header.contents.images || c.missingImages.length !== header.contents.missingImages) fail("invalidContent", "passt nicht zum Kopf");
  return c;
}

// ---------------------------------------------------------------- Erzeugen aus dem Notizmodell (SolutionBuilder)

export const timestamp = (d = new Date()) => d.toISOString().replace(/\.\d{3}Z$/, "Z");
export function uuid() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  const b = randomBytes(16); b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
export const shareable = entry => (entry.type || "pdf") === "pdf" || entry.type === "blank";

/** Eigene Bilder der Seiten (Quelle `src`), sortiert. */
export function imageSources(model, keys) {
  const out = new Set();
  for (const k of keys) for (const o of model.pages?.[k]?.objects || []) if (o.type === "image" && typeof o.src === "string" && o.src) out.add(o.src);
  return [...out].sort();
}

/**
 * Inhalt bauen. `model`: Notizmodell des Editors (pageOrder, pages[key].objects). `pdfPage(i)`: {width, height,
 * rotation} der PDF-Seite i (CropBox ohne Drehung, /Rotate) oder null. `images`: {src: {mime, data: Uint8Array}}.
 */
export function buildContent({ model, selectedKeys, pdfPageCount, pdfPage, images = {}, fingerprint, title = "", displayName = "",
                               solutionId = uuid(), createdAt = new Date(), requireOwnNotes = true }) {
  const wanted = new Set(selectedKeys || []); if (!wanted.size) fail("nothingSelected");
  const pages = [], seen = new Set();
  model.pageOrder.forEach((entry, i) => {
    const key = entry.key; if (!wanted.has(key) || seen.has(key)) return; seen.add(key);
    const type = entry.type || "pdf"; const extra = normRot(entry.rotation || 0);
    const objects = JSON.parse(JSON.stringify(model.pages?.[key]?.objects || []));
    const label = type === "pdf" ? `Seite ${i + 1}` : type === "blank" ? `Eigene Seite ${i + 1}` : `Eingefügte Seite ${i + 1}`;
    try { objects.forEach(validateObject); } catch (e) { e.message = `${label}: ${e.message}`; throw e; }
    if (type === "pdf") {
      const info = entry.index >= 1 && entry.index <= pdfPageCount ? pdfPage(entry.index) : null;
      if (!info) { const e = new SolutionError("pageNotInPDF", `${label}: ${MSG.pageNotInPDF}`); throw e; }
      pages.push({ key, kind: "pdf", pdfIndex: entry.index, width: info.width, height: info.height, rotation: normRot(info.rotation + extra), extraRotation: extra, objects });
    } else if (type === "blank") {
      const t = entry.template || model.pages?.[key]?.template;
      const p = { key, kind: "blank", width: entry.w || 595, height: entry.h || 842, rotation: extra, extraRotation: extra, objects };
      p.template = TEMPLATES.includes(t) ? t : "blank";
      pages.push(p);
    } else fail("invalidContent", "eingefügte Bild-/PDF-Seite");
  });
  if (!pages.length) fail("nothingSelected");
  if (requireOwnNotes && !pages.some(p => p.objects.length)) fail("noOwnNotes");
  const embedded = {}, missing = [];
  for (const src of imageSources(model, pages.map(p => p.key))) {
    const img = images[src];
    if (img && sniffImage(img.data) === img.mime) embedded[src] = { mime: img.mime, data: b64encode(img.data) }; else missing.push(src);
  }
  const content = { format: CONTENT_FORMAT, formatVersion: CONTENT_VERSION, solutionId: String(solutionId).toLowerCase(),
                    createdAt: typeof createdAt === "string" ? createdAt : timestamp(createdAt), title: [...String(title).trim()].slice(0, LIMITS.maxTitle).join(""),
                    displayName: [...String(displayName).trim()].slice(0, LIMITS.maxDisplayName).join(""),
                    document: { sha256: String(fingerprint).toLowerCase(), pageCount: pdfPageCount }, pages, images: embedded, missingImages: missing };
  return validateContent(content);
}

// ---------------------------------------------------------------- Zusammenfuehren (03.11.2026)
// Eine Loesung je Konto, PDF und Community: teilt jemand erneut zu derselben PDF, fragt die Seite "Aktualisieren?" und
// fuehrt die neuen Seiten mit der bisherigen Loesung zusammen (Referenz app/solution_format.merge_contents, Swift
// SolutionBuilder.merge; gemeinsame Faelle packages/shared-contracts/fixtures/solutions/merge-cases.json).

/** Seite aus einem mitgeteilten Notizblatt ("nb-…", "nb2-…"), wie SolutionBuilder.isNotebookKey. */
export const isNotebookKey = key => /^nb\d*-/.test(key);

function mergeRanks(pages, source) {
  let anchor = 0;
  return pages.map((p, i) => {
    if (p.kind === "pdf") { anchor = p.pdfIndex; return { rank: [anchor, 0, source, i], p }; }
    return { rank: [isNotebookKey(p.key) ? Infinity : anchor, 1, source, i], p };
  });
}
function pageImageSources(pages) {
  const out = new Set();
  for (const p of pages) for (const o of p.objects || []) if (o && o.type === "image" && typeof o.src === "string" && o.src) out.add(o.src);
  return [...out].sort();
}

/**
 * Bisherige Loesung `previous` und neue Fassung `next` (geoeffneter Inhalt) zusammenfuehren: dieselbe PDF-Seite oder
 * derselbe Seitenschluessel wird ersetzt, andere Seiten kommen dazu; Reihenfolge nach PDF-Seite (Leerseiten hinter der
 * PDF-Seite, der sie folgten, Notizblatt hinten). ID und Erstellungsdatum bleiben, Titel und Name kommen aus `next`.
 */
export function mergeContent(previous, next) {
  if (previous.document.sha256 !== next.document.sha256) fail("fingerprintMismatch");
  const newPdf = new Set(next.pages.filter(p => p.kind === "pdf").map(p => p.pdfIndex));
  const newKeys = new Set(next.pages.map(p => p.key));
  const replaced = p => (p.kind === "pdf" && newPdf.has(p.pdfIndex)) || newKeys.has(p.key);
  const ranked = [...mergeRanks(previous.pages, 0).filter(x => !replaced(x.p)), ...mergeRanks(next.pages, 1)];
  const cmp = (a, b) => { for (let i = 0; i < 4; i++) if (a.rank[i] !== b.rank[i]) return a.rank[i] < b.rank[i] ? -1 : 1; return 0; };
  const pages = ranked.sort(cmp).map(x => x.p);
  const used = pageImageSources(pages), images = {};
  for (const src of used) { const img = next.images?.[src] || previous.images?.[src]; if (img) images[src] = img; }
  return validateContent({ ...next, solutionId: previous.solutionId, createdAt: previous.createdAt, pages, images,
                           missingImages: used.filter(s => !images[s]) });
}

export const UPDATE_QUESTION = "Du hast zu dieser PDF schon eine Lösung geteilt. Aktualisieren?";

/**
 * In eine Community veroeffentlichen, hoechstens eine Loesung je PDF: gibt es schon eine eigene (vorher gefragt bei
 * `/mine`, sonst 409 `already_published`), fragt `confirmUpdate()`; bei Ja wird die bisherige Loesung geladen, mit dem
 * Community-Schluessel geoeffnet, zusammengefuehrt, neu versiegelt und per PUT ersetzt. `call(path, {method, body})`
 * spricht /api/community an und wirft Fehler mit `code` und `data` (Antwort des Dienstes).
 * Ergebnis: {published | updated | cancelled, solutionId, pages}.
 */
export async function shareToCommunity({ content, space, call, confirmUpdate }) {
  const title = content.title || null;
  const own = async () => {
    const mine = (await call("/mine")).solutions || [];
    return mine.filter(s => s.fingerprint === content.document.sha256 && s.community_key === space.key && ["active", "hidden"].includes(s.status))
      .sort((a, b) => String(b.published_at).localeCompare(String(a.published_at)))[0]?.solution_id || null;
  };
  let existing = await own();
  if (!existing) {
    try {
      const sealed = await seal(content, null, { secret: space.secret });
      const r = await call("/solutions", { method: "POST", body: { package: sealed, title, community_key: space.key } });
      return { published: true, solutionId: r?.solution_id || content.solutionId, pages: content.pages.length };
    } catch (e) {
      if (e.code !== "already_published") throw e;
      existing = e.data?.solution_id || await own();
      if (!existing) throw e;
    }
  }
  if (!(await confirmUpdate())) return { cancelled: true, solutionId: existing, pages: 0 };
  const { package: pkg } = await call(`/solutions/${existing}`);
  const previous = await openPackage(pkg, null, null, space.secret);
  const merged = mergeContent(previous, content);
  const sealed = await seal(merged, null, { secret: space.secret });
  await call(`/solutions/${existing}`, { method: "PUT", body: { package: sealed, title, community_key: space.key } });
  return { updated: true, solutionId: existing, pages: merged.pages.length };
}

// ---------------------------------------------------------------- Anzeige beim Empfaenger (SolutionGeometry)

/** Seitenbox ohne Drehung -> angezeigte Seite (im Uhrzeigersinn), Matrix [a, b, c, d, tx, ty]. */
export function fromUnrotated(W, H, rotation) {
  switch (normRot(rotation)) {
    case 90: return [0, 1, -1, 0, H, 0];
    case 180: return [-1, 0, 0, -1, W, H];
    case 270: return [0, -1, 1, 0, 0, W];
    default: return [1, 0, 0, 1, 0, 0];
  }
}
const invert = ([a, b, c, d, tx, ty]) => { const det = a * d - b * c; if (!det) return [1, 0, 0, 1, 0, 0]; const ia = d / det, ib = -b / det, ic = -c / det, id = a / det; return [ia, ib, ic, id, -(ia * tx + ic * ty), -(ib * tx + id * ty)]; };
const then = ([a, b, c, d, tx, ty], [A, B, C, D, TX, TY]) => [A * a + C * b, B * a + D * b, A * c + C * d, B * c + D * d, A * tx + C * ty + TX, B * tx + D * ty + TY];
/** Anzeige des Absenders (Drehung `from`) -> eigene Anzeige (Drehung `to`) fuer dieselbe Seitenbox. */
export function transform(W, H, from, to) {
  if (normRot(from) === normRot(to)) return [1, 0, 0, 1, 0, 0];
  return then(invert(fromUnrotated(W, H, from)), fromUnrotated(W, H, to));
}
export const applyT = ([a, b, c, d, tx, ty], x, y) => [a * x + c * y + tx, b * x + d * y + ty];
export const displaySize = p => (normRot(p.rotation) % 180 ? [p.height, p.width] : [p.width, p.height]);

/**
 * Passt der Inhalt zur eigenen PDF? `pdf`: {pageCount, page(i) -> {width, height, rotation}}. Wie
 * SolutionSharing.layer auf dem iPad: Seitenzahl, Groesse (< 0,5 pt) und /Rotate + extraRotation == rotation.
 * Liefert null oder die Meldung.
 */
export function mismatch(content, pdf) {
  if (content.document.pageCount !== pdf.pageCount) return MSG.fingerprintMismatch;
  for (const p of content.pages) {
    if (p.kind !== "pdf") continue;
    const info = pdf.page(p.pdfIndex);
    if (!info) return MSG.fingerprintMismatch;
    if (Math.abs(info.width - p.width) >= 0.5 || Math.abs(info.height - p.height) >= 0.5 || normRot(info.rotation + p.extraRotation) !== p.rotation)
      return `Die Lösung ist beschädigt (Inhalt: Seite ${p.pdfIndex} passt nicht zur PDF).`;
  }
  return null;
}

// ---------------------------------------------------------------- Community (ohne DOM)

export const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function normalizedCode(raw) {
  const c = String(raw || "").toUpperCase().replace(/[\s-]/g, "");
  return c.length === 8 && [...c].every(x => CODE_ALPHABET.includes(x)) ? c : null;
}

/** Notizen einer Seite auf einen Canvas-Kontext zeichnen, in Punkten der Seite (ohne PDF). */
export function drawObjects(ctx, page, images = {}) {
  for (const o of page.objects || []) {
    ctx.save();
    ctx.translate(o.x || 0, o.y || 0); ctx.rotate((o.rotation || 0) * Math.PI / 180); ctx.scale(o.scaleX || 1, o.scaleY || 1);
    ctx.globalAlpha = o.opacity ?? 1; ctx.lineCap = "round"; ctx.lineJoin = "round";
    const poly = (p, close) => { ctx.beginPath(); for (let i = 0; i + 1 < p.length; i += 2) i ? ctx.lineTo(p[i], p[i + 1]) : ctx.moveTo(p[i], p[i + 1]); if (close) ctx.closePath(); };
    if (o.type === "stroke" && o.points?.length >= 2) { ctx.strokeStyle = o.color || "#000"; ctx.lineWidth = o.width || 1; poly(o.points); ctx.stroke(); }
    else if (o.type === "text") {
      const size = o.fontSize || 14; ctx.font = `${o.italic ? "italic " : ""}${o.bold ? "bold " : ""}${size}px ${o.fontFamily || "sans-serif"}`;
      const lines = String(o.text || "").split("\n");
      if (o.bg) { ctx.fillStyle = o.bg; ctx.fillRect(0, 0, o.width || 200, lines.length * size * 1.2); }
      ctx.fillStyle = o.fill || "#000"; ctx.textBaseline = "top"; lines.forEach((l, i) => ctx.fillText(l, 0, i * size * 1.2));
    } else if (o.type === "shape") {
      ctx.strokeStyle = o.stroke || "#000"; ctx.lineWidth = o.strokeWidth || 1; ctx.fillStyle = o.fill || "transparent";
      const w = o.width || 0, h = o.height || 0;
      if (o.shape === "rect") { ctx.beginPath(); ctx.rect(0, 0, w, h); }
      else if (o.shape === "ellipse") { ctx.beginPath(); ctx.ellipse(w / 2, h / 2, w / 2, h / 2, 0, 0, Math.PI * 2); }
      else if (o.shape === "triangle") poly([w / 2, 0, w, h, 0, h], true);
      else poly(o.points || [], o.shape === "polygon");
      if (o.fill) ctx.fill(); ctx.stroke();
    } else if (o.type === "image" && images[o.src]) ctx.drawImage(images[o.src], 0, 0, o.width || 0, o.height || 0);
    ctx.restore();
  }
}
