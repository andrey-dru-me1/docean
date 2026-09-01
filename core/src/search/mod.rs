//! Full-text and semantic search.
//!
//! **Boundary:** indexing and querying document text and embeddings.
//!
//! **Planned crates:**
//! * [`tantivy`](https://crates.io/crates/tantivy) — inverted-index full-text search.
//! * [`fastembed`](https://crates.io/crates/fastembed) — local ONNX embedding models for semantic search.
//! * [`usearch`](https://crates.io/crates/usearch) — HNSW vector similarity index.

use crate::domain::DocumentId;

/// A single search result.
#[derive(Debug, Clone, Default)]
pub struct SearchHit {
    pub document_id: DocumentId,
    pub score: f32,
    pub snippet: Option<String>,
}

/// Query kinds supported by the search service.
#[derive(Debug, Clone)]
pub enum Query {
    Text(String),
    Semantic(String),
    Hybrid { text: String, semantic: String },
}

/// Interface for the search service (full-text + semantic + hybrid).
pub trait SearchIndex {
    fn index(&mut self, doc: &DocumentId, text: &str) -> anyhow::Result<()>;

    fn remove(&mut self, doc: &DocumentId) -> anyhow::Result<()>;

    fn search(&self, query: &Query, limit: usize) -> anyhow::Result<Vec<SearchHit>>;
}
