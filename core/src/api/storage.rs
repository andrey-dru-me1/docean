//! Bridge surface for the local document repository.
//!
//! Exposes a [`DocumentRepository`] — an opaque handle wrapping the SQLite +
//! content-addressed store — plus the domain types it operates on. Everything
//! here is reachable from Flutter via `flutter_rust_bridge`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::domain::{
    Content, Document, DocumentSuggestion, FeedbackStats, HierarchyLink, HierarchyPath,
    PathAssignment, SuggestionFeedback, SuggestionKind, Tag,
};
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
    pub fn apply_suggested_tags(&self, document_id: String, tags: Vec<String>) -> Result<(), String> {
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
