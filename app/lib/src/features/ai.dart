/// Pluggable AI providers (Dart side).
///
/// This wraps the `flutter_rust_bridge` bindings generated from `core::api::ai`
/// (see `src/rust/api/ai.dart`) behind a small, documented facade. Provider
/// configuration and model selection are persisted by the Rust core; API keys
/// never cross the FFI boundary and are stored in the OS keychain on the native
/// side.
///
/// All callers should go through [AiService]; the generated `ai*` functions are
/// the low-level bridge surface.
library;

import '../rust/api/ai.dart' as bridge;

export '../rust/ai.dart' show GenerateMode;
export '../rust/api/ai.dart'
    show
        ActiveProviderInfo,
        ClassifyRequestDto,
        ClassifyResponseDto,
        EmbedRequestDto,
        EmbedResponseDto,
        GenerateRequestDto,
        GenerateResponseDto,
        LabelScore,
        ModelInfo,
        ProviderKind,
        ProviderSettings;

/// A small facade over the Rust-backed pluggable AI subsystem.
///
/// [`AiService`] mirrors `core::ai::AiManager`'s runtime surface: list/select
/// providers and models, and run generation, classification, and embeddings
/// against the active provider.
class AiService {
  const AiService();

  /// All configured providers, with `hasApiKey` computed without ever touching
  /// the key material on the Dart side.
  List<bridge.ProviderSettings> listProviders() => bridge.aiListProviders();

  /// The currently active provider + model.
  bridge.ActiveProviderInfo activeProvider() => bridge.aiActiveProvider();

  /// Select the active provider and (optionally) model at runtime.
  bridge.ActiveProviderInfo selectProvider(String kind, {String? model}) =>
      bridge.aiSelectProvider(kind: kind, model: model);

  /// Upsert a provider's configuration. Secrets are *not* included.
  void saveProviderSettings(bridge.ProviderSettings settings) =>
      bridge.aiSaveProviderSettings(settings: settings);

  /// Store an API key in the OS keychain (Rust side) for the given provider.
  void setApiKey(String kind, String key) =>
      bridge.aiSetApiKey(kind: kind, key: key);

  /// Remove a stored API key.
  void removeApiKey(String kind) => bridge.aiRemoveApiKey(kind: kind);

  /// Generate text from a prompt using the active provider.
  Future<bridge.GenerateResponseDto> generate(bridge.GenerateRequestDto req) =>
      bridge.aiGenerate(req: req);

  /// Classify text into one of `labels` using the active provider.
  Future<bridge.ClassifyResponseDto> classify(bridge.ClassifyRequestDto req) =>
      bridge.aiClassify(req: req);

  /// Embed text into a dense vector using the active provider.
  Future<bridge.EmbedResponseDto> embed(bridge.EmbedRequestDto req) =>
      bridge.aiEmbed(req: req);
}
