import WebKit

/// QIS-Anmeldeseite am iPhone (Befund des Inhabers 11.11.2026: "anmelden QIS nicht lesbar, weil Anweisung so groß"):
/// Die Seite des QIS ist nur fuer Rechner gebaut (kein Viewport, 970 pt breit). iOS zeigt sie verkleinert, lesbar
/// bleibt nur die grosse Begruessung. Am iPhone setzt ein Skript in eigener Inhaltswelt einen Viewport und blendet
/// Kopfbild, Menue und Pfad aus; Begruessung klein, Felder und "Login" in voller Breite. Es aendert nur die Darstellung,
/// liest und fuellt nichts (das Passwort-Autofill von iOS bleibt). Nur auf dem Rechner des QIS, nur ohne eigenen Viewport.
enum QISPhoneFit {
    static let css = """
    #wrapper,.divcontent,.content_max_portal_qis,.content_max_portal_qis>div,.portalcontent,.portalcontent1,.portalcontent2,\
    .welcome_text,.containerLogin,form.formular,.clearer{width:auto!important;min-width:0!important;max-width:100%!important;\
    float:none!important;margin-left:0!important;margin-right:0!important;box-sizing:border-box!important;position:static!important}
    .divheader,.divlinks,.breadcrumb,#makronavigation,.unsichtbar,.welcome_text .square{display:none!important}
    .welcome_text .headline{display:block!important;padding:12px 16px 4px!important;background:none!important}
    .welcome_text .headlineText,.welcome_text .headlineText h4{font-size:17px!important;line-height:1.3!important;margin:0!important;\
    padding:0!important;width:auto!important;float:none!important}
    .containerLogin ol{padding:8px 16px!important;margin:0!important;list-style:none!important}
    .containerLogin li{display:block!important;margin:0 0 12px!important;padding:0!important}
    .containerLogin .label{display:block!important;width:auto!important;text-align:left!important;font-size:16px!important;\
    margin:0 0 4px!important;float:none!important}
    .containerLogin .nolabel{display:none!important}
    input.input_login{width:100%!important;font-size:17px!important;padding:10px!important;box-sizing:border-box!important;height:auto!important}
    input.submit{width:100%!important;font-size:17px!important;padding:12px!important;height:auto!important}
    .portalcontent1,.clearer{padding:0 16px!important;font-size:14px!important}
    body{font-size:16px!important;min-width:0!important}
    """

    static var source: String {
        let quoted = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "")
        return """
        (function () {
          if (!/(^|\\.)qis\\.verwaltung\\.uni-hannover\\.de$/.test(location.hostname)) return;
          if (document.querySelector('meta[name=viewport]')) return;
          var m = document.createElement('meta'); m.name = 'viewport'; m.content = 'width=device-width, initial-scale=1';
          document.head.appendChild(m);
          var s = document.createElement('style'); s.textContent = `\(quoted)`; document.head.appendChild(s);
        })();
        """
    }

    static func install(in config: WKWebViewConfiguration) {
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true, in: .defaultClient))
    }
}
