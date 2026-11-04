// Frühere Semester: Anbindung an Seite, Dialog und Abgleich (Texte und HTML-Teile: older-semesters.js).
// Geladen wird nicht hier, sondern vom Abgleich der Hochschule; die Routen stehen in app/older_semesters_api.py.
import { $, $$, api, toast, modal, esc, icon, state } from "./core.js?v=41";
import { questionText, shouldAsk, courseCount, semestersHtml, courseHeaderHtml, NOTE_QUEUED } from "./older-semesters.js?v=1";

/** Abgleich fuer die vorgemerkten Kurse anzeigen: Fortschritt oben, danach laedt die Seite neu (window.pollBg in app.js) */
function watchLoading(note) {
  toast(note || NOTE_QUEUED, 4000);
  try { window.pollBg?.(); } catch {}
}

/** "Dateien laden": Kurse vormerken, dann den Abgleich nur fuer sie starten */
export async function loadCourses(ids) {
  try {
    const r = await api("/older-semesters/request", { method: "POST", body: { course_ids: ids } });
    watchLoading(r.note);
  } catch (e) { toast(`Dateien laden fehlgeschlagen: ${e.message}`, 4000); }
}

/** Bereich "Frühere Semester" in die Seite haengen und bedienen; reload() zeichnet die Bibliothek neu */
export function bindSemesters(host, overview, reload) {
  const open = new Set(), busy = new Set();
  const draw = () => { host.innerHTML = semestersHtml(overview, open, busy); wire(); };
  const run = async (ids, key) => { busy.add(key); draw(); await loadCourses(ids); busy.delete(key); await reload(); };
  const wire = () => {
    $$("[data-older-toggle]", host).forEach(b => b.onclick = () => { const l = overview.semesters[+b.dataset.olderToggle].label; open.has(l) ? open.delete(l) : open.add(l); draw(); });
    $$("[data-older-all]", host).forEach(b => b.onclick = () => { const s = overview.semesters[+b.dataset.olderAll]; run((s.courses || []).filter(c => !c.loaded || c.downloaded < c.files).map(c => c.id), s.label); });
    $$("[data-older-course]", host).forEach(b => b.onclick = () => run([b.dataset.olderCourse], b.dataset.olderCourse));
  };
  draw();
}

/** Kopf im Kursordner eines frueheren Semesters */
export function bindCourseHeader(host, courseId, files, reload) {
  let loading = false, showAll = false;
  const draw = () => {
    host.innerHTML = courseHeaderHtml(files, { loading, showAll });
    $("[data-older-load]", host)?.addEventListener("click", async () => { loading = true; draw(); await loadCourses([courseId]); loading = false; await reload(); });
    $("[data-older-more]", host)?.addEventListener("click", () => { showAll = !showAll; draw(); });
  };
  draw();
}

let asking = false;
/**
 * Die einmalige Frage "Auch frühere Semester laden?": nach einem Abgleich (und beim Oeffnen), wenn noch nie entschieden
 * wurde und es Kurse frueherer Semester gibt. Schon beim Zeigen gilt "Nur aktuelles Semester" als Wahl, die Frage kommt
 * also nie wieder; "Frühere Semester auch laden" aendert sie.
 */
export async function askOlderSemesters() {
  if (asking) return;
  asking = true;
  try {
    const bg = await api("/bg").catch(() => null);
    if (bg?.running) return;
    const o = await api("/older-semesters").catch(() => null);
    if (!shouldAsk(o)) return;
    await api("/older-semesters/choice", { method: "POST", body: { choice: "current" } });   // als gefragt merken, bevor die Frage erscheint
    const m = modal(`<h3>${icon("folder", 18)} Auch frühere Semester laden?</h3><p>${esc(questionText(o.current, courseCount(o)))}</p>
      <div class="modal-foot"><button class="btn primary" data-close>Nur aktuelles Semester</button><button class="btn" id="olderAll">Frühere Semester auch laden</button></div>`);
    $("#olderAll", m).onclick = async () => {
      m.remove();
      try {
        await api("/older-semesters/choice", { method: "POST", body: { choice: "all" } });
        watchLoading((await api("/older-semesters/load", { method: "POST" })).note);
        if (location.hash.startsWith("#/files")) state.route();
      } catch (e) { toast(`Frühere Semester laden: ${e.message}`, 4000); }
    };
  } catch { /* die Frage ist eine Zugabe: kein Fehler in der Oberflaeche */ } finally { asking = false; }
}

/** Kontrollkaestchen in Einstellungen → Module: Wahl aendern; eingeschaltet laedt der Abgleich die Dateien gleich */
export function bindSetting(root) {
  const box = $("#sOlderAll", root);
  if (!box) return;
  box.addEventListener("change", async () => {
    const on = box.checked;
    try {
      await api("/older-semesters/choice", { method: "POST", body: { choice: on ? "all" : "current" } });
      toast("Gespeichert");
      if (on) watchLoading((await api("/older-semesters/load", { method: "POST" })).note);
    } catch (e) { box.checked = !on; toast(`Speichern fehlgeschlagen: ${e.message}`, 4000); }
  });
}
