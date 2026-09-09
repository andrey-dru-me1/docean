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
use crate::library_fs::{sanitize_fs_stem, LibraryFs, TreeFile};
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

/// Tag dispersion: for every non-property tag, the number of documents whose
/// materialized tag set contains it (a doc tagged `study/mit` counts towards
/// `study` too, because storage materializes implicit ancestors).
fn tag_dispersion(docs: &[Document]) -> HashMap<String, u32> {
    let mut map: HashMap<String, u32> = HashMap::new();
    for doc in docs {
        for tag in &doc.tags {
            if tag.contains(':') {
                continue;
            }
            *map.entry(tag.clone()).or_insert(0) += 1;
        }
    }
    map
}

/// The tag-derived folder path for one document (`""` = library root).
///
/// The document's materialized, non-property tags are ordered by dispersion
/// (most used first; ties broken by full tag path ascending) and each
/// contributes its last segment. Segments may repeat (nested duplicates are
/// kept). Documents without hierarchy tags land at the root.
///
/// Example: tags `article` (4), `study` (21), `study/mit` (15),
/// `study/lecture` (2) order to `study, study/mit, article, study/lecture`
/// and produce `study/mit/article/lecture`.
pub fn tag_main_path(tags: &[String], dispersion: &HashMap<String, u32>) -> String {
    let mut ordered: Vec<&String> = tags.iter().filter(|t| !t.contains(':')).collect();
    ordered.sort_by(|a, b| {
        let ca = dispersion.get(*a).copied().unwrap_or(0);
        let cb = dispersion.get(*b).copied().unwrap_or(0);
        cb.cmp(&ca).then(a.cmp(b))
    });
    ordered
        .iter()
        .map(|tag| {
            let last = tag.rsplit('/').next().unwrap_or(tag);
            sanitize_fs_stem(last)
        })
        .collect::<Vec<_>>()
        .join("/")
}

/// First available name for [base] inside [rel_dir]: `base`, then
/// `base (2)`, `base (3)`, ... [skip] names a file (in the same folder)
/// known to be vacated during this move, so the document's own current slot
/// never blocks its rename.
fn unique_tree_name(dir: &dyn LibraryDir, rel_dir: &str, base: &str, skip: Option<&str>) -> String {
    let available = |name: &str| !dir.contains_tree(rel_dir, name) || skip == Some(name);
    if available(base) {
        return base.to_owned();
    }
    let (stem, ext) = match base.rfind('.') {
        Some(i) => (&base[..i], Some(&base[i + 1..])),
        None => (base, None),
    };
    let make = |n: u64| match ext {
        Some(e) => format!("{stem} ({n}).{e}"),
        None => format!("{stem} ({n})"),
    };
    let mut n: u64 = 2;
    loop {
        let candidate = make(n);
        if available(&candidate) {
            return candidate;
        }
        n += 1;
    }
}

/// The title-derived mirror file name for a document.
fn title_name_for(doc: &Document) -> String {
    LibraryFs::title_file_name(
        Some(&doc.title),
        doc.extra.get("original_name").map(String::as_str),
        &doc.mime_type,
        &doc.id,
    )
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
/// location is `<dir>/<tag_main_path(...)>/<title file name>` — the folder
/// path derives from the document's tags (most used first) and the file name
/// from the document title. The pass reconciles in three phases:
///
/// 1. **Backfill** — documents without a `file_name` get a title-named file
///    written at their tag-derived location and the name stamped onto `extra`.
/// 2. **Additions** — unclaimed tree files become new documents via the ingest
///    pipeline (auto-organize + search indexing); their `main_path` starts at
///    the found `rel_dir`.
/// 3. **Placement** — every stamped document is moved/renamed to its current
///    tag-derived folder and title-derived file name. Tags always win: a file
///    moved manually in the folder is snapped back. A file that cannot be
///    found anywhere means the document dies (the folder is the source of
///    truth for bytes — decided product behavior).
///
/// Moves and renames are folded into `report.linked` (the
/// `LibrarySyncReportDto` is frozen for this wave — no new fields).
pub fn sync_library(
    repo: &DocumentRepository,
    dir: &dyn LibraryDir,
) -> Result<LibrarySyncReport, String> {
    let mut report = LibrarySyncReport::default();

    // ---- Phase BACKFILL: give every unstamped document a real file. --------
    let docs = all_documents(repo)?;
    let dispersion = tag_dispersion(&docs);
    for doc in &docs {
        if doc.extra.contains_key("file_name") {
            continue;
        }
        let id = doc.id.clone();
        let expected_dir = tag_main_path(&doc.tags, &dispersion);
        let result = (|| -> Result<(), String> {
            let base = title_name_for(doc);
            let name = unique_tree_name(dir, &expected_dir, &base, None);
            if !dir.contains_tree(&expected_dir, &name) {
                let bytes = repo.read_bytes(id.clone()).map_err(|e| e.to_string())?;
                dir.write_tree_file(&expected_dir, &name, &bytes)
                    .map_err(|e| e.to_string())?;
            }
            stamp_file_name(repo, &id, &name)?;
            stamp_main_path(repo, &id, &expected_dir)?;
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

    // ---- Phase ADDITIONS: claim unclaimed tree files as documents. ---------
    let all_tree = dir.walk_tree().map_err(|e| e.to_string())?;
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

    // ---- Phase PLACEMENT: every doc lives at its tag path under its title. -
    // Tags always win: files that drifted (manual moves, stale placements,
    // or tags that changed since the last pass) are moved to the expected
    // location; a file that cannot be found anywhere deletes its document.
    let docs = all_documents(repo)?;
    let dispersion = tag_dispersion(&docs);
    let all_tree = dir.walk_tree().map_err(|e| e.to_string())?;

    for doc in &docs {
        let Some(file_name) = doc.extra.get("file_name").cloned() else {
            continue;
        };
        let id = doc.id.clone();
        let stamped_dir = doc
            .extra
            .get("main_path")
            .map(|s| s.as_str())
            .unwrap_or("")
            .to_owned();
        let expected_dir = tag_main_path(&doc.tags, &dispersion);
        let title_base = title_name_for(doc);

        // Locate the file: expected spot, stamped spot, then the whole tree.
        let found: Option<(String, String)> = if dir.contains_tree(&expected_dir, &file_name) {
            Some((expected_dir.clone(), file_name.clone()))
        } else if dir.contains_tree(&stamped_dir, &file_name) {
            Some((stamped_dir.clone(), file_name.clone()))
        } else {
            let matches: Vec<&TreeFile> = all_tree.iter().filter(|e| e.name == file_name).collect();
            matches
                .iter()
                .find(|e| e.rel_dir == stamped_dir)
                .or_else(|| matches.first())
                .map(|e| (e.rel_dir.clone(), e.name.clone()))
        };

        let Some((src_dir, src_name)) = found else {
            // Gone from the whole tree → the document dies with its bytes.
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
            continue;
        };

        // Target name: title-derived, uniquified against the folder. The
        // file's own current slot never blocks its rename.
        let own_slot = if src_dir == expected_dir {
            Some(src_name.as_str())
        } else {
            None
        };
        let target_name = if src_name == title_base {
            src_name.clone()
        } else {
            unique_tree_name(dir, &expected_dir, &title_base, own_slot)
        };

        if src_dir == expected_dir && src_name == target_name {
            continue;
        }

        let result = (|| -> Result<(), String> {
            let bytes = dir
                .read_tree_file(&src_dir, &src_name)
                .map_err(|e| e.to_string())?;
            dir.write_tree_file(&expected_dir, &target_name, &bytes)
                .map_err(|e| e.to_string())?;
            dir.remove_tree_file(&src_dir, &src_name)
                .map_err(|e| e.to_string())?;
            if target_name != src_name {
                stamp_file_name(repo, &id, &target_name)?;
            }
            if expected_dir != stamped_dir {
                stamp_main_path(repo, &id, &expected_dir)?;
                if !expected_dir.is_empty() {
                    repo.assign_path(crate::domain::PathAssignment {
                        document_id: id.clone(),
                        path: expected_dir.clone(),
                        position: 0,
                    })?;
                }
            }
            Ok(())
        })();
        match result {
            Ok(()) => report.linked.push(id),
            Err(e) => report.failed.push((src_name, e)),
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
    use crate::domain::{Content, Document, NodeKind};
    use crate::storage::{hash_bytes, DocumentQuery, DocumentStore};

    use crate::library_fs::TreeFile;

    use super::{
        sync_library, tag_dispersion, tag_main_path, DirFile, LibraryDir, LibrarySyncReport,
    };

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
            let mut removed = self.tree_files.borrow_mut().remove(&key).is_some();
            if rel_dir.is_empty() && self.files.borrow_mut().remove(name).is_some() {
                removed = true;
            }
            Ok(removed)
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
            "docean-libsync-{tag}-{}-{}",
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
        seed_tagged_doc(repo, title, bytes, extra, content, Vec::new())
    }

    /// [`seed_doc`] with an explicit (already materialized) tag set.
    fn seed_tagged_doc(
        repo: &DocumentRepository,
        title: &str,
        bytes: &[u8],
        extra: HashMap<String, String>,
        content: Option<&str>,
        tags: Vec<String>,
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
                    tags,
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
        // Untagged doc → root; title-derived name ("note.txt" supplies .txt).
        assert_eq!(dir.read_tree_file("", "Draft.txt").unwrap(), bytes);
        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("Draft.txt")
        );
        assert_eq!(doc.extra.get("main_path").map(String::as_str), Some(""));

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

        let id = &report.ingested[0];
        let doc = repo.get(id.clone()).unwrap();
        assert!(
            !doc.tags.is_empty(),
            "auto-organization should have tagged the new doc: {:?}",
            doc.tags
        );
        assert!(
            doc.extra.contains_key("file_name"),
            "a file name must be stamped"
        );
        // The fresh doc already sits at its tag-derived folder (auto-organize
        // assigned plain tags; the title may have been replaced as well).
        let expected = tag_main_path(&doc.tags, &tag_dispersion(std::slice::from_ref(&doc)));
        assert!(
            dir.contains_tree(&expected, doc.extra.get("file_name").unwrap()),
            "file must live at its tag path {expected:?}"
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
        // Two link events, same doc: `copy.txt` claims as identical bytes,
        // then placement re-links the original under its title.
        assert!(
            report.linked.iter().all(|x| *x == id),
            "only the existing doc may be linked: {:?}",
            report.linked
        );
        assert!(report.ingested.is_empty(), "no new document may be created");
        assert!(report.removed.is_empty());

        // Still exactly one document, and the mirror now carries the title.
        assert!(repo.get(id.clone()).is_ok());
        assert_eq!(
            repo.get(id.clone())
                .unwrap()
                .extra
                .get("file_name")
                .map(String::as_str),
            Some("Original.txt")
        );
        // The mirrored copy stays on disk.
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
        assert!(
            report.failed.is_empty(),
            "no phase may fail: {:?}",
            report.failed
        );

        // Backfill wrote the title-named file at the tag path (root) + stamped.
        assert!(dir.contains("Awaiting.txt"));
        assert_eq!(
            repo.get(backfill_id.clone())
                .unwrap()
                .extra
                .get("file_name")
                .map(String::as_str),
            Some("Awaiting.txt")
        );

        // Removal deleted the vanished doc.
        assert_eq!(report.removed, vec![gone_id.clone()]);
        assert!(repo.get(gone_id).is_err());

        // Kept was relocated to its tag path (root, untagged) under its title.
        assert!(repo.get(kept_id.clone()).is_ok());
        assert!(dir.contains("Kept.txt"), "kept must be re-placed by title");
        assert!(
            !dir.contains_tree("/a/b", "kept.txt"),
            "stale location must be cleaned up"
        );

        // Addition ingested the new file and left everything else alone.
        assert_eq!(report.ingested, vec![new_id.clone()]);
        assert!(repo.get(new_id.clone()).is_ok());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn backfill_overrides_stale_main_path_with_tag_path() {
        let root = temp_root("backfill-path");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"backfill under a folder".to_vec();

        // Doc without file_name, but with a main_path stamped (by an earlier
        // adoption or manual edit). Untagged → the tag path wins: root.
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
        assert!(dir.contains_tree("", "Draft.txt"));
        assert!(
            !dir.contains_tree("/diploma/2025-2026", "note.txt"),
            "the stale main_path must not be used"
        );
        let docs = repo.query(DocumentQuery::default()).unwrap();
        assert_eq!(docs.len(), 1);
        let doc = &docs[0];
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("Draft.txt")
        );
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some(""),
            "the tag path (root) must be re-stamped"
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
        assert!(dir.contains_tree("", "Draft.txt"));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn moved_file_snaps_back_to_tag_path() {
        let root = temp_root("adopt-move");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"moved to a new folder".to_vec();
        let id = hash_bytes(&bytes);

        // Doc claims the file at /old/, but the file was moved to /new/.
        // Tags always win: the file is snapped back to the tag path.
        seed_tagged_doc(
            &repo,
            "Moved",
            &bytes,
            HashMap::from([
                ("file_name".to_owned(), "doc.txt".to_owned()),
                ("main_path".to_owned(), "/old".to_owned()),
            ]),
            None,
            vec!["keeper".to_owned()],
        );
        dir.add_tree("/new", "doc.txt", &bytes);

        let report = sync_library(&repo, &dir).unwrap();
        assert_eq!(report.linked, vec![id.clone()]);
        assert!(report.removed.is_empty(), "doc must NOT be deleted");
        assert!(report.failed.is_empty(), "snap-back: {:?}", report);

        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some("keeper"),
            "main_path must be re-stamped to the tag path"
        );
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("Moved.txt"),
            "the mirror carries the document title"
        );
        // The soft hierarchy knows the document at /keeper.
        let paths = repo.paths_of(id.clone()).unwrap();
        assert!(
            paths.iter().any(|p| p.path == "keeper"),
            "doc must be soft-assigned to keeper: {:?}",
            paths
        );

        // Idempotent: second run is empty.
        let second = sync_library(&repo, &dir).unwrap();
        assert_eq!(second, LibrarySyncReport::default());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn manual_copy_elsewhere_snaps_original_back_and_links_copy() {
        let root = temp_root("adopt-ambiguous");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"duplicated across folders".to_vec();
        let id = hash_bytes(&bytes);

        // The doc lived at /old/; copies now sit in /a/ and /target/.
        seed_tagged_doc(
            &repo,
            "Dup",
            &bytes,
            HashMap::from([
                ("file_name".to_owned(), "dup.txt".to_owned()),
                ("main_path".to_owned(), "/old".to_owned()),
            ]),
            None,
            vec!["vault".to_owned()],
        );
        dir.add_tree("/a", "dup.txt", &bytes);
        dir.add_tree("/target", "dup.txt", &bytes);

        let report = sync_library(&repo, &dir).unwrap();
        assert_eq!(report.linked, vec![id.clone()]);
        assert!(report.removed.is_empty());
        assert!(report.failed.is_empty());

        // The first sorted copy is snapped back under the title.
        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some("vault")
        );
        assert_eq!(
            doc.extra.get("file_name").map(String::as_str),
            Some("Dup.txt")
        );
        assert!(dir.contains_tree("vault", "Dup.txt"));
        // The other copy survives as a plain mirror of the same bytes.
        assert!(dir.contains_tree("/target", "dup.txt"));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn tag_main_path_follows_dispersion_example() {
        // The product example: tags article (4), study (21), study/mit (15),
        // study/lecture (2) order most-used first and produce
        // study/mit/article/lecture — hierarchical tags need not be in a row.
        let mut dispersion = HashMap::new();
        dispersion.insert("study".to_owned(), 21);
        dispersion.insert("study/mit".to_owned(), 15);
        dispersion.insert("article".to_owned(), 4);
        dispersion.insert("study/lecture".to_owned(), 2);
        let tags = vec![
            "article".to_owned(),
            "study".to_owned(),
            "study/mit".to_owned(),
            "study/lecture".to_owned(),
        ];
        assert_eq!(
            tag_main_path(&tags, &dispersion),
            "study/mit/article/lecture"
        );
    }

    #[test]
    fn tag_main_path_rules() {
        let disp = |kv: &[(&str, u32)]| -> HashMap<String, u32> {
            kv.iter().map(|(t, c)| ((*t).to_owned(), *c)).collect()
        };
        // Untagged and property-only docs land at the root.
        assert_eq!(tag_main_path(&[], &HashMap::new()), "");
        assert_eq!(
            tag_main_path(&["student:Alice".to_owned()], &HashMap::new()),
            ""
        );
        // Ties break by full tag path ascending.
        let ties = disp(&[("alpha", 1), ("zeta", 1)]);
        assert_eq!(
            tag_main_path(&["zeta".to_owned(), "alpha".to_owned()], &ties),
            "alpha/zeta"
        );
        // Colliding last segments keep the nested duplicate.
        let dupes = disp(&[("study/mit/cprog", 3), ("work/cprog", 2)]);
        assert_eq!(
            tag_main_path(
                &["work/cprog".to_owned(), "study/mit/cprog".to_owned()],
                &dupes
            ),
            "cprog/cprog"
        );
    }

    #[test]
    fn tag_path_follows_dispersion_in_sync() {
        let root = temp_root("dispersion");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();

        // Reproduce the product example's dispersion: study 21, study/mit 15,
        // article 4, study/lecture 2 — hero included in every count.
        for i in 0..14 {
            seed_tagged_doc(
                &repo,
                &format!("Filler {i}"),
                format!("filler document bytes number {i}").as_bytes(),
                HashMap::new(),
                None,
                vec!["study/mit".to_owned()],
            );
        }
        seed_tagged_doc(
            &repo,
            "Lecture filler",
            b"lecture filler document bytes",
            HashMap::new(),
            None,
            vec!["study/lecture".to_owned()],
        );
        for i in 0..5 {
            seed_tagged_doc(
                &repo,
                &format!("Keep {i}"),
                format!("keep document bytes number {i}").as_bytes(),
                HashMap::new(),
                None,
                vec!["study".to_owned()],
            );
        }
        for i in 0..3 {
            seed_tagged_doc(
                &repo,
                &format!("Paper {i}"),
                format!("paper document bytes number {i}").as_bytes(),
                HashMap::new(),
                None,
                vec!["article".to_owned()],
            );
        }
        seed_tagged_doc(
            &repo,
            "Hero",
            b"hero document bytes",
            HashMap::new(),
            None,
            vec![
                "article".to_owned(),
                "study".to_owned(),
                "study/mit".to_owned(),
                "study/lecture".to_owned(),
            ],
        );

        let report = sync_library(&repo, &dir).unwrap();
        assert!(
            report.failed.is_empty(),
            "placement must not fail: {:?}",
            report.failed
        );
        assert!(
            dir.contains_tree("study/mit/article/lecture", "Hero.txt"),
            "hero must sit at the dispersion-ordered tag path"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn placement_moves_docs_when_tags_change() {
        let root = temp_root("tag-change");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"document bytes that move on tag change".to_vec();
        let id = seed_tagged_doc(
            &repo,
            "Report",
            &bytes,
            HashMap::from([("file_name".to_owned(), "Report.txt".to_owned())]),
            None,
            vec!["alpha".to_owned()],
        );
        dir.add_tree("", "Report.txt", &bytes);

        let first = sync_library(&repo, &dir).unwrap();
        assert!(first.failed.is_empty());
        assert!(dir.contains_tree("alpha", "Report.txt"));

        // Re-tag to beta: the file must follow.
        {
            let mut doc = repo.get(id.clone()).unwrap();
            doc.tags = vec!["beta".to_owned()];
            repo.put(doc, bytes.to_vec()).unwrap();
        }
        let second = sync_library(&repo, &dir).unwrap();
        assert!(
            second.failed.is_empty(),
            "tag-change placement: {:?}",
            second
        );
        assert!(dir.contains_tree("beta", "Report.txt"));
        assert!(
            !dir.contains_tree("alpha", "Report.txt"),
            "the old folder must be pruned"
        );

        // Idempotent.
        let third = sync_library(&repo, &dir).unwrap();
        assert_eq!(third, LibrarySyncReport::default());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn title_rename_in_place_with_collision_suffix() {
        let root = temp_root("title-rename");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();

        let bytes_a = b"title rename bytes for the first report".to_vec();
        seed_tagged_doc(
            &repo,
            "Report",
            &bytes_a,
            HashMap::from([("file_name".to_owned(), "old-name.txt".to_owned())]),
            None,
            Vec::new(),
        );
        dir.add_tree("", "old-name.txt", &bytes_a);

        let bytes_b = b"title rename bytes for the second report".to_vec();
        seed_tagged_doc(
            &repo,
            "Report",
            &bytes_b,
            HashMap::from([("file_name".to_owned(), "Bee.txt".to_owned())]),
            None,
            Vec::new(),
        );
        dir.add_tree("", "Bee.txt", &bytes_b);

        let report = sync_library(&repo, &dir).unwrap();
        assert!(
            report.failed.is_empty(),
            "rename must not fail: {:?}",
            report
        );
        // Two same-titled docs: one takes the plain name, the other gets (2).
        assert!(dir.contains_tree("", "Report.txt"));
        assert!(dir.contains_tree("", "Report (2).txt"));
        let name_a = repo
            .get(hash_bytes(&bytes_a))
            .unwrap()
            .extra
            .get("file_name")
            .cloned()
            .unwrap();
        let name_b = repo
            .get(hash_bytes(&bytes_b))
            .unwrap()
            .extra
            .get("file_name")
            .cloned()
            .unwrap();
        assert_eq!(
            std::collections::HashSet::from([name_a.clone(), name_b.clone()]),
            std::collections::HashSet::from(["Report.txt".to_owned(), "Report (2).txt".to_owned()]),
            "the stamp set must match the mirror"
        );

        // Idempotent.
        let second = sync_library(&repo, &dir).unwrap();
        assert_eq!(second, LibrarySyncReport::default());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn property_only_docs_stay_at_root_under_their_title() {
        let root = temp_root("prop-only");
        let repo = open_repository(root.display().to_string()).unwrap();
        let dir = FakeDir::new();
        let bytes = b"property tagged document bytes".to_vec();
        seed_tagged_doc(
            &repo,
            "Alice note",
            &bytes,
            HashMap::from([("file_name".to_owned(), "weird-name.txt".to_owned())]),
            None,
            vec!["student:Alice".to_owned()],
        );
        dir.add_tree("", "weird-name.txt", &bytes);

        let report = sync_library(&repo, &dir).unwrap();
        assert!(report.failed.is_empty(), "sync: {:?}", report);
        assert!(dir.contains_tree("", "Alice note.txt"));

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
        assert!(
            doc.extra.contains_key("file_name"),
            "file_name must be stamped (auto-org may have renamed the title)"
        );
        // After placement the doc sits at its tag-derived folder (auto-org
        // replaced the initial /x/y main_path).
        let expected = tag_main_path(&doc.tags, &tag_dispersion(std::slice::from_ref(&doc)));
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some(expected.as_str())
        );
        assert!(
            !doc.tags.is_empty(),
            "auto-organization should have tagged the new doc"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn addition_at_root_gets_tag_placement() {
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
        let expected = tag_main_path(&doc.tags, &tag_dispersion(std::slice::from_ref(&doc)));
        assert_eq!(
            doc.extra.get("main_path").map(String::as_str),
            Some(expected.as_str()),
            "the doc must sit at its tag path"
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
