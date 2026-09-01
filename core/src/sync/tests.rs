//! Two-peer simulation tests for the sync engine.
//!
//! Each test builds two [`SyncEngineImpl`]s over shared in-memory stores linked
//! by [`LocalLink`] transports (no network), then drives `push`/`pull` and
//! asserts on the reconciled content, the returned [`ConflictResolution`]s, and
//! the emitted [`SyncEvent`]s.

use std::sync::{Arc, Mutex};

use crate::domain::Document;
use crate::sync::testing::{make_doc, InMemoryStore, LocalLink};
use crate::sync::{
    ConflictResolution, PeerId, ResolutionStrategy, SyncEngine, SyncEngineImpl, SyncEvent,
    SyncProgress, SyncStore,
};

/// Shorthand store type used by both the engines and the links.
type SharedStore = Arc<Mutex<InMemoryStore>>;

fn doc(id: &str, checksum: &str, updated_at_ms: i64, title: &str) -> Document {
    make_doc(id, checksum, updated_at_ms, title)
}

/// Build two engines sharing their stores, linked A <-> B.
fn linked_pair(
    a_store: InMemoryStore,
    b_store: InMemoryStore,
    strategy: ResolutionStrategy,
) -> (
    SyncEngineImpl<SharedStore>,
    SyncEngineImpl<SharedStore>,
    SharedStore,
    SharedStore,
) {
    let a_shared: SharedStore = Arc::new(Mutex::new(a_store));
    let b_shared: SharedStore = Arc::new(Mutex::new(b_store));

    let mut a = SyncEngineImpl::with_strategy(a_shared.clone(), strategy);
    let mut b = SyncEngineImpl::with_strategy(b_shared.clone(), strategy);

    a.attach_transport(Box::new(LocalLink::new(
        PeerId("peer-b".to_owned()),
        b_shared.clone(),
    )));
    b.attach_transport(Box::new(LocalLink::new(
        PeerId("peer-a".to_owned()),
        a_shared.clone(),
    )));

    (a, b, a_shared, b_shared)
}

fn collect_events(engine: &mut SyncEngineImpl<SharedStore>) -> Vec<SyncEvent> {
    let mut out = Vec::new();
    if let Some(rx) = engine.subscribe() {
        while let Ok(ev) = rx.try_recv() {
            out.push(ev);
        }
    }
    out
}

#[test]
fn pull_transfers_missing_document_and_preserves_tags_and_parent() {
    let mut b_store = InMemoryStore::new();

    // Peer B holds one document with tags and a parent assignment.
    let mut d = doc("doc-1", "hash-b", 2000, "notes");
    d.tags = vec!["work".to_owned(), "important".to_owned()];
    d.parent_id = Some("folder-1".to_owned());
    b_store.put(d, b"B version".to_vec()).unwrap();

    let (mut a, _b, a_shared, _b_shared) =
        linked_pair(InMemoryStore::new(), b_store, ResolutionStrategy::Fork);

    let results = a.pull().unwrap();
    assert!(results.is_empty(), "no conflict expected, got {results:?}");

    let adopted = a_shared
        .lock()
        .unwrap()
        .document(&"doc-1".to_owned())
        .unwrap()
        .unwrap();
    assert_eq!(adopted.checksum_sha256, "hash-b");
    assert_eq!(
        adopted.tags,
        vec!["work".to_owned(), "important".to_owned()]
    );
    assert_eq!(adopted.parent_id, Some("folder-1".to_owned()));

    // Bytes were transferred too.
    assert_eq!(
        a_shared
            .lock()
            .unwrap()
            .read_bytes(&"doc-1".to_owned())
            .unwrap()
            .unwrap(),
        b"B version".to_vec()
    );
}

#[test]
fn push_sends_document_to_peer() {
    let mut a_store = InMemoryStore::new();
    a_store
        .put(
            doc("doc-x", "hash-x", 3000, "pushed"),
            b"pushed bytes".to_vec(),
        )
        .unwrap();

    let (mut a, _b, _a_shared, b_shared) =
        linked_pair(a_store, InMemoryStore::new(), ResolutionStrategy::Fork);

    a.push(&"doc-x".to_owned()).unwrap();

    // Peer B adopted the pushed document.
    let b_docs = b_shared.lock().unwrap().list().unwrap();
    assert_eq!(b_docs.len(), 1);
    assert_eq!(b_docs[0].id, "doc-x");
    assert_eq!(b_docs[0].checksum_sha256, "hash-x");
}

#[test]
fn conflict_with_fork_keeps_both_versions() {
    let mut a_store = InMemoryStore::new();
    let mut b_store = InMemoryStore::new();
    a_store
        .put(
            doc("doc-c", "hash-a", 1000, "local edit"),
            b"local".to_vec(),
        )
        .unwrap();
    b_store
        .put(
            doc("doc-c", "hash-b", 2000, "remote edit"),
            b"remote".to_vec(),
        )
        .unwrap();

    let (mut a, _b, a_shared, _b_shared) = linked_pair(a_store, b_store, ResolutionStrategy::Fork);

    let results = a.pull().unwrap();

    // Fork resolution returns a Forked outcome.
    assert_eq!(results.len(), 1);
    assert!(matches!(results[0], ConflictResolution::Forked(_)));

    // Both versions now coexist in A's store.
    let docs = a_shared.lock().unwrap().list().unwrap();
    assert_eq!(docs.len(), 2, "fork should keep both, got {docs:?}");

    // The conflict was recorded and surfaced.
    assert_eq!(a.conflicts().len(), 1);
    let c = &a.conflicts()[0];
    assert_eq!(c.document_id, "doc-c");
    assert_eq!(c.local_checksum, "hash-a");
    assert_eq!(c.remote_checksum, "hash-b");
    assert_eq!(c.winner, "fork");
    let forked_id = c.forked_document_id.clone().unwrap();
    assert!(forked_id.starts_with("doc-c.conflict."));
}

#[test]
fn conflict_with_newest_wins_deterministically() {
    let mut a_store = InMemoryStore::new();
    let mut b_store = InMemoryStore::new();
    a_store
        .put(doc("doc-n", "hash-old", 1000, "old"), b"old".to_vec())
        .unwrap();
    b_store
        .put(doc("doc-n", "hash-new", 9000, "new"), b"new".to_vec())
        .unwrap();

    let (mut a, _b, a_shared, _b_shared) =
        linked_pair(a_store, b_store, ResolutionStrategy::Newest);

    let results = a.pull().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0], ConflictResolution::RemoteWon);

    // A now holds the newer (remote) content.
    let doc = a_shared
        .lock()
        .unwrap()
        .document(&"doc-n".to_owned())
        .unwrap()
        .unwrap();
    assert_eq!(doc.checksum_sha256, "hash-new");
}

#[test]
fn agreement_produces_no_transfer_and_no_conflict() {
    let mut a_store = InMemoryStore::new();
    let mut b_store = InMemoryStore::new();
    let shared = doc("doc-s", "hash-same", 5000, "same");
    a_store.put(shared.clone(), b"same".to_vec()).unwrap();
    b_store.put(shared, b"same".to_vec()).unwrap();

    let (mut a, _b, a_shared, _b_shared) = linked_pair(a_store, b_store, ResolutionStrategy::Fork);

    let results = a.pull().unwrap();
    assert!(results.is_empty(), "no conflict expected, got {results:?}");

    // Still exactly one copy.
    let docs = a_shared.lock().unwrap().list().unwrap();
    assert_eq!(docs.len(), 1);
}

#[test]
fn events_report_progress_transfer_and_finish() {
    let mut b_store = InMemoryStore::new();
    b_store
        .put(doc("doc-e", "hash-e", 1000, "event"), b"bytes".to_vec())
        .unwrap();

    let (mut a, _b, _a_shared, _b_shared) =
        linked_pair(InMemoryStore::new(), b_store, ResolutionStrategy::Fork);

    a.pull().unwrap();
    let events = collect_events(&mut a);

    let saw_manifest = events.iter().any(|e| {
        matches!(
            e,
            SyncEvent::Progress {
                progress: SyncProgress::ExchangingManifests,
                ..
            }
        )
    });
    let saw_transfer = events.iter().any(|e| {
        matches!(
            e,
            SyncEvent::Progress {
                progress: SyncProgress::TransferringContent,
                ..
            }
        )
    });
    let saw_transferred = events.iter().any(|e| {
        matches!(e, SyncEvent::DocumentTransferred { document_id, .. } if document_id == "doc-e")
    });
    let saw_finished = events
        .iter()
        .any(|e| matches!(e, SyncEvent::Finished { .. }));

    assert!(saw_manifest, "expected ExchangingManifests event");
    assert!(saw_transfer, "expected TransferringContent event");
    assert!(saw_transferred, "expected DocumentTransferred event");
    assert!(saw_finished, "expected Finished event");
}
