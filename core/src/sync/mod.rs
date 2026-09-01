//! Peer-to-peer file sync with conflict resolution.
//!
//! **Boundary:** replicate the library across devices over a P2P transport and
//! merge concurrent edits deterministically.
//!
//! # Protocol overview
//!
//! Sync is content-addressed: every [`crate::domain::Document`] carries a
//! `checksum_sha256` of its raw bytes, and a document's *identity* is its
//! [`DocumentId`]. Two peers reconcile by exchanging lightweight "manifests"
//! (per-document `(id, content_hash, updated_at, parent, tags)`), comparing them,
//! and only then transferring the raw bytes whose hashes are missing locally.
//!
//! The comparison yields, for each document, one of:
//!
//! * **copy** — the remote has it and the local peer does not (or its content is
//!   stale and has not been edited locally since the common ancestor);
//! * **no-op** — both agree on content hash;
//! * **conflict** — both peers edited the same document since their last common
//!   ancestor. These are resolved deterministically (see [`ResolutionStrategy`])
//!   with an optional "keep both" fork.
//!
//! The engine is deliberately transport-agnostic: it talks to peers through the
//! [`PeerTransport`] trait, so production can drive it over
//! [`crate::net::P2pEngine`] while tests use an in-process transport. This keeps
//! the reconciliation logic deterministic and unit-testable with two simulated
//! peers.
//!
//! **Planned crates:**
//! * [`iroh`](https://crates.io/crates/iroh) — P2P transport over QUIC, with
//!   content-addressed blobs and document sync primitives.
//! * [`automerge`](https://crates.io/crates/automerge) — CRDT used for
//!   conflict-free merges of metadata, hierarchy, and tags.

mod protocol;
mod transport;

/// In-memory reference implementations ([`InMemoryStore`], [`LocalLink`]) used
/// by tests and as a stand-in backend until the `redb` storage task lands.
pub mod testing;

#[cfg(test)]
mod tests;

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};

pub use protocol::{
    ConflictInfo, ConflictKind, ResolutionStrategy, SyncError, SyncEvent, SyncProgress,
};
pub use transport::{PeerTransport, SyncEnvelope};

use crate::domain::{Document, DocumentId, HierarchyLink, Tag};
use crate::search::NearDuplicateIndex;

/// A shared handle to the search layer's MinHash/LSH near-duplicate index. The
/// sync engine consults this to recognize substantially-same documents (minor
/// edits) as related versions rather than unrelated files.
pub type SharedNearDuplicateIndex = Arc<Mutex<NearDuplicateIndex>>;

/// A device participating in sync.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PeerId(pub String);

impl std::fmt::Display for PeerId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Outcome of reconciling a remote change with local state.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConflictResolution {
    /// Local and remote changes merged automatically (CRDT).
    Merged,
    /// Remote change was adopted wholesale.
    RemoteWon,
    /// Local change was kept; remote was discarded.
    LocalWon,
    /// A conflicting fork was created and requires user attention.
    Forked(DocumentId),
}

/// The local view a sync engine needs of durable storage: document metadata and
/// content, plus hierarchy links and tags.
///
/// Sync is read-mostly: it lists manifests and reads bytes, and writes adopted
/// documents, hierarchy links, and tags. This trait is the seam between the
/// sync engine and the concrete ([`crate::storage::DocumentStore`]) backend.
pub trait SyncStore {
    fn document(&self, id: &DocumentId) -> Result<Option<Document>, SyncError>;
    /// Enumerate every document currently known to the store. The reconciler
    /// needs this to build a complete manifest before comparing with a peer.
    fn list(&self) -> Result<Vec<Document>, SyncError>;
    fn read_bytes(&self, id: &DocumentId) -> Result<Option<Vec<u8>>, SyncError>;
    fn put(&mut self, doc: Document, bytes: Vec<u8>) -> Result<(), SyncError>;
    fn delete(&mut self, id: &DocumentId) -> Result<(), SyncError>;
    fn links(&self) -> Result<Vec<HierarchyLink>, SyncError>;
    fn link(&mut self, link: HierarchyLink) -> Result<(), SyncError>;
    fn tags(&self) -> Result<Vec<Tag>, SyncError>;
    fn put_tag(&mut self, tag: Tag) -> Result<(), SyncError>;
}

/// Interface for the P2P sync engine.
pub trait SyncEngine {
    fn start(&mut self) -> anyhow::Result<()>;

    fn peers(&self) -> Vec<PeerId>;

    fn connect(&mut self, peer: &PeerId) -> anyhow::Result<()>;

    /// Replicate a document (and its ancestry) to connected peers.
    fn push(&mut self, doc: &DocumentId) -> anyhow::Result<()>;

    /// Fetch remote changes and reconcile them; returns per-document outcomes.
    fn pull(&mut self) -> anyhow::Result<Vec<ConflictResolution>>;
}

/// The concrete sync engine.
///
/// Owns a [`SyncStore`] and one or more [`PeerTransport`] connections, and
/// implements the deterministic reconcile + conflict-resolution protocol in
/// [`protocol`]. Events and progress are emitted through the channel returned
/// by [`SyncEngineImpl::subscribe`].
pub struct SyncEngineImpl<S: SyncStore> {
    store: S,
    peers: BTreeSet<PeerId>,
    transports: Vec<std::sync::Arc<dyn PeerTransport>>,
    events: std::sync::mpsc::Sender<SyncEvent>,
    rx: Option<std::sync::mpsc::Receiver<SyncEvent>>,
    /// Per-document conflict records surfaced to the user for manual resolution.
    conflicts: Vec<ConflictInfo>,
    /// Deterministic resolution policy. Fork = keep both when conflicting.
    strategy: ResolutionStrategy,
    /// Shared handle to the search layer's MinHash/LSH near-duplicate index.
    /// When attached, reconciliation proposes substantially-same documents
    /// (minor edits) as related versions instead of unrelated files.
    near_dup: Option<SharedNearDuplicateIndex>,
    /// Similarity threshold above which two documents are "near duplicates".
    near_dup_threshold: f32,
}

impl<S: SyncStore> SyncEngineImpl<S> {
    pub fn new(store: S) -> Self {
        Self::with_strategy(store, ResolutionStrategy::Fork)
    }

    pub fn with_strategy(store: S, strategy: ResolutionStrategy) -> Self {
        let (tx, rx) = std::sync::mpsc::channel();
        Self {
            store,
            peers: BTreeSet::new(),
            transports: Vec::new(),
            events: tx,
            rx: Some(rx),
            conflicts: Vec::new(),
            strategy,
            near_dup: None,
            near_dup_threshold: 0.6,
        }
    }

    /// Attach the shared near-duplicate index so this engine can recognize
    /// related versions during reconciliation.
    pub fn attach_near_duplicate_index(&mut self, index: SharedNearDuplicateIndex) {
        self.near_dup = Some(index);
    }

    /// Set the Jaccard-similarity threshold for near-duplicate proposals.
    pub fn set_near_duplicate_threshold(&mut self, threshold: f32) {
        self.near_dup_threshold = threshold;
    }

    /// Attach a transport connection. The engine performs a full reconcile
    /// against each attached transport when [`SyncEngine::pull`] runs.
    pub fn attach_transport(&mut self, transport: Box<dyn PeerTransport>) {
        for peer in transport.peers() {
            self.peers.insert(peer);
        }
        self.transports.push(std::sync::Arc::from(transport));
    }

    /// Subscribe to sync events (progress, transfers, conflicts).
    pub fn subscribe(&mut self) -> Option<std::sync::mpsc::Receiver<SyncEvent>> {
        self.rx.take()
    }

    /// Documents that currently require manual resolution.
    pub fn conflicts(&self) -> &[ConflictInfo] {
        &self.conflicts
    }
}

impl<S: SyncStore> SyncEngine for SyncEngineImpl<S> {
    fn start(&mut self) -> anyhow::Result<()> {
        self.emit(SyncEvent::Started {
            peers: self.peers.iter().map(|p| p.0.clone()).collect(),
        });
        Ok(())
    }

    fn peers(&self) -> Vec<PeerId> {
        self.peers.iter().cloned().collect()
    }

    fn connect(&mut self, peer: &PeerId) -> anyhow::Result<()> {
        self.peers.insert(peer.clone());
        Ok(())
    }

    fn push(&mut self, doc: &DocumentId) -> anyhow::Result<()> {
        protocol::push(self, doc).map_err(anyhow::Error::from)
    }

    fn pull(&mut self) -> anyhow::Result<Vec<ConflictResolution>> {
        protocol::pull(self).map_err(anyhow::Error::from)
    }
}

impl<S: SyncStore> SyncEngineImpl<S> {
    pub(crate) fn emit(&self, event: SyncEvent) {
        let _ = self.events.send(event);
    }

    pub(crate) fn store(&self) -> &S {
        &self.store
    }

    pub(crate) fn store_mut(&mut self) -> &mut S {
        &mut self.store
    }

    pub(crate) fn transports(&self) -> &[std::sync::Arc<dyn PeerTransport>] {
        &self.transports
    }

    pub(crate) fn strategy(&self) -> &ResolutionStrategy {
        &self.strategy
    }

    pub(crate) fn near_dup(&self) -> Option<&SharedNearDuplicateIndex> {
        self.near_dup.as_ref()
    }

    pub(crate) fn near_dup_threshold(&self) -> f32 {
        self.near_dup_threshold
    }

    pub(crate) fn record_conflict(&mut self, info: ConflictInfo) {
        self.conflicts.push(info);
    }
}
