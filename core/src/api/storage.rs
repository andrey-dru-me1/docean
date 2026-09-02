//! Bridge surface for the local document repository.
//!
//! Exposes a [`DocumentRepository`] — an opaque handle wrapping the SQLite +
//! content-addressed store — plus the domain types it operates on. Everything
//! here is reachable from Flutter via `flutter_rust_bridge`.

use std::sync::{Arc, Mutex};

use crate::domain::{Content, Document, HierarchyLink, HierarchyPath, PathAssignment, Tag};
use crate::storage::{DocumentQuery, DocumentStore, SqliteDocumentStore};

/// Opaque handle to an open document repository.
///
/// Wraps [`SqliteDocumentStore`] behind an `Arc<Mutex<_>>` so it can be shared
/// and called from the single-threaded Dart isolate without `&mut self` across
/// the FFI boundary. `Clone` is a cheap handle copy onto the same underlying
/// store (used internally so consumers can keep using a repository after
/// handing one to a consuming bridge function).
#[derive(Clone)]
pub struct DocumentRepository {
    inner: Arc<Mutex<SqliteDocumentStore>>,
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
        SqliteDocumentStore::open(std::path::PathBuf::from(root)).map_err(|e| e.to_string())?;
    Ok(DocumentRepository {
        inner: Arc::new(Mutex::new(store)),
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
    pub fn read_bytes(&self, id: String) -> Result<Vec<u8>, String> {
        self.store()?.read_bytes(&id).map_err(|e| e.to_string())
    }

    /// Delete a document and (when unreferenced) its blob.
    pub fn delete(&self, id: String) -> Result<(), String> {
        self.store()?.delete(&id).map_err(|e| e.to_string())
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

    // --- many-to-many paths ------------------------------------------------

    pub fn put_path(&self, path: String) -> Result<(), String> {
        self.store()?
            .put_path(&HierarchyPath { path })
            .map_err(|e| e.to_string())
    }

    pub fn list_paths(&self) -> Result<Vec<HierarchyPath>, String> {
        self.store()?.list_paths().map_err(|e| e.to_string())
    }

    pub fn delete_path(&self, path: String) -> Result<(), String> {
        self.store()?.delete_path(&path).map_err(|e| e.to_string())
    }

    pub fn assign_path(&self, assignment: PathAssignment) -> Result<(), String> {
        self.store()?
            .assign_path(assignment)
            .map_err(|e| e.to_string())
    }

    pub fn unassign_path(&self, document_id: String, path: String) -> Result<(), String> {
        self.store()?
            .unassign_path(&document_id, &path)
            .map_err(|e| e.to_string())
    }

    pub fn paths_of(&self, document_id: String) -> Result<Vec<HierarchyPath>, String> {
        self.store()?
            .paths_of(&document_id)
            .map_err(|e| e.to_string())
    }

    pub fn documents_at(&self, path: String) -> Result<Vec<String>, String> {
        self.store()?.documents_at(&path).map_err(|e| e.to_string())
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
        let mut doc = self.get(document_id.clone())?;
        doc.tags = tags.clone();
        doc.extra
            .insert("tags_manual".to_owned(), "true".to_owned());
        doc.updated_at_ms = crate::api::storage::now_ms();
        let bytes = self.read_bytes(document_id.clone())?;
        self.put(doc, bytes)?;

        // Mirror the tags (and the unchanged paths) into the in-memory search
        // metadata so results can be filtered by them immediately.
        let paths = self
            .paths_of(document_id.clone())?
            .into_iter()
            .map(|p| p.path)
            .collect();
        crate::api::search::search_set_metadata(document_id, tags, paths);
        Ok(())
    }

    /// Rename a document through the repository (`repo.put`, reusing the stored
    /// raw bytes so the rename never depends on re-ingestion).
    ///
    /// This is a *user* rename, so the persisted `extra` map is marked with
    /// `title_manual = "true"`. Bulk auto-organization therefore preserves the
    /// user's title instead of clobbering it.
    pub fn update_title(&self, document_id: String, title: String) -> Result<(), String> {
        let mut doc = self.get(document_id.clone())?;
        doc.title = title;
        doc.extra
            .insert("title_manual".to_owned(), "true".to_owned());
        doc.updated_at_ms = crate::api::storage::now_ms();
        let tags = doc.tags.clone();
        let bytes = self.read_bytes(document_id.clone())?;
        self.put(doc, bytes)?;

        // Mirror the (unchanged) tags and paths into the search metadata so the
        // renamed document stays filterable with its existing assignments.
        let paths = self
            .paths_of(document_id.clone())?
            .into_iter()
            .map(|p| p.path)
            .collect();
        crate::api::search::search_set_metadata(document_id, tags, paths);
        Ok(())
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
