//! Filesystem paths the dispatch binary needs to locate at runtime.
//!
//! All helpers are pure stdlib — no env-crate, no dirs-crate.

use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use nix::unistd::Uid;

/// Resolve `$XDG_RUNTIME_DIR`, falling back to `/run/user/<uid>` (which is
/// what GNOME on Ubuntu actually populates), and finally `/tmp` if even
/// that's missing. Mirrors the bash `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}`
/// idiom.
pub fn xdg_runtime_dir() -> PathBuf {
    if let Ok(dir) = env::var("XDG_RUNTIME_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    let uid = Uid::current().as_raw();
    let candidate = PathBuf::from(format!("/run/user/{uid}"));
    if candidate.is_dir() {
        return candidate;
    }
    PathBuf::from("/tmp")
}

/// Path to the recursion-guard lock file. Matches the bash script's
/// `RECURSION_LOCK="${XDG_RUNTIME_DIR:-/tmp}/tmux-paste-dispatch.lock"`.
pub fn recursion_lock_path() -> PathBuf {
    xdg_runtime_dir().join("tmux-paste-dispatch.lock")
}

/// `~/Pictures/Screenshots`. Mirrors the bash `_early_ss_dir`.
pub fn screenshots_dir() -> Option<PathBuf> {
    let home = env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Pictures").join("Screenshots"))
}

/// Scan `/run/user/<uid>/` for the live kitty IPC socket (`kitty-main-*`).
///
/// The bash script globs `for sock_path in /run/user/$(id -u)/kitty-main-*`
/// and takes the first socket it finds. We do the same: read_dir + filter
/// by prefix + check it's actually a socket via `file_type().is_socket()`.
pub fn kitty_socket() -> Option<PathBuf> {
    let dir = xdg_runtime_dir();
    let entries = fs::read_dir(&dir).ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        if !name_str.starts_with("kitty-main-") {
            continue;
        }
        // file_type().is_socket() avoids one extra stat compared to metadata().
        let Ok(ft) = entry.file_type() else { continue };
        use std::os::unix::fs::FileTypeExt;
        if ft.is_socket() {
            return Some(entry.path());
        }
    }
    None
}

/// Default per-invocation log path. Matches the bash script's
/// `~/.local/state/tmux-paste.log` — but the Rust binary writes its own
/// stream to `flashpaste-paste.log` so the two implementations can be
/// compared head-to-head during the Phase 1 cutover.
pub fn default_log_path() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    Path::new(&home)
        .join(".local")
        .join("state")
        .join("flashpaste-paste.log")
}

/// Path for the JSON trace sink. Matches the bash
/// `FLASHPASTE_TRACE_LOG=~/.local/state/flashpaste-trace.jsonl` so the
/// analyzer can group bash and Rust invocations side-by-side.
pub fn default_trace_log_path() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    Path::new(&home)
        .join(".local")
        .join("state")
        .join("flashpaste-trace.jsonl")
}

/// Locate the bash dispatcher used as the durable fallback when a Rust fast
/// path declines or fails.
///
/// Source installs historically ship `tmux-paste-dispatch.sh` under
/// `~/.local/bin`; distro packages strip the suffix and install
/// `tmux-paste-dispatch` under `/usr/bin`. Prefer explicit override, then
/// PATH, then the known install locations.
pub fn bash_dispatcher_path() -> Option<PathBuf> {
    if let Ok(path) = env::var("FLASHPASTE_BASH_FALLBACK") {
        if !path.is_empty() {
            let candidate = PathBuf::from(path);
            if is_executable_file(&candidate) {
                return Some(candidate);
            }
        }
    }

    find_on_path(&["tmux-paste-dispatch", "tmux-paste-dispatch.sh"]).or_else(|| {
        let mut candidates = Vec::new();
        if let Some(home) = env::var_os("HOME") {
            let local_bin = PathBuf::from(home).join(".local").join("bin");
            candidates.push(local_bin.join("tmux-paste-dispatch"));
            candidates.push(local_bin.join("tmux-paste-dispatch.sh"));
        }
        candidates.push(PathBuf::from("/usr/bin/tmux-paste-dispatch"));
        candidates
            .into_iter()
            .find(|candidate| is_executable_file(candidate))
    })
}

/// Locate the legacy kitty fallback helper.
///
/// Package installs keep this under `/usr/share/flashpaste/paste_image.sh`;
/// source installs historically symlink it at `~/paste_image.sh`. Keep both
/// layouts valid behind one resolver so snippets can ask `flashpaste paths`
/// instead of guessing install roots themselves.
pub fn paste_image_path() -> Option<PathBuf> {
    if let Ok(path) = env::var("FLASHPASTE_PASTE_IMAGE") {
        if !path.is_empty() {
            let candidate = PathBuf::from(path);
            if is_executable_file(&candidate) {
                return Some(candidate);
            }
        }
    }

    find_on_path(&["paste_image.sh"]).or_else(|| {
        let mut candidates = Vec::new();
        if let Some(home) = env::var_os("HOME") {
            let home = PathBuf::from(home);
            candidates.push(home.join("paste_image.sh"));
            candidates.push(
                home.join(".local")
                    .join("share")
                    .join("flashpaste")
                    .join("bin")
                    .join("paste_image.sh"),
            );
        }
        candidates.push(PathBuf::from("/usr/share/flashpaste/paste_image.sh"));
        candidates
            .into_iter()
            .find(|candidate| is_executable_file(candidate))
    })
}

/// FlashPaste ships systemd user units, never system services.
pub fn systemd_unit_mode() -> &'static str {
    "user"
}

fn find_on_path(names: &[&str]) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        for name in names {
            let candidate = dir.join(name);
            if is_executable_file(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

fn is_executable_file(path: &Path) -> bool {
    fs::metadata(path)
        .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct EnvSnapshot {
        vars: Vec<(&'static str, Option<OsString>)>,
    }

    impl EnvSnapshot {
        fn capture(vars: &[&'static str]) -> Self {
            Self {
                vars: vars.iter().map(|name| (*name, env::var_os(name))).collect(),
            }
        }
    }

    impl Drop for EnvSnapshot {
        fn drop(&mut self) {
            for (name, value) in &self.vars {
                match value {
                    Some(value) => env::set_var(name, value),
                    None => env::remove_var(name),
                }
            }
        }
    }

    fn temp_root(name: &str) -> PathBuf {
        let root = env::temp_dir().join(format!("flashpaste-paths-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn write_executable(path: &Path) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn resolves_source_install_script_fallback() {
        let _guard = env_lock().lock().unwrap();
        let _env = EnvSnapshot::capture(&["FLASHPASTE_BASH_FALLBACK", "HOME", "PATH"]);
        let root = temp_root("source-script");
        let home = root.join("home");
        let empty_path = root.join("empty-path");
        let dispatcher = home
            .join(".local")
            .join("bin")
            .join("tmux-paste-dispatch.sh");
        fs::create_dir_all(&empty_path).unwrap();
        write_executable(&dispatcher);

        env::remove_var("FLASHPASTE_BASH_FALLBACK");
        env::set_var("HOME", &home);
        env::set_var("PATH", &empty_path);

        assert_eq!(
            bash_dispatcher_path().as_deref(),
            Some(dispatcher.as_path())
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn prefers_extensionless_package_dispatcher_on_path() {
        let _guard = env_lock().lock().unwrap();
        let _env = EnvSnapshot::capture(&["FLASHPASTE_BASH_FALLBACK", "HOME", "PATH"]);
        let root = temp_root("package-layout");
        let bin = root.join("bin");
        let extensionless = bin.join("tmux-paste-dispatch");
        write_executable(&extensionless);
        write_executable(&bin.join("tmux-paste-dispatch.sh"));

        env::remove_var("FLASHPASTE_BASH_FALLBACK");
        env::set_var("HOME", root.join("home"));
        env::set_var("PATH", &bin);

        assert_eq!(
            bash_dispatcher_path().as_deref(),
            Some(extensionless.as_path())
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn paste_image_override_resolves_helper_contract() {
        let _guard = env_lock().lock().unwrap();
        let _env = EnvSnapshot::capture(&["FLASHPASTE_PASTE_IMAGE", "HOME", "PATH"]);
        let root = temp_root("paste-image");
        let helper = root.join("share").join("flashpaste").join("paste_image.sh");
        let empty_path = root.join("empty-path");
        fs::create_dir_all(&empty_path).unwrap();
        write_executable(&helper);

        env::set_var("FLASHPASTE_PASTE_IMAGE", &helper);
        env::set_var("HOME", root.join("home"));
        env::set_var("PATH", &empty_path);

        assert_eq!(paste_image_path().as_deref(), Some(helper.as_path()));
        let _ = fs::remove_dir_all(root);
    }
}
