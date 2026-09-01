//! Local document storage.
//!
//! **Boundary:** durable persistence of document metadata and raw bytes. This is
//! the only module that talks to disk; every other module goes through
//! [`DocumentStore`].
//!
//! **Planned crate:** [`redb`](https://crates.io/crates/redb) — an embedded,
//! typed, transactional key/value store (pure Rust, no C dependency). Metadata
//! records and index lookups live in `redb`; raw bytes are stored as files under
//! the app data directory keyed by content hash.

use std::path::PathBuf;

use crate::domain::{Document, DocumentId, HierarchyLink, NodeKind, Tag};

/// Errors returned by storage operations.
#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("document {0} not found")]
    NotFound(DocumentId),
    #[error("storage is not open")]
    Closed,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// A predicate for listing documents.
#[derive(Debug, Clone, Default)]
pub struct DocumentQuery {
    pub parent: Option<DocumentId>,
    pub tags: Vec<String>,
    pub kind: Option<NodeKind>,
    pub limit: Option<usize>,
    pub offset: Option<usize>,
}

/// Interface for the local document store (metadata index + blob store).
///
/// **Not implemented yet** — this is the contract the `redb`-backed
/// implementation will fulfill.
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

    // --- tags --------------------------------------------------------------

    fn put_tag(&mut self, tag: Tag) -> Result<(), StorageError>;

    fn list_tags(&self) -> Result<Vec<Tag>, StorageError>;
}
