//! The config file, shared in format with the macOS app. Linux: ~/.config/shotate/config.json.
//! Windows: %APPDATA%\shotate\config.json. People and agents edit it directly; Shotate reloads
//! it when it changes. Missing keys keep their defaults, unknown keys are ignored, and a file with
//! a JSON error is reported and never overwritten.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const ACTIONS: [&str; 3] = ["captureArea", "captureWindow", "captureScreen"];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Config {
    pub save_folder: String,
    pub copy_on_capture: bool,
    /// Called showMenuBarIcon for the macOS app's sake; here it is the system tray icon.
    pub show_menu_bar_icon: bool,
    pub shortcuts: BTreeMap<String, String>,
    pub commands: BTreeMap<String, String>,
    pub tool_keys: BTreeMap<String, String>,
}

impl Default for Config {
    fn default() -> Self {
        let shortcuts = ACTIONS
            .iter()
            .map(|a| (a.to_string(), String::new()))
            .collect::<BTreeMap<_, _>>();
        let mut c = Config {
            save_folder: default_folder(),
            copy_on_capture: true,
            show_menu_bar_icon: true,
            shortcuts,
            commands: BTreeMap::new(),
            tool_keys: BTreeMap::new(),
        };
        c.shortcuts
            .insert("captureArea".into(), "ctrl+shift+s".into());
        c
    }
}

fn default_folder() -> String {
    let pictures = dirs::picture_dir()
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join("Pictures"));
    tilde(&pictures.join("Screenshots"))
}

/// Writes paths under the home folder as "~/…", the way people type them.
fn tilde(p: &Path) -> String {
    match dirs::home_dir().and_then(|h| p.strip_prefix(&h).ok().map(|r| r.to_path_buf())) {
        Some(rest) => format!("~/{}", rest.to_string_lossy().replace('\\', "/")),
        None => p.to_string_lossy().into_owned(),
    }
}

pub fn expand(path: &str) -> PathBuf {
    match path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        Some(rest) => dirs::home_dir().unwrap_or_default().join(rest),
        None if path == "~" => dirs::home_dir().unwrap_or_default(),
        None => PathBuf::from(path),
    }
}

pub fn path() -> PathBuf {
    config_root().join("shotate").join("config.json")
}

/// Where the app kept its config when it was called Snapmark.
pub fn legacy_path() -> PathBuf {
    config_root().join("snapmark").join("config.json")
}

fn config_root() -> PathBuf {
    dirs::config_dir().unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".config"))
}

/// Copies the Snapmark-era config into place the first time Shotate runs, so shortcuts and folders
/// carry over. The old file is left where it was. Returns true when it copied.
pub fn adopt_legacy(old: &Path, new: &Path) -> bool {
    if new.exists() || !old.exists() {
        return false;
    }
    new.parent().map_or(Ok(()), std::fs::create_dir_all).is_ok() && std::fs::copy(old, new).is_ok()
}

/// Reads the file. `Ok(None)` when there is no file yet; `Err` when its JSON is broken.
pub fn load(path: &Path) -> Result<Option<Config>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    let file: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let Some(fields) = file.as_object() else {
        return Err(format!(
            "{}: the config file must be a JSON object",
            path.display()
        ));
    };
    // Lay the file over the defaults, one level deep for the shortcuts map, so a file that names
    // only one shortcut keeps the others at their defaults (as on macOS).
    let mut merged = serde_json::to_value(Config::default()).map_err(|e| e.to_string())?;
    for (k, v) in fields {
        match (k.as_str(), v) {
            ("shortcuts", serde_json::Value::Object(m)) => {
                for (a, s) in m {
                    merged["shortcuts"][a] = s.clone();
                }
            }
            _ => merged[k] = v.clone(),
        }
    }
    let mut c: Config =
        serde_json::from_value(merged).map_err(|e| format!("{}: {e}", path.display()))?;
    c.normalize();
    Ok(Some(c))
}

pub fn save(path: &Path, c: &Config) -> Result<(), String> {
    let mut value = serde_json::to_value(c).map_err(|e| e.to_string())?;
    value["_help"] = "Shotate settings. Edit and save; Shotate reloads right away. \
                      Docs: https://github.com/baney75/shotate#configuration"
        .into();
    let text = serde_json::to_string_pretty(&value).map_err(|e| e.to_string())?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    // Write a sibling then rename, so a reader never sees half a file.
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, text + "\n").map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

impl Config {
    /// Every action present, unusable shortcuts turned off.
    pub fn normalize(&mut self) {
        for a in ACTIONS {
            let v = self
                .shortcuts
                .get(a)
                .cloned()
                .unwrap_or_default()
                .to_lowercase();
            let v = if accelerator(&v).is_some() {
                v
            } else {
                String::new()
            };
            self.shortcuts.insert(a.to_string(), v);
        }
        self.shortcuts.retain(|k, _| ACTIONS.contains(&k.as_str()));
        self.commands
            .retain(|k, v| accelerator(k).is_some() && !v.trim().is_empty());
        if self.save_folder.trim().is_empty() {
            self.save_folder = default_folder();
        }
    }

    pub fn save_dir(&self) -> PathBuf {
        expand(&self.save_folder)
    }

    /// "Shotate 2026-10-10 at 14.03.22.png" in the save folder; adds " 2", " 3" on a clash.
    pub fn new_capture_path(&self) -> PathBuf {
        let base = format!(
            "Shotate {}",
            chrono::Local::now().format("%Y-%m-%d at %H.%M.%S")
        );
        unique(&self.save_dir(), &base)
    }
}

/// `dir/base.png`, or `dir/base 2.png`, `dir/base 3.png`… whichever doesn't exist yet.
pub fn unique(dir: &Path, base: &str) -> PathBuf {
    let mut p = dir.join(format!("{base}.png"));
    let mut n = 2;
    while p.exists() {
        p = dir.join(format!("{base} {n}.png"));
        n += 1;
    }
    p
}

/// Where edits to `file` are saved: the capture itself, or "name (edited).png" beside an opened image.
pub fn output_path(file: &Path, owns: bool) -> PathBuf {
    if owns {
        return file.to_path_buf();
    }
    let stem = file
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Image".into());
    let dir = file.parent().map(Path::to_path_buf).unwrap_or_default();
    unique(&dir, &format!("{stem} (edited)"))
}

/// "ctrl+shift+s" → "Control+Shift+S" for the global-shortcut plugin. `cmd` means Ctrl here, so a
/// config written on a Mac works unchanged. Returns None for anything that can't be a shortcut.
pub fn accelerator(text: &str) -> Option<String> {
    let mut mods = Vec::new();
    let mut key = None;
    for part in text
        .split('+')
        .map(|p| p.trim().to_lowercase())
        .filter(|p| !p.is_empty())
    {
        match part.as_str() {
            "cmd" | "command" | "ctrl" | "control" => mods.push("Control"),
            "shift" => mods.push("Shift"),
            "alt" | "option" | "opt" => mods.push("Alt"),
            "super" | "win" | "meta" => mods.push("Super"),
            k if key.is_none() => key = Some(key_name(k)?),
            _ => return None,
        }
    }
    let key = key?;
    // A bare key would swallow normal typing everywhere; Print Screen alone is the exception.
    if mods.is_empty() && key != "PrintScreen" {
        return None;
    }
    mods.dedup();
    Some(
        mods.into_iter()
            .chain(std::iter::once(key.as_str()))
            .collect::<Vec<_>>()
            .join("+"),
    )
}

fn key_name(k: &str) -> Option<String> {
    let named = match k {
        "space" => "Space",
        "return" | "enter" => "Enter",
        "escape" | "esc" => "Escape",
        "tab" => "Tab",
        "printscreen" | "prtsc" | "print" => "PrintScreen",
        _ => "",
    };
    if !named.is_empty() {
        return Some(named.into());
    }
    if k.len() == 1 && k.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Some(k.to_uppercase());
    }
    if let Some(n) = k
        .strip_prefix('f')
        .and_then(|n| n.parse::<u8>().ok())
        .filter(|n| (1..=24).contains(n))
    {
        return Some(format!("F{n}"));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accelerators() {
        assert_eq!(
            accelerator("ctrl+shift+s").as_deref(),
            Some("Control+Shift+S")
        );
        assert_eq!(
            accelerator("cmd+option+2").as_deref(),
            Some("Control+Alt+2")
        );
        assert_eq!(accelerator("super+f5").as_deref(), Some("Super+F5"));
        assert_eq!(accelerator("printscreen").as_deref(), Some("PrintScreen"));
        assert_eq!(accelerator("a"), None, "a bare key would swallow typing");
        assert_eq!(accelerator("ctrl+ab"), None);
        assert_eq!(accelerator(""), None);
    }

    #[test]
    fn partial_files_keep_defaults_and_round_trip() {
        let dir = std::env::temp_dir().join(format!("shotate-test-{}", std::process::id()));
        let file = dir.join("config.json");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&file, r#"{"shortcuts": {"captureScreen": "CTRL+SHIFT+9", "captureWindow": "nonsense"}, "extra": 1}"#).unwrap();
        let c = load(&file).unwrap().unwrap();
        assert_eq!(
            c.shortcuts["captureArea"], "ctrl+shift+s",
            "unnamed shortcuts keep their defaults"
        );
        assert_eq!(c.shortcuts["captureScreen"], "ctrl+shift+9");
        assert_eq!(c.shortcuts["captureWindow"], "");
        assert!(c.copy_on_capture);
        save(&file, &c).unwrap();
        assert_eq!(load(&file).unwrap().unwrap(), c);
        std::fs::write(&file, "{ not json").unwrap();
        assert!(load(&file).is_err());
        assert_eq!(load(&dir.join("missing.json")).unwrap(), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn adopts_the_snapmark_config_once() {
        let dir = std::env::temp_dir().join(format!("shotate-adopt-{}", std::process::id()));
        let (old, new) = (
            dir.join("snapmark/config.json"),
            dir.join("shotate/config.json"),
        );
        assert!(!adopt_legacy(&old, &new), "nothing to adopt");
        std::fs::create_dir_all(old.parent().unwrap()).unwrap();
        std::fs::write(&old, r#"{"copyOnCapture": false}"#).unwrap();
        assert!(adopt_legacy(&old, &new));
        assert!(!load(&new).unwrap().unwrap().copy_on_capture);
        std::fs::write(&new, "{}").unwrap();
        assert!(!adopt_legacy(&old, &new), "an existing Shotate config wins");
        assert!(old.exists(), "the old file stays");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn opened_images_are_never_overwritten() {
        let dir = std::env::temp_dir().join(format!("shotate-out-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let shot = dir.join("shot.png");
        assert_eq!(output_path(&shot, true), shot);
        let first = output_path(&shot, false);
        assert!(first.ends_with("shot (edited).png"));
        std::fs::write(&first, b"x").unwrap();
        assert!(output_path(&shot, false).ends_with("shot (edited) 2.png"));
        std::fs::remove_dir_all(&dir).ok();
    }
}
