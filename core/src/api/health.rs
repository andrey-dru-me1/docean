//! Engine health check — the smoke test that proves Dart ↔ Rust wiring works.

use serde::{Deserialize, Serialize};

/// Status returned by [`health_check`] and shown in the app's status bar.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthStatus {
    /// Always `true` when the engine is reachable and initialized.
    pub ok: bool,
    /// Engine crate name.
    pub engine: String,
    /// Crate version (from `Cargo.toml`).
    pub engine_version: String,
    /// Host OS as reported by Rust (`std::env::consts::OS`).
    pub platform: String,
    /// Wall-clock time of the check, milliseconds since the Unix epoch.
    pub timestamp_ms: i64,
}

/// Liveness/readiness probe. Called from Dart at startup.
///
/// `sync` marks this as a synchronous bridge function (no `await` in Dart).
#[flutter_rust_bridge::frb(sync)]
pub fn health_check() -> HealthStatus {
    HealthStatus {
        ok: true,
        engine: "docer-core".to_owned(),
        engine_version: env!("CARGO_PKG_VERSION").to_owned(),
        platform: std::env::consts::OS.to_owned(),
        timestamp_ms: now_millis(),
    }
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}
