// Studienverlauf (Web/Windows, 05.11.2026): Beschriftungen, Regeln und HTML-Bausteine der Seite. Vorlage ist die Ansicht
// auf dem iPad (apps/apple/UniFlow/Views/StudyPlan: StudyPlanModel.swift, StudyPlanPage.swift, StudyPlanSheets.swift);
// der Plan kommt fertig vom Backend (GET /api/study-plan, app/study_plan.py): hier wird nichts berechnet, nur gelesen,
// gefiltert und beschriftet. Verbindlich ist immer die Pruefungsordnung der Hochschule (steht in jeder Ansicht).
// Kein Import aus core.js (braucht das DOM): so laeuft die Datei auch unter node (tests/js/study-plan.test.mjs).

export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export const T = {
  title: "Studienverlauf",
  disclaimer: "Verbindlich ist die Prüfungsordnung deiner Hochschule.",
  noQIS: "Verbinde QIS, damit StudiNow deinen Studiengang kennt",
  noQISSub: "Aus deinem Notenspiegel liest StudiNow Studiengang und Prüfungsordnung. Deine Noten bleiben auf diesem Gerät. Oder wähle deinen Studiengang selbst aus der Liste.",
  noCatalog: "Noch kein Katalog für deinen Studiengang",
  noCatalogSub: "Für deinen Studiengang kennt StudiNow noch keinen Modulkatalog. Hast du einen Link zum Modulhandbuch (PDF)? Dann lädt StudiNow ihn wie ein Browser.",
  linkSaved: "Gespeichert. StudiNow sucht jetzt den Katalog unter diesem Link.",
  linkInvalid: "Bitte einen vollständigen Link mit https:// einfügen.",
  loading: "Studienverlauf wird berechnet …",
  materialsEmpty: "Noch keine Kurse oder Dateien in StudiNow, die zu diesem Modul gehören.",
  localOnly: "Modultexte liegen nur auf diesem Gerät.",
  lastAttempt: "Letzter Versuch – sprich mit der Studienberatung.",
  backlog: "Nachholen im nächsten passenden Semester",
  backlogSub: "Diese Module sind noch offen. StudiNow hat sie in das nächste Semester gelegt, in dem sie angeboten werden.",
};

/** Richtwert je Semester 30 LP; ueber 36 LP warnt die Spalte (wie die Regel im Backend) */
export const LP_LIMIT = 36;

/** Schluessel ohne Umlaute, klein, mit Unterstrich ("Nicht bestanden" -> "nicht_bestanden") */
export const key = s => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/ß/g, "ss").trim().replace(/[ -]/g, "_");

/** nur Buchstaben und Ziffern, ohne Umlaute (Vergleich von Titeln) */
export const normalized = s => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]/g, "");

/** Zahl deutsch ohne ueberfluessige Nachkommastellen: 5 -> "5", 2.5 -> "2,5" */
export const number = d => { const n = Number(d) || 0; return Number.isInteger(n) ? String(n) : n.toFixed(1).replace(".", ","); };
export const lpText = d => `${number(d)} LP`;
export const progressText = (done, total) => `${number(done)} von ${number(total)} LP`;
export const percent = (done, total) => total > 0 ? Math.max(0, Math.min(100, (done / total) * 100)) : 0;
export const fach = n => Number.isFinite(Number(n)) && n != null ? `${n}. Fachsemester` : null;

/** lange Katalogtexte (Prüfungs-/Studienleistung) kuerzen: im Katalog stehen dort manchmal ganze Absaetze */
export function shorten(text, max = 180) {
  const t = String(text ?? "").replace(/\s+/g, " ").trim();
  if (t.length <= max) return t;
  const cut = t.slice(0, max - 1);
  const at = cut.lastIndexOf(" ");
  return (at > max * 0.6 ? cut.slice(0, at) : cut).replace(/[\s,;:.-]+$/, "") + " …";
}

// ---------------------------------------------------------------- Art, Turnus, Status

export function kindText(k) {
  const v = key(k || "pflicht");
  return { pflicht: "Pflicht", wahlpflicht: "Wahlpflicht", wahl: "Wahl", abschluss: "Abschluss", abschlussarbeit: "Abschluss" }[v] || (v ? v[0].toUpperCase() + v.slice(1) : "Pflicht");
}
export const kindClass = k => ({ wahlpflicht: "lav", wahl: "teal", abschluss: "butter", abschlussarbeit: "butter" }[key(k)] || "plain");

export function turnusShort(t) {
  switch (String(t ?? "").toUpperCase().replace(/\s/g, "")) {
    case "WS": case "WISE": case "WINTER": return "WiSe";
    case "SS": case "SOSE": case "SOMMER": return "SoSe";
    case "WS+SS": case "SS+WS": case "JEDES": case "BEIDE": return "jedes Semester";
    default: return null;
  }
}
export const turnusLong = t => ({ WiSe: "Wintersemester", SoSe: "Sommersemester", "jedes Semester": "jedes Semester" }[turnusShort(t)] || "unbekannt");

export const STATUS = {
  passed: { text: "Bestanden", tone: "ok", icon: "check" },
  registered: { text: "Angemeldet", tone: "info", icon: "flag" },
  failed: { text: "Nicht bestanden", tone: "bad", icon: "alert" },
  moved: { text: "Verschoben", tone: "warn", icon: "move" },
  planned: { text: "Geplant", tone: "neutral", icon: "calendar" },
  open: { text: "Offen", tone: "neutral", icon: "circle" },
};

/** Anzeigeform des Status: das Backend liefert bestanden, angemeldet, nicht_bestanden, offen, geplant; ein verschobenes
    Modul traegt zusaetzlich `moved_from` */
export function statusKey(raw, movedFrom) {
  switch (key(raw)) {
    case "bestanden": case "passed": case "be": return "passed";
    case "angemeldet": case "registered": case "an": return "registered";
    case "nicht_bestanden": case "failed": case "nb": case "endgueltig_nicht_bestanden": return "failed";
    default: break;
  }
  if (movedFrom || ["verschoben", "nachholen", "nachgeholt", "moved"].includes(key(raw))) return "moved";
  return ["geplant", "planned", "plan"].includes(key(raw)) ? "planned" : "open";
}
export const moduleStatus = m => statusKey(m?.status, m?.moved_from);
/** zaehlt zum Filter "Offen": alles, was noch nicht bestanden ist */
export const isOpen = m => moduleStatus(m) !== "passed";

/** Text der Statuspille: "Bestanden · 1,7", "Nicht bestanden · Versuch 2", "Verschoben · aus WiSe 25/26" */
export function statusText(m) {
  const s = moduleStatus(m);
  const grade = m?.grade != null && m.grade !== "" ? (typeof m.grade === "number" ? m.grade.toFixed(1).replace(".", ",") : String(m.grade)) : null;
  if (s === "passed") return grade ? `Bestanden · ${grade}` : "Bestanden";
  if (s === "failed") return m?.attempt ? `Nicht bestanden · Versuch ${m.attempt}` : "Nicht bestanden";
  if (s === "moved") return m?.moved_from ? `Verschoben · aus ${m.moved_from}` : "Nachholen";
  return STATUS[s].text;
}

/** Zeile unter der Statuspille: Grund, bei einem nicht bestandenen, weitergereichten Modul mit Herkunft */
export function reasonLine(m) {
  const from = moduleStatus(m) !== "moved" && m?.moved_from ? `aus ${m.moved_from}` : null;
  const parts = [from, m?.reason].filter(Boolean);
  return parts.length ? parts.join(" · ") : null;
}

/** Vorlesetext je Modulkarte: "Programmieren I, 5 Leistungspunkte, Pflicht, Wintersemester, Bestanden, 1,7" */
export function moduleLabel(m) {
  const parts = [m.title, `${number(m.lp)} Leistungspunkte`, kindText(m.kind)];
  if (turnusShort(m.turnus)) parts.push(turnusLong(m.turnus));
  parts.push(statusText(m).replace(" · ", ", "));
  if (moduleStatus(m) !== "moved" && m.moved_from) parts.push(`aus ${m.moved_from}`);
  if (m.reason) parts.push(m.reason);
  if (m.last_attempt) parts.push("letzter Versuch");
  if (m.placed) parts.push("selbst eingeplant");
  if (m.custom) parts.push("eigener Eintrag");
  parts.push(...(m.hints || []).filter(Boolean));
  return parts.join(", ");
}

/** feste Farbe je Bereich (Streifen links an der Karte): immer dieselbe fuer denselben Bereich */
export const AREA_COLORS = ["#4f5bd5", "#1f9d5b", "#d9851e", "#c03535", "#2f7fd1", "#8a4bbf", "#1f9682", "#de5797"];
export function areaColor(area) {
  if (!area) return "";
  let h = 5381;
  for (const c of String(area)) h = ((h * 33) ^ c.codePointAt(0)) >>> 0;
  return AREA_COLORS[h % AREA_COLORS.length];
}

// ---------------------------------------------------------------- Filter

export const FILTERS = [["all", "Alle"], ["open", "Offen"], ["passed", "Bestanden"]];
export const keeps = (filter, m) => filter === "passed" ? moduleStatus(m) === "passed" : filter === "open" ? isOpen(m) : true;
export const allModules = plan => (plan?.semesters || []).flatMap(s => s.modules || []);
export function counts(plan) {
  const all = allModules(plan);
  return { all: all.length, open: all.filter(isOpen).length, passed: all.filter(m => moduleStatus(m) === "passed").length };
}
/** Semester mit den Modulen, die der Filter behaelt (leere Semester fallen weg); die LP-Summe bleibt die des Semesters */
export function visibleSemesters(plan, filter) {
  const sems = plan?.semesters || [];
  if (!filter || filter === "all") return sems;
  return sems.map(s => ({ ...s, modules: (s.modules || []).filter(m => keeps(filter, m)) })).filter(s => s.modules.length);
}

/** Modul nach id oder Titel (Sprung von der Modulseite: "Im Studienverlauf") */
export function findModule(plan, focus) {
  const mods = allModules(plan);
  const byId = mods.find(m => m.id === focus);
  if (byId) return byId;
  const f = normalized(focus);
  if (!f) return null;
  return mods.find(m => normalized(m.title) === f)
    || mods.find(m => { const t = normalized(m.title); return t && (f.startsWith(t) || t.startsWith(f)); }) || null;
}
export const semesterOf = (plan, id) => (plan?.semesters || []).find(s => (s.modules || []).some(m => m.id === id)) || null;

/** Grund-Texte des Backends, die "nachholen" meinen (nicht bestanden, noch nicht abgelegt); Verschiebungen wegen einer
    Voraussetzung oder zu vieler LP gehoeren nicht dazu, sie bleiben auf der Karte sichtbar */
const CATCH_UP = /nachholen|nicht bestanden|noch nicht abgelegt/i;

/** Liste "Nachholen im naechsten passenden Semester": nicht bestandene und liegengebliebene Module mit ihrem Ziel-Semester */
export function backlog(plan) {
  const out = [];
  for (const s of plan?.semesters || []) {
    for (const m of s.modules || []) {
      const st = moduleStatus(m);
      if (st === "failed" || (st === "moved" && m.moved_from && CATCH_UP.test(m.reason || ""))) {
        out.push({ id: m.id, title: m.title, lp: m.lp, to: s.term, from: m.moved_from || null, attempt: m.attempt || null, reason: m.reason || null,
          current: !!s.current, last: !!m.last_attempt, status: st });
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------- Katalogsuche

const BUSY = ["searching", "downloading", "parsing", "loading", "building", "queued", "pending", "found"];
const READY = ["ready", "seed", "library", "loaded", "done", "ok"];
export const catalogState = st => key(st?.state || st?.status || "searching");
export const catalogBusy = st => BUSY.includes(catalogState(st));
export const catalogReady = st => READY.includes(catalogState(st));
export const catalogFailed = st => ["error", "failed"].includes(catalogState(st));
export const catalogNotFound = st => ["not_found", "no_catalog"].includes(catalogState(st));

/** Zeile unter dem Fortschritt: Text des Backends, sonst je Schritt */
export function catalogText(st) {
  const m = st?.message || st?.detail || st?.error;
  if (m) return String(m);
  switch (catalogState(st)) {
    case "searching": case "queued": case "pending": return "StudiNow sucht den Modulkatalog deines Studiengangs …";
    case "found": return "Modulkatalog gefunden …";
    case "downloading": case "loading": return "Modulkatalog wird geladen …";
    case "parsing": case "building": return "Module werden gelesen …";
    case "library": return "Aus der Bibliothek übernommen";
    case "seed": return "Aus dem StudiNow-Grundstock";
    case "ready": case "loaded": case "done": case "ok": return "Modulkatalog geladen";
    case "error": case "failed": return "Der Modulkatalog ließ sich nicht laden.";
    default: return "Modulkatalog wird vorbereitet …";
  }
}

/** Warum es (noch) keinen Plan gibt: noqis | loading | nocatalog | other */
export function gapKind(plan, st) {
  if (!plan || plan.available) return null;
  const r = key(plan.reason || "");
  if (["no_qis", "qis", "no_grades", "no_program", "keine_qis", "qis_missing"].includes(r)) return "noqis";
  if (["catalog_loading", "loading", "searching", "downloading", "parsing", "pending", "building", "queued"].includes(r)) return "loading";
  if (["no_catalog", "no_catalog_po", "catalog_missing", "not_found", "unknown_program", "no_source", "kein_katalog"].includes(r)) {
    // ohne Studiengang aus QIS und ohne gewaehlte Ordnung kennt StudiNow den Studiengang noch nicht (wie auf dem iPad)
    if (r === "no_catalog" && !plan.qis_program && !plan.program && !plan.po_confirmed) return "noqis";
    return catalogBusy(st) || catalogFailed(st) ? "loading" : "nocatalog";
  }
  return "other";
}

/** eingefuegter Link zum Modulhandbuch: nur https mit Rechnernamen, ohne Leerzeichen, hoechstens 500 Zeichen */
export function catalogUrl(text) {
  const t = String(text ?? "").trim();
  if (!t || t.length > 500 || /\s/.test(t) || !/^https:\/\//i.test(t)) return null;
  try { const u = new URL(t); return u.hostname.includes(".") ? u.href : null; } catch { return null; }
}

/** Quelle mit Seite: die PDF springt mit "#page=12" auf die Seite */
export function sourceUrl(url, page) {
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    if (page && !u.hash) u.hash = `page=${page}`;
    return u.href;
  } catch { return null; }
}
export const sourceLabel = page => page ? `Im Modulkatalog ansehen (S. ${page})` : "Im Modulkatalog ansehen";

// ---------------------------------------------------------------- HTML: Plan

const pill = (text, tone, icon, ic) => `<span class="sp-pill ${tone}">${ic ? ic(icon, 12) : ""}<span>${esc(text)}</span></span>`;

/** Karte eines Moduls; mit `opts.edit` (Bearbeiten erlaubt) zusaetzlich Ziehen und Menue "Aktionen" (Verschieben nach …,
    Nicht belegen …), Etiketten "Selbst eingeplant" / "Eigener Eintrag" und Hinweise des Kerns */
export function moduleCardHtml(m, ic, opts = null) {
  const s = moduleStatus(m), st = STATUS[s], reason = reasonLine(m), color = areaColor(m.area);
  const hints = (m.hints || []).filter(Boolean);
  const card = `<button type="button" class="sp-mod${s === "failed" ? " failed" : ""}${s === "passed" ? " passed" : ""}" data-module="${esc(m.id)}" style="${color ? `--ac:${color}` : ""}" aria-label="${esc(moduleLabel(m))}" title="Details zum Modul">`
    + `<span class="sp-mod-top"><b class="sp-mod-title">${esc(m.title)}</b><span class="sp-lp">${esc(lpText(m.lp))}</span></span>`
    + `<span class="sp-tags"><span class="sp-tag ${kindClass(m.kind)}">${esc(kindText(m.kind))}</span>${turnusShort(m.turnus) ? `<span class="sp-tag line">${esc(turnusShort(m.turnus))}</span>` : ""}`
    + (m.placed ? `<span class="sp-tag sky">Selbst eingeplant</span>` : "") + (m.custom ? `<span class="sp-tag line">Eigener Eintrag</span>` : "") + `</span>`
    + pill(statusText(m), st.tone, st.icon, ic)
    + (reason ? `<span class="sp-reason">${esc(reason)}</span>` : "")
    + hints.map(h => `<span class="sp-hint">${ic ? ic("alert", 12) : ""}<span>${esc(h)}</span></span>`).join("")
    + (m.last_attempt ? `<span class="sp-last">${ic ? ic("alert", 12) : ""}<b>Letzter Versuch</b></span>` : "")
    + `</button>`;
  if (!opts) return card;
  const drag = opts.edit && movable(m);
  const menu = opts.edit && menuItems(m, opts.plan).length > 1;
  return `<div class="sp-card${drag ? " can-drag" : ""}${s === "passed" ? " locked" : ""}" data-card="${esc(m.id)}"${drag ? ` draggable="true" data-drag="${esc(m.id)}"` : ""}>${card}`
    + (menu ? `<button type="button" class="sp-more" data-menu="${esc(m.id)}" aria-haspopup="menu" aria-expanded="false" aria-label="${esc(`Aktionen für ${m.title}`)}" title="Verschieben, nicht belegen …">${ic ? ic("more", 16) : "…"}</button>` : "")
    + (s === "passed" && opts.edit ? `<span class="sp-lock" title="Bestanden – bleibt im Semester aus QIS" aria-hidden="true">${ic ? ic("check", 11) : ""}</span>` : "")
    + `</div>`;
}

/** Spalte bzw. Abschnitt eines Semesters; mit `opts` (Plan, edit) auch offene Plaetze, "+ n LP offen" und Ablageziel */
export function semesterHtml(s, ic, opts = null) {
  const over = Number(s.lp) > LP_LIMIT + 0.01;
  const slots = opts ? (s.slots || []) : [];
  const lpSlots = Number(s.lp_slots) || 0;
  const label = [s.term, fach(s.fachsemester), `${number(s.lp)} Leistungspunkte${over ? ", mehr als der Richtwert" : ""}`,
    opts && lpSlots > 0 ? `dazu ${number(lpSlots)} Leistungspunkte offene Wahl` : null, s.current ? "aktuelles Semester" : null].filter(Boolean).join(", ");
  const mods = s.modules || [];
  return `<section class="sp-sem${s.current ? " current" : ""}${over ? " over" : ""}" data-term="${esc(s.term)}"${opts?.edit ? ` data-drop="${esc(s.term)}"` : ""} aria-label="${esc(label)}">`
    + `<header class="sp-sem-head"><div><b>${esc(s.term)}</b>${s.current ? ` <span class="badge">Aktuell</span>` : ""}${fach(s.fachsemester) ? `<small>${esc(fach(s.fachsemester))}</small>` : ""}</div>`
    + `<div class="sp-sem-lp"><span class="badge ${over ? "warn" : "neutral"}">${over && ic ? ic("alert", 12) : ""}${esc(lpText(s.lp))}</span>${opts && lpSlots > 0 ? `<small>+ ${esc(number(lpSlots))} LP offen</small>` : ""}</div></header>`
    + (mods.length || slots.length ? `<div class="sp-mods">${mods.map(m => moduleCardHtml(m, ic, opts)).join("")}${slots.map(sl => slotCardHtml(sl, opts.plan, ic, opts.edit, s.term)).join("")}</div>` : `<p class="sp-none">Keine Module geplant</p>`)
    + `</section>`;
}

/** Kopfkarte: Ring "84 von 180 LP", Studiengang, PO, Hinweise, Satz zur Pruefungsordnung */
export function headerHtml(plan, ic) {
  const done = Number(plan.lp_done) || 0, total = Number(plan.lp_total) || 0, p = percent(done, total);
  const line = [plan.program, plan.degree].filter(Boolean).join(" ") || plan.qis_program || "Dein Studiengang";
  const sub = [plan.po != null && plan.po !== "" ? `PO ${plan.po}` : null, plan.catalog_term ? `Katalog ${plan.catalog_term}` : null].filter(Boolean).join(" · ");
  const notes = (plan.notes || []).map(n => { const t = typeof n === "string" ? n : n.text; const tone = n?.tone === "bad" ? "bad" : n?.tone === "ok" ? "ok" : n?.tone === "info" ? "info" : "warn";
    return t ? `<span class="badge ${tone}">${ic ? ic(tone === "bad" ? "alert" : tone === "warn" ? "move" : "info", 12) : ""}${esc(t)}</span>` : ""; }).join("");
  return `<div class="card sp-head">`
    + `<div class="sp-ring" style="--p:${p.toFixed(1)}" role="img" aria-label="${esc(progressText(done, total))}, ${Math.round(p)} Prozent"><div><b>${esc(number(done))}</b><small>von ${esc(number(total))} LP</small></div></div>`
    + `<div class="sp-head-t"><h2>${esc(line)}</h2>${sub ? `<div class="muted">${esc(sub)}</div>` : ""}<div class="sp-done">${esc(progressText(done, total))} erreicht</div>`
    + (notes ? `<div class="sp-notes" aria-label="Hinweise">${notes}</div>` : "") + `</div>`
    + `<p class="sp-disc">${ic ? ic("info", 13) : ""}<span>${esc(plan.disclaimer || T.disclaimer)}</span></p></div>`;
}

/** Filterleiste Alle / Offen / Bestanden mit Zahlen */
export function filterHtml(plan, filter) {
  const c = counts(plan);
  return `<div class="seg pill sp-filter" role="radiogroup" aria-label="Filter">${FILTERS.map(([v, t]) =>
    `<button type="button" role="radio" aria-checked="${v === filter}" class="${v === filter ? "active" : ""}" data-filter="${v}">${esc(t)} (${c[v]})</button>`).join("")}</div>`;
}

/** Karte "Nachholen im naechsten passenden Semester" (leer ohne Eintraege) */
export function backlogHtml(plan, ic) {
  const list = backlog(plan);
  if (!list.length) return "";
  return `<section class="card sp-backlog" aria-label="${esc(T.backlog)}"><div class="card-head"><h2>${ic ? ic("move", 16) : ""} ${esc(T.backlog)}</h2></div><p class="muted small">${esc(T.backlogSub)}</p>`
    + `<ul>${list.map(b => `<li><button type="button" class="sp-link" data-module="${esc(b.id)}"><b>${esc(b.title)}</b></button>`
      + `<span class="muted"> · ${esc(lpText(b.lp))}</span>`
      + `<span class="sp-arrow">${b.from ? `aus ${esc(b.from)} → ` : "→ "}<b>${esc(b.to)}</b>${b.current ? " (jetzt)" : ""}</span>`
      + (b.attempt ? `<span class="badge ${b.last ? "bad" : "neutral"}">Versuch ${b.attempt}</span>` : "") + `</li>`).join("")}</ul></section>`;
}

/** Board (Semester-Spalten) oder Hinweis, wenn der Filter nichts uebrig laesst */
export function boardHtml(plan, filter, ic, opts = null) {
  const sems = visibleSemesters(plan, filter);
  if (!sems.length) {
    return `<div class="card flat"><div class="empty">${ic ? `<div class="ic">${ic(filter === "passed" ? "check" : "calendar", 28)}</div>` : ""}${filter === "passed" ? "Noch kein Modul bestanden." : "Alles bestanden – nichts mehr offen."}</div></div>`;
  }
  // Plaetze nur ohne Filter "Bestanden" (der Kern liefert sie ohnehin nur fuer offene Wahl)
  const o = opts ? { ...opts, plan } : null;
  return `<div class="sp-board" id="spBoard">${sems.map(s => semesterHtml(filter === "passed" ? { ...s, slots: [] } : s, ic, o)).join("")}</div>`;
}

/** Pruefungsordnung bestaetigen: erscheint, solange die PO nur vorgeschlagen ist */
export function poCardHtml(plan, ic) {
  if (!plan.suggested_po || plan.po_confirmed) return "";
  const q = plan.qis_program ? `QIS nennt „${plan.qis_program}“. Der passende aktuelle Katalog gehört zur PO ${plan.suggested_po} – stimmt das?` : "StudiNow hat die passende Ordnung vorgeschlagen. Bestätige sie oder wähle eine andere.";
  return `<div class="card sp-po" id="spPo"><div class="sp-po-t">${ic ? ic("file-text", 18) : ""}<div><b>Deine Prüfungsordnung: PO ${esc(plan.suggested_po)}?</b><div class="muted small">${esc(q)}</div></div></div>`
    + `<div class="row wrap"><button type="button" class="btn primary sm" id="spPoYes">${ic ? ic("check", 14) : ""} Ja, PO ${esc(plan.suggested_po)}</button><button type="button" class="btn sm" id="spPoChange">Ändern</button></div>`
    + `<div class="sp-err small" id="spPoErr" hidden></div></div>`;
}

// ---------------------------------------------------------------- HTML: Zustaende ohne Plan

const notice = (icon, title, text, actions, ic, tone = "") =>
  `<div class="card sp-notice ${tone}"><div class="sp-notice-ic">${ic ? ic(icon, 20) : ""}</div><div class="sp-notice-t"><h3>${esc(title)}</h3>${text ? `<p class="muted">${esc(text)}</p>` : ""}${actions || ""}</div></div>`;

export function noQisHtml(ic) {
  return notice("graduation", T.noQIS, T.noQISSub, `<div class="row wrap"><a class="btn primary" href="#/services">${ic ? ic("arrow-right", 15) : ""} Zu Uni &amp; Noten</a><button type="button" class="btn" id="spPick">${ic ? ic("list", 15) : ""} Studiengang wählen</button></div>`, ic);
}

export function loadingHtml(plan, st, ic) {
  const failed = catalogFailed(st);
  const line = [[plan?.program, plan?.degree].filter(Boolean).join(" ") || plan?.qis_program, plan?.po ? `PO ${plan.po}` : null].filter(Boolean).join(" · ");
  const pr = typeof st?.progress === "number" ? Math.max(0, Math.min(1, st.progress > 1 ? st.progress / 100 : st.progress)) : null;
  return notice(failed ? "alert" : "download", failed ? "Modulkatalog nicht geladen" : "Modulkatalog wird vorbereitet",
    "", `${line ? `<div class="muted small"><b>${esc(line)}</b></div>` : ""}<div class="sp-status${failed ? " bad" : ""}" id="spCatStatus" role="status">${failed ? "" : `<span class="sp-spin" aria-hidden="true"></span>`}<span>${esc(catalogText(st))}</span></div>`
    + (pr != null && !failed ? `<div class="progress" role="progressbar" aria-valuenow="${Math.round(pr * 100)}" aria-valuemin="0" aria-valuemax="100"><i style="width:${(pr * 100).toFixed(0)}%"></i></div>` : "")
    + `<p class="muted small">Der Katalog wird einmal je Studiengang geladen – ohne deine Noten oder deinen Namen.</p>`
    + (failed ? `<div class="row wrap"><button type="button" class="btn sm" id="spRetry">${ic ? ic("refresh", 14) : ""} Erneut versuchen</button></div>` : ""), ic, failed ? "bad" : "");
}

export function noCatalogHtml(plan, ic) {
  const line = [[plan?.program, plan?.degree].filter(Boolean).join(" ") || plan?.qis_program, plan?.po ? `PO ${plan.po}` : null].filter(Boolean).join(" · ");
  const msg = plan?.message && !String(plan.message).startsWith("Für deinen Studiengang") ? plan.message : "";
  return notice("book", T.noCatalog, "", `${line ? `<div class="muted small"><b>${esc(line)}</b></div>` : ""}${msg ? `<div class="sp-warn small">${esc(msg)}</div>` : ""}`
    + `<p class="muted">${esc(T.noCatalogSub)}</p>`
    + `<div class="sp-link-row"><input class="input" id="spLink" type="url" inputmode="url" autocomplete="off" placeholder="https://…/modulhandbuch.pdf" aria-label="Link zum Modulhandbuch einfügen"><button type="button" class="btn primary" id="spLinkSave">${ic ? ic("check", 15) : ""} Link speichern</button></div>`
    + `<div class="small" id="spLinkMsg" role="status"></div><div class="row wrap"><button type="button" class="btn sm" id="spPick">${ic ? ic("list", 14) : ""} Anderen Studiengang wählen</button></div>`, ic);
}

export function otherGapHtml(plan, ic) {
  return notice("info", "Studienverlauf noch nicht verfügbar", plan?.message || plan?.reason || "Unbekannter Grund", `<div class="row wrap"><button type="button" class="btn" id="spRetry">${ic ? ic("refresh", 15) : ""} Erneut laden</button></div>`, ic);
}

// ---------------------------------------------------------------- HTML: Studiengang waehlen (Register)

/** nach Name filtern (ohne Umlaute und Gross-/Kleinschreibung) */
export function filterPrograms(list, q) {
  const k = normalized(q);
  return (list || []).filter(p => !k || normalized(`${p.program} ${p.degree || ""} ${p.faculty || ""}`).includes(k));
}

/** Liste der Studiengaenge des Registers: je Studiengang die Pruefungsordnungen als Knoepfe (Kuerzel = settings.po),
    Studiengaenge ohne Katalog ausgegraut */
export function programsHtml(list, q, current, limit = 60) {
  const items = filterPrograms(list, q);
  const shown = items.slice(0, limit);
  if (!items.length) return `<p class="muted">Kein Studiengang gefunden. Prüfe die Schreibweise oder füge den Link zum Modulhandbuch ein.</p>`;
  return `<ul class="sp-prog">${shown.map(p => {
    const has = (p.pos || []).length > 0;
    const pos = has ? `<div class="sp-prog-po">${p.pos.map(x => `<button type="button" class="chip${current && (current === x.code || current === x.po) ? " on" : ""}" data-pick="${esc(x.code)}" title="${esc(x.catalog_terms?.length ? `Katalog ${x.catalog_terms.join(", ")}` : "Katalog im Grundstock")}">PO ${esc(x.po)}</button>`).join("")}</div>`
      : `<span class="muted small">Katalog noch nicht bekannt</span>`;
    return `<li class="${has ? "" : "off"}"><div class="sp-prog-t"><b>${esc(p.program)}</b> <span class="muted">${esc(p.degree || "")}</span>${p.faculty ? `<small>${esc(p.faculty)}</small>` : ""}</div>${pos}</li>`;
  }).join("")}</ul>${items.length > shown.length ? `<p class="muted small">${items.length - shown.length} weitere – tippe mehr vom Namen ein.</p>` : ""}`;
}

// ---------------------------------------------------------------- HTML: Moduldetail

/** "2026-02-10" -> "10.02.2026"; anderes bleibt, wie es ist */
export const day = v => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(v ?? "")); return m ? `${m[3]}.${m[2]}.${m[1]}` : String(v ?? ""); };

/** Einzelner Versuch: "Versuch 1  WiSe 24/25 · 12.02.2025  5,0  [Nicht bestanden]" */
function attemptHtml(a, ic) {
  const s = statusKey(a.status, null), st = STATUS[s];
  const when = [a.semester, day(a.date)].filter(Boolean).join(" · ");
  const grade = a.grade != null && a.grade !== "" ? (typeof a.grade === "number" ? a.grade.toFixed(1).replace(".", ",") : a.grade) : "";
  return `<div class="sp-try"><b>${a.attempt ? `Versuch ${esc(a.attempt)}` : "Versuch"}</b><span class="muted">${esc(when)}</span>${grade ? `<b class="sp-grade">${esc(grade)}</b>` : ""}${pill(st.text, st.tone, st.icon, ic)}</div>`;
}

/** eigener Stand: Statuspille, Grund, Versuche, Warnung beim letzten Versuch */
export function ownHtml(d, ic) {
  const own = d.own || {};
  const s = statusKey(own.status, own.moved_from), st = STATUS[s];
  const tries = (own.attempts || []);
  let text = st.text;
  if (s === "passed") { const g = [...tries].reverse().find(a => statusKey(a.status) === "passed")?.grade; text = g != null && g !== "" ? `Bestanden · ${typeof g === "number" ? g.toFixed(1).replace(".", ",") : g}` : "Bestanden"; }
  else if (s === "failed") { const n = Math.max(0, ...tries.map(a => Number(a.attempt) || 0)); text = n ? `Nicht bestanden · Versuch ${n}` : "Nicht bestanden"; }
  else if (s === "moved") text = own.moved_from ? `Verschoben · aus ${own.moved_from}` : "Nachholen";
  else if (own.status === "nicht_gewaehlt") text = "Nicht gewählt";
  const last = own.last_attempt || (s === "failed" && Math.max(0, ...tries.map(a => Number(a.attempt) || 0)) >= 3);
  return `<div class="sp-sec"><h4>${ic ? ic("user", 14) : ""} Dein Stand</h4><div class="card flat">`
    + pill(text, own.status === "nicht_gewaehlt" ? "neutral" : st.tone, st.icon, ic)
    + (own.term ? `<span class="muted small"> im ${esc(own.term)}</span>` : "")
    + (own.reason ? `<p class="muted small">${esc(own.reason)}</p>` : "")
    + (tries.length ? `<div class="sp-tries">${tries.map(a => attemptHtml(a, ic)).join("")}</div>` : "")
    + (last ? `<p class="sp-lastw">${ic ? ic("alert", 14) : ""}<span>${esc(T.lastAttempt)}</span></p>` : "") + `</div></div>`;
}

/** Fakten aus dem Katalog; lange Texte gekuerzt (shorten) */
export function factsHtml(d, ic) {
  const facts = [["Leistungspunkte", lpText(d.lp)], ["Empfohlen", fach(d.semester) || "frei wählbar"], ["Turnus", turnusLong(d.turnus)],
    ["Prüfungsleistung", d.exam ? shorten(d.exam) : "–"], ["Studienleistung", d.coursework ? shorten(d.coursework) : "keine"],
    ["Sprache", d.language ? d.language[0].toUpperCase() + d.language.slice(1) : "–"], ["Arbeitsaufwand", d.workload_h ? `${d.workload_h} Stunden` : "–"]];
  const pre = d.prerequisites || [];
  return `<div class="sp-sec"><h4>${ic ? ic("list", 14) : ""} Fakten</h4><div class="card flat"><dl class="sp-facts">${facts.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join("")}</dl>`
    + `<div class="sp-pre"><dt>Voraussetzungen</dt>${pre.length ? `<div class="chips">${pre.map(p => `<button type="button" class="chip" data-open="${esc(p.id)}">${ic ? ic("arrow-right", 12) : ""} ${esc(p.title || p.id)}</button>`).join("")}</div>` : `<dd>keine</dd>`}</div></div></div>`;
}

/** Modultexte (nur auf diesem Geraet) zum Aufklappen; solange sie nachgeladen werden, ein Hinweis */
export function textsHtml(d, ic) {
  const t = d.texts || {};
  const parts = [["content", "Inhalte"], ["goals", "Lernziele"], ["literature", "Literatur"]].filter(([k]) => String(t[k] ?? "").trim());
  if (!parts.length) {
    return d.texts_loading ? `<div class="sp-sec"><h4>${ic ? ic("file-text", 14) : ""} Aus dem Modulkatalog</h4><div class="card flat"><div class="sp-status"><span class="sp-spin" aria-hidden="true"></span><span>Inhalte und Lernziele werden geladen …</span></div></div></div>` : "";
  }
  return `<div class="sp-sec"><h4>${ic ? ic("file-text", 14) : ""} Aus dem Modulkatalog</h4><div class="card flat">${parts.map(([k, name], i) =>
    `<details class="sp-text"${i === 0 ? " open" : ""}><summary>${esc(name)}</summary><div class="sp-long">${esc(String(t[k]).trim())}</div></details>`).join("")}<p class="muted tiny">${esc(T.localOnly)}</p></div></div>`;
}

/** Kurse und Dateien in StudiNow, die zu diesem Modul gehoeren */
export function materialsHtml(d, ic) {
  const rows = [];
  for (const a of d.app_modules || []) rows.push({ href: `#/modules/${a.id}`, title: a.name || "Modul", sub: "Fach in StudiNow", icon: "book" });
  const first = (d.app_modules || [])[0]?.id;
  for (const c of d.courses || []) rows.push({ href: Number.isInteger(c.module_id) ? `#/modules/${c.module_id}` : (first ? `#/modules/${first}` : ""), title: c.title || "Kurs", sub: c.semester || "", icon: "book" });
  for (const f of d.files || []) rows.push({ href: `#/doc/${f.id}`, title: f.name || "Datei", sub: "", icon: "file-text" });
  return `<div class="sp-sec"><h4>${ic ? ic("folder", 14) : ""} Deine Unterlagen</h4><div class="card flat">`
    + (rows.length ? `<div class="list">${rows.map(r => `<a class="item" ${r.href ? `href="${esc(r.href)}" data-away` : ""}>${ic ? ic(r.icon, 16) : ""}<div class="main"><div class="title">${esc(r.title)}</div>${r.sub ? `<div class="sub">${esc(r.sub)}</div>` : ""}</div></a>`).join("")}</div>`
      : `<p class="muted small">${esc(T.materialsEmpty)}</p>`) + `</div></div>`;
}

/** ganzes Moduldetail (Inhalt des Fensters) */
export function detailHtml(d, ic) {
  const src = d.source?.url ? sourceUrl(d.source.url, d.source.page) : null;
  return `<div class="sp-detail"><h2>${esc(d.title)}</h2>`
    + `<div class="sp-tags"><span class="sp-tag ${kindClass(d.kind)}">${esc(kindText(d.kind))}</span>${turnusShort(d.turnus) ? `<span class="sp-tag line">${esc(turnusShort(d.turnus))}</span>` : ""}${d.code ? `<span class="sp-tag line">${esc(d.code)}</span>` : ""}${d.area_name ? `<span class="muted small">${esc(d.area_name)}</span>` : ""}</div>`
    + ownHtml(d, ic) + factsHtml(d, ic) + textsHtml(d, ic) + materialsHtml(d, ic)
    + `<div class="sp-src">${src ? `<a class="btn" href="${esc(src)}" target="_blank" rel="noopener noreferrer">${ic ? ic("arrow-right", 14) : ""} ${esc(sourceLabel(d.source?.page))}</a>` : ""}<p class="muted small">${ic ? ic("info", 13) : ""} ${esc(T.disclaimer)}</p></div></div>`;
}

// ---------------------------------------------------------------- HTML: Einstellungen

/** LP der gewaehlten Wahlpflichtmodule */
export const chosenLp = (s, chosen) => (s.elective_options || []).filter(e => chosen.has(e.id)).reduce((a, e) => a + (Number(e.lp) || 0), 0);

/** Rumpf fuer POST /api/study-plan/settings; Wahlmodule in der Reihenfolge der Liste (stabil fuer den Vergleich) */
export function settingsBody(s, { po, start, chosen }) {
  const known = (s.elective_options || []).map(e => e.id).filter(id => chosen.has(id));
  const extra = [...chosen].filter(id => !known.includes(id)).sort();
  return { po: po || null, start_term: start || null, electives: [...known, ...extra] };
}

export function counterText(lp, req) { return req ? `${number(lp)} von ${number(req)} LP gewählt` : `${number(lp)} LP gewählt`; }

/** Beschriftung einer Ordnung: ein Kuerzel aus dem Register ("TIBSc22") heisst im Katalog "2022" */
export const poLabel = (s, po) => String((s.catalogs || []).find(c => c.code === po)?.po ?? po);

export function settingsHtml(s, st, ic, extra = "") {
  const pos = [...(s.po_options || [])];
  if (s.po && !pos.includes(s.po)) pos.push(s.po);
  const terms = [...(s.term_options || [])];
  if (s.start_term && !terms.includes(s.start_term)) terms.unshift(s.start_term);
  const opts = s.elective_options || [];
  const req = Number(s.elective_lp_required) || 0, lp = chosenLp(s, st.chosen);
  return `<div class="sp-set">`
    + `<div class="sp-sec"><h4>${ic ? ic("file-text", 14) : ""} Prüfungsordnung</h4><div class="card flat">`
    + (pos.length ? `<select class="input" id="spSetPo" aria-label="Prüfungsordnung"><option value="">Automatisch</option>${pos.map(p => `<option value="${esc(p)}"${p === st.po ? " selected" : ""}>PO ${esc(poLabel(s, p))}</option>`).join("")}</select>` : `<p class="muted small">Für deinen Studiengang ist nur eine Ordnung bekannt.</p>`)
    + `<p class="muted small">Bestimmt den Modulkatalog und den Verlaufsplan. Verbindlich ist die Ordnung, nach der du eingeschrieben bist.</p>`
    + `<button type="button" class="btn sm" id="spSetPick">${ic ? ic("list", 14) : ""} Anderen Studiengang wählen</button></div></div>`
    + `<div class="sp-sec"><h4>${ic ? ic("calendar", 14) : ""} Studienbeginn</h4><div class="card flat"><select class="input" id="spSetStart" aria-label="Studienbeginn"><option value="">Aus QIS übernehmen${s.suggested_start_term ? ` (${esc(s.suggested_start_term)})` : ""}</option>${terms.map(t => `<option value="${esc(t)}"${t === st.start ? " selected" : ""}>${esc(t)}</option>`).join("")}</select>`
    + `<p class="muted small">Ab hier zählen die Fachsemester. StudiNow schlägt das früheste Semester aus QIS vor.</p></div></div>`
    + `<div class="sp-sec"><h4>${ic ? ic("layers", 14) : ""} Wahlpflicht</h4><div class="card flat">`
    + (opts.length ? `<div class="sp-count"><b id="spCount" class="${req && lp >= req ? "ok" : ""}">${esc(counterText(lp, req))}</b><span class="muted small">${[...st.chosen].filter(id => opts.some(o => o.id === id)).length} von ${opts.length} Modulen</span></div>`
      + (req ? `<div class="progress${lp >= req ? " ok" : ""}"><i id="spCountBar" style="width:${Math.min(100, (lp / req) * 100).toFixed(0)}%"></i></div>` : "")
      + `<div class="sp-electives">${opts.map(e => `<label class="sp-el"><input type="checkbox" data-el="${esc(e.id)}"${st.chosen.has(e.id) ? " checked" : ""}><span><b>${esc(e.title)}</b><small>${esc([lpText(e.lp), e.area_name || e.area].filter(Boolean).join(" · "))}</small></span></label>`).join("")}</div>`
      : `<p class="muted small">Dein Studiengang hat keine Wahlpflichtmodule zum Auswählen.</p>`) + `</div></div>`
    + extra + `<div class="sp-err small" id="spSetErr" hidden></div></div>`;
}

// ================================================================ Selbst gestalten (05.11.2026)
// Wie auf dem iPad (StudyPlanEditing.swift, StudyPlanModel.swift "StudyPlanEdit"): offene Plaetze je Semester, Auswahl der
// erlaubten Module, Tauschen, "Nicht belegen", "Zurück in den Plan", eigene Eintraege, Verschieben (Ziehen und Menue),
// "Plan zurücksetzen", Kasten "Bereiche und Wahl" und die Gesamtansicht. Hier entstehen nur Texte, HTML und die Rumpfe fuer
// POST /api/study-plan/settings (der Kern speichert teilweise); gerechnet wird im Backend (docs/STUDIENVERLAUF-2026-11-04.md,
// Abschnitt "Für Web und iPhone").

/** Richtwert je Semester; "im 3. Semester sind jetzt 12 LP frei" zaehlt bis hierher */
export const LP_TARGET = 30;

const TERM_RE = /^\s*(WiSe|SoSe|Wintersemester|Sommersemester|WS|SS)\s*(\d{2,4})(?:\s*\/\s*(\d{2,4}))?\s*$/i;
const two = n => String(n % 100).padStart(2, "0");
/** "WiSe 25/26" -> Jahr * 2 + 1, "SoSe 26" -> Jahr * 2 (wie parse_term in app/study_plan.py) */
export function parseTerm(t) {
  const m = TERM_RE.exec(String(t ?? ""));
  if (!m) return null;
  let y = Number(m[2]);
  if (y < 100) y += 2000;
  return y * 2 + (/^(wi|ws)/i.test(m[1]) ? 1 : 0);
}
export const termName = n => n % 2 ? `WiSe ${two(Math.floor(n / 2))}/${two(Math.floor(n / 2) + 1)}` : `SoSe ${two(Math.floor(n / 2))}`;

export const currentTerm = plan => plan?.current_term || (plan?.semesters || []).find(s => s.current)?.term || null;

/** Semester fuer "Verschieben nach …": vom aktuellen (bzw. ersten) bis vier Semester nach dem letzten im Plan */
export function moveTerms(plan) {
  const sems = plan?.semesters || [];
  const known = sems.map(s => parseTerm(s.term)).filter(n => n != null);
  if (!known.length) return sems.map(s => s.term);
  const from = parseTerm(currentTerm(plan)) ?? Math.min(...known);
  const last = Math.max(...known), out = [];
  for (let t = from; t <= Math.max(from, last + 4); t++) out.push(termName(t));
  return out;
}

/** Fachsemester eines Semesternamens (auch nach dem letzten Semester im Plan) */
export function fachsemesterOf(plan, term) {
  const sems = plan?.semesters || [];
  const s = sems.find(x => x.term === term);
  if (s) return s.fachsemester ?? null;
  const t = parseTerm(term), first = sems[0], t0 = parseTerm(first?.term);
  return t == null || t0 == null || first?.fachsemester == null ? null : t - t0 + Number(first.fachsemester);
}

export const lpFree = s => Math.max(0, LP_TARGET - (Number(s?.lp) || 0));
export const overloaded = s => (Number(s?.lp) || 0) > LP_LIMIT + 0.01;

/** Wahl(pflicht)modul? */
export const isElective = m => ["wahlpflicht", "wahl"].includes(key(m?.kind));
/** verschiebbar: alles ausser Bestandenem (liegt im Semester aus QIS) und eigenen Eintraegen */
export const movable = m => !!m && moduleStatus(m) !== "passed" && !m.custom;
/** gewaehltes Wahlmodul, das sich tauschen laesst (nicht bestanden, nicht angemeldet) */
export const replaceable = m => isElective(m) && movable(m) && !["registered", "failed"].includes(moduleStatus(m));

/** Eintraege des Menues "Aktionen" einer Modulkarte: [Aktion, Text, Symbol] */
export function menuItems(m, plan) {
  const out = [["detail", "Details ansehen", "eye"]];
  if (movable(m)) {
    out.push(["move", "Verschieben nach …", "move"]);
    if (m.placed) out.push(["reset", "Ins empfohlene Semester", "undo"]);
    if (replaceable(m) && (plan?.electives || []).some(o => o.id === m.id)) out.push(["replace", "Anderes Modul wählen", "refresh"]);
    out.push(["drop", "Nicht belegen", "x"]);
  }
  if (m?.custom) out.push(["remove", "Eigenen Eintrag entfernen", "trash"]);
  return out;
}

/** Hinweis beim Ziel: Turnus passt nicht */
export function turnusWarning(turnus, term) {
  const t = parseTerm(term);
  if (t == null) return null;
  const winter = t % 2 === 1, k = turnusShort(turnus);
  if (k === "WiSe" && !winter) return "Laut Katalog nur im Wintersemester angeboten";
  if (k === "SoSe" && winter) return "Laut Katalog nur im Sommersemester angeboten";
  return null;
}

// ---------------------------------------------------------------- Aenderungen (Rumpf fuer POST /api/study-plan/settings)

const placementsOf = plan => ({ ...(plan?.placements || {}) });
const chosenIds = plan => (plan?.electives || []).filter(o => o.chosen).map(o => o.id);
const excludedIds = plan => (plan?.excluded || []).map(o => o.id);
const without = (obj, id) => { const o = { ...obj }; delete o[id]; return o; };

export const editMove = (plan, id, term) => ({ placements: { ...placementsOf(plan), [id]: term } });
export const editResetPlacement = (plan, id) => ({ placements: without(placementsOf(plan), id) });

/** Modul aus dem Katalog in den Plan nehmen (Platz, "Zurück in den Plan", "Modul hinzufügen"), optional in ein Semester */
export function editChoose(plan, option, term) {
  const o = {};
  if (option.excluded) o.excluded = excludedIds(plan).filter(id => id !== option.id);
  if (isElective(option)) { const c = chosenIds(plan); if (!c.includes(option.id)) c.push(option.id); o.electives = c; }
  if (term) o.placements = { ...placementsOf(plan), [option.id]: term };
  return o;
}

/** gewaehltes Wahlmodul tauschen: altes ab, neues dazu, neues ins Semester des alten */
export function editReplace(plan, old, option, term) {
  const c = chosenIds(plan).filter(id => id !== old);
  if (!c.includes(option.id)) c.push(option.id);
  const p = without(placementsOf(plan), old);
  if (term) p[option.id] = term;
  return { electives: c, placements: p };
}

/** "Nicht belegen": gewaehltes Wahlmodul abwaehlen, sonst ausschliessen; die eigene Lage faellt weg */
export function editDrop(plan, m) {
  const o = {};
  if (isElective(m) && (plan?.electives || []).some(e => e.id === m.id && e.chosen)) o.electives = chosenIds(plan).filter(id => id !== m.id);
  else o.excluded = [...excludedIds(plan), m.id];
  if (plan?.placements && m.id in plan.placements) o.placements = without(placementsOf(plan), m.id);
  return o;
}

/** "Plan zurücksetzen": eigene Lage und "Nicht belegen" weg (Wahl, Schwerpunkt, eigene Eintraege bleiben) */
export const EDIT_RESET = Object.freeze({ placements: null, excluded: null });

/** Schwerpunkt/Nebenfach (Bereich) einer Gruppe waehlen; aus QIS geschlossene Gruppen bleiben automatisch */
export function editTrack(plan, group, area) {
  const t = {};
  for (const g of plan?.groups || []) if (!g.auto && g.chosen) t[g.id] = g.chosen;
  if (area) t[group] = area; else delete t[group];
  return { tracks: t };
}

export const customModules = plan => allModules(plan).filter(m => m.custom);
export function customJSON(m, plan) {
  const f = semesterOf(plan, m.id)?.fachsemester;
  return { id: m.id, title: m.title, lp: Number(m.lp) || 0, area: m.area ?? null, semester: m.semester ?? f ?? null };
}
/** eingegebene LP: Komma oder Punkt, 0 bis 60 */
export function parseLp(text) {
  const n = Number(String(text ?? "").replace(",", ".").trim());
  return Number.isFinite(n) ? Math.max(0, Math.min(60, n)) : 0;
}
export function editAddCustom(plan, title, lp, area, fachsemester) {
  return { custom: [...customModules(plan).map(m => customJSON(m, plan)), { title: String(title).trim(), lp, area: area ?? null, semester: fachsemester ?? null }] };
}
export const editRemoveCustom = (plan, id) => ({ custom: customModules(plan).filter(m => m.id !== id).map(m => customJSON(m, plan)) });

// ---------------------------------------------------------------- Rueckmeldung

/** "Rechnernetze vorgezogen nach SoSe 26 – im 4. Semester sind jetzt 10 LP frei"; mehrere vorgezogen:
    "3 Module vorgezogen – …"; spaeter: "… verschoben nach …" (frei = 30 − LP des Ausgangssemesters danach) */
export function moveMessage(title, from, to, after) {
  const src = from ? (after?.semesters || []).find(s => s.term === from.term) : null;
  const free = src ? `im ${src.fachsemester != null ? `${src.fachsemester}. Semester` : src.term} sind jetzt ${number(lpFree(src))} LP frei` : null;
  const f = parseTerm(from?.term), t = parseTerm(to);
  let head;
  if (f != null && t != null && t < f) {
    const pulled = allModules(after).filter(m => {
      const fs = semesterOf(after, m.id)?.fachsemester;
      return m.placed && m.semester != null && fs != null && fs < m.semester;
    }).length;
    head = pulled >= 2 ? `${pulled} Module vorgezogen` : `${title} vorgezogen nach ${to}`;
  } else head = `${title} verschoben nach ${to}`;
  return free ? `${head} – ${free}` : head;
}

// ---------------------------------------------------------------- Plaetze, Bereiche, Auswahl

export const area = (plan, id) => id ? (plan?.areas || []).find(a => a.id === id) || null : null;
export const isTrack = slot => slot?.kind === "track";

/** Titel des Platzes mit LP: "Seminar (5 LP)" */
export const slotTitle = slot => Number(slot?.lp) > 0 ? `${slot.title} (${number(slot.lp)} LP)` : String(slot?.title ?? "Wahlmodul");

/** Zeile unter dem Platz: "1 von 3 Modulen gewählt", "noch 10 von 15 LP offen", "Eine von 5 Richtungen wählen" */
export function slotLine(slot, plan) {
  if (isTrack(slot)) {
    const n = ((plan?.groups || []).find(g => g.id === slot.group)?.options || []).length;
    return n > 0 ? `Eine von ${n} Richtungen wählen` : "Eine Richtung wählen";
  }
  const a = area(plan, slot?.area);
  if (!a) return "Modul wählen";
  if (a.modules_required != null) return `${Math.min(Number(a.count) || 0, a.modules_required)} von ${a.modules_required} Modulen gewählt`;
  if (a.target != null && a.lp_open != null) return `noch ${number(a.lp_open)} von ${number(a.target)} LP offen`;
  return `${Number(a.options) || 0} Module zur Wahl`;
}

/** Kurzform des Bereichstyps fuer das Etikett am Platz */
export const typeLabel = t => ({ studium_generale: "Studium generale", schluessel: "Schlüsselkompetenzen", seminar: "Seminar", labor: "Labor", projekt: "Projekt", praktikum: "Praktikum", schwerpunkt: "Schwerpunkt", nebenfach: "Nebenfach", vertiefung: "Vertiefung" }[t] || null);

/** Vorlesetext je Platz: "Offener Platz, Seminare (5 Leistungspunkte), Wahlpflicht, 0 von 1 Modulen gewählt" */
export function slotLabel(slot, plan) {
  const parts = ["Offener Platz", slotTitle(slot).replace(" LP)", " Leistungspunkte)")];
  if (!isTrack(slot)) parts.push(kindText(slot.area_kind || "wahlpflicht"));
  parts.push(slotLine(slot, plan));
  return parts.join(", ");
}

/** gestrichelte Karte "Platz" im Semester; ohne Bearbeiten nur Anzeige */
export function slotCardHtml(slot, plan, ic, edit, term) {
  const tag = edit ? "button" : "div";
  const t = typeLabel(slot.type);
  return `<${tag}${edit ? ` type="button"` : ""} class="sp-slot${isTrack(slot) ? " track" : ""}" data-slot="${esc(slot.id)}" data-term="${esc(term || "")}" ${edit ? "" : `role="group" `}aria-label="${esc(slotLabel(slot, plan))}"${edit ? ` title="${isTrack(slot) ? "Richtung wählen" : "Module zeigen, die du hier wählen kannst"}"` : ""}>`
    + `<span class="sp-slot-ic" aria-hidden="true">${ic ? ic(isTrack(slot) ? "layers" : "plus", 15) : "+"}</span>`
    + `<span class="sp-slot-t"><b>${esc(slotTitle(slot))}</b><span class="sp-tags">${isTrack(slot) ? "" : `<span class="sp-tag ${kindClass(slot.area_kind || "wahlpflicht")}">${esc(kindText(slot.area_kind || "wahlpflicht"))}</span>`}${t ? `<span class="sp-tag line">${esc(t)}</span>` : ""}</span>`
    + `<small>${esc(slotLine(slot, plan))}</small></span></${tag}>`;
}

/** alle Plaetze des Plans mit ihrem Semester */
export const allSlots = plan => (plan?.semesters || []).flatMap(s => (s.slots || []).map(sl => ({ ...sl, term: s.term })));
export const findSlot = (plan, id) => allSlots(plan).find(s => s.id === id) || null;

/** Waehlbare Module: `electives` ohne die schon im Plan, dazu die nicht belegten */
export function allOptions(plan) {
  return [...(plan?.electives || []).filter(o => !o.included && !o.excluded), ...(plan?.excluded || []).map(o => ({ ...o, excluded: true }))];
}

/** Auswahl fuer einen Platz (Bereiche des Platzes; leer = alle Wahlbereiche), gefiltert nach Suche, sortiert nach
    empfohlenem Semester und Titel */
export function choices(plan, slot, query = "") {
  let list = allOptions(plan);
  const areas = slot?.areas || [];
  if (slot && areas.length) list = list.filter(o => (o.areas || []).some(a => areas.includes(a)) || (o.area != null && areas.includes(o.area)));
  const q = normalized(query);
  if (q) list = list.filter(o => normalized(o.title).includes(q));
  return list.sort((a, b) => ((a.semester ?? 99) - (b.semester ?? 99)) || String(a.title).localeCompare(String(b.title), "de"));
}

/** Platz fuer das Tauschen: Bereiche des gewaehlten Moduls, Semester, in dem es liegt */
export function replaceSlot(plan, m) {
  const o = (plan?.electives || []).find(e => e.id === m.id);
  return { id: `tausch-${m.id}`, kind: "slot", title: `Statt ${m.title}`, area: m.area ?? null, areas: o?.areas?.length ? o.areas : (m.area ? [m.area] : []),
    area_kind: key(m.kind), lp: m.lp, term: semesterOf(plan, m.id)?.term || "" };
}

/** Bereiche im Kasten: aktiv, kein Abschluss, mit Ziel oder Stand; Wahlbereiche zuerst */
export function shownAreas(plan) {
  return (plan?.areas || []).filter(a => a.active !== false && a.type !== "abschluss" && (a.target != null || (Number(a.lp_done) || 0) + (Number(a.lp_planned) || 0) > 0))
    .map((a, i) => [a, i]).sort((x, y) => ((x[0].choice ? 0 : 1) - (y[0].choice ? 0 : 1)) || x[1] - y[1]).map(x => x[0]);
}
export const hasAreasBox = plan => (plan?.groups || []).length > 0 || (plan?.areas || []).some(a => a.choice) || (plan?.excluded || []).length > 0;

/** "10 von 15 LP · 5 bestanden · 2 von 3 Modulen" */
export function areaLine(a) {
  const have = (Number(a.lp_done) || 0) + (Number(a.lp_planned) || 0), parts = [];
  parts.push(a.target != null ? `${number(have)} von ${number(a.target)} LP` : `${number(have)} LP`);
  if (Number(a.lp_done) > 0) parts.push(`${number(a.lp_done)} bestanden`);
  if (a.modules_required != null) parts.push(`${Math.min(Number(a.count) || 0, a.modules_required)} von ${a.modules_required} Modulen`);
  return parts.join(" · ");
}

/** Kasten "Bereiche und Wahl": Gruppen (Schwerpunkt, Nebenfach), Stand je Bereich, "Nicht belegt" mit "Zurück in den Plan" */
export function areasHtml(plan, ic, edit) {
  if (!hasAreasBox(plan)) return "";
  const groups = (plan.groups || []).map(g => {
    const name = area(plan, g.chosen)?.name;
    const text = name ? `${g.label}: ${name}${g.auto ? " (aus QIS)" : ""}` : `${g.label}: noch nicht gewählt`;
    return `<div class="sp-group${name ? "" : " open"}"><b>${esc(text)}</b>${edit ? `<button type="button" class="btn sm" data-track="${esc(g.id)}" aria-label="${esc(`${g.label} ${name ? "ändern" : "wählen"}`)}">${name ? "Ändern" : "Wählen"}</button>` : ""}</div>`;
  }).join("");
  const rows = shownAreas(plan).map(a => {
    const have = (Number(a.lp_done) || 0) + (Number(a.lp_planned) || 0), t = Number(a.target) || 0;
    const p = t > 0 ? Math.min(100, (have / t) * 100) : null, done = t > 0 && Number(a.lp_done) >= t;
    return `<div class="sp-area" role="group" aria-label="${esc(`${a.name}, ${kindText(a.kind)}, ${areaLine(a)}`)}"><div class="sp-area-h"><b>${esc(a.name)}</b><span class="sp-tag ${kindClass(a.kind)}">${esc(kindText(a.kind))}</span></div>`
      + (p != null ? `<div class="progress${done ? " ok" : ""}" aria-hidden="true"><i style="width:${p.toFixed(0)}%"></i></div>` : "")
      + `<small>${esc(areaLine(a))}</small>${a.rule ? `<details class="sp-rule"><summary>Regel</summary><p>${esc(shorten(a.rule, 500))}</p></details>` : ""}</div>`;
  }).join("");
  const ex = (plan.excluded || []);
  const exHtml = ex.length ? `<div class="sp-excl"><h3>Nicht belegt</h3><ul>${ex.map(o => `<li><span>${esc(o.title)} · ${esc(lpText(o.lp))}</span>${edit ? `<button type="button" class="btn sm" data-restore="${esc(o.id)}" aria-label="${esc(`${o.title} zurück in den Plan`)}">${ic ? ic("undo", 14) : ""} Zurück in den Plan</button>` : ""}</li>`).join("")}</ul></div>` : "";
  return `<section class="card sp-areas" aria-labelledby="spAreasH"><div class="card-head"><h2 id="spAreasH">${ic ? ic("layers", 16) : ""} Bereiche und Wahl</h2></div>`
    + (groups ? `<div class="sp-groups">${groups}</div>` : "") + (rows ? `<div class="sp-area-grid">${rows}</div>` : "") + exHtml + `</section>`;
}

// ---------------------------------------------------------------- Fenster: Auswahl, Richtung, Verschieben

/** eine Zeile der Auswahl; aufgeklappt mit Pruefung, Kurztext (aus dem Moduldetail), Turnus-Warnung und "In … wählen" */
export function optionRowHtml(plan, o, { open, detail, target }, ic) {
  const warn = target ? turnusWarning(o.turnus, target) : null;
  const areaName = area(plan, o.area)?.name;
  const label = [o.title, `${number(o.lp)} Leistungspunkte`, kindText(o.kind), turnusShort(o.turnus) ? turnusLong(o.turnus) : null, o.semester != null ? `empfohlen im ${o.semester}. Semester` : null, o.excluded ? "nicht belegt" : null].filter(Boolean).join(", ");
  const content = String(detail?.texts?.content ?? "").trim();
  return `<li class="sp-opt${open ? " open" : ""}"><button type="button" class="sp-opt-h" data-opt="${esc(o.id)}" aria-expanded="${open ? "true" : "false"}" aria-controls="spOpt-${esc(o.id)}" aria-label="${esc(label)}">`
    + `<span class="sp-opt-t"><b>${esc(o.title)}</b><span class="sp-tags"><span class="sp-tag ${kindClass(o.kind)}">${esc(kindText(o.kind))}</span>${turnusShort(o.turnus) ? `<span class="sp-tag line">${esc(turnusShort(o.turnus))}</span>` : ""}${o.semester != null ? `<span class="sp-tag line">${esc(o.semester)}. Semester</span>` : ""}${o.excluded ? `<span class="sp-tag line">nicht belegt</span>` : ""}</span>${areaName ? `<small>${esc(areaName)}</small>` : ""}</span>`
    + `<span class="sp-lp">${esc(lpText(o.lp))}</span><span class="sp-chev" aria-hidden="true">${ic ? ic(open ? "chevron-down" : "chevron-right", 14) : ""}</span></button>`
    + (open ? `<div class="sp-opt-b" id="spOpt-${esc(o.id)}">`
      + (detail ? (detail.exam ? `<p>Prüfung: ${esc(shorten(detail.exam))}</p>` : "") + (content ? `<p>${esc(shorten(content, 240))}</p>` : "")
        : `<div class="sp-status"><span class="sp-spin" aria-hidden="true"></span><span>Lädt …</span></div>`)
      + (warn ? `<p class="sp-hint">${ic ? ic("alert", 12) : ""}<span>${esc(warn)}</span></p>` : "")
      + `<button type="button" class="btn primary sm" data-choose="${esc(o.id)}">${ic ? ic("plus", 14) : ""} ${target ? `In ${esc(target)} wählen` : "Wählen"}</button></div>` : "")
    + `</li>`;
}

/** Liste der Auswahl (hoechstens 150 Zeilen) oder Hinweis */
export function chooserListHtml(plan, slot, query, ui, ic) {
  const list = choices(plan, slot, query);
  if (!list.length) return `<p class="muted">${slot ? "Für diesen Platz gibt es im Katalog keine weiteren Module – trag unten einen eigenen ein." : "Alle Module des Katalogs sind schon im Plan."}</p>`;
  const shown = list.slice(0, 150);
  return `<ul class="sp-opts" aria-label="Module zur Wahl">${shown.map(o => optionRowHtml(plan, o, { open: ui.expanded === o.id, detail: ui.details?.[o.id], target: ui.target }, ic)).join("")}</ul>`
    + (list.length > shown.length ? `<p class="muted small">${list.length - shown.length} weitere – such nach dem Namen.</p>` : "");
}

/** Kopf der Auswahl: Platz mit Regel, oder (Modul hinzufuegen) das Semester */
export function chooserHeadHtml(plan, slot, target) {
  if (slot) {
    const rule = area(plan, slot.area)?.rule;
    return `<p class="sp-ch-line"><b>${esc(slotTitle(slot))}</b> · ${esc(slot.id?.startsWith("tausch-") ? `tauscht im ${slot.term}` : slotLine(slot, plan))}</p>${rule ? `<p class="muted small">${esc(shorten(rule, 500))}</p>` : ""}`;
  }
  return `<label class="sp-field"><span>Semester</span><select class="input" id="spChTerm">${moveTerms(plan).map(t => { const f = fachsemesterOf(plan, t); return `<option value="${esc(t)}"${t === target ? " selected" : ""}>${esc(t)}${f != null ? ` · ${f}. Fachsemester` : ""}</option>`; }).join("")}</select></label>`;
}

export const CUSTOM_HINT = "Zum Beispiel eine Studium-generale-Veranstaltung einer anderen Fakultät. Heißt er wie in QIS, übernimmt StudiNow Stand und Note.";
export function customBlockHtml(ic) {
  return `<div class="sp-custom" role="group" aria-labelledby="spCustH"><h3 id="spCustH">Eigener Eintrag</h3><p class="muted small">${esc(CUSTOM_HINT)}</p>`
    + `<div class="sp-custom-row"><input class="input" id="spCustTitle" placeholder="Titel" aria-label="Titel des eigenen Eintrags" maxlength="200"><input class="input sp-lp-in" id="spCustLp" value="5" inputmode="decimal" aria-label="Leistungspunkte des eigenen Eintrags"><button type="button" class="btn sm" id="spCustAdd" disabled>${ic ? ic("plus", 14) : ""} Hinzufügen</button></div></div>`;
}

/** Auswahl einer Richtung (Schwerpunkt, Nebenfach) */
export function tracksHtml(plan, slot, ic) {
  const g = (plan?.groups || []).find(x => x.id === slot.group);
  return `<p class="muted">Wähle eine Richtung. Ihre Module erscheinen danach als Plätze im Plan.</p><div class="sp-tracks">${(slot.areas || []).map(id => {
    const a = area(plan, id), on = g?.chosen === id;
    const sub = [a ? `${Number(a.options) || 0} Module` : null, (a?.lp_max ?? a?.lp_required) != null ? `bis ${lpText(a.lp_max ?? a.lp_required)}` : null].filter(Boolean).join(" · ");
    return `<button type="button" class="sp-track${on ? " on" : ""}" data-pick-track="${esc(id)}" aria-pressed="${on ? "true" : "false"}"><span><b>${esc(a?.name || id)}</b>${sub ? `<small>${esc(sub)}</small>` : ""}${a?.rule ? `<small class="sp-rule-t">${esc(shorten(a.rule, 220))}</small>` : ""}</span>${on && ic ? ic("check", 15) : ""}</button>`;
  }).join("")}</div>`;
}

/** Zeilen "Verschieben nach …": Semester ab jetzt mit Fachsemester, LP danach und Turnus-Warnung */
export function moveRows(plan, m) {
  const here = semesterOf(plan, m.id)?.term;
  return moveTerms(plan).map(term => {
    const sem = (plan.semesters || []).find(s => s.term === term), current = term === here;
    const lp = (Number(sem?.lp) || 0) + (current ? 0 : Number(m.lp) || 0);
    return { term, fach: fachsemesterOf(plan, term), current, lp, over: !current && lp > LP_LIMIT + 0.01, warn: current ? null : turnusWarning(m.turnus, term) };
  });
}

export function moveHtml(plan, m, ic) {
  const rows = moveRows(plan, m);
  const sub = [lpText(m.lp), turnusLong(m.turnus), m.semester != null ? `empfohlen im ${m.semester}. Fachsemester` : null].filter(Boolean).join(" · ");
  return `<h3 class="sp-mv-t">${esc(m.title)}</h3><p class="muted small">${esc(sub)}</p><ul class="sp-moves" aria-label="Semester">${rows.map(r =>
    `<li><button type="button" class="sp-move${r.current ? " here" : ""}" data-to="${esc(r.term)}"${r.current ? ` aria-current="true"` : ""} aria-label="${esc([r.term, r.fach != null ? `${r.fach}. Fachsemester` : null, r.current ? "aktuelle Lage" : `danach ${number(r.lp)} Leistungspunkte`, r.warn].filter(Boolean).join(", "))}">`
    + `<span><b>${esc(r.term)}${r.fach != null ? ` · ${r.fach}. Fachsemester` : ""}</b><small class="${r.over ? "sp-warn" : ""}">${r.current ? "Hier liegt das Modul jetzt" : `danach ${esc(lpText(r.lp))} in diesem Semester`}</small>${r.warn ? `<small class="sp-hint">${ic ? ic("alert", 12) : ""}<span>${esc(r.warn)}</span></small>` : ""}</span>`
    + `${r.current && ic ? ic("check", 15) : ""}</button></li>`).join("")}</ul>`
    + (m.placed ? `<button type="button" class="btn" data-reset-one="${esc(m.id)}">${ic ? ic("undo", 14) : ""} Ins empfohlene Semester</button>` : "");
}

/** Menue "Aktionen" einer Karte bzw. eines Chips */
export function menuHtml(m, plan, ic) {
  return `<div class="sp-menu" role="menu" aria-label="${esc(`Aktionen für ${m.title}`)}">${menuItems(m, plan).map(([a, t, i]) =>
    `<button type="button" role="menuitem" tabindex="-1" class="${a === "drop" || a === "remove" ? "danger" : ""}" data-act="${a}">${ic ? ic(i, 14) : ""}<span>${esc(t)}</span></button>`).join("")}</div>`;
}

/** Hinweis ohne aktives Abo (Web/Windows): ansehen ja, aendern nein */
export function readOnlyHtml(ic) {
  return `<div class="card sp-ro" role="note">${ic ? ic("info", 16) : ""}<span><b>Nur lesen.</b> Ohne aktives Abo kannst du deinen Studienverlauf ansehen, aber nicht ändern. Mit StudiNow Plus oder Pro AI wählst, verschiebst und planst du wieder selbst.</span><a class="btn sm primary" href="#/abo">Abo wählen</a></div>`;
}

// ---------------------------------------------------------------- Gesamtansicht (alles auf einmal)

/** Kurzname fuer die Gesamtansicht: passt der Titel nicht in die Breite, Fuellwoerter weg und lange Woerter gekuerzt
    ("Grundlagen der Rechnernetze" -> "Grundl. Rechnernetze" -> "Grun. Rech."), zuletzt Anfangsbuchstaben */
export function abbreviation(title, width, font) {
  const t = String(title ?? "");
  const fits = s => s.length * font * 0.56 <= Math.max(20, width);
  if (fits(t)) return t;
  const filler = new Set(["der", "die", "das", "und", "für", "in", "im", "zur", "zum", "von", "des", "den", "mit", "an", "&", "-", "–"]);
  const words = t.split(/\s+/).filter(w => w && !filler.has(w.toLowerCase()));
  for (const keep of [7, 5, 4, 3]) {
    const s = words.map(w => /^[IVX0-9:]+$/.test(w) || [...w].length <= keep + 1 ? w : [...w].slice(0, keep).join("") + ".").join(" ");
    if (fits(s)) return s;
  }
  return words.map(w => /^[IVX0-9]+$/.test(w) ? " " + w : [...w][0]).join("");
}

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
/** geschaetzte Breite eines Chips (Punkt, Text, LP, Raender) */
export const chipWidth = (chars, font) => chars * font * 0.56 + font * 1.4 + 22;

/**
 * Masse der Gesamtansicht fuer die verfuegbare Flaeche. Breit (ab 600 px): Spalten ohne Rollen, quer eine Reihe, hoch
 * oder sehr schmal zwei; Chip-Hoehe 14–30 px je nach Platz (wie StudyPlanOverview auf dem iPad). Schmal (Telefon):
 * Semester untereinander, Chips brechen um; die groesste Schrift, bei der alles in die Hoehe passt.
 * semesters: [{ titles: [...], slots: n }] (Titel der Module und Plaetze).
 */
export function overviewLayout({ width, height, semesters, gap = 6 }) {
  const n = Math.max(1, semesters.length);
  const counts = semesters.map(s => (s.titles || []).length);
  if (width < 600) {
    // Masse wie im CSS (.sp-ov.stack): Rahmen 2, oben 4, Kopf 16, Abstand 3, unten 5; Chips umbrechend mit 4 px Abstand
    const inner = width - 14;
    for (let font = 12.5; font >= 9.5; font -= 0.5) {
      const chip = Math.round(font * 1.9), max = Math.floor((inner - 4) / 2);
      let total = 0;
      for (const s of semesters) {
        let lines = 0, x = 0;
        for (const t of s.titles || []) {
          const w = Math.min(max, chipWidth(String(t).length, font));
          if (lines === 0) { lines = 1; x = w; } else if (x + 4 + w > inner) { lines++; x = w; } else x += 4 + w;
        }
        total += 30 + lines * chip + Math.max(0, lines - 1) * 4;
      }
      total += gap * (n - 1);
      if (total <= height || font <= 9.5) return { mode: "stack", font, chip, chipMax: max, fits: total <= height, total };
    }
  }
  let rows = width >= height || n <= 4 ? 1 : 2;
  let perRow = Math.ceil(n / rows);
  let colWidth = (width - gap * (perRow - 1)) / perRow;
  if (rows === 1 && n > 4 && colWidth < 110) { rows = 2; perRow = Math.ceil(n / 2); colWidth = (width - gap * (perRow - 1)) / perRow; }
  const rowHeight = Math.max(120, (height - gap * (rows - 1)) / rows);
  const most = Math.max(1, ...counts);
  const raw = (rowHeight - 34 - most * 3) / most;
  const chip = clamp(raw, 14, 30), font = clamp(chip * 0.45, 9.5, 12.5);
  return { mode: "cols", rows, perRow, colWidth: Math.floor(colWidth), rowHeight: Math.floor(rowHeight), chip: Math.floor(chip), font: Math.round(font * 2) / 2, fits: raw >= 14 };
}

/** Eingabe fuer overviewLayout aus dem Plan */
export const overviewInput = plan => (plan?.semesters || []).map(s => ({ titles: [...(s.modules || []).map(m => m.title), ...(s.slots || []).map(sl => sl.title)] }));

/** Ton des Chips wie StudyPlanStatus.tone: bestanden gruen, angemeldet blau, nicht bestanden rot, verschoben gelb */
export const chipTone = m => ({ passed: "ok", registered: "info", failed: "bad", moved: "warn" }[moduleStatus(m)] || "neutral");

export function overviewHtml(plan, lay, ic, edit) {
  const stack = lay.mode === "stack";
  const textW = stack ? lay.chipMax - (lay.font * 1.4 + 22) : lay.colWidth - 8 - (lay.font * 1.4 + 22);
  const col = s => {
    const over = overloaded(s);
    const head = `<header class="sp-ov-h" aria-label="${esc([s.term, fach(s.fachsemester), `${number(s.lp)} Leistungspunkte${over ? ", mehr als der Richtwert" : ""}`, s.current ? "aktuelles Semester" : null].filter(Boolean).join(", "))}">`
      + `<span class="sp-ov-f" aria-hidden="true">${s.fachsemester != null ? `${esc(s.fachsemester)}.` : ""}</span><b aria-hidden="true">${esc(s.term)}</b><span class="sp-ov-lp${over ? " over" : ""}" aria-hidden="true">${esc(number(s.lp))}${Number(s.lp_slots) > 0 ? `<small>+${esc(number(s.lp_slots))}</small>` : ""}</span></header>`;
    const chips = (s.modules || []).map(m => {
      const drag = edit && movable(m), tone = chipTone(m), color = areaColor(m.area);
      return `<button type="button" class="sp-chip t-${tone}${moduleStatus(m) === "passed" ? " passed" : ""}" data-module="${esc(m.id)}"${drag ? ` draggable="true" data-drag="${esc(m.id)}"` : ""}${edit && menuItems(m, plan).length > 1 ? ` data-ctx="${esc(m.id)}" aria-haspopup="menu"` : ""} style="${color ? `--ac:${color}` : ""}" title="${esc(`${m.title} · ${lpText(m.lp)} · ${statusText(m)}`)}" aria-label="${esc(moduleLabel(m))}">`
        + `<i class="dot" aria-hidden="true"></i><span class="t">${esc(abbreviation(m.title, textW, lay.font))}</span><span class="n">${esc(number(m.lp))}</span>${(m.hints || []).length && ic ? `<span class="w">${ic("alert", Math.round(lay.font))}</span>` : ""}</button>`;
    }).join("") + (s.slots || []).map(sl =>
      `<${edit ? "button" : "span"}${edit ? ` type="button"` : ""} class="sp-chip slot" data-slot="${esc(sl.id)}" data-term="${esc(s.term)}" title="${esc(slotTitle(sl))}" aria-label="${esc(slotLabel(sl, plan))}">${ic ? ic(isTrack(sl) ? "layers" : "plus", Math.round(lay.font)) : "+"}<span class="t">${esc(abbreviation(sl.title, textW, lay.font))}</span>${Number(sl.lp) > 0 ? `<span class="n">${esc(number(sl.lp))}</span>` : ""}</${edit ? "button" : "span"}>`).join("");
    return `<section class="sp-ov-col${s.current ? " current" : ""}${over ? " over" : ""}" data-term="${esc(s.term)}"${edit ? ` data-drop="${esc(s.term)}"` : ""} aria-label="${esc(`${s.term}${s.fachsemester != null ? `, ${s.fachsemester}. Fachsemester` : ""}`)}">${head}<div class="sp-ov-chips">${chips}</div></section>`;
  };
  const style = stack ? `--chip:${lay.chip}px;--cf:${lay.font}px;--cmax:${lay.chipMax}px`
    : `--cols:${lay.perRow};--rowh:${lay.rowHeight}px;--chip:${lay.chip}px;--cf:${lay.font}px`;
  return `<div class="sp-ov ${stack ? "stack" : "cols"}" id="spOverview" style="${style}">${(plan.semesters || []).map(col).join("")}</div>`;
}

// ---------------------------------------------------------------- Einstellungen: Schwerpunkt und eigene Eintraege

/** Ausgangsstand der Einstellung "Schwerpunkt": je Gruppe der gewaehlte Bereich ("" = offen bzw. automatisch aus QIS) */
export const tracksBefore = plan => Object.fromEntries((plan?.groups || []).map(g => [g.id, g.auto ? "" : (g.chosen || "")]));

export function settingsExtraHtml(plan, ui, ic) {
  if (!plan?.available) return "";
  const groups = plan.groups || [];
  const tracks = groups.length ? `<div class="sp-sec"><h4>${ic ? ic("layers", 14) : ""} Schwerpunkt</h4><div class="card flat">${groups.map(g => {
    const cur = ui.tracks[g.id] || "", rule = area(plan, cur)?.rule;
    return `<label class="sp-field"><span>${esc(g.label)}</span><select class="input" data-set-track="${esc(g.id)}"><option value="">${g.auto && g.chosen ? `Automatisch aus QIS (${esc(area(plan, g.chosen)?.name || g.chosen)})` : "Noch offen"}</option>${(g.options || []).map(id => `<option value="${esc(id)}"${id === cur ? " selected" : ""}>${esc(area(plan, id)?.name || id)}</option>`).join("")}</select></label>${rule ? `<p class="muted small">${esc(shorten(rule, 300))}</p>` : ""}`;
  }).join("")}</div></div>` : "";
  const list = customModules(plan).filter(m => !ui.removed.has(m.id));
  const custom = customModules(plan).length ? `<div class="sp-sec"><h4>${ic ? ic("pen", 14) : ""} Eigene Einträge</h4><div class="card flat">${list.length ? `<ul class="sp-custom-list">${list.map(m =>
    `<li><span><b>${esc(m.title)}</b><small>${esc([lpText(m.lp), area(plan, m.area)?.name, statusText(m)].filter(Boolean).join(" · "))}</small></span><button type="button" class="btn ghost icon" data-rm-custom="${esc(m.id)}" aria-label="${esc(`${m.title} entfernen`)}" title="Entfernen">${ic ? ic("trash", 15) : "×"}</button></li>`).join("")}</ul>`
    : `<p class="muted small">Alle eigenen Einträge werden entfernt.</p>`}</div></div>` : "";
  return tracks + custom;
}

/** Zusatz zum Rumpf der Einstellungen: Schwerpunkt und eigene Eintraege nur, wenn geaendert (der Kern speichert teilweise) */
export function settingsExtraBody(plan, ui) {
  const out = {};
  if (!plan?.available) return out;
  const before = tracksBefore(plan);
  if (Object.keys({ ...before, ...ui.tracks }).some(k => (before[k] || "") !== (ui.tracks[k] || ""))) {
    out.tracks = Object.fromEntries(Object.entries(ui.tracks).filter(([, v]) => v));
  }
  if (ui.removed.size) out.custom = customModules(plan).filter(m => !ui.removed.has(m.id)).map(m => customJSON(m, plan));
  return out;
}
