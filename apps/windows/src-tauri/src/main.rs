// UniFlow fuer Windows: ein Tauri-Fenster und das mitgelieferte Backend (uniflow-backend.exe, PyInstaller).
//
// Start: das Backend wird aus den Ressourcen gestartet (backend/uniflow-backend.exe) mit der eigenen Prozess-ID als
// Elternprozess; es bindet einen freien Port auf 127.0.0.1 und schreibt ihn in %LOCALAPPDATA%\de.uniflow.desktop\backend.json.
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
                            std::thread::spawn(move || {
                                set_message(&win, "UniFlow startet …");
                                match wait_for_url(&state_path, &backend, started, Duration::from_secs(90)) {
                                    Ok(url) => {
                                        if let Ok(parsed) = tauri::Url::parse(&url) {
                                            let _ = win.navigate(parsed);
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
