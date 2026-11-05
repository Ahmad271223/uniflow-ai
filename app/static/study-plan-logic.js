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

/** Karte eines Moduls */
export function moduleCardHtml(m, ic) {
  const s = moduleStatus(m), st = STATUS[s], reason = reasonLine(m), color = areaColor(m.area);
  return `<button type="button" class="sp-mod${s === "failed" ? " failed" : ""}${s === "passed" ? " passed" : ""}" data-module="${esc(m.id)}" style="${color ? `--ac:${color}` : ""}" aria-label="${esc(moduleLabel(m))}" title="Details zum Modul">`
    + `<span class="sp-mod-top"><b class="sp-mod-title">${esc(m.title)}</b><span class="sp-lp">${esc(lpText(m.lp))}</span></span>`
    + `<span class="sp-tags"><span class="sp-tag ${kindClass(m.kind)}">${esc(kindText(m.kind))}</span>${turnusShort(m.turnus) ? `<span class="sp-tag line">${esc(turnusShort(m.turnus))}</span>` : ""}</span>`
    + pill(statusText(m), st.tone, st.icon, ic)
    + (reason ? `<span class="sp-reason">${esc(reason)}</span>` : "")
    + (m.last_attempt ? `<span class="sp-last">${ic ? ic("alert", 12) : ""}<b>Letzter Versuch</b></span>` : "")
    + `</button>`;
}

/** Spalte bzw. Abschnitt eines Semesters */
export function semesterHtml(s, ic) {
  const over = Number(s.lp) > LP_LIMIT + 0.01;
  return `<section class="sp-sem${s.current ? " current" : ""}" data-term="${esc(s.term)}" aria-label="${esc([s.term, fach(s.fachsemester), `${number(s.lp)} Leistungspunkte${over ? ", mehr als der Richtwert" : ""}`, s.current ? "aktuelles Semester" : null].filter(Boolean).join(", "))}">`
    + `<header class="sp-sem-head"><div><b>${esc(s.term)}</b>${s.current ? ` <span class="badge">Aktuell</span>` : ""}${fach(s.fachsemester) ? `<small>${esc(fach(s.fachsemester))}</small>` : ""}</div>`
    + `<span class="badge ${over ? "warn" : "neutral"}">${over && ic ? ic("alert", 12) : ""}${esc(lpText(s.lp))}</span></header>`
    + ((s.modules || []).length ? `<div class="sp-mods">${s.modules.map(m => moduleCardHtml(m, ic)).join("")}</div>` : `<p class="sp-none">Keine Module geplant</p>`)
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
export function boardHtml(plan, filter, ic) {
  const sems = visibleSemesters(plan, filter);
  if (!sems.length) {
    return `<div class="card flat"><div class="empty">${ic ? `<div class="ic">${ic(filter === "passed" ? "check" : "calendar", 28)}</div>` : ""}${filter === "passed" ? "Noch kein Modul bestanden." : "Alles bestanden – nichts mehr offen."}</div></div>`;
  }
  return `<div class="sp-board" id="spBoard">${sems.map(s => semesterHtml(s, ic)).join("")}</div>`;
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

export function settingsHtml(s, st, ic) {
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
    + `<div class="sp-err small" id="spSetErr" hidden></div></div>`;
}
