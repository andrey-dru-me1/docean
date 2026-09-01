//! The deterministic reconcile and conflict-resolution protocol.
//!
//! # Algorithm
//!
//! Reconciliation runs per connected peer:
//!
//! 1. **Manifest exchange** — the local peer sends its full manifest (built from
//!    [`SyncStore::list`]); the peer replies with the entries it has that the
//!    local peer is *missing entirely* or *holding with a different hash*.
//! 2. **Content transfer** — the local peer fetches the raw bytes for every
//!    missing/stale entry (keyed by content hash) and stores the adopted
//!    document, preserving its `parent_id` and `tags`.
//! 3. **Conflict detection & resolution** — for entries the local peer already
//!    had but with a *different* hash, both sides edited the document. The
//!    winner is chosen deterministically (so both peers agree without extra
//!    negotiation) according to [`ResolutionStrategy`]:
//!    * `RemoteWins` / `LocalWins` — adopt one side wholesale;
//!    * `Newest` — newer edit time wins, content hash breaks ties;
//!    * `Fork` — keep both: the local copy stays, the remote copy is written
//!      under a deterministically derived id and re-parented under the original
//!      so both versions sit together for manual review.
//!
//! Every conflict is also recorded and emitted as a [`SyncEvent::Conflict`], so
//! the user can review and manually resolve it later.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::{Deserialize, Serialize};

use crate::domain::{DocumentId, HierarchyLink};
use crate::sync::transport::{DocumentPayload, ManifestEntry, SyncRequest, SyncResponse};
use crate::sync::{ConflictResolution, PeerId, PeerTransport, SyncEngineImpl, SyncStore};

/// Errors surfaced by the sync protocol.
#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("document {0} not found")]
    NotFound(DocumentId),
    #[error("transport failure: {0}")]
    Transport(#[from] crate::sync::transport::TransportError),
    #[error("sync: {0}")]
    Other(String),
}

/// How the protocol resolves a conflicting document.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ResolutionStrategy {
    /// Adopt the remote copy wholesale.
    RemoteWins,
    /// Keep the local copy; discard the remote.
    LocalWins,
    /// Adopt whichever copy has the newer edit time (hash breaks ties).
    Newest,
    /// Keep both copies: fork the remote into its own document.
    Fork,
}

/// The kind of conflict that was detected.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConflictKind {
    /// Both peers edited the same document's content independently.
    ContentDiverged,
    /// Both peers changed the document's tags / parent independently.
    MetadataDiverged,
}

/// A record of a conflict, surfaced to the user for manual resolution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConflictInfo {
    pub document_id: DocumentId,
    pub kind: ConflictKind,
    pub local_checksum: String,
    pub remote_checksum: String,
    pub local_updated_at_ms: i64,
    pub remote_updated_at_ms: i64,
    /// If resolved by [`ResolutionStrategy::Fork`], the id of the created fork.
    pub forked_document_id: Option<DocumentId>,
    /// Which side was adopted: `"local"`, `"remote"`, or `"fork"`.
    pub winner: String,
}

/// Coarse-grained progress of a sync round, pushed to Dart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncProgress {
    ExchangingManifests,
    TransferringContent,
    Reconciling,
    Done,
}

/// An event emitted by the sync engine during a round.
// Note: not `Eq` — `NearDuplicate::similarity` is an `f32`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncEvent {
    Started {
        peers: Vec<String>,
    },
    Progress {
        progress: SyncProgress,
        peer: String,
    },
    DocumentTransferred {
        document_id: DocumentId,
        bytes: u64,
    },
    Conflict {
        conflict: ConflictInfo,
    },
    /// A substantially-same document (minor edit) was detected between an
    /// incoming document under a new id and an existing local document, via the
    /// search layer's MinHash/LSH near-duplicate index. Surfaced so the UI can
    /// propose the two as *related versions* rather than unrelated files.
    NearDuplicate {
        document_id: DocumentId,
        related_to: DocumentId,
        similarity: f32,
    },
    Finished {
        results: Vec<ConflictResolution>,
    },
}

/// Deterministically derive a fork id from an original document id and the
/// remote content hash, so both peers independently compute the *same* id.
fn fork_id(original: &str, remote_checksum: &str) -> String {
    let d: String = remote_checksum.chars().take(8).collect();
    format!("{original}.conflict.{d}")
}

/// Choose the winning side of a conflict, independent of which peer runs the
/// comparison. Returns `true` when the *remote* copy is preferred.
fn remote_preferred(
    strategy: ResolutionStrategy,
    local: &ManifestEntry,
    remote: &ManifestEntry,
) -> bool {
    match strategy {
        ResolutionStrategy::RemoteWins => true,
        ResolutionStrategy::LocalWins => false,
        ResolutionStrategy::Newest | ResolutionStrategy::Fork => {
            (remote.updated_at_ms, &remote.checksum_sha256)
                > (local.updated_at_ms, &local.checksum_sha256)
        }
    }
}

/// Build the local manifest (one entry per document) from the store.
fn local_manifest<S: SyncStore>(store: &S) -> Result<BTreeMap<String, ManifestEntry>, SyncError> {
    let mut out = BTreeMap::new();
    for doc in store.list()? {
        out.insert(doc.id.clone(), ManifestEntry::from(&doc));
    }
    Ok(out)
}

/// Advertise (push) a single document to all connected peers. In practice this
/// is a focused manifest exchange for one document: the peer replies with the
/// content it still needs, which we then send.
pub(crate) fn push<S: SyncStore>(
    engine: &mut SyncEngineImpl<S>,
    doc_id: &DocumentId,
) -> Result<(), SyncError> {
    let doc = engine
        .store()
        .document(doc_id)?
        .ok_or_else(|| SyncError::NotFound(doc_id.clone()))?;
    let bytes = engine
        .store()
        .read_bytes(doc_id)?
        .ok_or_else(|| SyncError::NotFound(doc_id.clone()))?;
    let payload = DocumentPayload {
        manifest: ManifestEntry::from(&doc),
        bytes,
    };

    let mut peers: Vec<(PeerId, std::sync::Arc<dyn PeerTransport>)> = Vec::new();
    for t in engine.transports() {
        for p in t.peers() {
            peers.push((p, t.clone()));
        }
    }

    for (peer, transport) in &peers {
        // Push = offer the document to the peer, which stores it if it does not
        // already hold the same content (see `serve`'s PushDocument arm).
        transport.request(
            peer,
            SyncRequest::PushDocument {
                payload: payload.clone(),
            },
        )?;
    }

    engine.emit(crate::sync::SyncEvent::DocumentTransferred {
        document_id: doc_id.clone(),
        bytes: payload.bytes.len() as u64,
    });
    Ok(())
}

/// Pull remote changes from all connected peers and reconcile them.
pub(crate) fn pull<S: SyncStore>(
    engine: &mut SyncEngineImpl<S>,
) -> Result<Vec<ConflictResolution>, SyncError> {
    let strategy = *engine.strategy();
    let mut results = Vec::new();

    let manifest = local_manifest(engine.store())?;

    // Seed the shared near-duplicate index with the local library so incoming
    // documents can be matched against it (idempotent: repeated indexing just
    // replaces the same signatures).
    if let Some(ndi) = engine.near_dup() {
        let mut idx = ndi.lock().unwrap();
        for doc in engine.store().list().unwrap_or_default() {
            if let Ok(Some(bytes)) = engine.store().read_bytes(&doc.id) {
                idx.index(&doc.id, &String::from_utf8_lossy(&bytes));
            }
        }
    }

    // Snapshot (peer id, transport handle) pairs so we can mutate `engine`
    // while still issuing requests through the (cheaply cloned) handles.
    let mut pairs: Vec<(PeerId, std::sync::Arc<dyn PeerTransport>)> = Vec::new();
    for t in engine.transports() {
        for p in t.peers() {
            pairs.push((p, t.clone()));
        }
    }

    for (peer, transport) in &pairs {
        engine.emit(crate::sync::SyncEvent::Progress {
            progress: SyncProgress::ExchangingManifests,
            peer: peer.0.clone(),
        });

        let entries: Vec<ManifestEntry> = manifest.values().cloned().collect();
        let resp = transport.request(peer, SyncRequest::SendManifest { entries })?;
        let SyncResponse::Manifest { missing } = resp else {
            return Err(SyncError::Other("unexpected manifest response".into()));
        };

        // Partition: documents we lack entirely vs. documents we hold differently
        // (i.e. conflicts).
        let mut new_docs: Vec<ManifestEntry> = Vec::new();
        let mut conflicts: Vec<(ManifestEntry, ManifestEntry)> = Vec::new(); // (local, remote)
        for remote in missing {
            match manifest.get(&remote.id) {
                None => new_docs.push(remote),
                Some(local) => {
                    if local.checksum_sha256 != remote.checksum_sha256 {
                        conflicts.push((local.clone(), remote));
                    }
                }
            }
        }

        // Transfer missing content.
        if !new_docs.is_empty() {
            engine.emit(crate::sync::SyncEvent::Progress {
                progress: SyncProgress::TransferringContent,
                peer: peer.0.clone(),
            });
            let hashes: BTreeSet<String> =
                new_docs.iter().map(|m| m.checksum_sha256.clone()).collect();
            let resp = transport.request(
                peer,
                SyncRequest::FetchBlobs {
                    checksums: hashes.into_iter().collect(),
                },
            )?;
            if let SyncResponse::Blobs { blobs } = resp {
                for b in blobs {
                    apply_blob(engine, b);
                }
            }
        }

        // Reconcile conflicts.
        if !conflicts.is_empty() {
            engine.emit(crate::sync::SyncEvent::Progress {
                progress: SyncProgress::Reconciling,
                peer: peer.0.clone(),
            });

            let conflict_hashes: BTreeSet<String> = conflicts
                .iter()
                .map(|(_, remote)| remote.checksum_sha256.clone())
                .collect();
            let blobs = transport
                .request(
                    peer,
                    SyncRequest::FetchBlobs {
                        checksums: conflict_hashes.into_iter().collect(),
                    },
                )?
                .into_blobs();

            for (local, remote) in conflicts {
                let payload = blobs.iter().find(|b| b.manifest.id == remote.id).cloned();
                let resolution = resolve_conflict(engine, strategy, &local, &remote, payload);
                results.push(resolution);
            }
        }
    }

    engine.emit(crate::sync::SyncEvent::Progress {
        progress: SyncProgress::Done,
        peer: String::new(),
    });
    engine.emit(crate::sync::SyncEvent::Finished {
        results: results.clone(),
    });

    Ok(results)
}

/// Store an incoming blob payload, preserving metadata, tags, and parent.
fn apply_blob<S: SyncStore>(engine: &mut SyncEngineImpl<S>, payload: DocumentPayload) {
    let bytes = payload.bytes.len() as u64;
    let doc = payload.manifest.to_document(HashMap::new());

    // Before filing this as a brand-new document, ask the shared near-duplicate
    // index whether its content is substantially the same as an existing local
    // document (under a different id). If so, propose them as related versions.
    propose_near_duplicate(engine, &doc.id, &payload.bytes);

    if engine.store_mut().put(doc.clone(), payload.bytes).is_ok() {
        engine.emit(crate::sync::SyncEvent::DocumentTransferred {
            document_id: doc.id,
            bytes,
        });
    }
}

/// Consult the search layer's near-duplicate index and, when an incoming
/// document is substantially the same as a locally known document under a
/// different id, emit a [`SyncEvent::NearDuplicate`] proposal.
fn propose_near_duplicate<S: SyncStore>(engine: &SyncEngineImpl<S>, id: &str, bytes: &[u8]) {
    let Some(ndi) = engine.near_dup() else {
        return;
    };
    let threshold = engine.near_dup_threshold();
    let text = String::from_utf8_lossy(bytes);
    let matches = ndi.lock().unwrap().query(&text, threshold);

    let best = matches
        .into_iter()
        .filter(|m| m.document_id != id)
        .max_by(|a, b| {
            a.similarity
                .partial_cmp(&b.similarity)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

    if let Some(best) = best {
        engine.emit(crate::sync::SyncEvent::NearDuplicate {
            document_id: id.to_owned(),
            related_to: best.document_id,
            similarity: best.similarity,
        });
    }
}

/// Resolve a single detected conflict deterministically and record it.
fn resolve_conflict<S: SyncStore>(
    engine: &mut SyncEngineImpl<S>,
    strategy: ResolutionStrategy,
    local: &ManifestEntry,
    remote: &ManifestEntry,
    remote_payload: Option<DocumentPayload>,
) -> ConflictResolution {
    let preferred_remote = remote_preferred(strategy, local, remote);

    if strategy == ResolutionStrategy::Fork {
        let mut forked_id = None;
        if let Some(payload) = remote_payload {
            let fid = fork_id(&remote.id, &remote.checksum_sha256);
            let mut forked_doc = payload.manifest.to_document(HashMap::new());
            forked_doc.id = fid.clone();
            // Preserve the remote's original tags and re-parent the fork under
            // the originating document so both versions sit side-by-side.
            if engine.store_mut().put(forked_doc, payload.bytes).is_ok() {
                let _ = engine.store_mut().link(HierarchyLink {
                    parent_id: remote.id.clone(),
                    child_id: fid.clone(),
                    position: 0,
                });
                forked_id = Some(fid);
            }
        }
        let info = ConflictInfo {
            document_id: remote.id.clone(),
            kind: ConflictKind::ContentDiverged,
            local_checksum: local.checksum_sha256.clone(),
            remote_checksum: remote.checksum_sha256.clone(),
            local_updated_at_ms: local.updated_at_ms,
            remote_updated_at_ms: remote.updated_at_ms,
            forked_document_id: forked_id.clone(),
            winner: "fork".to_owned(),
        };
        engine.record_conflict(info.clone());
        engine.emit(crate::sync::SyncEvent::Conflict { conflict: info });
        ConflictResolution::Forked(forked_id.unwrap_or_else(|| remote.id.clone()))
    } else if preferred_remote {
        if let Some(payload) = remote_payload {
            let doc = payload.manifest.to_document(HashMap::new());
            let _ = engine.store_mut().put(doc, payload.bytes);
        }
        let info = ConflictInfo {
            document_id: remote.id.clone(),
            kind: ConflictKind::ContentDiverged,
            local_checksum: local.checksum_sha256.clone(),
            remote_checksum: remote.checksum_sha256.clone(),
            local_updated_at_ms: local.updated_at_ms,
            remote_updated_at_ms: remote.updated_at_ms,
            forked_document_id: None,
            winner: "remote".to_owned(),
        };
        engine.record_conflict(info.clone());
        engine.emit(crate::sync::SyncEvent::Conflict { conflict: info });
        ConflictResolution::RemoteWon
    } else {
        let info = ConflictInfo {
            document_id: remote.id.clone(),
            kind: ConflictKind::ContentDiverged,
            local_checksum: local.checksum_sha256.clone(),
            remote_checksum: remote.checksum_sha256.clone(),
            local_updated_at_ms: local.updated_at_ms,
            remote_updated_at_ms: remote.updated_at_ms,
            forked_document_id: None,
            winner: "local".to_owned(),
        };
        engine.record_conflict(info.clone());
        engine.emit(crate::sync::SyncEvent::Conflict { conflict: info });
        ConflictResolution::LocalWon
    }
}

impl SyncResponse {
    fn into_blobs(self) -> Vec<DocumentPayload> {
        match self {
            SyncResponse::Blobs { blobs } => blobs,
            _ => Vec::new(),
        }
    }
}
