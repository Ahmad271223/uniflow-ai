// Startseite des Fensters. Mit mitgeliefertem Backend setzt das Fenster (Rust) die Meldung und wechselt selbst zur
// Oberflaeche, sobald das Backend hoert; diese Seite wartet nur. Ohne Backend (Entwicklung) meldet Rust den
// Entwicklungsmodus, dann verbindet sich die Seite mit dem Server aus serve.py - aber nur, wenn dort wirklich
// UniFlow antwortet (Status 200 und JSON mit "mode" von /api/account/info), nicht bei irgendeiner HTTP-Antwort.
(function () {
  var DEV_SERVER = "http://127.0.0.1:8765/";
  var msg = document.getElementById("msg");
  var help = document.getElementById("help");
  var retry = document.getElementById("retry");

  function devConnect() {
    msg.textContent = "Verbinde mit dem UniFlow-Server auf diesem PC …";
    fetch(DEV_SERVER + "api/account/info", { cache: "no-store" })
      .then(function (r) {
        if (r.status !== 200) { throw new Error("Status " + r.status); }
        return r.json();
      })
      .then(function (info) {
        if (!info || typeof info.mode !== "string") { throw new Error("keine UniFlow-Antwort"); }
        location.replace(DEV_SERVER);
      })
      .catch(function (e) {
        msg.textContent = "Keine Verbindung zu " + DEV_SERVER + " (" + (e && e.message ? e.message : e) + ")";
        help.hidden = false;
        retry.hidden = false;
      });
  }
  retry.addEventListener("click", devConnect);

  // Rust aendert #msg; "Entwicklungsmodus" bedeutet: kein Backend im Paket
  var seen = false;
  var obs = new MutationObserver(function () {
    if (!seen && msg.textContent.indexOf("Entwicklungsmodus") === 0) { seen = true; devConnect(); }
  });
  obs.observe(msg, { childList: true, characterData: true, subtree: true });
})();
