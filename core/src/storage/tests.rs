//! Unit tests for the repository layer (SQLite metadata + content-addressed blobs).

use std::collections::HashMap;

use crate::domain::{
    Content, Document, HierarchyLink, HierarchyPath, NodeKind, PathAssignment, Tag,
};
use crate::storage::{hash_bytes, DocumentQuery, DocumentStore, SqliteDocumentStore, StorageError};

/// Create a fresh store rooted at a unique temp directory.
fn temp_store(name: &str) -> SqliteDocumentStore {
    let mut root = std::env::temp_dir();
    root.push(format!(
        "docer-test-{name}-{}-{}",
        std::process::id(),
        rand_token()
    ));
    SqliteDocumentStore::open(root).unwrap()
}

fn rand_token() -> u128 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos()
}

fn doc(id: &str, title: &str, tags: &[&str]) -> Document {
    Document {
        id: id.to_owned(),
        parent_id: None,
        kind: NodeKind::Document,
        title: title.to_owned(),
        mime_type: "text/plain".to_owned(),
        size_bytes: 0,
        checksum_sha256: String::new(),
        tags: tags.iter().map(|s| s.to_string()).collect(),
        created_at_ms: 1,
        updated_at_ms: 1,
        extra: HashMap::new(),
    }
}

#[test]
fn put_get_round_trip_and_read_bytes() {
    let mut store = temp_store("roundtrip");
    store
        .put(doc("d1", "Hello", &["a", "b"]), b"hello world")
        .unwrap();

    let got = store.get(&"d1".to_owned()).unwrap();
    assert_eq!(got.title, "Hello");
    assert_eq!(got.tags, vec!["a".to_owned(), "b".to_owned()]);
    assert_eq!(got.checksum_sha256, hash_bytes(b"hello world"));

    assert_eq!(store.read_bytes(&"d1".to_owned()).unwrap(), b"hello world");
}

#[test]
fn get_missing_returns_not_found() {
    let store = temp_store("missing");
    match store.get(&"nope".to_owned()) {
        Err(StorageError::NotFound(id)) => assert_eq!(id, "nope"),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn put_upserts_existing_document() {
    let mut store = temp_store("upsert");
    store.put(doc("d1", "v1", &[]), b"one").unwrap();
    store.put(doc("d1", "v2", &["t"]), b"two").unwrap();

    let got = store.get(&"d1".to_owned()).unwrap();
    assert_eq!(got.title, "v2");
    assert_eq!(got.tags, vec!["t".to_owned()]);
    assert_eq!(store.read_bytes(&"d1".to_owned()).unwrap(), b"two");
}

#[test]
fn checksum_mismatch_is_rejected() {
    let mut store = temp_store("checksum");
    let mut d = doc("d1", "x", &[]);
    d.checksum_sha256 = "deadbeef".to_owned();
    assert!(matches!(store.put(d, b"payload"), Err(StorageError::Io(_))));
}

#[test]
fn delete_cascades_and_removes_unreferenced_blob() {
    let mut store = temp_store("delete");
    store.put(doc("d1", "x", &["t"]), b"bytes").unwrap();
    let hash = store.get(&"d1".to_owned()).unwrap().checksum_sha256;
    assert!(store.blobs().contains(&hash));

    store.delete(&"d1".to_owned()).unwrap();
    assert!(matches!(
        store.get(&"d1".to_owned()),
        Err(StorageError::NotFound(_))
    ));
    assert!(!store.blobs().contains(&hash));
}

#[test]
fn shared_blob_is_not_deleted_until_last_reference() {
    let mut store = temp_store("shared");
    store.put(doc("d1", "a", &[]), b"shared").unwrap();
    store.put(doc("d2", "b", &[]), b"shared").unwrap();

    let hash = hash_bytes(b"shared");

    store.delete(&"d1".to_owned()).unwrap();
    assert!(store.blobs().contains(&hash));
    assert_eq!(store.read_bytes(&"d2".to_owned()).unwrap(), b"shared");

    store.delete(&"d2".to_owned()).unwrap();
    assert!(!store.blobs().contains(&hash));
}

#[test]
fn query_filters_by_kind_tags_parent_and_paging() {
    let mut store = temp_store("query");

    let folder = Document {
        id: "folder".to_owned(),
        parent_id: None,
        kind: NodeKind::Folder,
        title: "F".to_owned(),
        mime_type: "inode/directory".to_owned(),
        size_bytes: 0,
        checksum_sha256: String::new(),
        tags: vec![],
        created_at_ms: 1,
        updated_at_ms: 1,
        extra: HashMap::new(),
    };
    store.put(folder.clone(), b"").unwrap();

    let mut d1 = doc("d1", "one", &["work"]);
    d1.parent_id = Some("folder".to_owned());
    d1.updated_at_ms = 100;
    store.put(d1, b"a").unwrap();

    let mut d2 = doc("d2", "two", &["work", "receipt"]);
    d2.parent_id = Some("folder".to_owned());
    d2.updated_at_ms = 200;
    store.put(d2, b"b").unwrap();

    let folders = store
        .query(&DocumentQuery {
            kind: Some(NodeKind::Folder),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(folders.len(), 1);
    assert_eq!(folders[0].id, "folder");

    let children = store
        .query(&DocumentQuery {
            parent: Some("folder".to_owned()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(children.len(), 2);

    let both = store
        .query(&DocumentQuery {
            tags: vec!["work".to_owned(), "receipt".to_owned()],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(both.len(), 1);
    assert_eq!(both[0].id, "d2");

    let page = store
        .query(&DocumentQuery {
            parent: Some("folder".to_owned()),
            limit: Some(1),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].id, "d2");
}

#[test]
fn hierarchy_link_and_children() {
    let mut store = temp_store("hierarchy");
    store.put(doc("root", "root", &[]), b"").unwrap();
    store.put(doc("c1", "c1", &[]), b"1").unwrap();
    store.put(doc("c2", "c2", &[]), b"2").unwrap();

    store
        .link(HierarchyLink {
            parent_id: "root".to_owned(),
            child_id: "c2".to_owned(),
            position: 0,
        })
        .unwrap();
    store
        .link(HierarchyLink {
            parent_id: "root".to_owned(),
            child_id: "c1".to_owned(),
            position: 1,
        })
        .unwrap();

    assert_eq!(
        store.children(&"root".to_owned()).unwrap(),
        vec!["c2", "c1"]
    );
}

#[test]
fn many_to_many_paths() {
    let mut store = temp_store("paths");
    store.put(doc("d1", "one", &[]), b"payload").unwrap();
    store.put(doc("d2", "two", &[]), b"payload").unwrap();

    store
        .assign_path(PathAssignment {
            document_id: "d1".to_owned(),
            path: "/inbox".to_owned(),
            position: 0,
        })
        .unwrap();
    store
        .assign_path(PathAssignment {
            document_id: "d1".to_owned(),
            path: "/archive/2026".to_owned(),
            position: 0,
        })
        .unwrap();
    store
        .assign_path(PathAssignment {
            document_id: "d2".to_owned(),
            path: "/inbox".to_owned(),
            position: 1,
        })
        .unwrap();

    let paths = store.paths_of(&"d1".to_owned()).unwrap();
    // Ordered by position, then path (both assignments use position 0, so
    // alphabetical path order applies).
    assert_eq!(
        paths,
        vec![
            HierarchyPath {
                path: "/archive/2026".to_owned()
            },
            HierarchyPath {
                path: "/inbox".to_owned()
            },
        ]
    );

    assert_eq!(store.documents_at("/inbox").unwrap(), vec!["d1", "d2"]);
    assert_eq!(store.list_paths().unwrap().len(), 2);

    store.unassign_path(&"d1".to_owned(), "/inbox").unwrap();
    assert_eq!(store.documents_at("/inbox").unwrap(), vec!["d2"]);

    store.delete_path("/archive/2026").unwrap();
    assert!(store.paths_of(&"d1".to_owned()).unwrap().is_empty());
}

#[test]
fn content_upsert_get_delete() {
    let mut store = temp_store("content");
    store.put(doc("d1", "one", &[]), b"raw").unwrap();

    store
        .put_content(&Content {
            document_id: "d1".to_owned(),
            text: "extracted".to_owned(),
            source: "ocr".to_owned(),
        })
        .unwrap();

    let c = store.get_content(&"d1".to_owned()).unwrap().unwrap();
    assert_eq!(c.text, "extracted");
    assert_eq!(c.source, "ocr");

    store
        .put_content(&Content {
            document_id: "d1".to_owned(),
            text: "new text".to_owned(),
            source: "pdf".to_owned(),
        })
        .unwrap();
    assert_eq!(
        store.get_content(&"d1".to_owned()).unwrap().unwrap().text,
        "new text"
    );

    assert!(store.get_content(&"nope".to_owned()).unwrap().is_none());

    store.delete_content(&"d1".to_owned()).unwrap();
    assert!(store.get_content(&"d1".to_owned()).unwrap().is_none());
}

#[test]
fn tags_put_and_list() {
    let mut store = temp_store("tags");
    store
        .put_tag(Tag {
            name: "receipts".to_owned(),
            parent: None,
            color: Some("#ff0000".to_owned()),
        })
        .unwrap();
    store
        .put_tag(Tag {
            name: "receipts/2026".to_owned(),
            parent: Some("receipts".to_owned()),
            color: None,
        })
        .unwrap();

    let tags = store.list_tags().unwrap();
    assert_eq!(tags.len(), 2);
    assert_eq!(tags[0].name, "receipts");
    assert_eq!(tags[1].name, "receipts/2026");
    assert_eq!(tags[1].parent.as_deref(), Some("receipts"));
}

#[test]
fn persistence_survives_reopen() {
    let root = std::env::temp_dir().join(format!(
        "docer-persist-{}-{}",
        std::process::id(),
        rand_token()
    ));

    {
        let mut store = SqliteDocumentStore::open(root.clone()).unwrap();
        store.put(doc("d1", "persisted", &["k"]), b"data").unwrap();
        store
            .assign_path(PathAssignment {
                document_id: "d1".to_owned(),
                path: "/p".to_owned(),
                position: 0,
            })
            .unwrap();
    }

    let store = SqliteDocumentStore::open(root.clone()).unwrap();
    assert_eq!(store.get(&"d1".to_owned()).unwrap().title, "persisted");
    assert_eq!(store.read_bytes(&"d1".to_owned()).unwrap(), b"data");
    assert_eq!(
        store.paths_of(&"d1".to_owned()).unwrap(),
        vec![HierarchyPath {
            path: "/p".to_owned()
        }]
    );

    let _ = std::fs::remove_dir_all(&root);
}
