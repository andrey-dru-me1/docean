/// Peer-to-peer file sync with conflict resolution (mirrors `core::sync`).
///
/// Thin, typed facade over the generated [`sync`] bindings. Use [`SyncClient`]
/// or the top-level functions ([`start`], [`peers`], [`connect`], [`push`],
/// [`pull`], [`conflicts`], [`events`]) from Dart to drive reconciliation and
/// observe progress and conflict events.
library;

import '../rust/api/sync.dart' as bridge;
import '../rust/api/sync.dart'
    show
        SyncConflictDto,
        SyncConflictKindDto,
        SyncEventDto,
        SyncEventKindDto,
        SyncPhaseDto,
        SyncResolutionDto;

export '../rust/api/sync.dart'
    show
        SyncConflictDto,
        SyncConflictKindDto,
        SyncEventDto,
        SyncEventKindDto,
        SyncPhaseDto,
        SyncResolutionDto;

/// A device participating in sync.
class PeerId {
  const PeerId(this.value);

  final String value;
}

/// Start the sync engine.
void start() => bridge.syncStart();

/// The peer ids the engine is currently connected to.
List<String> peers() => bridge.syncPeers();

/// Register a peer the engine should try to sync with.
void connect(String peerId) => bridge.syncConnect(peerId: peerId);

/// Replicate a single document (and its bytes) to all connected peers.
void push(String documentId) => bridge.syncPush(documentId: documentId);

/// Pull remote changes and reconcile; returns per-document conflict outcomes.
List<SyncResolutionDto> pull() => bridge.syncPull();

/// Conflicts currently awaiting manual resolution.
List<SyncConflictDto> conflicts() => bridge.syncConflicts();

/// A `Stream` of sync events (progress, transfers, conflicts, done).
Stream<SyncEventDto> events() => bridge.syncEvents();

/// Object-oriented facade over the sync bridge surface.
class SyncClient {
  const SyncClient();

  void start() => bridge.syncStart();

  List<String> peers() => bridge.syncPeers();

  void connect(String peerId) => bridge.syncConnect(peerId: peerId);

  void push(String documentId) => bridge.syncPush(documentId: documentId);

  List<SyncResolutionDto> pull() => bridge.syncPull();

  List<SyncConflictDto> conflicts() => bridge.syncConflicts();

  Stream<SyncEventDto> events() => bridge.syncEvents();
}
