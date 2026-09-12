/// A thin, typed facade over the generated search bindings, mirroring how
/// [`AiService`](ai.dart) wraps the AI bridge surface.
///
/// The facade isolates the UI from the generated top-level functions and is
/// deliberately an interface so tests can inject a fake implementation without
/// loading the native library.
library;

import '../rust/api/search.dart' as bridge;
import '../rust/api/search.dart' show SearchHitDto;

export '../rust/api/search.dart'
    show HighlightSpan, SearchHitDto, SearchMode, SearchRequestDto;

/// The search service contract. Implement with the Rust bridge, fakes in tests.
abstract interface class SearchService {
  /// Run a search; results carry snippets, highlight spans, and tags.
  List<SearchHitDto> query(
    String text, {
    required bridge.SearchMode mode,
    List<String> tags = const [],
    int? limit,
  });

  /// Index a document's text so it becomes searchable.
  void indexDocument(String documentId, String text);

  /// Register a document's tags for result filtering.
  void setMetadata(String documentId, {List<String> tags = const []});

  /// Drop a document from all search indexes.
  void removeDocument(String documentId);
}

/// The default implementation backed by the Rust bridge.
class BridgeSearchService implements SearchService {
  const BridgeSearchService();

  @override
  List<SearchHitDto> query(
    String text, {
    required bridge.SearchMode mode,
    List<String> tags = const [],
    int? limit,
  }) => bridge.searchQuery(
    req: bridge.SearchRequestDto(
      text: text,
      mode: mode,
      tags: tags,
      limit: limit,
    ),
  );

  @override
  void indexDocument(String documentId, String text) =>
      bridge.searchIndexDocument(documentId: documentId, text: text);

  @override
  void setMetadata(String documentId, {List<String> tags = const []}) =>
      bridge.searchSetMetadata(documentId: documentId, tags: tags);

  @override
  void removeDocument(String documentId) =>
      bridge.searchRemoveDocument(documentId: documentId);
}
