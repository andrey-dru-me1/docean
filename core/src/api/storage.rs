//! Bridge surface for the local document repository.
//!
//! Exposes a [`DocumentRepository`] — an opaque handle wrapping the SQLite +
//! content-addressed store — plus the domain types it operates on. Everything
//! here is reachable from Flutter via `flutter_rust_bridge`.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use crate::domain::{
    Content, Document, DocumentSuggestion, FeedbackStats, HierarchyLink, SuggestionFeedback,
    SuggestionKind, Tag,
};
use crate::library_fs::LibraryFs;
use crate::storage::{DocumentQuery, DocumentStore, SqliteDocumentStore};

/// Opaque handle to an open document repository.
///
/// Wraps [`SqliteDocumentStore`] behind an `Arc<Mutex<_>>` so it can be shared
/// and called from the single-threaded Dart isolate without `&mut self` across
/// the FFI boundary. `Clone` is a cheap handle copy onto the same underlying
/// store (used internally so consumers can keep using a repository after
/// handing one to a consuming bridge function).
///
/// The optional [`LibraryFs`] mirrors document bytes as friendly-named files in
/// a user-chosen directory. It lives in its own `Mutex` so reads/writes
/// through `read_bytes`/`ensure_library_file`/`delete` never deadlock the
/// store mutex — library lock is always acquired before any store lock.
#[derive(Clone)]
pub struct DocumentRepository {
    inner: Arc<Mutex<SqliteDocumentStore>>,
    /// Root directory of the store; needed to persist `library_dir.txt`.
    root: String,
    library: Arc<std::sync::Mutex<Option<LibraryFs>>>,
}

impl DocumentRepository {
    pub(crate) fn store(&self) -> Result<std::sync::MutexGuard<'_, SqliteDocumentStore>, String> {
        self.inner
            .lock()
            .map_err(|_| "repository is closed".to_owned())
    }
}

/// Open (or create) a document repository rooted at `root` on disk.
pub fn open_repository(root: String) -> Result<DocumentRepository, String> {
    let store =
        SqliteDocumentStore::open(std::path::PathBuf::from(&root)).map_err(|e| e.to_string())?;
    let library = std::fs::read_to_string(Path::new(&root).join("library_dir.txt"))
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .and_then(|dir| LibraryFs::open(Path::new(&dir)).ok());
    Ok(DocumentRepository {
        inner: Arc::new(Mutex::new(store)),
        root,
        library: Arc::new(std::sync::Mutex::new(library)),
    })
}

// The concrete methods are implemented below and exposed to Dart. Each is a
// thin adapter over the `DocumentStore` trait, translating `StorageError` into
// `String` so the bridge needs no error-type plumbing.
#[flutter_rust_bridge::frb]
impl DocumentRepository {
    /// Insert or replace a document and its raw bytes.
    pub fn put(&self, doc: Document, bytes: Vec<u8>) -> Result<(), String> {
        self.store()?.put(doc, &bytes).map_err(|e| e.to_string())
    }

    /// Fetch a document's metadata.
    pub fn get(&self, id: String) -> Result<Document, String> {
        self.store()?.get(&id).map_err(|e| e.to_string())
    }

    /// Fetch a document's raw bytes.
    ///
    /// When a library mirror is configured and the document's `file_name` is
    /// present and the mirrored file exists, bytes are read from the library
    /// file. On any library failure (or when not configured) it falls back to
    /// the blob store, which remains the source of truth for correctness.
    pub fn read_bytes(&self, id: String) -> Result<Vec<u8>, String> {
        {
            let lib_guard = self
                .library
                .lock()
                .map_err(|_| "library lock poisoned".to_string())?;
            if let Some(lib) = lib_guard.as_ref() {
                if let Ok(doc) = self.get(id.clone()) {
                    if let Some(name) = doc.extra.get("file_name") {
                        if lib.contains(name) {
                            if let Ok(bytes) = lib.read_file(name) {
                                return Ok(bytes);
                            }
                        }
                    }
                }
            }
        }
        self.store()?.read_bytes(&id).map_err(|e| e.to_string())
    }

    /// Delete a document and (when unreferenced) its blob.
    ///
    /// Also best-effort removes the mirrored library file (if any); a library
    /// failure never fails or masks the delete.
    pub fn delete(&self, id: String) -> Result<(), String> {
        let library_file = {
            let lib_guard = self
                .library
                .lock()
                .map_err(|_| "library lock poisoned".to_string())?;
            lib_guard
                .as_ref()
                .and_then(|_| self.get(id.clone()).ok())
                .and_then(|doc| doc.extra.get("file_name").cloned())
        };
        self.store()?.delete(&id).map_err(|e| e.to_string())?;
        if let Some(name) = library_file {
            let lib_guard = self
                .library
                .lock()
                .map_err(|_| "library lock poisoned".to_string())?;
            if let Some(lib) = lib_guard.as_ref() {
                let _ = lib.remove_file(&name);
            }
        }
        Ok(())
    }

    // --- library filesystem ------------------------------------------------

    /// Set (or clear) the library mirror directory.
    ///
    /// When `Some(dir)`, the directory is created (via [`LibraryFs::open`]), the
    /// path is persisted in `<root>/library_dir.txt` **before** the handle is
    /// swapped so that a crash never leaves metadata pointing to an un-writable
    /// location. When `None`, the path file is removed (missing is OK) and the
    /// library handle is dropped.
    pub fn set_library_dir(&self, dir: Option<String>) -> Result<(), String> {
        match dir {
            Some(dir) => {
                let lib = LibraryFs::open(Path::new(&dir)).map_err(|e| e.to_string())?;
                // Persist first; on failure the handle stays unchanged (consistent).
                std::fs::write(Path::new(&self.root).join("library_dir.txt"), &dir)
                    .map_err(|e| e.to_string())?;
                let mut guard = self
                    .library
                    .lock()
                    .map_err(|_| "library lock poisoned".to_string())?;
                *guard = Some(lib);
                Ok(())
            }
            None => {
                let _ = std::fs::remove_file(Path::new(&self.root).join("library_dir.txt"));
                let mut guard = self
                    .library
                    .lock()
                    .map_err(|_| "library lock poisoned".to_string())?;
                *guard = None;
                Ok(())
            }
        }
    }

    /// Returns the configured library directory, or `None`.
    pub fn library_dir(&self) -> Option<String> {
        let guard = self.library.lock().ok()?;
        guard
            .as_ref()
            .map(|lib| lib.dir().to_string_lossy().into_owned())
    }

    /// Ensure a document's file exists on disk with a friendly, deterministic
    /// name and that `extra["file_name"]` is stamped to record that mapping.
    ///
    /// When no library is configured this is a no-op (`Ok(())`).
    ///
    /// The name is derived from the document title + mime/original extension
    /// via [`LibraryFs::title_file_name`], avoiding collisions with
    /// [`LibraryFs::unique_name`]. Blob bytes are read from the store and
    /// written atomically when the file is missing. Stamp order (write first,
    /// then `put`) means a crash after the write but before the stamp is healed
    /// by a subsequent call.
    pub fn ensure_library_file(&self, id: String) -> Result<(), String> {
        let lib_guard = self
            .library
            .lock()
            .map_err(|_| "library lock poisoned".to_string())?;
        let lib = match lib_guard.as_ref() {
            Some(lib) => lib,
            None => return Ok(()),
        };
        let mut doc = self.get(id.clone())?;
        let hash = doc.checksum_sha256.clone();
        let name = match doc.extra.get("file_name") {
            Some(n) => n.clone(),
            None => {
                let base = LibraryFs::title_file_name(
                    Some(&doc.title),
                    doc.extra.get("original_name").map(String::as_str),
                    &doc.mime_type,
                    &hash,
                );
                lib.unique_name(&base)
            }
        };
        let exists = lib.contains(&name);
        let stamped = doc.extra.contains_key("file_name");
        if exists && stamped {
            return Ok(());
        }
        let bytes = self.store()?.read_bytes(&id).map_err(|e| e.to_string())?;
        if !exists {
            lib.write_file(&name, &bytes).map_err(|e| e.to_string())?;
        }
        doc.extra.insert("file_name".to_owned(), name);
        doc.updated_at_ms = now_ms();
        self.store()?.put(doc, &bytes).map_err(|e| e.to_string())?;
        Ok(())
    }

    /// List documents matching a query.
    pub fn query(&self, query: DocumentQuery) -> Result<Vec<Document>, String> {
        self.store()?.query(&query).map_err(|e| e.to_string())
    }

    // --- hierarchy ---------------------------------------------------------

    pub fn link(&self, link: HierarchyLink) -> Result<(), String> {
        self.store()?.link(link).map_err(|e| e.to_string())
    }

    pub fn children(&self, parent: String) -> Result<Vec<String>, String> {
        self.store()?.children(&parent).map_err(|e| e.to_string())
    }

    // --- extracted content -------------------------------------------------

    pub fn put_content(
        &self,
        document_id: String,
        text: String,
        source: String,
    ) -> Result<(), String> {
        self.store()?
            .put_content(&Content {
                document_id,
                text,
                source,
            })
            .map_err(|e| e.to_string())
    }

    pub fn get_content(&self, document_id: String) -> Result<Option<Content>, String> {
        self.store()?
            .get_content(&document_id)
            .map_err(|e| e.to_string())
    }

    pub fn delete_content(&self, document_id: String) -> Result<(), String> {
        self.store()?
            .delete_content(&document_id)
            .map_err(|e| e.to_string())
    }

    // --- tags --------------------------------------------------------------

    pub fn put_tag(&self, tag: Tag) -> Result<(), String> {
        self.store()?.put_tag(tag).map_err(|e| e.to_string())
    }

    pub fn list_tags(&self) -> Result<Vec<Tag>, String> {
        self.store()?.list_tags().map_err(|e| e.to_string())
    }

    /// Replace the full tag set on a document (creating tag-catalog entries as
    /// needed) so the UI can add/remove tags without re-putting raw bytes.
    ///
    /// This is a *user* tag edit, so the persisted `extra` map is marked with
    /// `tags_manual = "true"`. Bulk auto-organization therefore preserves the
    /// user's assignment instead of clobbering it.
    pub fn set_tags(&self, document_id: String, tags: Vec<String>) -> Result<(), String> {
        self.set_tags_internal(document_id.clone(), tags.clone(), true)?;
        // A user tag edit strongly signals preference: record high-weight accept
        // feedback for each authored tag term.
        for t in &tags {
            let _ = self.record_user_feedback(
                crate::domain::SuggestionKind::Tags,
                "tag",
                t,
                "accepted",
                2.0,
            );
        }
        Ok(())
    }

    /// Apply a tag set WITHOUT stamping `tags_manual` (used by suggestion
    /// auto-apply: a suggestion is not a *user* manual edit, so we do not want
    /// it to influence the "user-authored" learning weight).
    pub fn apply_suggested_tags(
        &self,
        document_id: String,
        tags: Vec<String>,
    ) -> Result<(), String> {
        self.set_tags_internal(document_id, tags, false)
    }

    fn set_tags_internal(
        &self,
        document_id: String,
        tags: Vec<String>,
        mark_manual: bool,
    ) -> Result<(), String> {
        let mut doc = self.get(document_id.clone())?;
        doc.tags = tags.clone();
        if mark_manual {
            doc.extra
                .insert("tags_manual".to_owned(), "true".to_owned());
        }
        doc.updated_at_ms = crate::api::storage::now_ms();
        let bytes = self.read_bytes(document_id.clone())?;
        self.put(doc, bytes)?;

        // Mirror the tags into the in-memory search metadata so results can
        // be filtered by them immediately.
        crate::api::search::search_set_metadata(document_id, tags);
        Ok(())
    }

    /// Rename a document through the repository (`repo.put`, reusing the stored
    /// raw bytes so the rename never depends on re-ingestion).
    ///
    /// This is a *user* rename, so the persisted `extra` map is marked with
    /// `title_manual = "true"`. Bulk auto-organization therefore preserves the
    /// user's title instead of clobbering it.
    pub fn update_title(&self, document_id: String, title: String) -> Result<(), String> {
        self.update_title_internal(document_id.clone(), title.clone(), true)?;
        // A user rename strongly signals preference: record high-weight accept
        // feedback for the authored title term.
        let _ = self.record_user_feedback(
            crate::domain::SuggestionKind::Title,
            "title",
            &title,
            "accepted",
            2.0,
        );
        Ok(())
    }

    /// Apply a suggested title WITHOUT stamping `title_manual`.
    pub fn apply_suggested_title(&self, document_id: String, title: String) -> Result<(), String> {
        self.update_title_internal(document_id, title, false)
    }

    fn update_title_internal(
        &self,
        document_id: String,
        title: String,
        mark_manual: bool,
    ) -> Result<(), String> {
        let mut doc = self.get(document_id.clone())?;
        doc.title = title;
        if mark_manual {
            doc.extra
                .insert("title_manual".to_owned(), "true".to_owned());
        }
        doc.updated_at_ms = crate::api::storage::now_ms();
        let tags = doc.tags.clone();
        let bytes = self.read_bytes(document_id.clone())?;
        self.put(doc, bytes)?;

        // Mirror the tags into the search metadata so the renamed document
        // stays filterable with its existing assignments.
        crate::api::search::search_set_metadata(document_id, tags);
        Ok(())
    }

    // --- pending suggestions + feedback -----------------------------------
    //
    // These are the low-level CRUD surfaces for the review UI. The higher-level
    // "suggest + apply + record feedback" flows live in `crate::api::auto_org`;
    // this repository only persists and reads the rows.

    /// Persist (or update) one pending suggestion row.
    pub fn put_suggestion(&self, suggestion: DocumentSuggestion) -> Result<(), String> {
        let mut store = self.store()?;
        store.put_suggestion(&suggestion).map_err(|e| e.to_string())
    }

    /// Record a user-authored accept/reject feedback event (weight 2.0 for
    /// manual edits). The ML can't change behavior — it only learns more
    /// strongly from what the user typed themselves.
    fn record_user_feedback(
        &self,
        kind: crate::domain::SuggestionKind,
        context: &str,
        term: &str,
        action: &str,
        weight: f64,
    ) -> Result<(), String> {
        self.record_feedback(crate::domain::SuggestionFeedback {
            id: format!(
                "{}-{}-{}-{}",
                crate::api::storage::now_ms(),
                context,
                term,
                action
            ),
            kind,
            context: context.to_owned(),
            term: term.to_owned(),
            action: action.to_owned(),
            weight,
            created_at_ms: crate::api::storage::now_ms(),
        })
    }

    /// Fetch a document's suggestions (optionally filtered by kind), newest
    /// alternatives first per kind.
    pub fn suggestions_of(
        &self,
        document_id: String,
        kind: Option<SuggestionKind>,
    ) -> Result<Vec<DocumentSuggestion>, String> {
        let store = self.store()?;
        store
            .suggestions_for_document(&document_id.to_owned(), kind)
            .map_err(|e| e.to_string())
    }

    /// Update the review status (pending/applied/dismissed) of one suggestion.
    pub fn mark_suggestion(
        &self,
        suggestion_id: String,
        status: crate::domain::SuggestionStatus,
    ) -> Result<(), String> {
        let mut store = self.store()?;
        store
            .mark_suggestion(&suggestion_id, status)
            .map_err(|e| e.to_string())
    }

    /// Remove all suggestion rows for a document.
    pub fn delete_document_suggestions(&self, document_id: String) -> Result<(), String> {
        let mut store = self.store()?;
        store
            .delete_suggestions_for_document(&document_id.to_owned())
            .map_err(|e| e.to_string())
    }

    /// Persist one feedback event.
    pub fn record_feedback(&self, feedback: SuggestionFeedback) -> Result<(), String> {
        let mut store = self.store()?;
        store.record_feedback(&feedback).map_err(|e| e.to_string())
    }

    /// Aggregated accept/reject evidence per term (feedback model input).
    pub fn feedback_stats(
        &self,
        kind: Option<SuggestionKind>,
        context: Option<String>,
    ) -> Result<HashMap<String, FeedbackStats>, String> {
        let store = self.store()?;
        store
            .feedback_stats(kind, context.as_deref())
            .map_err(|e| e.to_string())
    }

    /// Wipe all learning data.
    pub fn clear_feedback(&self) -> Result<(), String> {
        let mut store = self.store()?;
        store.clear_feedback().map_err(|e| e.to_string())
    }

    /// Housekeeping: drop non-pending suggestions older than `older_than_ms`.
    pub fn prune_suggestions(&self, older_than_ms: i64) -> Result<(), String> {
        let mut store = self.store()?;
        store
            .prune_suggestions(older_than_ms)
            .map_err(|e| e.to_string())
    }
}

/// Current wall-clock time in milliseconds (shared by metadata update paths).
pub(crate) fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::fs;
    use std::path::PathBuf;

    use crate::api::storage::open_repository;
    use crate::domain::{Document, NodeKind};
    use crate::storage::hash_bytes;

    /// A temp root for a fresh on-disk repository.
    fn temp_root(tag: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let mut p = std::env::temp_dir();
        p.push(format!(
            "docean-storage-bridge-{tag}-{}-{}",
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
    fn ensure_library_file_backfills_name_file_and_extra() {
        let root = temp_root("lib-backfill");
        let repo = open_repository(root.display().to_string()).unwrap();
        let lib_dir = temp_root("lib-backfill-dir");
        repo.set_library_dir(Some(lib_dir.display().to_string()))
            .unwrap();

        let bytes = b"quarterly report contents";
        let doc = make_doc("Quarterly Report.pdf", "application/pdf", bytes);
        let id = doc.id.clone();
        repo.put(doc, bytes.to_vec()).unwrap();

        repo.ensure_library_file(id.clone()).unwrap();

        let doc = repo.get(id.clone()).unwrap();
        let name = doc
            .extra
            .get("file_name")
            .expect("file_name should be stamped")
            .clone();
        assert_eq!(name, "Quarterly Report.pdf");
        assert!(PathBuf::from(&lib_dir).join(&name).exists());
    }

    #[test]
    fn ensure_library_file_idempotent_second_call() {
        let root = temp_root("lib-idempotent");
        let repo = open_repository(root.display().to_string()).unwrap();
        let lib_dir = temp_root("lib-idempotent-dir");
        repo.set_library_dir(Some(lib_dir.display().to_string()))
            .unwrap();

        let bytes = b"same content twice";
        let doc = make_doc("Notes.txt", "text/plain", bytes);
        let id = doc.id.clone();
        repo.put(doc, bytes.to_vec()).unwrap();

        repo.ensure_library_file(id.clone()).unwrap();
        let name_before = repo
            .get(id.clone())
            .unwrap()
            .extra
            .get("file_name")
            .unwrap()
            .clone();
        assert_eq!(fs::read_dir(&lib_dir).unwrap().count(), 1);

        repo.ensure_library_file(id.clone()).unwrap();
        let doc = repo.get(id.clone()).unwrap();
        assert_eq!(doc.extra.get("file_name").unwrap(), &name_before);
        assert_eq!(fs::read_dir(&lib_dir).unwrap().count(), 1);
    }

    #[test]
    fn read_bytes_prefers_library_file_after_blob_deleted() {
        let root = temp_root("lib-read");
        let repo = open_repository(root.display().to_string()).unwrap();
        let lib_dir = temp_root("lib-read-dir");
        repo.set_library_dir(Some(lib_dir.display().to_string()))
            .unwrap();

        let bytes = b"blob backup source";
        let doc = make_doc("Doc.pdf", "application/pdf", bytes);
        let id = doc.id.clone();
        let hash = doc.checksum_sha256.clone();
        repo.put(doc, bytes.to_vec()).unwrap();
        repo.ensure_library_file(id.clone()).unwrap();

        assert_eq!(repo.read_bytes(id.clone()).unwrap(), bytes);

        let blob_path = root.join("blobs").join(&hash);
        assert!(blob_path.exists());
        fs::remove_file(&blob_path).unwrap();

        assert_eq!(repo.read_bytes(id.clone()).unwrap(), bytes);
    }

    #[test]
    fn delete_removes_library_file() {
        let root = temp_root("lib-delete");
        let repo = open_repository(root.display().to_string()).unwrap();
        let lib_dir = temp_root("lib-delete-dir");
        repo.set_library_dir(Some(lib_dir.display().to_string()))
            .unwrap();

        let bytes = b"to be deleted";
        let doc = make_doc("Gone.pdf", "application/pdf", bytes);
        let id = doc.id.clone();
        repo.put(doc, bytes.to_vec()).unwrap();
        repo.ensure_library_file(id.clone()).unwrap();

        let name = repo
            .get(id.clone())
            .unwrap()
            .extra
            .get("file_name")
            .unwrap()
            .clone();
        assert!(PathBuf::from(&lib_dir).join(&name).exists());

        repo.delete(id.clone()).unwrap();
        assert!(repo.get(id.clone()).is_err());
        assert!(!PathBuf::from(&lib_dir).join(&name).exists());
    }

    #[test]
    fn set_library_dir_persists_across_reopen() {
        let root = temp_root("lib-persist");
        let lib_dir = temp_root("lib-persist-dir");
        {
            let repo = open_repository(root.display().to_string()).unwrap();
            assert_eq!(repo.library_dir(), None);
            repo.set_library_dir(Some(lib_dir.display().to_string()))
                .unwrap();
            assert_eq!(repo.library_dir(), Some(lib_dir.display().to_string()));
        }
        let reopened = open_repository(root.display().to_string()).unwrap();
        assert_eq!(reopened.library_dir(), Some(lib_dir.display().to_string()));
    }

    #[test]
    fn set_library_dir_none_clears() {
        let root = temp_root("lib-clear");
        let lib_dir = temp_root("lib-clear-dir");
        let repo = open_repository(root.display().to_string()).unwrap();

        repo.set_library_dir(Some(lib_dir.display().to_string()))
            .unwrap();
        assert!(root.join("library_dir.txt").exists());

        repo.set_library_dir(None).unwrap();
        assert_eq!(repo.library_dir(), None);
        assert!(!root.join("library_dir.txt").exists());

        // And stays cleared across a reopen
        let reopened = open_repository(root.display().to_string()).unwrap();
        assert_eq!(reopened.library_dir(), None);
        assert!(!root.join("library_dir.txt").exists());
    }

    #[test]
    fn ensure_library_file_noop_without_library() {
        let root = temp_root("lib-noop");
        let repo = open_repository(root.display().to_string()).unwrap();

        let bytes = b"no library configured";
        let doc = make_doc("Plain.txt", "text/plain", bytes);
        let id = doc.id.clone();
        repo.put(doc, bytes.to_vec()).unwrap();

        repo.ensure_library_file(id.clone()).unwrap();
        let doc = repo.get(id.clone()).unwrap();
        assert!(!doc.extra.contains_key("file_name"));
    }
}
