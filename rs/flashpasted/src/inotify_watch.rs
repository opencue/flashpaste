//! Inotify watcher on `~/Pictures/Screenshots/`.
//!
//! GNOME's PrtScr saves a file but doesn't copy to the clipboard (fact #4
//! from the spec). The bash dispatcher worked around this by polling the
//! dir on every paste. The daemon does it properly: one persistent inotify
//! handle, fires `IN_CLOSE_WRITE` the instant a file is finished writing,
//! reads the bytes into memory, and stages them into both clipboard owners.
//!
//! Why `spawn_blocking` + sync `inotify`:
//!   The sync API is dead simple (an iterator over events). The async API
//!   adds a tokio-stream dependency we don't need. Inotify events are sparse
//!   (one per screenshot), so a dedicated blocking thread is the right shape.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use flashpaste_common::compress;
use inotify::{Inotify, WatchMask};
use tracing::{debug, error, info, warn};

use crate::state::{SharedState, StagedImage};

pub fn spawn_watcher(state: Arc<SharedState>) {
    let Some(dir) = state.config.screenshots_dir.clone() else {
        warn!("no screenshots_dir configured; inotify watcher disabled");
        return;
    };

    // Ensure the directory exists. Don't create it ourselves — that'd hide
    // a config typo. Log and return so the daemon still serves staged data
    // for non-screenshot sources (the `stage` IPC op).
    if !dir.is_dir() {
        warn!(
            path = %dir.display(),
            "screenshots dir doesn't exist; inotify watcher not started"
        );
        return;
    }

    // The actual blocking loop runs on a spawn_blocking thread because the
    // sync `inotify` iterator parks the OS thread on `read`. We bridge back
    // into tokio via `Handle::current().block_on(...)` for the staging
    // write, which is fine — staging is rare (≤1 per screenshot).
    let handle = tokio::runtime::Handle::current();
    tokio::task::spawn_blocking(move || {
        if let Err(e) = run_watcher(state, dir, handle) {
            error!(error = ?e, "inotify watcher exited with error");
        }
    });
}

fn run_watcher(
    state: Arc<SharedState>,
    dir: PathBuf,
    handle: tokio::runtime::Handle,
) -> anyhow::Result<()> {
    let mut inotify = Inotify::init()?;
    // IN_CLOSE_WRITE is the right event: GNOME Screenshot finishes writing
    // the PNG, closes the fd, and we get a single event with the final
    // filename. IN_CREATE would fire too early (before the bytes are flushed).
    // IN_MOVED_TO covers tools that atomic-rename a tempfile into place.
    inotify.watches().add(
        &dir,
        WatchMask::CLOSE_WRITE | WatchMask::MOVED_TO,
    )?;
    info!(
        path = %dir.display(),
        "inotify watcher started on screenshots dir"
    );

    // 64 KiB buffer is overkill for inotify but it's allocated once. Each
    // event is ~16 bytes + the filename.
    let mut buf = [0u8; 65_536];
    loop {
        let events = match inotify.read_events_blocking(&mut buf) {
            Ok(it) => it,
            Err(e) => {
                error!(error = %e, "inotify read failed; retrying in 1s");
                std::thread::sleep(std::time::Duration::from_secs(1));
                continue;
            }
        };

        for event in events {
            let Some(name) = event.name else { continue };
            let path = dir.join(name);
            if !is_image_path(&path) {
                debug!(path = %path.display(), "ignoring non-image inotify event");
                continue;
            }
            // Don't recurse on the compressed siblings we drop next to
            // the original. Their filenames embed `.fpc.` (see
            // `make_compressed_tmp_path`).
            if path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.contains(".fpc."))
            {
                debug!(path = %path.display(), "ignoring compressed-sibling event");
                continue;
            }

            // Auto-compress before staging. The common case (small PNG
            // from PrtScr) is a pure pass-through and is no more expensive
            // than the previous `fs::read` — `compress_for_attach` stats
            // first and only reads if it returns early. The big-screen
            // case (4K multimon → 12 MB PNG) gets re-encoded to ~1 MB
            // WebP. Env-vars `FLASHPASTE_MAX_BYTES` and `FLASHPASTE_MAX_DIM`
            // tune the thresholds.
            //
            // If compression itself errors out we fall back to the raw
            // file — staging *something* is better than staging nothing,
            // and the user can still pick the file up via auto-pickup.
            let (bytes, mime, staged_path) = match compress::compress_for_attach_env(&path) {
                Ok((b, m)) if m == "image/png" || m == "image/jpeg" => {
                    let mime = mime_for_string(&m);
                    (b, mime, path.clone())
                }
                Ok((b, m)) => {
                    // The compressor returned re-encoded bytes (likely
                    // WebP). Write them to a sibling tmpfile so X11
                    // selection requests (which serve from-disk in some
                    // paths) and downstream tools that want a file path
                    // both see the smaller artifact. The original PNG
                    // is left in place — never destroy user data.
                    let tmp = make_compressed_tmp_path(&path, &m);
                    match std::fs::write(&tmp, &b) {
                        Ok(()) => {
                            info!(
                                src = %path.display(),
                                dst = %tmp.display(),
                                bytes = b.len(),
                                mime = %m,
                                "wrote compressed sibling for staging"
                            );
                            let mime = mime_for_string(&m);
                            (b, mime, tmp)
                        }
                        Err(e) => {
                            warn!(
                                path = %tmp.display(),
                                error = %e,
                                "failed to write compressed sibling — staging raw bytes from original path"
                            );
                            let mime = mime_for_string(&m);
                            (b, mime, path.clone())
                        }
                    }
                }
                Err(e) => {
                    warn!(
                        path = %path.display(),
                        error = ?e,
                        "compress_for_attach failed — falling back to raw read"
                    );
                    match std::fs::read(&path) {
                        Ok(b) => (b, mime_for(&path), path.clone()),
                        Err(e2) => {
                            warn!(
                                path = %path.display(),
                                error = %e2,
                                "failed to read new screenshot"
                            );
                            continue;
                        }
                    }
                }
            };
            let len = bytes.len();
            let staged = StagedImage {
                bytes: Arc::new(bytes),
                mime,
                path: staged_path,
                captured_at: SystemTime::now(),
            };
            // Cross thread back into tokio for the write. block_on inside
            // spawn_blocking is fine — we're not on a worker.
            let state_clone = state.clone();
            handle.block_on(async move {
                state_clone.set_staged_image(staged).await;
            });
            info!(
                path = %path.display(),
                bytes = len,
                mime = mime,
                "staged screenshot from inotify"
            );
        }
    }
}

fn is_image_path(p: &Path) -> bool {
    matches!(
        p.extension()
            .and_then(|s| s.to_str())
            .map(str::to_lowercase)
            .as_deref(),
        Some("png") | Some("jpg") | Some("jpeg")
    )
}

fn mime_for(p: &Path) -> &'static str {
    match p
        .extension()
        .and_then(|s| s.to_str())
        .map(str::to_lowercase)
        .as_deref()
    {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        _ => "image/png",
    }
}

/// `StagedImage::mime` is a `&'static str`, so anything we get back from
/// `compress_for_attach` needs to be promoted to one of the three known
/// constants. Unknown MIMEs are coerced to `image/png` (the most
/// permissive consumer-side).
fn mime_for_string(s: &str) -> &'static str {
    match s {
        "image/jpeg" => "image/jpeg",
        "image/webp" => "image/webp",
        _ => "image/png",
    }
}

/// Compose a sibling path next to `original` with the compressed
/// MIME's extension. E.g. `screenshot.png` + `image/webp` → `screenshot.png.fpc.webp`.
/// The `.fpc.` infix marks it as a flashpaste-compressed sibling so a
/// future cleanup pass can identify (and reap) these files without
/// guessing.
fn make_compressed_tmp_path(original: &Path, mime: &str) -> PathBuf {
    let ext = match mime {
        "image/webp" => "webp",
        "image/jpeg" => "jpg",
        _ => "png",
    };
    let mut owned = original.to_path_buf();
    let file_name = original
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image".to_string());
    owned.set_file_name(format!("{file_name}.fpc.{ext}"));
    owned
}
