import 'rust/api/health.dart';

/// Signature for the engine health probe.
///
/// Injecting this into the UI keeps widgets testable without loading the
/// native library (widget tests pass a fake; the app uses the real one).
typedef HealthCheckFn = HealthStatus Function();

/// Default health probe backed by the Rust core.
HealthStatus defaultHealthCheck() => healthCheck();
