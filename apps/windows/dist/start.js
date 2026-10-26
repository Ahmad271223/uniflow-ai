// Startseite des Fensters. Mit mitgeliefertem Backend setzt das Fenster (Rust) die Meldung und wechselt selbst zur
// Oberflaeche, sobald das Backend hoert; diese Seite wartet nur. Ohne Backend (Entwicklung) meldet Rust den
// Entwicklungsmodus, dann verbindet sich die Seite mit dem Server aus serve.py.
(function () {
  var DEV_SERVER = "http://127.0.0.1:8765/";
  var msg = document.getElementById("msg");
  var help = document.getElementById("help");
  var retry = document.getElementById("retry");

  function devConnect() {
    msg.textContent = "Verbinde mit dem UniFlow-Server auf diesem PC …";
    fetch(DEV_SERVER + "api/account/info", { cache: "no-store" })
      .then(function () { location.replace(DEV_SERVER); })
      .catch(function () {
        msg.textContent = "Keine Verbindung zu " + DEV_SERVER;
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
