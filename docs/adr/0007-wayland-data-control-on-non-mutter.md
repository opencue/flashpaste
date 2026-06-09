# ADR 0007 — Own the Wayland clipboard via data-control on non-Mutter compositors

- **Status:** Proposed (deferred — untestable on the maintainer's Mutter box)
- **Date:** 2026-06-10
- **Deciders:** maintainers
- **Tags:** architecture, wayland, correctness

## Context and problem statement

The whole shim layer exists because of one constraint: on GNOME 46 / Mutter,
the daemon **cannot own the Wayland clipboard**. Mutter ships neither
`ext-data-control` nor `wlr-data-control`, so a surfaceless client can't be a
selection owner. This is latched at `rs/flashpasted/src/wayland.rs`
(`WAYLAND_WEDGED`, ~line 41). Because the daemon can't own Wayland, when a
browser does "Copy image" the browser keeps Wayland ownership and advertises
`image/png` + a `text/html` `<img src="blob:...">`; Claude reads both and
pastes the blob markup as text. We fixed that at the read chokepoint (the
`wl-paste` shim's image-coexistence guard) — a workaround, not a root fix.

## The root-fix opportunity

On compositors that DO implement a data-control protocol (wlroots: sway,
Hyprland, river; KDE Plasma 6 via `ext-data-control`), the daemon CAN take
Wayland ownership. There it could serve a clean clipboard directly — image
bytes only, no `text/html` — so the leak never reaches Claude and the shim
guard becomes belt-and-suspenders rather than the primary defense. That is a
source fix: it removes a whole class of read-side races.

## Why this is deferred, not done

The maintainer's box is Mutter, where `WAYLAND_WEDGED` latches true and this
code path never executes. Writing it blind and shipping it untested would
violate the project's "do not revert without a regression test" discipline
(see the shim header and ADR 0003). A correctness path that cannot be
exercised on the only available machine is a liability, not a feature.

## Decision

**Proposed:** add the data-control ownership path **guarded** behind the
existing `WAYLAND_WEDGED` detection, so it is a no-op on Mutter (today's
behavior, byte-for-byte) and only activates where data-control is actually
advertised. Do NOT enable or claim it works until it is tested on a real
wlroots/KDE session.

Concrete shape when picked up:

1. In `wayland.rs`, when `copy_multi` succeeds (compositor speaks
   data-control), the daemon becomes the Wayland owner for staged images and
   serves `image/png` (+ the real format) only — never `text/html`.
2. Mirror the X11 owner's policy already in `x11.rs`: text targets are not
   served for an image selection.
3. Test matrix before flipping Status to Accepted: sway + Hyprland + KDE
   Plasma 6, each running the `tests/` paste-correctness suite plus a live
   "Copy image from a browser → paste into Claude" check.

## Consequences

- Zero change on Mutter (the gate stays wedged there).
- On supported compositors the shim guard becomes redundant defense-in-depth,
  and flashpaste stops depending on a PATH shim for clipboard hygiene.
- Until tested, the ROI the improvement list gave #7 (correctness +30% 🟠,
  "not on this box") stands: real, but unrealizable on current hardware.
