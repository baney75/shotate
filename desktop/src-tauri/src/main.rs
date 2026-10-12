// No console window on Windows release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    #[cfg(target_os = "linux")]
    webkit_safe_rendering();
    shotate_lib::run()
}

/// WebKitGTK aborts at startup when the system has no OpenGL ES library (virtual machines, some
/// minimal installs), and its DMA-BUF renderer shows blank windows on some NVIDIA and Wayland
/// setups. Pick the safe paths before the first window exists. A variable the user already set wins.
#[cfg(target_os = "linux")]
fn webkit_safe_rendering() {
    let set_default = |key: &str| {
        if std::env::var_os(key).is_none() {
            std::env::set_var(key, "1");
        }
    };
    set_default("WEBKIT_DISABLE_DMABUF_RENDERER");
    if !has_library("libGLESv2.so.2") {
        set_default("WEBKIT_DISABLE_COMPOSITING_MODE");
    }
}

#[cfg(target_os = "linux")]
fn has_library(name: &str) -> bool {
    let roots = ["/usr/lib", "/usr/lib64", "/lib", "/lib64", "/usr/local/lib"];
    roots.iter().any(|root| {
        let root = std::path::Path::new(root);
        root.join(name).exists()
            || std::fs::read_dir(root)
                .map(|dirs| dirs.flatten().any(|d| d.path().join(name).exists()))
                .unwrap_or(false)
    })
}
