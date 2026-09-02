//! Lightweight in-memory semantic search index.
//!
//! This is a deterministic, fully-offline semantic vector index. It hashes
//! character n-grams of indexed text into dense vectors and answers queries by
//! cosine similarity, so semantically related text (shared vocabulary with
//! rephrasing) ranks above exact-match-only. It deliberately requires **no AI
//! provider** — the same [`crate::ai::AiProvider::embed`] surface can replace the
//! hasher later without changing callers.
//!
//! The module is additive to [`super::MemorySearch`]: the full-text index and the
//! vector index are separate [`super::SearchIndex`] implementations, and the
//! bridge (`crate::api::search`) composes them for hybrid queries.

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex};

use crate::domain::DocumentId;

use super::{excerpt, SearchHit, SearchIndex};

/// Fixed dimensionality of the hashed-vector space.
pub const SEMANTIC_DIM: usize = 256;

/// A dense, normalized vector embedding.
type Vector = Vec<f32>;

/// Generate a normalized `dim`-dimensional vector from hashed character
/// n-grams. Each n-gram contributes to a few dimensions (with sign), then the
/// whole vector is L2-normalized so cosine similarity equals the dot product.
pub fn hash_embed(text: &str, dim: usize) -> Vector {
    let mut v = vec![0.0f32; dim];
    let mut grams: HashSet<String> = text
        .to_lowercase()
        .chars()
        .collect::<Vec<_>>()
        .windows(3)
        .map(|w| w.iter().collect::<String>())
        .collect();
    if grams.is_empty() {
        // Fall back to word unigrams for very short inputs.
        for w in text.to_lowercase().split(|c: char| !c.is_alphanumeric()) {
            if !w.is_empty() {
                grams.insert(w.to_owned());
            }
        }
    }
    for g in &grams {
        let h = hash_str(g);
        let idx = (h as usize) % dim;
        let sign = if h & 1 == 0 { 1.0 } else { -1.0 };
        v[idx] += sign;
        // Second bucket smooths collisions.
        let idx2 = ((h >> 8) as usize) % dim;
        v[idx2] += sign * 0.5;
    }
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in &mut v {
            *x /= norm;
        }
    }
    v
}

fn hash_str(s: &str) -> u64 {
    let mut h = DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
}

/// An in-memory vector store keyed by document id.
#[derive(Default)]
pub struct SemanticMemorySearch {
    docs: HashMap<DocumentId, String>,
    vectors: HashMap<DocumentId, Vector>,
}

impl SemanticMemorySearch {
    pub fn new() -> Self {
        Self::default()
    }

    fn embed_doc(&self, text: &str) -> Vector {
        hash_embed(text, SEMANTIC_DIM)
    }

    /// Build the context snippet around the best-scoring span of `body` for
    /// `query`. The snippet is centered on the first match so the UI can show
    /// *why* the document matched.
    fn snippet_for(&self, body: &str, query: &str) -> String {
        let lower_body = body.to_lowercase();
        let needle = query.trim().to_lowercase();
        if needle.is_empty() {
            return excerpt(body, 240);
        }
        let idx = lower_body.find(&needle).unwrap_or(0);
        let start = idx.saturating_sub(70);
        let end = (idx + needle.len() + 170).min(body.len());
        let mut s: String = body.chars().skip(start).take(end - start).collect();
        if start > 0 {
            s = format!("…{s}");
        }
        if end < body.len() {
            s = format!("{s}…");
        }
        s
    }
}

impl SearchIndex for SemanticMemorySearch {
    fn index(&mut self, doc: &DocumentId, text: &str) -> anyhow::Result<()> {
        self.docs.insert(doc.clone(), text.to_owned());
        let vector = self.embed_doc(text);
        self.vectors.insert(doc.clone(), vector);
        Ok(())
    }

    fn remove(&mut self, doc: &DocumentId) -> anyhow::Result<()> {
        self.docs.remove(doc);
        self.vectors.remove(doc);
        Ok(())
    }

    fn search(&self, query: &super::Query, limit: usize) -> anyhow::Result<Vec<SearchHit>> {
        let text = match query {
            super::Query::Semantic(t) | super::Query::Hybrid { semantic: t, .. } => t,
            super::Query::Text(_) => return Ok(Vec::new()),
        };
        let qv = self.embed_doc(text);
        let mut scored: Vec<SearchHit> = self
            .vectors
            .iter()
            .map(|(id, v)| {
                // Since `hash_embed` produces L2-normalized vectors, the dot
                // product equals cosine similarity in `[-1, 1]`. Remap to a
                // `[0, 1]` relevance score (same contract as the engine's
                // other backends) and drop non-positive results.
                let score = super::relevance((v.iter().zip(&qv).map(|(a, b)| a * b).sum::<f32>() + 1.0) / 2.0);
                SearchHit {
                    document_id: id.clone(),
                    score,
                    snippet: self.docs.get(id).map(|b| self.snippet_for(b, text)),
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

/// A cloneable, interior-mutable handle to a shared [`SemanticMemorySearch`].
#[derive(Clone)]
pub struct SharedSemanticMemorySearch(Arc<Mutex<SemanticMemorySearch>>);

impl SharedSemanticMemorySearch {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(SemanticMemorySearch::new())))
    }
}

impl Default for SharedSemanticMemorySearch {
    fn default() -> Self {
        Self::new()
    }
}

impl SearchIndex for SharedSemanticMemorySearch {
    fn index(&mut self, doc: &DocumentId, text: &str) -> anyhow::Result<()> {
        self.0.lock().unwrap().index(doc, text)
    }

    fn remove(&mut self, doc: &DocumentId) -> anyhow::Result<()> {
        self.0.lock().unwrap().remove(doc)
    }

    fn search(&self, query: &super::Query, limit: usize) -> anyhow::Result<Vec<SearchHit>> {
        self.0.lock().unwrap().search(query, limit)
    }
}
