// Community Teil 2 in der Oberflaeche (28.10.2026): Fragen je Kurs mit Antworten, Lesezeichen, Mitteilungen.
// Gleich im Browser (Dienst) und in der Windows-App (Weiterleitung ueber das Studora-Konto, app/service_link.py).
// Der Kurs-Schluessel entsteht im eigenen Backend aus der Kurs-ID (/api/courses/community-keys), wie auf dem iPad.
import { icon } from "./icons.js?v=31";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const when = iso => { try { return new Date(iso).toLocaleString("de-DE", { day: "2-digit", month: "2-digit", year: "2-digit", hour: "2-digit", minute: "2-digit" }); } catch { return ""; } };
const REASONS = { offensive: "anstößig", spam: "Spam", foreignMaterial: "Fremdmaterial", gradedSubmission: "benotete Abgabe", other: "Sonstiges" };

export async function capi(path, { method = "GET", body } = {}) {
  const r = await fetch("/api/community" + path, { method, headers: body !== undefined ? { "Content-Type": "application/json" } : {}, body: body !== undefined ? JSON.stringify(body) : undefined });
  let d = null; try { d = await r.json(); } catch {}
  if (!r.ok) { const e = new Error(d?.detail || `Fehler ${r.status}`); e.code = d?.code; e.status = r.status; throw e; }
  return d;
}
export async function courseKeys() {
  const r = await fetch("/api/courses/community-keys"); if (!r.ok) throw new Error("Kurse nicht lesbar");
  return (await r.json()).courses;
}
const body = t => esc(t).replace(/\n/g, "<br>");
function reasonPick() {
  const p = prompt(`Grund der Meldung (${Object.values(REASONS).join(", ")}):`, "Spam"); if (!p) return null;
  return Object.keys(REASONS).find(k => REASONS[k].toLowerCase().startsWith(p.trim().toLowerCase().slice(0, 4))) || "other";
}

// ---------------------------------------------------------------- Fragen eines Kurses
/** Liste mit "Neue Frage" und "Mehr laden". opts: {courseKey?, fingerprint?, page?, compact?, onOpen?} */
export async function renderQuestions(el, opts = {}) {
  let courses = [];
  try { courses = await courseKeys(); } catch (e) { el.innerHTML = `<p class="small muted">${esc(e.message)}</p>`; return; }
  if (!courses.length) { el.innerHTML = `<p class="small muted">Noch keine Kurse. Nach dem ersten Abgleich mit Stud.IP oder Learnweb erscheinen hier deine Kurse.</p>`; return; }
  let key = opts.courseKey || (() => { try { return localStorage.getItem("qa-course"); } catch { return null; } })();
  if (!courses.some(c => c.key === key)) key = courses[0].key;
  const st = { items: [], next: null, onlyThis: !!opts.fingerprint };
  const draw = () => {
    const c = courses.find(x => x.key === key);
    el.innerHTML = `<div class="qa">
      ${opts.courseKey ? `<div class="small"><b>${esc(c?.title || "")}</b></div>` : `<label class="small">Kurs <select class="input qa-course">${courses.map(x => `<option value="${x.key}" ${x.key === key ? "selected" : ""}>${esc(x.title)}${x.semester ? ` (${esc(x.semester)})` : ""}</option>`).join("")}</select></label>`}
      ${opts.fingerprint ? `<label class="small row" style="gap:.35rem;align-items:center"><input type="checkbox" class="qa-only" ${st.onlyThis ? "checked" : ""}> nur zu dieser PDF</label>` : ""}
      <details class="qa-new"><summary class="btn sm primary">${icon("plus", 13)} Frage stellen</summary>
        <div class="qa-form"><input class="input qa-title" maxlength="160" placeholder="Worum geht es? (z. B. Aufgabe 2b: Konvergenz zeigen)">
        <textarea class="input qa-body" rows="4" maxlength="4000" placeholder="Was hast du schon versucht? Wo hängst du?"></textarea>
        ${opts.fingerprint ? `<label class="small row" style="gap:.35rem;align-items:center"><input type="checkbox" class="qa-ref" checked> zu dieser PDF${opts.page ? `, Seite ${opts.page}` : ""}</label>` : ""}
        <div class="row" style="gap:.4rem"><button class="btn sm primary qa-send">Fragen</button><span class="qa-msg small"></span></div></div></details>
      <div class="qa-list">${st.items.length ? st.items.map(q => `<button class="qa-item" data-q="${q.id}"><b>${esc(q.title)}</b>${q.accepted_answer ? ` <span class="badge ok">gelöst</span>` : ""}${q.mine ? ` <span class="badge neutral">deine</span>` : ""}
        <span class="tiny muted">${esc(q.pseudonym)} · ${when(q.last_activity)} · ${q.answers} Antwort${q.answers === 1 ? "" : "en"}${q.page ? ` · Seite ${q.page}` : ""}</span></button>`).join("")
        : `<p class="small muted">Noch keine Fragen${st.onlyThis ? " zu dieser PDF" : " in diesem Kurs"}. Stell die erste – Kommilitonen mit demselben Kurs sehen sie.</p>`}</div>
      ${st.next ? `<button class="btn sm ghost qa-more">Mehr laden</button>` : ""}</div>`;
    $(".qa-course", el)?.addEventListener("change", e => { key = e.target.value; try { localStorage.setItem("qa-course", key); } catch {} load(true); });
    $(".qa-only", el)?.addEventListener("change", e => { st.onlyThis = e.target.checked; load(true); });
    $(".qa-more", el)?.addEventListener("click", () => load(false));
    $$("[data-q]", el).forEach(b => b.onclick = () => (opts.onOpen || openQuestion)(b.dataset.q, () => load(true)));
    $(".qa-send", el).onclick = async e => {
      const t = $(".qa-title", el).value.trim(); if (!t) return; e.target.disabled = true;
      const ref = $(".qa-ref", el)?.checked;
      try { await capi(`/courses/${key}/questions`, { method: "POST", body: { title: t, body: $(".qa-body", el).value, fingerprint: ref ? opts.fingerprint : undefined, page: ref ? opts.page : undefined } }); load(true); }
      catch (x) { $(".qa-msg", el).textContent = x.message; e.target.disabled = false; }
    };
  };
  const load = async reset => {
    if (reset) { st.items = []; st.next = null; }
    const q = new URLSearchParams({ limit: "30" }); if (st.next && !reset) q.set("before", st.next); if (st.onlyThis && opts.fingerprint) q.set("fingerprint", opts.fingerprint);
    try { const d = await capi(`/courses/${key}/questions?${q}`); st.items = reset ? d.questions : st.items.concat(d.questions); st.next = d.next; draw(); }
    catch (e) { el.innerHTML = `<p class="small">${icon("alert", 13)} ${esc(e.message)}</p>`; }
  };
  draw(); load(true);
}

// ---------------------------------------------------------------- eine Frage mit Antworten (Dialog)
export async function openQuestion(id, onChange) {
  const back = document.createElement("div"); back.className = "modal qa-modal";
  back.innerHTML = `<div class="modal-box" style="width:min(760px,100%);max-height:90vh;overflow:auto" role="dialog" aria-modal="true" aria-label="Frage"><div class="qa-detail">Lade …</div></div>`;
  (document.getElementById("overlay") || document.body).append(back);
  const close = () => { back.remove(); onChange?.(); };
  back.addEventListener("click", e => { if (e.target === back) close(); });
  const onKey = e => { if (e.key === "Escape") { close(); document.removeEventListener("keydown", onKey); } }; document.addEventListener("keydown", onKey);
  const box = $(".qa-detail", back);
  const draw = async () => {
    let q; try { q = await capi(`/questions/${id}`); } catch (e) { box.innerHTML = `<p>${esc(e.message)}</p><button class="btn" data-x>Schließen</button>`; $("[data-x]", box).onclick = close; return; }
    box.innerHTML = `<div class="card-head"><h2>${esc(q.title)}</h2><button class="btn ghost icon" data-x aria-label="Schließen">${icon("x", 16)}</button></div>
      <div class="tiny muted">${esc(q.pseudonym)} · ${when(q.created_at)}${q.edited_at ? " · bearbeitet" : ""}${q.page ? ` · Seite ${q.page}` : ""}</div>
      ${q.body ? `<div class="qa-body-text">${body(q.body)}</div>` : ""}
      <div class="row wrap" style="gap:.3rem;margin:.4rem 0 .8rem"><button class="btn sm ghost" data-bm>${icon("bookmark", 13)} ${q.bookmarked ? "Lesezeichen entfernen" : "Merken"}</button>
        ${q.mine ? `<button class="btn sm ghost" data-del-q>${icon("trash", 13)} Frage löschen</button>` : `<button class="btn sm ghost" data-rep-q>Melden</button>`}</div>
      <h3 class="small" style="margin:.4rem 0">${q.answer_list.length} Antwort${q.answer_list.length === 1 ? "" : "en"}</h3>
      <div class="qa-answers">${q.answer_list.map(a => `<div class="qa-answer${a.id === q.accepted_answer ? " accepted" : ""}">
        ${a.id === q.accepted_answer ? `<div class="badge ok">${icon("check", 12)} Lösung</div>` : ""}
        <div>${body(a.body)}</div><div class="tiny muted">${esc(a.pseudonym)}${a.by_asker ? " (fragt)" : ""} · ${when(a.created_at)}</div>
        <div class="row wrap" style="gap:.25rem;margin-top:.25rem">
          <button class="btn sm ghost${a.voted_by_me ? " active" : ""}" data-vote="${a.id}" ${a.mine ? "disabled" : ""} title="Hilfreich">${icon("heart", 13)} ${a.votes}</button>
          ${q.mine ? `<button class="btn sm ghost" data-accept="${a.id === q.accepted_answer ? "" : a.id}">${a.id === q.accepted_answer ? "Markierung aufheben" : "Als Lösung markieren"}</button>` : ""}
          ${a.mine || q.mine ? `<button class="btn sm ghost" data-del-a="${a.id}">Löschen</button>` : `<button class="btn sm ghost" data-rep-a="${a.id}">Melden</button>`}</div></div>`).join("") || `<p class="small muted">Noch keine Antwort.</p>`}</div>
      <div class="qa-form"><textarea class="input qa-ans" rows="3" maxlength="4000" placeholder="Deine Antwort"></textarea><div class="row" style="gap:.4rem"><button class="btn sm primary" data-answer>Antworten</button><span class="qa-msg small"></span></div></div>`;
    const run = async (fn, b) => { if (b) b.disabled = true; try { await fn(); await draw(); } catch (e) { const m = $(".qa-msg", box); if (m) m.textContent = e.message; else alert(e.message); if (b) b.disabled = false; } };
    $("[data-x]", box).onclick = close;
    $("[data-bm]", box).onclick = e => run(() => capi(`/bookmarks/question/${q.id}`, { method: q.bookmarked ? "DELETE" : "POST" }), e.target);
    $("[data-del-q]", box)?.addEventListener("click", async () => { if (!confirm("Frage löschen?")) return; await capi(`/questions/${q.id}`, { method: "DELETE" }); close(); });
    $("[data-rep-q]", box)?.addEventListener("click", () => { const r = reasonPick(); if (r) run(() => capi(`/questions/${q.id}/report-post`, { method: "POST", body: { reason: r } })); });
    $$("[data-vote]", box).forEach(b => b.onclick = () => { const a = q.answer_list.find(x => x.id === b.dataset.vote); run(() => capi(`/answers/${a.id}/vote`, { method: a.voted_by_me ? "DELETE" : "POST" }), b); });
    $$("[data-accept]", box).forEach(b => b.onclick = () => run(() => capi(`/questions/${q.id}/accept`, { method: "POST", body: { answer_id: b.dataset.accept || null } }), b));
    $$("[data-del-a]", box).forEach(b => b.onclick = () => { if (confirm("Antwort löschen?")) run(() => capi(`/answers/${b.dataset.delA}`, { method: "DELETE" }), b); });
    $$("[data-rep-a]", box).forEach(b => b.onclick = () => { const r = reasonPick(); if (r) run(() => capi(`/answers/${b.dataset.repA}/report-post`, { method: "POST", body: { reason: r } }), b); });
    $("[data-answer]", box).onclick = e => { const t = $(".qa-ans", box).value.trim(); if (t) run(() => capi(`/questions/${q.id}/answers`, { method: "POST", body: { body: t } }), e.target); };
  };
  draw();
}

// ---------------------------------------------------------------- Lesezeichen und Mitteilungen
async function openFingerprint(fp) {
  const r = await fetch(`/api/files/by-fingerprint/${fp}`); const d = await r.json().catch(() => ({}));
  if (!r.ok) { alert(d.detail || "Diese PDF ist hier nicht vorhanden."); return; }
  try { sessionStorage.setItem("open-community", "1"); } catch {}
  location.hash = `#/doc/${encodeURIComponent(d.file_id)}`;
}
export async function renderBookmarks(el) {
  let d; try { d = await capi("/bookmarks"); } catch (e) { el.innerHTML = `<p class="small">${esc(e.message)}</p>`; return; }
  el.innerHTML = d.bookmarks.length ? `<div class="qa-list">${d.bookmarks.map(b => `<button class="qa-item" data-bk="${b.kind}" data-id="${b.id}" data-fp="${b.fingerprint || ""}">${icon(b.kind === "question" ? "message" : "layers", 14)} <b>${esc(b.title)}</b><span class="tiny muted">${b.kind === "question" ? "Frage" : "Lösung"} · gemerkt ${when(b.created_at)}</span></button>`).join("")}</div>`
    : `<p class="small muted">Noch nichts gemerkt. Lösungen merkst du in der Community-Leiste des Editors, Fragen im Fragen-Fenster.</p>`;
  $$("[data-bk]", el).forEach(b => b.onclick = () => b.dataset.bk === "question" ? openQuestion(b.dataset.id, () => renderBookmarks(el)) : openFingerprint(b.dataset.fp));
}
const NOTE = { comment: "hat deine Lösung kommentiert", reply: "hat auf deinen Kommentar geantwortet", like: "gefällt deine Lösung", answer: "hat deine Frage beantwortet", accepted: "hat deine Antwort als Lösung markiert" };
export async function renderNotifications(el, onCount) {
  let d; try { d = await capi("/notifications?limit=100"); } catch (e) { el.innerHTML = `<p class="small">${esc(e.message)}</p>`; return; }
  onCount?.(d.unread);
  el.innerHTML = `<div class="row" style="justify-content:space-between;align-items:center;margin-bottom:.4rem"><span class="small muted">${d.unread} ungelesen</span>${d.unread ? `<button class="btn sm ghost" data-all>Alle als gelesen markieren</button>` : ""}</div>
    ${d.notifications.length ? `<div class="qa-list">${d.notifications.map(n => `<button class="qa-item${n.read ? "" : " unread"}" data-n="${n.id}"><span><b>${esc(n.actor || "Jemand")}</b>${n.count > 1 ? ` und ${n.count - 1} weitere` : ""} ${NOTE[n.kind] || n.kind}${n.title ? `: „${esc(n.title)}“` : ""}</span>${n.text && n.kind !== "like" && n.text !== n.title ? `<span class="tiny muted">${esc(n.text)}</span>` : ""}<span class="tiny muted">${when(n.created_at)}</span></button>`).join("")}</div>`
      : `<p class="small muted">Keine Mitteilungen. Du bekommst hier Bescheid, wenn jemand deine Lösung kommentiert oder liked oder deine Frage beantwortet.</p>`}`;
  $("[data-all]", el)?.addEventListener("click", async () => { await capi("/notifications/read", { method: "POST", body: {} }); renderNotifications(el, onCount); });
  $$("[data-n]", el).forEach(b => b.onclick = async () => {
    const n = d.notifications.find(x => x.id === b.dataset.n);
    if (!n.read) await capi("/notifications/read", { method: "POST", body: { ids: [n.id] } }).catch(() => {});
    if (n.target_kind === "question") openQuestion(n.target_id, () => renderNotifications(el, onCount));
    else if (n.fingerprint) openFingerprint(n.fingerprint);
  });
}

/** Zahl ungelesener Mitteilungen (Glocke in der Kopfzeile); null = Community nicht verfuegbar. */
export async function unreadCount() {
  try { const r = await fetch("/api/community/notifications?unread=true&limit=1"); if (!r.ok) return null; return (await r.json()).unread; } catch { return null; }
}
