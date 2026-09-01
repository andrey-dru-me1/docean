/// Automatic document organization pipeline.
///
/// **Classic-ML first:** the primary path is deterministic and offline; a
/// generative LLM filename tier is an optional upgrade gated on an AI provider.
///
/// Mirrors the data types in `core::auto_org`. The FRB-backed implementation
/// maps these to the generated `autoOrgOrganize` / `autoOrgGenerateFilename`
/// bridge functions.
library;

/// Where a suggested title came from.
enum FilenameSource { template, generative }

/// How a placement rule matches a document signal.
enum MatchKind { tag, keyword, titleContains }

/// A single placement rule: when a signal matches, place the document at `path`.
class PlacementRule {
  const PlacementRule({
    required this.id,
    required this.matchKind,
    required this.value,
    required this.path,
    this.priority = 0,
  });

  final String id;
  final MatchKind matchKind;
  final String value;
  final String path;
  final int priority;
}

/// The rule set + fallbacks governing deterministic placement and renaming.
class RuleSet {
  const RuleSet({
    this.placement = const [],
    this.fallbackPath,
    this.filenameTemplate = '{keywords}-{date}',
  });

  final List<PlacementRule> placement;
  final String? fallbackPath;
  final String filenameTemplate;
}

/// Global auto-organization settings.
class OrgConfig {
  const OrgConfig({
    this.enabled = true,
    this.generativeEnabled = false,
    this.dedupThreshold = 0.85,
    this.shingleK = 3,
    this.clusterK = 0,
    this.rules = const RuleSet(),
  });

  final bool enabled;
  final bool generativeEnabled;
  final double dedupThreshold;
  final int shingleK;
  final int clusterK;
  final RuleSet rules;
}

/// The result of organizing one document: everything the caller needs to apply
/// (or show for approval). Suggestion-only; applying is a separate step.
class OrgPlan {
  const OrgPlan({
    required this.documentId,
    this.tags = const [],
    this.suggestedPath,
    this.suggestedTitle,
    this.isDuplicateOf,
    this.confidence = 1.0,
    this.filenameSource = FilenameSource.template,
  });

  final String documentId;
  final List<String> tags;
  final String? suggestedPath;
  final String? suggestedTitle;
  final String? isDuplicateOf;
  final double confidence;
  final FilenameSource filenameSource;
}

/// Auto-organization pipeline interface (mirrors `core::auto_org`).
abstract interface class AutoOrganizer {
  /// Run the deterministic organizer on [documentId], returning suggestions.
  Future<OrgPlan> organize(String documentId, {OrgConfig config});

  /// Regenerate the filename via the generative tier (requires a provider).
  Future<String> generateFilename(String documentId, {String? model});
}
