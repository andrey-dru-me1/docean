//! SQLite schema and migration mechanism.
//!
//! Migrations are idempotent SQL migrations tracked with SQLite's built-in
//! `PRAGMA user_version`. Each migration bumps the version by one; applying is
//! simply running every migration whose index is greater than the current
//! version, inside a transaction.

use rusqlite::Connection;

use crate::storage::StorageError;

/// Ordered list of migrations. `MIGRATIONS[i]` migrates `i -> i + 1`.
const MIGRATIONS: &[&str] = &[
    // v0 -> v1: initial schema.
    r#"
    CREATE TABLE documents (
        id              TEXT PRIMARY KEY,
        kind            TEXT NOT NULL,
        title           TEXT NOT NULL,
        mime_type       TEXT NOT NULL,
        size_bytes      INTEGER NOT NULL,
        checksum_sha256 TEXT NOT NULL,
        created_at_ms   INTEGER NOT NULL,
        updated_at_ms   INTEGER NOT NULL,
        parent_id       TEXT,
        extra           TEXT NOT NULL
    );

    -- Nested tags keyed by unique name (parent points at another tag's name).
    CREATE TABLE tags (
        name    TEXT PRIMARY KEY,
        parent  TEXT,
        color   TEXT
    );

    -- Many-to-many: documents <-> tags.
    CREATE TABLE document_tags (
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        tag         TEXT NOT NULL REFERENCES tags(name) ON DELETE CASCADE,
        PRIMARY KEY (document_id, tag)
    );

    -- Hierarchy paths are first-class entities, independent of any document.
    CREATE TABLE paths (
        id   INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE
    );

    -- Many-to-many: documents <-> paths. A single document is reachable via
    -- multiple paths (and a path contains multiple documents).
    CREATE TABLE document_paths (
        document_id  TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        path_id      INTEGER NOT NULL REFERENCES paths(id) ON DELETE CASCADE,
        position     INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (document_id, path_id)
    );
    CREATE INDEX idx_document_paths_path ON document_paths(path_id, position);

    -- The legacy single-parent hierarchy edge (parent/child folders).
    CREATE TABLE hierarchy_links (
        parent_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        child_id  TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        position  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (parent_id, child_id)
    );

    -- Extracted/ingested text content, one row per document.
    CREATE TABLE content (
        document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
        text        TEXT NOT NULL,
        source      TEXT NOT NULL
    );
    "#,
    // v1 -> v2: pending metadata suggestions (for user review in the document
    // detail view) and the on-device feedback table that powers the learning
    // model.
    r#"
    -- One row per suggested title or tag-set candidate. rank 0 is the currently
    -- applied suggestion (when the user has not replaced it with a manual edit);
    -- rank >= 1 are pending alternatives the user may review in the document
    -- info card. status transitions: pending -> applied|dismissed.
    CREATE TABLE document_suggestions (
        id            TEXT PRIMARY KEY,
        document_id   TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        kind          TEXT NOT NULL,          -- 'title' | 'tags'
        payload       TEXT NOT NULL,          -- title text / JSON array of tags
        rank          INTEGER NOT NULL,
        source        TEXT NOT NULL,          -- 'ingest' | 'bulk' | 'manual_request' | 'user'
        confidence    REAL NOT NULL DEFAULT 1.0,
        status        TEXT NOT NULL,          -- 'pending' | 'applied' | 'dismissed'
        created_at_ms INTEGER NOT NULL
    );
    CREATE INDEX idx_suggestions_doc ON document_suggestions(document_id, kind, status, rank);

    -- Per-term preference evidence recorded when the user reviews a suggestion
    -- (Keep/switch/dismiss/type-own). The feedback model aggregates accepts and
    -- rejects per (kind, context, term) to re-rank future suggestions.
    CREATE TABLE suggestion_feedback (
        id            TEXT PRIMARY KEY,
        kind          TEXT NOT NULL,          -- 'title' | 'tags'
        context       TEXT NOT NULL,          -- 'title' | 'tag' (future: 'path', ...)
        term          TEXT NOT NULL,          -- tag name or normalized title keyword
        action        TEXT NOT NULL,          -- 'accepted' | 'rejected'
        weight        REAL NOT NULL,          -- 1.0 model tap, 2.0 user-typed
        created_at_ms INTEGER NOT NULL
    );
    CREATE INDEX idx_feedback_term ON suggestion_feedback(kind, context, term);
    "#,
    // v2 -> v3: unused tags are never stored. An AFTER DELETE trigger on the
    // join table prunes a tag row the moment its last document reference
    // disappears — this covers re-tagging (`set_tags`/`put` delete the join
    // rows first), tag renames (which re-tag through the same path) and
    // document deletion (the FK cascade's row deletions fire the trigger;
    // verified empirically on this SQLite build). The tag-keyed index backs
    // the per-delete reference check and the FK cascades. The backfill sweep
    // purges orphans left behind by the previous catalog-forever behaviour.
    // Note: `put_tag` (metadata seeding, unused in production) is the only
    // remaining way to create a standalone row; every document-driven path
    // keeps the registry and the join table in lockstep.
    r#"
    CREATE INDEX idx_document_tags_tag ON document_tags(tag);

    CREATE TRIGGER tags_prune_unreferenced
    AFTER DELETE ON document_tags
    FOR EACH ROW
    WHEN (SELECT COUNT(*) FROM document_tags WHERE tag = OLD.tag) = 0
    BEGIN
        DELETE FROM tags WHERE name = OLD.tag;
    END;

    DELETE FROM tags WHERE name NOT IN (SELECT tag FROM document_tags);
    "#,
    // v3 -> v4: the logical many-to-many hierarchy-path system is removed.
    // The physical folder layout lives in the library mirror (main_path,
    // derived from tags) and parent/child links live in hierarchy_links; this
    // virtual-placement table (whose default only ever produced `/inbox`) was
    // display-only with no editor. Dropping the tables also severs every
    // assignment; `/inbox` and friends disappear with them.
    r#"
    DROP TABLE IF EXISTS document_paths;
    DROP TABLE IF EXISTS paths;
    "#,
];

/// Apply all pending migrations to `conn`.
pub fn migrate(conn: &mut Connection) -> Result<(), StorageError> {
    let current: u32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;

    for (i, migration) in MIGRATIONS.iter().enumerate() {
        let target = (i + 1) as u32;
        if target <= current {
            continue;
        }
        let tx = conn.transaction()?;
        tx.execute_batch(migration)?;
        tx.pragma_update(None, "user_version", target)?;
        tx.commit()?;
    }

    Ok(())
}

/// Version helper primarily used by tests to assert migrations ran.
#[cfg(test)]
pub fn user_version(conn: &Connection) -> Result<u32, StorageError> {
    Ok(conn.pragma_query_value(None, "user_version", |row| row.get(0))?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrations_apply_cleanly_and_are_idempotent() {
        let mut conn = Connection::open_in_memory().unwrap();

        migrate(&mut conn).unwrap();
        assert_eq!(user_version(&conn).unwrap(), MIGRATIONS.len() as u32);

        // Re-running must be a no-op.
        migrate(&mut conn).unwrap();
        assert_eq!(user_version(&conn).unwrap(), MIGRATIONS.len() as u32);

        // Core tables exist.
        for table in [
            "documents",
            "tags",
            "document_tags",
            "hierarchy_links",
            "content",
            "document_suggestions",
            "suggestion_feedback",
        ] {
            let count: i64 = conn
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    [table],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(count, 1, "missing table {table}");
        }

        // The logical hierarchy-path tables were dropped in v4.
        for table in ["paths", "document_paths"] {
            let count: i64 = conn
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    [table],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(count, 0, "table {table} should have been dropped");
        }
    }
}
