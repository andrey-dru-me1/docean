//! Runtime AI manager: configuration + active-provider selection + dispatch.
//!
//! The manager owns the persisted [`AiConfig`]'s in-memory mirror and a boxed
//! erase of the active backend. Selecting a provider/model at runtime rebuilds
//! the underlying provider instance and updates persistence.

use std::sync::Arc;

use crate::ai::{
    secrets, AiConfig, BoxAiProvider, BuiltinProvider, ClassifyRequest, ClassifyResponse,
    CompletionRequest, CompletionResponse, ConfigStore, EmbedRequest, EmbedResponse,
    GenerateRequest, OllamaProvider, OpenAiProvider,
};

/// Which backend is currently active, plus its selected model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveProvider {
    pub kind: String,
    pub model: String,
    pub base_url: Option<String>,
    /// Whether the active backend has a stored API key (only relevant for
    /// `openai`; always `true` for keyless backends).
    pub has_api_key: bool,
}

/// Rebuild a concrete provider from a config entry.
fn build_provider(
    kind: &crate::ai::config::ProviderKind,
    cfg: &crate::ai::config::ProviderConfig,
) -> BoxAiProvider {
    let client = reqwest::Client::new();
    match kind {
        crate::ai::config::ProviderKind::Builtin => crate::ai::erase(BuiltinProvider::new(
            ConfigStore::default_root().join("models"),
        )),
        crate::ai::config::ProviderKind::Ollama => {
            crate::ai::erase(OllamaProvider::new(cfg.base_url.clone(), client))
        }
        crate::ai::config::ProviderKind::OpenAi => {
            crate::ai::erase(OpenAiProvider::new(cfg.base_url.clone(), client))
        }
    }
}

/// The process's shared AI manager.
///
/// Wrapped in `Arc<Mutex<_>>` so the synchronous FRB facade can call it from
/// the single-threaded Dart isolate without `&mut self` across the FFI boundary.
pub struct AiManager {
    store: ConfigStore,
    config: AiConfig,
    active: BoxAiProvider,
}

impl AiManager {
    /// Create a manager from a [`ConfigStore`], ensuring a built-in provider is
    /// present and an active backend is selected.
    pub fn new(store: ConfigStore) -> Self {
        let mut config = store.load();
        // Make sure the built-in backend always exists (it needs no external
        // service and is the default).
        let builtin = crate::ai::config::ProviderConfig::default_for(
            crate::ai::config::ProviderKind::Builtin,
        );
        config
            .providers
            .entry("builtin".to_owned())
            .or_insert_with(|| builtin.clone());
        if config.active_provider.is_none() {
            config.active_provider = Some("builtin".to_owned());
        }

        let active = build_active(&mut config);
        AiManager {
            store,
            config,
            active,
        }
    }

    /// Create a manager over `store` whose active provider is *exactly* the
    /// given `provider` (bypassing the default built-in bootstrap). Used by
    /// tests with a mock provider.
    pub fn with_provider(store: ConfigStore, provider: BoxAiProvider) -> Self {
        let mut config = store.load();
        if config.active_provider.is_none() {
            config.active_provider = Some(provider.name().to_owned());
        }
        AiManager {
            store,
            config,
            active: provider,
        }
    }

    /// Reload persisted config and rebuild the active provider.
    pub fn reload(&mut self) -> anyhow::Result<()> {
        self.config = self.store.load();
        self.active = build_active(&mut self.config);
        Ok(())
    }

    /// Snapshot of the currently active backend.
    pub fn active(&self) -> ActiveProvider {
        let kind = self.config.active_provider.clone().unwrap_or_default();
        let cfg = self
            .config
            .providers
            .get(&kind)
            .cloned()
            .unwrap_or_else(|| {
                crate::ai::config::ProviderConfig::default_for(
                    crate::ai::config::ProviderKind::Builtin,
                )
            });
        ActiveProvider {
            model: cfg.model,
            base_url: cfg.base_url.clone(),
            has_api_key: secrets::get_api_key(&kind).is_some(),
            kind,
        }
    }

    /// Full in-memory config (provider table + active id).
    pub fn config(&self) -> &AiConfig {
        &self.config
    }

    /// Clone a handle to the active provider, so a caller can `await` on it
    /// without holding any `MutexGuard` across the await point.
    pub fn active_handle(&self) -> Arc<dyn crate::ai::DynAiProvider> {
        self.active.clone()
    }

    /// Select `provider_kind` and `model` as the active backend, persisting the
    /// choice and swapping the underlying provider.
    pub fn select(&mut self, provider_kind: &str, model: &str) -> Result<ActiveProvider, String> {
        if !self.config.providers.contains_key(provider_kind) {
            // Create a default entry for an unknown-but-valid kind id.
            if let Some(kind) = crate::ai::config::ProviderKind::from_id(provider_kind) {
                self.config.providers.insert(
                    provider_kind.to_owned(),
                    crate::ai::config::ProviderConfig::default_for(kind),
                );
            } else {
                return Err(format!("unknown provider kind '{provider_kind}'"));
            }
        }
        if !model.is_empty() {
            if let Some(cfg) = self.config.providers.get_mut(provider_kind) {
                cfg.model = model.to_owned();
            }
        }
        self.config.active_provider = Some(provider_kind.to_owned());
        self.store.save(&self.config).map_err(|e| e.to_string())?;
        self.active = build_active(&mut self.config);
        Ok(self.active())
    }

    /// Upsert a provider configuration entry and persist it.
    pub fn upsert_provider(
        &mut self,
        cfg: crate::ai::config::ProviderConfig,
    ) -> Result<(), String> {
        let kind_id = cfg.kind.id().to_owned();
        self.config.providers.insert(kind_id.clone(), cfg);
        self.store.save(&self.config).map_err(|e| e.to_string())?;
        // If the updated provider is active, rebuild it immediately.
        if self.config.active_provider.as_deref() == Some(kind_id.as_str()) {
            self.active = build_active(&mut self.config);
        }
        Ok(())
    }

    pub async fn complete(&self, req: &CompletionRequest) -> anyhow::Result<CompletionResponse> {
        self.active.complete(req.clone()).await
    }

    pub async fn generate(&self, req: &GenerateRequest) -> anyhow::Result<CompletionResponse> {
        self.active.generate(req.clone()).await
    }

    pub async fn classify(&self, req: &ClassifyRequest) -> anyhow::Result<ClassifyResponse> {
        self.active.classify(req.clone()).await
    }

    pub async fn embed(&self, req: &EmbedRequest) -> anyhow::Result<EmbedResponse> {
        self.active.embed(req.clone()).await
    }
}

/// Build the erased active provider from the config's `active_provider` field.
///
/// Falls back to the built-in provider (creating its entry if needed) when no
/// active backend is recorded.
fn build_active(config: &mut AiConfig) -> BoxAiProvider {
    let active_id = config
        .active_provider
        .clone()
        .or_else(|| {
            config.active_provider = Some("builtin".to_owned());
            config.active_provider.clone()
        })
        .unwrap_or_else(|| "builtin".to_owned());

    let kind = crate::ai::config::ProviderKind::from_id(&active_id)
        .unwrap_or(crate::ai::config::ProviderKind::Builtin);
    let cfg = config
        .providers
        .entry(active_id)
        .or_insert_with(|| crate::ai::config::ProviderConfig::default_for(kind));
    build_provider(&kind, cfg)
}

/// Shared, lazily-initialized process-wide manager for the FRB facade.
///
/// Kept as an `Arc` handle in a `OnceLock` so the manager outlives individual
/// bridge calls while remaining cheap to share.
pub fn default_manager() -> &'static Arc<std::sync::Mutex<AiManager>> {
    use std::sync::OnceLock;
    static MANAGER: OnceLock<Arc<std::sync::Mutex<AiManager>>> = OnceLock::new();
    MANAGER.get_or_init(|| {
        let store = ConfigStore::new(ConfigStore::default_root());
        Arc::new(std::sync::Mutex::new(AiManager::new(store)))
    })
}
