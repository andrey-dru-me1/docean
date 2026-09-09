//! Peer-to-peer networking: device discovery and connection management.
//!
//! **Boundary:** discover other devices running docean on the local network and
//! manage transport connections between them. This module is deliberately
//! narrower than [`crate::sync`]: it only addresses *How do devices find each
//! other and stay connected?* — the actual document replication (what to send
//! over those connections) lives in `sync` and is not implemented here yet.
//!
//! **Stack:**
//! * [`rust-libp2p`](https://crates.io/crates/libp2p) — peer identity,
//!   transports, and the event-driven [`Swarm`].
//! * mDNS ([`libp2p::mdns`]) — local-network peer discovery.
//! * TCP + QUIC transports, secured with Noise and multiplexed with Yamux.
//! * A persistent Ed25519 keypair gives the device a stable peer identity
//!   across launches (see [`identity`]).
//!
//! Everything here is transport-agnostic: production uses TCP/QUIC, tests use
//! libp2p's [`libp2p::core::transport::MemoryTransport`], which speaks the
//! `/memory/N` multiaddress scheme and requires no OS sockets.

mod behaviour;
mod engine;
pub mod identity;
pub mod models;

pub use engine::{Command, EngineEvent, P2pEngine, PeerEventSender};
pub use identity::{DeviceIdentity, IdentityError};
pub use models::{ConnectionState, NodeAddress, Peer, PeerIdString};
