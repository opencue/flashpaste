# ADR 0006 — Reduce the bash surface, bounded by the Tier-1 fallback guarantee

- **Status:** Proposed
- **Date:** 2026-06-10
- **Deciders:** maintainers
- **Tags:** architecture, maintainability, scope

## Context and problem statement

flashpaste carries ~3.7k lines of bash across 17 tracked scripts alongside
~4k lines of Rust. Bash is hard to test and each script has been a breakage
source (the `wl-paste` shim, `clipboard-set.sh`, `tmux-paste-dispatch.sh`).
A tempting "improvement" is to fold the shell into the Rust daemon so the
logic is testable and typed.

## The constraint that makes this an ocean

Most of the bash is **load-bearing by design**, not accident:

- `bin/tmux-paste-dispatch.sh` (657 lines) is the **Tier-1 canonical path**
  per [ADR 0001](0001-three-progressive-tiers.md). It MUST run with zero
  daemon, zero Rust toolchain, zero systemd. The daemon (Tier 3) execs it on
  any failure. Folding it into the daemon would delete the very fallback that
  makes "flashpasted is not running" a non-event.
- `bin/clipboard-set.sh` is invoked by tmux's `@clip` hook in the user's
  shell, before any daemon round-trip — it has to be a script tmux can exec.
- `~/.local/bin/wl-paste` is a PATH shim that Claude Code reads through
  directly; it only works because it IS a `wl-paste`-named executable. It
  cannot become daemon-internal without changing how Claude reads the
  clipboard.

So "move the bash into Rust" is partly a **non-goal**: the bash surface is
the zero-dependency tier. This downgrades the ROI estimate the improvement
list gave #3 (friction +50% 🟠) — the genuinely reducible part is smaller.

## What IS reducible (the real first slices)

1. **Duplication between shims and daemon.** The daemon already has typed
   probes (`read_clipboard_text_if_present`, `read_clipboard_image_if_present`,
   `looks_like_text`) that re-implement logic also living in
   `get-clipboard-text.sh` (169 lines) and parts of `tmux-paste-dispatch.sh`.
   Where the daemon is up, those shells should call the daemon (one op) rather
   than re-deriving. First slice: a `flashpaste-trigger --get-text` op that
   `get-clipboard-text.sh` shells to when the socket exists, falling back to
   its current logic otherwise. Removes ~100 lines of duplicated probe logic
   without touching the Tier-1 guarantee.
2. **Behavioral test coverage for the bash that must stay.** Tier-1 is
   permanent, so test it instead of deleting it. The `tests/*.test.sh` harness
   (mocked clipboard, headless, in CI as of this session) is the pattern; grow
   it to cover `tmux-paste-dispatch.sh`'s text-vs-image decision.

## Decision

**Proposed:** do NOT pursue a wholesale bash→Rust rewrite. Treat the Tier-1
bash as a permanent, first-class artifact and invest in (a) deleting only the
*duplication* between shims and the daemon, slice by slice, and (b) behavioral
tests for the bash that must remain. Each slice ships independently and keeps
the no-daemon guarantee intact.

## Consequences

- The ~657-line Tier-1 dispatcher stays. That's correct, not debt.
- "Shrink the bash" becomes a bounded, test-first cleanup, not a multi-day
  rewrite that risks the fallback path.
- Open question: if a future ADR retires the three-tier model (daemon becomes
  mandatory), this constraint lifts and a fuller consolidation reopens.
