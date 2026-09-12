//! SQLite-backed implementation of [`DocumentStore`].
//!
//! Metadata, tags, hierarchy edges, and extracted content live in a
//! single SQLite database file (`<root>/docean.db`); raw bytes live in the
//! [`BlobStore`] under `<root>/blobs/`. See [`crate::storage::schema`] for the
//! schema.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::domain::{
    Content, Document, DocumentId, DocumentSuggestion, FeedbackStats, HierarchyLink, NodeKind,
    SuggestionFeedback, SuggestionKind, Tag,
};
use crate::storage::blob::{hash_bytes, BlobStore};
use crate::storage::schema;
use crate::storage::{DocumentQuery, DocumentStore, StorageError};

/// The concrete local store: SQLite metadata + content-addressed blobs.
///
/// Wrapped in `Arc<Mutex<Connection>>` because `rusqlite::Connection` is not
/// safe to share across threads directly; the mutex serializes access so the
/// store can be shared behind an `Arc` on the bridge side.
pub struct SqliteDocumentStore {
    conn: Arc<Mutex<Connection>>,
    blobs: BlobStore,
}

impl SqliteDocumentStore {
    /// Open (or create) a store rooted at `root`.
    fn open_impl(root: &Path) -> Result<Self, StorageError> {
        std::fs::create_dir_all(root)?;

        let db_path = root.join("docean.db");
        let mut conn = Connection::open(db_path)?;
        // Enforce foreign keys so `ON DELETE CASCADE` actually fires.
        conn.pragma_update(None, "foreign_keys", true)?;
        schema::migrate(&mut conn)?;

        let blobs = BlobStore::open(root)?;

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            blobs,
        })
    }

    /// Access to the underlying blob store (used by the bridge facade).
    pub fn blobs(&self) -> &BlobStore {
        &self.blobs
    }

    /// Lock and run a closure against the underlying connection.
    fn with_conn<T>(
        &self,
        f: impl FnOnce(&Connection) -> Result<T, StorageError>,
    ) -> Result<T, StorageError> {
        let guard = self.conn.lock().map_err(|_| StorageError::Closed)?;
        f(&guard)
    }

    /// Lock and run a mutable closure (e.g. wrapping a transaction).
    fn with_conn_mut<T>(
        &self,
        f: impl FnOnce(&mut Connection) -> Result<T, StorageError>,
    ) -> Result<T, StorageError> {
        let mut guard = self.conn.lock().map_err(|_| StorageError::Closed)?;
        f(&mut guard)
    }

    fn row_to_document(row: &Row) -> rusqlite::Result<Document> {
        let id: String = row.get("id")?;
        let kind: String = row.get("kind")?;
        let title: String = row.get("title")?;
        let mime_type: String = row.get("mime_type")?;
        let size_bytes: u64 = row.get("size_bytes")?;
        let checksum_sha256: String = row.get("checksum_sha256")?;
        let created_at_ms: i64 = row.get("created_at_ms")?;
        let updated_at_ms: i64 = row.get("updated_at_ms")?;
        let parent_id: Option<String> = row.get("parent_id")?;
        let extra_json: String = row.get("extra")?;
        let tags_json: String = row.get("tags")?;

        let kind = match kind.as_str() {
            "folder" => NodeKind::Folder,
            _ => NodeKind::Document,
        };

        let extra: HashMap<String, String> = serde_json::from_str(&extra_json).unwrap_or_default();
        let tags: Vec<String> = serde_json::from_str(&tags_json).unwrap_or_default();

        Ok(Document {
            id,
            parent_id,
            kind,
            title,
            mime_type,
            size_bytes,
            checksum_sha256,
            tags,
            created_at_ms,
            updated_at_ms,
            extra,
        })
    }

    fn load_document(&self, conn: &Connection, id: &DocumentId) -> Result<Document, StorageError> {
        conn.query_row(
            r#"
            SELECT d.id, d.kind, d.title, d.mime_type, d.size_bytes,
                   d.checksum_sha256, d.created_at_ms, d.updated_at_ms,
                   d.parent_id, d.extra,
                   COALESCE((SELECT json_group_array(tag)
                             FROM (SELECT tag FROM document_tags
                                   WHERE document_id = d.id ORDER BY tag)),
                            '[]') AS tags
            FROM documents d
            WHERE d.id = ?1
            "#,
            [id],
            Self::row_to_document,
        )
        .optional()?
        .ok_or_else(|| StorageError::NotFound(id.clone()))
    }
}

impl DocumentStore for SqliteDocumentStore {
    fn open(root: PathBuf) -> Result<Self, StorageError> {
        Self::open_impl(&root)
    }

    fn put(&mut self, doc: Document, bytes: &[u8]) -> Result<(), StorageError> {
        let hash = self.blobs.put(bytes)?;

        // The caller-provided checksum must match the computed hash; if empty,
        // adopt the computed hash. A mismatch is a hard error to guard against
        // silent corruption.
        let checksum = if doc.checksum_sha256.is_empty() {
            hash
        } else {
            let expected = hash_bytes(bytes);
            if doc.checksum_sha256 != expected {
                let _ = self.blobs.delete(&expected);
                return Err(StorageError::Io(std::io::Error::other(
                    "checksum mismatch between Document.checksum_sha256 and bytes",
                )));
            }
            expected
        };

        let kind = match doc.kind {
            NodeKind::Document => "document",
            NodeKind::Folder => "folder",
        };
        let extra_json = serde_json::to_string(&doc.extra).unwrap_or_else(|_| "{}".to_owned());

        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            tx.execute(
                r#"
                INSERT INTO documents
                    (id, kind, title, mime_type, size_bytes, checksum_sha256,
                     created_at_ms, updated_at_ms, parent_id, extra)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind,
                    title = excluded.title,
                    mime_type = excluded.mime_type,
                    size_bytes = excluded.size_bytes,
                    checksum_sha256 = excluded.checksum_sha256,
                    created_at_ms = excluded.created_at_ms,
                    updated_at_ms = excluded.updated_at_ms,
                    parent_id = excluded.parent_id,
                    extra = excluded.extra
                "#,
                params![
                    doc.id,
                    kind,
                    doc.title,
                    doc.mime_type,
                    doc.size_bytes as i64,
                    checksum,
                    doc.created_at_ms,
                    doc.updated_at_ms,
                    doc.parent_id,
                    extra_json,
                ],
            )?;

            // Reconcile the document's tag assignments; hierarchical tags
            // materialize their implicit ancestors (see `expand_tag_ancestors`).
            tx.execute(
                "DELETE FROM document_tags WHERE document_id = ?1",
                [&doc.id],
            )?;
            for tag in expand_tag_ancestors(&doc.tags) {
                tx.execute("INSERT OR IGNORE INTO tags(name) VALUES (?1)", [&tag])?;
                tx.execute(
                    "INSERT INTO document_tags(document_id, tag) VALUES (?1, ?2)",
                    params![doc.id, tag],
                )?;
            }

            tx.commit()?;
            Ok(())
        })
    }

    fn get(&self, id: &DocumentId) -> Result<Document, StorageError> {
        self.with_conn(|conn| self.load_document(conn, id))
    }

    fn read_bytes(&self, id: &DocumentId) -> Result<Vec<u8>, StorageError> {
        let doc = self.get(id)?;
        self.blobs.get(&doc.checksum_sha256)
    }

    fn delete(&mut self, id: &DocumentId) -> Result<(), StorageError> {
        let doc = self.get(id)?;
        let hash = doc.checksum_sha256.clone();

        self.with_conn_mut(|conn| {
            conn.execute("DELETE FROM documents WHERE id = ?1", [id])?;
            Ok(())
        })?;

        // Drop the blob only if no other document references the same hash.
        self.with_conn(|conn| {
            let refs: i64 = conn.query_row(
                "SELECT count(*) FROM documents WHERE checksum_sha256 = ?1",
                [&hash],
                |r| r.get(0),
            )?;
            if refs == 0 {
                let _ = self.blobs.delete(&hash);
            }
            Ok(())
        })
    }

    fn query(&self, q: &DocumentQuery) -> Result<Vec<Document>, StorageError> {
        let mut sql = String::from(
            r#"
            SELECT d.id, d.kind, d.title, d.mime_type, d.size_bytes,
                   d.checksum_sha256, d.created_at_ms, d.updated_at_ms,
                   d.parent_id, d.extra,
                   COALESCE((SELECT json_group_array(tag)
                             FROM (SELECT tag FROM document_tags
                                   WHERE document_id = d.id ORDER BY tag)),
                            '[]') AS tags
            FROM documents d
            "#,
        );

        let mut conditions: Vec<String> = Vec::new();
        let mut params_list: Vec<String> = Vec::new();

        if let Some(parent) = &q.parent {
            conditions.push("d.parent_id = ?".to_owned());
            params_list.push(parent.clone());
        }
        if let Some(kind) = q.kind {
            conditions.push("d.kind = ?".to_owned());
            params_list.push(match kind {
                NodeKind::Document => "document".to_owned(),
                NodeKind::Folder => "folder".to_owned(),
            });
        }
        if !q.tags.is_empty() {
            // The document must carry *all* requested tags.
            let clauses = q
                .tags
                .iter()
                .map(|_| {
                    "EXISTS (SELECT 1 FROM document_tags dt \
                     WHERE dt.document_id = d.id AND dt.tag = ?)"
                        .to_owned()
                })
                .collect::<Vec<_>>()
                .join(" AND ");
            conditions.push(format!("({clauses})"));
            params_list.extend(q.tags.iter().cloned());
        }

        if !conditions.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&conditions.join(" AND "));
        }
        sql.push_str(" ORDER BY d.updated_at_ms DESC");

        if let Some(limit) = q.limit {
            sql.push_str(&format!(" LIMIT {limit}"));
        }
        if let Some(offset) = q.offset {
            sql.push_str(&format!(" OFFSET {offset}"));
        }

        self.with_conn(|conn| {
            let mut stmt = conn.prepare(&sql)?;
            let docs = stmt
                .query_map(
                    rusqlite::params_from_iter(params_list.iter()),
                    Self::row_to_document,
                )?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(docs)
        })
    }

    // --- hierarchy ---------------------------------------------------------

    fn link(&mut self, link: HierarchyLink) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                r#"
                INSERT INTO hierarchy_links(parent_id, child_id, position)
                VALUES (?1, ?2, ?3)
                ON CONFLICT(parent_id, child_id) DO UPDATE SET position = excluded.position
                "#,
                params![link.parent_id, link.child_id, link.position],
            )?;
            Ok(())
        })
    }

    fn children(&self, parent: &DocumentId) -> Result<Vec<DocumentId>, StorageError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT child_id FROM hierarchy_links \
                 WHERE parent_id = ?1 ORDER BY position, child_id",
            )?;
            let ids = stmt
                .query_map([parent], |r| r.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(ids)
        })
    }

    // --- extracted content -------------------------------------------------

    fn put_content(&mut self, content: &Content) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                r#"
                INSERT INTO content(document_id, text, source)
                VALUES (?1, ?2, ?3)
                ON CONFLICT(document_id) DO UPDATE SET text = excluded.text, source = excluded.source
                "#,
                params![content.document_id, content.text, content.source],
            )?;
            Ok(())
        })
    }

    fn get_content(&self, document_id: &DocumentId) -> Result<Option<Content>, StorageError> {
        self.with_conn(|conn| {
            let row = conn
                .query_row(
                    "SELECT document_id, text, source FROM content WHERE document_id = ?1",
                    [document_id],
                    |r| {
                        Ok(Content {
                            document_id: r.get(0)?,
                            text: r.get(1)?,
                            source: r.get(2)?,
                        })
                    },
                )
                .optional()?;
            Ok(row)
        })
    }

    fn delete_content(&mut self, document_id: &DocumentId) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute("DELETE FROM content WHERE document_id = ?1", [document_id])?;
            Ok(())
        })
    }

    // --- tags --------------------------------------------------------------

    fn put_tag(&mut self, tag: Tag) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                r#"
                INSERT INTO tags(name, parent, color)
                VALUES (?1, ?2, ?3)
                ON CONFLICT(name) DO UPDATE SET parent = excluded.parent, color = excluded.color
                "#,
                params![tag.name, tag.parent, tag.color],
            )?;
            Ok(())
        })
    }

    fn list_tags(&self) -> Result<Vec<Tag>, StorageError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare("SELECT name, parent, color FROM tags ORDER BY name")?;
            let tags = stmt
                .query_map([], |r| {
                    Ok(Tag {
                        name: r.get(0)?,
                        parent: r.get(1)?,
                        color: r.get(2)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(tags)
        })
    }

    fn set_tags(&mut self, document_id: &DocumentId, tags: &[String]) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;

            let known: i64 = tx.query_row(
                "SELECT count(*) FROM documents WHERE id = ?1",
                [document_id],
                |r| r.get(0),
            )?;
            if known == 0 {
                return Err(StorageError::NotFound(document_id.clone()));
            }

            tx.execute(
                "DELETE FROM document_tags WHERE document_id = ?1",
                [document_id],
            )?;
            for tag in expand_tag_ancestors(tags) {
                tx.execute("INSERT OR IGNORE INTO tags(name) VALUES (?1)", [&tag])?;
                tx.execute(
                    "INSERT INTO document_tags(document_id, tag) VALUES (?1, ?2)",
                    params![document_id, tag],
                )?;
            }

            tx.commit()?;
            Ok(())
        })
    }
}

// --- pending suggestions + feedback ---------------------------------------
//
// These live on the concrete store (not the `DocumentStore` trait) because
// they back the review UI, not the document index. `DocumentRepository` calls
// them directly through the `Arc<Mutex<SqliteDocumentStore>>` handle.
impl SqliteDocumentStore {
    /// Insert or update one suggestion row.
    pub fn put_suggestion(&mut self, s: &DocumentSuggestion) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                r#"
                INSERT INTO document_suggestions
                    (id, document_id, kind, payload, rank, source, confidence, status, created_at_ms)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                ON CONFLICT(id) DO UPDATE SET
                    rank = excluded.rank,
                    status = excluded.status,
                    payload = excluded.payload,
                    source = excluded.source,
                    confidence = excluded.confidence
                "#,
                params![
                    s.id,
                    s.document_id,
                    kind_str(s.kind),
                    s.payload,
                    s.rank,
                    source_str(s.source),
                    s.confidence,
                    status_str(s.status),
                    s.created_at_ms,
                ],
            )?;
            Ok(())
        })
    }

    /// Fetch suggestions for a document, optionally filtered by kind.
    pub fn suggestions_for_document(
        &self,
        document_id: &DocumentId,
        kind: Option<SuggestionKind>,
    ) -> Result<Vec<DocumentSuggestion>, StorageError> {
        self.with_conn(|conn| {
            let mut sql = String::from(
                r#"
                SELECT id, document_id, kind, payload, rank, source, confidence, status, created_at_ms
                FROM document_suggestions
                WHERE document_id = ?1
                "#,
            );
            let mut args: Vec<String> = vec![document_id.clone()];
            if let Some(kind) = kind {
                sql.push_str(" AND kind = ?2");
                args.push(kind_str(kind).to_owned());
            }
            sql.push_str(" ORDER BY kind, rank, created_at_ms");
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt
                .query_map(
                    rusqlite::params_from_iter(args.iter()),
                    Self::row_to_suggestion,
                )?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
    }

    /// Update the review status of one suggestion.
    pub fn mark_suggestion(
        &mut self,
        id: &str,
        status: crate::domain::SuggestionStatus,
    ) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                "UPDATE document_suggestions SET status = ?2 WHERE id = ?1",
                params![id, status_str(status)],
            )?;
            Ok(())
        })
    }

    /// Remove every suggestion row for a document (used on replacement).
    pub fn delete_suggestions_for_document(
        &mut self,
        document_id: &DocumentId,
    ) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                "DELETE FROM document_suggestions WHERE document_id = ?1",
                [document_id],
            )?;
            Ok(())
        })
    }

    /// Persist one feedback event (accepted/rejected term).
    pub fn record_feedback(&mut self, f: &SuggestionFeedback) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                r#"
                INSERT INTO suggestion_feedback
                    (id, kind, context, term, action, weight, created_at_ms)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                "#,
                params![
                    f.id,
                    kind_str(f.kind),
                    f.context,
                    f.term,
                    f.action,
                    f.weight,
                    f.created_at_ms,
                ],
            )?;
            Ok(())
        })
    }

    /// Aggregate accept/reject evidence per term for the feedback model.
    pub fn feedback_stats(
        &self,
        kind: Option<SuggestionKind>,
        context: Option<&str>,
    ) -> Result<HashMap<String, FeedbackStats>, StorageError> {
        self.with_conn(|conn| {
            let mut sql = String::from(
                r#"
                SELECT term,
                       COALESCE(SUM(CASE WHEN action = 'accepted' THEN weight END), 0.0) AS accepts,
                       COALESCE(SUM(CASE WHEN action = 'rejected' THEN weight END), 0.0) AS rejects
                FROM suggestion_feedback
                WHERE 1 = 1
                "#,
            );
            let mut args: Vec<String> = Vec::new();
            let mut idx = 0usize;
            if let Some(kind) = kind {
                idx += 1;
                sql.push_str(&format!(" AND kind = ?{idx}"));
                args.push(kind_str(kind).to_owned());
            }
            if let Some(context) = context {
                idx += 1;
                sql.push_str(&format!(" AND context = ?{idx}"));
                args.push(context.to_owned());
            }
            sql.push_str(" GROUP BY term");
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt
                .query_map(rusqlite::params_from_iter(args.iter()), |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        FeedbackStats {
                            accepts: r.get::<_, f64>(1)?,
                            rejects: r.get::<_, f64>(2)?,
                        },
                    ))
                })?
                .collect::<Result<HashMap<_, _>, _>>()?;
            Ok(rows)
        })
    }

    /// Wipe all learning data (settings "reset learning").
    pub fn clear_feedback(&mut self) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute("DELETE FROM suggestion_feedback", [])?;
            Ok(())
        })
    }

    /// Delete non-pending suggestions older than `older_than_ms` (housekeeping).
    pub fn prune_suggestions(&mut self, older_than_ms: i64) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                "DELETE FROM document_suggestions WHERE status != 'pending' AND created_at_ms < ?1",
                [older_than_ms],
            )?;
            Ok(())
        })
    }

    fn row_to_suggestion(row: &Row) -> rusqlite::Result<DocumentSuggestion> {
        Ok(DocumentSuggestion {
            id: row.get(0)?,
            document_id: row.get(1)?,
            kind: kind_from_str(&row.get::<_, String>(2)?),
            payload: row.get(3)?,
            rank: row.get(4)?,
            source: source_from_str(&row.get::<_, String>(5)?),
            confidence: row.get(6)?,
            status: status_from_str(&row.get::<_, String>(7)?),
            created_at_ms: row.get(8)?,
        })
    }
}

fn kind_str(k: SuggestionKind) -> &'static str {
    match k {
        SuggestionKind::Title => "title",
        SuggestionKind::Tags => "tags",
    }
}

fn kind_from_str(s: &str) -> SuggestionKind {
    match s {
        "tags" => SuggestionKind::Tags,
        _ => SuggestionKind::Title,
    }
}

/// Materialize the implicit ancestors of hierarchical tags: a document tagged
/// `study/mit/ml` also carries `study` and `study/mit`, so the tag index and
/// flat tag filters see the full chain without deriving it per call site.
///
/// Order-preserving and deduplicated; the explicitly-set tag stays first,
/// ancestors are appended after it. Property tags (`key:value`) contain no
/// slash and are unaffected.
fn expand_tag_ancestors<'a, I>(tags: I) -> Vec<String>
where
    I: IntoIterator<Item = &'a String>,
{
    let mut out: Vec<String> = Vec::new();
    for tag in tags {
        let tag = tag.trim();
        if tag.is_empty() || out.iter().any(|x| x == tag) {
            continue;
        }
        out.push(tag.to_owned());
        let mut prefix = tag;
        while let Some(idx) = prefix.rfind('/') {
            prefix = &prefix[..idx];
            if prefix.is_empty() {
                break;
            }
            if !out.iter().any(|x| x == prefix) {
                out.push(prefix.to_owned());
            }
        }
    }
    out
}

fn source_str(s: crate::domain::SuggestionSource) -> &'static str {
    match s {
        crate::domain::SuggestionSource::Ingest => "ingest",
        crate::domain::SuggestionSource::Bulk => "bulk",
        crate::domain::SuggestionSource::ManualRequest => "manual_request",
        crate::domain::SuggestionSource::User => "user",
    }
}

fn source_from_str(s: &str) -> crate::domain::SuggestionSource {
    match s {
        "bulk" => crate::domain::SuggestionSource::Bulk,
        "manual_request" => crate::domain::SuggestionSource::ManualRequest,
        "user" => crate::domain::SuggestionSource::User,
        _ => crate::domain::SuggestionSource::Ingest,
    }
}

fn status_str(s: crate::domain::SuggestionStatus) -> &'static str {
    match s {
        crate::domain::SuggestionStatus::Applied => "applied",
        crate::domain::SuggestionStatus::Dismissed => "dismissed",
        _ => "pending",
    }
}

fn status_from_str(s: &str) -> crate::domain::SuggestionStatus {
    match s {
        "applied" => crate::domain::SuggestionStatus::Applied,
        "dismissed" => crate::domain::SuggestionStatus::Dismissed,
        _ => crate::domain::SuggestionStatus::Pending,
    }
}
