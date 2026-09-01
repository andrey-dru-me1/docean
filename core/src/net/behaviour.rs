//! The composed libp2p [`NetworkBehaviour`] used by the [`crate::net::P2pEngine`].
//!
//! Combines:
//! * [`libp2p::mdns`] — local-network discovery,
//! * [`libp2p::identify`] — learn a peer's protocol/version and its
//!   externally-reachable addresses,
//! * [`libp2p::ping`] — cheap keep-alive and liveness probing.
//!
//! We use libp2p's `NetworkBehaviour` derive macro to compose the three
//! sub-behaviours; the engine maps the generated [`BehaviourEvent`] and the
//! swarm-level connection events into the public [`crate::net::PeerEvent`]s.

use libp2p::identify;
use libp2p::mdns;
use libp2p::ping;
use libp2p::swarm::NetworkBehaviour;

/// The composed network behaviour.
#[derive(NetworkBehaviour)]
pub struct Behaviour {
    mdns: mdns::tokio::Behaviour,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
}

impl Behaviour {
    /// Build the behaviour for the given local identity.
    pub fn new(keypair: &libp2p::identity::Keypair) -> anyhow::Result<Self> {
        let peer_id = keypair.public().to_peer_id();
        let public_key = keypair.public();
        let mdns = mdns::tokio::Behaviour::new(mdns::Config::default(), peer_id)?;
        let identify = identify::Behaviour::new(
            identify::Config::new("/docer/1.0.0".into(), public_key)
                .with_agent_version(format!("docer-core/{}", env!("CARGO_PKG_VERSION"))),
        );
        let ping = ping::Behaviour::new(ping::Config::new());
        Ok(Self {
            mdns,
            identify,
            ping,
        })
    }
}
