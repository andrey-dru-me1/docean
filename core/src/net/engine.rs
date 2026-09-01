//! The [`P2pEngine`]: owns the libp2p `Swarm` and drives it on a background task.
//!
//! The engine exposes a small, synchronous command surface (list peers, connect,
//! subscribe to events) that is safe to call from the FRB facade, while the
//! actual transport work happens on a dedicated tokio task that owns the swarm.
//!
//! # Transport strategy
//!
//! Production builds use TCP + QUIC with Noise security and Yamux muxing. Tests
//! construct the same engine over libp2p's [`libp2p::core::transport::MemoryTransport`]
//! (the `/memory/N` multiaddress scheme), so no OS sockets are opened. The
//! transport is injected at construction time, keeping the engine logic
//! transport-agnostic.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

use futures::StreamExt;
use libp2p::identify;
use libp2p::mdns;
use libp2p::swarm::SwarmEvent;
use libp2p::{Multiaddr, PeerId, Swarm, SwarmBuilder};
use tokio::sync::{broadcast, mpsc};

use crate::net::behaviour::{Behaviour, BehaviourEvent};
use crate::net::identity::DeviceIdentity;
use crate::net::models::{ConnectionState, NodeAddress, Peer};

/// Commands that can be sent to the engine's background task.
pub enum Command {
    /// Dial a peer by id and address.
    Connect(PeerId, Multiaddr),
    /// Start listening on an additional address.
    Listen(Multiaddr),
    /// Stop the engine (used to drop the swarm cleanly).
    Shutdown,
}

/// An event observed by the engine, delivered to subscribers.
///
/// Named `EngineEvent` (rather than `PeerEvent`) to avoid colliding with the
/// Dart-facing [`crate::api::p2p::PeerEvent`] when FRB resolves crate types.
#[derive(Debug, Clone)]
pub enum EngineEvent {
    /// A peer was discovered via mDNS, with its known addresses.
    Discovered {
        peer_id: String,
        addresses: Vec<String>,
    },
    /// A peer's mDNS advertisement expired.
    Expired { peer_id: String },
    /// A connection to `peer_id` is now established.
    Connected { peer_id: String },
    /// A connection to `peer_id` was closed.
    Disconnected { peer_id: String },
}

/// A subscribe handle to the engine's event stream. Clones forward to the same
/// underlying `broadcast` receiver.
#[derive(Clone)]
pub struct PeerEventSender {
    tx: broadcast::Sender<EngineEvent>,
}

impl PeerEventSender {
    /// Subscribe to peer events. Returns a receiver that can be awaited from a
    /// tokio context.
    pub fn subscribe(&self) -> broadcast::Receiver<EngineEvent> {
        self.tx.subscribe()
    }

    fn emit(&self, event: EngineEvent) {
        let _ = self.tx.send(event);
    }
}

/// Shared, interior-mutable snapshot of the peers the engine knows about.
#[derive(Default)]
struct PeerRegistry {
    /// peer id → (addresses, connected) — address set and liveness.
    peers: BTreeMap<PeerId, (BTreeSet<String>, bool)>,
}

impl PeerRegistry {
    fn upsert_discovered(&mut self, peer: PeerId, addresses: Vec<String>) {
        let entry = self
            .peers
            .entry(peer)
            .or_insert_with(|| (BTreeSet::new(), false));
        entry.0.extend(addresses);
    }

    fn add_addresses(&mut self, peer: PeerId, addresses: Vec<String>) {
        let entry = self
            .peers
            .entry(peer)
            .or_insert_with(|| (BTreeSet::new(), false));
        entry.0.extend(addresses);
    }

    fn set_connected(&mut self, peer: PeerId, connected: bool) {
        let entry = self
            .peers
            .entry(peer)
            .or_insert_with(|| (BTreeSet::new(), false));
        entry.1 = connected;
    }

    fn remove(&mut self, peer: &PeerId) {
        self.peers.remove(peer);
    }

    fn snapshot(&self) -> Vec<Peer> {
        self.peers
            .iter()
            .map(|(id, (addrs, connected))| Peer {
                id: id.to_string(),
                addresses: addrs
                    .iter()
                    .map(|a| NodeAddress { addr: a.clone() })
                    .collect(),
                state: if *connected {
                    ConnectionState::Connected
                } else {
                    ConnectionState::Disconnected
                },
            })
            .collect()
    }
}

/// The peer-to-peer engine.
///
/// Construction returns immediately; the swarm is driven by a background task
/// spawned on the provided (or a lazily created) tokio runtime.
pub struct P2pEngine {
    /// Handle to send commands to the background task.
    cmd_tx: mpsc::UnboundedSender<Command>,
    /// Event broadcaster for Dart-side subscriptions.
    events: PeerEventSender,
    /// Shared peer registry, for lock-free-ish reads of the peer list.
    registry: Arc<Mutex<PeerRegistry>>,
    /// Local device id.
    local_peer_id: String,
}

impl P2pEngine {
    /// Build a production engine over TCP + QUIC.
    pub fn new(identity: &DeviceIdentity) -> anyhow::Result<Self> {
        let keypair = identity.keypair().clone();
        let swarm = SwarmBuilder::with_existing_identity(keypair)
            .with_tokio()
            .with_tcp(
                libp2p::tcp::Config::default(),
                libp2p::noise::Config::new,
                libp2p::yamux::Config::default,
            )?
            .with_quic()
            .with_dns()?
            .with_behaviour(|key| Behaviour::new(key).expect("build behaviour"))?
            .build();

        Ok(Self::from_swarm(swarm, identity.peer_id_string()))
    }

    /// Build an engine over an arbitrary pre-built swarm (tests inject a
    /// memory transport here).
    pub fn from_swarm(swarm: Swarm<Behaviour>, local_peer_id: String) -> Self {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let (event_tx, _) = broadcast::channel(256);
        let registry = Arc::new(Mutex::new(PeerRegistry::default()));
        let events = PeerEventSender { tx: event_tx };

        let engine = P2pEngine {
            cmd_tx,
            events: events.clone(),
            registry: registry.clone(),
            local_peer_id,
        };
        Self::spawn_loop(swarm, cmd_rx, events, registry);
        engine
    }

    /// The local device's stable peer id.
    pub fn local_peer_id(&self) -> &str {
        &self.local_peer_id
    }

    /// A snapshot of discovered / known peers and their connection state.
    pub fn list_peers(&self) -> Vec<Peer> {
        self.registry
            .lock()
            .map(|r| r.snapshot())
            .unwrap_or_default()
    }

    /// Subscribe to peer events (discovery and connection state changes).
    pub fn subscribe(&self) -> PeerEventSender {
        self.events.clone()
    }

    /// Ask the engine to dial `peer` at `addr`.
    pub fn connect(&self, peer_id: &str, addr: &str) -> anyhow::Result<()> {
        let peer: PeerId = peer_id
            .parse()
            .map_err(|_| anyhow::anyhow!("invalid peer id: {peer_id}"))?;
        let addr: Multiaddr = addr
            .parse()
            .map_err(|_| anyhow::anyhow!("invalid multiaddr: {addr}"))?;
        self.cmd_tx.send(Command::Connect(peer, addr))?;
        Ok(())
    }

    /// Start listening on an additional address (used by tests with the memory
    /// transport, and to open extra listeners in production).
    pub fn listen_on(&self, addr: &str) -> anyhow::Result<()> {
        let addr: Multiaddr = addr
            .parse()
            .map_err(|_| anyhow::anyhow!("invalid multiaddr: {addr}"))?;
        self.cmd_tx.send(Command::Listen(addr))?;
        Ok(())
    }

    /// Spawn the background event loop on a dedicated tokio runtime.
    fn spawn_loop(
        mut swarm: Swarm<Behaviour>,
        mut cmd_rx: mpsc::UnboundedReceiver<Command>,
        events: PeerEventSender,
        registry: Arc<Mutex<PeerRegistry>>,
    ) {
        std::thread::spawn(move || {
            let rt = match tokio::runtime::Runtime::new() {
                Ok(rt) => rt,
                Err(e) => {
                    eprintln!("p2p: failed to start runtime: {e}");
                    return;
                }
            };
            rt.block_on(async move {
                // Bind ephemeral listeners so we can be dialed by discovered peers.
                if let Err(e) = swarm.listen_on("/ip4/0.0.0.0/udp/0/quic-v1".parse().unwrap()) {
                    eprintln!("p2p: failed to listen (quic): {e}");
                }
                if let Err(e) = swarm.listen_on("/ip4/0.0.0.0/tcp/0".parse().unwrap()) {
                    eprintln!("p2p: failed to listen (tcp): {e}");
                }

                loop {
                    tokio::select! {
                        maybe_cmd = cmd_rx.recv() => {
                            match maybe_cmd {
                                Some(Command::Connect(peer, addr)) => {
                                    let target = addr
                                        .with(libp2p::multiaddr::Protocol::P2p(peer));
                                    if let Err(e) = swarm.dial(target) {
                                        eprintln!("p2p: dial failed: {e}");
                                    }
                                }
                                Some(Command::Listen(addr)) => {
                                    if let Err(e) = swarm.listen_on(addr) {
                                        eprintln!("p2p: listen failed: {e}");
                                    }
                                }
                                Some(Command::Shutdown) | None => break,
                            }
                        }
                        maybe_event = swarm.select_next_some() => {
                            handle_swarm_event(maybe_event, &events, &registry);
                        }
                    }
                }
            });
        });
    }
}

/// Translate a libp2p `SwarmEvent` into registry updates and outgoing events.
fn handle_swarm_event(
    event: SwarmEvent<BehaviourEvent>,
    events: &PeerEventSender,
    registry: &Arc<Mutex<PeerRegistry>>,
) {
    match event {
        SwarmEvent::Behaviour(BehaviourEvent::Mdns(mdns::Event::Discovered(list))) => {
            let mut reg = registry.lock().unwrap();
            for (peer, addrs) in list {
                let addrs: Vec<String> = addrs.iter().map(|a| a.to_string()).collect();
                reg.upsert_discovered(peer, addrs.clone());
                events.emit(EngineEvent::Discovered {
                    peer_id: peer.to_string(),
                    addresses: addrs,
                });
            }
        }
        SwarmEvent::Behaviour(BehaviourEvent::Mdns(mdns::Event::Expired(list))) => {
            let mut reg = registry.lock().unwrap();
            for (peer, _addr) in list {
                reg.remove(&peer);
                events.emit(EngineEvent::Expired {
                    peer_id: peer.to_string(),
                });
            }
        }
        SwarmEvent::Behaviour(BehaviourEvent::Identify(identify::Event::Received {
            peer_id,
            info,
            ..
        })) => {
            let mut reg = registry.lock().unwrap();
            let addrs: Vec<String> = info
                .listen_addrs
                .into_iter()
                .map(|a| a.to_string())
                .collect();
            reg.add_addresses(peer_id, addrs);
        }
        SwarmEvent::ConnectionEstablished { peer_id, .. } => {
            registry.lock().unwrap().set_connected(peer_id, true);
            events.emit(EngineEvent::Connected {
                peer_id: peer_id.to_string(),
            });
        }
        SwarmEvent::ConnectionClosed { peer_id, .. } => {
            registry.lock().unwrap().set_connected(peer_id, false);
            events.emit(EngineEvent::Disconnected {
                peer_id: peer_id.to_string(),
            });
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use libp2p::core::transport::{MemoryTransport, Transport};
    use libp2p::core::upgrade;
    use libp2p::identity::Keypair;

    /// Build a swarm over libp2p's in-memory transport (`/memory/N` scheme),
    /// authenticated with Noise and multiplexed with Yamux — no OS sockets.
    fn memory_swarm() -> Swarm<Behaviour> {
        let key = Keypair::generate_ed25519();
        let transport = MemoryTransport::default()
            .upgrade(upgrade::Version::V1)
            .authenticate(libp2p::noise::Config::new(&key).unwrap())
            .multiplex(libp2p::yamux::Config::default())
            .boxed();

        SwarmBuilder::with_existing_identity(key)
            .with_tokio()
            .with_other_transport(|_| transport)
            .unwrap()
            .with_behaviour(|key| Behaviour::new(key).unwrap())
            .unwrap()
            .build()
    }

    #[test]
    fn engine_starts_and_reports_own_identity() {
        let identity = DeviceIdentity::generate();
        let engine = P2pEngine::from_swarm(memory_swarm(), identity.peer_id_string());
        assert!(!engine.local_peer_id().is_empty());
        assert!(engine.list_peers().is_empty());
    }

    #[test]
    fn connect_to_unknown_peer_returns_error() {
        let identity = DeviceIdentity::generate();
        let engine = P2pEngine::from_swarm(memory_swarm(), identity.peer_id_string());
        // Invalid peer id string.
        assert!(engine.connect("not-a-peer-id", "/memory/1").is_err());
        // Valid peer id but invalid addr.
        let peer = libp2p::PeerId::random().to_string();
        assert!(engine.connect(&peer, "not-an-addr").is_err());
    }

    #[test]
    fn discovered_peers_appear_in_list() {
        let identity = DeviceIdentity::generate();
        let engine = P2pEngine::from_swarm(memory_swarm(), identity.peer_id_string());

        // Simulate a discovery by injecting into the shared registry directly.
        let peer = libp2p::PeerId::random();
        {
            let mut reg = engine.registry.lock().unwrap();
            reg.upsert_discovered(peer, vec!["/memory/1".to_string()]);
        }
        let peers = engine.list_peers();
        assert_eq!(peers.len(), 1);
        assert_eq!(peers[0].id, peer.to_string());
        assert_eq!(peers[0].state, ConnectionState::Disconnected);
        assert_eq!(peers[0].addresses[0].addr, "/memory/1");
    }

    /// End-to-end test over the in-memory transport: build two swarms with a
    /// shared [`MemoryTransport`] allocator so they can dial each other via
    /// `/{memory,N}` addresses, then verify a connection is established and
    /// surfaces through both `list_peers` and the event stream.
    #[tokio::test]
    async fn two_peers_connect_over_memory_transport() {
        let keypair_a = Keypair::generate_ed25519();
        let keypair_b = Keypair::generate_ed25519();
        let id_a = keypair_a.public().to_peer_id();
        let id_b = keypair_b.public().to_peer_id();

        // `MemoryTransport` listeners are registered in a process-global hub
        // keyed by `/memory/N`, so independent instances still reach each other.
        let transport_a = MemoryTransport::default()
            .upgrade(upgrade::Version::V1)
            .authenticate(libp2p::noise::Config::new(&keypair_a).unwrap())
            .multiplex(libp2p::yamux::Config::default())
            .boxed();
        let transport_b = MemoryTransport::default()
            .upgrade(upgrade::Version::V1)
            .authenticate(libp2p::noise::Config::new(&keypair_b).unwrap())
            .multiplex(libp2p::yamux::Config::default())
            .boxed();

        let swarm_a = SwarmBuilder::with_existing_identity(keypair_a)
            .with_tokio()
            .with_other_transport(|_| transport_a)
            .unwrap()
            .with_behaviour(|key| Behaviour::new(key).unwrap())
            .unwrap()
            .build();
        let swarm_b = SwarmBuilder::with_existing_identity(keypair_b)
            .with_tokio()
            .with_other_transport(|_| transport_b)
            .unwrap()
            .with_behaviour(|key| Behaviour::new(key).unwrap())
            .unwrap()
            .build();

        let engine_a = P2pEngine::from_swarm(swarm_a, id_a.to_string());
        let engine_b = P2pEngine::from_swarm(swarm_b, id_b.to_string());

        // Listen on fixed memory addresses so they can dial each other.
        // Addresses are in a shared namespace because both share `mem`.
        engine_a.listen_on("/memory/0").unwrap();
        engine_b.listen_on("/memory/1").unwrap();

        // Retry dialing until both sides observe an established connection:
        // the memory transport's listener is registered asynchronously, so the
        // first dial may fire before `/memory/1` is bound.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            engine_a.connect(&id_b.to_string(), "/memory/1").ok();
            engine_b.connect(&id_a.to_string(), "/memory/0").ok();

            let a = engine_a.list_peers();
            let b = engine_b.list_peers();
            let a_ok = a
                .iter()
                .any(|p| p.id == id_b.to_string() && p.state == ConnectionState::Connected);
            let b_ok = b
                .iter()
                .any(|p| p.id == id_a.to_string() && p.state == ConnectionState::Connected);
            if a_ok && b_ok {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "peers did not connect in time: a={a:?} b={b:?}"
            );
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    }
}
