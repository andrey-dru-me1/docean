//! Peer-to-peer file sync with conflict resolution.
//!
//! **Boundary:** replicate the library across devices over a P2P transport and
//! merge concurrent edits deterministically.
//!
//! **Planned crates:**
//! * [`iroh`](https://crates.io/crates/iroh) — P2P transport over QUIC, with
//!   content-addressed blobs and document sync primitives.
//! * [`automerge`](https://crates.io/crates/automerge) — CRDT used for
//!   conflict-free merges of metadata, hierarchy, and tags.

use crate::domain::DocumentId;

/// A device participating in sync.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PeerId(pub String);

/// Outcome of reconciling a remote change with local state.
#[derive(Debug, Clone, PartialEq, Eq)]
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
