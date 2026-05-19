//! End-to-end paste dispatch — the hot path.
//!
//! Sequence (mirrors the bash dispatcher's FAST PATH block, modulo:
//! clipboard ownership is already done by the daemon, so we can skip every
//! probe/prestage step):
//!
//!   1. `tmux select-pane -t <pane>`
//!   2. `tmux unbind -n C-v`   (fact #2 — must happen BEFORE send-text)
//!   3. kitty IPC: `send_text` with payload `\x16`  (fact #1)
//!   4. schedule detached `tmux bind -n C-v ...` after 100ms (fact #2)
//!
//! Steps 2 and 3 must run in that order. We `select-pane` first because the
//! caller's tmux paste menu may be on a different pane than the focused
//! one; without selecting we'd send-text into the wrong pane.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use tracing::{debug, info, warn};

use crate::kitty;
use crate::state::{now_unix_ms, SharedState, StagedImage};
use crate::tmux;

/// How long to wait before re-binding `C-v` in tmux. The bash dispatcher
/// settled on 100ms after observing that anything shorter races the
/// in-flight `\026` byte (tmux still processing it when the rebind lands)
/// and anything longer is visible to the user as "C-v doesn't paste right
/// after a paste".
const TMUX_REBIND_DELAY: Duration = Duration::from_millis(100);

/// Top-level entry from `ipc::handle_paste`.
///
/// `pane` is the tmux pane id (e.g. `%4`).
/// `_staged` is included so the caller can confirm the image is fresh
/// before we burn time on the IPC + tmux dance.
pub async fn dispatch_image_paste(
    state: Arc<SharedState>,
    pane: String,
    _staged: StagedImage,
) -> Result<()> {
    // Resolve the kitty IPC socket. The daemon could cache this at startup,
    // but kitty sometimes restarts (e.g. user reopens the terminal) and the
    // socket name embeds the kitty pid; resolving on each paste is cheap
    // (one readdir) and avoids stale paths.
    // Per-phase timing — emitted as a single summary line at the end so the
    // user can see where dispatch latency is going. Set RUST_LOG=debug for
    // intermediate step logs in addition to the summary.
    let t_start = std::time::Instant::now();
    let mut t_phase = t_start;
    let mut take_phase = || -> u64 {
        let now = std::time::Instant::now();
        let ms = now.duration_since(t_phase).as_millis() as u64;
        t_phase = now;
        ms
    };

    let xdg = xdg_runtime_dir();
    let Some(kitty_sock) = kitty::find_kitty_socket(&xdg) else {
        anyhow::bail!(
            "no kitty IPC socket in {} (is kitty running with --listen?)",
            xdg.display()
        );
    };
    let ms_socket = take_phase();
    debug!(kitty_sock = %kitty_sock.display(), ms_socket, "resolved kitty socket");

    // Step 0: re-assert clipboard ownership.
    //
    // Why: between two pastes, the user can have copied text (the v1.19
    // OSC 52 path makes kitty the live Wayland selection owner with
    // text/plain bytes). The daemon's `latest_image` is still cached in
    // memory, but the *live* clipboard owner has changed. When we
    // send-text \026 and Claude calls `wl-paste -t image/png`, kitty
    // serves the (text) selection — Claude reads 0 image bytes and
    // silently does nothing. Symptom: "right-click → Paste doesn't
    // paste the image; Ctrl+V right after a screenshot does."
    //
    // Bumping the stage notifier wakes the wayland.rs + x11.rs owner
    // tasks, which re-claim the selection with the staged image bytes.
    // The brief sleep lets the round-trip land before we send-text.
    // On mutter where the Wayland claim is rejected outright (no
    // ext-data-control / wlr-data-control), the X11 re-claim still
    // succeeds and the wl-paste shim's xclip fallback picks it up.
    // Identity of the staged image we're about to dispatch — the
    // `captured_at` SystemTime converted to ms since epoch. If this
    // matches `state.last_claim_request_image_ms`, the Wayland + X11
    // owners already claimed THIS image and there's no need to re-fire
    // the notifier (no SetSelectionOwner storm, no 8 ms sleep wasted).
    let staged_id_ms = staged_image_id_ms(&_staged);
    let prev_claim_id = state
        .last_claim_request_image_ms
        .load(std::sync::atomic::Ordering::Acquire);
    let ms_reassert = if prev_claim_id == staged_id_ms && staged_id_ms != 0 {
        // Skip the re-assert entirely — the staged image hasn't
        // changed since we last asked the owners to claim it.
        info!(
            pane,
            image_id_ms = staged_id_ms,
            "paste: skipping re-assert (staged image unchanged since last claim)"
        );
        take_phase()
    } else {
        info!(
            pane,
            image_id_ms = staged_id_ms,
            "paste: re-asserting clipboard ownership before dispatch"
        );
        let _ = state.stage_notifier_tx.send(now_unix_ms());
        state
            .last_claim_request_image_ms
            .store(staged_id_ms, std::sync::atomic::Ordering::Release);
        // X11 selection claim over the local socket is microseconds — 40 ms
        // was conservative padding "in case". 8 ms is a single ~16 ms frame
        // worth of slack which still survives any plausible scheduler hiccup
        // and shaves the bulk of Tier-3 dispatch latency.
        tokio::time::sleep(Duration::from_millis(8)).await;
        take_phase()
    };

    // Step 1: select pane. Best-effort.
    tmux::select_pane(&pane).await;
    let ms_select = take_phase();

    // Step 1.4: snapshot pane state (mode + current_command) in ONE
    // `tmux display` fork. Before this, the copy-mode check and the
    // pane-idle check each forked their own `tmux display` call — two
    // forks × ~5 ms = ~10 ms wasted per dispatch.
    let pane_snap = tmux::pane_snapshot(&pane).await;
    let ms_snapshot = take_phase();

    // Step 1.5: if the user wheel-scrolled the pane into copy-mode, the
    // \026 byte we're about to send would be swallowed by copy-mode's key
    // handler and silently lost. Cancel it first.
    tmux::cancel_copy_mode_if_active(&pane, &pane_snap).await;
    let ms_copymode = take_phase();

    // (v1.23 had a `wait_for_pane_idle` step here that polled
    // `capture-pane` for the Claude TUI's `↓ N tokens` indicator and held
    // the dispatch until generation ended. In practice the detector hit
    // any scrollback line containing "<digit> tokens" — release notes,
    // chat history, "Saved 200 tokens", etc. — so it timed out on every
    // press into a Claude pane and added the full timeout (5 s default)
    // as pure latency before dispatching anyway. Removed in v1.24; the
    // honest contract is "paste fires immediately; retry if the TUI
    // drops the byte." That cost is far below 5 s of guaranteed hang.)

    // Step 2: unbind -n C-v. Must happen synchronously before the byte
    // reaches tmux.
    tmux::unbind_c_v().await.context("tmux unbind -n C-v")?;
    let ms_unbind = take_phase();

    // Step 3: kitty `send_text` with Ctrl-V byte.
    if let Err(e) = kitty::send_ctrl_v(&kitty_sock, state.kitty_version).await {
        // If kitty IPC fails, the user is wedged. The schedule_rebind below
        // still needs to fire so we don't leave tmux without a C-v binding.
        let ms_kitty = take_phase();
        let ms_total = t_start.elapsed().as_millis() as u64;
        warn!(
            error = %e, pane,
            ms_socket, ms_reassert, ms_select, ms_snapshot, ms_copymode,
            ms_unbind, ms_kitty, ms_total,
            "kitty send_text failed — restoring tmux binding immediately (rebind scheduled at +10ms so C-v isn't left unbound)"
        );
        tmux::schedule_rebind(state.config.tmux_rebind_command.clone(), Duration::from_millis(10));
        return Err(e.context("kitty send_text"));
    }
    let ms_kitty = take_phase();

    // Step 4: schedule the detached rebind. Returns immediately.
    tmux::schedule_rebind(state.config.tmux_rebind_command.clone(), TMUX_REBIND_DELAY);
    let ms_total = t_start.elapsed().as_millis() as u64;

    info!(
        pane,
        ms_socket, ms_reassert, ms_select, ms_snapshot, ms_copymode,
        ms_unbind, ms_kitty, ms_total,
        "dispatched image paste"
    );
    Ok(())
}

/// Stable per-screenshot identity used to detect "same image as last
/// claim" in the notifier-skip path. Falls back to 0 if the SystemTime
/// is before the Unix epoch (impossible in practice but the type forces
/// us to handle it).
fn staged_image_id_ms(img: &StagedImage) -> u64 {
    img.captured_at
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn xdg_runtime_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    let uid = nix::unistd::Uid::current().as_raw();
    let candidate = PathBuf::from(format!("/run/user/{uid}"));
    if candidate.is_dir() {
        return candidate;
    }
    PathBuf::from("/tmp")
}
