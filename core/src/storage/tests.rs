//! Unit tests for the repository layer (SQLite metadata + content-addressed blobs).

use std::collections::HashMap;

use crate::domain::{
    Content, Document, DocumentSuggestion, HierarchyLink, HierarchyPath, NodeKind, PathAssignment,
    SuggestionFeedback, SuggestionKind, SuggestionSource, SuggestionStatus, Tag,
};
use crate::storage::{hash_bytes, DocumentQuery, DocumentStore, SqliteDocumentStore, StorageError};

/// Create a fresh store rooted at a unique temp directory.
fn temp_store(name: &str) -> SqliteDocumentStore {
    let mut root = std::env::temp_dir();
    root.push(format!(
        "docean-test-{name}-{}-{}",
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
fn set_tags_replaces_document_tags_without_rewriting_bytes() {
    let mut store = temp_store("set_tags");
    store
        .put(doc("d1", "one", &["work", "old"]), b"the raw payload")
        .unwrap();
    let checksum = store.get(&"d1".to_owned()).unwrap().checksum_sha256;

    // Replacing the tag set must not touch the blob or other metadata.
    store
        .set_tags(&"d1".to_owned(), &["receipts".to_owned(), "new".to_owned()])
        .unwrap();

    let got = store.get(&"d1".to_owned()).unwrap();
    // The document_tags join is always read back in the store's sorted order.
    assert_eq!(got.tags, vec!["new", "receipts"]);
    assert_eq!(got.checksum_sha256, checksum);
    assert_eq!(
        store.read_bytes(&"d1".to_owned()).unwrap(),
        b"the raw payload"
    );

    // The ancestors of hierarchical tags are materialized implicitly.
    store
        .set_tags(
            &"d1".to_owned(),
            &["study/mit/ml".to_owned(), "work".to_owned()],
        )
        .unwrap();
    let got = store.get(&"d1".to_owned()).unwrap();
    assert!(got.tags.contains(&"study".to_owned()));
    assert!(got.tags.contains(&"study/mit".to_owned()));
    assert!(got.tags.contains(&"study/mit/ml".to_owned()));
    assert!(got.tags.contains(&"work".to_owned()));

    // The registry holds exactly what is still attached: names from the
    // replaced set vanish automatically (v3 prune trigger), while ancestors
    // materialized for the current set surface in list_tags.
    let names: Vec<String> = store
        .list_tags()
        .unwrap()
        .into_iter()
        .map(|t| t.name)
        .collect();
    assert!(names.contains(&"study".to_owned()));
    assert!(names.contains(&"study/mit".to_owned()));
    assert!(names.contains(&"work".to_owned()));
    assert!(!names.contains(&"receipts".to_owned()));
    assert!(!names.contains(&"new".to_owned()));

    // Clearing the set prunes every tag this document was the last to use.
    store.set_tags(&"d1".to_owned(), &[]).unwrap();
    assert!(store.get(&"d1".to_owned()).unwrap().tags.is_empty());
    assert!(
        store.list_tags().unwrap().is_empty(),
        "no document references remain"
    );

    // Unknown documents are a storage error, not a silent no-op.
    let err = store
        .set_tags(&"nope".to_owned(), &["x".to_owned()])
        .unwrap_err();
    assert!(matches!(err, StorageError::NotFound(id) if id == "nope"));
}

#[test]
fn unused_tags_are_pruned_from_the_registry() {
    let mut store = temp_store("tag_prune");
    store
        .put(doc("d1", "one", &["solo", "shared"]), b"payload one")
        .unwrap();
    store
        .put(doc("d2", "two", &["shared"]), b"payload two")
        .unwrap();

    // Re-tagging drops 'solo' (last reference gone) but keeps 'shared'
    // (still referenced by both documents).
    store
        .set_tags(&"d1".to_owned(), &["shared".to_owned()])
        .unwrap();
    let names: Vec<String> = store
        .list_tags()
        .unwrap()
        .into_iter()
        .map(|t| t.name)
        .collect();
    assert_eq!(names, vec!["shared".to_owned()], "solo pruned on untag");

    // Reattaching 'solo' to d1 then DELETING the document must prune it
    // again — this time through the FK cascade's row deletions.
    store
        .set_tags(&"d1".to_owned(), &["solo".to_owned()])
        .unwrap();
    assert!(store.list_tags().unwrap().iter().any(|t| t.name == "solo"));
    store.delete(&"d1".to_owned()).unwrap();
    let names: Vec<String> = store
        .list_tags()
        .unwrap()
        .into_iter()
        .map(|t| t.name)
        .collect();
    assert_eq!(names, vec!["shared".to_owned()], "solo pruned via cascade");

    // The shared tag survives until its LAST document is deleted.
    store.delete(&"d2".to_owned()).unwrap();
    assert!(
        store.list_tags().unwrap().is_empty(),
        "registry empties exactly when references do"
    );
}

#[test]
fn suggestions_and_feedback_round_trip() {
    let mut store = temp_store("suggestions");
    store.put(doc("d1", "Doc", &[]), b"x").unwrap();

    let now = 1000i64;
    let s = DocumentSuggestion {
        id: "d1-title-0".to_owned(),
        document_id: "d1".to_owned(),
        kind: SuggestionKind::Title,
        payload: "Suggested title".to_owned(),
        rank: 0,
        source: SuggestionSource::Ingest,
        confidence: 1.0,
        status: SuggestionStatus::Applied,
        created_at_ms: now,
    };
    store.put_suggestion(&s).unwrap();

    let alt = DocumentSuggestion {
        id: "d1-title-1".to_owned(),
        document_id: "d1".to_owned(),
        kind: SuggestionKind::Title,
        payload: "Alt title".to_owned(),
        rank: 1,
        source: SuggestionSource::Bulk,
        confidence: 0.9,
        status: SuggestionStatus::Pending,
        created_at_ms: now,
    };
    store.put_suggestion(&alt).unwrap();

    // A second applied row that should survive pruning (status = Applied is
    // kept; only Pending-older-than-threshold is pruned below).
    store
        .put_suggestion(&DocumentSuggestion {
            id: "d1-title-applied".to_owned(),
            document_id: "d1".to_owned(),
            kind: SuggestionKind::Title,
            payload: "Applied title".to_owned(),
            rank: 0,
            source: SuggestionSource::Ingest,
            confidence: 1.0,
            status: SuggestionStatus::Applied,
            created_at_ms: now,
        })
        .unwrap();

    let rows = store
        .suggestions_for_document(&"d1".to_owned(), Some(SuggestionKind::Title))
        .unwrap();
    assert_eq!(rows.len(), 3, "applied + pending + second applied");
    assert_eq!(rows[0].payload, "Suggested title");
    assert!(rows.iter().any(|r| r.status == SuggestionStatus::Pending));

    // Status transition + prune only removes non-pending rows: the two applied
    // rows (declared before `now + 1`) are pruned, the pending alternative stays.
    store.prune_suggestions(now + 1).unwrap();
    let after = store
        .suggestions_for_document(&"d1".to_owned(), Some(SuggestionKind::Title))
        .unwrap();
    assert_eq!(after.len(), 1, "pending row survives prune");
    assert_eq!(
        after[0].id, "d1-title-1",
        "only the pending alternative remains"
    );

    // Marking it dismissed then pruning removes it entirely.
    store
        .mark_suggestion("d1-title-1", SuggestionStatus::Dismissed)
        .unwrap();
    store.prune_suggestions(now + 1).unwrap();
    let cleared = store
        .suggestions_for_document(&"d1".to_owned(), Some(SuggestionKind::Title))
        .unwrap();
    assert!(cleared.is_empty(), "dismissed rows are pruned");

    // Feedback aggregation (unique ids so the primary key stays distinct).
    let events = [
        ("fb-1", "invoice", "accepted", 1.0),
        ("fb-2", "invoice", "accepted", 1.0),
        ("fb-3", "tax", "rejected", 1.0),
    ];
    for (id, term, action, weight) in events {
        store
            .record_feedback(&SuggestionFeedback {
                id: id.to_owned(),
                kind: SuggestionKind::Tags,
                context: "tag".to_owned(),
                term: term.to_owned(),
                action: action.to_owned(),
                weight,
                created_at_ms: now,
            })
            .unwrap();
    }
    let stats = store
        .feedback_stats(Some(SuggestionKind::Tags), Some("tag"))
        .unwrap();
    assert_eq!(stats["invoice"].accepts, 2.0);
    assert_eq!(stats["invoice"].rejects, 0.0);
    assert_eq!(stats["tax"].accepts, 0.0);
    assert_eq!(stats["tax"].rejects, 1.0);

    store.clear_feedback().unwrap();
    assert!(store.feedback_stats(None, None).unwrap().is_empty());
}

#[test]
fn persistence_survives_reopen() {
    let root = std::env::temp_dir().join(format!(
        "docean-persist-{}-{}",
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
