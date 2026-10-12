//! Update checks for the stable and nightly channels. A check is one HTTPS GET of the channel's
//! manifest.json from GitHub releases (no API, no identifiers, no cookies). An update installs the
//! same way the app was installed: the Windows setup, an AppImage swapped in place, or the .deb or
//! .rpm through pkexec. Anything else opens the release page.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

pub const STABLE_MANIFEST: &str =
    "https://github.com/baney75/shotate/releases/latest/download/manifest.json";
pub const NIGHTLY_MANIFEST: &str =
    "https://github.com/baney75/shotate/releases/download/nightly/manifest.json";
pub const RELEASES_PAGE: &str = "https://github.com/baney75/shotate/releases";

/// The largest installer Shotate will download.
const MAX_DOWNLOAD: u64 = 512 * 1024 * 1024;

/// What this build knows about itself, baked in by build.rs.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Build {
    pub version: String,
    pub commit: String,
    pub channel: String,
    pub date: String,
}

impl Build {
    pub fn current() -> Build {
        Build {
            version: env!("CARGO_PKG_VERSION").into(),
            commit: env!("SHOTATE_COMMIT").into(),
            channel: env!("SHOTATE_CHANNEL").into(),
            date: env!("SHOTATE_BUILD_DATE").into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Asset {
    pub name: String,
    pub url: String,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    pub channel: String,
    pub version: String,
    pub commit: String,
    pub date: String,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub assets: BTreeMap<String, Asset>,
}

impl Manifest {
    /// The release notes link, or the releases page when the manifest's link isn't https.
    pub fn notes_url(&self) -> String {
        if self.notes.starts_with("https://") {
            self.notes.clone()
        } else {
            RELEASES_PAGE.into()
        }
    }
}

/// Why a manifest is worth offering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Offer {
    /// A newer build on the channel this build already follows.
    Update,
    /// A nightly build moving to the stable channel ("Switch to Stable X.Y.Z").
    SwitchToStable,
}

/// The channel Windows and Linux follow. Stable releases are macOS only for now (the platform each
/// release is tested on), so these builds are nightly previews whatever the config file says.
pub const CHANNEL: &str = "nightly";

pub fn manifest_url(channel: &str) -> &'static str {
    if channel == "nightly" {
        NIGHTLY_MANIFEST
    } else {
        STABLE_MANIFEST
    }
}

/// The decision rule, shared with the macOS app. `channel` is the channel the user selected.
pub fn offer(local: &Build, remote: &Manifest, channel: &str) -> Option<Offer> {
    if remote.channel != channel {
        return None;
    }
    // An empty or "unknown" local commit (a build without git) never matches.
    let known = !local.commit.is_empty() && !local.commit.eq_ignore_ascii_case("unknown");
    if known && remote.commit.eq_ignore_ascii_case(&local.commit) {
        return None;
    }
    match channel {
        // By date, so a stable installed after the last nightly is never "downgraded".
        "nightly" => match (parse_date(&remote.date), parse_date(&local.date)) {
            (Some(r), Some(l)) if r > l => Some(Offer::Update),
            _ => None,
        },
        "stable" if local.channel == "nightly" => Some(Offer::SwitchToStable),
        "stable" => (compare_versions(&remote.version, &local.version) == Some(Ordering::Greater))
            .then_some(Offer::Update),
        _ => None,
    }
}

fn parse_date(s: &str) -> Option<chrono::DateTime<chrono::FixedOffset>> {
    chrono::DateTime::parse_from_rfc3339(s.trim()).ok()
}

#[derive(Debug, PartialEq, Eq)]
enum Ident {
    Num(u64),
    Text(String),
}

/// "0.12.1-nightly.20261011+build" → ((0, 12, 1), [Text("nightly"), Num(20261011)]). Build metadata
/// (after "+") is ignored, as semver says.
fn parse_version(s: &str) -> Option<([u64; 3], Vec<Ident>)> {
    let s = s.trim().trim_start_matches('v');
    let s = s.split('+').next()?;
    let (core, pre) = match s.split_once('-') {
        Some((c, p)) => (c, Some(p)),
        None => (s, None),
    };
    let mut nums = core.split('.').map(|n| n.parse::<u64>().ok());
    let v = [nums.next()??, nums.next()??, nums.next()??];
    if nums.next().is_some() {
        return None;
    }
    let pre = match pre {
        None => Vec::new(),
        Some("") => return None,
        Some(p) => p
            .split('.')
            .map(|i| match i.parse::<u64>() {
                Ok(n) if i.bytes().all(|b| b.is_ascii_digit()) => Ident::Num(n),
                _ => Ident::Text(i.to_string()),
            })
            .collect(),
    };
    Some((v, pre))
}

/// Semver precedence: numeric X.Y.Z first; a prerelease is lower than the same X.Y.Z release;
/// prereleases compare field by field (numbers numerically, so nightly.YYYYMMDD goes by date).
/// None when either side isn't a version.
pub fn compare_versions(a: &str, b: &str) -> Option<Ordering> {
    let (av, ap) = parse_version(a)?;
    let (bv, bp) = parse_version(b)?;
    Some(
        av.cmp(&bv)
            .then_with(|| match (ap.is_empty(), bp.is_empty()) {
                (true, true) => Ordering::Equal,
                (true, false) => Ordering::Greater,
                (false, true) => Ordering::Less,
                (false, false) => {
                    for (x, y) in ap.iter().zip(&bp) {
                        let o = match (x, y) {
                            (Ident::Num(x), Ident::Num(y)) => x.cmp(y),
                            (Ident::Num(_), Ident::Text(_)) => Ordering::Less,
                            (Ident::Text(_), Ident::Num(_)) => Ordering::Greater,
                            (Ident::Text(x), Ident::Text(y)) => x.cmp(y),
                        };
                        if o != Ordering::Equal {
                            return o;
                        }
                    }
                    ap.len().cmp(&bp.len())
                }
            }),
    )
}

// MARK: - Network

fn agent(whole: Duration) -> ureq::Agent {
    ureq::Agent::config_builder()
        .https_only(true)
        .user_agent("Shotate")
        .timeout_connect(Some(Duration::from_secs(20)))
        .timeout_global(Some(whole))
        .build()
        .into()
}

pub fn fetch_manifest(channel: &str) -> Result<Manifest, String> {
    let text = agent(Duration::from_secs(30))
        .get(manifest_url(channel))
        .call()
        .map_err(|e| format!("Couldn't reach GitHub: {e}"))?
        .body_mut()
        .with_config()
        .limit(1024 * 1024)
        .read_to_string()
        .map_err(|e| format!("Couldn't read the update information: {e}"))?;
    serde_json::from_str(&text).map_err(|e| format!("The update information is malformed: {e}"))
}

#[cfg(test)]
fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Downloads `asset` to `dest`, checking its sha256 on the way. A file that doesn't match is
/// deleted and never run.
pub fn download(asset: &Asset, dest: &Path) -> Result<(), String> {
    let expected = asset.sha256.trim().to_lowercase();
    if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(format!(
            "{} has no valid checksum in the manifest",
            asset.name
        ));
    }
    let mut response = agent(Duration::from_secs(30 * 60))
        .get(&asset.url)
        .call()
        .map_err(|e| format!("Couldn't download {}: {e}", asset.name))?;
    let mut reader = response
        .body_mut()
        .with_config()
        .limit(MAX_DOWNLOAD)
        .reader();
    let result = (|| {
        let mut file =
            std::fs::File::create(dest).map_err(|e| format!("{}: {e}", dest.display()))?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = reader
                .read(&mut buf)
                .map_err(|e| format!("Couldn't download {}: {e}", asset.name))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            file.write_all(&buf[..n])
                .map_err(|e| format!("{}: {e}", dest.display()))?;
        }
        file.sync_all()
            .map_err(|e| format!("{}: {e}", dest.display()))?;
        let got = hex(&hasher.finalize());
        if got != expected {
            return Err(format!(
                "{} failed its checksum (expected {expected}, got {got}), so Shotate won't install it.",
                asset.name
            ));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(dest);
    }
    result
}

// MARK: - Installing

/// How this copy of Shotate was installed, which decides how it updates.
#[derive(Debug, Clone, PartialEq)]
pub enum Route {
    WindowsSetup,
    AppImage(PathBuf),
    Deb,
    Rpm,
    /// Unknown install (a dev build, a tarball): open the release page.
    ReleasePage,
}

/// The manifest asset for this route on this CPU, e.g. "linux-arm64-deb".
pub fn asset_key(route: &Route, arch: &str) -> Option<String> {
    let arch = match arch {
        "x86_64" => "x64",
        "aarch64" => "arm64",
        _ => return None,
    };
    match route {
        Route::WindowsSetup if arch == "x64" => Some("windows-x64".into()),
        Route::AppImage(_) => Some(format!("linux-{arch}-appimage")),
        Route::Deb => Some(format!("linux-{arch}-deb")),
        Route::Rpm => Some(format!("linux-{arch}-rpm")),
        _ => None,
    }
}

pub fn detect_route() -> Route {
    if cfg!(windows) {
        return Route::WindowsSetup;
    }
    if !cfg!(target_os = "linux") {
        return Route::ReleasePage;
    }
    if let Some(p) = std::env::var_os("APPIMAGE").filter(|p| !p.is_empty()) {
        return Route::AppImage(PathBuf::from(p));
    }
    let Ok(exe) = std::env::current_exe() else {
        return Route::ReleasePage;
    };
    if !exe.starts_with("/usr") {
        return Route::ReleasePage;
    }
    let owns = |cmd: &str, args: &[&str]| {
        Command::new(cmd)
            .args(args)
            .arg(&exe)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    };
    if owns(DPKG_QUERY, &["-S"]) {
        Route::Deb
    } else if owns(RPM, &["-qf"]) {
        Route::Rpm
    } else {
        Route::ReleasePage
    }
}

/// What the caller does after `install` succeeds.
#[derive(Debug, PartialEq)]
pub enum Installed {
    /// The new version is installed or installing and will start on its own: quit now.
    Quit,
    /// Shotate can't update itself here: show this page instead.
    OpenPage(String),
}

pub fn install(manifest: &Manifest, route: &Route) -> Result<Installed, String> {
    let page = Installed::OpenPage(manifest.notes_url());
    let Some(asset) =
        asset_key(route, std::env::consts::ARCH).and_then(|k| manifest.assets.get(&k).cloned())
    else {
        return Ok(page);
    };
    // Only the file name, never a path from the manifest.
    let name = Path::new(&asset.name)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| !n.is_empty())
        .ok_or("the manifest names no installer file")?;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    match route {
        Route::WindowsSetup => {
            let Some(powershell) = windows_powershell().filter(|p| p.is_file()) else {
                return Ok(page);
            };
            let dir = private_dir()?;
            // A fixed name: nothing from the manifest reaches the command line.
            let setup = dir.join(WINDOWS_SETUP_NAME);
            if let Err(e) = download(&asset, &setup) {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(e);
            }
            if let Err(e) = spawn_windows_setup(&powershell, &dir, &setup, &exe) {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(e);
            }
            Ok(Installed::Quit)
        }
        Route::AppImage(target) => {
            let dir = target.parent().ok_or("the AppImage has no folder")?;
            let partial = dir.join(format!(".{name}.{}.part", std::process::id()));
            download(&asset, &partial)?;
            let swap = (|| {
                set_executable(&partial)?;
                // Same folder, so the rename is atomic: the old AppImage or the new, never half.
                std::fs::rename(&partial, target).map_err(|e| format!("{}: {e}", target.display()))
            })();
            if swap.is_err() {
                let _ = std::fs::remove_file(&partial);
            }
            swap?;
            relaunch_after_exit(target)?;
            Ok(Installed::Quit)
        }
        Route::Deb | Route::Rpm => {
            let tool = if *route == Route::Rpm { RPM } else { APT_GET };
            if !Path::new(PKEXEC).is_file() || !Path::new(tool).is_file() {
                return Ok(page);
            }
            let dir = private_dir()?;
            let file = dir.join(&name);
            if let Err(e) = download(&asset, &file) {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(e);
            }
            let status = Command::new(PKEXEC)
                .args(package_command(route, &file))
                .status()
                .map_err(|e| format!("Couldn't run pkexec: {e}"));
            let _ = std::fs::remove_dir_all(&dir);
            match status?.code() {
                Some(0) => {}
                Some(126) | Some(127) => return Err("The update was cancelled.".into()),
                code => {
                    return Err(format!(
                        "The package manager couldn't install the update (exit {}).",
                        code.map_or("signal".into(), |c| c.to_string())
                    ))
                }
            }
            relaunch_after_exit(&exe)?;
            Ok(Installed::Quit)
        }
        Route::ReleasePage => Ok(page),
    }
}

/// System tools run by absolute path, so nothing on PATH can stand in for them.
const PKEXEC: &str = "/usr/bin/pkexec";
const APT_GET: &str = "/usr/bin/apt-get";
const RPM: &str = "/usr/bin/rpm";
const DPKG_QUERY: &str = "/usr/bin/dpkg-query";

/// The pkexec arguments for a package. Nightly packages carry plain X.Y.Z versions, so the same
/// version may need installing again (`--reinstall`, `--replacepkgs`), and moving from nightly to
/// stable can be a downgrade. rpm directly works on both dnf and zypper systems.
pub fn package_command(route: &Route, file: &Path) -> Vec<String> {
    let args: &[&str] = match route {
        Route::Rpm => &[RPM, "-U", "--oldpackage", "--replacepkgs"],
        _ => &[
            APT_GET,
            "install",
            "-y",
            "--reinstall",
            "--allow-downgrades",
        ],
    };
    args.iter()
        .map(|s| s.to_string())
        .chain([file.to_string_lossy().into_owned()])
        .collect()
}

/// A folder only this user can read (0700 on Linux). Not deleted on drop: the caller removes it
/// (on Windows the installer script does, after the setup has run).
fn private_dir() -> Result<PathBuf, String> {
    tempfile::Builder::new()
        .prefix("shotate-update-")
        .tempdir()
        .map(|d| d.keep())
        .map_err(|e| e.to_string())
}

#[cfg(unix)]
fn set_executable(p: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755))
        .map_err(|e| format!("{}: {e}", p.display()))
}

#[cfg(not(unix))]
fn set_executable(_: &Path) -> Result<(), String> {
    Ok(())
}

/// Starts `exe` once this process has exited (the single-instance lock would otherwise hand the
/// launch straight back to us). Runs in its own process group, so it outlives Shotate.
#[cfg(unix)]
fn relaunch_after_exit(exe: &Path) -> Result<(), String> {
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new("/bin/sh");
    cmd.args([
        "-c",
        r#"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec "$0""#,
    ])
    .arg(exe)
    .arg(std::process::id().to_string())
    .stdin(Stdio::null())
    .stdout(Stdio::null())
    .stderr(Stdio::null())
    .process_group(0);
    // An AppImage's runtime points variables into its own mount, which goes away when we quit.
    if let Some(appdir) = std::env::var_os("APPDIR").filter(|d| !d.is_empty()) {
        let appdir = appdir.to_string_lossy().into_owned();
        for (k, v) in std::env::vars_os() {
            let runtime = ["APPDIR", "APPIMAGE", "ARGV0", "OWD"]
                .iter()
                .any(|n| k == *n);
            if runtime || v.to_string_lossy().contains(&appdir) {
                cmd.env_remove(&k);
            }
        }
    }
    cmd.spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[cfg(not(unix))]
fn relaunch_after_exit(exe: &Path) -> Result<(), String> {
    Command::new(exe)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// The name the Windows setup is saved under, whatever the manifest calls it.
const WINDOWS_SETUP_NAME: &str = "Shotate-setup.exe";

/// The PowerShell that runs the setup silently, deletes its folder, then starts the new Shotate.
/// It is constant: paths reach it only through environment variables, never as script text.
#[cfg_attr(not(windows), allow(dead_code))]
const WINDOWS_SCRIPT: &str = "try { Start-Process -Wait -FilePath $env:SHOTATE_SETUP -ArgumentList '/S' } \
     finally { Remove-Item -LiteralPath $env:SHOTATE_UPDATE_DIR -Recurse -Force -ErrorAction SilentlyContinue }; \
     Start-Process -FilePath $env:SHOTATE_EXE";

/// %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
fn windows_powershell() -> Option<PathBuf> {
    let root = std::env::var_os("SystemRoot").filter(|r| !r.is_empty())?;
    Some(
        PathBuf::from(root)
            .join("System32")
            .join("WindowsPowerShell")
            .join("v1.0")
            .join("powershell.exe"),
    )
}

#[cfg(windows)]
fn spawn_windows_setup(
    powershell: &Path,
    dir: &Path,
    setup: &Path,
    exe: &Path,
) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    Command::new(powershell)
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            WINDOWS_SCRIPT,
        ])
        .env("SHOTATE_SETUP", setup)
        .env("SHOTATE_UPDATE_DIR", dir)
        .env("SHOTATE_EXE", exe)
        .creation_flags(CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Couldn't start the installer: {e}"))
}

#[cfg(not(windows))]
fn spawn_windows_setup(_: &Path, _: &Path, _: &Path, _: &Path) -> Result<(), String> {
    Err("the Windows installer only runs on Windows".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build(version: &str, commit: &str, channel: &str, date: &str) -> Build {
        Build {
            version: version.into(),
            commit: commit.into(),
            channel: channel.into(),
            date: date.into(),
        }
    }

    fn manifest(version: &str, commit: &str, channel: &str, date: &str) -> Manifest {
        Manifest {
            channel: channel.into(),
            version: version.into(),
            commit: commit.into(),
            date: date.into(),
            notes: "https://github.com/baney75/shotate/releases/tag/v0.12.1".into(),
            assets: BTreeMap::new(),
        }
    }

    const D1: &str = "2026-10-10T06:17:00Z";
    const D2: &str = "2026-10-11T06:17:00Z";

    #[test]
    fn stable_offers_a_newer_version_only() {
        let local = build("0.12.0", "aaa", "stable", D1);
        let newer = manifest("0.12.1", "bbb", "stable", D2);
        assert_eq!(offer(&local, &newer, "stable"), Some(Offer::Update));
        let same = manifest("0.12.0", "ccc", "stable", D2);
        assert_eq!(offer(&local, &same, "stable"), None);
        let older = manifest("0.11.9", "ddd", "stable", D2);
        assert_eq!(offer(&local, &older, "stable"), None);
        let minor = manifest("0.13.0", "eee", "stable", D1);
        assert_eq!(offer(&local, &minor, "stable"), Some(Offer::Update));
    }

    #[test]
    fn the_same_commit_is_never_an_update() {
        let local = build("0.12.0", "ABC123", "stable", D1);
        assert_eq!(
            offer(
                &local,
                &manifest("0.13.0", "abc123", "stable", D2),
                "stable"
            ),
            None
        );
        let nightly = build("0.12.1+nightly.202610100617", "abc", "nightly", D1);
        let remote = manifest("0.12.1+nightly.202610110617", "abc", "nightly", D2);
        assert_eq!(offer(&nightly, &remote, "nightly"), None);
    }

    #[test]
    fn nightly_goes_by_build_date() {
        let local = build("0.12.1+nightly.202610100617", "aaa", "nightly", D1);
        let newer = manifest("0.12.1+nightly.202610110617", "bbb", "nightly", D2);
        assert_eq!(offer(&local, &newer, "nightly"), Some(Offer::Update));
        let older = manifest(
            "0.12.1+nightly.202610090617",
            "ccc",
            "nightly",
            "2026-10-09T06:17:00Z",
        );
        assert_eq!(offer(&local, &older, "nightly"), None);
        // Offsets are honored, not compared as text.
        let same_instant = manifest("x", "ddd", "nightly", "2026-10-10T08:17:00+02:00");
        assert_eq!(offer(&local, &same_instant, "nightly"), None);
    }

    #[test]
    fn a_stable_installed_after_the_last_nightly_is_not_downgraded() {
        let local = build("0.13.0", "aaa", "stable", D2);
        let nightly = manifest("0.13.0+nightly.202610100617", "bbb", "nightly", D1);
        assert_eq!(offer(&local, &nightly, "nightly"), None);
        let next = manifest(
            "0.13.1+nightly.202610120617",
            "ccc",
            "nightly",
            "2026-10-12T06:17:00Z",
        );
        assert_eq!(offer(&local, &next, "nightly"), Some(Offer::Update));
    }

    #[test]
    fn switching_from_nightly_to_stable_is_offered() {
        let local = build("0.12.1+nightly.202610110617", "aaa", "nightly", D2);
        let stable = manifest("0.12.0", "bbb", "stable", D1);
        assert_eq!(
            offer(&local, &stable, "stable"),
            Some(Offer::SwitchToStable)
        );
        let newer = manifest("0.12.1", "ccc", "stable", D2);
        assert_eq!(offer(&local, &newer, "stable"), Some(Offer::SwitchToStable));
        // Already on that exact commit: nothing to switch to.
        let same = manifest("0.12.0", "aaa", "stable", D1);
        assert_eq!(offer(&local, &same, "stable"), None);
        // A nightly build when stable 0.13.0 is published.
        let local = build("0.12.1+nightly.202610110617", "abc", "nightly", D2);
        let published = manifest("0.13.0", "def", "stable", D2);
        assert_eq!(
            offer(&local, &published, "stable"),
            Some(Offer::SwitchToStable)
        );
    }

    #[test]
    fn an_unknown_local_commit_never_matches() {
        let local = build("0.12.0", "unknown", "stable", D1);
        let remote = manifest("0.12.1", "unknown", "stable", D2);
        assert_eq!(offer(&local, &remote, "stable"), Some(Offer::Update));
        let local = build("0.12.0", "", "stable", D1);
        let remote = manifest("0.12.1", "", "stable", D2);
        assert_eq!(offer(&local, &remote, "stable"), Some(Offer::Update));
    }

    #[test]
    fn nightly_without_a_local_date_never_offers() {
        let local = build("0.12.1", "aaa", "nightly", "");
        assert_eq!(
            offer(&local, &manifest("x", "bbb", "nightly", D2), "nightly"),
            None
        );
    }

    #[test]
    fn windows_and_linux_follow_nightly() {
        // Stable releases are macOS only; these builds must never check the stable manifest.
        assert_eq!(CHANNEL, "nightly");
        assert!(manifest_url(CHANNEL).ends_with("/releases/download/nightly/manifest.json"));
    }

    #[test]
    fn a_manifest_for_another_channel_is_ignored() {
        let local = build("0.12.0", "aaa", "stable", D1);
        let nightly = manifest("0.12.1+nightly.202610110617", "bbb", "nightly", D2);
        assert_eq!(offer(&local, &nightly, "stable"), None);
        let stable = manifest("0.13.0", "ccc", "stable", D2);
        assert_eq!(offer(&local, &stable, "nightly"), None);
        assert_eq!(offer(&local, &stable, "beta"), None);
    }

    #[test]
    fn semver_with_prereleases_and_build_metadata() {
        use Ordering::*;
        let cmp = |a, b| compare_versions(a, b).unwrap();
        assert_eq!(cmp("0.12.1", "0.12.0"), Greater);
        assert_eq!(cmp("0.12.0", "0.12.0"), Equal);
        assert_eq!(cmp("0.10.0", "0.9.9"), Greater, "numeric, not text");
        assert_eq!(cmp("1.0.0", "0.99.99"), Greater);
        assert_eq!(cmp("v0.12.0", "0.12.0"), Equal);
        assert_eq!(
            cmp("0.12.1-nightly.20261011", "0.12.1"),
            Less,
            "prerelease below release"
        );
        assert_eq!(cmp("0.12.1-nightly.20261011", "0.12.0"), Greater);
        assert_eq!(
            cmp("0.12.1-nightly.20261011", "0.12.1-nightly.20261009"),
            Greater
        );
        assert_eq!(
            cmp("0.12.1-nightly.20261011", "0.12.1-nightly.9"),
            Greater,
            "dates compare as numbers"
        );
        assert_eq!(cmp("1.0.0-alpha", "1.0.0-alpha.1"), Less);
        assert_eq!(cmp("1.0.0-alpha.1", "1.0.0-alpha.beta"), Less);
        assert_eq!(cmp("1.0.0-rc.1", "1.0.0-beta.11"), Greater);
        assert_eq!(
            cmp("0.12.1+nightly.202610110617", "0.12.1+nightly.202610100617"),
            Equal,
            "build metadata is ignored"
        );
        assert_eq!(compare_versions("0.12", "0.12.0"), None);
        assert_eq!(compare_versions("nonsense", "0.12.0"), None);
        assert_eq!(compare_versions("0.12.0-", "0.12.0"), None);
    }

    #[test]
    fn unparsable_versions_never_offer() {
        let local = build("0.12.0", "aaa", "stable", D1);
        assert_eq!(
            offer(&local, &manifest("garbage", "bbb", "stable", D2), "stable"),
            None
        );
        let nightly = build("0.12.1", "aaa", "nightly", D1);
        assert_eq!(
            offer(
                &nightly,
                &manifest("x", "bbb", "nightly", "not a date"),
                "nightly"
            ),
            None
        );
    }

    #[test]
    fn manifest_parses_the_spec_format() {
        let text = r#"{"channel":"stable","version":"0.12.0","commit":"0123456789abcdef0123456789abcdef01234567",
            "date":"2026-10-11T18:00:00Z","notes":"https://github.com/baney75/shotate/releases/tag/v0.12.0",
            "assets":{"windows-x64":{"name":"Shotate_0.12.0_x64-setup.exe","url":"https://github.com/x","sha256":"ab"}}}"#;
        let m: Manifest = serde_json::from_str(text).unwrap();
        assert_eq!(m.assets["windows-x64"].name, "Shotate_0.12.0_x64-setup.exe");
        assert_eq!(
            m.notes_url(),
            "https://github.com/baney75/shotate/releases/tag/v0.12.0"
        );
        let bare = Manifest {
            notes: "javascript:alert(1)".into(),
            ..m
        };
        assert_eq!(bare.notes_url(), RELEASES_PAGE);
    }

    #[test]
    fn asset_keys_per_route_and_cpu() {
        assert_eq!(
            asset_key(&Route::WindowsSetup, "x86_64").as_deref(),
            Some("windows-x64")
        );
        assert_eq!(asset_key(&Route::WindowsSetup, "aarch64"), None);
        let appimage = Route::AppImage("/home/me/Shotate.AppImage".into());
        assert_eq!(
            asset_key(&appimage, "aarch64").as_deref(),
            Some("linux-arm64-appimage")
        );
        assert_eq!(
            asset_key(&Route::Deb, "x86_64").as_deref(),
            Some("linux-x64-deb")
        );
        assert_eq!(
            asset_key(&Route::Rpm, "aarch64").as_deref(),
            Some("linux-arm64-rpm")
        );
        assert_eq!(asset_key(&Route::ReleasePage, "x86_64"), None);
        assert_eq!(asset_key(&Route::Deb, "riscv64"), None);
    }

    #[test]
    fn package_commands_reinstall_and_allow_downgrades() {
        let f = Path::new("/tmp/shotate-update-x/Shotate_0.12.0_amd64.deb");
        assert_eq!(
            package_command(&Route::Deb, f),
            [
                "/usr/bin/apt-get",
                "install",
                "-y",
                "--reinstall",
                "--allow-downgrades",
                "/tmp/shotate-update-x/Shotate_0.12.0_amd64.deb"
            ]
        );
        let r = Path::new("/tmp/s/Shotate-0.12.0-1.x86_64.rpm");
        assert_eq!(
            package_command(&Route::Rpm, r),
            [
                "/usr/bin/rpm",
                "-U",
                "--oldpackage",
                "--replacepkgs",
                "/tmp/s/Shotate-0.12.0-1.x86_64.rpm"
            ]
        );
    }

    #[test]
    fn the_windows_script_is_constant() {
        // Paths travel in environment variables; the script text never contains one.
        assert!(!WINDOWS_SCRIPT.contains(":\\"));
        for var in [
            "$env:SHOTATE_SETUP",
            "$env:SHOTATE_UPDATE_DIR",
            "$env:SHOTATE_EXE",
        ] {
            assert!(WINDOWS_SCRIPT.contains(var), "{var}");
        }
        assert!(WINDOWS_SCRIPT.contains("Remove-Item -LiteralPath $env:SHOTATE_UPDATE_DIR"));
        assert_eq!(WINDOWS_SETUP_NAME, "Shotate-setup.exe");
    }

    #[test]
    fn checksums() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("x");
        let bad = Asset {
            name: "x".into(),
            url: "https://example.com/x".into(),
            sha256: "nothex".into(),
        };
        assert!(
            download(&bad, &dest).is_err(),
            "a malformed checksum is refused before any download"
        );
        assert!(!dest.exists());
    }

    #[test]
    fn build_metadata_is_baked_in() {
        let b = Build::current();
        assert_eq!(b.version, env!("CARGO_PKG_VERSION"));
        assert!(b.channel == "stable" || b.channel == "nightly");
        assert!(!b.commit.is_empty());
        assert!(
            parse_date(&b.date).is_some(),
            "build date {} is ISO 8601",
            b.date
        );
    }
}
