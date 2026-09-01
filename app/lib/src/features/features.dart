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
export 'sync.dart';
