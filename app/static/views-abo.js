// StudiNow – Abo-Übersicht: drei Tarife (Free, Plus, Pro AI; Entscheidung 04.11.2026), eigener Stand, Kontingente
// (Server: /api/billing/plans, /api/entitlements). Die Karten kommen aus contract.order; Pro Connect gibt es nicht mehr.
// Es wird nur als enthalten gezeigt, was technisch freigeschaltet ist (status "available"); alles andere steht als
// "kommt bald" bzw. "in Vorbereitung" daneben. Abschließen: Apple-App (App Store) oder, wenn Stripe eingerichtet ist, im Web.
// Jedes neue Konto hat 7 Tage Probe (plans.TRIAL: alles wie Pro AI, 25 Credits); danach einmal die Aufforderung, einen Tarif zu wählen (planChoicePrompt).
import { $, $$, api, esc, icon, modal, state, toast } from "./core.js?v=43";

const euro = c => c === 0 ? "0 €" : `${(c / 100).toFixed(2).replace(".", ",")} €`;
const QUOTA_TXT = (q, key, labels) => {
  const v = q[key];
  if (v === null) return `${labels[key]}: unbegrenzt (Fair Use)`;
  if (!v) return null;
  return `${labels[key]}: ${v} pro Monat`;
};
const POSITION = {
  free: "Organisieren, lesen, Stundenplan – kostenlos.",
  // Plus gilt je Geraet (Entscheidung 04.11.2026): Notizen-Abgleich zwischen iPad, PC und Web erst mit Pro AI
  plus: "Schreiben mit Apple Pencil, Textmarker und Textfeldern (je Gerät), eigene Karteikarten und Wochentests.",
  pro_ai: "Komfortabel: StudiNow-KI inklusive, kein eigenes ChatGPT-Konto nötig, Notizen auf allen Geräten.",
};

// Funktionen der StudiNow-KI: als enthalten nur, wenn der Dienst die KI eingerichtet hat (studora_ai_configured)
const AI_FEATURES = new Set(["can_generate_studora_ai_tests", "can_use_ai_explanations", "can_use_ai_generated_questions", "can_use_ai_summaries", "can_use_ai_recommendations", "can_use_prepared_week_sets"]);

function featureRows(contract, key) {
  const order = contract.order, idx = order.indexOf(key);
  const own = Object.entries(contract.entitlements).filter(([, e]) => e.from === key);
  const rows = [];
  if (idx > 0) rows.push(`<li class="off">${icon("check", 13)} Alles aus ${esc(contract.plans[order[idx - 1]].name)}</li>`);
  for (const [name, e] of own) {
    if (e.status === "available" && AI_FEATURES.has(name) && !contract.studora_ai_configured) rows.push(`<li class="off">${icon("clock", 13)} ${esc(e.label)} <span class="badge neutral">in Vorbereitung</span></li>`);
    else if (e.status === "available") rows.push(`<li>${icon("check", 13)} ${esc(e.label)}</li>`);
    else if (e.status === "coming_soon") rows.push(`<li class="off">${icon("clock", 13)} ${esc(e.label)} <span class="badge neutral">kommt bald</span></li>`);
    else if (name === "chatgpt_connection_premium") rows.push(`<li class="off">${icon("clock", 13)} Eigenes ChatGPT-Konto verbinden <span class="badge neutral">in Vorbereitung</span></li>`);
  }
  return rows.join("");
}

function quotaBar(label, q) {
  if (!q) return "";
  if (q.unlimited || q.limit === null) return `<div class="abo-q"><span class="abo-q-l">${esc(label)}</span><b>${q.used} genutzt</b><span class="abo-q-n">unbegrenzt (Fair Use)</span></div>`;
  if (!q.limit) return "";
  const pct = Math.min(100, Math.round(100 * q.used / q.limit));
  return `<div class="abo-q"><span class="abo-q-l">${esc(label)}</span><b>${q.used} von ${q.limit}</b><span class="abo-q-n">in diesem Monat</span><div class="abo-bar${pct >= 100 ? " full" : ""}"><i style="width:${pct}%"></i></div></div>`;
}

export async function viewAbo(_, params, view) {
  const [contract, me, gptLocal] = await Promise.all([api("/billing/plans"), api("/entitlements"), api("/integrations/chatgpt").catch(() => null)]);
  const labels = contract.quotas.labels, current = me.plan;
  const local = me.mode === "local";
  const gpt = contract.integrations.chatgpt;
  const web = contract.purchase.web || {}, viaStripe = me.source === "stripe";
  const tr = me.trial || {};
  const trial = local || !tr.granted ? "" : tr.active
    ? `<div class="abo-note">${icon("sparkles", 18)}<div><b>Probe: noch ${tr.days_left} Tag${tr.days_left === 1 ? "" : "e"} alles frei</b><p>Probe: alles wie ${esc(contract.plans[tr.plan]?.name || "StudiNow Pro AI")}, mit ${contract.trial?.credits ?? 25} Credits für die StudiNow-KI, bis ${new Date(tr.ends_at).toLocaleDateString("de-DE")}. Danach wählst du einen Tarif; ohne Wahl geht es mit Free weiter, deine Notizen, Karten und Tests bleiben.</p></div></div>`
    : me.needs_plan_choice
      ? `<div class="abo-note warn">${icon("alert", 18)}<div><b>Deine Probe ist vorbei</b><p>Wähle unten einen Tarif oder bleib bei Free. Deine Notizen bleiben erhalten und lesbar.</p></div><button class="btn sm" id="aboStayFree">Bei Free bleiben</button></div>`
      : "";
  const afterCheckout = params.checkout === "success"
    ? `<p class="abo-flash ok">${icon("check", 14)} Zahlung abgeschlossen. Dein Tarif erscheint hier, sobald Stripe die Bestätigung geschickt hat (meist sofort).</p>`
    : params.checkout === "cancel" ? `<p class="abo-flash">Abschluss abgebrochen, nichts wurde berechnet.</p>` : "";
  const term = local
    ? `<p class="abo-term">Auf deinem eigenen PC gibt es keine Tarife: alle Funktionen sind frei, die KI läuft über deinen eigenen Claude-Zugang. Tarife gelten für StudiNow-Konten im Dienst und in der Apple-App.</p>`
    : `<p class="abo-term">${me.expires_at ? `${me.will_renew ? "Verlängert sich am" : "Läuft aus am"} <b>${new Date(me.expires_at).toLocaleDateString("de-DE")}</b>` : current === "free" ? "Kostenlos, ohne Laufzeit." : "Ohne Ablaufdatum."}${me.pending_plan ? ` · Ab der nächsten Verlängerung: <b>${esc(contract.plans[me.pending_plan]?.name || me.pending_plan)}</b>` : ""}</p>`;
  const quotas = local ? "" : [quotaBar(labels.ai_tests_new, me.quotas.ai_tests_new), quotaBar(labels.library_tests, me.quotas.library_tests), quotaBar(labels.ai_assist, me.quotas.ai_assist)].join("");
  const cards = contract.order.map(key => {
    const p = contract.plans[key], isCur = key === current;
    const q = p.quotas;
    const facts = [
      p.entitlements.can_annotate_pdf ? `${icon("pen", 13)} PDF-Bearbeitung und Apple Pencil` : `${icon("book", 13)} PDFs lesen, keine Bearbeitung`,
      p.credits ? `${icon("sparkles", 13)} ${p.credits} Credits für die StudiNow-KI pro Monat` : null,
      ...[QUOTA_TXT(q, "ai_tests_new", labels), QUOTA_TXT(q, "library_tests", labels), QUOTA_TXT(q, "ai_assist", labels)]
        .map(t => t && !contract.studora_ai_configured && !t.startsWith(labels.library_tests) ? `${t} (sobald die StudiNow-KI eingerichtet ist)` : t),
    ].filter(Boolean).map(t => `<div>${t}</div>`).join("");
    const action = local ? "" : isCur ? `<span class="badge ok">Dein Tarif</span>${viaStripe ? ` <button class="btn sm" id="aboPortal">Abo verwalten</button>` : ""}`
      : key === "free" ? `<span class="plan-hint">${viaStripe ? "Zurück zu Free: im Kundenportal kündigen (Abo verwalten)" : me.source === "app_store" ? "Zurück zu Free: Abo im App Store kündigen" : "Kostenlos, ohne Laufzeit"}</span>`
      : web.available && (web.plans || []).includes(key) && !viaStripe ? `<button class="btn sm primary" data-buy="${key}">Abschließen</button>`
      : viaStripe ? `<button class="btn sm" data-portal="1">Wechseln (Abo verwalten)</button>`
      : `<button class="btn sm" disabled title="${esc(web.note || "")}">In der Apple-App abschließen</button>`;
    return `<article class="plan${isCur ? " is-current" : ""}${key === "pro_ai" ? " is-top" : ""}">
      <header><h2>${esc(p.name)}</h2></header>
      <div class="plan-price"><b>${euro(p.price_cents)}</b><span> / Monat</span></div>
      ${key === "pro_ai" ? `<div class="plan-tag"><span class="badge info">ohne eigenes ChatGPT</span></div>` : ""}
      ${action ? `<div class="plan-act">${action}</div>` : ""}
      <p class="plan-pos">${esc(POSITION[key] || p.tagline)}</p>
      <div class="plan-facts">${facts}</div>
      <ul class="plan-list">${featureRows(contract, key)}</ul></article>`;
  }).join("");
  view.innerHTML = `<div class="content abo" style="max-width:1180px">
    <div class="page-head"><div><h1>Abo & Tarife</h1><div class="sub">${local ? "Eigener PC" : `Dein Tarif: ${esc(me.plan_name)}`}</div></div></div>
    <section class="abo-now" aria-label="Aktueller Stand">${trial}${afterCheckout}${term}${quotas ? `<div class="abo-quotas">${quotas}</div>` : ""}</section>
    <h2 class="abo-h">Tarif wählen</h2>
    <div class="plans">${cards}</div>
    <div class="abo-more">
      ${local && gptLocal?.available ? `<section class="abo-info"><header><h2>${icon("sparkles", 18)} Eigenes ChatGPT-Konto</h2><span class="badge ${gptLocal.connected ? (gptLocal.sharing && !gptLocal.needs_reauth ? "ok" : "warn") : "neutral"}">${gptLocal.connected ? (gptLocal.needs_reauth ? "neu anmelden" : gptLocal.sharing ? "verbunden" : "ohne Abo-Nutzung") : "nicht verbunden"}</span></header>
        <p>${gptLocal.connected ? `Verbunden als <b>${esc(gptLocal.email || gptLocal.name || "ChatGPT-Konto")}</b>${gptLocal.model ? `, Modell ${esc(gptLocal.model)}` : ""}. ` : "Auf dem eigenen PC kannst du dein ChatGPT-Konto (Plus, Pro oder Go) verbinden; KI-Anfragen laufen dann über dein Abo. "}Einrichten unter <a href="#/settings?tab=advanced">Einstellungen → Erweitert</a>. Das Token bleibt auf diesem Rechner; ohne Tarif, ohne Zahlung an uns.</p></section>`
      : `<section class="abo-info"><header><h2>${icon("sparkles", 18)} Eigenes ChatGPT-Konto</h2><span class="badge ${gpt.status === "enabled" ? "ok" : "neutral"}">${gpt.status === "enabled" ? "verfügbar" : "noch nicht verfügbar"}</span></header>
        <p>${esc(gpt.reason || "")} Sobald OpenAI StudiNow freigibt, kannst du dein eigenes ChatGPT-Abo verbinden. Diese Verbindung verkaufen wir nicht: sie wird nie nur gegen einen StudiNow-Tarif angeboten, solange die Bedingungen von OpenAI das nicht erlauben.</p></section>`}
      <section class="abo-info"><header><h2>${icon("info", 18)} Abschließen, wechseln, kündigen</h2></header>
        <p>${esc(contract.purchase.apple.note)} ${esc(contract.purchase.web.note)}</p>
        <p>Wechsel nach oben gilt sofort, nach unten zum Ende des bezahlten Monats. Bei Kündigung oder Ablauf bleiben deine Notizen erhalten und lesbar; nur Bearbeiten und die Bezahlfunktionen werden gesperrt.</p></section>
    </div></div>`;
  if (state.hosted) state.entitlements = me;
  if (params.checkout === "success" && me.source !== "stripe" && !viewAbo._retried) { viewAbo._retried = true; setTimeout(() => { if (location.hash.startsWith("#/abo")) state.route(); }, 4000); }
  $$("[data-buy]", view).forEach(b => b.onclick = async () => { b.disabled = true; try { const r = await api("/billing/plan-choice", { method: "POST", body: { plan: b.dataset.buy } }); if (r.checkout_url) { location.href = r.checkout_url; return; } toast(r.checkout_error || "Abschluss zurzeit nur in der Apple-App", 5000); } catch (e) { toast(e.message, 5000); } b.disabled = false; });
  const portal = async () => { try { const r = await api("/billing/stripe/portal", { method: "POST", body: {} }); location.href = r.url; } catch (e) { toast(e.message, 5000); } };
  $("#aboPortal", view)?.addEventListener("click", portal);
  $$("[data-portal]", view).forEach(b => b.onclick = portal);
  $("#aboStayFree", view)?.addEventListener("click", async () => { try { await api("/billing/plan-choice", { method: "POST", body: { plan: "free" } }); toast("Du bleibst bei Free – deine Notizen bleiben"); state.route(); } catch (e) { toast(e.message, 5000); } });
}

/// Einmal je Sitzung nach der Probe: Tarif waehlen oder bei Free bleiben (app.js beim Start, wenn needs_plan_choice)
export function planChoicePrompt(me) {
  try { if (sessionStorage.getItem("plan-choice-prompted")) return; sessionStorage.setItem("plan-choice-prompted", "1"); } catch {}
  const m = modal(`<h2 style="margin-top:0">${icon("sparkles", 18)} Deine Probe ist vorbei</h2>
    <p class="small muted">Sieben Tage lang war alles frei wie in StudiNow Pro AI. Wähle jetzt einen Tarif – oder bleib bei Free. Deine Notizen, Karten und Tests bleiben in jedem Fall erhalten und lesbar; bei Free ist nur das Bearbeiten und die KI gesperrt.</p>
    <div class="row wrap" style="gap:.5rem;margin-top:.8rem"><a class="btn primary" href="#/abo" data-close>Tarife ansehen</a><button class="btn" id="pcFree">Bei Free bleiben</button><button class="btn ghost" data-close>Später</button></div>`);
  $("#pcFree", m).onclick = async () => { try { await api("/billing/plan-choice", { method: "POST", body: { plan: "free" } }); toast("Du bleibst bei Free"); if (state.entitlements) state.entitlements.needs_plan_choice = false; } catch (e) { toast(e.message, 5000); } m.remove(); };
}
