//! Opt-in push-model clipboard pre-stager (`FLASHPASTE_CLIPBOARD_WATCH=1`).
//!
//! ## Why
//! The measured hot-path cost of a paste is dominated by the live-clipboard
//! probe — `xclip`/`wl-clipboard` forks plus the byte read — that
//! `ipc::handle_paste` runs on every keystroke to discover whether the user
//! copied a fresh image/text. This watcher moves that work OFF the keystroke
//! path: it polls the clipboard in the background and stages new external
//! content the instant it appears. When a paste then fires, the content is
//! already staged and fresh, so the paste-time probe sees `differs == false`
//! and skips the expensive read.
//!
//! ## Safety / blast radius
//! Deliberately additive and isolated:
//!   * It only ever calls `SharedState::set_staged_*` — the SAME path the
//!     paste handler already uses. It never touches the X11/Wayland *owner*
//!     code (the regression-prone part).
//!   * The paste-time probes in `handle_paste` are left intact as a fallback,
//!     so even if this watcher lags or misses, correctness is unchanged.
//!   * With the flag off (the default) `spawn` is never called, so the
//!     daemon behaves exactly as before.
//!
//! ## Loop safety
//! Staging re-claims the clipboard (via the stage notifier), so after the
//! watcher stages external content the daemon itself becomes the owner. The
//! next poll then reads the daemon's OWN bytes, computes `differs == false`,
//! and does nothing — the ping-pong settles after a single cycle. This is the
//! standard clipboard-manager pattern, and as a side effect it keeps the
//! staged selection equal to what the user actually copied (fixing the
//! "stale staged image clobbers a fresh external copy" failure mode).

use std::sync::Arc;
use std::time::{Duration, SystemTime};

use tracing::{debug, info};

use crate::ipc::{read_clipboard_image_if_present, read_clipboard_text_if_present};
use crate::state::{SharedState, StagedImage, StagedSelection, StagedText};

/// How often the background poll samples the clipboard. 250 ms matches the
/// existing hot-path probe throttle: fast enough that a copy is almost always
/// staged before the user can switch windows and paste, cheap enough that the
/// idle daemon isn't forking `xclip` in a tight loop.
const POLL_INTERVAL_MS: u64 = 250;

/// Read `FLASHPASTE_CLIPBOARD_WATCH`. Truthy: `1`, `true`, `yes`, `on`.
pub fn enabled() -> bool {
    std::env::var("FLASHPASTE_CLIPBOARD_WATCH")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            matches!(v.as_str(), "1" | "true" | "yes" | "on")
        })
        .unwrap_or(false)
}

/// Spawn the background poll loop. Caller gates on [`enabled`].
pub fn spawn(state: Arc<SharedState>) {
    tokio::spawn(async move {
        info!(
            poll_ms = POLL_INTERVAL_MS,
            "clipboard pre-stager enabled (FLASHPASTE_CLIPBOARD_WATCH)"
        );
        let mut ticker = tokio::time::interval(Duration::from_millis(POLL_INTERVAL_MS));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            poll_once(&state).await;
        }
    });
}

/// One sample: stage a fresh external image (preferred) or text if it differs
/// from what's currently staged. Image wins when both are advertised, mirroring
/// the paste handler's own preference order.
async fn poll_once(state: &Arc<SharedState>) {
    if let Some((bytes, mime)) = read_clipboard_image_if_present().await {
        let differs = match state.staged_snapshot().await {
            Some(StagedSelection::Image(img)) => img.bytes.as_slice() != bytes.as_slice(),
            _ => true,
        };
        if differs {
            let len = bytes.len();
            let path = synthetic_image_path(state, mime);
            state
                .set_staged_image(StagedImage {
                    bytes: Arc::new(bytes),
                    mime,
                    path,
                    captured_at: SystemTime::now(),
                })
                .await;
            debug!(bytes = len, mime, "clip_watch: pre-staged external image");
        }
        return;
    }

    if let Some(bytes) = read_clipboard_text_if_present().await {
        let differs = match state.staged_snapshot().await {
            Some(StagedSelection::Text(txt)) => txt.bytes.as_slice() != bytes.as_slice(),
            _ => true,
        };
        if differs {
            let len = bytes.len();
            state
                .set_staged_text(StagedText {
                    bytes: Arc::new(bytes),
                    captured_at: SystemTime::now(),
                })
                .await;
            debug!(bytes = len, "clip_watch: pre-staged external text");
        }
    }
}

/// Stable synthetic filename for a clipboard-captured image, rooted in the
/// screenshots dir when configured so downstream logging/Aider delivery have a
/// predictable path. Matches the naming `handle_paste`'s live-image bridge uses.
fn synthetic_image_path(state: &SharedState, mime: &str) -> std::path::PathBuf {
    let name = match mime {
        "image/jpeg" => "flashpaste-clip-live.jpg",
        "image/webp" => "flashpaste-clip-live.webp",
        _ => "flashpaste-clip-live.png",
    };
    state
        .config
        .screenshots_dir
        .clone()
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
        .join(name)
}
