//! Document-content search: exact full-text, semantic (embedding), and
//! near-duplicate detection.
//!
//! **Boundary:** indexing and querying document text and embeddings. The chat
//! assistant (RAG) and later auto-organization consume the shared
//! [`embeddings`] module rather than maintaining their own vector plumbing.
//!
//! # Retrieval modes
//!
//! 1. **Exact** — SQLite FTS5 ([`fts::FtsIndex`]) supports word, `"phrase"`, and
//!    boolean (`AND`/`OR`/`NOT`/`NEAR`) queries.
//! 2. **Semantic** — local embeddings ([`embeddings`]) stored in a shared
//!    [`embeddings::VectorStore`], ranked by cosine similarity with snippets.
//!    Fully offline; the model is a lightweight local featurizer, **not** a
//!    generative LLM.
//! 3. **Near-duplicate** — MinHash + LSH ([`near_dup`]) keyed by content shingles,
//!    independent of any LLM. Powers deduplication and conflict resolution.
//!
//! [`SearchEngine`] unifies the three behind one handle; the lower-level types are
//! also public so callers can use them directly.

pub mod embeddings;
pub mod fts;

pub use embeddings::{
    cosine, embed, Embedder, Embedding, HashEmbedder, VectorHit, VectorStore, EMBED_DIM,
};
pub use fts::{FtsError, FtsHit, FtsIndex};

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

mod near_dup;

pub use near_dup::{
    minhash_signature, shingles, MinHashSignature, NearDuplicateIndex, NearDuplicateMatch,
    NearDuplicatePair,
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
pub(crate) fn excerpt(text: &str, max: usize) -> String {
    let cleaned: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    cleaned.chars().take(max).collect()
}

/// The unified search engine over document contents.
///
/// Owns the three retrieval backends — FTS5 (exact), [`VectorStore`] (semantic),
/// and [`NearDuplicateIndex`] (near-duplicate via MinHash + LSH) — and keeps
/// them in sync as documents are indexed or removed. It also implements
/// [`SearchIndex`] so the assistant can reuse it for RAG, routing
/// [`Query::Text`] to FTS5 and [`Query::Semantic`] to the vector store.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug)]
pub struct SearchEngine {
    fts: FtsIndex,
    vectors: VectorStore,
    near_dup: NearDuplicateIndex,
}

impl SearchEngine {
    /// Build an in-memory engine (FTS5 in-memory, empty vector + near-duplicate
    /// stores).
    pub fn new() -> Self {
        Self {
            fts: FtsIndex::in_memory().expect("in-memory FTS5 always opens"),
            vectors: VectorStore::new(),
            near_dup: NearDuplicateIndex::default_index(),
        }
    }

    /// Index (or re-index) a document's extracted text across all three backends.
    pub fn index_document(&mut self, doc: &DocumentId, text: &str) -> anyhow::Result<()> {
        self.fts.index(doc, text)?;
        self.vectors.index(doc.clone(), text);
        self.near_dup.index(doc, text);
        Ok(())
    }

    /// Remove a document from all three backends.
    pub fn remove_document(&mut self, doc: &DocumentId) -> anyhow::Result<()> {
        self.fts.remove(doc)?;
        self.vectors.remove(doc);
        self.near_dup.remove(doc);
        Ok(())
    }

    /// Exact full-text search (FTS5).
    pub fn search_exact(&self, query: &str, limit: usize) -> anyhow::Result<Vec<SearchHit>> {
        let hits = self.fts.search(query, limit)?;
        // FTS5 `rank` is negative BM25 (closer to 0 = better); map to a
        // decreasingly relevant positive score.
        Ok(hits
            .into_iter()
            .map(|h| SearchHit {
                document_id: h.document_id,
                score: (-h.score).exp(),
                snippet: h.snippet.map(strip_marks),
            })
            .collect())
    }

    /// Semantic search: embed the query and return the nearest chunks by cosine
    /// similarity with snippets.
    pub fn search_semantic(&self, query: &str, limit: usize) -> anyhow::Result<Vec<SearchHit>> {
        let qvec = embed(query);
        Ok(self
            .vectors
            .nearest(&qvec, limit)
            .into_iter()
            .map(|h| SearchHit {
                document_id: h.document_id,
                score: h.score,
                snippet: Some(h.snippet),
            })
            .collect())
    }

    /// Near-duplicate detection: list all candidate duplicate pairs (with
    /// estimated Jaccard similarity), deduplicated.
    pub fn duplicate_candidates(&self) -> Vec<NearDuplicatePair> {
        self.near_dup.candidates()
    }

    /// Near-duplicate detection: documents similar to `text` above `threshold`.
    pub fn find_near_duplicates(&self, text: &str, threshold: f32) -> Vec<DocumentId> {
        self.near_dup
            .query(text, threshold)
            .into_iter()
            .map(|m| m.document_id)
            .collect()
    }

    /// Shared access to the embedding store (for later auto-organization).
    pub fn vectors(&self) -> &VectorStore {
        &self.vectors
    }
}

impl Default for SearchEngine {
    fn default() -> Self {
        Self::new()
    }
}

/// Strip FTS5 highlight markers (`<b>`/`</b>`) for clean snippets.
fn strip_marks(s: String) -> String {
    s.replace("<b>", "").replace("</b>", "")
}

impl SearchIndex for SearchEngine {
    fn index(&mut self, doc: &DocumentId, text: &str) -> anyhow::Result<()> {
        self.index_document(doc, text)
    }

    fn remove(&mut self, doc: &DocumentId) -> anyhow::Result<()> {
        self.remove_document(doc)
    }

    fn search(&self, query: &Query, limit: usize) -> anyhow::Result<Vec<SearchHit>> {
        match query {
            Query::Text(t) => self.search_exact(t, limit),
            Query::Semantic(t) => self.search_semantic(t, limit),
            Query::Hybrid { text, semantic } => {
                let combined = format!("{text} {semantic}");
                let exact = self.search_exact(text, limit.max(1))?;
                let semantic = self.search_semantic(&combined, limit.max(1))?;
                Ok(merge(exact, semantic, limit))
            }
        }
    }
}

/// Merge exact and semantic hits, preferring exact matches but backfilling with
/// semantic when under `limit`.
fn merge(exact: Vec<SearchHit>, semantic: Vec<SearchHit>, limit: usize) -> Vec<SearchHit> {
    let mut out = exact;
    let seen: std::collections::HashSet<DocumentId> =
        out.iter().map(|h| h.document_id.clone()).collect();
    for h in semantic {
        if out.len() >= limit {
            break;
        }
        if !seen.contains(&h.document_id) {
            out.push(h);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_exact_semantic_and_duplicate_queries() {
        let mut e = SearchEngine::new();

        e.index_document(
            &"a".to_owned(),
            "the quick brown fox jumps over the lazy dog",
        )
        .unwrap();
        e.index_document(&"c".to_owned(), "office party chocolate chip cookie recipe")
            .unwrap();
        // b and d are near-duplicates: same body with a single trailing word appended.
        let body_b = "office supplies invoice for printer paper and toner cartridges";
        let body_d = "office supplies invoice for printer paper and toner cartridges duplicate";
        e.index_document(&"b".to_owned(), body_b).unwrap();
        e.index_document(&"d".to_owned(), body_d).unwrap();

        // Exact phrase.
        let exact = e.search_exact("\"office supplies\"", 10).unwrap();
        let ids: Vec<&str> = exact.iter().map(|h| h.document_id.as_str()).collect();
        assert!(ids.contains(&"b"));
        assert!(ids.contains(&"d"));

        // Semantic: dessert query ranks the cookie recipe (c) highest.
        let sem = e.search_semantic("chocolate dessert recipe", 10).unwrap();
        assert!(!sem.is_empty());
        assert_eq!(sem[0].document_id, "c");

        // Near-duplicate: b ~ d, but neither is a duplicate of a.
        let cands = e.duplicate_candidates();
        assert!(cands
            .iter()
            .any(|c| { (c.a == "b" && c.b == "d") || (c.a == "d" && c.b == "b") }));
        assert!(!cands
            .iter()
            .any(|c| (c.a == "a" && c.b == "b") || (c.a == "b" && c.b == "a")));

        let dup = e.find_near_duplicates(body_b, 0.35);
        assert!(dup.contains(&"b".to_owned()));

        e.remove_document(&"d".to_owned()).unwrap();
        assert!(!e
            .find_near_duplicates(body_b, 0.35)
            .contains(&"d".to_owned()));
    }

    #[test]
    fn engine_implements_search_index_for_rag() {
        let mut e = SearchEngine::new();
        e.index_document(&"x".to_owned(), "rust programming with sqlite")
            .unwrap();

        let hits = e.search(&Query::Text("sqlite".to_owned()), 5).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].document_id, "x");

        let hits = e
            .search(&Query::Semantic("databases".to_owned()), 5)
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].document_id, "x");
    }
}
