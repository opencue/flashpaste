# flashpaste-overlayd Phase 1 — references, protocol spec, crate scaffold, Rust message types

Plan slug: `flashpaste-overlayd-phase1-2026-05-20`

## Problem

Ship a tiny Rust daemon (flashpaste-overlayd) that paints agent-driven annotations on a Wayland screen, with new MCP tools on flashpaste-mcp that drive it. Phase 1 lays the foundation: study reference implementations (wayscriber, gromit-mpx, gtk4-layer-shell), pin down the JSON-over-unix-socket wire protocol, scaffold the new Rust crate inside the existing flashpaste workspace, and implement the protocol types in Rust with round-trip serde tests. Phases 2-7 (rendering, IPC, MCP wiring, fallbacks, tests, release) follow in later plans. Source of truth: docs/flashpaste-overlayd-plan.md in the flashpaste repo.

## Acceptance Criteria

- docs/overlay-references.md exists, summarizes wayscriber/gromit-mpx/gtk4-layer-shell across the four required dimensions, is under 400 lines, lints clean.
- docs/overlay-protocol.md fully specifies the five-message wire protocol with three example messages, three example responses, and the canonical socket path under $XDG_RUNTIME_DIR.
- rs/flashpaste-overlayd/ exists as a binary crate, registered in the rs/ workspace, with all required dependencies pinned and 'cargo check -p flashpaste-overlayd' succeeding clean.
- rs/flashpaste-overlayd/src/protocol.rs implements serde Serialize/Deserialize for every message in the spec with default-applying helpers, a Color newtype parsing #rrggbb/#rrggbbaa, and passing #[cfg(test)] round-trip tests; 'cargo test -p flashpaste-overlayd' is green.
- All four sub-task branches merge to main and the plan archives without an outstanding BLOCKED line in any tasks.md.

## Roles

- [planner](./planner.md)
- [architect](./architect.md)
- [critic](./critic.md)
- [executor](./executor.md)
- [writer](./writer.md)
- [verifier](./verifier.md)

## Operator Flow

1. Refine this workspace until scope, risks, and tasks are explicit.
2. Publish the plan with `colony plan publish flashpaste-overlayd-phase1-2026-05-20` or the `task_plan_publish` MCP tool.
3. Claim subtasks through Colony plan tools before editing files.
4. Close only when all subtasks are complete and `checkpoints.md` records final evidence.
