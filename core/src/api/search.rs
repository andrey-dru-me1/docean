//! Flutter bridge surface for document-content search.
//!
//! A thin facade over [`crate::search::SearchEngine`], which unifies the three
//! retrieval modes — exact (FTS5), semantic (embeddings), and near-duplicate
//! (MinHash + LSH). The engine is held process-wide behind a lock, exactly like
//! the assistant's shared index, so the chat assistant (RAG) and later
//! auto-organization can reuse the same corpus.

use serde::{Deserialize, Serialize};

use crate::search::{embed, SearchEngine, EMBED_DIM};
use std::sync::{Arc, Mutex};

/// A single search result (Dart DTO).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHitDto {
    pub document_id: String,
    pub score: f32,
    pub snippet: Option<String>,
}

/// A candidate near-duplicate pair (Dart DTO).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DuplicatePairDto {
    pub a: String,
    pub b: String,
    /// Estimated Jaccard similarity in `[0, 1]`.
    pub similarity: f32,
}

/// The process-wide search engine, shared behind a lock.
fn engine() -> &'static Arc<Mutex<SearchEngine>> {
    static E: std::sync::OnceLock<Arc<Mutex<SearchEngine>>> = std::sync::OnceLock::new();
    E.get_or_init(|| Arc::new(Mutex::new(SearchEngine::new())))
}

/// Index (or re-index) a document's extracted text across exact, semantic, and
/// near-duplicate backends. Call after content extraction.
#[flutter_rust_bridge::frb(sync)]
pub fn search_index_document(document_id: String, text: String) -> Result<(), String> {
    let mut e = engine()
        .lock()
        .map_err(|_| "search engine is closed".to_owned())?;
    e.index_document(&document_id, &text)
        .map_err(|e| e.to_string())
}

/// Remove a document from all search backends.
#[flutter_rust_bridge::frb(sync)]
pub fn search_remove_document(document_id: String) -> Result<(), String> {
    let mut e = engine()
        .lock()
        .map_err(|_| "search engine is closed".to_owned())?;
    e.remove_document(&document_id).map_err(|e| e.to_string())
}

/// Exact full-text search (FTS5 word / `"phrase"` / boolean queries).
#[flutter_rust_bridge::frb(sync)]
pub fn search_exact(query: String, limit: u32) -> Result<Vec<SearchHitDto>, String> {
    let e = engine()
        .lock()
        .map_err(|_| "search engine is closed".to_owned())?;
    let hits = e
        .search_exact(&query, limit as usize)
        .map_err(|e| e.to_string())?;
    Ok(hits.into_iter().map(Into::into).collect())
}

/// Semantic search via local embeddings, ranked by cosine similarity.
#[flutter_rust_bridge::frb(sync)]
pub fn search_semantic(query: String, limit: u32) -> Result<Vec<SearchHitDto>, String> {
    let e = engine()
        .lock()
        .map_err(|_| "search engine is closed".to_owned())?;
    let hits = e
        .search_semantic(&query, limit as usize)
        .map_err(|e| e.to_string())?;
    Ok(hits.into_iter().map(Into::into).collect())
}

/// Near-duplicate detection: list all candidate duplicate pairs.
#[flutter_rust_bridge::frb(sync)]
pub fn search_duplicates() -> Result<Vec<DuplicatePairDto>, String> {
    let e = engine()
        .lock()
        .map_err(|_| "search engine is closed".to_owned())?;
    Ok(e.duplicate_candidates()
        .into_iter()
        .map(|c| DuplicatePairDto {
            a: c.a,
            b: c.b,
            similarity: c.similarity,
        })
        .collect())
}

/// Near-duplicate detection: documents similar to `text` above `threshold`.
#[flutter_rust_bridge::frb(sync)]
pub fn search_find_duplicates(text: String, threshold: f32) -> Result<Vec<String>, String> {
    let e = engine()
        .lock()
        .map_err(|_| "search engine is closed".to_owned())?;
    Ok(e.find_near_duplicates(&text, threshold))
}

/// Embed `text` into a dense vector using the shared local embedding model.
///
/// This exposes the single shared embedding store's `embed(text) -> Vec<f32>`
/// surface to Dart, so later tasks (e.g. auto-organization) reuse it rather than
/// building their own.
#[flutter_rust_bridge::frb(sync)]
pub fn search_embed(text: String) -> Vec<f32> {
    embed(&text)
}

/// Dimensionality of the embedding vectors produced by [`search_embed`].
#[flutter_rust_bridge::frb(sync)]
pub fn search_embed_dims() -> u32 {
    EMBED_DIM as u32
}

impl From<crate::search::SearchHit> for SearchHitDto {
    fn from(h: crate::search::SearchHit) -> Self {
        SearchHitDto {
            document_id: h.document_id,
            score: h.score,
            snippet: h.snippet,
        }
    }
}
