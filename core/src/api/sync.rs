//! Flutter bridge surface for P2P file sync and conflict resolution.
//!
//! Thin facade over [`crate::sync::SyncEngineImpl`]. Like the `p2p` facade, the
//! engine is a process-wide singleton. Its durable backend is an in-memory
//! [`crate::sync::testing::InMemoryStore`] for now (a stand-in until the `redb`
//! [`crate::storage::DocumentStore`] is implemented); the sync *protocol* itself
//! (manifest comparison, content transfer, deterministic conflict resolution) is
//! fully implemented and transport-agnostic.
//!
//! Progress and conflict events are surfaced to Dart over the [`sync_events`]
//! stream; conflicts awaiting manual resolution can also be read via
//! [`sync_conflicts`].
//!
//! The Dart-facing event/result types are plain structs (mirroring the `p2p`
//! facade's convention) so the generated bindings stay simple Dart classes -
//! no Freezed sealed unions are required.

use std::sync::{Arc, Mutex, OnceLock};

use serde::{Deserialize, Serialize};

use crate::sync::testing::InMemoryStore;
use crate::sync::{SyncEngine, SyncEngineImpl};

/// The concrete engine type used by the process-wide singleton.
type SharedStore = Arc<Mutex<InMemoryStore>>;
type Engine = SyncEngineImpl<SharedStore>;

/// Process-wide sync engine, protected by a mutex (its protocol methods take
/// `&mut self`).
static ENGINE: OnceLock<Result<Mutex<Engine>, String>> = OnceLock::new();

fn engine() -> &'static Result<Mutex<Engine>, String> {
    ENGINE.get_or_init(|| {
        let store: SharedStore = Arc::new(Mutex::new(InMemoryStore::new()));
        Ok(Mutex::new(SyncEngineImpl::new(store)))
    })
}

/// The kind of a sync event (enum of unit variants; no Freezed needed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncEventKindDto {
    Started,
    Progress,
    DocumentTransferred,
    Conflict,
    Finished,
}

/// Coarse-grained sync phase reported in progress events.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncPhaseDto {
    ExchangingManifests,
    TransferringContent,
    Reconciling,
    Done,
}

/// The kind of a conflict (plain enum; no Freezed needed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncConflictKindDto {
    ContentDiverged,
    MetadataDiverged,
}

/// A single document-conflict outcome, as a plain struct over the bridge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncResolutionDto {
    /// `"merged"`, `"remoteWon"`, `"localWon"`, or `"forked"`.
    pub kind: String,
    /// For `"forked"`, the id of the created fork.
    pub document_id: Option<String>,
}

/// A record of a conflict awaiting manual resolution, as a plain struct.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncConflictDto {
    pub document_id: String,
    pub kind: SyncConflictKindDto,
    pub local_checksum: String,
    pub remote_checksum: String,
    pub local_updated_at_ms: i64,
    pub remote_updated_at_ms: i64,
    pub forked_document_id: Option<String>,
    /// `"local"`, `"remote"`, or `"fork"`.
    pub winner: String,
}

/// A sync event delivered to Dart over the [`sync_events`] stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncEventDto {
    pub kind: SyncEventKindDto,
    pub peer_id: String,
    /// Populated for [`SyncEventKindDto::Progress`].
    pub phase: Option<SyncPhaseDto>,
    /// Populated for [`SyncEventKindDto::DocumentTransferred`].
    pub document_id: Option<String>,
    pub bytes: Option<u64>,
    /// Populated for [`SyncEventKindDto::Conflict`].
    pub conflict: Option<SyncConflictDto>,
    /// Populated for [`SyncEventKindDto::Finished`].
    pub results: Vec<SyncResolutionDto>,
}

fn to_resolution_dto(r: &crate::sync::ConflictResolution) -> SyncResolutionDto {
    match r {
        crate::sync::ConflictResolution::Merged => SyncResolutionDto {
            kind: "merged".to_owned(),
            document_id: None,
        },
        crate::sync::ConflictResolution::RemoteWon => SyncResolutionDto {
            kind: "remoteWon".to_owned(),
            document_id: None,
        },
        crate::sync::ConflictResolution::LocalWon => SyncResolutionDto {
            kind: "localWon".to_owned(),
            document_id: None,
        },
        crate::sync::ConflictResolution::Forked(id) => SyncResolutionDto {
            kind: "forked".to_owned(),
            document_id: Some(id.clone()),
        },
    }
}

fn to_phase_dto(p: crate::sync::SyncProgress) -> SyncPhaseDto {
    match p {
        crate::sync::SyncProgress::ExchangingManifests => SyncPhaseDto::ExchangingManifests,
        crate::sync::SyncProgress::TransferringContent => SyncPhaseDto::TransferringContent,
        crate::sync::SyncProgress::Reconciling => SyncPhaseDto::Reconciling,
        crate::sync::SyncProgress::Done => SyncPhaseDto::Done,
    }
}

fn to_conflict_kind_dto(k: crate::sync::ConflictKind) -> SyncConflictKindDto {
    match k {
        crate::sync::ConflictKind::ContentDiverged => SyncConflictKindDto::ContentDiverged,
        crate::sync::ConflictKind::MetadataDiverged => SyncConflictKindDto::MetadataDiverged,
    }
}

fn to_conflict_dto(c: &crate::sync::ConflictInfo) -> SyncConflictDto {
    SyncConflictDto {
        document_id: c.document_id.clone(),
        kind: to_conflict_kind_dto(c.kind),
        local_checksum: c.local_checksum.clone(),
        remote_checksum: c.remote_checksum.clone(),
        local_updated_at_ms: c.local_updated_at_ms,
        remote_updated_at_ms: c.remote_updated_at_ms,
        forked_document_id: c.forked_document_id.clone(),
        winner: c.winner.clone(),
    }
}

fn to_event_dto(e: crate::sync::SyncEvent) -> SyncEventDto {
    match e {
        crate::sync::SyncEvent::Started { peers } => SyncEventDto {
            kind: SyncEventKindDto::Started,
            peer_id: peers.join(","),
            phase: None,
            document_id: None,
            bytes: None,
            conflict: None,
            results: vec![],
        },
        crate::sync::SyncEvent::Progress { progress, peer } => SyncEventDto {
            kind: SyncEventKindDto::Progress,
            peer_id: peer,
            phase: Some(to_phase_dto(progress)),
            document_id: None,
            bytes: None,
            conflict: None,
            results: vec![],
        },
        crate::sync::SyncEvent::DocumentTransferred { document_id, bytes } => SyncEventDto {
            kind: SyncEventKindDto::DocumentTransferred,
            peer_id: String::new(),
            phase: None,
            document_id: Some(document_id),
            bytes: Some(bytes),
            conflict: None,
            results: vec![],
        },
        crate::sync::SyncEvent::Conflict { conflict } => SyncEventDto {
            kind: SyncEventKindDto::Conflict,
            peer_id: String::new(),
            phase: None,
            document_id: None,
            bytes: None,
            conflict: Some(to_conflict_dto(&conflict)),
            results: vec![],
        },
        crate::sync::SyncEvent::Finished { results } => SyncEventDto {
            kind: SyncEventKindDto::Finished,
            peer_id: String::new(),
            phase: None,
            document_id: None,
            bytes: None,
            conflict: None,
            results: results.iter().map(to_resolution_dto).collect(),
        },
    }
}

/// Start the sync engine and emit a `Started` event.
#[flutter_rust_bridge::frb(sync)]
pub fn sync_start() -> Result<(), String> {
    match engine() {
        Ok(e) => e.lock().unwrap().start().map_err(|e| e.to_string()),
        Err(e) => Err(e.clone()),
    }
}

/// The peer ids the engine is currently connected to.
#[flutter_rust_bridge::frb(sync)]
pub fn sync_peers() -> Vec<String> {
    match engine() {
        Ok(e) => e
            .lock()
            .unwrap()
            .peers()
            .iter()
            .map(|p| p.0.clone())
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// Register a peer the engine should try to sync with.
#[flutter_rust_bridge::frb(sync)]
pub fn sync_connect(peer_id: String) -> Result<(), String> {
    match engine() {
        Ok(e) => e
            .lock()
            .unwrap()
            .connect(&crate::sync::PeerId(peer_id))
            .map_err(|e| e.to_string()),
        Err(e) => Err(e.clone()),
    }
}

/// Replicate a single document (and its bytes) to all connected peers.
#[flutter_rust_bridge::frb(sync)]
pub fn sync_push(document_id: String) -> Result<(), String> {
    match engine() {
        Ok(e) => e
            .lock()
            .unwrap()
            .push(&document_id)
            .map_err(|e| e.to_string()),
        Err(e) => Err(e.clone()),
    }
}

/// Pull remote changes from all connected peers and reconcile them. Returns the
/// per-document conflict resolutions from this round.
#[flutter_rust_bridge::frb(sync)]
pub fn sync_pull() -> Result<Vec<SyncResolutionDto>, String> {
    match engine() {
        Ok(e) => e
            .lock()
            .unwrap()
            .pull()
            .map(|rs| rs.iter().map(to_resolution_dto).collect())
            .map_err(|e| e.to_string()),
        Err(e) => Err(e.clone()),
    }
}

/// Conflicts currently awaiting manual resolution.
#[flutter_rust_bridge::frb(sync)]
pub fn sync_conflicts() -> Vec<SyncConflictDto> {
    match engine() {
        Ok(e) => e
            .lock()
            .unwrap()
            .conflicts()
            .iter()
            .map(to_conflict_dto)
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// Open a Dart `Stream` of sync events (progress, transfers, conflicts, done).
///
/// The returned stream stays open until the Dart side closes it, receiving one
/// [`SyncEventDto`] per engine event.
#[flutter_rust_bridge::frb]
pub fn sync_events(sink: crate::frb_generated::StreamSink<SyncEventDto>) {
    let rx = match engine() {
        Ok(e) => match e.lock().unwrap().subscribe() {
            Some(rx) => rx,
            None => {
                let _ = sink.add_error("sync event stream already subscribed".to_owned());
                return;
            }
        },
        Err(e) => {
            let _ = sink.add_error(e.clone());
            return;
        }
    };

    std::thread::spawn(move || {
        while let Ok(event) = rx.recv() {
            if sink.add(to_event_dto(event)).is_err() {
                break;
            }
        }
    });
}
