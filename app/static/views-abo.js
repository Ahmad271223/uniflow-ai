// Studora – Abo-Übersicht: vier Tarife, eigener Stand, Kontingente (Server: /api/billing/plans, /api/entitlements).
// Es wird nur als enthalten gezeigt, was technisch freigeschaltet ist (status "available"); alles andere steht als
// "kommt bald" bzw. "in Vorbereitung" daneben. Abschließen geht heute nur in der Apple-App (App Store).
import { api, esc, icon, state } from "./core.js?v=32";

const euro = c => c === 0 ? "0 €" : `${(c / 100).toFixed(2).replace(".", ",")} €`;
const QUOTA_TXT = (q, key, labels) => {
  const v = q[key];
  if (v === null) return `${labels[key]}: unbegrenzt (Fair Use)`;
  if (!v) return null;
  return `${labels[key]}: ${v} pro Monat`;
};
const POSITION = {
  free: "Organisieren, lesen, Stundenplan – kostenlos.",
  plus: "Schreiben mit Apple Pencil, Textmarker und Textfeldern, Notizen auf allen Geräten.",
  pro_connect: "Für Studierende, die mehr aus ihren Tests holen wollen: Statistiken, Wiederholung, Empfehlungen.",
  pro_ai: "Komfortabel: Studora-KI inklusive, kein eigenes ChatGPT-Konto nötig.",
};

// Funktionen der Studora-KI: als enthalten nur, wenn der Dienst die KI eingerichtet hat (studora_ai_configured)
const AI_FEATURES = new Set(["can_generate_studora_ai_tests", "can_use_ai_explanations", "can_use_ai_generated_questions", "can_use_ai_summaries", "can_use_ai_recommendations"]);

function featureRows(contract, key) {
  const order = contract.order, idx = order.indexOf(key);
  const own = Object.entries(contract.entitlements).filter(([, e]) => e.from === key);
  const rows = [];
  if (idx > 0) rows.push(`<li class="muted">${icon("check", 13)} Alles aus ${esc(contract.plans[order[idx - 1]].name)}</li>`);
  for (const [name, e] of own) {
    if (e.status === "available" && AI_FEATURES.has(name) && !contract.studora_ai_configured) rows.push(`<li class="muted">${icon("clock", 13)} ${esc(e.label)} <span class="badge neutral">in Vorbereitung</span></li>`);
    else if (e.status === "available") rows.push(`<li>${icon("check", 13)} ${esc(e.label)}</li>`);
    else if (e.status === "coming_soon") rows.push(`<li class="muted">${icon("clock", 13)} ${esc(e.label)} <span class="badge neutral">kommt bald</span></li>`);
    else if (name === "chatgpt_connection_premium") rows.push(`<li class="muted">${icon("clock", 13)} Eigenes ChatGPT-Konto verbinden <span class="badge neutral">in Vorbereitung</span></li>`);
  }
  return rows.join("");
}

function quotaBar(label, q) {
  if (!q) return "";
  if (q.unlimited || q.limit === null) return `<div class="small">${esc(label)}: ${q.used} genutzt · unbegrenzt (Fair Use)</div>`;
  if (!q.limit) return "";
  const pct = Math.min(100, Math.round(100 * q.used / q.limit));
  return `<div class="small" style="margin:.35rem 0">${esc(label)}: <b>${q.used} von ${q.limit}</b> in diesem Monat
    <div style="height:6px;border-radius:4px;background:var(--surface-2);margin-top:.25rem"><div style="height:6px;border-radius:4px;width:${pct}%;background:${pct >= 100 ? "var(--bad)" : "var(--accent)"}"></div></div></div>`;
}

export async function viewAbo(_, params, view) {
  const [contract, me, gptLocal] = await Promise.all([api("/billing/plans"), api("/entitlements"), api("/integrations/chatgpt").catch(() => null)]);
  const labels = contract.quotas.labels, current = me.plan;
  const local = me.mode === "local";
  const status = local
    ? `<p class="muted small">Auf deinem eigenen PC gibt es keine Tarife: alle Funktionen sind frei, die KI läuft über deinen eigenen Claude-Zugang. Tarife gelten für Studora-Konten im Dienst und in der Apple-App.</p>`
    : `<p class="small" style="margin:.2rem 0">${me.expires_at ? `${me.will_renew ? "Verlängert sich am" : "Läuft aus am"} <b>${new Date(me.expires_at).toLocaleDateString("de-DE")}</b>` : current === "free" ? "Kostenlos, ohne Laufzeit." : "Ohne Ablaufdatum."}
       ${me.pending_plan ? ` · Ab der nächsten Verlängerung: <b>${esc(contract.plans[me.pending_plan]?.name || me.pending_plan)}</b>` : ""}</p>
       ${quotaBar(labels.ai_tests_new, me.quotas.ai_tests_new)}${quotaBar(labels.library_tests, me.quotas.library_tests)}${quotaBar(labels.ai_assist, me.quotas.ai_assist)}`;
  const gpt = contract.integrations.chatgpt;
  const cards = contract.order.map(key => {
    const p = contract.plans[key], isCur = key === current;
    const q = p.quotas;
    const facts = [
      p.entitlements.can_annotate_pdf ? `${icon("pen", 13)} PDF-Bearbeitung und Apple Pencil` : `${icon("book", 13)} PDFs lesen, keine Bearbeitung`,
      ...[QUOTA_TXT(q, "ai_tests_new", labels), QUOTA_TXT(q, "library_tests", labels), QUOTA_TXT(q, "ai_assist", labels)]
        .map(t => t && !contract.studora_ai_configured && !t.startsWith(labels.library_tests) ? `${t} (sobald die Studora-KI eingerichtet ist)` : t),
    ].filter(Boolean).map(t => `<div class="small">${t}</div>`).join("");
    const highlight = key === "pro_ai" ? "border-color:var(--accent)" : "";
    const action = local ? "" : isCur ? `<span class="badge ok">Dein Tarif</span>`
      : key === "free" ? `<span class="muted small">Zurück zu Free: Abo im App Store kündigen</span>`
      : `<button class="btn sm" disabled title="${esc(contract.purchase.web.note)}">In der Apple-App abschließen</button>`;
    return `<div class="card" style="display:flex;flex-direction:column;gap:.5rem;${highlight}">
      <div class="card-head" style="margin:0"><h2>${esc(p.name)}</h2>${key === "pro_ai" ? `<span class="badge info">ohne eigenes ChatGPT</span>` : ""}</div>
      <div><span style="font-size:1.6rem;font-weight:700">${euro(p.price_cents)}</span><span class="muted small"> / Monat</span></div>
      <p class="muted small" style="margin:0">${esc(POSITION[key] || p.tagline)}</p>
      <div style="display:grid;gap:.2rem">${facts}</div>
      <ul style="list-style:none;padding:0;margin:.3rem 0;display:grid;gap:.3rem" class="small">${featureRows(contract, key)}</ul>
      <div style="margin-top:auto">${action}</div></div>`;
  }).join("");
  view.innerHTML = `<div class="content" style="max-width:1180px">
    <div class="page-head"><div><h1>Abo & Tarife</h1><div class="sub">${local ? "Eigener PC" : `Dein Tarif: ${esc(me.plan_name)}`}</div></div></div>
    <div class="card" style="margin-bottom:1rem">${status}</div>
    <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(240px,1fr))">${cards}</div>
    <div class="grid cols-2" style="margin-top:1rem">
      ${local && gptLocal?.available ? `<div class="card"><div class="card-head"><h2>${icon("sparkles", 18)} Eigenes ChatGPT-Konto</h2><span class="badge ${gptLocal.connected ? (gptLocal.sharing && !gptLocal.needs_reauth ? "ok" : "warn") : "neutral"}">${gptLocal.connected ? (gptLocal.needs_reauth ? "neu anmelden" : gptLocal.sharing ? "verbunden" : "ohne Abo-Nutzung") : "nicht verbunden"}</span></div>
        <p class="small muted">${gptLocal.connected ? `Verbunden als <b>${esc(gptLocal.email || gptLocal.name || "ChatGPT-Konto")}</b>${gptLocal.model ? `, Modell ${esc(gptLocal.model)}` : ""}. ` : "Auf dem eigenen PC kannst du dein ChatGPT-Konto (Plus, Pro oder Go) verbinden; KI-Anfragen laufen dann über dein Abo. "}Einrichten unter <a href="#/settings?tab=advanced">Einstellungen → Erweitert</a>. Das Token bleibt auf diesem Rechner; ohne Tarif, ohne Zahlung an uns.</p></div>`
      : `<div class="card"><div class="card-head"><h2>${icon("sparkles", 18)} Eigenes ChatGPT-Konto</h2><span class="badge ${gpt.status === "enabled" ? "ok" : "neutral"}">${gpt.status === "enabled" ? "verfügbar" : "noch nicht verfügbar"}</span></div>
        <p class="small muted">${esc(gpt.reason || "")} Sobald OpenAI Studora freigibt, kannst du dein eigenes ChatGPT-Abo verbinden. Diese Verbindung verkaufen wir nicht: sie wird nie nur gegen einen Studora-Tarif angeboten, solange die Bedingungen von OpenAI das nicht erlauben.</p></div>`}
      <div class="card"><div class="card-head"><h2>${icon("info", 18)} Abschließen, wechseln, kündigen</h2></div>
        <p class="small muted">${esc(contract.purchase.apple.note)} ${esc(contract.purchase.web.note)}</p>
        <p class="small muted">Wechsel nach oben gilt sofort, nach unten zum Ende des bezahlten Monats. Bei Kündigung oder Ablauf bleiben deine Notizen erhalten und lesbar; nur Bearbeiten und die Bezahlfunktionen werden gesperrt.</p></div>
    </div></div>`;
  if (state.hosted) state.entitlements = me;
}
