/// Peer-to-peer file sync with conflict resolution (mirrors `core::sync::SyncEngine`).
library;

class PeerId {
  const PeerId(this.value);

  final String value;
}

/// Outcome of reconciling a remote change with local state.
sealed class ConflictResolution {
  const ConflictResolution();
}

class Merged extends ConflictResolution {
  const Merged();
}

class RemoteWon extends ConflictResolution {
  const RemoteWon();
}

class LocalWon extends ConflictResolution {
  const LocalWon();
}

class Forked extends ConflictResolution {
  const Forked(this.documentId);

  final String documentId;
}

/// P2P sync engine interface.
abstract interface class SyncEngine {
  Future<void> start();

  List<PeerId> peers();

  Future<void> connect(PeerId peer);

  Future<void> push(String documentId);

  Future<List<ConflictResolution>> pull();
}
