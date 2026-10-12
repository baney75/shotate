//! Bakes what this build knows about itself into the binary, for the updater and About:
//! SHOTATE_COMMIT, SHOTATE_CHANNEL and SHOTATE_BUILD_DATE. CI sets them; a local build reads git.

use std::process::Command;

fn main() {
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_default();
    let commit = env("SHOTATE_COMMIT")
        .or_else(|| git(&["rev-parse", "HEAD"]))
        .unwrap_or_else(|| "unknown".into());
    // Stable only when HEAD is exactly the release tag for this version.
    let channel = env("SHOTATE_CHANNEL").unwrap_or_else(|| {
        let tag = format!("v{version}");
        let tagged = git(&["tag", "--points-at", "HEAD"])
            .is_some_and(|tags| tags.lines().any(|t| t.trim() == tag));
        if tagged { "stable" } else { "nightly" }.into()
    });
    let date = env("SHOTATE_BUILD_DATE").unwrap_or_else(now_utc);

    println!("cargo:rustc-env=SHOTATE_COMMIT={commit}");
    println!("cargo:rustc-env=SHOTATE_CHANNEL={channel}");
    println!("cargo:rustc-env=SHOTATE_BUILD_DATE={date}");
    for var in ["SHOTATE_COMMIT", "SHOTATE_CHANNEL", "SHOTATE_BUILD_DATE"] {
        println!("cargo:rerun-if-env-changed={var}");
    }
    // A new commit or tag rebuilds the metadata.
    if let Some(git_dir) = git(&["rev-parse", "--absolute-git-dir"]) {
        for p in ["HEAD", "refs/tags", "packed-refs"] {
            println!("cargo:rerun-if-changed={git_dir}/{p}");
        }
        if let Some(head) = git(&["symbolic-ref", "-q", "HEAD"]) {
            println!("cargo:rerun-if-changed={git_dir}/{head}");
        }
    }

    tauri_build::build()
}

fn env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    let text = String::from_utf8(out.stdout).ok()?.trim().to_string();
    (out.status.success() && !text.is_empty()).then_some(text)
}

/// The current time as "2026-10-11T18:00:00Z", without a date crate in the build script.
fn now_utc() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}
