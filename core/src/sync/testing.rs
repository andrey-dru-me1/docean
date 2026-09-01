//! Test and reference implementations: an in-memory [`SyncStore`] and an
//! in-process peer link connecting two stores directly.
//!
//! These are used by the sync unit tests to simulate two peers, but they are
//! also useful as a self-contained memory backend for prototyping.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::domain::{Document, DocumentId, HierarchyLink, Tag};
use crate::sync::transport::{serve, SyncRequest, SyncResponse, TransportError};
use crate::sync::{PeerId, PeerTransport, SyncError, SyncStore};

/// A simple, fully in-memory [`SyncStore`]. Documents are keyed by id; raw bytes
/// are held alongside metadata.
#[derive(Default, Clone)]
pub struct InMemoryStore {
    docs: BTreeMap<DocumentId, Document>,
    blobs: BTreeMap<DocumentId, Vec<u8>>,
    links: Vec<HierarchyLink>,
    tags: Vec<Tag>,
}

impl InMemoryStore {
    pub fn new() -> Self {
        Self::default()
    }
}

/// Allow an engine to own a *shared* handle to an in-memory store, so the store
/// can also be handed to a [`LocalLink`] (the remote side of a peer) and read by
/// tests. All methods lock the inner mutex.
impl SyncStore for Arc<Mutex<InMemoryStore>> {
    fn document(&self, id: &DocumentId) -> Result<Option<Document>, SyncError> {
        self.lock().unwrap().document(id)
    }

    fn list(&self) -> Result<Vec<Document>, SyncError> {
        self.lock().unwrap().list()
    }

    fn read_bytes(&self, id: &DocumentId) -> Result<Option<Vec<u8>>, SyncError> {
        self.lock().unwrap().read_bytes(id)
    }

    fn put(&mut self, doc: Document, bytes: Vec<u8>) -> Result<(), SyncError> {
        self.lock().unwrap().put(doc, bytes)
    }

    fn delete(&mut self, id: &DocumentId) -> Result<(), SyncError> {
        self.lock().unwrap().delete(id)
    }

    fn links(&self) -> Result<Vec<HierarchyLink>, SyncError> {
        self.lock().unwrap().links()
    }

    fn link(&mut self, link: HierarchyLink) -> Result<(), SyncError> {
        self.lock().unwrap().link(link)
    }

    fn tags(&self) -> Result<Vec<Tag>, SyncError> {
        self.lock().unwrap().tags()
    }

    fn put_tag(&mut self, tag: Tag) -> Result<(), SyncError> {
        self.lock().unwrap().put_tag(tag)
    }
}

impl SyncStore for InMemoryStore {
    fn document(&self, id: &DocumentId) -> Result<Option<Document>, SyncError> {
        Ok(self.docs.get(id).cloned())
    }

    fn list(&self) -> Result<Vec<Document>, SyncError> {
        Ok(self.docs.values().cloned().collect())
    }

    fn read_bytes(&self, id: &DocumentId) -> Result<Option<Vec<u8>>, SyncError> {
        Ok(self.blobs.get(id).cloned())
    }

    fn put(&mut self, doc: Document, bytes: Vec<u8>) -> Result<(), SyncError> {
        self.blobs.insert(doc.id.clone(), bytes);
        self.docs.insert(doc.id.clone(), doc);
        Ok(())
    }

    fn delete(&mut self, id: &DocumentId) -> Result<(), SyncError> {
        self.docs.remove(id);
        self.blobs.remove(id);
        Ok(())
    }

    fn links(&self) -> Result<Vec<HierarchyLink>, SyncError> {
        Ok(self.links.clone())
    }

    fn link(&mut self, link: HierarchyLink) -> Result<(), SyncError> {
        self.links.push(link);
        Ok(())
    }

    fn tags(&self) -> Result<Vec<Tag>, SyncError> {
        Ok(self.tags.clone())
    }

    fn put_tag(&mut self, tag: Tag) -> Result<(), SyncError> {
        self.tags.push(tag);
        Ok(())
    }
}

/// An in-process [`PeerTransport`] that routes requests directly to another
/// peer's in-memory store. This lets two [`crate::sync::SyncEngineImpl`]s talk
/// to each other without any network, which is ideal for deterministic tests.
///
/// The link holds a shared handle to the *remote* store; `request` answers by
/// calling [`serve`] against it (matching exactly what a network transport
/// would do on the far side).
pub struct LocalLink {
    peer: PeerId,
    remote: Arc<Mutex<InMemoryStore>>,
}

impl LocalLink {
    /// Build a link toward `peer` backing onto `remote` store.
    pub fn new(peer: PeerId, remote: Arc<Mutex<InMemoryStore>>) -> Self {
        Self { peer, remote }
    }
}

impl PeerTransport for LocalLink {
    fn peers(&self) -> Vec<PeerId> {
        vec![self.peer.clone()]
    }

    fn request(&self, _peer: &PeerId, req: SyncRequest) -> Result<SyncResponse, TransportError> {
        let mut store = self
            .remote
            .lock()
            .map_err(|e| TransportError::Other(e.to_string()))?;
        Ok(serve(&mut *store, &req))
    }
}

/// Convenience: seed an in-memory store with a single document.
pub fn seed_doc(store: &mut InMemoryStore, doc: Document, bytes: &[u8]) {
    store.put(doc, bytes.to_vec()).unwrap();
}

/// Convenience: a ready-made [`Document`] with the given id/hash/edit-time.
pub fn make_doc(id: &str, checksum: &str, updated_at_ms: i64, title: &str) -> Document {
    Document {
        id: id.to_owned(),
        parent_id: None,
        kind: crate::domain::NodeKind::Document,
        title: title.to_owned(),
        mime_type: "text/plain".to_owned(),
        size_bytes: 0,
        checksum_sha256: checksum.to_owned(),
        tags: vec![],
        created_at_ms: updated_at_ms,
        updated_at_ms,
        extra: Default::default(),
    }
}
