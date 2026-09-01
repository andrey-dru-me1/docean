//! Wire-facing data types for peer discovery and connection tracking.
//!
//! These types are plain serde data (no plugin types) so they can be serialized
//! across the flutter_rust_bridge boundary unchanged.

use serde::{Deserialize, Serialize};

/// A device identity as a libp2p `PeerId`, encoded as its base58 multihash
/// string (e.g. `12D3KooW...`). Stable per device because it derives from the
/// persistent keypair.
pub type PeerIdString = String;

/// The connection state of a given peer as observed by the local node.
///
/// Mirrored in Dart so the UI can render connection status without bridging a
/// richer (non-serializable) libp2p object.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConnectionState {
    /// A peer was discovered (e.g. via mDNS) but no connection is established
    /// yet, or a previously open connection has closed.
    Disconnected,
    /// A transport connection to the peer is currently established.
    Connected,
}

/// A single multiaddr of a discovered peer, in its string form.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeAddress {
    /// Human-readable multiaddr string, e.g. `/ip4/192.168.1.10/udp/1234/quic-v1`.
    pub addr: String,
}

/// A discovered (or previously connected) remote device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Peer {
    /// Stable device identity (base58 libp2p `PeerId`).
    pub id: PeerIdString,
    /// Known listen addresses for this peer (discovered via mDNS / identify).
    pub addresses: Vec<NodeAddress>,
    /// Current connection state relative to the local node.
    pub state: ConnectionState,
}
