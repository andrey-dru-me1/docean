//! Flutter bridge surface for peer-to-peer discovery and connection management.
//!
//! Thin, blocking facade over [`crate::net::P2pEngine`]. The engine is a lazy
//! process-wide singleton: the first call initializes the device identity and
//! starts the swarm on a background task; subsequent calls read the shared
//! state. Discovery (mDNS) and connection tracking happen continuously, and
//! changes are surfaced to Dart via [`p2p_events`]'s stream.

use std::sync::{Arc, OnceLock};

use serde::{Deserialize, Serialize};

use crate::net::{self, DeviceIdentity, P2pEngine};

/// Connection state of a peer, relative to this device.
///
/// Re-exported from `crate::net` so Dart sees a single shared type.
pub use crate::net::models::ConnectionState;

/// A discovered peer / device and its current connection state (Dart DTO).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerInfo {
    pub id: String,
    pub addresses: Vec<String>,
    pub state: ConnectionState,
}

/// The kind of connectivity change an event describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PeerEventKind {
    Discovered,
    Expired,
    Connected,
    Disconnected,
}

/// A connectivity change pushed to Dart over the [`p2p_events`] stream.
///
/// Modeled as a plain struct (not a data-carrying enum) so the generated Dart
/// binding is a simple class rather than a freezed sealed union.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerEvent {
    pub kind: PeerEventKind,
    pub peer_id: String,
    /// Listen addresses for the peer; populated only for [`PeerEventKind::Discovered`].
    pub addresses: Vec<String>,
}

/// Serialize the net models to the Dart DTOs.
fn to_dto(peer: &net::Peer) -> PeerInfo {
    PeerInfo {
        id: peer.id.clone(),
        addresses: peer.addresses.iter().map(|a| a.addr.clone()).collect(),
        state: match peer.state {
            net::ConnectionState::Connected => ConnectionState::Connected,
            net::ConnectionState::Disconnected => ConnectionState::Disconnected,
        },
    }
}

fn to_event_dto(event: net::EngineEvent) -> PeerEvent {
    match event {
        net::EngineEvent::Discovered { peer_id, addresses } => PeerEvent {
            kind: PeerEventKind::Discovered,
            peer_id,
            addresses,
        },
        net::EngineEvent::Expired { peer_id } => PeerEvent {
            kind: PeerEventKind::Expired,
            peer_id,
            addresses: Vec::new(),
        },
        net::EngineEvent::Connected { peer_id } => PeerEvent {
            kind: PeerEventKind::Connected,
            peer_id,
            addresses: Vec::new(),
        },
        net::EngineEvent::Disconnected { peer_id } => PeerEvent {
            kind: PeerEventKind::Disconnected,
            peer_id,
            addresses: Vec::new(),
        },
    }
}

/// Process-wide engine handle.
static ENGINE: OnceLock<Result<Arc<P2pEngine>, String>> = OnceLock::new();

/// Get (or lazily initialize) the engine, mapping init failures to a message.
fn engine() -> &'static Result<Arc<P2pEngine>, String> {
    ENGINE.get_or_init(|| {
        let dir = net::identity::default_identity_dir();
        let identity = DeviceIdentity::load_or_create(&dir).map_err(|e| e.to_string())?;
        let engine = P2pEngine::new(&identity).map_err(|e| e.to_string())?;
        Ok(Arc::new(engine))
    })
}

/// The local device's stable peer id (base58 libp2p `PeerId`).
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_local_peer_id() -> String {
    match engine() {
        Ok(e) => e.local_peer_id().to_owned(),
        Err(e) => format!("<unavailable: {e}>"),
    }
}

/// Snapshot of currently known peers and their connection state.
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_list_peers() -> Vec<PeerInfo> {
    match engine() {
        Ok(e) => e.list_peers().iter().map(|p| to_dto(p)).collect(),
        Err(_) => Vec::new(),
    }
}

/// Dial a peer by id and multiaddr.
#[flutter_rust_bridge::frb(sync)]
pub fn p2p_connect(peer_id: String, addr: String) -> Result<(), String> {
    match engine() {
        Ok(e) => e.connect(&peer_id, &addr).map_err(|e| e.to_string()),
        Err(e) => Err(e.clone()),
    }
}

/// Open a Dart `Stream` of peer events (discovery + connection state changes).
///
/// The returned stream stays open for the life of the subscription, receiving
/// one [`PeerEvent`] per connectivity change.
#[flutter_rust_bridge::frb]
pub fn p2p_events(sink: crate::frb_generated::StreamSink<PeerEvent>) {
    let engine = match engine() {
        Ok(e) => e.clone(),
        Err(e) => {
            let _ = sink.add_error(e.clone());
            return;
        }
    };
    let mut rx = engine.subscribe().subscribe();

    std::thread::spawn(move || {
        // Blocking receive: `broadcast::Receiver::recv()` is async; this thread
        // is dedicated to forwarding events, so block until the next one.
        while let Ok(event) = rx.blocking_recv() {
            let dto = to_event_dto(event);
            if sink.add(dto).is_err() {
                // The Dart side closed the stream; stop forwarding.
                break;
            }
        }
    });
}
