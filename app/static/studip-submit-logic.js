// "In Stud.IP abgeben" aus dem Web-Editor (Windows/Einzelplatz, 05.11.2026): reine Regeln und Texte ohne DOM (laeuft unter
// node, tests/js/studip-submit.test.mjs). Gleiche Texte wie StudIPSubmitSheet.swift der iPad-App
// (docs/ABGEBEN-STUDIP-2026-11-05.md); Ordner, Dateiname und Hochladen macht app/studip_submit.py.

export const TYPICAL_LIMIT = 7 * 1024 * 1024;

export const TEXTS = {
  title: "In Stud.IP abgeben",
  menu: "In Stud.IP abgeben …",
  warning: "Die Datei wird an deine Hochschule hochgeladen (Stud.IP). Lehrende sehen sie; in normalen Ordnern auch andere Teilnehmende des Kurses.",
  course: "Kurs",
  folder: "Zielordner",
  fileName: "Dateiname",
  withNotes: "Notizen und Blätter mitschicken",
  withNotesHint: "Seitennotizen und Blätter, die neben einer Folie beschrieben wurden, stehen direkt hinter ihrer Folie. Deine Notizen auf den Folien gehen immer mit.",
  confirm: "Jetzt abgeben",
  open: "In Stud.IP öffnen",
  openFolder: "Ordner in Stud.IP öffnen",
  history: "Bisher abgegeben",
  homework: "Abgabeordner – nur du und die Lehrenden sehen deine Datei",
  noFolders: "In diesem Kurs gibt es keinen Ordner, in den du hochladen darfst.",
  notAvailable: "Abgeben gibt es nur in der Windows-App mit Stud.IP. Exportiere die PDF und lade sie im Browser hoch.",
  notConnected: "Stud.IP ist nicht verbunden.",
  login: "Bei der Hochschule anmelden",
  building: "PDF wird erstellt …",
  loadingFolders: "Ordner werden aus Stud.IP gelesen …",
  noCourses: "Keine Stud.IP-Kurse gefunden. Gleiche zuerst mit Stud.IP ab.",
};

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export { esc };

/** "1,2 MB" */
export function megabytes(n) {
  const mb = (Number(n) || 0) / (1024 * 1024);
  return (mb < 10 ? mb.toFixed(1) : mb.toFixed(0)).replace(".", ",") + " MB";
}

/** "6 Seiten · 1,2 MB" */
export const preview = (pages, bytes) => `${pages === 1 ? "1 Seite" : `${pages} Seiten`} · ${megabytes(bytes)}`;

/** Hinweis ueber 7 MB (die Abgabe wird nicht gesperrt), sonst "" */
export const sizeNotice = bytes => bytes > TYPICAL_LIMIT ? `Die Datei ist ${megabytes(bytes)} groß. Manche Stud.IP-Ordner nehmen nur bis 7 MB an.` : "";

const UML = { "ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss" };

/** Teil eines Dateinamens wie safe_component in app/studip_submit.py */
export function safeComponent(s) {
  let out = "";
  for (const ch of String(s || "").trim()) {
    if (UML[ch]) { out += UML[ch]; continue; }
    if (/\s/.test(ch) || ch === "/" || ch === "\\") { out += "_"; continue; }
    for (const c of ch.normalize("NFD")) if (/[A-Za-z0-9._-]/.test(c)) out += c;
  }
  while (out.includes("__")) out = out.replace("__", "_");
  return out.replace(/^[_.-]+|[_.-]+$/g, "");
}

/** Vom Menschen geaenderter Name: sicher machen, ".pdf" anhaengen; "" wenn nichts bleibt */
export function finalFileName(input) {
  let t = String(input || "").trim();
  if (t.toLowerCase().endsWith(".pdf")) t = t.slice(0, -4);
  const c = safeComponent(t);
  return c ? c.slice(0, 120) + ".pdf" : "";
}

/** Knopf erst mit Ordner, Name und PDF */
export const canSubmit = ({ folder, name, pdf }) => !!folder && !!finalFileName(name) && !!pdf;

/** Kursauswahl: Kurse des Moduls oben (Gruppe), dann die uebrigen */
export function courseOptions(courses, selected) {
  const opt = c => `<option value="${esc(c.id)}"${c.id === selected ? " selected" : ""}>${esc(c.title)}${c.module_name && !c.in_module ? ` (${esc(c.module_name)})` : ""}</option>`;
  const mine = courses.filter(c => c.in_module), rest = courses.filter(c => !c.in_module);
  return `${selected ? "" : `<option value="">Kurs wählen …</option>`}`
    + (mine.length ? `<optgroup label="Dieses Modul">${mine.map(opt).join("")}</optgroup>` : "")
    + (rest.length ? (mine.length ? `<optgroup label="Weitere Kurse">${rest.map(opt).join("")}</optgroup>` : rest.map(opt).join("")) : "");
}

/** Ordnerliste (Optionsfelder), Hausaufgabenordner mit Unterzeile; geschlossene als Fusszeile */
export function foldersHtml(f, selected) {
  if (!f?.writable?.length) return `<p class="muted small">${esc(TEXTS.noFolders)}</p>` + closedHtml(f);
  const rows = f.writable.map(x => `<label class="sub-folder${x.is_homework ? " hw" : ""}"><input type="radio" name="subFolder" value="${esc(x.id)}"${x.id === selected ? " checked" : ""}>`
    + `<span><b>${esc(x.label)}</b>${x.is_homework ? `<span class="small muted">${esc(TEXTS.homework)}</span>` : ""}</span></label>`).join("");
  return `<div class="sub-folders" role="radiogroup" aria-label="${esc(TEXTS.folder)}">${rows}</div>` + closedHtml(f);
}

export const closedHtml = f => f?.closed?.length ? `<p class="small muted">Derzeit geschlossen (Frist vorbei oder noch nicht offen): ${esc(f.closed.map(x => x.label).join(", "))}</p>` : "";

/** "Abgegeben – Datei liegt jetzt in Kurs › Ordner" */
export const doneText = (course, folder) => `Abgegeben – Datei liegt jetzt in ${course} › ${folder}`;

/** Fehler mit Ausweg "Ordner in Stud.IP öffnen" */
export const offersFolderLink = code => ["submit_security_token", "submit_not_writable", "submit_too_large", "submit_http"].includes(code);
export const needsLogin = code => code === "studip_login" || code === "studip_not_connected";
