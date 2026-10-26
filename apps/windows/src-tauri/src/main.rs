// UniFlow fuer Windows: ein Tauri-Fenster und das mitgelieferte Backend (uniflow-backend.exe, PyInstaller).
//
// Start: das Backend wird aus den Ressourcen gestartet (backend/uniflow-backend.exe) mit der eigenen Prozess-ID als
// Elternprozess; es waehlt einen freien Port auf 127.0.0.1 und schreibt ihn in %LOCALAPPDATA%\UniFlow\backend.json.
// Sobald die Datei da ist, wechselt das Fenster von der Startseite (dist/index.html) zur Oberflaeche des Backends.
// Ende: beim Schliessen des Fensters wird das Backend beendet (zusaetzlich endet es selbst, wenn dieser Prozess weg ist).
// Entwicklung ohne Paket: fehlt die exe, verbindet die Startseite wie bisher mit http://127.0.0.1:8765.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tauri::{Manager, RunEvent};

struct Backend(Mutex<Option<Child>>);

fn state_file() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir())
        .join("UniFlow");
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

/// Wartet auf die Zustandsdatei des Backends und liefert die URL der Oberflaeche.
fn wait_for_url(state: &Path, started: Instant, timeout: Duration) -> Option<String> {
    let since = started;
    while since.elapsed() < timeout {
        if let Ok(text) = std::fs::read_to_string(state) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                if let Some(url) = v.get("url").and_then(|u| u.as_str()) {
                    // nur eine Datei, die nach unserem Start geschrieben wurde (keine alte vom letzten Lauf)
                    let fresh = v.get("started_at").and_then(|t| t.as_f64()).map(|t| {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.as_secs_f64())
                            .unwrap_or(0.0);
                        now - t < timeout.as_secs_f64() + 5.0
                    });
                    if fresh.unwrap_or(true) && reachable(url) {
                        return Some(url.to_string());
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    None
}

/// Kurzer TCP-Test, ob der Port schon annimmt (die Datei kommt knapp vor dem Hoeren).
fn reachable(url: &str) -> bool {
    let hostport = url
        .trim_start_matches("http://")
        .trim_end_matches('/')
        .to_string();
    std::net::TcpStream::connect_timeout(
        &match hostport.parse() {
            Ok(a) => a,
            Err(_) => return false,
        },
        Duration::from_millis(300),
    )
    .is_ok()
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
        .manage(Backend(Mutex::new(None)))
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
                            *app.state::<Backend>().0.lock().unwrap() = Some(child);
                            let win = window.clone();
                            let state_path = state.clone();
                            std::thread::spawn(move || {
                                set_message(&win, "UniFlow startet …");
                                match wait_for_url(&state_path, started, Duration::from_secs(90)) {
                                    Some(url) => {
                                        if let Ok(parsed) = tauri::Url::parse(&url) {
                                            let _ = win.navigate(parsed);
                                        }
                                    }
                                    None => set_message(
                                        &win,
                                        "Das Backend hat nicht geantwortet. Protokoll: %LOCALAPPDATA%\\UniFlow\\logs\\backend.log",
                                    ),
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

#[allow(dead_code)]
struct Shared(Arc<Mutex<Option<Child>>>);
