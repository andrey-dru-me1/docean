/// Public Dart interface surface for the feature modules.
///
/// These interfaces mirror the Rust `core` module boundaries. They are the
/// contracts that the FRB-backed implementations (and the UI) will use once the
/// modules are implemented.
library;

export 'domain.dart';
export 'storage.dart';
export 'taxonomy.dart';
export 'search.dart';
export 'ai.dart';
export 'auto_org.dart';
export 'assistant.dart';
export 'p2p.dart';
// Both `p2p` and `sync` define top-level `connect` and `events` functions (they
// mirror the Rust `net` vs `sync` modules). Hide the colliding names from
// `sync`'s barrel export so importing `features.dart` stays unambiguous: the
// P2P variants dial/discover peers, while the sync variants live on `SyncClient`.
export 'sync.dart' hide connect, events;
