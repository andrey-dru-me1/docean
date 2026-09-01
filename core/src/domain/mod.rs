//! Shared domain model: documents, tags, and hierarchy.
//!
//! These types are the common language used across every feature module. They
//! are intentionally framework-agnostic — no storage/search/sync implementation
//! details leak into them.

use std::collections::BTreeMap;

/// Opaque, stable identifier for a document.
pub type DocumentId = String;

/// Whether a hierarchy node is a leaf document or a folder/collection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NodeKind {
    Document,
    Folder,
}

/// A document as tracked by the system.
///
/// Raw bytes live in the blob store (see [`crate::storage`]); this struct is the
/// indexed metadata record.
#[derive(Debug, Clone, PartialEq)]
pub struct Document {
    pub id: DocumentId,
    pub parent_id: Option<DocumentId>,
    pub kind: NodeKind,
    pub title: String,
    pub mime_type: String,
    pub size_bytes: u64,
    /// SHA-256 of the raw bytes, used for de-duplication and integrity checks.
    pub checksum_sha256: String,
    pub tags: Vec<String>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    /// Extensible key/value metadata (EXIF, OCR language, source URL, ...).
    pub extra: BTreeMap<String, String>,
}

/// A user-defined tag. Tags may be nested (e.g. `receipts/2026`) via [`Tag::parent`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Tag {
    pub name: String,
    pub parent: Option<String>,
    pub color: Option<String>,
}

/// A directed parent/child edge used to assemble the folder hierarchy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HierarchyLink {
    pub parent_id: DocumentId,
    pub child_id: DocumentId,
    /// Ordinal position of the child among its siblings.
    pub position: i32,
}
