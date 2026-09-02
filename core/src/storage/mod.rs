//! Local document storage.
//!
//! **Boundary:** durable persistence of document metadata, path/tag assignments,
//! extracted text, and raw bytes. This is the only module that talks to disk;
//! every other module goes through [`DocumentStore`].
//!
//! # Implementation
//!
//! * **Metadata index** — SQLite via [`rusqlite`](https://crates.io/crates/rusqlite)
//!   (compiled from source with the `bundled` feature). See [`schema`] for the
//!   migrations that build and version the tables.
//! * **Raw bytes** — a content-addressed file store under `<root>/blobs/<hash>`
//!   (SHA-256), giving deduplication by construction and a stable key for later
//!   conflict resolution. See the [`blob`] module.
//!
//! The concrete [`SqliteDocumentStore`] lives in the [`sqlite`] submodule; the
//! [`DocumentStore`] trait is the contract the rest of the system depends on.

mod blob;
mod schema;
mod sqlite;

#[cfg(test)]
mod tests;

use std::path::PathBuf;

use crate::domain::{
    Content, Document, DocumentId, HierarchyLink, HierarchyPath, NodeKind, PathAssignment, Tag,
};

pub use blob::{hash_bytes, BlobStore};
pub use sqlite::SqliteDocumentStore;

/// Errors returned by storage operations.
#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("document {0} not found")]
    NotFound(DocumentId),
    #[error("path {0} not found")]
    PathNotFound(String),
    #[error("storage is not open")]
    Closed,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
}

/// A predicate for listing documents.
#[derive(Debug, Clone, Default)]
pub struct DocumentQuery {
    pub parent: Option<DocumentId>,
    pub tags: Vec<String>,
    pub kind: Option<NodeKind>,
    pub limit: Option<u32>,
    pub offset: Option<u32>,
}

/// Interface for the local document store (metadata index + blob store).
///
/// Implemented by [`SqliteDocumentStore`].
pub trait DocumentStore {
    /// Open (or create) a store rooted at `root`.
    fn open(root: PathBuf) -> Result<Self, StorageError>
    where
        Self: Sized;

    /// Insert or replace a document and its raw bytes.
    fn put(&mut self, doc: Document, bytes: &[u8]) -> Result<(), StorageError>;

    /// Fetch a document's metadata.
    fn get(&self, id: &DocumentId) -> Result<Document, StorageError>;

    /// Fetch a document's raw bytes.
    fn read_bytes(&self, id: &DocumentId) -> Result<Vec<u8>, StorageError>;

    fn delete(&mut self, id: &DocumentId) -> Result<(), StorageError>;

    fn query(&self, q: &DocumentQuery) -> Result<Vec<Document>, StorageError>;

    // --- hierarchy ---------------------------------------------------------

    fn link(&mut self, link: HierarchyLink) -> Result<(), StorageError>;

    fn children(&self, parent: &DocumentId) -> Result<Vec<DocumentId>, StorageError>;

    // --- many-to-many paths ------------------------------------------------

    /// Put (upsert) a hierarchy path into the catalog.
    fn put_path(&mut self, path: &HierarchyPath) -> Result<(), StorageError>;

    /// List all hierarchy paths.
    fn list_paths(&self) -> Result<Vec<HierarchyPath>, StorageError>;

    /// Delete a hierarchy path and sever all of its document assignments.
    fn delete_path(&mut self, path: &str) -> Result<(), StorageError>;

    /// Assign a document to an additional hierarchy path (many-to-many).
    fn assign_path(&mut self, assignment: PathAssignment) -> Result<(), StorageError>;

    /// Remove a document from a hierarchy path.
    fn unassign_path(&mut self, document_id: &DocumentId, path: &str) -> Result<(), StorageError>;

    /// All paths through which a document is reachable.
    fn paths_of(&self, document_id: &DocumentId) -> Result<Vec<HierarchyPath>, StorageError>;

    /// Document ids assigned to the given path, ordered by `position`.
    fn documents_at(&self, path: &str) -> Result<Vec<DocumentId>, StorageError>;

    // --- extracted content -------------------------------------------------

    /// Upsert the extracted text content for a document.
    fn put_content(&mut self, content: &Content) -> Result<(), StorageError>;

    /// Fetch the extracted text content for a document, if present.
    fn get_content(&self, document_id: &DocumentId) -> Result<Option<Content>, StorageError>;

    fn delete_content(&mut self, document_id: &DocumentId) -> Result<(), StorageError>;

    // --- tags --------------------------------------------------------------

    fn put_tag(&mut self, tag: Tag) -> Result<(), StorageError>;

    fn list_tags(&self) -> Result<Vec<Tag>, StorageError>;

    /// Replace the full tag set on a document, creating tag-catalog entries as
    /// needed. No-op on documents that don't exist (see [`StorageError::NotFound`]).
    fn set_tags(&mut self, document_id: &DocumentId, tags: &[String]) -> Result<(), StorageError>;
}
