// UniFlow fuer Windows: ein Tauri-Fenster und das mitgelieferte Backend (uniflow-backend.exe, PyInstaller).
//
// Start: das Backend wird aus den Ressourcen gestartet (backend/uniflow-backend.exe) mit der eigenen Prozess-ID als
// Elternprozess; es bindet einen freien Port auf 127.0.0.1 und schreibt ihn in %LOCALAPPDATA%\de.uniflow.desktop\backend.json.
// Fenster-Agent: nach dem Start holt ein Thread beim Backend Auftraege ab (GET /api/desktop/commands, lange Abfrage)
// und oeffnet dafuer eigene WebView-Fenster – Links („Im Stud.IP oeffnen“) und die Anmeldung bei der Hochschule
// erscheinen so als Fenster der App, nicht als fremder Browser (app/desktop_windows.py). Beim Anmeldefenster meldet
// der Agent jede Sekunde die Cookies der gewuenschten Hosts an das Backend, das die Anmeldung prueft; antwortet es
// mit done, wird das Fenster geschlossen. Das Backend ist nur auf 127.0.0.1 erreichbar.
// Datenordner (= identifier) und Programmordner (%LOCALAPPDATA%\UniFlow, = productName) sind getrennt, siehe app/desktop.py.
// Die Datei gilt nur, wenn ihre `pid` die des gerade gestarteten Kindprozesses ist (keine alte Datei, kein fremder
// Prozess) und ihre `url` genau http://127.0.0.1:<port>/ lautet; dann wechselt das Fenster von der Startseite
// (dist/index.html) zur Oberflaeche des Backends. Endet das Backend vorher, zeigt die Startseite sofort den Fehler
// statt bis zum Zeitlimit zu warten.
// Ende: beim Schliessen des Fensters wird das Backend beendet (zusaetzlich endet es selbst, wenn dieser Prozess weg ist).
// Entwicklung ohne Paket: fehlt die exe, verbindet die Startseite wie bisher mit http://127.0.0.1:8765.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tauri::{Manager, RunEvent};

const LOG_HINT: &str = "Protokoll: %LOCALAPPDATA%\\de.uniflow.desktop\\logs\\backend.log";
/// Datenordner unter %LOCALAPPDATA%; gleicher Wert wie DATA_FOLDER in app/desktop.py und identifier in tauri.conf.json.
const DATA_FOLDER: &str = "de.uniflow.desktop";

/// Der Backend-Prozess; None, bevor er gestartet und nachdem er beim Beenden abgeraeumt wurde.
type Shared = Arc<Mutex<Option<Child>>>;

struct Backend(Shared);

fn state_file() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir())
        .join(DATA_FOLDER);
    base.join("backend.json")
}

fn backend_exe(resource_dir: &Path) -> Option<PathBuf> {
    let candidates = [
        resource_dir.join("backend").join("uniflow-backend.exe"),
        resource_dir.join("backend").join("uniflow-backend"),
    ];
    candidates.into_iter().find(|p| p.is_file())
}

fn spawn_backend(exe: &Path, state: &Path) -> std::io::Result<Child> {
    let mut cmd = Command::new(exe);
    cmd.arg("--parent-pid")
        .arg(std::process::id().to_string())
        .arg("--state")
        .arg(state)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(dir) = exe.parent() {
        cmd.current_dir(dir);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    cmd.spawn()
}

/// Port aus genau `http://127.0.0.1:<port>/`. Alles andere (anderer Host, https, Pfad, Abfrage, Port 0) wird
/// abgelehnt: das Fenster navigiert nur zum eigenen Backend auf der Loopback-Adresse.
fn local_port(url: &str) -> Option<u16> {
    let digits = url.strip_prefix("http://127.0.0.1:")?.strip_suffix('/')?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    match digits.parse::<u16>() {
        Ok(port) if port > 0 => Some(port),
        _ => None,
    }
}

/// Prueft den Inhalt der Zustandsdatei gegen den gestarteten Kindprozess.
/// Ok(None): noch nicht brauchbar (kein JSON, andere `pid` = alte Datei oder fremder Prozess) -> weiter warten.
/// Ok(Some((url, port))): unsere Datei mit zulaessiger Adresse.
/// Err: unsere Datei, aber die Adresse ist nicht http://127.0.0.1:<port>/ -> Abbruch mit Meldung.
fn check_state(text: &str, child_pid: u32) -> Result<Option<(String, u16)>, String> {
    let v: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return Ok(None),
    };
    if v.get("pid").and_then(|p| p.as_u64()) != Some(u64::from(child_pid)) {
        return Ok(None);
    }
    let url = v.get("url").and_then(|u| u.as_str()).unwrap_or("");
    let port_field = v.get("port").and_then(|p| p.as_u64());
    match local_port(url) {
        Some(port) if port_field.map_or(true, |p| p == u64::from(port)) => Ok(Some((url.to_string(), port))),
        _ => Err(format!("Das Backend hat eine unerwartete Adresse gemeldet ({url:?}). {LOG_HINT}")),
    }
}

/// Some(status), sobald der Kindprozess beendet ist (try_wait, ohne zu blockieren).
fn exited(backend: &Shared) -> Option<ExitStatus> {
    let mut guard = backend.lock().unwrap();
    guard.as_mut().and_then(|child| child.try_wait().ok().flatten())
}

/// Wartet auf die Zustandsdatei des gestarteten Backends und liefert die URL der Oberflaeche. Endet das Backend
/// vorher oder meldet es eine fremde Adresse, kommt sofort der Fehlertext fuer die Startseite.
fn wait_for_url(state: &Path, backend: &Shared, started: Instant, timeout: Duration) -> Result<String, String> {
    let child_pid = match backend.lock().unwrap().as_ref() {
        Some(child) => child.id(),
        None => return Err(format!("Das Backend wurde nicht gestartet. {LOG_HINT}")),
    };
    while started.elapsed() < timeout {
        if let Some(status) = exited(backend) {
            return Err(format!("Das Backend hat sich beendet ({status}). {LOG_HINT}"));
        }
        if let Ok(text) = std::fs::read_to_string(state) {
            if let Some((url, port)) = check_state(&text, child_pid)? {
                if reachable(port) {
                    return Ok(url);
                }
            }
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    Err(format!("Das Backend hat nicht geantwortet. {LOG_HINT}"))
}

/// Kurzer TCP-Test auf 127.0.0.1:<port> (das Backend bindet den Port vor der Datei; hier nur zur Sicherheit).
fn reachable(port: u16) -> bool {
    let addr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port));
    std::net::TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok()
}

/// Minimaler HTTP/1.1-Aufruf gegen das eigene Backend auf 127.0.0.1 (kein Zusatzpaket): JSON hin, JSON zurueck.
/// None bei Verbindungsfehler oder Status ausserhalb 2xx; Some(Null) bei 204 oder leerem Koerper.
fn backend_json(port: u16, method: &str, path: &str, body: Option<&serde_json::Value>, timeout: Duration) -> Option<serde_json::Value> {
    use std::io::{Read, Write};
    let addr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port));
    let mut stream = std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(3)).ok()?;
    stream.set_read_timeout(Some(timeout)).ok()?;
    let payload = body.map(|b| b.to_string()).unwrap_or_default();
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    );
    stream.write_all(request.as_bytes()).ok()?;
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).ok()?;
    let text = String::from_utf8_lossy(&raw);
    let (head, rest) = text.split_once("\r\n\r\n")?;
    let status: u16 = head.split_whitespace().nth(1)?.parse().ok()?;
    if !(200..300).contains(&status) {
        return None;
    }
    let chunked = head.to_ascii_lowercase().contains("transfer-encoding: chunked");
    let body_text = if chunked { dechunk(rest) } else { rest.to_string() };
    if status == 204 || body_text.trim().is_empty() {
        return Some(serde_json::Value::Null);
    }
    serde_json::from_str(&body_text).ok()
}

/// Chunked-Koerper zusammensetzen (uvicorn schickt JSON normalerweise mit Content-Length; nur zur Sicherheit).
fn dechunk(data: &str) -> String {
    let mut out = String::new();
    let mut rest = data;
    loop {
        let Some((size_line, after)) = rest.split_once("\r\n") else { break };
        let size = usize::from_str_radix(size_line.trim().split(';').next().unwrap_or("0"), 16).unwrap_or(0);
        if size == 0 || after.len() < size {
            break;
        }
        out.push_str(&after[..size]);
        rest = after[size..].strip_prefix("\r\n").unwrap_or("");
    }
    out
}

/// Nur http(s)-Adressen werden in App-Fenstern geoeffnet (und about:blank waehrend der Navigation).
fn allowed_window_url(url: &tauri::Url) -> bool {
    matches!(url.scheme(), "http" | "https" | "about")
}

fn cookie_json(c: &tauri::webview::Cookie<'_>) -> serde_json::Value {
    serde_json::json!({
        "name": c.name(), "value": c.value(),
        "domain": c.domain().unwrap_or(""), "path": c.path().unwrap_or("/"),
        "expires": c.expires_datetime().map(|d| d.unix_timestamp()),
        "httpOnly": c.http_only().unwrap_or(false), "secure": c.secure().unwrap_or(false)
    })
}

/// Fenster auf dem Hauptthread anlegen (WebviewWindowBuilder darf unter Windows nicht aus Ereignis-Handlern laufen).
fn open_app_window(app: &tauri::AppHandle, label: &str, url: tauri::Url, title: &str) -> Result<(), String> {
    let (tx, rx) = std::sync::mpsc::channel();
    let (app2, label2, title2) = (app.clone(), label.to_string(), title.to_string());
    app.run_on_main_thread(move || {
        let built = tauri::WebviewWindowBuilder::new(&app2, &label2, tauri::WebviewUrl::External(url))
            .title(title2)
            .inner_size(1000.0, 820.0)
            .on_navigation(allowed_window_url)
            .build()
            .map(|_| ())
            .map_err(|e| e.to_string());
        let _ = tx.send(built);
    })
    .map_err(|e| e.to_string())?;
    rx.recv_timeout(Duration::from_secs(15)).unwrap_or_else(|_| Err("Fenster nicht angelegt (Zeitueberschreitung)".into()))
}

/// Anmeldefenster begleiten: jede Sekunde Zustand und Cookies der gewuenschten Hosts melden, bis das Backend `done`
/// sagt (dann schliessen) oder der Mensch das Fenster schliesst.
fn track_login_window(app: tauri::AppHandle, port: u16, id: String, label: String, cookie_urls: Vec<tauri::Url>) {
    loop {
        std::thread::sleep(Duration::from_secs(1));
        let Some(window) = app.get_webview_window(&label) else {
            let _ = backend_json(port, "POST", &format!("/api/desktop/windows/{id}/state"),
                                 Some(&serde_json::json!({"status": "closed"})), Duration::from_secs(10));
            return;
        };
        let mut cookies = Vec::new();
        for u in &cookie_urls {
            if let Ok(list) = window.cookies_for_url(u.clone()) {
                cookies.extend(list.iter().map(cookie_json));
            }
        }
        let current = window.url().map(|u| u.to_string()).unwrap_or_default();
        let body = serde_json::json!({"status": "open", "url": current, "cookies": cookies});
        match backend_json(port, "POST", &format!("/api/desktop/windows/{id}/state"), Some(&body), Duration::from_secs(10)) {
            Some(v) if v.get("done").and_then(|d| d.as_bool()) == Some(true) => {
                let _ = window.close();
                return;
            }
            Some(_) => {}
            None => return,                          // Backend weg: nicht weiter melden, Fenster bleibt dem Menschen
        }
    }
}

fn handle_command(app: &tauri::AppHandle, port: u16, cmd: &serde_json::Value) {
    let id = cmd.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let kind = cmd.get("kind").and_then(|v| v.as_str()).unwrap_or("");
    let title = cmd.get("title").and_then(|v| v.as_str()).unwrap_or("UniFlow").to_string();
    let Some(url) = cmd.get("url").and_then(|v| v.as_str()).and_then(|u| tauri::Url::parse(u).ok()) else { return };
    if id.is_empty() || !allowed_window_url(&url) || url.scheme() == "about" {
        return;
    }
    let label = format!("win-{id}");
    if let Err(e) = open_app_window(app, &label, url, &title) {
        let _ = backend_json(port, "POST", &format!("/api/desktop/windows/{id}/state"),
                             Some(&serde_json::json!({"status": "closed", "error": e})), Duration::from_secs(10));
        return;
    }
    if kind == "login" {
        let cookie_urls: Vec<tauri::Url> = cmd.get("cookie_urls").and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|u| u.as_str()).filter_map(|u| tauri::Url::parse(u).ok()).collect())
            .unwrap_or_default();
        let app2 = app.clone();
        std::thread::spawn(move || track_login_window(app2, port, id, label, cookie_urls));
    } else {
        let _ = backend_json(port, "POST", &format!("/api/desktop/windows/{id}/state"),
                             Some(&serde_json::json!({"status": "open"})), Duration::from_secs(10));
    }
}

/// Auftraege des Backends abholen (lange Abfrage), solange die App laeuft.
fn window_agent(app: tauri::AppHandle, port: u16) {
    loop {
        match backend_json(port, "GET", "/api/desktop/commands?wait=25", None, Duration::from_secs(45)) {
            None => std::thread::sleep(Duration::from_secs(2)),          // Backend nicht erreichbar: spaeter erneut
            Some(serde_json::Value::Null) => {}                            // nichts zu tun
            Some(cmd) => handle_command(&app, port, &cmd),
        }
    }
}

fn set_message(window: &tauri::WebviewWindow, text: &str) {
    let js = format!(
        "(function(){{var m=document.getElementById('msg');if(m)m.textContent={};}})()",
        serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into())
    );
    let _ = window.eval(&js);
}

fn main() {
    tauri::Builder::default()
        // Einzelinstanz: ein zweiter Start (Doppelklick, Startmenue) holt das offene Fenster nach vorn und endet; sonst
        // liefe ein zweites Backend auf derselben Datenbank. Muss das erste Plugin sein.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.show();
                let _ = w.set_focus();
            }
        }))
        .manage(Backend(Arc::new(Mutex::new(None))))
        .setup(|app| {
            let window = app.get_webview_window("main").expect("Hauptfenster fehlt");
            let resource_dir = app.path().resource_dir().unwrap_or_else(|_| PathBuf::from("."));
            let state = state_file();
            let _ = std::fs::remove_file(&state);
            match backend_exe(&resource_dir) {
                Some(exe) => {
                    let started = Instant::now();
                    match spawn_backend(&exe, &state) {
                        Ok(child) => {
                            let backend: Shared = app.state::<Backend>().0.clone();
                            *backend.lock().unwrap() = Some(child);
                            let win = window.clone();
                            let state_path = state.clone();
                            let handle = app.handle().clone();
                            std::thread::spawn(move || {
                                set_message(&win, "UniFlow startet …");
                                match wait_for_url(&state_path, &backend, started, Duration::from_secs(90)) {
                                    Ok(url) => {
                                        if let Ok(parsed) = tauri::Url::parse(&url) {
                                            let _ = win.navigate(parsed);
                                        }
                                        if let Some(port) = local_port(&url) {
                                            std::thread::spawn(move || window_agent(handle, port));
                                        }
                                    }
                                    Err(text) => set_message(&win, &text),
                                }
                            });
                        }
                        Err(e) => set_message(&window, &format!("Backend konnte nicht gestartet werden: {e}")),
                    }
                }
                None => {
                    // Entwicklung ohne Paket: die Startseite verbindet sich mit dem Server aus serve.py
                    set_message(&window, "Entwicklungsmodus: verbinde mit http://127.0.0.1:8765 …");
                }
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("UniFlow konnte nicht gestartet werden")
        .run(|app, event| {
            if let RunEvent::Exit | RunEvent::ExitRequested { .. } = event {
                if let Some(mut child) = app.state::<Backend>().0.lock().unwrap().take() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
                let _ = std::fs::remove_file(state_file());
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dechunk_joins_chunks() {
        assert_eq!(dechunk("5\r\nhello\r\n0\r\n\r\n"), "hello");
        assert_eq!(dechunk("2\r\n{}\r\n0\r\n\r\n"), "{}");
    }

    #[test]
    fn app_windows_open_only_http() {
        assert!(allowed_window_url(&tauri::Url::parse("https://studip.uni-hannover.de/x").unwrap()));
        assert!(!allowed_window_url(&tauri::Url::parse("file:///C:/x").unwrap()));
        assert!(!allowed_window_url(&tauri::Url::parse("javascript:alert(1)").unwrap()));
    }

    #[test]
    fn local_port_accepts_only_loopback_http() {
        assert_eq!(local_port("http://127.0.0.1:8765/"), Some(8765));
        assert_eq!(local_port("http://127.0.0.1:65535/"), Some(65535));
        for bad in [
            "",
            "http://localhost:8765/",
            "https://127.0.0.1:8765/",
            "http://127.0.0.1:8765",
            "http://127.0.0.1:8765/app/",
            "http://127.0.0.1:8765/?x=1",
            "http://127.0.0.1:0/",
            "http://127.0.0.1:65536/",
            "http://127.0.0.1:8765/@evil.example/",
            "http://10.0.0.5:8765/",
            "file:///C:/x/",
        ] {
            assert_eq!(local_port(bad), None, "{bad}");
        }
    }

    #[test]
    fn check_state_needs_our_pid_and_local_url() {
        let ok = r#"{"port": 8765, "pid": 42, "url": "http://127.0.0.1:8765/"}"#;
        assert_eq!(check_state(ok, 42), Ok(Some(("http://127.0.0.1:8765/".to_string(), 8765))));
        assert_eq!(check_state(ok, 43), Ok(None), "alte Datei oder fremder Prozess: weiter warten");
        assert_eq!(check_state(r#"{"port": 8765, "url": "http://127.0.0.1:8765/"}"#, 42), Ok(None));
        assert_eq!(check_state("{", 42), Ok(None));
        assert!(check_state(r#"{"port": 8765, "pid": 42, "url": "http://evil.example/"}"#, 42).is_err());
        assert!(check_state(r#"{"port": 8765, "pid": 42, "url": "https://127.0.0.1:8765/"}"#, 42).is_err());
        assert!(check_state(r#"{"port": 1, "pid": 42, "url": "http://127.0.0.1:8765/"}"#, 42).is_err(), "port und url widersprechen sich");
        assert!(check_state(r#"{"pid": 42}"#, 42).is_err());
    }
}
