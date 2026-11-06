// Bescheinigungen (06.11.2026, docs/BESCHEINIGUNGEN-2026-11-06.md): reine Regeln und HTML der Seite #/bescheinigungen,
// wie CertificatesPage.swift (groups, subline, emptyText, fileName). Daten: GET /api/certificates (app/certificates.py).
// Getestet in tests/js/certificates.test.mjs mit der gemeinsamen Fixture.

export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** Dokumente nach Art in der Reihenfolge der Liste (der Server sortiert schon) */
export function groups(offers) {
  const order = [], by = new Map();
  for (const o of offers || []) {
    const k = o.kind || "sonstige";
    if (!by.has(k)) { order.push(k); by.set(k, []); }
    by.get(k).push(o);
  }
  return order.map(k => ({ kind: k, label: by.get(k)[0]?.kind_label || k, offers: by.get(k) }));
}

const pad = n => String(n).padStart(2, "0");

/** "06.11.2026, 14:03" aus "2026-11-06T14:03:00" (Zeit wie gespeichert, Berlin); ohne Uhrzeit nur das Datum */
export function stand(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(String(iso || ""));
  if (!m) return String(iso || "");
  return `${m[3]}.${m[2]}.${m[1]}` + (m[4] ? `, ${m[4]}:${m[5]}` : "");
}

/** "WiSe 2026/27 · Stand: 06.11.2026, 14:03" bzw. "noch nicht geladen"; unbestaetigter Aufbau mit Hinweis */
export function subline(o) {
  const parts = [];
  if (o.semester) parts.push(o.semester);
  if (o.file) parts.push("Stand: " + stand(o.file.fetched_at) + (o.file.semester && o.file.semester !== o.semester ? ` (${o.file.semester})` : ""));
  else parts.push("noch nicht geladen");
  if (o.confirmed === false) parts.push("Aufbau noch nicht mit echtem Konto geprüft");
  return parts.join(" · ");
}

export function emptyText(status, portal) {
  if (status === "login") return `Melde dich bei ${portal} an, dann zeigt StudiNow hier alle Bescheinigungen.`;
  if (!status || status === "never") return `Noch nicht gelesen. Tippe auf „Liste aktualisieren“, dann zeigt StudiNow hier alles, was ${portal} anbietet.`;
  return `${portal} bietet deinem Konto gerade keine Bescheinigungen an.`;
}

export function fileName(title, fetchedAt) {
  const d = stand(fetchedAt).split(",")[0] || "";
  return `${String(title || "Bescheinigung").replace(/\//g, "-").replace(/:/g, " ").slice(0, 80)}${d ? ` (Stand ${d})` : ""}.pdf`;
}

export const missing = d => (d?.kinds || []).filter(k => !k.offered);

/** Zeile eines Dokuments: Titel, Stand, Semesterwahl, Knoepfe (Öffnen/Neu laden bzw. Herunterladen) */
export function rowHtml(o, icon = () => "") {
  const sel = (o.semesters || []).length
    ? `<select class="input sm" data-sem="${esc(o.id)}" aria-label="Semester">${o.semesters.map(s => `<option value="${esc(s.value)}">${esc(s.label)}</option>`).join("")}</select>` : "";
  const btns = o.file
    ? `<a class="btn primary sm" href="${esc(o.file.url)}" target="_blank" rel="noopener" download="${esc(fileName(o.title, o.file.fetched_at))}" data-open="${esc(o.id)}">${icon("eye", 14)} Öffnen</a>
       <button class="btn sm" data-dl="${esc(o.id)}">${icon("sync", 14)} Neu laden</button>`
    : `<button class="btn primary sm" data-dl="${esc(o.id)}">${icon("download", 14)} Herunterladen</button>`;
  return `<div class="item" data-cert="${esc(o.id)}">${icon("file-text", 16)}<div class="main"><div class="title">${esc(o.title)}</div>
    <div class="sub">${esc(subline(o))}</div></div><div class="row" style="gap:.4rem;flex-wrap:wrap">${sel}${btns}</div></div>`;
}

export function pageHtml(d, icon = () => "") {
  const offers = d?.offers || [];
  const portal = d?.portal || "Portal";
  const miss = missing(d);
  const loginNeeded = d?.status === "login";
  return `<div class="content" style="max-width:960px"><div class="page-head"><div><h1>Bescheinigungen</h1>
    <div class="sub">Alles, was ${esc(portal)} an Bescheinigungen anbietet. StudiNow lädt eine PDF nur, wenn du klickst, und speichert sie mit Datum.</div></div>
    <div class="actions"><a class="btn sm" href="#/services">${icon("graduation", 14)} Uni & Noten</a></div></div>
    <div class="card"><div class="card-head"><h2>${icon("graduation", 18)} Aus ${esc(portal)}</h2><div class="actions">
      ${loginNeeded ? `<a class="btn primary sm" href="#/settings?tab=account">${icon("arrow-right", 14)} Anmeldung nötig</a>` : ""}
      <button class="btn sm" id="certRefresh">${icon("sync", 14)} Liste aktualisieren</button></div></div>
      <div class="row" style="gap:.5rem">${loginNeeded ? `<span class="badge warn">Anmeldung nötig</span>` : d?.status === "error" ? `<span class="badge bad">Fehler</span>` : d?.checked_at ? `<span class="badge neutral">Liste vom ${esc(stand(d.checked_at))}</span>` : ""}
      <span class="small muted">${esc(d?.message || "")}</span></div></div>
    ${offers.length ? "" : `<div class="card"><div class="empty small">${icon("file-text", 30)}<div>${esc(emptyText(d?.status, portal))}</div></div></div>`}
    ${groups(offers).map(g => `<div class="card" data-kind="${esc(g.kind)}"><div class="card-head"><h2>${icon(g.kind === "notenspiegel" ? "exam" : "file-text", 18)} ${esc(g.label)}</h2></div>
      <div class="list">${g.offers.map(o => rowHtml(o, icon)).join("")}</div></div>`).join("")}
    ${miss.length && d?.status !== "never" ? `<div class="card"><div class="card-head"><h2>${icon("info", 18)} Nicht im Portal gefunden</h2></div>
      <p class="small">${miss.map(k => esc(k.label)).join(" · ")}</p><p class="small muted">Diese Dokumente bietet ${esc(portal)} deinem Konto gerade nicht an. Manche erscheinen erst nach der Rückmeldung oder wenn Leistungen verbucht sind; sonst hilft das Studierendensekretariat.</p></div>` : ""}
    ${(d?.documents || []).length ? `<div class="card"><div class="card-head"><h2>${icon("folder", 18)} Beim Notenabruf gespeichert</h2></div><div class="list">${d.documents.map(x => `<a class="item" href="/api/qis/documents/${esc(x.id)}" target="_blank">${icon("file-text", 16)}<div class="main"><div class="title">${esc(x.title)}</div><div class="sub">${esc(stand(x.fetched_at))}</div></div></a>`).join("")}</div></div>` : ""}
    <p class="muted tiny">${esc(d?.note || "")}</p></div>`;
}
