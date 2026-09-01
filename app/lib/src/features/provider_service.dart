/// A thin, typed facade over the pluggable AI provider bridge surface.
///
/// Exposes provider listing/activation/config/API-key management for the
/// provider configuration screen. Injectable so widget tests can supply a fake
/// without loading the native library.
library;

import '../rust/api/ai.dart' as bridge;
import '../rust/api/ai.dart' show ActiveProviderInfo, ProviderSettings;

export '../rust/api/ai.dart'
    show ActiveProviderInfo, ModelInfo, ProviderKind, ProviderSettings;

/// The provider configuration service interface.
abstract interface class ProviderService {
  List<ProviderSettings> listProviders();
  ActiveProviderInfo activeProvider();
  ActiveProviderInfo selectProvider(String kind, {String? model});
  void saveProviderSettings(ProviderSettings settings);
  void setApiKey(String kind, String key);
  void removeApiKey(String kind);
}

/// Default implementation backed by the Rust AI bridge.
class BridgeProviderService implements ProviderService {
  const BridgeProviderService();

  @override
  List<ProviderSettings> listProviders() => bridge.aiListProviders();

  @override
  ActiveProviderInfo activeProvider() => bridge.aiActiveProvider();

  @override
  ActiveProviderInfo selectProvider(String kind, {String? model}) =>
      bridge.aiSelectProvider(kind: kind, model: model);

  @override
  void saveProviderSettings(ProviderSettings settings) =>
      bridge.aiSaveProviderSettings(settings: settings);

  @override
  void setApiKey(String kind, String key) =>
      bridge.aiSetApiKey(kind: kind, key: key);

  @override
  void removeApiKey(String kind) => bridge.aiRemoveApiKey(kind: kind);
}
