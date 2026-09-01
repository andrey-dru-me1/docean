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
            "paths",
            "document_paths",
            "hierarchy_links",
            "content",
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
    }
}
