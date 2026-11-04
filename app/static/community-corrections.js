// Korrekturvorschlaege (03.11.2026): Chiffrat, Pruefung und Texte ohne DOM, wie CommunityCorrection.swift auf dem iPad
// (apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Solutions/CommunityCorrection.swift) und die Referenz
// app/community_corrections.py. Laeuft auch unter Node (tests/js/community-corrections.test.mjs) gegen die gemeinsamen
// Vektoren packages/shared-contracts/fixtures/community/correction-vectors.json.
//
// Ein Mitglied markiert auf einer fremden, geteilten Loesung (Striche, Randnotizen an einer Stelle, Begleittext) und schickt
// das dem Ersteller. Die Loesung bleibt unveraendert. Seiten wie im Loesungspaket (CropBox ohne Drehung, `rotation` =
// angezeigte Drehung beim Korrigierenden, Striche in diesen Koordinaten), Randnotizen x, y in 0..1 der angezeigten Seite.
// Chiffrat: Version 1 (1 Byte), Salz (32), Nonce (12), AES-256-GCM ueber den mit raw DEFLATE gepackten kanonischen
// Klartext (Version 2); Schluessel per HKDF-SHA256 aus dem Community-Geheimnis, Info
// "uniflow-community-correction/v1|<loesung>", Zusatzdaten "...|<loesung>|<korrektur>".
import * as S from "./solutions.js?v=6";

export const FORMAT = "uniflow-community-correction";
export const CONTENT_VERSION = 2;
export const PAYLOAD_VERSION = 1;
export const MAX_TEXT = 2000;
export const MAX_NOTES_PER_PAGE = 50;
export const MAX_PAGES = 300;
export const MAX_PLAINTEXT_BYTES = 8 << 20;
export const MAX_PAYLOAD_CHARS = 750000;
const SALT = 32, NONCE = 12, TAG = 16;

const err = (code, message) => new S.SolutionError(code, message);
const chars = s => [...String(s)].length;
const subtle = () => { const c = globalThis.crypto?.subtle; if (!c) throw err("noCrypto", "Verschlüsselung ist hier nicht verfügbar (nur in der App am PC oder über https)."); return c; };

export const TEXTS = {
  action: "Korrektur vorschlagen",
  needsPDF: "Lade die PDF, um zu korrigieren.",
  needsPDFToView: "Lade die PDF, um die Korrektur anzusehen.",
  reported: "Danke – die Korrektur wurde gemeldet.",
  deleted: "Deine Korrektur wurde zurückgenommen.",
  sent: "Deine Korrektur ist unterwegs. Der Ersteller bekommt einen Hinweis.",
  sectionTitle: "Korrekturvorschläge",
  sectionNotice: "Korrekturen ändern die Lösung nicht. Mit „Ansehen“ liegen sie in deiner PDF über der Lösung.",
  empty: "Die Korrektur ist leer: markiere etwas oder schreibe eine Notiz.",
  seen: "Gesehen",
  inboxEmpty: "Keine Korrekturhinweise. Wenn jemand deine geteilte Lösung korrigiert, siehst du das hier.",
};
export const strokes = n => (n === 1 ? "1 Markierung" : `${n} Markierungen`);
export const notes = n => (n === 1 ? "1 Randnotiz" : `${n} Randnotizen`);
export const seenGroup = n => `Gesehen (${n})`;
export const editorHint = n => (n === 1 ? "1 Korrekturhinweis zu deiner Lösung" : `${n} Korrekturhinweise zu deiner Lösung`);
export const discussionTab = (comments, corrections) => `Diskussion (${comments + corrections})`;
export const entryTitle = c => `Korrekturvorschlag von ${displayName(c)}`;
export const displayName = c => (String(c?.pseudonym || "").trim() || "Anonym");
/** "Deine Lösung „Blatt 3“ hat einen Korrekturhinweis von Ben bekommen" (ohne Titel: "Deine Lösung hat …"). */
export function inboxMessage(c, title = "") {
  const t = String(title || "").trim();
  return `Deine Lösung${t ? ` „${t}“` : ""} hat einen Korrekturhinweis von ${displayName(c)} bekommen`;
}
export const strokeCount = c => (c.pages || []).reduce((n, p) => n + (p.strokes || []).length, 0);
export const noteCount = c => (c.pages || []).reduce((n, p) => n + (p.notes || []).length, 0);
export const summary = c => `${strokes(strokeCount(c))} · ${notes(noteCount(c))}`;
export const isEmpty = c => !strokeCount(c) && !noteCount(c) && !String(c.note || "").trim();
/** Zahl am Menuepunkt: leer ohne offene Hinweise, "99+" ab 100. */
export const badgeText = n => (n > 0 ? (n > 99 ? "99+" : String(n)) : "");

/**
 * Was die Leiste unter fremden Notizen zu "Korrektur vorschlagen" anbietet (CorrectionOffer.resolve):
 * "hidden" (eigene Notizen oder Dienst ohne Korrekturen), "locked" (Tarif ohne Teilen), "checking" (eigene PDF wird gesucht),
 * "needsPDF" (PDF fehlt), "ready". `localFile`: undefined = noch nicht gesucht, null = keine eigene Datei, sonst die Datei.
 */
export function offer({ own, supported = true, canShare, localFile }) {
  if (!supported || own) return "hidden";
  if (!canShare) return "locked";
  if (localFile === undefined) return "checking";
  return localFile ? "ready" : "needsPDF";
}

/** Eintrag des Posteingangs oder der Liste fuer die Oberflaeche: offen / gesehen / ignoriert. */
export const isOpen = c => (c.status || "open") === "open";
export const isSeen = c => c.status === "seen";
/** Gruppen des Posteingangs: offene zuerst, "Gesehen" eingeklappt (ignorierte fehlen schon beim Dienst). */
export function groupInbox(items) {
  const list = (items || []).filter(c => c.status !== "ignored");
  return { open: list.filter(isOpen), seen: list.filter(isSeen) };
}

// ---------------------------------------------------------------- Pruefen

function cleanText(text, allowEmpty) {
  const t = String(text ?? "").trim();
  if (!t && !allowEmpty) throw err("noteEmpty", "Die Randnotiz ist leer.");
  if (chars(t) > MAX_TEXT) throw err("textTooLong", `Höchstens ${MAX_TEXT} Zeichen.`);
  return t;
}

/** Korrektur pruefen und bereinigen (Texte getrimmt, leere Seiten weg, nach Seite sortiert), wie CommunityCorrections.validated. */
export function validated(c) {
  const out = { id: String(c.id).toLowerCase(), solution_id: String(c.solution_id).toLowerCase(), pseudonym: String(c.pseudonym ?? ""),
                created_at: String(c.created_at), note: cleanText(c.note, true), pages: [] };
  if (!out.id || out.id.length > 64 || !out.solution_id || out.solution_id.length > 64) throw err("invalidContent", "Kennung");
  if (chars(out.pseudonym) > S.LIMITS.maxDisplayName) throw err("invalidContent", "Pseudonym");
  const seen = new Set();
  for (const p of c.pages || []) {
    if (!Number.isInteger(p.pdfIndex) || p.pdfIndex < 1 || p.pdfIndex > S.LIMITS.maxPDFPages) throw err("invalidContent", "PDF-Seite");
    if (!(p.width > 0) || !(p.height > 0) || p.width > S.LIMITS.maxPageSide || p.height > S.LIMITS.maxPageSide) throw err("invalidContent", "Seitengröße");
    if (!Number.isInteger(p.rotation ?? 0) || (p.rotation ?? 0) % 90) throw err("invalidContent", "Drehung");
    const strokesOf = p.strokes || [], notesOf = p.notes || [];
    if (strokesOf.length > S.LIMITS.maxObjectsPerPage) throw err("tooLarge", "Die Korrektur ist zu groß.");
    for (const o of strokesOf) { S.validateObject(o); if (o.type !== "stroke") throw err("unsupportedObjectType", `Die Lösung enthält einen unbekannten Objekttyp („${o.type}“).`); }
    if (notesOf.length > MAX_NOTES_PER_PAGE) throw err("tooManyNotes", `Höchstens ${MAX_NOTES_PER_PAGE} Randnotizen je Seite.`);
    const cleaned = notesOf.map(n => {
      if (![n.x, n.y].every(v => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1)) throw err("anchorInvalid", "Ungültige Stelle (x und y zwischen 0 und 1).");
      if (!n.id || String(n.id).length > 64) throw err("invalidContent", "Notiz-ID");
      return { id: String(n.id), x: n.x, y: n.y, text: cleanText(n.text, false) };
    });
    if (!strokesOf.length && !cleaned.length) continue;
    if (seen.has(p.pdfIndex)) throw err("invalidContent", "doppelte Seite");
    seen.add(p.pdfIndex);
    out.pages.push({ pdfIndex: p.pdfIndex, width: p.width, height: p.height, rotation: S.normRot(p.rotation ?? 0), strokes: strokesOf, notes: cleaned });
  }
  if (out.pages.length > MAX_PAGES) throw err("tooLarge", "Die Korrektur ist zu groß.");
  out.pages.sort((a, b) => a.pdfIndex - b.pdfIndex);
  if (!out.pages.length && !out.note) throw err("empty", TEXTS.empty);
  return out;
}

// ---------------------------------------------------------------- Klartext und Chiffrat

const pageJSON = p => ({ key: `c${p.pdfIndex}`, kind: "pdf", pdfIndex: p.pdfIndex, width: p.width, height: p.height, rotation: S.normRot(p.rotation ?? 0),
                         extraRotation: 0, objects: (p.strokes || []).map(S.encodeObject), notes: (p.notes || []).map(n => ({ id: n.id, x: n.x, y: n.y, text: n.text })) });

/** Kanonischer Klartext von Version 2 (byte-gleich mit Python und Swift). `c` ist schon geprueft (`validated`). */
export function plaintext(c) {
  return S.utf8(S.canonical({ format: FORMAT, formatVersion: CONTENT_VERSION, correctionID: c.id, solutionID: c.solution_id, pseudonym: c.pseudonym,
                              createdAt: c.created_at, note: c.note, pages: c.pages.map(pageJSON) }));
}
export const keyInfo = solutionId => S.utf8(`${FORMAT}/v${PAYLOAD_VERSION}|${String(solutionId).toLowerCase()}`);
export const aad = (solutionId, correctionId) => S.utf8(`${FORMAT}/v${PAYLOAD_VERSION}|${String(solutionId).toLowerCase()}|${String(correctionId).toLowerCase()}`);

async function aesKey(secret, salt, info) {
  const base = await subtle().importKey("raw", secret, "HKDF", false, ["deriveKey"]);
  return subtle().deriveKey({ name: "HKDF", hash: "SHA-256", salt, info }, base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

/** Korrektur pruefen, packen und mit dem Geheimnis der Community versiegeln: Base64 aus Version, Salz, Nonce, Chiffrat+Tag. */
export async function seal(correction, secret, { salt, nonce } = {}) {
  const c = validated(correction);
  const plain = plaintext(c);
  if (plain.length > MAX_PLAINTEXT_BYTES) throw tooLarge();
  const packed = await S.deflateRaw(plain);
  salt = salt || S.randomBytes(SALT); nonce = nonce || S.randomBytes(NONCE);
  if (salt.length !== SALT || nonce.length !== NONCE) throw err("invalidContent", "Verschlüsselung");
  const key = await aesKey(secret, salt, keyInfo(c.solution_id));
  const ct = new Uint8Array(await subtle().encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad(c.solution_id, c.id), tagLength: 128 }, key, packed));
  if (ct.length !== packed.length + TAG) throw err("invalidContent", "Verschlüsselung");
  const out = new Uint8Array(1 + SALT + NONCE + ct.length);
  out[0] = PAYLOAD_VERSION; out.set(salt, 1); out.set(nonce, 1 + SALT); out.set(ct, 1 + SALT + NONCE);
  const b64 = S.b64encode(out);
  if (b64.length > MAX_PAYLOAD_CHARS) throw tooLarge();
  return b64;
}
function tooLarge() { return err("tooLarge", "Die Korrektur ist zu groß. Markiere weniger Seiten oder schicke sie in Teilen."); }

/** Entschluesseln und vollstaendig pruefen; falscher Schluessel, veraendertes oder umgehaengtes Chiffrat werfen decryptionFailed. */
export async function open(payload, correctionId, solutionId, secret) {
  const raw = typeof payload === "string" && payload.length <= MAX_PAYLOAD_CHARS ? S.b64decode(payload) : null;
  if (!raw || raw.length <= 1 + SALT + NONCE + TAG || raw[0] !== PAYLOAD_VERSION) throw err("decryptionFailed", "Diese Korrektur lässt sich nicht öffnen.");
  const salt = raw.slice(1, 1 + SALT), nonce = raw.slice(1 + SALT, 1 + SALT + NONCE), sealed = raw.slice(1 + SALT + NONCE);
  let packed;
  try {
    const key = await aesKey(secret, salt, keyInfo(solutionId));
    packed = new Uint8Array(await subtle().decrypt({ name: "AES-GCM", iv: nonce, additionalData: aad(solutionId, correctionId), tagLength: 128 }, key, sealed));
  } catch { throw err("decryptionFailed", "Diese Korrektur lässt sich nicht öffnen."); }
  const plain = await S.inflateRaw(packed, MAX_PLAINTEXT_BYTES);
  let j; try { j = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain)); } catch { throw err("invalidContent", "Die Korrektur ist beschädigt (JSON)."); }
  return fromJSON(j, correctionId, solutionId);
}

/** Klartext lesen (fremde Daten: alles pruefen, nur was auch so geschrieben werden durfte). */
export function fromJSON(j, correctionId, solutionId) {
  if (!j || j.format !== FORMAT) throw err("invalidContent", "Die Korrektur ist beschädigt (Formatkennung).");
  if (j.formatVersion !== CONTENT_VERSION) throw err("unsupportedVersion", `Diese Korrektur hat Formatversion ${j.formatVersion} – bitte StudiNow aktualisieren.`);
  S.checkFinite(j); S.checkStrokeSizes(j);
  if (typeof j.correctionID !== "string" || typeof j.solutionID !== "string" || typeof j.pseudonym !== "string" || typeof j.createdAt !== "string" ||
      typeof j.note !== "string" || !Array.isArray(j.pages)) throw err("invalidContent", "Die Korrektur ist beschädigt (Inhalt).");
  if (j.pages.length > MAX_PAGES) throw tooLarge();
  const pages = j.pages.map(p => {
    if (!p || p.kind !== "pdf" || !Array.isArray(p.objects) || !Array.isArray(p.notes) || p.notes.length > MAX_NOTES_PER_PAGE) throw err("invalidContent", "Die Korrektur ist beschädigt (Seite).");
    return { pdfIndex: p.pdfIndex, width: p.width, height: p.height, rotation: p.rotation, strokes: p.objects.map(S.decodeObject),
             notes: p.notes.map(n => ({ id: n.id, x: n.x, y: n.y, text: n.text })) };
  });
  const c = validated({ id: j.correctionID, solution_id: j.solutionID, pseudonym: j.pseudonym, created_at: j.createdAt, note: j.note, pages });
  if (c.id !== String(correctionId).toLowerCase() || c.solution_id !== String(solutionId).toLowerCase()) throw err("invalidContent", "Die Korrektur gehört zu einem anderen Datensatz.");
  return c;
}

// ---------------------------------------------------------------- Stelle auf der Seite

/** Seite einer Korrektur als Loesungsseite (zum Zeichnen mit den Funktionen der Leiste). */
export const solutionPage = p => ({ key: `c${p.pdfIndex}`, kind: "pdf", pdfIndex: p.pdfIndex, width: p.width, height: p.height, rotation: p.rotation, extraRotation: 0, objects: p.strokes });
