// Frühere Semester: Anbindung an Seite, Dialog und Abgleich (Texte und HTML-Teile: older-semesters.js).
// Geladen wird nicht hier, sondern vom Abgleich der Hochschule; die Routen stehen in app/older_semesters_api.py.
import { $, $$, api, toast, modal, esc, icon, state } from "./core.js?v=47";
import { questionText, shouldAsk, courseCount, semestersHtml, courseHeaderHtml, NOTE_QUEUED } from "./older-semesters.js?v=4";

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
 * wurde und es Kurse frueherer Semester gibt. Schon beim Zeigen gilt die Vorgabe "Nur WLAN" (05.11.2026: fruehere
 * Semester kommen im Hintergrund, app/sync_order.py) als Wahl, die Frage kommt also nie wieder; "Nur aktuelles Semester"
 * stellt auf Aus.
 */
export async function askOlderSemesters() {
  if (asking) return;
  asking = true;
  try {
    const bg = await api("/bg").catch(() => null);
    if (bg?.running) return;
    const o = await api("/older-semesters").catch(() => null);
    if (!shouldAsk(o)) return;
    await api("/older-semesters/mode", { method: "POST", body: { mode: "wifi" } });   // als gefragt merken, bevor die Frage erscheint
    const m = modal(`<h3>${icon("folder", 18)} Auch frühere Semester laden?</h3><p>${esc(questionText(o.current, courseCount(o)))}</p>
      <div class="modal-foot"><button class="btn" id="olderOff">Nur aktuelles Semester</button><button class="btn primary" data-close>Frühere Semester auch laden</button></div>`);
    $("#olderOff", m).onclick = async () => {
      m.remove();
      try {
        await api("/older-semesters/mode", { method: "POST", body: { mode: "off" } });
        if (location.hash.startsWith("#/files") || location.hash.startsWith("#/modules")) state.route();
      } catch (e) { toast(`Speichern fehlgeschlagen: ${e.message}`, 4000); }
    };
  } catch { /* die Frage ist eine Zugabe: kein Fehler in der Oberflaeche */ } finally { asking = false; }
}

/** "Ältere Semester laden" in Einstellungen → Module: Wahl aendern; nicht "Aus" startet das Laden im Hintergrund gleich */
export function bindSetting(root) {
  const sel = $("#sOlderMode", root);
  if (!sel) return;
  let was = sel.value;
  sel.addEventListener("change", async () => {
    const mode = sel.value;
    try {
      const r = await api("/older-semesters/mode", { method: "POST", body: { mode } });
      was = mode;
      toast(r.started ? "Gespeichert · frühere Semester werden im Hintergrund geladen" : "Gespeichert");
    } catch (e) { sel.value = was; toast(`Speichern fehlgeschlagen: ${e.message}`, 4000); }
  });
}
