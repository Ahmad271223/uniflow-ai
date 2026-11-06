// Seite #/bescheinigungen in Web und Windows (06.11.2026, docs/BESCHEINIGUNGEN-2026-11-06.md), wie CertificatesPage.swift:
// alle Dokumente, die QIS, Campusmanagement bzw. PLuS anbieten, mit gespeicherter Kopie und Datum. "Liste aktualisieren"
// (POST /api/certificates/refresh) liest nur Links/Knoepfe; "Herunterladen"/"Neu laden" (POST .../{id}/download) laedt
// genau dieses Dokument im Hintergrund (Playwright mit der Anmeldung am PC). Im Dienst nicht verfuegbar (409).
import { $$, api, icon, toast } from "./core.js?v=46";
import * as L from "./certificates-logic.js?v=1";

export async function viewCertificates(parts, params, view) {
  const d = await api("/certificates");
  view.innerHTML = L.pageHtml(d, icon);
  const run = async (path, body, msg) => {
    try { await api(path, { method: "POST", body }); toast(msg); window.pollBg?.(); }
    catch (e) { toast(e.message, 5000); }
  };
  view.querySelector("#certRefresh")?.addEventListener("click", () => run("/certificates/refresh", {}, "Bescheinigungen werden gelesen …"));
  $$("[data-dl]", view).forEach(b => b.addEventListener("click", () => {
    const sem = view.querySelector(`[data-sem="${CSS.escape(b.dataset.dl)}"]`)?.value;
    run(`/certificates/${b.dataset.dl}/download`, sem ? { semester: sem } : {}, "Bescheinigung wird geladen …");
  }));
}
