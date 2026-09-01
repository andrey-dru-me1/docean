//! Shared embedding index — the single vector store for the whole core.
//!
//! This module is intentionally a *shared* dependency: the chat assistant (RAG),
//! semantic search, and later auto-organization all reuse the same
//! [`embed`]/[`VectorStore`] surface rather than rolling their own embedding
//! plumbing.
//!
//! # Model
//!
//! The embedding model is a **lightweight local model**, not a generative LLM.
//! It runs fully offline with no external service. By default it is
//! [`HashEmbedder`], a deterministic, dependency-free character n-gram hasher
//! that maps text to a normalized dense vector. The [`Embedder`] trait is the
//! extension point: a sentence-transformer via `fastembed`/ONNX Runtime can be
//! dropped in later *without* changing any callers, because everything depends
//! on the trait + [`VectorStore`], not on the concrete featurizer.
//!
//! # Nearest neighbor
//!
//! [`VectorStore`] keeps chunk embeddings in memory and answers cosine-similarity
//! nearest-neighbor queries. For the corpus sizes docer targets (a personal
//! library), brute force is exact and plenty fast; [`VectorStore::nearest`] is
//! the single primitive later auto-organization will call.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use crate::domain::DocumentId;

/// Dimensionality of the default [`HashEmbedder`].
pub const EMBED_DIM: usize = 256;

/// A vector embedding of a piece of text.
pub type Embedding = Vec<f32>;

/// Abstracts an embedding model (e.g. hashed n-grams today, a sentence-transformer
/// via `fastembed`/ONNX later).
#[flutter_rust_bridge::frb(ignore)]
pub trait Embedder: Send + Sync {
    /// Embed `text` into a normalized dense vector of [`Embedder::dim`] scalars.
    fn embed(&self, text: &str) -> Embedding;

    /// The fixed output dimensionality.
    fn dim(&self) -> usize;
}

/// A deterministic, fully offline hashed character n-gram embedder.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Clone, Copy, Default)]
pub struct HashEmbedder {}

impl HashEmbedder {
    pub fn new() -> Self {
        Self {}
    }
}

impl Embedder for HashEmbedder {
    fn embed(&self, text: &str) -> Embedding {
        hash_embed(text, EMBED_DIM)
    }

    fn dim(&self) -> usize {
        EMBED_DIM
    }
}

/// The default, process-wide embedder (the shared, reusable one).
fn default_embedder() -> &'static HashEmbedder {
    static E: std::sync::OnceLock<HashEmbedder> = std::sync::OnceLock::new();
    E.get_or_init(HashEmbedder::new)
}

/// Embed `text` using the shared default embedder.
pub fn embed(text: &str) -> Embedding {
    default_embedder().embed(text)
}

/// Hash `text` into a dense `dim`-vector, normalized to unit length.
fn hash_embed(text: &str, dim: usize) -> Embedding {
    let mut vec = vec![0.0f32; dim];

    // Character n-grams (1..=3) — captures subword/typo-robust overlap.
    let lower: Vec<char> = text.to_lowercase().chars().collect();
    for n in 1..=3usize {
        if lower.len() < n {
            break;
        }
        for window in lower.windows(n) {
            let gram: String = window.iter().collect();
            add_feature(&mut vec, dim, gram.as_bytes());
        }
    }

    // Whole lowercase word tokens — stronger signal for shared vocabulary.
    for token in text.split(|c: char| !c.is_alphanumeric()) {
        if token.is_empty() {
            continue;
        }
        add_feature(&mut vec, dim, token.to_lowercase().as_bytes());
    }

    normalize(&mut vec);
    vec
}

/// Add a single hashed feature (signed unit impulse) into `vec`.
fn add_feature(vec: &mut [f32], dim: usize, feature: &[u8]) {
    let mut hasher = DefaultHasher::new();
    feature.hash(&mut hasher);
    let h = hasher.finish();
    let idx = (h % dim as u64) as usize;
    let sign = if (h >> 32) & 1 == 0 { 1.0f32 } else { -1.0f32 };
    vec[idx] += sign;
}

/// L2-normalize in place (no-op for the zero vector).
fn normalize(vec: &mut [f32]) {
    let norm: f32 = vec.iter().map(|v| v * v).sum::<f32>().sqrt();
    if norm > 0.0 {
        for v in vec.iter_mut() {
            *v /= norm;
        }
    }
}

/// Cosine similarity between two equal-length vectors, in `[-1, 1]`.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    debug_assert_eq!(a.len(), b.len());
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    dot.clamp(-1.0, 1.0)
}

/// A stored chunk vector plus its source text (for snippets).
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Clone)]
pub struct VectorRecord {
    pub document_id: DocumentId,
    pub text: String,
    pub vector: Embedding,
}

/// A cosine-similarity nearest-neighbor hit.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Clone)]
pub struct VectorHit {
    pub document_id: DocumentId,
    pub score: f32,
    pub snippet: String,
}

/// The shared in-memory vector store: chunk embeddings + brute-force nearest
/// neighbors by cosine similarity. One instance is shared process-wide; later
/// auto-organization queries it for clustering.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Default)]
pub struct VectorStore {
    records: Vec<VectorRecord>,
    dim: usize,
}

impl VectorStore {
    /// Create an empty store. `dim` is fixed at [`EMBED_DIM`].
    pub fn new() -> Self {
        Self {
            records: Vec::new(),
            dim: EMBED_DIM,
        }
    }

    /// Number of stored chunks.
    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// Upsert one chunk: replace any existing vector for `document_id`.
    pub fn upsert(&mut self, document_id: DocumentId, text: &str, vector: Embedding) {
        debug_assert_eq!(vector.len(), self.dim);
        if let Some(rec) = self
            .records
            .iter_mut()
            .find(|r| r.document_id == document_id)
        {
            rec.text = text.to_owned();
            rec.vector = vector;
            return;
        }
        self.records.push(VectorRecord {
            document_id,
            text: text.to_owned(),
            vector,
        });
    }

    /// Remove a chunk (and its vector) by document id. Returns whether it existed.
    pub fn remove(&mut self, document_id: &DocumentId) -> bool {
        let before = self.records.len();
        self.records.retain(|r| &r.document_id != document_id);
        self.records.len() != before
    }

    /// Compute the vector for `text` and store it (convenience over [`Self::upsert`]).
    pub fn index(&mut self, document_id: DocumentId, text: &str) {
        let vector = embed(text);
        self.upsert(document_id, text, vector);
    }

    /// Return the top-`k` stored chunks most similar to `query` by cosine.
    pub fn nearest(&self, query: &[f32], k: usize) -> Vec<VectorHit> {
        let mut scored: Vec<VectorHit> = self
            .records
            .iter()
            .map(|r| VectorHit {
                document_id: r.document_id.clone(),
                score: cosine(query, &r.vector),
                snippet: crate::search::excerpt(&r.text, 240),
            })
            .collect();
        scored.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        scored.truncate(k);
        scored
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embed_is_deterministic_and_normalized() {
        let a = embed("invoice for office supplies");
        let b = embed("invoice for office supplies");
        assert_eq!(a, b);
        assert_eq!(a.len(), EMBED_DIM);

        let norm: f32 = a.iter().map(|v| v * v).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-4);
    }

    #[test]
    fn similar_texts_are_closer_than_dissimilar() {
        let a = embed("invoice for office supplies");
        let b = embed("office supplies invoice");
        let c = embed("chocolate chip cookie recipe");

        assert!(cosine(&a, &b) > cosine(&a, &c));
    }

    #[test]
    fn empty_text_yields_zero_vector() {
        let v = embed("");
        assert_eq!(v.len(), EMBED_DIM);
        assert!(v.iter().all(|x| *x == 0.0));
    }

    #[test]
    fn vector_store_nearest_ranks_and_upserts() {
        let mut store = VectorStore::new();
        store.index("a".to_owned(), "the sky is blue on a sunny day");
        store.index("b".to_owned(), "chocolate cookies with vanilla");
        store.index("c".to_owned(), "blue sky and sun");

        let hits = store.nearest(&embed("blue sky sunshine"), 3);
        assert_eq!(hits.len(), 3);
        assert_ne!(hits[0].document_id, "b");

        // Upsert replaces rather than duplicating.
        store.index("c".to_owned(), "totally unrelated text about boats");
        assert_eq!(store.len(), 3);
        store.remove(&"a".to_owned());
        assert_eq!(store.len(), 2);
        assert!(!store.remove(&"missing".to_owned()));
    }
}
