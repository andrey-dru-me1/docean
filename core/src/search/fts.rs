//! Exact full-text search via SQLite FTS5.
//!
//! Word, phrase, and boolean queries are expressed through SQLite's FTS5 MATCH
//! query syntax:
//!
//! * **Word** — `office` (token substring matches).
//! * **Phrase** — `"office supplies"`.
//! * **Boolean** — `office AND supplies`, `invoice OR receipt`, `NOT spam`;
//!   also `NEAR(a b, 2)` for proximity.
//!
//! [`FtsIndex`] owns a `rusqlite` connection whose FTS5 virtual table stores one
//! row per document (id + full extracted text). Results include a BM25 score and
//! an excerpt (snippet) of the matched document.

use rusqlite::{params, Connection, OptionalExtension};

use crate::domain::DocumentId;

/// A single full-text hit with its BM25-derived score (higher is better).
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Clone)]
pub struct FtsHit {
    pub document_id: DocumentId,
    /// Negative BM25; closer to `0.0` means "more relevant".
    pub score: f32,
    /// A snippet of extracted text around the match (when available).
    pub snippet: Option<String>,
}

/// Errors specific to the FTS index.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, thiserror::Error)]
pub enum FtsError {
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("invalid FTS5 query: {0}")]
    InvalidQuery(String),
}

/// An SQLite FTS5-backed exact full-text index over document contents.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug)]
pub struct FtsIndex {
    conn: Connection,
}

impl Default for FtsIndex {
    fn default() -> Self {
        Self::in_memory().expect("in-memory FTS5 index should always open")
    }
}

impl FtsIndex {
    /// Create an index backed by ephemeral in-memory storage.
    pub fn in_memory() -> Result<Self, FtsError> {
        let conn = Connection::open_in_memory()?;
        Self::init(&conn)?;
        Ok(Self { conn })
    }

    /// Create an index persisted to `db_path` on disk.
    pub fn open(db_path: &std::path::Path) -> Result<Self, FtsError> {
        let conn = Connection::open(db_path)?;
        Self::init(&conn)?;
        Ok(Self { conn })
    }

    fn init(conn: &Connection) -> Result<(), FtsError> {
        conn.execute_batch(
            r#"
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_documents USING fts5(
                document_id UNINDEXED,
                text
            );
            "#,
        )?;
        Ok(())
    }

    /// Index (or re-index) a document's extracted text.
    pub fn index(&self, document_id: &DocumentId, text: &str) -> Result<(), FtsError> {
        self.remove(document_id)?;
        self.conn.execute(
            "INSERT INTO fts_documents(document_id, text) VALUES (?1, ?2) ",
            params![document_id, text],
        )?;
        Ok(())
    }

    /// Remove a document from the index.
    pub fn remove(&self, document_id: &DocumentId) -> Result<(), FtsError> {
        self.conn.execute(
            "DELETE FROM fts_documents WHERE document_id = ?1 ",
            [document_id],
        )?;
        Ok(())
    }

    /// Execute an FTS5 `MATCH` query, returning hits sorted by relevance.
    ///
    /// `query` is the raw FTS5 query string (word, `"phrase"`, or boolean
    /// operators). `limit` caps the returned hits.
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<FtsHit>, FtsError> {
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        // Validate up-front so a syntax error surfaces as InvalidQuery.
        if let Err(e) = self
            .conn
            .query_row(
                "SELECT count(*) FROM fts_documents WHERE fts_documents MATCH ?1",
                [query],
                |row| row.get::<_, i64>(0),
            )
            .optional()
        {
            return Err(FtsError::InvalidQuery(e.to_string()));
        }

        let mut stmt = self.conn.prepare(
            r#"
            SELECT document_id, rank, snippet(fts_documents, 1, '<b>', '</b>', '…', 24)
            FROM fts_documents
            WHERE fts_documents MATCH ?1
            ORDER BY rank
            LIMIT ?2
            "#,
        )?;
        let rows = stmt.query_map(params![query, limit as i64], |row| {
            let document_id: String = row.get(0)?;
            let rank: f64 = row.get(1)?;
            let snippet: Option<String> = row.get(2)?;
            Ok(FtsHit {
                document_id,
                score: rank as f32,
                snippet,
            })
        })?;

        let mut hits = Vec::new();
        for row in rows {
            hits.push(row?);
        }
        Ok(hits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seeded() -> FtsIndex {
        let idx = FtsIndex::in_memory().unwrap();
        idx.index(
            &"a".to_owned(),
            "the quick brown fox jumps over the lazy dog",
        )
        .unwrap();
        idx.index(&"b".to_owned(), "office supplies invoice for printer paper")
            .unwrap();
        idx.index(
            &"c".to_owned(),
            "chocolate chip cookie recipe for office party",
        )
        .unwrap();
        idx
    }

    #[test]
    fn word_query_returns_relevant_docs() {
        let idx = seeded();
        let hits = idx.search("office", 10).unwrap();
        let ids: Vec<String> = hits.iter().map(|h| h.document_id.clone()).collect();
        assert!(ids.contains(&"b".to_owned()));
        assert!(ids.contains(&"c".to_owned()));
        assert!(!ids.contains(&"a".to_owned()));
    }

    #[test]
    fn phrase_query_requires_exact_phrase() {
        let idx = seeded();
        let hits = idx.search("\"office supplies\"", 10).unwrap();
        let ids: Vec<String> = hits.iter().map(|h| h.document_id.clone()).collect();
        assert_eq!(ids, vec!["b".to_owned()]);
    }

    #[test]
    fn boolean_query_supports_and_or_not() {
        let idx = seeded();
        let hits = idx.search("office AND invoice", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].document_id, "b");

        let hits = idx.search("office NOT invoice", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].document_id, "c");
    }

    #[test]
    fn remove_deletes_from_index() {
        let idx = seeded();
        idx.remove(&"a".to_owned()).unwrap();
        let hits = idx.search("fox", 10).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn snippet_is_highlighted() {
        let idx = seeded();
        let hits = idx.search("printer", 10).unwrap();
        assert_eq!(hits.len(), 1);
        let snip = hits[0].snippet.as_ref().unwrap();
        assert!(snip.contains("<b>printer</b>"), "snippet: {snip}");
    }

    #[test]
    fn empty_query_returns_nothing() {
        let idx = seeded();
        assert!(idx.search("   ", 10).unwrap().is_empty());
    }
}
