# Tasks

| # | Status | Title | Files | Depends on | Capability | Spec row | Owner |
| - | - | - | - | - | - | - | - |
0|available|Prompt 1 — Read reference repos and write docs/overlay-references.md|`docs/overlay-references.md`<br>`.gitignore`|-|doc_work|-|-
1|available|Prompt 2 — Write JSON-over-unix-socket wire protocol spec|`docs/overlay-protocol.md`|-|doc_work|-|-
2|available|Prompt 3 — Scaffold the flashpaste-overlayd Rust crate|`rs/Cargo.toml`<br>`rs/flashpaste-overlayd/Cargo.toml`<br>`rs/flashpaste-overlayd/src/main.rs`|-|infra_work|-|-
3|available|Prompt 4 — Define the wire-protocol message types in Rust|`rs/flashpaste-overlayd/src/protocol.rs`|1, 2|api_work|-|-
