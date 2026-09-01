//! Flutter bridge surface for document-content search.
//!
//! Thin facade over [`crate::search::SearchEngine`], which unifies exact (FTS5),
//! semantic (local embeddings), and near-duplicate (MinHash + LSH) retrieval.
//! The engine is held process-wide behind a lock so the chat assistant (RAG)
//! and later auto-organization reuse the same corpus.
//!
//! On top of the engine's raw exact/semantic/duplicate functions, this module
//! also exposes a higher-level [`search_query`] used by the search UI: it takes
//! a mode plus optional tag/path filters, dispatches to the engine, and returns
//! snippets annotated with match-highlight spans and per-document metadata.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::search::{embed, SearchEngine, SearchHit, EMBED_DIM};

/// Document id -> (tags, paths) lookup table for result filtering.
type DocMeta = HashMap<String, (Vec<String>, Vec<String>)>;

/// The process-wide search engine, shared behind a lock.
fn engine() -> &'static Arc<Mutex<SearchEngine>> {
    static E: std::sync::OnceLock<Arc<Mutex<SearchEngine>>> = std::sync::OnceLock::new();
    E.get_or_init(|| Arc::new(Mutex::new(SearchEngine::new())))
}

/// A process-wide handle to the search layer's MinHash/LSH near-duplicate index.
///
/// This is the *same* index instance [`engine`] indexes into, so handing it to
/// the sync reconciliation layer wires near-duplicate-assisted version proposals
/// for substantially-same documents. Exposed for [`crate::api::sync`].
pub(crate) fn shared_near_dup_index() -> crate::search::SharedNearDuplicateIndex {
    engine().lock().unwrap().near_dup_index()
}

/// document id -> (tags, paths) metadata for UI filtering.
fn metadata() -> &'static Arc<std::sync::Mutex<DocMeta>> {
    static META: std::sync::OnceLock<Arc<std::sync::Mutex<DocMeta>>> = std::sync::OnceLock::new();
    META.get_or_init(|| Arc::new(Mutex::new(HashMap::new())))
}

// ---------------------------------------------------------------------------
// Dart DTOs
// ---------------------------------------------------------------------------

/// Query kinds selectable in the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SearchMode {
    Exact,
    Semantic,
    Hybrid,
}

/// A single continuous run of matching text inside a snippet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HighlightSpan {
    /// Byte offset (relative to the snippet) where the match starts.
    pub start: usize,
    /// Byte offset (exclusive) where the match ends.
    pub end: usize,
}

/// A single search result (Dart DTO).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHitDto {
    pub document_id: String,
    pub score: f32,
    pub snippet: String,
    /// Byte ranges of the matching terms within `snippet`, for UI highlighting.
    pub highlights: Vec<HighlightSpan>,
    pub tags: Vec<String>,
    pub paths: Vec<String>,
}

/// A search request (Dart DTO).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequestDto {
    /// The user's query text.
    pub text: String,
    pub mode: SearchMode,
    /// Only return documents bearing all of these tags.
    #[serde(default)]
    pub tags: Vec<String>,
    /// Only return documents reachable via any of these paths.
    #[serde(default)]
    pub paths: Vec<String>,
    pub limit: Option<u32>,
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

// ---------------------------------------------------------------------------
// Search plumbing
// ---------------------------------------------------------------------------

/// Find all start offsets of `needle` in `haystack` (byte offsets).
fn find_offsets(haystack: &str, needle: &str) -> Vec<usize> {
    if needle.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(pos) = haystack[from..].find(needle) {
        let abs = from + pos;
        out.push(abs);
        from = abs + needle.len();
    }
    out
}

/// Compute non-overlapping highlight spans for every query term found in the
/// snippet. Matching is case-insensitive; spans never overlap.
fn compute_highlights(snippet: &str, query: &str) -> Vec<HighlightSpan> {
    let mut terms: Vec<String> = query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(|t| t.to_lowercase())
        .collect();
    terms.sort_by_key(|t| std::cmp::Reverse(t.len()));
    let lower = snippet.to_lowercase();
    let mut spans: Vec<HighlightSpan> = Vec::new();
    let mut occupied: Vec<(usize, usize)> = Vec::new();
    for term in &terms {
        for start in find_offsets(&lower, term) {
            let end = start + term.len();
            if occupied.iter().any(|(s, e)| start < *e && *s < end) {
                continue;
            }
            occupied.push((start, end));
            spans.push(HighlightSpan { start, end });
            break; // one span per term keeps the snippet readable
        }
    }
    spans.sort_by_key(|s| s.start);
    spans
}

/// Merge two result sets, de-duplicating by document id and keeping the higher
/// score per document.
fn merge_hits(a: Vec<SearchHit>, b: Vec<SearchHit>) -> Vec<SearchHit> {
    let mut map: HashMap<String, SearchHit> = HashMap::new();
    for hit in a.into_iter().chain(b) {
        map.entry(hit.document_id.clone())
            .and_modify(|existing| {
                if hit.score > existing.score {
                    *existing = hit.clone();
                }
            })
            .or_insert(hit);
    }
    let mut out: Vec<SearchHit> = map.into_values().collect();
    out.sort_by(|x, y| {
        y.score
            .partial_cmp(&x.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    out
}

fn to_dto(
    hit: &SearchHit,
    query: &str,
    meta: &HashMap<String, (Vec<String>, Vec<String>)>,
) -> SearchHitDto {
    let snippet = hit.snippet.clone().unwrap_or_default();
    SearchHitDto {
        document_id: hit.document_id.clone(),
        score: hit.score,
        snippet: snippet.clone(),
        highlights: compute_highlights(&snippet, query),
        tags: meta
            .get(&hit.document_id)
            .map(|(t, _)| t.clone())
            .unwrap_or_default(),
        paths: meta
            .get(&hit.document_id)
            .map(|(_, p)| p.clone())
            .unwrap_or_default(),
    }
}
// ---------------------------------------------------------------------------
// Bridge functions
// ---------------------------------------------------------------------------

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

/// Remove a document from all search backends and the metadata table.
#[flutter_rust_bridge::frb(sync)]
pub fn search_remove_document(document_id: String) -> Result<(), String> {
    let mut e = engine()
        .lock()
        .map_err(|_| "search engine is closed".to_owned())?;
    let res = e.remove_document(&document_id).map_err(|e| e.to_string());
    metadata().lock().unwrap().remove(&document_id);
    res
}

/// Exact full-text search (FTS5 word / `"phrase"` / boolean queries).
#[flutter_rust_bridge::frb(sync)]
pub fn search_exact(query: String, limit: u32) -> Result<Vec<SearchHitDto>, String> {
    dispatch_to_dto(SearchMode::Exact, &query, Some(limit), &[], &[])
}

/// Semantic search via local embeddings, ranked by cosine similarity.
#[flutter_rust_bridge::frb(sync)]
pub fn search_semantic(query: String, limit: u32) -> Result<Vec<SearchHitDto>, String> {
    dispatch_to_dto(SearchMode::Semantic, &query, Some(limit), &[], &[])
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

/// Register a document's tags and hierarchy paths for result filtering.
///
/// Call after a document is tagged or assigned to a path so searches can be
/// filtered by that metadata. Pure bookkeeping: indexing text is separate.
#[flutter_rust_bridge::frb(sync)]
pub fn search_set_metadata(document_id: String, tags: Vec<String>, paths: Vec<String>) {
    metadata()
        .lock()
        .unwrap()
        .insert(document_id, (tags, paths));
}

/// Run a search across the document library.
///
/// `mode` selects exact full-text, semantic (vector similarity), or a hybrid
/// combination. When `tags`/`paths` are non-empty only documents carrying all of
/// the tags (and reachable via any listed path) are returned, with snippets
/// annotated by match-highlight spans for the UI.
#[flutter_rust_bridge::frb(sync)]
pub fn search_query(req: SearchRequestDto) -> Vec<SearchHitDto> {
    dispatch_to_dto(req.mode, &req.text, req.limit, &req.tags, &req.paths).unwrap_or_default()
}

/// Shared dispatch for exact/semantic/hybrid search: runs the engine, applies
/// tag/path filters, and converts results to [`SearchHitDto`] with highlights.
fn dispatch_to_dto(
    mode: SearchMode,
    text: &str,
    limit: Option<u32>,
    tags: &[String],
    paths: &[String],
) -> Result<Vec<SearchHitDto>, String> {
    let text = text.trim();
    if text.is_empty() {
        return Ok(Vec::new());
    }
    let limit = limit.unwrap_or(50) as usize;
    let e = engine()
        .lock()
        .map_err(|_| "search engine is closed".to_owned())?;
    let hits: Vec<SearchHit> = match mode {
        SearchMode::Exact => e.search_exact(text, limit).map_err(|e| e.to_string())?,
        SearchMode::Semantic => e.search_semantic(text, limit).map_err(|e| e.to_string())?,
        SearchMode::Hybrid => {
            let a = e.search_exact(text, limit).map_err(|e| e.to_string())?;
            let b = e.search_semantic(text, limit).map_err(|e| e.to_string())?;
            merge_hits(a, b)
        }
    };

    let meta = metadata().lock().unwrap();
    let filtered: Vec<&SearchHit> = hits
        .iter()
        .filter(|h| {
            let tag_ok = tags.is_empty()
                || meta
                    .get(&h.document_id)
                    .is_some_and(|(t, _)| tags.iter().all(|want| t.contains(want)));
            let path_ok = paths.is_empty()
                || meta
                    .get(&h.document_id)
                    .is_some_and(|(_, p)| paths.iter().any(|want| p.contains(want)));
            tag_ok && path_ok
        })
        .take(limit)
        .collect();

    Ok(filtered.iter().map(|h| to_dto(h, text, &meta)).collect())
}

#[cfg(test)]
mod tests;

impl From<crate::search::SearchHit> for SearchHitDto {
    fn from(h: crate::search::SearchHit) -> Self {
        SearchHitDto {
            document_id: h.document_id,
            score: h.score,
            snippet: h.snippet.unwrap_or_default(),
            highlights: Vec::new(),
            tags: Vec::new(),
            paths: Vec::new(),
        }
    }
}
