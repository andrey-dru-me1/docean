//! The transport seam between the sync engine and a concrete P2P connection.
//!
//! [`PeerTransport`] abstracts "send a request to a peer and await its reply" so
//! the reconcile protocol (see [`crate::sync::protocol`]) never depends on a
//! particular transport. Production wires this to [`crate::net::P2pEngine`];
//! tests use the in-process [`LocalLink`] whose halves are connected directly to
//! each other's store.

use serde::{Deserialize, Serialize};

use crate::domain::{Document, NodeKind};
use crate::sync::PeerId;

/// A lightweight per-document record exchanged during reconciliation: the fields
/// needed to compare two peers' views without shipping raw bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestEntry {
    pub id: String,
    /// SHA-256 of the raw bytes.
    pub checksum_sha256: String,
    /// Wall-clock edit time, milliseconds since epoch.
    pub updated_at_ms: i64,
    pub parent_id: Option<String>,
    pub tags: Vec<String>,
    pub title: String,
    pub mime_type: String,
    pub kind: String,
    pub size_bytes: u64,
    pub created_at_ms: i64,
}

fn kind_to_str(kind: NodeKind) -> String {
    match kind {
        NodeKind::Document => "document".to_owned(),
        NodeKind::Folder => "folder".to_owned(),
    }
}

fn kind_from_str(s: &str) -> NodeKind {
    match s {
        "folder" => NodeKind::Folder,
        _ => NodeKind::Document,
    }
}

impl From<&Document> for ManifestEntry {
    fn from(d: &Document) -> Self {
        Self {
            id: d.id.clone(),
            checksum_sha256: d.checksum_sha256.clone(),
            updated_at_ms: d.updated_at_ms,
            parent_id: d.parent_id.clone(),
            tags: d.tags.clone(),
            title: d.title.clone(),
            mime_type: d.mime_type.clone(),
            kind: kind_to_str(d.kind),
            size_bytes: d.size_bytes,
            created_at_ms: d.created_at_ms,
        }
    }
}

impl ManifestEntry {
    /// Rebuild a full [`Document`] from this manifest record. Raw bytes and
    /// `extra` are supplied by the caller (bytes come from the blob transfer;
    /// `extra` is empty for network-adopted documents).
    pub fn to_document(&self, extra: std::collections::HashMap<String, String>) -> Document {
        Document {
            id: self.id.clone(),
            parent_id: self.parent_id.clone(),
            kind: kind_from_str(&self.kind),
            title: self.title.clone(),
            mime_type: self.mime_type.clone(),
            size_bytes: self.size_bytes,
            checksum_sha256: self.checksum_sha256.clone(),
            tags: self.tags.clone(),
            created_at_ms: self.created_at_ms,
            updated_at_ms: self.updated_at_ms,
            extra,
        }
    }
}

/// A request sent from one peer to another during a sync round.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncRequest {
    /// The sender advertises one or more documents; the receiver replies with
    /// the entries the sender is missing or holding stale.
    SendManifest { entries: Vec<ManifestEntry> },
    /// Request raw bytes for the given content hashes.
    FetchBlobs { checksums: Vec<String> },
    /// Request full documents (metadata + bytes) for the given ids.
    FetchDocuments { ids: Vec<String> },
    /// Offer a document (metadata + bytes) that the receiver should store if it
    /// does not already hold the same content (used by push).
    PushDocument { payload: DocumentPayload },
}

/// A document plus its raw bytes, as carried over the wire.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentPayload {
    pub manifest: ManifestEntry,
    pub bytes: Vec<u8>,
}

/// A reply to a [`SyncRequest`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncResponse {
    /// Entries the requesting peer is missing or stale on (reply to SendManifest).
    Manifest { missing: Vec<ManifestEntry> },
    /// Raw bytes keyed by content hash (reply to FetchBlobs).
    Blobs { blobs: Vec<DocumentPayload> },
    /// Full documents (reply to FetchDocuments).
    Documents { docs: Vec<DocumentPayload> },
}

/// A full, serializable unit of a sync exchange (one request and/or one reply).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncEnvelope {
    pub request: Option<SyncRequest>,
    pub response: Option<SyncResponse>,
}

/// Error returned by a transport layer.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("peer {0} is not reachable")]
    Unreachable(PeerId),
    #[error("transport: {0}")]
    Other(String),
}

/// The transport seam: send a [`SyncRequest`] and receive a [`SyncResponse`].
///
/// Implementations may be asynchronous in reality; the sync engine drives them
/// synchronously (the protocol runs on a worker thread in production).
pub trait PeerTransport: Send + Sync {
    /// The peers reachable over this transport.
    fn peers(&self) -> Vec<PeerId>;

    /// Send a request and block for the peer's response.
    fn request(&self, peer: &PeerId, req: SyncRequest) -> Result<SyncResponse, TransportError>;
}

use crate::sync::SyncStore;

/// Answer a [`SyncRequest`] against a local [`SyncStore`] (the *server* side of
/// the protocol). This is shared by every transport so request handling is
/// identical in-process (tests) and over the wire (production).
///
/// `store` is mutable because [`SyncRequest::PushDocument`] writes to it.
pub fn serve<S: SyncStore>(store: &mut S, req: &SyncRequest) -> SyncResponse {
    match req {
        SyncRequest::SendManifest { entries } => {
            let remote: std::collections::BTreeMap<String, ManifestEntry> =
                entries.iter().map(|e| (e.id.clone(), e.clone())).collect();
            let mut missing = Vec::new();
            for doc in store.list().unwrap_or_default() {
                let entry = ManifestEntry::from(&doc);
                match remote.get(&entry.id) {
                    // Sender doesn't have it at all.
                    None => missing.push(entry),
                    // Sender has it but with a different hash.
                    Some(their) if their.checksum_sha256 != entry.checksum_sha256 => {
                        missing.push(entry);
                    }
                    // Same hash -> agree.
                    Some(_) => {}
                }
            }
            SyncResponse::Manifest { missing }
        }
        SyncRequest::FetchBlobs { checksums } => {
            let wanted: std::collections::BTreeSet<&String> = checksums.iter().collect();
            let mut blobs = Vec::new();
            for doc in store.list().unwrap_or_default() {
                if wanted.contains(&doc.checksum_sha256) {
                    if let Ok(Some(bytes)) = store.read_bytes(&doc.id) {
                        blobs.push(DocumentPayload {
                            manifest: ManifestEntry::from(&doc),
                            bytes,
                        });
                    }
                }
            }
            SyncResponse::Blobs { blobs }
        }
        SyncRequest::FetchDocuments { ids } => {
            let wanted: std::collections::BTreeSet<&String> = ids.iter().collect();
            let mut docs = Vec::new();
            for doc in store.list().unwrap_or_default() {
                if wanted.contains(&doc.id) {
                    if let Ok(Some(bytes)) = store.read_bytes(&doc.id) {
                        docs.push(DocumentPayload {
                            manifest: ManifestEntry::from(&doc),
                            bytes,
                        });
                    }
                }
            }
            SyncResponse::Documents { docs }
        }
        SyncRequest::PushDocument { payload } => {
            // Store unconditionally (idempotent: same id + hash re-put is a no-op
            // in the content-addressed sense, and newer content overwrites stale).
            let doc = payload
                .manifest
                .to_document(std::collections::HashMap::new());
            let _ = store.put(doc, payload.bytes.clone());
            SyncResponse::Documents {
                docs: vec![payload.clone()],
            }
        }
    }
}
