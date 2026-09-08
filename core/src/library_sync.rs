//! Two-way directory reconciliation for the library.
//!
//! A user-chosen directory mirrors the library as real files: each document's
//! `extra["file_name"]` names the file carrying its bytes. [`sync_library`]
//! reconciles the store with that directory in three phases:
//!
//! * **Backfill** — documents without a `file_name` get a friendly file
//!   written from their blob bytes and the name stamped onto `extra`.
//! * **Removals** — documents whose file vanished from the directory are
//!   deleted from the store (the folder is the source of truth for bytes;
//!   metadata dies with it — decided product behavior).
//! * **Additions** — files in the directory that no document claims become
//!   documents via the normal ingest pipeline (auto-organize + search
//!   indexing), or link to an existing document when identical bytes already
//!   exist.
//!
//! The module is decoupled from any concrete filesystem via [`LibraryDir`];
//! tests use a fake in-memory implementation. A separate task delivers a real
//! `LibraryFs` implementation and the production wiring that calls this from
//! the Dart side (later, behind the `api` facade).
//!
//! Search-index bookkeeping: [`sync_library`] removes a deleted document from
//! the in-memory search index via `crate::api::search::search_remove_document`.
//! Stale entries that somehow survive are cleared by the next startup reindex
//! (`search_reindex_from_repository` — Dart rebuilds the index from SQLite).

use std::collections::{HashMap, HashSet};

use crate::api::auto_org::organize_document;
use crate::api::search::{index_document_from_repository, search_remove_document};
use crate::api::storage::DocumentRepository;
use crate::auto_org::config::OrgConfig;
use crate::domain::{Content, Document, NodeKind};
use crate::ingest::{FileInfo, IngestOption, IngestPipeline};
use crate::library_fs::TreeFile;
use crate::storage::{hash_bytes, DocumentQuery, DocumentStore};

/// A file entry reported by [`LibraryDir::list_files`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirFile {
    /// File name (basename) within the library directory.
    pub name: String,
    /// Size in bytes.
    pub size: u64,
    /// Last-modified time, ms since Unix epoch (0 = unknown).
    pub modified_ms: i64,
}

/// The filesystem surface a library directory must expose.
///
/// Implementors may be a real on-disk directory (`path_for` returns the file's
/// path) or a virtual store (`path_for` returns `None`; all I/O goes through
/// `read_file`/`write_file`).
pub trait LibraryDir {
    /// Choose a friendly file name for a document with no stamped `file_name`.
    fn name_for(&self, original_name: Option<&str>, mime_type: &str, hash: &str) -> String;
    /// Whether a file with `name` exists in the directory.
    fn contains(&self, name: &str) -> bool;
    /// List every file currently in the directory.
    fn list_files(&self) -> std::io::Result<Vec<DirFile>>;
    /// Read a file's raw bytes.
    fn read_file(&self, name: &str) -> std::io::Result<Vec<u8>>;
    /// Write (overwrite) a file's raw bytes.
    fn write_file(&self, name: &str, bytes: &[u8]) -> std::io::Result<()>;
    /// The on-disk path of `name`, when the implementation is backed by real
    /// files. `None` for virtual directories (ingest falls back to a manual
    /// byte-level path).
    fn path_for(&self, name: &str) -> Option<std::path::PathBuf>;

    // --- tree surface ------------------------------------------------------

    /// Recursively list every file in the directory tree. `rel_dir` is `""` for
    /// files at the root, `"/a/b"` otherwise (no trailing slash).
    fn walk_tree(&self) -> std::io::Result<Vec<TreeFile>>;
    /// Create a nested directory (`rel_dir` like `"/a/b"`), if missing.
    fn ensure_dir(&self, rel_dir: &str) -> std::io::Result<()>;
    /// Read a file's raw bytes from a nested location.
    fn read_tree_file(&self, rel_dir: &str, name: &str) -> std::io::Result<Vec<u8>>;
    /// Write (overwrite) a file's raw bytes at a nested location.
    fn write_tree_file(&self, rel_dir: &str, name: &str, bytes: &[u8]) -> std::io::Result<()>;
    /// Remove a file from a nested location; prunes now-empty parent dirs.
    fn remove_tree_file(&self, rel_dir: &str, name: &str) -> std::io::Result<bool>;
    /// Whether a file exists at a nested location.
    fn contains_tree(&self, rel_dir: &str, name: &str) -> bool;
}

/// The outcome of one reconciliation pass.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct LibrarySyncReport {
    /// Document ids linked to an existing directory file (same bytes).
    pub linked: Vec<String>,
    /// Document ids deleted because their file vanished from the directory.
    pub removed: Vec<String>,
    /// Document ids newly ingested from previously-unclaimed directory files.
    pub ingested: Vec<String>,
    /// Per-file failures: `(file_name, error)`. The pass always continues.
    pub failed: Vec<(String, String)>,
}

/// Query every document in the repository (never folders).
fn all_documents(repo: &DocumentRepository) -> Result<Vec<Document>, String> {
    repo.query(DocumentQuery {
        kind: Some(NodeKind::Document),
        ..Default::default()
    })
}

/// Stamp `extra["file_name"] = name` on a document, persisting through
/// `store.put` (the blob is deduplicated, so this never rewrites bytes).
///
/// The `repo.store()` guard is scoped to this function so callers never hold
/// it across a re-locking call (`organize_document`,
/// `index_document_from_repository`, `search_remove_document`), which would
/// deadlock the shared `Arc<Mutex<_>>`.
fn stamp_file_name(repo: &DocumentRepository, id: &str, name: &str) -> Result<(), String> {
    let mut store = repo.store()?;
    let id_owned = id.to_owned();
    let mut doc = store.get(&id_owned).map_err(|e| e.to_string())?;
    doc.extra.insert("file_name".to_owned(), name.to_owned());
    let bytes = store.read_bytes(&id_owned).map_err(|e| e.to_string())?;
    store.put(doc, &bytes).map_err(|e| e.to_string())?;
    Ok(())
}

/// Stamp `extra["main_path"] = main_path` on a document. Guard-scoped.
fn stamp_main_path(repo: &DocumentRepository, id: &str, main_path: &str) -> Result<(), String> {
    let mut store = repo.store()?;
    let id_owned = id.to_owned();
    let mut doc = store.get(&id_owned).map_err(|e| e.to_string())?;
    doc.extra
        .insert("main_path".to_owned(), main_path.to_owned());
    let bytes = store.read_bytes(&id_owned).map_err(|e| e.to_string())?;
    store.put(doc, &bytes).map_err(|e| e.to_string())?;
    Ok(())
}

/// Reconcile the document store with a library directory.
///
/// The directory is the source of truth for file bytes. A document's expected
/// location is `<dir>/<extra["main_path"]>/<extra["file_name"]>` (root when
/// `main_path` is absent or empty). The pass reconciles in three phases:
///
/// 1. **Backfill** — documents without a `file_name` get a friendly file
///    written at their `main_path` location and the name stamped onto `extra`.
/// 2. **Adoption / Removals** — for each stamped doc the expected location is
///    checked. When the file exists there, nothing happens. When the file was
///    moved (same name elsewhere), the move is *adopted*: `main_path` is
///    re-stamped and a soft path assigned. When the file is gone entirely, the
///    document is deleted.
/// 3. **Additions** — unclaimed tree files become new documents via the ingest
///    pipeline; their `main_path` is set to `rel_dir`.
///
/// Adoptions are folded into `report.linked` (the `LibrarySyncReportDto` is
/// frozen for this wave — no new fields).
pub fn sync_library(
    repo: &DocumentRepository,
    dir: &dyn LibraryDir,
) -> Result<LibrarySyncReport, String> {
    let mut report = LibrarySyncReport::default();

    // ---- Phase BACKFILL: give every unstamped document a real file. --------
    let docs = all_documents(repo)?;
    for doc in &docs {
        if doc.extra.contains_key("file_name") {
            continue;
        }
        let id = doc.id.clone();
        let result = (|| -> Result<(), String> {
            let name = dir.name_for(
                doc.extra.get("original_name").map(|s| s.as_str()),
                &doc.mime_type,
                &id,
            );
            let main_path = doc.extra.get("main_path").map(|s| s.as_str()).unwrap_or("");
            if dir.contains_tree(main_path, &name) {
                // Existing file at expected location — stamp only.
            } else {
                let bytes = repo.read_bytes(id.clone()).map_err(|e| e.to_string())?;
                dir.write_tree_file(main_path, &name, &bytes)
                    .map_err(|e| e.to_string())?;
            }
            stamp_file_name(repo, &id, &name)?;
            Ok(())
        })();
        if let Err(e) = result {
            report.failed.push((
                doc.extra
                    .get("original_name")
                    .cloned()
                    .unwrap_or_else(|| id.clone()),
                e,
            ));
        }
    }

    // ---- Phase ADOPTION + REMOVALS: reconcile stamped docs. ----------------
    let all_tree = dir.walk_tree().map_err(|e| e.to_string())?;
    let docs = all_documents(repo)?;

    for doc in &docs {
        let Some(file_name) = doc.extra.get("file_name") else {
            continue;
        };
        let id = doc.id.clone();
        let main_path = doc.extra.get("main_path").map(|s| s.as_str()).unwrap_or("");

        if dir.contains_tree(main_path, file_name) {
            continue;
        }

        // File not at expected location — search the tree for moves.
        let matching: Vec<&TreeFile> = all_tree.iter().filter(|e| e.name == *file_name).collect();

        let adopt_target: Option<String> = match matching.len() {
            0 => None,
            1 => Some(matching[0].rel_dir.clone()),
            _ => {
                // Ambiguous: prefer the match whose rel_dir equals a soft path.
                let paths = repo.paths_of(id.clone()).unwrap_or_default();
                let soft: std::collections::HashSet<String> =
                    paths.into_iter().map(|p| p.path).collect();
                matching
                    .iter()
                    .find(|e| soft.contains(&e.rel_dir))
                    .map(|e| e.rel_dir.clone())
            }
        };

        match adopt_target {
            // Single (or soft-path-preferred) match → adopt the move.
            Some(new_main) => {
                let result = (|| -> Result<(), String> {
                    stamp_main_path(repo, &id, &new_main)?;
                    if !new_main.is_empty() {
                        repo.assign_path(crate::domain::PathAssignment {
                            document_id: id.clone(),
                            path: new_main.clone(),
                            position: 0,
                        })?;
                    }
                    Ok(())
                })();
                match result {
                    Ok(()) => report.linked.push(id),
                    Err(e) => report.failed.push((file_name.clone(), e)),
                }
            }
            // No match (or ambiguous with no soft-path tiebreak) → removal.
            None => {
                let result = (|| -> Result<(), String> {
                    {
                        let mut store = repo.store()?;
                        store.delete(&id).map_err(|e| e.to_string())?;
                    }
                    let _ = search_remove_document(id.clone());
                    Ok(())
                })();
                match result {
                    Ok(()) => report.removed.push(id),
                    Err(e) => report.failed.push((file_name.clone(), e)),
                }
            }
        }
    }

    // ---- Phase ADDITIONS: claim unclaimed tree files as documents. ----------
    let docs = all_documents(repo)?;
    let mut claimed_names: HashSet<String> = HashSet::new();
    for doc in &docs {
        if let Some(name) = doc.extra.get("file_name") {
            claimed_names.insert(name.clone());
        }
    }

    for entry in &all_tree {
        if claimed_names.contains(&entry.name) {
            continue;
        }
        let name = entry.name.clone();
        let bytes = match dir.read_tree_file(&entry.rel_dir, &name) {
            Ok(b) => b,
            Err(e) => {
                report.failed.push((name, e.to_string()));
                continue;
            }
        };
        let id = hash_bytes(&bytes);

        match repo.get(id.clone()) {
            Ok(existing) => {
                // Same bytes already stored: link, don't duplicate.
                match existing.extra.get("file_name") {
                    None => {
                        if let Err(e) = stamp_file_name(repo, &id, &name) {
                            report.failed.push((name, e));
                            continue;
                        }
                        if let Err(e) = stamp_main_path(repo, &id, &entry.rel_dir) {
                            report.failed.push((name, e));
                            continue;
                        }
                        if !entry.rel_dir.is_empty() {
                            if let Err(e) = repo.assign_path(crate::domain::PathAssignment {
                                document_id: id.clone(),
                                path: entry.rel_dir.clone(),
                                position: 0,
                            }) {
                                report.failed.push((name, e));
                                continue;
                            }
                        }
                        report.linked.push(id);
                    }
                    Some(current) if current != &name => {
                        // Identical bytes already claimed under a different name.
                        report.linked.push(id);
                    }
                    _ => {}
                }
            }
            Err(_) => {
                // Not stored yet: full ingest.
                let result = (|| -> Result<(), String> {
                    match dir.path_for(&name) {
                        Some(path) if path.is_file() => {
                            let info = FileInfo {
                                path,
                                size: entry.size,
                                modified_ms: entry.modified_ms,
                                created_ms: 0,
                            };
                            let mut store = repo.store()?;
                            let ids = IngestPipeline::new()
                                .ingest(
                                    &mut *store,
                                    std::slice::from_ref(&info),
                                    &IngestOption {
                                        skip_existing: true,
                                        ..Default::default()
                                    },
                                    None,
                                )
                                .map_err(|e| e.to_string())?;
                            ids.into_iter()
                                .next()
                                .ok_or_else(|| "ingest returned no document id".to_owned())?;
                            Ok(())
                        }
                        _ => {
                            // Manual ingest for virtual directories.
                            let ext = crate::ingest::extension_of(&name);
                            let (text, source) = crate::ingest::text::extract(&ext, &bytes)
                                .map(|e| (e.text, e.source.to_owned()))
                                .unwrap_or_else(|_| (String::new(), "none".to_owned()));
                            let now = crate::ingest::now_millis();
                            let mut extra = HashMap::new();
                            extra.insert("original_name".to_owned(), name.clone());
                            extra.insert("extractor".to_owned(), source.clone());
                            let doc = Document {
                                id: id.clone(),
                                parent_id: None,
                                kind: NodeKind::Document,
                                title: crate::ingest::stem_of(&name),
                                mime_type: crate::ingest::mime_for(ext, &source),
                                size_bytes: bytes.len() as u64,
                                checksum_sha256: id.clone(),
                                tags: Vec::new(),
                                created_at_ms: now,
                                updated_at_ms: entry.modified_ms.max(now),
                                extra,
                            };
                            let mut store = repo.store()?;
                            store.put(doc, &bytes).map_err(|e| e.to_string())?;
                            store
                                .put_content(&Content {
                                    document_id: id.clone(),
                                    text,
                                    source,
                                })
                                .map_err(|e| e.to_string())?;
                            Ok(())
                        }
                    }
                })();

                match result {
                    Ok(()) => {
                        if let Err(e) = stamp_file_name(repo, &id, &name) {
                            report.failed.push((name, e));
                            continue;
                        }
                        if let Err(e) = stamp_main_path(repo, &id, &entry.rel_dir) {
                            report.failed.push((name, e));
                            continue;
                        }
                        if !entry.rel_dir.is_empty() {
                            if let Err(e) = repo.assign_path(crate::domain::PathAssignment {
                                document_id: id.clone(),
                                path: entry.rel_dir.clone(),
                                position: 0,
                            }) {
                                report.failed.push((name, e));
                                continue;
                            }
                        }
                        if let Err(e) = organize_document(repo, &id, OrgConfig::default()) {
                            eprintln!(
                                "library_sync: auto-organization failed for {id} (tags/title left unchanged): {e}"
                            );
                        }
                        if let Err(e) = index_document_from_repository(repo, &id) {
                            eprintln!("library_sync: failed to index {id} into search: {e}");
                        }
                        report.ingested.push(id);
                    }
                    Err(e) => report.failed.push((name, e)),
                }
            }
        }
    }

    Ok(report)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::api::search::{
        index_document_from_repository, search_query, SearchMode, SearchRequestDto,
    };
    use crate::api::storage::{open_repository, DocumentRepository};
    use crate::domain::{Content, Document, NodeKind, PathAssignment};
    use crate::storage::{hash_bytes, DocumentQuery, DocumentStore};

    use crate::library_fs::TreeFile;

    use super::{sync_library, DirFile, LibraryDir, LibrarySyncReport};

    struct FakeDir {
        files: RefCell<HashMap<String, Vec<u8>>>,
        tree_files: RefCell<HashMap<String, Vec<u8>>>,
        fail_reads: Vec<String>,
    }

    impl FakeDir {
        fn new() -> Self {
            Self {
                files: RefCell::new(HashMap::new()),
                tree_files: RefCell::new(HashMap::new()),
                fail_reads: Vec::new(),
            }
        }

        fn add(&self, name: &str, bytes: &[u8]) {
            self.files
                .borrow_mut()
                .insert(name.to_owned(), bytes.to_vec());
        }

        fn add_tree(&self, rel_dir: &str, name: &str, bytes: &[u8]) {
            let key = if rel_dir.is_empty() {
                name.to_owned()
            } else {
                format!("{}/{}", rel_dir, name)
            };
            self.tree_files.borrow_mut().insert(key, bytes.to_vec());
        }

        fn fail_read(&mut self, name: &str) {
            self.fail_reads.push(name.to_owned());
        }

        fn tree_key(rel_dir: &str, name: &str) -> String {
            if rel_dir.is_empty() {
                name.to_owned()
            } else {
                format!("{}/{}", rel_dir, name)
            }
        }
    }

    impl LibraryDir for FakeDir {
        fn name_for(&self, original_name: Option<&str>, _mime_type: &str, hash: &str) -> String {
            original_name
                .map(|s| s.to_owned())
                .unwrap_or_else(|| format!("{}.bin", &hash[..8]))
        }

        fn contains(&self, name: &str) -> bool {
            self.files.borrow().contains_key(name) || self.tree_files.borrow().contains_key(name)
        }

        fn list_files(&self) -> std::io::Result<Vec<DirFile>> {
            Ok(self
                .files
                .borrow()
                .iter()
                .map(|(name, bytes)| DirFile {
                    name: name.clone(),
                    size: bytes.len() as u64,
                    modified_ms: 0,
                })
                .collect())
        }

        fn read_file(&self, name: &str) -> std::io::Result<Vec<u8>> {
            if self.fail_reads.iter().any(|f| f == name) {
                return Err(std::io::Error::other(format!("read failed for {name}")));
            }
            self.files
                .borrow()
                .get(name)
                .cloned()
                .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no such file"))
        }

        fn write_file(&self, name: &str, bytes: &[u8]) -> std::io::Result<()> {
            self.files
                .borrow_mut()
                .insert(name.to_owned(), bytes.to_vec());
            Ok(())
        }

        fn path_for(&self, _name: &str) -> Option<std::path::PathBuf> {
            None
        }

        fn walk_tree(&self) -> std::io::Result<Vec<TreeFile>> {
            let mut result = Vec::new();
            for (key, bytes) in self.tree_files.borrow().iter() {
                let (rel_dir, name) = match key.rfind('/') {
                    Some(pos) => (key[..pos].to_owned(), key[pos + 1..].to_owned()),
                    None => (String::new(), key.clone()),
                };
                result.push(TreeFile {
                    rel_dir,
                    name,
                    size: bytes.len() as u64,
                    modified_ms: 0,
                });
            }
            for (name, bytes) in self.files.borrow().iter() {
                if !result
                    .iter()
                    .any(|e| e.name == *name && e.rel_dir.is_empty())
                {
                    result.push(TreeFile {
                        rel_dir: String::new(),
                        name: name.clone(),
                        size: bytes.len() as u64,
                        modified_ms: 0,
                    });
                }
            }
            result.sort_by(|a, b| a.rel_dir.cmp(&b.rel_dir).then_with(|| a.name.cmp(&b.name)));
            Ok(result)
        }

        fn ensure_dir(&self, _rel_dir: &str) -> std::io::Result<()> {
            Ok(())
        }

        fn read_tree_file(&self, rel_dir: &str, name: &str) -> std::io::Result<Vec<u8>> {
            if self.fail_reads.iter().any(|f| f == name) {
                return Err(std::io::Error::other(format!("read failed for {name}")));
            }
            let key = Self::tree_key(rel_dir, name);
            if let Some(bytes) = self.tree_files.borrow().get(&key) {
                return Ok(bytes.clone());
            }
            if rel_dir.is_empty() {
                if let Some(bytes) = self.files.borrow().get(name) {
                    return Ok(bytes.clone());
                }
            }
            Err(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "no such file",
            ))
        }

        fn write_tree_file(&self, rel_dir: &str, name: &str, bytes: &[u8]) -> std::io::Result<()> {
            self.add_tree(rel_dir, name, bytes);
            Ok(())
        }

        fn remove_tree_file(&self, rel_dir: &str, name: &str) -> std::io::Result<bool> {
            let key = Self::tree_key(rel_dir, name);
            Ok(self.tree_files.borrow_mut().remove(&key).is_some())
        }

        fn contains_tree(&self, rel_dir: &str, name: &str) -> bool {
            let key = Self::tree_key(rel_dir, name);
            if self.tree_files.borrow().contains_key(&key) {
                return true;
            }
            rel_dir.is_empty() && self.files.borrow().contains_key(name)
        }
    }

    /// A unique temp root for a fresh on-disk repository.
    fn temp_root(tag: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "docer-libsync-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }

    /// Seed a document whose id is the content hash of `bytes` (the same
    /// identity the ingest pipeline uses), optionally with extracted content.
    fn seed_doc(
        repo: &DocumentRepository,
        title: &str,
        bytes: &[u8],
        extra: HashMap<String, String>,
        content: Option<&str>,
    ) -> String {
        let id = hash_bytes(bytes);
        let mut store = repo.store().unwrap();
        store
            .put(
                Document {
                    id: id.clone(),
                    parent_id: None,
                    kind: NodeKind::Document,
                    title: title.to_owned(),
                    mime_type: "text/plain".to_owned(),
                    size_bytes: bytes.len() as u64,
                    checksum_sha256: id.clone(),
                    tags: Vec::new(),
                    created_at_ms: 1,
                    updated_at_ms: 1,
                    extra,
                },
                bytes,
            )
            .unwrap();
        if let Some(text) = content {
            store
                .put_content(&Content {
                    document_id: id.clone(),
                    text: text.to_owned(),
                    source: "test".to_owned(),
                })
                .unwrap();
        }
        drop(store);
        id
    }

    #[test]
    fn backfill_stamps_name_writes_bytes_and_is_idempotent() {
        let root = temp_root("backfill");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"backfill payload bytes".to_vec();

        let id = seed_doc(
            &repo,
            "Draft",
            &bytes,
            HashMap::from([("original_name".to_owned(), "note.txt".to_owned())]),
            None,
        );

        let report = sync_library(&repo, &dir).unwrap();
        assert!(
            report.failed.is_empty(),
            "backfill must not fail: {:?}",
            report
        );
        assert_eq!(dir.read_tree_file("", "note.txt").unwrap(), bytes);
        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("note.txt")
        );

        // Idempotency: a second run changes nothing.
        let second = sync_library(&repo, &dir).unwrap();
        assert_eq!(second, LibrarySyncReport::default());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn removal_deletes_missing_file_and_unindexes_search() {
        let root = temp_root("removal");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"vanished document with unique term acme5691".to_vec();

        let id = seed_doc(
            &repo,
            "Gone",
            &bytes,
            HashMap::from([("file_name".to_owned(), "vanished.txt".to_owned())]),
            Some("invoice quarterly acme5691 document"),
        );

        // Index it first so the removal can be verified to unindex it.
        index_document_from_repository(&repo, &id).unwrap();
        let before = search_query(SearchRequestDto {
            text: "acme5691".to_owned(),
            mode: SearchMode::Exact,
            tags: vec![],
            paths: vec![],
            limit: None,
        });
        assert!(
            before.iter().any(|h| h.document_id == id),
            "doc should be searchable before removal"
        );

        let report = sync_library(&repo, &dir).unwrap();
        assert_eq!(report.removed, vec![id.clone()]);
        assert!(
            report.failed.is_empty(),
            "removal must not fail: {:?}",
            report
        );
        assert!(repo.get(id.clone()).is_err(), "document must be deleted");

        let after = search_query(SearchRequestDto {
            text: "acme5691".to_owned(),
            mode: SearchMode::Exact,
            tags: vec![],
            paths: vec![],
            limit: None,
        });
        assert!(
            !after.iter().any(|h| h.document_id == id),
            "deleted doc must be unindexed from search"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn addition_ingests_organizes_and_stamps_file_name() {
        let root = temp_root("addition");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let content = "quarterly invoice summary for acme corporation total due payable";
        dir.add("meeting_notes.txt", content.as_bytes());

        let report = sync_library(&repo, &dir).unwrap();
        assert!(
            report.failed.is_empty(),
            "addition must not fail: {:?}",
            report
        );
        assert_eq!(report.ingested.len(), 1);
        assert!(report.linked.is_empty());

        let id = &report.ingested[0];
        let doc = repo.get(id.clone()).unwrap();
        assert!(
            !doc.tags.is_empty(),
            "auto-organization should have tagged the new doc: {:?}",
            doc.tags
        );
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("meeting_notes.txt")
        );
        assert_eq!(
            repo.read_bytes(id.clone()).unwrap(),
            content.as_bytes(),
            "blob bytes must match the added file"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn addition_links_identical_bytes_without_duplication() {
        let root = temp_root("link");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"identical content for the link case".to_vec();

        // Existing doc owns `original.txt` with these bytes; `copy.txt` holds
        // the same bytes but is unclaimed.
        seed_doc(
            &repo,
            "Original",
            &bytes,
            HashMap::from([("file_name".to_owned(), "original.txt".to_owned())]),
            None,
        );
        dir.add("original.txt", &bytes);
        dir.add("copy.txt", &bytes);
        let id = hash_bytes(&bytes);

        let report = sync_library(&repo, &dir).unwrap();
        assert!(report.failed.is_empty(), "link must not fail: {:?}", report);
        assert_eq!(report.linked, vec![id.clone()]);
        assert!(report.ingested.is_empty(), "no new document may be created");
        assert!(report.removed.is_empty());

        // Still exactly one document, and the original stamp is untouched.
        assert!(repo.get(id.clone()).is_ok());
        assert_eq!(
            repo.get(id.clone())
                .unwrap()
                .extra
                .get("file_name")
                .map(String::as_str),
            Some("original.txt")
        );
        // The mirrored file stays on disk.
        assert!(dir.contains("copy.txt"));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn per_file_failure_is_collected_and_pass_continues() {
        let root = temp_root("failures");
        let repo = open_repository(root.display().to_string()).unwrap();
        let mut dir = FakeDir::new();
        dir.add("good.txt", b"fine content for ingestion");
        dir.add("bad.txt", b"unreadable content");
        dir.fail_read("bad.txt");

        let report = sync_library(&repo, &dir).unwrap();
        assert_eq!(report.failed.len(), 1);
        assert_eq!(report.failed[0].0, "bad.txt");
        assert!(report.failed[0].1.contains("bad.txt"));

        // The healthy file was still ingested.
        let good_id = hash_bytes(b"fine content for ingestion");
        assert_eq!(report.ingested, vec![good_id.clone()]);
        assert!(repo.get(good_id).is_ok());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn full_pass_exercises_all_phases_without_deadlock() {
        let root = temp_root("full");
        let repo = open_repository(root.display().to_string()).unwrap();

        // Backfill target: doc without a file_name.
        let backfill_bytes = b"doc awaiting backfill".to_vec();
        let backfill_id = seed_doc(
            &repo,
            "Awaiting",
            &backfill_bytes,
            HashMap::from([("original_name".to_owned(), "queued.txt".to_owned())]),
            None,
        );

        // Removal target: doc whose file no longer exists.
        let gone_bytes = b"file manually deleted from the folder".to_vec();
        let gone_id = seed_doc(
            &repo,
            "Gone",
            &gone_bytes,
            HashMap::from([("file_name".to_owned(), "gone.txt".to_owned())]),
            None,
        );

        // Kept target: doc whose file exists.
        let kept_bytes = b"kept document bytes".to_vec();
        let kept_id = seed_doc(
            &repo,
            "Kept",
            &kept_bytes,
            HashMap::from([("file_name".to_owned(), "kept.txt".to_owned())]),
            None,
        );
        let dir = FakeDir::new();
        dir.add("kept.txt", &kept_bytes);
        // A brand-new unclaimed file (addition target).
        let new_bytes = b"brand new folder file".to_vec();
        dir.add("new.txt", &new_bytes);
        let new_id = hash_bytes(&new_bytes);

        // Runs all three phases under the repository mutex; a mis-scoped guard
        // would hang the test (the suite would time out).
        let report = sync_library(&repo, &dir).unwrap();

        // Backfill wrote + stamped.
        assert!(dir.contains("queued.txt"));
        assert_eq!(
            repo.get(backfill_id.clone())
                .unwrap()
                .extra
                .get("file_name")
                .map(String::as_str),
            Some("queued.txt")
        );

        // Removal deleted the vanished doc.
        assert_eq!(report.removed, vec![gone_id.clone()]);
        assert!(repo.get(gone_id).is_err());

        // Kept is untouched, no removal reported.
        assert!(repo.get(kept_id.clone()).is_ok());

        // Addition ingested the new file and left everything else alone.
        assert_eq!(report.ingested, vec![new_id.clone()]);
        assert!(report.linked.is_empty());
        assert!(report.failed.is_empty());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn backfill_writes_under_main_path() {
        let root = temp_root("backfill-path");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"backfill under a folder".to_vec();

        // Doc without file_name, but with a main_path stamped (by an earlier
        // adoption or manual edit).
        seed_doc(
            &repo,
            "Draft",
            &bytes,
            HashMap::from([
                ("original_name".to_owned(), "note.txt".to_owned()),
                ("main_path".to_owned(), "/diploma/2025-2026".to_owned()),
            ]),
            None,
        );

        let report = sync_library(&repo, &dir).unwrap();
        assert!(report.failed.is_empty(), "backfill: {:?}", report);
        assert!(dir.contains_tree("/diploma/2025-2026", "note.txt"));
        assert!(!dir.contains("note.txt"), "file must not be at root");
        let docs = repo.query(DocumentQuery::default()).unwrap();
        assert_eq!(docs.len(), 1);
        let doc = &docs[0];
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("note.txt")
        );
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some("/diploma/2025-2026")
        );

        // Idempotent second run.
        let second = sync_library(&repo, &dir).unwrap();
        assert_eq!(second, LibrarySyncReport::default());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn backfill_root_when_no_main_path() {
        let root = temp_root("backfill-root");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"backfill at root".to_vec();

        seed_doc(
            &repo,
            "Draft",
            &bytes,
            HashMap::from([("original_name".to_owned(), "root.txt".to_owned())]),
            None,
        );

        let report = sync_library(&repo, &dir).unwrap();
        assert!(report.failed.is_empty());
        assert!(dir.contains_tree("", "root.txt"));
        assert!(dir.contains("root.txt"));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn adoption_on_move_restamps_main_path_and_assigns_soft_path() {
        let root = temp_root("adopt-move");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"moved to a new folder".to_vec();
        let id = hash_bytes(&bytes);

        // Doc claims the file at /old/, but the file was moved to /new/.
        seed_doc(
            &repo,
            "Moved",
            &bytes,
            HashMap::from([
                ("file_name".to_owned(), "doc.txt".to_owned()),
                ("main_path".to_owned(), "/old".to_owned()),
            ]),
            None,
        );
        dir.add_tree("/new", "doc.txt", &bytes);

        let report = sync_library(&repo, &dir).unwrap();
        // Adoptions are folded into `linked`.
        assert_eq!(report.linked, vec![id.clone()]);
        assert!(report.removed.is_empty(), "doc must NOT be deleted");
        assert!(report.failed.is_empty(), "adoption: {:?}", report);

        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some("/new"),
            "main_path must be re-stamped to the file's folder"
        );
        // The soft hierarchy knows the document at /new.
        let paths = repo.paths_of(id.clone()).unwrap();
        assert!(
            paths.iter().any(|p| p.path == "/new"),
            "doc must be soft-assigned to /new: {:?}",
            paths
        );

        // Idempotent: second run is empty.
        let second = sync_library(&repo, &dir).unwrap();
        assert_eq!(second, LibrarySyncReport::default());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn ambiguous_double_move_prefers_soft_path_match() {
        let root = temp_root("adopt-ambiguous");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"duplicated across folders".to_vec();
        let id = hash_bytes(&bytes);

        // The doc was at /old/ but the name now appears in /a/ and /target/.
        // The existing soft path /target must break the tie.
        seed_doc(
            &repo,
            "Dup",
            &bytes,
            HashMap::from([
                ("file_name".to_owned(), "dup.txt".to_owned()),
                ("main_path".to_owned(), "/old".to_owned()),
            ]),
            None,
        );
        repo.assign_path(PathAssignment {
            document_id: id.clone(),
            path: "/target".to_owned(),
            position: 0,
        })
        .unwrap();
        dir.add_tree("/a", "dup.txt", &bytes);
        dir.add_tree("/target", "dup.txt", &bytes);

        let report = sync_library(&repo, &dir).unwrap();
        assert_eq!(report.linked, vec![id.clone()]);
        assert!(report.removed.is_empty());
        assert!(report.failed.is_empty());

        // Tie broken by the doc's soft path.
        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some("/target")
        );

        // The other file at /a stays untouched (extra mirror).
        assert!(repo.get(hash_bytes(&bytes)).is_ok());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn removal_anywhere_prunes_doc_and_keeps_tree_consistent() {
        let root = temp_root("removal-anywhere");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"vanished from a deep folder".to_vec();
        let id = hash_bytes(&bytes);

        // File existed at /deep/nested/ before, now gone entirely.
        seed_doc(
            &repo,
            "Deep",
            &bytes,
            HashMap::from([
                ("file_name".to_owned(), "deep.txt".to_owned()),
                ("main_path".to_owned(), "/deep/nested".to_owned()),
            ]),
            None,
        );
        // No file anywhere in the tree.

        let report = sync_library(&repo, &dir).unwrap();
        assert_eq!(report.removed, vec![id.clone()]);
        assert!(repo.get(id.clone()).is_err(), "doc must be deleted");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn addition_in_subdir_ingests_with_main_path_and_soft_path() {
        let root = temp_root("add-subdir");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let content = "quarterly invoice summary for acme corporation total due";
        dir.add_tree("/x/y", "invoice.txt", content.as_bytes());

        let report = sync_library(&repo, &dir).unwrap();
        assert!(report.failed.is_empty(), "addition: {:?}", report);
        assert_eq!(report.ingested.len(), 1);

        let id = &report.ingested[0];
        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("invoice.txt")
        );
        assert_eq!(doc.extra.get("main_path").map(String::as_str), Some("/x/y"));
        let paths = repo.paths_of(id.clone()).unwrap();
        assert!(
            paths.iter().any(|p| p.path == "/x/y"),
            "new doc must be soft-assigned to /x/y: {:?}",
            paths
        );
        assert!(
            !doc.tags.is_empty(),
            "auto-organization should have tagged the new doc"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn addition_at_root_gets_empty_main_path() {
        let root = temp_root("add-root");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let content = "root-level foreign file content";
        dir.add("foreign.txt", content.as_bytes());

        let report = sync_library(&repo, &dir).unwrap();
        assert!(report.failed.is_empty());
        assert_eq!(report.ingested.len(), 1);

        let id = &report.ingested[0];
        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some(""),
            "root files must get main_path = \"\""
        );
        // The sync pass itself must not soft-assign the empty root as a path
        // (auto-org may still assign its own fallback path, which is fine).
        let paths = repo.paths_of(id.clone()).unwrap();
        assert!(
            !paths.iter().any(|p| p.path.is_empty()),
            "root file must not be soft-assigned to the empty path: {:?}",
            paths
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn full_tree_pass_is_idempotent() {
        let root = temp_root("tree-idempotent");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();

        // Backfill target under a path.
        let backfill_bytes = b"tree backfill".to_vec();
        seed_doc(
            &repo,
            "Awaiting",
            &backfill_bytes,
            HashMap::from([
                ("original_name".to_owned(), "queued.txt".to_owned()),
                ("main_path".to_owned(), "/p1/p2".to_owned()),
            ]),
            None,
        );
        // Kept doc at nested location.
        let kept_bytes = b"kept during tree sweep".to_vec();
        let kept_id = seed_doc(
            &repo,
            "Kept",
            &kept_bytes,
            HashMap::from([
                ("file_name".to_owned(), "kept.txt".to_owned()),
                ("main_path".to_owned(), "/a/b".to_owned()),
            ]),
            None,
        );
        dir.add_tree("/a/b", "kept.txt", &kept_bytes);
        // A new file in a subdir + one at root.
        dir.add_tree("/z/1", "incoming.txt", b"incoming content");
        dir.add("root.txt", b"root incoming");

        let first = sync_library(&repo, &dir).unwrap();
        assert!(first.failed.is_empty(), "first pass: {:?}", first);
        assert_eq!(first.ingested.len(), 2);

        // Second run: nothing to do.
        let second = sync_library(&repo, &dir).unwrap();
        assert_eq!(second, LibrarySyncReport::default());

        // The kept doc is intact, backfill stamped.
        assert!(repo.get(kept_id.clone()).is_ok());

        let _ = fs::remove_dir_all(&root);
    }
}
