//! Bridge surface for the library filesystem mirror.
//!
//! Exposes the configured library folder and the two-way directory
//! reconciliation ([`crate::library_sync`]) to Flutter via
//! `flutter_rust_bridge`. The library is optional: when no folder is set,
//! [`library_get_directory`] returns `None` and [`library_sync`] errors.

use std::path::PathBuf;

use crate::api::storage::DocumentRepository;
use crate::library_fs::LibraryFs;
use crate::library_sync::{sync_library, LibrarySyncReport};

/// The outcome of one reconciliation pass, as plain Dart-friendly data.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LibrarySyncReportDto {
    /// Document ids ingested from newly-claimed directory files.
    pub added: Vec<String>,
    /// Document ids deleted because their file vanished from the directory.
    pub removed: Vec<String>,
    /// Document ids linked to an existing directory file (same bytes).
    pub linked: Vec<String>,
    /// Per-file failures: `(file_name, error)`. The pass always continues.
    pub failed: Vec<(String, String)>,
}

impl From<LibrarySyncReport> for LibrarySyncReportDto {
    fn from(r: LibrarySyncReport) -> Self {
        Self {
            // The core report calls the additions phase "ingested".
            added: r.ingested,
            removed: r.removed,
            linked: r.linked,
            failed: r.failed,
        }
    }
}

/// The configured library mirror directory, or `None` when not set.
#[flutter_rust_bridge::frb(sync)]
pub fn library_get_directory(repo: &DocumentRepository) -> Option<String> {
    repo.library_dir()
}

/// Set (or clear, when `None`) the library mirror directory.
///
/// Persists `<root>/library_dir.txt` before swapping the handle (a crash never
/// leaves metadata pointing at an un-writable location).
#[flutter_rust_bridge::frb(sync)]
pub fn library_set_directory(repo: &DocumentRepository, dir: Option<String>) -> Result<(), String> {
    repo.set_library_dir(dir)
}

/// Reconcile the repository with its configured library directory.
///
/// Errors when no library folder is configured.
#[flutter_rust_bridge::frb(sync)]
pub fn library_sync(repo: &DocumentRepository) -> Result<LibrarySyncReportDto, String> {
    let dir = repo
        .library_dir()
        .ok_or_else(|| "Library folder is not set".to_owned())?;
    let fs = LibraryFs::open(std::path::Path::new(&dir)).map_err(|e| e.to_string())?;
    let report = sync_library(repo, &fs)?;
    Ok(report.into())
}

/// The on-disk path of a document's mirrored library file, when it exists.
///
/// Used for reveal-in-finder / open-directly from the real file (no temp copy
/// needed). Returns `None` when the library is unset, the document has no
/// stamped `file_name`, or the file no longer exists on disk.
#[flutter_rust_bridge::frb(sync)]
pub fn library_file_path(repo: &DocumentRepository, id: String) -> Option<String> {
    let dir = repo.library_dir()?;
    let doc = repo.get(id).ok()?;
    let name = doc.extra.get("file_name")?;
    let path = PathBuf::from(&dir).join(name);
    if path.is_file() {
        Some(path.to_string_lossy().into_owned())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::fs;
    use std::path::{Path, PathBuf};

    use crate::api::storage::open_repository;
    use crate::domain::{Document, NodeKind};
    use crate::storage::hash_bytes;

    /// A temp root for a fresh on-disk repository.
    fn temp_root(tag: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let mut p = std::env::temp_dir();
        p.push(format!(
            "docean-library-api-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }

    /// A document whose id/checksum is the content hash, with `original_name`
    /// stamped (as the ingest pipeline does).
    fn make_doc(original_name: &str, mime_type: &str, bytes: &[u8]) -> Document {
        let hash = hash_bytes(bytes);
        let mut extra = HashMap::new();
        extra.insert("original_name".to_owned(), original_name.to_owned());
        Document {
            id: hash.clone(),
            parent_id: None,
            kind: NodeKind::Document,
            title: original_name.to_owned(),
            mime_type: mime_type.to_owned(),
            size_bytes: bytes.len() as u64,
            checksum_sha256: hash,
            tags: Vec::new(),
            created_at_ms: 1,
            updated_at_ms: 1,
            extra,
        }
    }

    #[test]
    fn get_directory_none_when_unset() {
        let root = temp_root("get-none");
        let repo = open_repository(root.display().to_string()).unwrap();
        assert_eq!(library_get_directory(&repo), None);
    }

    #[test]
    fn set_directory_persists_and_get_returns_it() {
        let root = temp_root("set-get");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = temp_root("set-get-dir");
        assert_eq!(
            library_set_directory(&repo, Some(dir.display().to_string())),
            Ok(())
        );
        assert_eq!(
            library_get_directory(&repo),
            Some(dir.display().to_string())
        );
    }

    #[test]
    fn clear_directory_returns_none() {
        let root = temp_root("clear");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = temp_root("clear-dir");
        library_set_directory(&repo, Some(dir.display().to_string())).unwrap();
        library_set_directory(&repo, None).unwrap();
        assert_eq!(library_get_directory(&repo), None);
    }

    #[test]
    fn sync_errors_when_no_library_set() {
        let root = temp_root("sync-no-dir");
        let repo = open_repository(root.display().to_string()).unwrap();
        let err = library_sync(&repo).unwrap_err();
        assert!(err.contains("not set"), "unexpected error: {err}");
    }

    #[test]
    fn sync_backfills_files_and_stamps_extra() {
        let root = temp_root("sync-backfill");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = temp_root("sync-backfill-dir");
        library_set_directory(&repo, Some(dir.display().to_string())).unwrap();

        let bytes = b"quarterly report contents";
        let doc = make_doc("Quarterly Report.pdf", "application/pdf", bytes);
        let id = doc.id.clone();
        repo.put(doc, bytes.to_vec()).unwrap();

        let report = library_sync(&repo).unwrap();
        // No directory files to add; the existing doc is backfilled (not added).
        assert!(report.added.is_empty());
        assert!(report.failed.is_empty());

        let doc = repo.get(id.clone()).unwrap();
        let name = doc.extra.get("file_name").expect("stamped").clone();
        assert!(PathBuf::from(&dir).join(&name).exists());
    }

    #[test]
    fn sync_adds_foreign_file_as_document() {
        let root = temp_root("sync-add");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = temp_root("sync-add-dir");
        library_set_directory(&repo, Some(dir.display().to_string())).unwrap();

        // A file nobody claims: sync must ingest it.
        let foreign = b"a foreign file from outside docean";
        fs::write(dir.join("Foreign.txt"), foreign).unwrap();

        let report = library_sync(&repo).unwrap();
        assert_eq!(report.added.len(), 1, "one doc should be added: {report:?}");
        assert!(report.failed.is_empty());

        let id = hash_bytes(foreign);
        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("Foreign.txt")
        );
    }

    #[test]
    fn sync_removes_document_when_file_deleted() {
        let root = temp_root("sync-remove");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = temp_root("sync-remove-dir");
        library_set_directory(&repo, Some(dir.display().to_string())).unwrap();

        let bytes = b"gone soon";
        let doc = make_doc("Gone.pdf", "application/pdf", bytes);
        let id = doc.id.clone();
        repo.put(doc, bytes.to_vec()).unwrap();
        library_sync(&repo).unwrap();
        assert!(repo.get(id.clone()).is_ok());

        // Delete the mirrored file; the next sync removes the document.
        let name = repo
            .get(id.clone())
            .unwrap()
            .extra
            .get("file_name")
            .unwrap()
            .clone();
        fs::remove_file(Path::new(&dir).join(&name)).unwrap();

        let report = library_sync(&repo).unwrap();
        assert_eq!(report.removed, vec![id.clone()]);
        assert!(repo.get(id.clone()).is_err(), "doc should be removed");
    }

    #[test]
    fn file_path_returns_real_path_only_when_file_exists() {
        let root = temp_root("file-path");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = temp_root("file-path-dir");
        library_set_directory(&repo, Some(dir.display().to_string())).unwrap();

        let bytes = b"path content";
        let doc = make_doc("Path.pdf", "application/pdf", bytes);
        let id = doc.id.clone();
        repo.put(doc, bytes.to_vec()).unwrap();

        // No file yet → None.
        assert_eq!(library_file_path(&repo, id.clone()), None);

        library_sync(&repo).unwrap();
        let name = repo
            .get(id.clone())
            .unwrap()
            .extra
            .get("file_name")
            .unwrap()
            .clone();
        let path = library_file_path(&repo, id.clone()).expect("file exists now");
        assert_eq!(path, PathBuf::from(&dir).join(&name).to_string_lossy());

        // Delete the file → None again.
        fs::remove_file(Path::new(&dir).join(&name)).unwrap();
        assert_eq!(library_file_path(&repo, id.clone()), None);

        // Unknown id → None.
        assert_eq!(library_file_path(&repo, "missing".to_owned()), None);
    }

    #[test]
    fn sync_is_idempotent() {
        let root = temp_root("sync-idem");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = temp_root("sync-idem-dir");
        library_set_directory(&repo, Some(dir.display().to_string())).unwrap();

        let bytes = b"stable bytes";
        let doc = make_doc("Stable.txt", "text/plain", bytes);
        repo.put(doc, bytes.to_vec()).unwrap();
        fs::write(dir.join("External.txt"), b"external file").unwrap();

        library_sync(&repo).unwrap();
        let second = library_sync(&repo).unwrap();
        assert!(second.added.is_empty());
        assert!(second.removed.is_empty());
        assert!(second.linked.is_empty());
        assert!(second.failed.is_empty());
    }
}
