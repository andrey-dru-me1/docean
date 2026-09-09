//! Content-addressed file store.
//!
//! Raw document bytes are persisted on disk under `<root>/blobs/<hash>` where
//! `<hash>` is the lowercase hex SHA-256 of the bytes. Because the path is
//! derived from the content, identical bytes are written exactly once
//! (deduplication) and a known hash always resolves to the same location — the
//! foundation for later conflict resolution and P2P sync.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::storage::StorageError;

/// Compute the lowercase hex SHA-256 of `bytes`.
pub fn hash_bytes(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for b in digest {
        use std::fmt::Write as _;
        let _ = write!(out, "{b:02x}");
    }
    out
}

/// A content-addressed file store rooted at a directory on disk.
#[derive(Debug, Clone)]
pub struct BlobStore {
    blobs_dir: PathBuf,
}

impl BlobStore {
    /// Create (or open) a blob store rooted at `root`. The blobs live in
    /// `<root>/blobs/`.
    pub fn open(root: &Path) -> Result<Self, StorageError> {
        let blobs_dir = root.join("blobs");
        fs::create_dir_all(&blobs_dir)?;
        Ok(Self { blobs_dir })
    }

    /// Directory where blobs are stored.
    pub fn blobs_dir(&self) -> &Path {
        &self.blobs_dir
    }

    /// The on-disk path a blob with the given hash maps to.
    pub fn path_for(&self, hash: &str) -> PathBuf {
        self.blobs_dir.join(hash)
    }

    /// Write `bytes` to the store, returning their content hash.
    ///
    /// If a blob with the same hash already exists, it is left untouched
    /// (deduplication); this is intentional and cheap.
    pub fn put(&self, bytes: &[u8]) -> Result<String, StorageError> {
        let hash = hash_bytes(bytes);
        let path = self.path_for(&hash);
        if !path.exists() {
            // Write to a temp file first, then atomically rename, so a crash
            // partway through never leaves a truncated blob that a later reader
            // would mistake for complete.
            let tmp = self.blobs_dir.join(format!(".{hash}.tmp"));
            {
                let mut f = fs::File::create(&tmp)?;
                f.write_all(bytes)?;
                f.sync_all()?;
            }
            fs::rename(&tmp, &path)?;
        }
        Ok(hash)
    }

    /// Read a blob by hash. The returned bytes are *not* re-hashed here;
    /// callers that need integrity verification can use [`hash_bytes`].
    pub fn get(&self, hash: &str) -> Result<Vec<u8>, StorageError> {
        let path = self.path_for(hash);
        Ok(fs::read(path)?)
    }

    /// Whether a blob with the given hash exists.
    pub fn contains(&self, hash: &str) -> bool {
        self.path_for(hash).exists()
    }

    /// Remove a blob by hash. Returns `Ok(true)` if it existed.
    pub fn delete(&self, hash: &str) -> Result<bool, StorageError> {
        let path = self.path_for(hash);
        match fs::remove_file(path) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_is_sha256_hex() {
        assert_eq!(
            hash_bytes(b"docean"),
            "a684100ce08779244b8af5732fd0372d38d6a55f99bfb8451221fd4462541126"
        );
    }

    #[test]
    fn put_then_get_round_trips_and_dedupes() {
        let root = temp_root();
        let store = BlobStore::open(&root).unwrap();

        let hash = store.put(b"hello world").unwrap();
        assert_eq!(hash, hash_bytes(b"hello world"));
        assert_eq!(store.get(&hash).unwrap(), b"hello world");

        // Writing the same bytes again yields the same hash and no error.
        let hash2 = store.put(b"hello world").unwrap();
        assert_eq!(hash, hash2);

        // A different payload maps to a different hash/path.
        assert_ne!(hash, store.put(b"hello worlD").unwrap());
        assert!(store.contains(&hash));

        assert!(store.delete(&hash).unwrap());
        assert!(!store.delete(&hash).unwrap());
        assert!(!store.contains(&hash));

        let _ = fs::remove_dir_all(&root);
    }

    fn temp_root() -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("docean-blob-{}", std::process::id()));
        fs::create_dir_all(&p).unwrap();
        p
    }
}
