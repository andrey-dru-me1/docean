//! SQLite-backed implementation of [`DocumentStore`].
//!
//! Metadata, tags, paths, hierarchy edges, and extracted content live in a
//! single SQLite database file (`<root>/docer.db`); raw bytes live in the
//! [`BlobStore`] under `<root>/blobs/`. See [`crate::storage::schema`] for the
//! schema.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::domain::{
    Content, Document, DocumentId, HierarchyLink, HierarchyPath, NodeKind, PathAssignment, Tag,
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

        let db_path = root.join("docer.db");
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

            // Reconcile the document's tag assignments.
            tx.execute(
                "DELETE FROM document_tags WHERE document_id = ?1",
                [&doc.id],
            )?;
            for tag in &doc.tags {
                tx.execute("INSERT OR IGNORE INTO tags(name) VALUES (?1)", [tag])?;
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

    // --- many-to-many paths ------------------------------------------------

    fn put_path(&mut self, path: &HierarchyPath) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                "INSERT INTO paths(path) VALUES (?1) ON CONFLICT(path) DO NOTHING",
                [&path.path],
            )?;
            Ok(())
        })
    }

    fn list_paths(&self) -> Result<Vec<HierarchyPath>, StorageError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare("SELECT path FROM paths ORDER BY path")?;
            let paths = stmt
                .query_map([], |r| Ok(HierarchyPath { path: r.get(0)? }))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(paths)
        })
    }

    fn delete_path(&mut self, path: &str) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            let n = conn.execute("DELETE FROM paths WHERE path = ?1", [path])?;
            if n == 0 {
                return Err(StorageError::PathNotFound(path.to_owned()));
            }
            Ok(())
        })
    }

    fn assign_path(&mut self, assignment: PathAssignment) -> Result<(), StorageError> {
        // Ensure the path exists before assigning to it.
        self.put_path(&HierarchyPath {
            path: assignment.path.clone(),
        })?;

        self.with_conn_mut(|conn| {
            conn.execute(
                r#"
                INSERT INTO document_paths(document_id, path_id, position)
                VALUES (?1, (SELECT id FROM paths WHERE path = ?2), ?3)
                ON CONFLICT(document_id, path_id) DO UPDATE SET position = excluded.position
                "#,
                params![assignment.document_id, assignment.path, assignment.position],
            )?;
            Ok(())
        })
    }

    fn unassign_path(&mut self, document_id: &DocumentId, path: &str) -> Result<(), StorageError> {
        self.with_conn_mut(|conn| {
            conn.execute(
                r#"
                DELETE FROM document_paths
                WHERE document_id = ?1 AND path_id = (SELECT id FROM paths WHERE path = ?2)
                "#,
                params![document_id, path],
            )?;
            Ok(())
        })
    }

    fn paths_of(&self, document_id: &DocumentId) -> Result<Vec<HierarchyPath>, StorageError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                r#"
                SELECT p.path FROM paths p
                JOIN document_paths dp ON dp.path_id = p.id
                WHERE dp.document_id = ?1
                ORDER BY dp.position, p.path
                "#,
            )?;
            let paths = stmt
                .query_map([document_id], |r| Ok(HierarchyPath { path: r.get(0)? }))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(paths)
        })
    }

    fn documents_at(&self, path: &str) -> Result<Vec<DocumentId>, StorageError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare(
                r#"
                SELECT dp.document_id FROM document_paths dp
                JOIN paths p ON p.id = dp.path_id
                WHERE p.path = ?1
                ORDER BY dp.position, dp.document_id
                "#,
            )?;
            let ids = stmt
                .query_map([path], |r| r.get::<_, String>(0))?
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
}
