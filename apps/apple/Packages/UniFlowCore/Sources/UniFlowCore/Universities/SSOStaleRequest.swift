import Foundation

/// "Veraltete Anfrage" des Shibboleth-IdP (WebSSO der LUH, 26.11.2026 am echten Login gesehen): stand die Anmeldeseite
/// zu lange offen (etwa eine halbe Stunde), nimmt der IdP das abgeschickte Formular nicht mehr an und zeigt unter
/// `/idp/profile/…` eine Fehlerseite (HTTP 500, Ueberschrift "WebSSO Login Service - Veraltete Anfrage", englisch
/// "Stale Request", kein Seitentitel). In der App war das eine Sackgasse: weiter ging es nur mit "Später anmelden" oder
/// einem Neustart. Die Anmeldeansicht erkennt die Seite hiermit und laedt die Anmeldung neu (`StudIPWebView`).
public enum SSOStaleRequest {
    private static let headingRE = HText.regex(#"<h1[^>]*>([\s\S]*?)</h1>"#, [.caseInsensitive])
    private static let tagRE = HText.regex(#"<[^>]+>"#)
    /// Woerter der Ueberschrift (deutsch und englisch, wie die Nachrichten des Shibboleth-IdP)
    static let markers = ["veraltete anfrage", "stale request"]

    /// Nur Seiten eines Shibboleth-IdP kommen in Frage (Pfad `/idp/`): eine Seite einer anderen Adresse mit denselben
    /// Woertern ist nie gemeint
    public static func mayBeStale(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host != nil else { return false }
        return url.path.lowercased().hasPrefix("/idp/")
    }

    /// Die Seite ist die Fehlerseite "Veraltete Anfrage" bzw. "Stale Request" (Adresse wie `mayBeStale`, eine
    /// Ueberschrift `h1` nennt es)
    public static func isStale(url: URL?, html: String) -> Bool {
        guard mayBeStale(url) else { return false }
        return HText.allMatches(headingRE, html).contains { heading in
            let text = HText.collapse(HText.replace(tagRE, in: heading, with: " ")).lowercased()
            return markers.contains { text.contains($0) }
        }
    }

    /// Hinweis ueber der neu geladenen Anmeldeseite
    public static let notice = "Die Anmeldeseite war zu lange offen und ist abgelaufen. StudiNow hat sie neu geladen – bitte melde dich noch einmal an."

    /// Hoechstens so oft hintereinander neu laden (`window`), danach bleibt die Seite stehen (kein Kreislauf, falls der
    /// IdP die Anmeldung dauerhaft ablehnt)
    public static let maxReloads = 2
    public static let window: TimeInterval = 120

    /// Darf jetzt neu geladen werden? `past`: Zeitpunkte der letzten Neuladungen (aelteste zuerst)
    public static func mayReload(past: [Date], now: Date = Date()) -> Bool {
        past.filter { now.timeIntervalSince($0) < window }.count < maxReloads
    }
}
