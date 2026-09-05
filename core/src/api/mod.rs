//! Bridge surface exposed to Flutter via `flutter_rust_bridge`.
//!
//! Every function or type that Dart may call must be reachable from this module
//! tree and annotated with `#[flutter_rust_bridge::frb(...)]`. After editing,
//! run `flutter_rust_bridge_codegen generate` (or `just codegen`) from the repo
//! root to regenerate the Dart bindings in `app/lib/src/rust/`.

pub mod ai;
pub mod assistant;
pub mod auto_org;
pub mod health;
pub mod ingest;
pub mod library;
pub mod p2p;
pub mod search;
pub mod storage;
pub mod sync;

/// One-time initialization, called automatically by the generated `RustLib.init()`.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Installs default FRB utilities: Dart-side logging hook, panic handling,
    // and a `Future` executor for async bridge functions.
    flutter_rust_bridge::setup_default_user_utils();
}
