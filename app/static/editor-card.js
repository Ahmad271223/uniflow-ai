// "Als Karteikarte" aus markiertem PDF-Text im Editor (wie auf dem iPad, 04.11.2026): der markierte Text wird die Vorderseite
// einer neuen Karte, die Rueckseite schreibt man selbst; die Karte gehoert zum Dokument (und damit zu dessen Modul und
// Stapel, sonst waehlt man einen Stapel). Gespeichert wird mit POST /api/flashcards (ab Plus). Der Teil bis
// `openCardDialog` ist reine Logik (tests/js/editor-card.test.mjs).

export const FRONT_MAX = 600;

/** Vorderseite aus dem markierten Text: Zeilenumbrueche aus der PDF zu Leerzeichen, Silbentrennung am Zeilenende
 *  ("Rekur-\nsion") zusammenfuehren, gekuerzt */
export function frontOf(text) {
  const t = String(text || "").replace(/(\p{L})-\s*\n\s*(\p{Ll})/gu, "$1$2").replace(/\s*\n\s*/g, " ").replace(/\s{2,}/g, " ").trim();
  return t.length > FRONT_MAX ? t.slice(0, FRONT_MAX - 1).trimEnd() + "…" : t;
}

/** Meldung oder null */
export function validate(d) {
  if (!String(d?.question ?? "").trim() || !String(d?.answer ?? "").trim()) return "Frage und Antwort sind nötig.";
  return null;
}

/** Rumpf fuer POST /api/flashcards: Karte mit Dokument, optional in einen vorhandenen Stapel */
export function cardBody(fileId, d) {
  const body = { file_id: fileId || null, cards: [{ question: String(d.question).trim(), answer: String(d.answer).trim() }] };
  const stack = Number(d.stack);
  if (Number.isInteger(stack) && stack > 0) body.stack_id = stack;
  return body;
}

/** Auswahl "Stapel": zuerst der automatische (Stapel des Dokuments), dann die vorhandenen mit Modul */
export function stackOptions(stacks) {
  return [{ id: "", name: "Stapel dieses Dokuments (automatisch)" },
    ...(Array.isArray(stacks) ? stacks : []).map(s => ({ id: String(s.id), name: s.subject ? `${s.name} · ${s.subject}` : s.name }))];
}

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/** Blatt "Karte anlegen" mit dem markierten Text als Vorderseite. opts: { text, fileId, fileName, onStatus } */
export async function openCardDialog({ text, fileId, fileName = "", onStatus = () => {} }) {
  const host = document.getElementById("overlay") || document.body;
  const m = document.createElement("div"); m.className = "modal"; m.setAttribute("role", "dialog"); m.setAttribute("aria-modal", "true"); m.setAttribute("aria-labelledby", "edCardT");
  m.innerHTML = `<div class="modal-box"><h3 id="edCardT">Karte anlegen</h3>
    <form id="edCardForm"><label class="field"><span>Frage (Vorderseite)</span><textarea name="question" rows="3"></textarea></label>
    <label class="field"><span>Antwort (Rückseite)</span><textarea name="answer" rows="3" placeholder="Was soll auf der Rückseite stehen?"></textarea></label>
    <label class="field"><span>Stapel</span><select name="stack">${stackOptions([]).map(o => `<option value="${esc(o.id)}">${esc(o.name)}</option>`).join("")}</select></label>
    <p class="muted small" style="margin:.2rem 0">${fileName ? `Aus „${esc(fileName)}“. ` : ""}Der Lernstand startet im Fach 1, heute fällig.</p>
    <div class="ed-err small" id="edCardErr" role="alert" hidden></div>
    <div class="modal-foot"><button class="btn" type="button" data-close>Abbrechen</button><button class="btn primary" type="submit">Karte speichern</button></div></form></div>`;
  m.addEventListener("click", e => { if (e.target === m) m.remove(); });
  host.append(m);
  const form = m.querySelector("#edCardForm"), err = m.querySelector("#edCardErr");
  m.querySelector("[data-close]").onclick = () => m.remove();
  form.question.value = frontOf(text);
  form.answer.focus();
  try {                                                      // Stapel nachladen; ohne Antwort bleibt "automatisch"
    const r = await fetch("/api/flashcard-stacks"); if (r.ok && m.isConnected) {
      const sel = form.stack; sel.innerHTML = stackOptions(await r.json()).map(o => `<option value="${esc(o.id)}">${esc(o.name)}</option>`).join("");
    }
  } catch { /* Stapel sind nur Komfort */ }
  form.onsubmit = async e => {
    e.preventDefault(); err.hidden = true;
    const d = { question: form.question.value, answer: form.answer.value, stack: form.stack.value };
    const bad = validate(d); if (bad) { err.textContent = bad; err.hidden = false; return; }
    const btn = form.querySelector("[type=submit]"); btn.disabled = true;
    try {
      const r = await fetch("/api/flashcards", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(cardBody(fileId, d)) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(typeof j.detail === "string" ? j.detail : j.detail?.detail || r.statusText);
      m.remove(); onStatus("Karteikarte gespeichert");
    } catch (x) { err.textContent = `Nicht gespeichert: ${x.message}`; err.hidden = false; btn.disabled = false; }
  };
}
