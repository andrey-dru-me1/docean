/// Full-text and semantic search (mirrors `core::search::SearchIndex`).
library;

/// A single search result.
class SearchHit {
  const SearchHit({
    required this.documentId,
    required this.score,
    this.snippet,
  });

  final String documentId;
  final double score;
  final String? snippet;
}

/// Query kinds supported by the search service.
sealed class Query {
  const Query();
}

class TextQuery extends Query {
  const TextQuery(this.text);

  final String text;
}

class SemanticQuery extends Query {
  const SemanticQuery(this.text);

  final String text;
}

class HybridQuery extends Query {
  const HybridQuery({required this.text, required this.semantic});

  final String text;
  final String semantic;
}

/// Search service interface (full-text + semantic + hybrid).
abstract interface class SearchIndex {
  Future<void> index(String documentId, String text);
  Future<void> remove(String documentId);
  Future<List<SearchHit>> search(Query query, {int limit = 20});
}
