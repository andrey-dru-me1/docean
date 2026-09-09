//! Provider configuration and persistence.
//!
//! Configuration (kind, base URL, model, enabled flag) is persisted as JSON in
//! a well-known location. **Secrets are deliberately excluded** from this file
//! and live in the OS keychain instead (see [`crate::ai::secrets`]).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Identifies a concrete backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    /// The small, self-contained local model (no external service).
    Builtin,
    /// A local Ollama server over its HTTP API.
    Ollama,
    /// Any OpenAI-compatible HTTP endpoint with an API key.
    OpenAi,
}

impl ProviderKind {
    /// Stable string id, used as the keychain service/account and JSON tag.
    pub fn id(&self) -> &'static str {
        match self {
            ProviderKind::Builtin => "builtin",
            ProviderKind::Ollama => "ollama",
            ProviderKind::OpenAi => "openai",
        }
    }

    /// Human-readable display name.
    pub fn display(&self) -> &'static str {
        match self {
            ProviderKind::Builtin => "Built-in (local)",
            ProviderKind::Ollama => "Ollama (local server)",
            ProviderKind::OpenAi => "OpenAI-compatible",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            "builtin" => Some(ProviderKind::Builtin),
            "ollama" => Some(ProviderKind::Ollama),
            "openai" => Some(ProviderKind::OpenAi),
            _ => None,
        }
    }
}

/// A selectable model on a provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub name: String,
    pub display_name: String,
}

/// Editable configuration for one provider backend.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderConfig {
    /// Backend identifier (serialized as `"builtin"`, `"ollama"`, `"openai"`).
    pub kind: ProviderKind,
    /// Base URL. Sensible default per backend when empty.
    pub base_url: Option<String>,
    /// The currently selected model name.
    pub model: String,
    /// Whether this backend is available for selection.
    pub enabled: bool,
    /// Known selectable models (best-effort; may be refreshed at runtime).
    pub models: Vec<ModelInfo>,
}

impl ProviderConfig {
    /// A config pre-populated with sensible defaults for `kind`.
    pub fn default_for(kind: ProviderKind) -> Self {
        let (base_url, model, models) = match kind {
            ProviderKind::Builtin => (
                None,
                "docean-tiny".to_owned(),
                vec![ModelInfo {
                    name: "docean-tiny".to_owned(),
                    display_name: "Docean Tiny (local)".to_owned(),
                }],
            ),
            ProviderKind::Ollama => (
                Some("http://127.0.0.1:11434".to_owned()),
                "llama3.2".to_owned(),
                Vec::new(),
            ),
            ProviderKind::OpenAi => (
                Some("https://api.openai.com/v1".to_owned()),
                "gpt-4o-mini".to_owned(),
                Vec::new(),
            ),
        };
        ProviderConfig {
            kind,
            base_url,
            model,
            enabled: kind == ProviderKind::Builtin,
            models,
        }
    }
}

/// Full persisted AI configuration: provider table + active selection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AiConfig {
    /// Config for each known backend, keyed by [`ProviderKind::id`].
    pub providers: std::collections::BTreeMap<String, ProviderConfig>,
    /// Id of the active backend.
    pub active_provider: Option<String>,
}

/// Where runtime AI state (config JSON + downloaded model data) lives.
#[derive(Debug, Clone)]
pub struct ConfigStore {
    root: PathBuf,
}

impl ConfigStore {
    /// Create a store rooted at `root` (creating directories on demand).
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// The default data directory for AI config/models.
    pub fn default_root() -> PathBuf {
        default_ai_dir()
    }

    pub fn config_path(&self) -> PathBuf {
        self.root.join("ai.json")
    }

    /// Directory for downloaded built-in model data.
    pub fn models_dir(&self) -> PathBuf {
        self.root.join("models")
    }

    /// Load config from disk, falling back to an empty default.
    pub fn load(&self) -> AiConfig {
        match std::fs::read_to_string(self.config_path()) {
            Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
            Err(_) => AiConfig::default(),
        }
    }

    /// Persist `config` to disk atomically.
    pub fn save(&self, config: &AiConfig) -> anyhow::Result<()> {
        std::fs::create_dir_all(&self.root)?;
        let json = serde_json::to_string_pretty(config)?;
        let tmp = self.config_path().with_extension("tmp");
        std::fs::write(&tmp, json)?;
        std::fs::rename(&tmp, self.config_path())?;
        Ok(())
    }
}

/// Default directory under the per-user config dir, e.g.
/// `~/.config/docean/ai` (or `%APPDATA%\docean\ai` on Windows).
fn default_ai_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."))
            .join("docean")
            .join("ai")
    }
    #[cfg(not(target_os = "windows"))]
    {
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(PathBuf::from)
                    .map(|h| h.join(".config"))
            })
            .unwrap_or_else(|| PathBuf::from("."));
        base.join("docean").join("ai")
    }
}

/// Load the persisted config from the default location.
pub fn load_config() -> Result<AiConfig, String> {
    Ok(ConfigStore::new(ConfigStore::default_root()).load())
}

/// Ensure `kind` has an entry, upsert `config`, and write the file.
///
/// Returns the freshly persisted [`AiConfig`].
pub fn save_provider_config(config: ProviderConfig) -> Result<AiConfig, String> {
    let store = ConfigStore::new(ConfigStore::default_root());
    let mut all = store.load();
    all.providers.insert(config.kind.id().to_owned(), config);
    store.save(&all).map_err(|e| e.to_string())?;
    Ok(all)
}

/// Convenience path helper used by tests and the bridge to pick a temp root.
pub fn with_root(root: &Path) -> ConfigStore {
    ConfigStore::new(root.to_path_buf())
}
