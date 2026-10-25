import SwiftUI
import WebKit

/// UEBERGANG: Web-Ansicht des UniFlow-Servers fuer Bereiche, die noch nicht nativ uebertragen sind
/// (Status in WEB-IPAD-PARITAET.md: "Übergang (Web eingebettet)", nicht "implementiert").
/// Laedt <Server>/#/<route> mit der PIN als Cookie, damit dieselben Daten und Funktionen nutzbar sind.
struct UFWebFallback: View {
    let route: UFRoute
    @EnvironmentObject private var session: Session

    var body: some View {
        if let api = session.api, let url = URL(string: api.base.absoluteString.trimmingSuffix("/") + "/" + route.hash) {
            VStack(spacing: 0) {
                HStack(spacing: 6.4) {
                    UFIcon("info", size: 14)
                    Text("Diese Ansicht ist noch nicht nativ übertragen und wird vom UniFlow-Server angezeigt.")
                }
                .font(UF.small).foregroundStyle(UF.info)
                .frame(maxWidth: .infinity).padding(6).background(UF.infoSoft)
                FallbackWebView(url: url, host: api.base.host ?? "", pin: api.pinValue)
            }
        } else {
            UFContent {
                UFCard {
                    UFEmpty(icon: "alert", text: "Diese Ansicht ist noch nicht nativ übertragen. Sie braucht vorerst die Verbindung zum UniFlow-Server.")
                }
            }
        }
    }
}

private struct FallbackWebView: UIViewRepresentable {
    let url: URL
    let host: String
    let pin: String?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()          // getrennt von der Stud.IP-Anmeldung
        let view = WKWebView(frame: .zero, configuration: config)
        if let pin, !pin.isEmpty,
           let cookie = HTTPCookie(properties: [.name: "lernapp_pin", .value: pin, .domain: host, .path: "/"]) {
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { view.load(URLRequest(url: url)) }
        } else {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url?.fragment != url.fragment, view.url != nil { view.load(URLRequest(url: url)) }
    }
}

private extension String {
    func trimmingSuffix(_ s: String) -> String {
        var r = self
        while r.hasSuffix(s) { r.removeLast(s.count) }
        return r
    }
}
