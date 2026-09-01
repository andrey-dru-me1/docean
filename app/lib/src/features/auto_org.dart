/// AI auto-organization pipeline (mirrors `core::auto_org::AutoOrganizer`).
///
/// The pipeline consumes AI output as plain [Suggestion] data, keeping it
/// decoupled from any specific provider.
library;

enum Stage { ingested, extracted, classified, applied, failed }

class Suggestion {
  const Suggestion({
    this.suggestedTags = const [],
    this.suggestedParent,
    this.confidence = 0.0,
    this.rationale,
  });

  final List<String> suggestedTags;
  final String? suggestedParent;
  final double confidence;
  final String? rationale;
}

class PipelineJob {
  const PipelineJob({
    required this.documentId,
    required this.stage,
    this.attempt = 0,
  });

  final String documentId;
  final Stage stage;
  final int attempt;
}

/// Auto-organization pipeline interface.
abstract interface class AutoOrganizer {
  Future<void> enqueue(String documentId);

  PipelineJob? next();

  Future<void> process(PipelineJob job, Suggestion suggestion);
}
