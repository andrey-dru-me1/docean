# docer

Cross-platform app for storing and managing digital documents. A single Flutter
(Dart) UI talks to a Rust core engine through
[`flutter_rust_bridge`](https://cjycode.com/flutter_rust_bridge) (FRB).

**Status:** the scaffold is fully wired and several feature modules are
implemented and exposed through the bridge. The app opens a window, shows an
engine health chip, and includes responsive Search + Chat + AI-provider
configuration screens, all driven by the Rust core through
`flutter_rust_bridge`. Implemented so far: local document storage, tagging and
hierarchy, full-text + offline semantic search (exact/semantic/hybrid with tag
and path filters and snippet highlighting), pluggable AI providers (built-in /
Ollama / OpenAI-compatible) with a configuration screen, retrieval-augmented
chat with streaming answers and clickable document citations, P2P networking,
file sync, and the chat assistant's in-memory RAG. The remaining feature modules
(auto-organization, end-to-end verification) are defined as interfaces in Rust
traits and `abstract interface class` in Dart.

---

## 1. Architecture

```
┌────────────────────────── app/ (Flutter, Dart) ────────────────────────────────┐
│                                                                                 │
│   lib/main.dart ─▶ lib/src/app.dart ─▶ lib/src/features/*.dart (interfaces)    │
│                          │                                                      │
│                          │  generated bindings                                  │
│                          ▼                                                      │
│   lib/src/rust/  (frb_generated.dart, api/*.dart)                               │
│                          │                                                      │
│                          │  Dart FFI                                            │
└──────────────────────────┼──────────────────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────── core/ (Rust) ──────────────────────┐
│                                                                                 │
│   src/api/        — #[frb] bridge surface (health check, init)                  │
│   src/domain/     — shared model: Document, Tag, HierarchyLink                  │
│   src/storage/    — local document storage      (interface: DocumentStore)      │
│   src/taxonomy/   — tagging & hierarchy         (interface: Taxonomy)           │
│   src/search/     — full-text + semantic search (interface: SearchIndex)        │
│   src/ai/         — pluggable AI providers      (interface: AiProvider)         │
│   src/auto_org/   — AI auto-organization        (interface: AutoOrganizer)      │
│   src/assistant/  — chat assistant + refs       (interface: Assistant)          │
│   src/sync/       — P2P sync + conflict resolution (interface: SyncEngine)      │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Key rules**

1. **All UI is Flutter; all domain logic is Rust.** Dart only renders and
   orchestrates; the Rust `core` crate owns storage, search, AI, and sync.
2. **The only bridge surface is `core/src/api/`.** Feature modules never talk to
   Dart directly; they expose plain Rust traits/types that the `api` module wraps
   in `#[flutter_rust_bridge::frb(...)]` functions when a feature is wired up.
3. **Interfaces do not leak concrete crate types.** The trait signatures use
   `docer_core`'s own types (`Document`, `Tag`, …) and `std`/`serde`/`anyhow`
   types, so swapping a backend never changes the public contract.

---

## 2. Repository layout

```
docer/
├── app/                       # Flutter application (single codebase)
│   ├── lib/
│   │   ├── main.dart          # RustLib.init() + runApp
│   │   ├── src/app.dart       # UI; calls the Rust health check
│   │   ├── src/rust_health.dart
│   │   ├── src/features/      # Dart interfaces mirroring core modules
│   │   └── src/rust/          # GENERATED FRB bindings (do not edit)
│   ├── rust_builder/          # cargokit glue: builds ../core & links it
│   ├── test/                  # widget tests (no native lib needed)
│   ├── integration_test/      # end-to-end tests (load native lib)
│   ├── android/  macos/  linux/  windows/   # platform shells
│   └── pubspec.yaml
├── core/                      # Rust crate `docer-core`
│   ├── src/lib.rs
│   ├── src/api/               # #[frb] bridge surface
│   ├── src/domain/  storage/  taxonomy/  search/  ai/  auto_org/  assistant/  sync/
│   └── Cargo.toml
├── flutter_rust_bridge.yaml   # FRB codegen config
├── rustfmt.toml               # Rust formatting config
├── justfile                   # task runner
├── .editorconfig
├── .github/workflows/ci.yml   # CI
└── README.md
```

## 3. Prerequisites

| Tool | Version used | Notes |
|------|-------------|-------|
| Flutter | 3.44.2 (Dart 3.12.2) | any recent stable should work |
| Rust | 1.98.0 (stable) | `rustup` recommended |
| `flutter_rust_bridge_codegen` | **2.13.0** | must match the pin below |
| `cargo-expand` | latest | used by the codegen to parse macros |

Install the FRB toolchain (prebuilt binaries via `cargo-binstall`, or compile
with `cargo install`):

```bash
cargo install cargo-binstall --locked
cargo binstall --no-confirm flutter_rust_bridge_codegen --version 2.13.0
cargo binstall --no-confirm cargo-expand
```

Platform toolchains (per target):

- **macOS** — Xcode + Command Line Tools; CocoaPods (`brew install cocoapods`).
- **Linux** — `clang`, `cmake`, `ninja`, GTK3: `sudo apt install clang cmake ninja-build libgtk-3-dev`.
- **Windows** — Visual Studio 2022 with the "Desktop development with C++" workload.
- **Android** — Android SDK + NDK (Flutter picks the NDK version it needs).

> The FRB version is pinned in **three** places and they must match:
> `core/Cargo.toml` (`flutter_rust_bridge = "=2.13.0"`), `app/pubspec.yaml`
> (`flutter_rust_bridge: 2.13.0`), and the installed codegen CLI (`2.13.0`).

---

## 4. Getting started

```bash
# 1. Flutter dependencies
cd app && flutter pub get && cd ..

# 2. Build the Rust core (also verifies the bridge compiles)
cargo build --manifest-path core/Cargo.toml

# 3. Run the app (see per-platform commands below)
cd app && flutter run -d macos   # or -d linux / -d windows / -d <android-id>
```

The first launch prints the Rust health check in the window (`Rust core: OK`,
engine name, version, host OS).

**Task runner** (`just`): `just` lists recipes; `just check` runs the full
format + lint + test suite.

---

## 5. Build & run per platform

| Platform | Run | Build release artifact |
|----------|-----|------------------------|
| macOS    | `flutter run -d macos`   | `flutter build macos` → `app/build/macos/Build/Products/Release/*.app` |
| Linux    | `flutter run -d linux`   | `flutter build linux` → `app/build/linux/x64/release/bundle/` |
| Windows  | `flutter run -d windows` | `flutter build windows` → `app/build/windows/x64/runner/Release/` |
| Android  | `flutter run -d <device>`| `flutter build apk` → `app/build/app/outputs/flutter-apk/*.apk` |

All four run the same Dart UI. The `docer_rust_builder` plugin (cargokit) compiles
`../core` for the target platform and links the resulting static/dynamic library
automatically, so no extra step is needed after `flutter pub get`.

---

## 6. Code generation workflow

`flutter_rust_bridge` generates the glue between `core/src/api/**` (Rust) and
`app/lib/src/rust/**` (Dart). Whenever you change anything under `core/src/api/`:

```bash
flutter_rust_bridge_codegen generate      # or: just codegen
```

What it writes (both committed to the repo):

- `core/src/frb_generated.rs`
- `app/lib/src/rust/frb_generated.dart`, `frb_generated.io.dart`, `frb_generated.web.dart`
- `app/lib/src/rust/api/*.dart`

CI has a `codegen-check` job that regenerates and fails on any drift.

## 7. Module boundaries & concrete crate/package choices

Each module is an **interface today**. The table pins the intended implementation
stack so later tasks build on the same choices without conflict.

| Module | Rust (`core/src/…`) | Dart (`app/lib/src/features/…`) | Concrete crates (pinned) | Responsibility |
|--------|---------------------|----------------------------------|--------------------------|----------------|
| Domain | `domain/` | `domain.dart` | — (pure model) | `Document`, `Tag`, `HierarchyLink`, `NodeKind` shared across modules |
| Local storage | `storage/` (`DocumentStore`) | `storage.dart` | `redb = "4"` | Durable metadata index (embedded, typed, transactional KV) + blob files keyed by content hash |
| Tagging & hierarchy | `taxonomy/` (`Taxonomy`) | `taxonomy.dart` | — (logic over `storage`) | Move/tag/untag, ancestor/descendant traversal, cycle detection |
| Full-text & semantic search | `search/` (`SearchIndex`) | `search.dart` | `tantivy = "0.26"`, `fastembed = "6"`, `usearch = "2"` | Index/query text, semantic, and hybrid queries |
| Pluggable AI providers | `ai/` (`AiProvider`, `AiManager`) | `ai.dart` (`AiService`) | `reqwest = "0.13"` (`json`, `rustls`), `keyring = "4"`, `log = "0.4"` | Uniform `generate`/`classify`/`embed` over three backends: a small built-in local model (data downloaded on first use), a local Ollama server, and any OpenAI-compatible API (user key + base URL). Secrets (API keys) stored in the OS keychain; never cross the FFI boundary. |
| Automatic organization | `auto_org/` (`DeterministicOrganizer`) | `auto_org.dart` | hand-rolled TF-IDF, k-means, k-NN, MinHash/LSH (see §7a); orchestration over `storage` + `taxonomy` + `search` | Deterministic offline pipeline: tag → place → rename → dedup; optional generative filename tier gated on `ai` |
| Chat assistant | `assistant/` (`Assistant`) | `assistant.dart` | (uses `search` + `ai`) | Retrieval-augmented chat with cited document references |
| P2P sync | `sync/` (`SyncEngine`) | `sync.dart` | `iroh = "1"`, `automerge = "0.11"` | Replicate library across devices; deterministic conflict resolution |
| Observability | — | — | `tracing = "0.1"`, `tracing-subscriber = "0.3"` | Structured logging/spans (planned) |

**Rationale highlights**

- **`redb`** over `sled`/`rusqlite`: pure Rust (no C/FFI), typed, transactional,
  ACID; ideal for the metadata index while blobs stay on the filesystem.
- **`tantivy`** for full-text: the de-facto Rust search engine, no external
  service, fine-grained control over tokenizers and ranking.
- **`fastembed`** for embeddings: runs ONNX models locally (no Python), keeping
  semantic search on-device.
- **`iroh`** for sync transport: modern QUIC-based P2P with content-addressed
  blobs; simpler than hand-rolling `libp2p`.
- **`automerge`** for conflict resolution: a CRDT gives automatic, deterministic
  merges of concurrent edits to metadata/hierarchy/tags.

> Versions above are the current stable at the time of writing. They are also
> listed (commented) in `core/Cargo.toml`; activate them per-module when that
> module is implemented.

### 7a. Auto-organization: classic-ML-first crate decision

`core/src/auto_org/` is fully implemented with **hand-rolled, deterministic,
offline** primitives. The task recommended `linfa` + `linfa-clustering` as a
"contract, not straitjacket"; after evaluating them against the requirements we
deliberately replaced the clustering dependency and documented it here:

| Concern | Implemented with | Why (replacement rationale) |
|---------|------------------|-----------------------------|
| TF-IDF | hand-rolled (`auto_org::text`) | No mature single crate for TF-IDF; deterministic by construction. |
| Clustering (emergent tags) | hand-rolled deterministic k-means with farthest-first seeding (`auto_org::cluster`) | `linfa-clustering` k-means uses **randomized** initialization and GMM is inherently stochastic — both break the hard determinism requirement (reproducible results + fixed test fixtures). Additionally, linfa **GMM** requires `ndarray-linalg` → a native BLAS/LAPACK backend (C/FFI), which conflicts with the project's "pure Rust, self-contained build" goal. |
| k-NN tag reuse | hand-rolled cosine k-NN over TF-IDF (`auto_org::knn`) | The search layer's embedding index (`SearchIndex`) is still an interface only; k-NN over TF-IDF works today and the signature is vector-agnostic so it can be swapped for embeddings later. |
| De-duplication | hand-rolled MinHash + LSH, FNV-1a hashing (`auto_org::minhash`) | `sha2` is already a dependency; FNV-1a with a fixed basis is deterministic across runs — no external LSH crate needed. |
| Renaming | deterministic template from keywords/metadata (`auto_org::keywords` + `rules`); **optional** generative tier (`auto_org::generative`) | The LLM tier is the *only* module importing `crate::ai`, wired in only when a provider is enabled. The classic-ML path has zero dependency on the LLM layer. |

Key properties:

- **Deterministic & reversible** — `DeterministicOrganizer::organize` returns an
  `OrgPlan` as pure data; nothing is mutated. Applying suggestions (tagging,
  path assignment, rename) is a separate, explicit step, and each file is
  organized opt-in.
- **Zero LLM dependency in the default path** — only `auto_org::generative`
  references `crate::ai`; the deterministic path compiles and runs with no AI
  provider configured.

---

## 8. Formatting & linting

**Rust** (`rustfmt.toml` + clippy via `core/Cargo.toml [lints.rust]`):

```bash
cargo fmt --manifest-path core/Cargo.toml -- --check
cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings
```

**Dart** (`app/analysis_options.yaml` → `flutter_lints`):

```bash
cd app
dart format --set-exit-if-changed lib test integration_test test_driver
dart analyze
```

`rustfmt.toml` disables module reordering (so the intentional module order in
`lib.rs` is preserved). Generated FRB files are already formatted by the codegen.

## 9. Testing

```bash
cargo test --manifest-path core/Cargo.toml          # Rust unit tests
cd app && flutter test                              # Dart widget tests (no native lib)
cd app && flutter test integration_test -d macos    # end-to-end (loads native lib)
```

- `app/test/widget_test.dart` — headless widget tests that inject a fake health
  check, so no native library is required.
- `app/test/search_chat_ui_test.dart` — widget tests for the search, chat, and
  AI-provider configuration screens using injected fake services (no FFI), and
  `search_service`/`assistant_service`/`provider_service` facades.
- `app/integration_test/health_test.dart` — loads the real `docer-core` library,
  asserts the Rust health check flows through to the UI, and exercises the
  search bridge (index + query with highlights).

---

## 10. Continuous integration

`.github/workflows/ci.yml` runs on every push/PR:

1. **codegen-check** — regenerates FRB bindings and fails on drift.
2. **core** — `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`.
3. **app** — matrix over Ubuntu/macOS/Windows: `dart format --check`,
   `dart analyze`, `flutter test`, then the platform build (`linux`/`macos`/`windows`).
4. **android** — debug APK build with the NDK.

---

## 11. Adding a feature module (the pattern)

1. Define the Rust trait + types in `core/src/<module>/` (no heavy deps).
2. Add the mirrored `abstract interface class` in `app/lib/src/features/`.
3. When implementing: add the pinned crates to `core/Cargo.toml`, implement the
   trait, then expose a thin `#[frb]` facade in `core/src/api/` and run `just codegen`.

---

## 12. Verification / QA status

Final integration & verification pass (`vs/qa`).

### What was verified

* **Rust core test suite** — `cargo test --manifest-path core/Cargo.toml`:
  **32 tests pass, 0 fail** (storage, schema, blob hash, net/discovery over the
  in-memory transport, sync reconciliation/conflict resolution, and the new
  near-duplicate unit + integration tests).
* **Rust lint/format** — `cargo fmt --check` and
  `cargo clippy --all-targets -- -D warnings` are both clean.
* **Flutter app** — `flutter test` (**4 tests pass**), `dart analyze`
  (**no issues**), and `dart format --set-exit-if-changed` (clean). This covers
  the widget health-check tests plus the new `p2p_sync_screen_test.dart`.
* **Near-duplicate-aware sync (wire-in exercise)** — a two-peer simulation test
  (`sync::tests::near_duplicate_proposal_is_emitted_for_minor_edits`) confirms
  that a substantially-same document arriving under a *different* id is proposed
  as a related version via the search layer's MinHash/LSH index rather than
  filed as an unrelated file.
* **FRB bindings** — regenerated with `flutter_rust_bridge_codegen` 2.13.0;
  the generated `core/src/frb_generated.rs` and `app/lib/src/rust/**` are in
  sync with the `api` surface (including the new `NearDuplicate` sync event).

### What was fixed

* **`dart analyze` error** — `connect`/`events` were exported ambiguously from
  `app/lib/src/features/features.dart` (both `p2p.dart` and `sync.dart` define
  top-level `connect`/`events`). The barrel now hides the sync variants, and
  `sync.dart` no longer re-imports unused names.
* **macOS link failure** — the static Rust core (rust-libp2p) references
  `SystemConfiguration` (network interface enumeration) and `Security` (crypto)
  symbols but those system frameworks were not linked. Both
  `macos/` and `ios/` `docer_rust_builder.podspec`s now declare
  `s.frameworks = 'SystemConfiguration', 'Security'`.

### What was integrated (was missing before this pass)

* **Near-duplicate index** (`core/src/search/near_dup.rs`) — a self-contained
  MinHash + LSH (banding) index owned by the search layer, with
  `NearDuplicateIndex`/`NearDuplicateMatch`, `shingles`, `minhash_signature`,
  and `signature_similarity`. No external crates.
* **Sync ↔ near-duplicate wiring** — `SyncEngineImpl` now accepts a shared
  `SharedNearDuplicateIndex` (`attach_near_duplicate_index` + a similarity
  threshold). `pull()` seeds the index from the local library and, when adopting
  an incoming document, queries it and emits a new `SyncEvent::NearDuplicate`
  (surfaced to Dart as `SyncEventKindDto::nearDuplicate` /
  `SyncNearDuplicateDto`) proposing the related, substantially-same document.
* **P2P + sync UI** (`app/lib/src/p2p_sync_screen.dart`) — a bridge-backed
  screen wired to the existing `p2p`/`sync` facades: shows the local peer id,
  discovered peers (mDNS), lets you dial a peer by id+addr, register sync peers,
  `push`/`pull`, and lists pending conflicts plus a live event log (including
  near-duplicate "related version" proposals). Reachable from the home screen
  via the **P2P & Sync** button. Bridge functions are injectable for headless
  widget testing.

### Known limitations

* **macOS app build not fully verified on this machine.** `flutter build macos`
  fails at the Swift compile step with `Unable to resolve module dependency:
  'FlutterMacOS'` (a Flutter 3.44.2 + Xcode 26.6 CocoaPods/Swift-Package-Manager
  toolchain issue; the linker-level system-framework bug above *was* found and
  fixed). The Rust core itself compiles and tests clean on macOS.
* **Linux / Windows not verifiable here** (macOS host; Flutter has no
  cross-compilation for those targets). They build in CI
  (`.github/workflows/ci.yml` matrix).
* **Android not verifiable here** — SDK present but licenses not accepted;
  `flutter build apk` is exercised in CI.
* The sync engine's runtime backend is still the in-memory
  [`InMemoryStore`](core/src/sync/testing.rs) stand-in, not the SQLite
  [`SqliteDocumentStore`](core/src/storage/sqlite.rs); the transport is the
  `LocalLink`/in-process seam, not yet bridged to the live `net::P2pEngine`.
  The protocol + conflict resolution + near-duplicate proposal logic are
  complete and transport-agnostic.
* Full-text/semantic search, AI auto-organization, and the chat assistant remain
  interface-only (not implemented in this pass).


