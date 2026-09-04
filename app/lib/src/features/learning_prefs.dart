/// In-memory preference for the on-device suggestion learning mode.
///
/// The `Off` / `Basic` toggle from the settings (Providers) screen is read by
/// [`BridgeDocumentService`](document_service.dart) when building the
/// auto-organization config, and by the review UI to decide whether to record
/// feedback. Persistence is intentionally minimal: the core `OrgConfig.default`
/// already defaults to `Basic`, so forgetting to persist just resets the toggle
/// to the same sane default on next launch.
library;

import '../rust/auto_org/feedback.dart' show LearningMode;

LearningMode _learningMode = LearningMode.basic;

/// The currently selected learning mode (defaults to `Basic`).
LearningMode suggestionLearningMode() => _learningMode;

/// Set the learning mode and return it (for the settings UI).
LearningMode setSuggestionLearningMode(LearningMode mode) {
  _learningMode = mode;
  return _learningMode;
}
