// Kein Konsolenfenster im Release-Build unter Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("UniFlow konnte nicht gestartet werden");
}
