/// Peer-to-peer device discovery and connection (mirrors `core::net`).
///
/// Thin, typed facade over the generated [`p2p`] bindings. Use [`P2pClient`] or
/// the top-level functions ([`localPeerId`], [`listPeers`], [`connect`],
/// [`events`]) from Dart to drive discovery and observe connection changes.
library;

import '../rust/api/p2p.dart' as bridge;
import '../rust/api/p2p.dart' show PeerEvent, PeerInfo;

export '../rust/api/p2p.dart' show PeerInfo, PeerEvent, PeerEventKind;
export '../rust/net/models.dart' show ConnectionState;

/// The local device's stable peer id.
String localPeerId() => bridge.p2PLocalPeerId();

/// Snapshot of currently known peers and their connection state.
List<PeerInfo> listPeers() => bridge.p2PListPeers();

/// Dial a peer by id and multiaddr.
void connect(String peerId, String addr) =>
    bridge.p2PConnect(peerId: peerId, addr: addr);

/// A `Stream` of peer events (discovery and connection state changes).
Stream<PeerEvent> events() => bridge.p2PEvents();

/// Object-oriented facade over the peer-to-peer bridge surface.
class P2pClient {
  const P2pClient();

  /// The local device's stable peer id.
  String get localPeerId => bridge.p2PLocalPeerId();

  /// Current peers and their connection state.
  List<PeerInfo> listPeers() => bridge.p2PListPeers();

  /// Establish a connection to [peerId] at [addr].
  void connect(String peerId, String addr) =>
      bridge.p2PConnect(peerId: peerId, addr: addr);

  /// Observe peer events (discovery and connection state changes).
  Stream<PeerEvent> events() => bridge.p2PEvents();
}
