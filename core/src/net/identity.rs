//! Persistent device identity backed by a libp2p keypair.
//!
//! The identity is an Ed25519 [`libp2p::identity::Keypair`] persisted as a
//! JSON file so the device keeps the same [`libp2p::PeerId`] across launches.
//! The `PeerId` is a stable, collision-resistant identifier for the device,
//! derived from the public key and independent of the network the device is
//! currently on.

use std::path::{Path, PathBuf};

use libp2p::identity::{Keypair, PeerId};

/// Errors loading or persisting a device identity.
#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("identity io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("identity file is malformed: {0}")]
    Malformed(#[from] serde_json::Error),
    #[error("identity file contains an unsupported key type")]
    UnsupportedKeyType,
}

/// Where the identity file lives, relative to the OS-appropriate config dir.
const IDENTITY_FILE_NAME: &str = "device_identity.json";

/// A persistent device identity.
///
/// Wraps the raw keypair and exposes the derived [`PeerId`] and a human-readable
/// string form suitable for display or bridging to Dart.
#[derive(Clone)]
pub struct DeviceIdentity {
    keypair: Keypair,
    peer_id: PeerId,
}

impl std::fmt::Debug for DeviceIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never leak secret key material into logs or Debug output.
        f.debug_struct("DeviceIdentity")
            .field("peer_id", &self.peer_id.to_string())
            .finish()
    }
}

impl DeviceIdentity {
    /// Generate a fresh identity (used when no identity file exists).
    pub fn generate() -> Self {
        let keypair = Keypair::generate_ed25519();
        Self::from_keypair(keypair)
    }

    /// Wrap an existing libp2p keypair.
    pub fn from_keypair(keypair: Keypair) -> Self {
        let peer_id = keypair.public().to_peer_id();
        Self { keypair, peer_id }
    }

    /// The stable device id (libp2p `PeerId`).
    pub fn peer_id(&self) -> &PeerId {
        &self.peer_id
    }

    /// The `PeerId` as its base58 string form.
    pub fn peer_id_string(&self) -> String {
        self.peer_id.to_string()
    }

    /// The underlying keypair. Callers must not expose this beyond the crate.
    pub fn keypair(&self) -> &Keypair {
        &self.keypair
    }

    /// Load the identity from `dir`, creating a fresh one (and persisting it)
    /// if none exists yet. `dir` is created if needed.
    pub fn load_or_create(dir: &Path) -> Result<Self, IdentityError> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join(IDENTITY_FILE_NAME);
        if path.exists() {
            Self::load_from(&path)
        } else {
            let identity = Self::generate();
            identity.save_to(&path)?;
            Ok(identity)
        }
    }

    fn load_from(path: &Path) -> Result<Self, IdentityError> {
        // The keypair is persisted using libp2p's canonical protobuf encoding,
        // wrapped in a small JSON envelope keyed by key type for forward-compat.
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct SerializedIdentity {
            key_type: String,
            secret_key: Vec<u8>,
        }

        let raw = std::fs::read(path)?;
        let parsed: SerializedIdentity = serde_json::from_slice(&raw)?;
        if parsed.key_type != "ed25519" {
            return Err(IdentityError::UnsupportedKeyType);
        }
        let keypair = Keypair::from_protobuf_encoding(&parsed.secret_key)
            .map_err(|_| IdentityError::UnsupportedKeyType)?;
        Ok(Self::from_keypair(keypair))
    }

    fn save_to(&self, path: &Path) -> Result<(), IdentityError> {
        let bytes = self
            .keypair
            .to_protobuf_encoding()
            .map_err(|_| IdentityError::UnsupportedKeyType)?;
        let json = serde_json::json!({
            "keyType": "ed25519",
            "secretKey": bytes,
        });
        std::fs::write(path, serde_json::to_vec_pretty(&json)?)?;
        Ok(())
    }
}

/// Default location for the identity file, resolved from the standard
/// platform config dir when available; falls back to a temp dir otherwise.
pub fn default_identity_dir() -> PathBuf {
    // Prefer an explicit data dir, else the OS temp dir scoped to this crate.
    std::env::var_os("DOCER_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("docer-core"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_identity_is_stable_across_loads() {
        let dir = temp_dir();
        let _ = std::fs::remove_dir_all(&dir);

        let first = DeviceIdentity::load_or_create(&dir).unwrap();
        let pid = first.peer_id_string();

        // Loading again must produce the *same* id (persisted, not regenerated).
        let second = DeviceIdentity::load_or_create(&dir).unwrap();
        assert_eq!(pid, second.peer_id_string());
        assert_eq!(first.peer_id(), second.peer_id());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn distinct_dirs_yield_distinct_identities() {
        let a = temp_dir();
        let b = temp_dir();
        let _ = std::fs::remove_dir_all(&a);
        let _ = std::fs::remove_dir_all(&b);

        let ia = DeviceIdentity::load_or_create(&a).unwrap();
        let ib = DeviceIdentity::load_or_create(&b).unwrap();
        assert_ne!(ia.peer_id(), ib.peer_id());

        let _ = std::fs::remove_dir_all(&a);
        let _ = std::fs::remove_dir_all(&b);
    }

    /// A unique temp dir per call without adding a uuid dependency.
    fn temp_dir() -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        std::env::temp_dir().join(format!("docer-id-{nanos}-{}", std::process::id()))
    }
}
