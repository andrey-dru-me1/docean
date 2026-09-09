//! API-key persistence via the OS credential store (`keyring` crate).
//!
//! Secrets are stored under a single keychain *service* with each provider id
//! as the *account*. On platforms without a keychain daemon (headless CI), we
//! fall back to a file under the config dir *only* when
//! [`KEYCHAIN_FALLBACK_ENV`] is set — keeping normal deployments strictly
//! keychain-backed while letting tests run hermetically.

use std::fs;
use std::path::PathBuf;

/// Keychain service name for all docean AI API keys.
pub const API_KEY_SERVICE: &str = "docean.ai";

/// Environment variable that, when set, opts into a file-backed fallback for
/// key storage. Intended for tests and headless CI only.
pub const KEYCHAIN_FALLBACK_ENV: &str = "DOCEAN_AI_KEYCHAIN_FALLBACK";

/// Backend used to persist a secret.
enum SecretBackend {
    /// The OS keychain (macOS Keychain, Windows Credential Manager, Secret Service).
    Keychain(keyring::Entry),
    /// A restricted-permission file (fallback for headless/test environments).
    File(PathBuf),
    /// No credential backend is available (no keychain, fallback not opted in).
    Unavailable,
}

impl SecretBackend {
    /// Resolve the preferred backend for `provider_id`.
    fn resolve(provider_id: &str) -> Self {
        match keyring::Entry::new(API_KEY_SERVICE, provider_id) {
            Ok(entry) => SecretBackend::Keychain(entry),
            Err(_) => SecretBackend::File(fallback_path(provider_id)),
        }
    }

    fn set(&self, key: &str) -> Result<(), String> {
        match self {
            SecretBackend::Keychain(entry) => entry
                .set_password(key)
                .map_err(|e| format!("keychain: {e}")),
            SecretBackend::File(path) => {
                if let Some(dir) = path.parent() {
                    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                }
                fs::write(path, key).map_err(|e| e.to_string())
            }
            SecretBackend::Unavailable => Err(
                "no OS keychain available; set DOCEAN_AI_KEYCHAIN_FALLBACK to store keys"
                    .to_owned(),
            ),
        }
    }

    fn get(&self) -> Result<Option<String>, String> {
        match self {
            SecretBackend::Keychain(entry) => match entry.get_password() {
                Ok(v) => Ok(Some(v).filter(|v| !v.is_empty())),
                Err(keyring::Error::NoEntry) => Ok(None),
                Err(e) => Err(format!("keychain: {e}")),
            },
            SecretBackend::File(path) => match fs::read_to_string(path) {
                Ok(v) => Ok(Some(v.trim().to_owned()).filter(|v| !v.is_empty())),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(e.to_string()),
            },
            SecretBackend::Unavailable => Ok(None),
        }
    }

    fn delete(&self) -> Result<(), String> {
        match self {
            SecretBackend::Keychain(entry) => match entry.delete_credential() {
                Ok(()) => Ok(()),
                Err(keyring::Error::NoEntry) => Ok(()),
                Err(e) => Err(format!("keychain: {e}")),
            },
            SecretBackend::File(path) => match fs::remove_file(path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e.to_string()),
            },
            SecretBackend::Unavailable => Ok(()),
        }
    }
}

/// Path for the file fallback (only used when the keychain is unavailable AND
/// [`KEYCHAIN_FALLBACK_ENV`] is set).
fn fallback_path(provider_id: &str) -> PathBuf {
    let root = crate::ai::config::ConfigStore::default_root();
    root.join("secrets").join(format!("{provider_id}.key"))
}

/// Store (or replace) the API key for `provider_id`.
///
/// An empty `key` removes the stored credential.
pub fn set_api_key(provider_id: &str, key: &str) -> Result<(), String> {
    if key.is_empty() {
        return remove_api_key(provider_id);
    }
    backend(provider_id).set(key)
}

/// Remove the API key for `provider_id`, if any.
pub fn remove_api_key(provider_id: &str) -> Result<(), String> {
    backend(provider_id).delete()
}

/// Read the API key for `provider_id`, or `None` if absent/unset.
pub fn get_api_key(provider_id: &str) -> Option<String> {
    backend(provider_id).get().ok().flatten()
}

fn backend(provider_id: &str) -> SecretBackend {
    let resolved = SecretBackend::resolve(provider_id);
    match resolved {
        // A file fallback is only acceptable when explicitly opted in.
        SecretBackend::File(_) if std::env::var_os(KEYCHAIN_FALLBACK_ENV).is_none() => {
            SecretBackend::Unavailable
        }
        other => other,
    }
}
