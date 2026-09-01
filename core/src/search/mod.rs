//! Full-text and semantic search.
//!
//! **Boundary:** indexing and querying document text and embeddings.
//!
//! **Planned crates:**
//! * [`tantivy`](https://crates.io/crates/tantivy) — inverted-index full-text search.
//! * [`fastembed`](https://crates.io/crates/fastembed) — local ONNX embedding models for semantic search.
//! * [`usearch`](https://crates.io/crates/usearch) — HNSW vector similarity index.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

mod near_dup;

pub use near_dup::{
    minhash_signature, shingles, MinHashSignature, NearDuplicateIndex, NearDuplicateMatch,
};

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

/// A simple, in-memory full-text index.
///
/// This is a lightweight, dependency-free implementation of [`SearchIndex`] used
/// as a stopgap until the full `tantivy` + embeddings engine lands. It scores
/// documents by the fraction of normalized query terms they contain and returns
/// a whitespace-normalized snippet with each hit.
#[derive(Default)]
pub struct MemorySearch {
    docs: HashMap<DocumentId, String>,
}

impl MemorySearch {
    pub fn new() -> Self {
        Self::default()
    }

    fn tokenize(text: &str) -> Vec<String> {
        text.split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .map(|w| w.to_lowercase())
            .collect()
    }
}

impl SearchIndex for MemorySearch {
    fn index(&mut self, doc: &DocumentId, text: &str) -> anyhow::Result<()> {
        self.docs.insert(doc.clone(), text.to_owned());
        Ok(())
    }

    fn remove(&mut self, doc: &DocumentId) -> anyhow::Result<()> {
        self.docs.remove(doc);
        Ok(())
    }

    fn search(&self, query: &Query, limit: usize) -> anyhow::Result<Vec<SearchHit>> {
        let text = match query {
            Query::Text(t) | Query::Semantic(t) => t,
            Query::Hybrid { text, .. } => text,
        };
        let qterms = MemorySearch::tokenize(text);
        if qterms.is_empty() {
            return Ok(Vec::new());
        }

        let mut scored: Vec<SearchHit> = self
            .docs
            .iter()
            .map(|(id, body)| {
                let body_terms = MemorySearch::tokenize(body);
                let overlap = qterms.iter().filter(|t| body_terms.contains(t)).count();
                let score = overlap as f32 / qterms.len() as f32;
                SearchHit {
                    document_id: id.clone(),
                    score,
                    snippet: Some(excerpt(body, 240)),
                }
            })
            .filter(|h| h.score > 0.0)
            .collect();

        scored.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        scored.truncate(limit);
        Ok(scored)
    }
}

/// A cloneable, interior-mutable handle to a shared [`MemorySearch`].
#[derive(Clone)]
pub struct SharedMemorySearch(Arc<Mutex<MemorySearch>>);

impl SharedMemorySearch {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(MemorySearch::new())))
    }
}

impl Default for SharedMemorySearch {
    fn default() -> Self {
        Self::new()
    }
}

impl SearchIndex for SharedMemorySearch {
    fn index(&mut self, doc: &DocumentId, text: &str) -> anyhow::Result<()> {
        self.0.lock().unwrap().index(doc, text)
    }

    fn remove(&mut self, doc: &DocumentId) -> anyhow::Result<()> {
        self.0.lock().unwrap().remove(doc)
    }

    fn search(&self, query: &Query, limit: usize) -> anyhow::Result<Vec<SearchHit>> {
        self.0.lock().unwrap().search(query, limit)
    }
}

/// A short, whitespace-normalized excerpt of `text`, capped at `max` chars.
fn excerpt(text: &str, max: usize) -> String {
    let cleaned: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    cleaned.chars().take(max).collect()
}
