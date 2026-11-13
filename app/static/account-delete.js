// "Konto löschen" im Web (Dienst) und in der Windows-App (13.11.2026), wie DeleteAccountDialog auf dem iPad:
// das StudiNow-Konto beim Dienst sofort sperren und abmelden, nach 30 Tagen endgueltig. Web: POST /api/account/delete,
// Windows: POST /api/app-account/delete (leitet an den Dienst weiter, meldet den PC danach ab; die Daten auf dem PC
// bleiben). Ein falsches Passwort meldet der Dienst mit 401; das darf hier nicht als "abgemeldet" gelten, darum
// fetch statt core.api.
import { $, esc, icon, modal, toast } from "./core.js?v=47";

export const TEXTS = {
  service: "Dein StudiNow-Konto wird beim StudiNow-Dienst gelöscht – auf allen Geräten, auf dem iPad, unter Windows und im Web: sofort gesperrt und abgemeldet, nach 30 Tagen endgültig mit allem, was dorthin abgeglichen wurde. Was du in der Community geteilt hast, ist sofort nicht mehr sichtbar.",
  irreversible: "Das lässt sich nicht rückgängig machen.",
  subscription: "Ein Abo mit Karte (im Web oder unter Windows abgeschlossen) beenden wir dabei sofort: es wird nichts mehr abgebucht, schon bezahlte Zeit wird nicht anteilig erstattet. Ein Abo aus der iPad-App kann nur Apple beenden – kündige es selbst in den Abo-Einstellungen deines Apple-Kontos.",
  apple: "Hast du dich mit Apple angemeldet, widerruft StudiNow die Verknüpfung „Mit Apple anmelden“ ebenfalls.",
  windowsLocal: "Die Daten auf diesem PC (Dateien, Notizen, Lernplan) bleiben auf der Festplatte. Ohne Konto öffnet StudiNow sie nicht mehr; exportiere sie vorher, wenn du sie behalten willst. Entfernen kannst du sie, indem du StudiNow deinstallierst.",
  password: "Passwort deines StudiNow-Kontos (leer lassen, wenn du dich nur mit Apple oder Google anmeldest)",
  wrongPassword: "Zum Löschen bitte das richtige Passwort deines StudiNow-Kontos angeben.",
  done: "Dein Konto ist gelöscht. Du bist abgemeldet; nach 30 Tagen sind die Daten beim Dienst endgültig weg.",
};

/** Antwort des Dienstes in einen verstaendlichen Satz; credentials_invalid -> Passwort-Hinweis */
export function problemText(status, data) {
  const code = data?.code || data?.detail?.code;
  if (code === "credentials_invalid") return TEXTS.wrongPassword;
  const d = typeof data?.detail === "string" ? data.detail : data?.detail?.detail;
  if (status === 0) return "Der StudiNow-Dienst ist gerade nicht erreichbar. Nichts wurde gelöscht – versuch es später noch einmal.";
  return d || `Löschen hat nicht geklappt (Fehler ${status}). Nichts wurde gelöscht.`;
}

/**
 * Rueckfrage mit Erklaerung, Passwort und Bestaetigung. `windows`: Windows-App (Konto-Pflicht), sonst Web im Dienst.
 * `onDeleted` wird nach dem Loeschen aufgerufen (Web: zur Anmeldung, Windows: neu laden -> Anmeldebildschirm).
 */
export function deleteAccountDialog({ windows = false, email = "", exportHref = "", onDeleted } = {}) {
  const m = modal(`<h3>${icon("trash", 18)} Konto löschen?</h3>
    ${email ? `<p style="margin:.2rem 0 .6rem">Konto: <b>${esc(email)}</b></p>` : ""}
    <p class="small">${esc(TEXTS.service)} <b style="color:var(--bad-text)">${esc(TEXTS.irreversible)}</b></p>
    <p class="small">${esc(TEXTS.subscription)}</p>
    <p class="small muted">${esc(TEXTS.apple)}</p>
    ${windows ? `<p class="small">${esc(TEXTS.windowsLocal)}${exportHref ? ` <a href="${esc(exportHref)}" download>Daten dieses PCs exportieren</a>` : ""}</p>` : ""}
    <label class="field">${esc(TEXTS.password)}<input class="input" type="password" id="adPw" autocomplete="current-password"></label>
    <label class="field row"><input type="checkbox" id="adSure"> Ich möchte mein StudiNow-Konto endgültig löschen</label>
    <p class="small" id="adMsg" role="alert" style="color:var(--bad-text)" hidden></p>
    <div class="modal-foot"><button class="btn" data-close>Abbrechen</button><button class="btn danger" id="adOk" disabled>${icon("trash", 15)} Konto löschen</button></div>`);
  const ok = $("#adOk", m), msg = $("#adMsg", m);
  $("#adSure", m).onchange = e => { ok.disabled = !e.target.checked; };
  ok.onclick = async () => {
    ok.disabled = true; msg.hidden = true;
    const pw = $("#adPw", m).value;
    let status = 0, data = null;
    try {
      const r = await fetch(windows ? "/api/app-account/delete" : "/api/account/delete", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(pw ? { password: pw } : {}) });
      status = r.status;
      data = await r.json().catch(() => null);
    } catch { status = 0; }
    if (status >= 200 && status < 300 && data?.deleted) {
      m.remove();
      const d = modal(`<h3>${icon("check", 18)} Konto gelöscht</h3><p>${esc(TEXTS.done)}</p><div class="modal-foot"><button class="btn primary" id="adDone">OK</button></div>`);
      $("#adDone", d).onclick = () => { d.remove(); onDeleted?.(); };
      return;
    }
    msg.textContent = problemText(status, data);
    msg.hidden = false;
    if ((data?.code || data?.detail?.code) === "credentials_invalid") $("#adPw", m).focus();
    ok.disabled = !$("#adSure", m).checked;
    if (status === 0) toast(msg.textContent, 5000);
  };
  return m;
}
