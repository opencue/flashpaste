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

use std::sync::Arc;

use anyhow::{Context, Result};
use tracing::info;

use crate::agent::{self, AgentKind};
use crate::state::{now_unix_ms, SharedState, StagedImage, StagedText};
use crate::tmux;
use tokio::io::AsyncWriteExt;

/// Top-level entry from `ipc::handle_paste`.
///
/// `pane` is the tmux pane id (e.g. `%4`).
/// `_staged` is included so the caller can confirm the image is fresh
/// before we burn time on the IPC + tmux dance.
pub async fn dispatch_image_paste(
    state: Arc<SharedState>,
    pane: String,
    staged: StagedImage,
) -> Result<()> {
    let payload_bytes = staged.bytes.len();
    let payload_name = staged
        .path
        .file_name()
        .and_then(|n| n.to_str())
        .map(|s| s.trim_start_matches("Screenshot from ").to_string())
        .unwrap_or_else(|| "<no-name>".to_string());

    // Re-claim X11 CLIPBOARD with the staged image bytes so Claude's
    // `wl-paste -t image/png` reads OUR image (and not whatever external
    // app last grabbed the selection). Wayland is mutter-wedged on this
    // box; the X11 owner does the real work.
    //
    // No sleep: the X11 reclaim wakes on the notifier and runs concurrently
    // with the rest of the dispatch (tmux forks, send-keys). By the time
    // Claude actually fires `wl-paste -t image/png`, the reclaim has long
    // since landed — local X11 socket round-trips are sub-millisecond,
    // while the tmux forks below add several ms of scheduling. If a race
    // ever shows up as "no image found" on the first paste after a new
    // screenshot, restore a 2 ms sleep here.
    let _ = state.stage_notifier_tx.send(now_unix_ms());

    let snap = tmux::pane_snapshot(&pane).await;
    let agent = agent::detect_cached(&state.agent_cache, &pane, &snap).await;

    // Experimental (opt-in via FLASHPASTE_IMAGE_AS_PATH=1): instead of the
    // X11-reclaim + Ctrl-V + clipboard-read dance, write the staged image to
    // a stable file and inject its PATH through the fast text path. Claude
    // Code / Codex can attach an image referenced by path, turning a ~38 ms
    // image paste into a ~text-speed one and skipping the clipboard entirely.
    //
    // Off by default: whether the TUI auto-attaches from a bare pasted path
    // is version-dependent, so this is a flag the user flips on if it works
    // for their build rather than a behaviour change everyone inherits.
    if image_as_path_enabled() && matches!(agent, AgentKind::ClaudeCode | AgentKind::Codex) {
        let image_path = agent::materialize_readable_path(&staged)
            .await
            .context("materialize image path for path-paste")?;
        let mut line = std::os::unix::ffi::OsStrExt::as_bytes(image_path.as_os_str()).to_vec();
        line.push(b' ');
        let text = StagedText {
            bytes: Arc::new(line),
            captured_at: std::time::SystemTime::now(),
        };
        dispatch_text_paste(state.clone(), pane.clone(), text).await?;
        info!(
            pane,
            kind = "image",
            agent = agent.as_str(),
            payload_bytes,
            payload_name = %payload_name,
            path = %image_path.display(),
            "PASTED image as path (FLASHPASTE_IMAGE_AS_PATH)"
        );
        return Ok(());
    }

    if agent == AgentKind::Aider {
        let image_path = agent::deliver_aider_image(&pane, &staged)
            .await
            .context("aider image delivery")?;
        info!(
            pane,
            kind = "image",
            agent = agent.as_str(),
            payload_bytes,
            payload_name = %payload_name,
            path = %image_path.display(),
            "PASTED image via agent adapter"
        );
        return Ok(());
    }

    // Inject Ctrl-V (0x16) into the pane's pty via `tmux send-keys -l`.
    // `-l` is literal: no keytable, no unbind/rebind dance. Reaches any
    // tmux pane regardless of which terminal hosts the client.
    tmux::dispatch_ctrl_v_to_pane(&pane)
        .await
        .context("batched tmux Ctrl-V dispatch")?;

    info!(
        pane,
        kind = "image",
        agent = agent.as_str(),
        payload_bytes,
        payload_name = %payload_name,
        "PASTED image"
    );
    Ok(())
}

/// Text-paste dispatch. Pipes the staged text bytes into a tmux buffer
/// via `tmux load-buffer -` (stdin), then `tmux paste-buffer -p -t <pane>`
/// writes the buffer bytes directly into the target pane's pty. No
/// clipboard claim, no kitty IPC, no unbind/rebind dance — just two
/// `tmux` forks and Claude Code reads the text as if the user typed it.
///
/// Works for ANY tmux pane regardless of which terminal hosts the tmux
/// client (same property as `tmux send-keys -l ^V` for image paste).
/// User contract (2026-05-19): "if last time was text and no new
/// screenshot was taken, text should be pasted to each terminal" — this
/// is what makes that contract hold across multiple panes.
pub async fn dispatch_text_paste(
    _state: Arc<SharedState>,
    pane: String,
    text: StagedText,
) -> Result<()> {
    let bytes_len = text.bytes.len();

    // Single tmux fork: `load-buffer - ; paste-buffer` chained with tmux's
    // `;` command separator. tmux runs both commands in one process — the
    // load reads our text from stdin, then the paste writes the buffer into
    // the target pane. Halves the fork count of the hot text path (was two
    // separate `tmux` spawns). `-p` keeps bracketed paste for multi-line
    // safety. Passing `;` as its own argv entry (no shell) is how tmux sees
    // a command separator when exec'd directly.
    let mut child = tokio::process::Command::new("tmux")
        .args([
            "load-buffer",
            "-b",
            "fp_text",
            "-",
            ";",
            "paste-buffer",
            "-p",
            "-b",
            "fp_text",
            "-t",
            &pane,
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .context("spawn tmux load-buffer;paste-buffer")?;
    {
        let mut stdin = child.stdin.take().context("tmux stdin not piped")?;
        stdin
            .write_all(&text.bytes)
            .await
            .context("write tmux stdin")?;
    }
    let status = child.wait().await.context("tmux load;paste wait")?;
    if !status.success() {
        anyhow::bail!("tmux load-buffer;paste-buffer non-zero: {:?}", status);
    }

    info!(pane, kind = "text", bytes = bytes_len, "PASTED text");
    Ok(())
}

/// Opt-in switch for the image-as-path fast path. Reads `FLASHPASTE_IMAGE_AS_PATH`
/// once per paste — cheap, and lets the user toggle it without restarting if
/// the daemon is launched through a wrapper that re-reads the env. Truthy
/// values: `1`, `true`, `yes`, `on` (case-insensitive).
fn image_as_path_enabled() -> bool {
    std::env::var("FLASHPASTE_IMAGE_AS_PATH")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            matches!(v.as_str(), "1" | "true" | "yes" | "on")
        })
        .unwrap_or(false)
}
