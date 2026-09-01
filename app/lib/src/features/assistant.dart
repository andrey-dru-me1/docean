/// Chat assistant with document references (mirrors `core::assistant::Assistant`).
///
/// Retrieval-augmented chat over the local library: combines search (retrieval)
/// with an AI provider (generation) and returns cited document references.
library;

class DocumentRef {
  const DocumentRef({required this.documentId, required this.excerpt});

  final String documentId;
  final String excerpt;
}

class AssistantReply {
  const AssistantReply({required this.answer, this.references = const []});

  final String answer;
  final List<DocumentRef> references;
}

/// Chat assistant interface.
abstract interface class Assistant {
  Future<AssistantReply> ask(String question);
}
