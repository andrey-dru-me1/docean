//! Shared domain model: documents, tags, and hierarchy.
//!
//! These types are the common language used across every feature module. They
//! are intentionally framework-agnostic — no storage/search/sync implementation
//! details leak into them.

use std::collections::HashMap;

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
    ///
    /// A `HashMap` rather than `BTreeMap` because `flutter_rust_bridge` can
    /// translate `HashMap<K, V>` → Dart `Map<K, V>` but not `BTreeMap`.
    pub extra: HashMap<String, String>,
}

/// A user-defined tag. Tags may be nested (e.g. `receipts/2026`) via [`Tag::parent`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tag {
    pub name: String,
    pub parent: Option<String>,
    pub color: Option<String>,
}

/// A directed parent/child edge used to assemble the folder hierarchy.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HierarchyLink {
    pub parent_id: DocumentId,
    pub child_id: DocumentId,
    /// Ordinal position of the child among its siblings.
    pub position: i32,
}

/// A hierarchy path, e.g. `/work/invoices/2026`.
///
/// A path is an entity independent of any single document: a document may be
/// reachable through *many* paths (each a [`PathAssignment`] edge), and a path
/// may contain many documents. This is a many-to-many relationship mirroring
/// filesystem hard links / multiple virtual folders.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct HierarchyPath {
    /// Canonical, `/`-separated path with a leading slash. Unique in storage.
    pub path: String,
}

/// A member edge of the many-to-many relationship between documents and paths.
///
/// One document ↔ many paths, and one path ↔ many documents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathAssignment {
    pub document_id: DocumentId,
    pub path: String,
    /// Ordinal position of the document among the path's members.
    pub position: i32,
}

/// Extracted/ingested textual content for a document.
///
/// Kept separate from [`Document`] metadata so that raw binary documents can be
/// stored without text, and so multiple extraction passes (OCR, re-parse) can
/// update the text without touching the immutable content hash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Content {
    /// The document this text belongs to.
    pub document_id: DocumentId,
    /// Plain-text content extracted from the document.
    pub text: String,
    /// A short extractor identifier, e.g. `"pdf"`, `"ocr"`, `"markdown"`.
    pub source: String,
}
