//! Snapmark for Windows and Linux: a tray app that captures the screen, opens the annotation
//! editor, and copies the result. The editor and settings UI live in the web view (../src); this
//! side owns capture, files, the clipboard, global shortcuts, the tray and the config file.

mod config;

use config::Config;
use image::RgbaImage;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use tauri::ipc::{InvokeBody, Request, Response};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{
    AppHandle, Emitter, Manager, RunEvent, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_dialog::{DialogExt, MessageDialogKind};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use tauri_plugin_opener::OpenerExt;

/// A capture waiting for the user to pick an area or a window in the overlay.
struct Pending {
    image: RgbaImage,
    scale: f64,
    mode: &'static str,
    windows: Vec<serde_json::Value>,
}

#[derive(Default)]
struct State {
    config: Mutex<Config>,
    /// True while the config file has a JSON error; Snapmark then never writes it.
    broken: Mutex<bool>,
    pending: Mutex<Option<Pending>>,
    /// Kept alive for the whole run: on Linux the clipboard empties when its owner goes away.
    clipboard: Mutex<Option<arboard::Clipboard>>,
    /// Which config entry each registered shortcut belongs to: "captureArea" or "cmd:<keys>".
    bindings: Mutex<Vec<(Shortcut, String)>>,
    tray: Mutex<Option<TrayIcon>>,
    _watcher: Mutex<Option<notify::RecommendedWatcher>>,
}

static EDITORS: AtomicU32 = AtomicU32::new(0);

// MARK: - Capture

fn capture(app: &AppHandle, mode: &'static str) {
    if app.get_webview_window("overlay").is_some() {
        return;
    }
    let app = app.clone();
    // Off the main thread: grabbing a screen can take a moment, and on Wayland a portal may ask.
    std::thread::spawn(move || {
        if let Err(e) = capture_inner(&app, mode) {
            error(&app, "Snapmark couldn't capture the screen", &e);
        }
    });
}

fn capture_inner(app: &AppHandle, mode: &'static str) -> Result<(), String> {
    let cursor = app
        .cursor_position()
        .map(|p| (p.x as i32, p.y as i32))
        .unwrap_or((0, 0));
    let monitor = xcap::Monitor::from_point(cursor.0, cursor.1)
        .or_else(|_| {
            xcap::Monitor::all()
                .map_err(|e| e.to_string())?
                .into_iter()
                .next()
                .ok_or("no screen found".into())
        })
        .map_err(|e: String| e)?;
    let image = match monitor.capture_image() {
        Ok(image) => image,
        Err(e) => linux_tool_capture().ok_or_else(|| wayland_hint(e.to_string()))?,
    };
    if mode == "screen" {
        return finish(app, image);
    }
    let (mx, my) = (monitor.x().unwrap_or(0), monitor.y().unwrap_or(0));
    let (mw, mh) = (
        monitor.width().unwrap_or(image.width()),
        monitor.height().unwrap_or(image.height()),
    );
    // Pixels in the image per logical point of this monitor (2.0 on a 200% display).
    let scale = image.width() as f64 / f64::from(mw.max(1))
        * f64::from(monitor.scale_factor().unwrap_or(1.0));
    let windows = xcap::Window::all()
        .unwrap_or_default()
        .into_iter()
        .filter(|w| !w.is_minimized().unwrap_or(true))
        .filter_map(|w| {
            let (x, y, ww, wh) = (w.x().ok()?, w.y().ok()?, w.width().ok()?, w.height().ok()?);
            let px = image.width() as f64 / f64::from(mw.max(1));
            (ww > 40 && wh > 40).then(|| {
                serde_json::json!({
                    "x": f64::from(x - mx) * px, "y": f64::from(y - my) * px,
                    "w": f64::from(ww) * px, "h": f64::from(wh) * px,
                    "title": w.title().unwrap_or_default(),
                })
            })
        })
        .collect();
    *app.state::<State>().pending.lock().unwrap() = Some(Pending {
        image,
        scale,
        mode,
        windows,
    });

    let factor = f64::from(monitor.scale_factor().unwrap_or(1.0));
    let handle = app.clone();
    app.run_on_main_thread(move || {
        let built = WebviewWindowBuilder::new(
            &handle,
            "overlay",
            WebviewUrl::App("index.html?view=overlay".into()),
        )
        .title("Snapmark")
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .position(f64::from(mx) / factor, f64::from(my) / factor)
        .inner_size(f64::from(mw) / factor, f64::from(mh) / factor)
        .focused(true)
        .build();
        match built {
            Ok(w) => {
                let _ = w.set_fullscreen(true);
                let _ = w.set_focus();
            }
            Err(e) => error(
                &handle,
                "Snapmark couldn't show the capture overlay",
                &e.to_string(),
            ),
        }
    })
    .map_err(|e| e.to_string())
}

/// Some Wayland desktops refuse direct capture. Their own screenshot tools still work, so try the
/// common ones before giving up. Returns the full screen.
fn linux_tool_capture() -> Option<RgbaImage> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    // A private (0700) folder, not a guessable name in shared /tmp.
    let dir = tempfile::Builder::new().prefix("snapmark-").tempdir().ok()?;
    let out = dir.path().join("screen.png");
    let o = out.to_string_lossy().into_owned();
    let tools: [(&str, Vec<&str>); 3] = [
        ("grim", vec![o.as_str()]),
        ("gnome-screenshot", vec!["-f", o.as_str()]),
        ("spectacle", vec!["-b", "-n", "-f", "-o", o.as_str()]),
    ];
    for (tool, args) in tools {
        let ok = std::process::Command::new(tool).args(&args).status().is_ok_and(|s| s.success());
        if ok {
            let image = image::open(&out).ok().map(|i| i.to_rgba8());
            let _ = std::fs::remove_file(&out);
            if image.is_some() {
                return image;
            }
        }
    }
    None
}

fn wayland_hint(e: String) -> String {
    if platform() == "linux-wayland" {
        format!(
            "{e}\n\nOn Wayland, Snapmark captures through your desktop's screenshot portal. \
                 Make sure xdg-desktop-portal and your desktop's portal backend are installed, \
                 or install grim (Sway, Hyprland) or gnome-screenshot."
        )
    } else {
        e
    }
}

/// Saves a finished capture, copies it if the user wants that, and opens the editor.
fn finish(app: &AppHandle, image: RgbaImage) -> Result<(), String> {
    let cfg = app.state::<State>().config.lock().unwrap().clone();
    let path = cfg.new_capture_path();
    std::fs::create_dir_all(path.parent().unwrap())
        .map_err(|e| format!("{}: {e}", cfg.save_folder))?;
    image
        .save(&path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    if cfg.copy_on_capture {
        if let Err(e) = copy_rgba(app, &image) {
            error(
                app,
                "Snapmark couldn't copy the capture",
                &format!("It is saved at {}.\n\n{e}", path.display()),
            );
        }
    }
    open_editor(app, &path, true);
    Ok(())
}

#[tauri::command]
fn capture_cmd(app: AppHandle, mode: String) {
    capture(
        &app,
        match mode.as_str() {
            "window" => "window",
            "screen" => "screen",
            _ => "area",
        },
    );
}

#[tauri::command]
fn overlay_info(app: AppHandle) -> Result<serde_json::Value, String> {
    let state = app.state::<State>();
    let pending = state.pending.lock().unwrap();
    let p = pending.as_ref().ok_or("no capture in progress")?;
    Ok(
        serde_json::json!({ "width": p.image.width(), "height": p.image.height(), "scale": p.scale, "mode": p.mode, "windows": p.windows }),
    )
}

/// The frozen screenshot for the overlay, as raw RGBA. It never touches the disk, so other users
/// on a shared machine can't read it from /tmp.
#[tauri::command]
fn overlay_pixels(app: AppHandle) -> Result<Response, String> {
    let state = app.state::<State>();
    let pending = state.pending.lock().unwrap();
    let p = pending.as_ref().ok_or("no capture in progress")?;
    Ok(Response::new(p.image.as_raw().clone()))
}

#[derive(serde::Deserialize)]
struct PickRect {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
}

#[tauri::command]
fn finish_capture(app: AppHandle, rect: Option<PickRect>) -> Result<(), String> {
    let pending = app.state::<State>().pending.lock().unwrap().take();
    if let Some(w) = app.get_webview_window("overlay") {
        let _ = w.close();
    }
    let (Some(p), Some(r)) = (pending, rect) else {
        return Ok(());
    };
    let (iw, ih) = p.image.dimensions();
    let x = r.x.min(iw.saturating_sub(1));
    let y = r.y.min(ih.saturating_sub(1));
    let w = r.w.min(iw - x).max(1);
    let h = r.h.min(ih - y).max(1);
    let cropped = image::imageops::crop_imm(&p.image, x, y, w, h).to_image();
    finish(&app, cropped)
}

// MARK: - Files and clipboard

fn header(request: &Request, name: &str) -> Result<String, String> {
    let raw = request
        .headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .ok_or(format!("missing {name}"))?;
    Ok(percent_decode(raw))
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn body<'a>(request: &'a Request<'_>) -> Result<&'a [u8], String> {
    match request.body() {
        InvokeBody::Raw(bytes) => Ok(bytes),
        _ => Err("expected image bytes".into()),
    }
}

#[tauri::command]
fn read_file(path: String) -> Result<Response, String> {
    std::fs::read(&path)
        .map(Response::new)
        .map_err(|e| format!("{path}: {e}"))
}

/// Writes PNG bytes (atomically) and returns the path written.
#[tauri::command]
fn save_png(request: Request<'_>) -> Result<String, String> {
    let path = PathBuf::from(header(&request, "path")?);
    let bytes = body(&request)?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let tmp = path.with_extension("png.tmp");
    std::fs::write(&tmp, bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
fn output_path(path: String, owns: bool) -> String {
    config::output_path(Path::new(&path), owns)
        .to_string_lossy()
        .into_owned()
}

fn copy_rgba(app: &AppHandle, image: &RgbaImage) -> Result<(), String> {
    let state = app.state::<State>();
    let mut slot = state.clipboard.lock().unwrap();
    if slot.is_none() {
        *slot = Some(arboard::Clipboard::new().map_err(|e| e.to_string())?);
    }
    slot.as_mut()
        .unwrap()
        .set_image(arboard::ImageData {
            width: image.width() as usize,
            height: image.height() as usize,
            bytes: std::borrow::Cow::Borrowed(image.as_raw()),
        })
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn copy_png(app: AppHandle, request: Request<'_>) -> Result<(), String> {
    let image = image::load_from_memory(body(&request)?)
        .map_err(|e| e.to_string())?
        .to_rgba8();
    copy_rgba(&app, &image)
}

#[tauri::command]
fn copy_text(app: AppHandle, text: String) -> Result<(), String> {
    let state = app.state::<State>();
    let mut slot = state.clipboard.lock().unwrap();
    if slot.is_none() {
        *slot = Some(arboard::Clipboard::new().map_err(|e| e.to_string())?);
    }
    slot.as_mut()
        .unwrap()
        .set_text(text)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn trash(path: String) -> Result<(), String> {
    trash::delete(&path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn save_dialog(app: AppHandle, name: String) -> Option<String> {
    let dir = app.state::<State>().config.lock().unwrap().save_dir();
    app.dialog()
        .file()
        .set_file_name(name)
        .set_directory(dir)
        .add_filter("PNG image", &["png"])
        .blocking_save_file()
        .and_then(|p| p.into_path().ok())
        .map(|p| p.to_string_lossy().into_owned())
}

// MARK: - Config

#[tauri::command]
fn get_config(app: AppHandle) -> Config {
    app.state::<State>().config.lock().unwrap().clone()
}

#[tauri::command]
fn set_config(app: AppHandle, config: Config) -> Result<(), String> {
    let mut c = config;
    c.normalize();
    if *app.state::<State>().broken.lock().unwrap() {
        return Err(format!(
            "{} has an error, so Snapmark won't overwrite it. Fix or delete the file first.",
            config::path().display()
        ));
    }
    config::save(&config::path(), &c)?;
    apply(&app, c);
    Ok(())
}

/// Applies settings to the running app: shortcuts and the tray icon.
fn apply(app: &AppHandle, c: Config) {
    *app.state::<State>().config.lock().unwrap() = c;
    register_shortcuts(app);
    let show = app
        .state::<State>()
        .config
        .lock()
        .unwrap()
        .show_menu_bar_icon;
    if let Some(tray) = app.state::<State>().tray.lock().unwrap().as_ref() {
        let _ = tray.set_visible(show);
    }
    let _ = app.emit("config-changed", ());
}

/// Loads the file at launch or after it changes. A broken file is reported once and left alone.
fn reload(app: &AppHandle, at_launch: bool) {
    let path = config::path();
    match config::load(&path) {
        Ok(Some(c)) => {
            *app.state::<State>().broken.lock().unwrap() = false;
            if at_launch || *app.state::<State>().config.lock().unwrap() != c {
                apply(app, c);
            }
        }
        Ok(None) => {
            // No file yet (first launch) or deleted: write the current settings out.
            *app.state::<State>().broken.lock().unwrap() = false;
            let c = app.state::<State>().config.lock().unwrap().clone();
            let _ = config::save(&path, &c);
            apply(app, c);
        }
        Err(e) => {
            let was = std::mem::replace(&mut *app.state::<State>().broken.lock().unwrap(), true);
            if !was {
                error(app, "Snapmark couldn't read its config file",
                      &format!("{e}\n\nSnapmark keeps its current settings and won't change the file until it is fixed."));
            }
            if at_launch {
                register_shortcuts(app);
            }
        }
    }
}

fn watch_config(app: &AppHandle) {
    use notify::{RecursiveMode, Watcher};
    let path = config::path();
    let Some(dir) = path.parent().map(Path::to_path_buf) else {
        return;
    };
    let _ = std::fs::create_dir_all(&dir);
    let handle = app.clone();
    let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(event) = res else { return };
        if event
            .paths
            .iter()
            .any(|p| p.file_name() == path.file_name())
        {
            // Let the writer finish (editors write a temp file, then rename).
            std::thread::sleep(std::time::Duration::from_millis(150));
            let h = handle.clone();
            let _ = handle.run_on_main_thread(move || reload(&h, false));
        }
    });
    if let Ok(mut w) = watcher {
        if w.watch(&dir, RecursiveMode::NonRecursive).is_ok() {
            *app.state::<State>()._watcher.lock().unwrap() = Some(w);
        }
    }
}

#[tauri::command]
fn open_config(app: AppHandle) -> Result<(), String> {
    let path = config::path();
    if !path.exists() {
        let c = app.state::<State>().config.lock().unwrap().clone();
        config::save(&path, &c)?;
    }
    app.opener()
        .open_path(path.to_string_lossy(), None::<&str>)
        .map_err(|e| e.to_string())
}

// MARK: - Shortcuts

fn register_shortcuts(app: &AppHandle) {
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    let cfg = app.state::<State>().config.lock().unwrap().clone();
    let mut bindings = Vec::new();
    let mut taken = Vec::new();
    let entries = config::ACTIONS
        .iter()
        .map(|a| {
            (
                cfg.shortcuts.get(*a).cloned().unwrap_or_default(),
                a.to_string(),
            )
        })
        .chain(cfg.commands.keys().map(|k| (k.clone(), format!("cmd:{k}"))));
    for (keys, target) in entries {
        let Some(accel) = config::accelerator(&keys) else {
            continue;
        };
        let Ok(shortcut) = accel.parse::<Shortcut>() else {
            continue;
        };
        if gs.register(shortcut).is_ok() {
            bindings.push((shortcut, target));
        } else {
            taken.push(accel);
        }
    }
    *app.state::<State>().bindings.lock().unwrap() = bindings;
    if !taken.is_empty() {
        eprintln!("Snapmark: shortcuts already in use: {}", taken.join(", "));
    }
}

fn on_shortcut(app: &AppHandle, shortcut: &Shortcut) {
    let target = app
        .state::<State>()
        .bindings
        .lock()
        .unwrap()
        .iter()
        .find(|(s, _)| s == shortcut)
        .map(|(_, t)| t.clone());
    match target.as_deref() {
        Some("captureArea") => capture(app, "area"),
        Some("captureWindow") => capture(app, "window"),
        Some("captureScreen") => capture(app, "screen"),
        Some(t) if t.starts_with("cmd:") => {
            let command = app
                .state::<State>()
                .config
                .lock()
                .unwrap()
                .commands
                .get(&t[4..])
                .cloned();
            if let Some(command) = command {
                run_command(&command);
            }
        }
        _ => {}
    }
}

/// Runs a user-configured command through the shell, detached from Snapmark.
fn run_command(command: &str) {
    #[cfg(windows)]
    let result = std::process::Command::new("cmd")
        .args(["/C", command])
        .spawn();
    #[cfg(not(windows))]
    let result =
        std::process::Command::new(std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into()))
            .args(["-lc", command])
            .spawn();
    if let Err(e) = result {
        eprintln!("Snapmark: couldn't run {command}: {e}");
    }
}

#[tauri::command]
fn pause_shortcuts(app: AppHandle, paused: bool) {
    if paused {
        let _ = app.global_shortcut().unregister_all();
    } else {
        register_shortcuts(&app);
    }
}

// MARK: - Windows

fn open_editor(app: &AppHandle, file: &Path, owns: bool) {
    let n = EDITORS.fetch_add(1, Ordering::Relaxed);
    let url = format!(
        "index.html?view=editor&owns={}&file={}",
        u8::from(owns),
        encode(&file.to_string_lossy())
    );
    let title = file
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Snapmark".into());
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        let (w, h) = editor_size(&handle);
        match WebviewWindowBuilder::new(&handle, format!("editor-{n}"), WebviewUrl::App(url.into()))
            .title(title)
            .inner_size(w, h)
            .min_inner_size(720.0, 360.0)
            .center()
            .focused(true)
            .build()
        {
            Ok(win) => {
                let _ = win.set_focus();
            }
            Err(e) => error(&handle, "Snapmark couldn't open the editor", &e.to_string()),
        }
    });
}

fn editor_size(app: &AppHandle) -> (f64, f64) {
    app.primary_monitor()
        .ok()
        .flatten()
        .map(|m| {
            let s = m.size().to_logical::<f64>(m.scale_factor());
            (s.width * 0.75, s.height * 0.75)
        })
        .unwrap_or((1100.0, 720.0))
}

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~/".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

fn show_view(app: &AppHandle, label: &str, title: &str, size: (f64, f64)) {
    if let Some(w) = app.get_webview_window(label) {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    let handle = app.clone();
    let (label, title) = (label.to_string(), title.to_string());
    let _ = app.run_on_main_thread(move || {
        if let Ok(w) = WebviewWindowBuilder::new(
            &handle,
            &label,
            WebviewUrl::App(format!("index.html?view={label}").into()),
        )
        .title(title)
        .inner_size(size.0, size.1)
        .resizable(false)
        .center()
        .focused(true)
        .build()
        {
            let _ = w.set_focus();
        }
    });
}

#[tauri::command]
fn close_window(window: WebviewWindow) {
    let _ = window.destroy();
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    if !url.starts_with("https://") {
        return Err("only https links".into());
    }
    app.opener()
        .open_url(url, None::<&str>)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn autostart(app: AppHandle, enable: Option<bool>) -> bool {
    let manager = app.autolaunch();
    match enable {
        Some(true) => {
            let _ = manager.enable();
        }
        Some(false) => {
            let _ = manager.disable();
        }
        None => {}
    }
    manager.is_enabled().unwrap_or(false)
}

/// "windows", "linux-x11" or "linux-wayland", "macos" (for development builds).
#[tauri::command]
fn platform() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if std::env::var_os("WAYLAND_DISPLAY").is_some()
        || std::env::var("XDG_SESSION_TYPE").is_ok_and(|s| s == "wayland")
    {
        "linux-wayland"
    } else {
        "linux-x11"
    }
}

fn error(app: &AppHandle, title: &str, detail: &str) {
    eprintln!("Snapmark: {title}: {detail}");
    app.dialog()
        .message(detail)
        .title(title)
        .kind(MessageDialogKind::Error)
        .show(|_| {});
}

// MARK: - Tray

fn build_tray(app: &AppHandle) -> tauri::Result<TrayIcon> {
    let item = |id: &str, text: &str| MenuItem::with_id(app, id, text, true, None::<&str>);
    let menu = Menu::with_items(
        app,
        &[
            &item("area", "Capture Area")?,
            &item("window", "Capture Window")?,
            &item("screen", "Capture Full Screen")?,
            &PredefinedMenuItem::separator(app)?,
            &item("open", "Open Image…")?,
            &item("folder", "Open Screenshots Folder")?,
            &PredefinedMenuItem::separator(app)?,
            &item("settings", "Settings…")?,
            &item("config", "Edit Config File…")?,
            &item("about", "About Snapmark")?,
            &PredefinedMenuItem::separator(app)?,
            &item("quit", "Quit Snapmark")?,
        ],
    )?;
    TrayIconBuilder::with_id("snapmark")
        .icon(
            app.default_window_icon()
                .cloned()
                .ok_or(tauri::Error::InvalidIcon(std::io::Error::other("no icon")))?,
        )
        .tooltip("Snapmark")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "area" => capture(app, "area"),
            "window" => capture(app, "window"),
            "screen" => capture(app, "screen"),
            "open" => open_image_dialog(app),
            "folder" => {
                let dir = app.state::<State>().config.lock().unwrap().save_dir();
                let _ = std::fs::create_dir_all(&dir);
                let _ = app.opener().open_path(dir.to_string_lossy(), None::<&str>);
            }
            "settings" => show_view(app, "settings", "Snapmark Settings", (620.0, 560.0)),
            "config" => {
                let _ = open_config(app.clone());
            }
            "about" => show_view(app, "welcome", "About Snapmark", (560.0, 600.0)),
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)
}

fn open_image_dialog(app: &AppHandle) {
    let dir = app.state::<State>().config.lock().unwrap().save_dir();
    let handle = app.clone();
    app.dialog()
        .file()
        .set_directory(dir)
        .add_filter("Images", &["png", "jpg", "jpeg", "webp", "bmp", "gif"])
        .pick_file(move |file| {
            if let Some(p) = file.and_then(|f| f.into_path().ok()) {
                open_editor(&handle, &p, false);
            }
        });
}

// MARK: - Command line

/// `snapmark --capture` and friends. On Wayland, bind these to keys in your desktop's settings.
fn handle_args(app: &AppHandle, args: &[String], first_run: bool) {
    let has = |flag: &str| args.iter().any(|a| a == flag);
    if has("--capture") || has("--capture-area") {
        capture(app, "area");
    } else if has("--capture-window") {
        capture(app, "window");
    } else if has("--capture-screen") {
        capture(app, "screen");
    } else if let Some(i) = args.iter().position(|a| a == "--open") {
        if let Some(p) = args.get(i + 1) {
            open_editor(app, Path::new(p), false);
        }
    } else if has("--settings") {
        show_view(app, "settings", "Snapmark Settings", (620.0, 560.0));
    } else if let Some(p) = args
        .iter()
        .skip(1)
        .find(|a| !a.starts_with("--") && Path::new(a).is_file())
    {
        // "Open with Snapmark" from a file manager.
        open_editor(app, Path::new(p), false);
    } else if first_run {
        show_view(app, "welcome", "Welcome to Snapmark", (560.0, 600.0));
    }
}

pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, cwd| {
            // Relative paths from the second launch belong to its working directory, not ours.
            let args: Vec<String> = args
                .into_iter()
                .map(|a| {
                    let p = Path::new(&a);
                    if !a.starts_with("--") && p.is_relative() && Path::new(&cwd).join(p).exists() {
                        Path::new(&cwd).join(p).to_string_lossy().into_owned()
                    } else {
                        a
                    }
                })
                .collect();
            // A second launch hands its arguments to the running copy; a plain relaunch opens Settings.
            if args.len() <= 1 {
                show_view(app, "settings", "Snapmark Settings", (620.0, 560.0));
            } else {
                handle_args(app, &args, false);
            }
        }))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        on_shortcut(app, shortcut);
                    }
                })
                .build(),
        )
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--autostart"]),
        ))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(State::default())
        .on_window_event(|window, event| {
            // However the overlay goes away (Esc, Alt+F4, the window manager), drop its capture.
            if window.label() == "overlay" && matches!(event, tauri::WindowEvent::Destroyed) {
                window.app_handle().state::<State>().pending.lock().unwrap().take();
            }
        })
        .invoke_handler(tauri::generate_handler![
            capture_cmd,
            overlay_info,
            overlay_pixels,
            finish_capture,
            read_file,
            save_png,
            output_path,
            copy_png,
            copy_text,
            trash,
            save_dialog,
            get_config,
            set_config,
            open_config,
            pause_shortcuts,
            close_window,
            open_url,
            autostart,
            platform,
        ])
        .setup(|app| {
            let handle = app.handle().clone();
            let first_run = !config::path().exists();
            reload(&handle, true);
            watch_config(&handle);
            let tray = build_tray(&handle)?;
            let _ = tray.set_visible(
                handle
                    .state::<State>()
                    .config
                    .lock()
                    .unwrap()
                    .show_menu_bar_icon,
            );
            *handle.state::<State>().tray.lock().unwrap() = Some(tray);
            let args: Vec<String> = std::env::args().collect();
            if !args.iter().any(|a| a == "--autostart") {
                handle_args(&handle, &args, first_run);
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Snapmark failed to start");

    app.run(|_app, event| {
        // A tray app keeps running with no windows open.
        if let RunEvent::ExitRequested {
            api, code: None, ..
        } = event
        {
            api.prevent_exit();
        }
    });
}

#[cfg(test)]
mod tests {
    #[test]
    fn decodes_header_paths() {
        assert_eq!(
            super::percent_decode("C%3A%5CUsers%5Cme%5Csh%C3%B6t.png"),
            "C:\\Users\\me\\shöt.png"
        );
        assert_eq!(
            super::percent_decode("/home/me/a%20b.png"),
            "/home/me/a b.png"
        );
        assert_eq!(super::percent_decode("100%"), "100%");
    }
}
