# Task runner for docean. Run `just` (or `just <recipe>`) from the repo root.
# Requires: flutter, dart, cargo, and flutter_rust_bridge_codegen on PATH.

default: check

# ---------------------------------------------------------------------------
# Code generation
# ---------------------------------------------------------------------------
# Regenerate the FRB bindings after editing anything under core/src/api/**.
codegen:
    flutter_rust_bridge_codegen generate

# ---------------------------------------------------------------------------
# Rust core
# ---------------------------------------------------------------------------
build-core:
    cargo build --manifest-path core/Cargo.toml

test-core:
    cargo test --manifest-path core/Cargo.toml

fmt-core:
    cargo fmt --manifest-path core/Cargo.toml

fmt-core-check:
    cargo fmt --manifest-path core/Cargo.toml -- --check

lint-core:
    cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings

# ---------------------------------------------------------------------------
# Flutter app
# ---------------------------------------------------------------------------
get:
    cd app && flutter pub get

fmt-app:
    cd app && dart format lib test integration_test test_driver

fmt-app-check:
    cd app && dart format --set-exit-if-changed lib test integration_test test_driver

lint-app:
    cd app && dart analyze

test-app:
    cd app && flutter test

# ---------------------------------------------------------------------------
# Combined
# ---------------------------------------------------------------------------
fmt: fmt-core fmt-app

fmt-check: fmt-core-check fmt-app-check

lint: lint-core lint-app

test: test-core test-app

# Full CI-style check (format + lint + tests).
check: fmt-check lint test

# ---------------------------------------------------------------------------
# Run / build per platform
# ---------------------------------------------------------------------------
run-macos:
    cd app && flutter run -d macos

run-linux:
    cd app && flutter run -d linux

run-windows:
    cd app && flutter run -d windows

run-android:
    cd app && flutter run -d android

build-macos:
    cd app && flutter build macos

build-linux:
    cd app && flutter build linux

build-windows:
    cd app && flutter build windows

build-apk:
    cd app && flutter build apk
