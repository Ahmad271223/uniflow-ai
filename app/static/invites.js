// Seite "Freunde einladen" (#/einladungen) fuer Web und Windows. Regeln und Texte: invites-logic.js; QR-Code ohne
// fremden Dienst: qr.js. Teilen ueber das Teilen-Menue des Systems (Web Share), sonst Kopieren in die Zwischenablage.
import { $, $$, api, esc, icon, toast, modal } from "./core.js?v=47";
import { toSvg } from "./qr.js?v=1";
import * as L from "./invites-logic.js?v=1";

async function copy(text) {
  try { await navigator.clipboard.writeText(text); toast("Kopiert"); }
  catch { prompt("Zum Kopieren markieren:", text); }
}

async function share(url) {
  if (navigator.share) {
    try { await navigator.share({ title: "StudiNow", text: L.shareText(url), url }); return; }
    catch (e) { if (e?.name === "AbortError") return; }
  }
  copy(L.shareText(url));
}

function qrDialog(c) {
  let which = "link";
  const m = modal(`<div class="card-head"><h3>${icon("share", 18)} QR-Code</h3><button class="btn ghost icon" data-close aria-label="Schließen">${icon("x", 16)}</button></div>
    <div class="seg" role="tablist" aria-label="Art des Codes"><button class="active" data-w="link">Link</button><button data-w="app">App-Code</button></div>
    <div class="inv-qr" style="width:min(280px,100%);margin:1rem auto"></div>
    <p class="small muted inv-qr-t" style="text-align:center;word-break:break-all"></p>
    <div class="modal-foot"><a class="btn" data-dl download="studinow-einladung.svg">${icon("download", 14)} Als Bild speichern</a><button class="btn primary" data-close>Fertig</button></div>`);
  const draw = () => {
    const text = which === "app" ? L.appCode(c.code) : c.url;
    $(".inv-qr", m).innerHTML = toSvg(text, { label: which === "app" ? "QR-Code mit dem App-Code der Einladung" : "QR-Code mit dem Einladungslink" });
    $(".inv-qr svg", m).style.width = "100%"; $(".inv-qr svg", m).style.height = "auto";
    $(".inv-qr-t", m).textContent = which === "app" ? `${text} – zum Scannen mit der iPad-App` : text;
    const a = $("[data-dl]", m); try { URL.revokeObjectURL(a.href); } catch {}
    a.href = URL.createObjectURL(new Blob([toSvg(text)], { type: "image/svg+xml" }));
    $$("[data-w]", m).forEach(b => b.classList.toggle("active", b.dataset.w === which));
  };
  $$("[data-w]", m).forEach(b => b.onclick = () => { which = b.dataset.w; draw(); });
  draw();
}

export async function viewInvites(_, __, view) {
  let ov = null, err = null;
  try { ov = await api("/invites"); } catch (e) { err = L.errorState(e); }
  const head = `<div class="page-head"><div><h1>Freunde einladen</h1><div class="sub">Teile StudiNow mit Kommilitoninnen und Kommilitonen – ohne Zwang, ohne Erinnerungen.</div></div></div>`;
  if (!ov) {
    view.innerHTML = `<div class="content" style="max-width:820px">${head}<div class="card"><p>${icon(err.noAccount ? "user" : "alert", 16)} ${esc(err.text)}</p>
      ${err.noAccount ? `<a class="btn" href="#/settings?tab=account">Zum Konto</a>` : `<button class="btn" id="invRetry">${icon("refresh", 14)} Erneut versuchen</button>`}</div></div>`;
    $("#invRetry", view)?.addEventListener("click", () => viewInvites(_, __, view));
    return;
  }
  const codes = L.sortedCodes(ov.codes);
  view.innerHTML = `<div class="content" style="max-width:820px">${head}
    <section class="card"><div class="card-head"><h2>${icon("users", 18)} Angekommen</h2><span class="badge ${ov.arrived ? "ok" : "neutral"}">${Number(ov.arrived) || 0}</span></div>
      <p style="margin:.2rem 0">${esc(L.arrivedLine(ov.arrived))}</p>
      <p class="muted small" style="margin:.3rem 0 0">Es zählt, wer StudiNow über deinen Link neu beginnt und sich anmeldet. Die eingeladene Person zahlt nichts und bekommt die normale 7-Tage-Probe.</p></section>
    <section class="card"><div class="card-head"><h2>${icon("share", 18)} Deine Einladungslinks</h2>
      <button class="btn primary sm" id="invNew"${ov.can_create ? "" : " disabled"}>${icon("plus", 14)} Neuer Einladungslink</button></div>
      <p class="muted small" style="margin:0 0 .6rem">${esc(L.createHint(ov))}</p>
      ${codes.length ? `<div class="list">${codes.map(c => `<div class="item inv-link${c.expired ? " muted" : ""}" style="flex-wrap:wrap"><div class="main" style="flex:1 1 16rem;min-width:0"><div class="title" style="white-space:normal;word-break:break-all">${esc(c.url)}</div><div class="sub">${esc(L.linkStatus(c))}</div></div>
        ${c.expired ? "" : `<div class="row" style="gap:.3rem;flex-wrap:wrap"><button class="btn sm" data-share="${esc(c.code)}">${icon("share", 13)} Teilen</button><button class="btn ghost sm" data-copy="${esc(c.code)}">${icon("copy", 13)} Kopieren</button><button class="btn ghost sm" data-qr="${esc(c.code)}">QR-Code</button></div>`}</div>`).join("")}</div>`
        : `<p class="muted">Noch kein Link angelegt.</p>`}</section>
    ${L.WEB_REWARDS ? "" : `<section class="card flat"><p class="small muted" style="margin:0">${icon("info", 14)} ${esc(L.REWARDS_NOTE)}</p></section>`}</div>`;
  const byCode = k => codes.find(c => c.code === k);
  $$("[data-share]", view).forEach(b => b.onclick = () => share(byCode(b.dataset.share).url));
  $$("[data-copy]", view).forEach(b => b.onclick = () => copy(byCode(b.dataset.copy).url));
  $$("[data-qr]", view).forEach(b => b.onclick = () => qrDialog(byCode(b.dataset.qr)));
  $("#invNew", view).onclick = async e => {
    e.target.disabled = true;
    try { const r = await api("/invites", { method: "POST" }); toast("Neuer Einladungslink angelegt"); await viewInvites(_, __, view); if (r.invite) qrDialog(r.invite); }
    catch (x) { toast(x.message, 5000); e.target.disabled = false; }
  };
}
