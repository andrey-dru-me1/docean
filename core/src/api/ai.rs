//! Flutter bridge surface for pluggable AI providers.
//!
//! Every function here is reachable from Dart. The facade holds a process-wide
//! [`AiManager`] behind a lazily-initialized lock and translates the request
//! DTOs into `core::ai` types. **API keys never cross the FFI boundary** —
//! they are read from the keychain on the Rust side and sent over the wire only.

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::ai::{self, AiManager, GenerateMode};

/// Re-exported provider-kind enum so Dart sees a single shared type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Builtin,
    Ollama,
    /// An OpenAI-compatible endpoint. Named `Openai` (single word) so the
    /// generated Dart enum member is `openai`, matching the stored `kind` id.
    #[serde(rename = "openai")]
    Openai,
}

impl From<ai::config::ProviderKind> for ProviderKind {
    fn from(k: ai::config::ProviderKind) -> Self {
        match k {
            ai::config::ProviderKind::Builtin => ProviderKind::Builtin,
            ai::config::ProviderKind::Ollama => ProviderKind::Ollama,
            ai::config::ProviderKind::OpenAi => ProviderKind::Openai,
        }
    }
}

/// One selectable model on a provider (Dart DTO).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub name: String,
    pub display_name: String,
}

/// Configuration for a single provider backend (Dart DTO; no secrets).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSettings {
    pub kind: ProviderKind,
    pub base_url: Option<String>,
    pub model: String,
    pub enabled: bool,
    pub models: Vec<ModelInfo>,
    /// Whether an API key is currently stored for this backend.
    pub has_api_key: bool,
}

/// Snapshot of the active provider + model (Dart DTO).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveProviderInfo {
    pub kind: String,
    pub model: String,
    pub base_url: Option<String>,
    pub has_api_key: bool,
}

/// A text-generation request (Dart DTO).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateRequestDto {
    pub prompt: String,
    pub system: Option<String>,
    pub mode: GenerateMode,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f32>,
}

/// A classification request (Dart DTO).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClassifyRequestDto {
    pub text: String,
    pub labels: Vec<String>,
}

/// An embedding request (Dart DTO).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EmbedRequestDto {
    pub text: String,
}

/// A text-generation response (Dart DTO).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateResponseDto {
    pub content: String,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
}

/// A single label score (Dart DTO).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LabelScore {
    pub label: String,
    pub score: f32,
}

/// A classification response (Dart DTO).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClassifyResponseDto {
    pub label: String,
    pub scores: Vec<LabelScore>,
}

/// An embedding response (Dart DTO).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EmbedResponseDto {
    pub vector: Vec<f32>,
    pub dimensions: u32,
}

/// Convert provider settings to/from the core config type.
fn to_settings(cfg: &ai::config::ProviderConfig) -> ProviderSettings {
    ProviderSettings {
        kind: cfg.kind.into(),
        base_url: cfg.base_url.clone(),
        model: cfg.model.clone(),
        enabled: cfg.enabled,
        models: cfg
            .models
            .iter()
            .map(|m| ModelInfo {
                name: m.name.clone(),
                display_name: m.display_name.clone(),
            })
            .collect(),
        has_api_key: ai::secrets::get_api_key(cfg.kind.id()).is_some(),
    }
}

fn from_settings(s: ProviderSettings) -> ai::config::ProviderConfig {
    let kind = match s.kind {
        ProviderKind::Builtin => ai::config::ProviderKind::Builtin,
        ProviderKind::Ollama => ai::config::ProviderKind::Ollama,
        ProviderKind::Openai => ai::config::ProviderKind::OpenAi,
    };
    ai::config::ProviderConfig {
        kind,
        base_url: s.base_url,
        model: s.model,
        enabled: s.enabled,
        models: s
            .models
            .into_iter()
            .map(|m| ai::config::ModelInfo {
                name: m.name,
                display_name: m.display_name,
            })
            .collect(),
    }
}

/// The shared process-wide AI manager.
fn manager() -> &'static Arc<Mutex<AiManager>> {
    ai::manager::default_manager()
}

/// List configured providers (with `has_api_key` computed without exposing keys).
#[flutter_rust_bridge::frb(sync)]
pub fn ai_list_providers() -> Vec<ProviderSettings> {
    let guard = manager().lock().unwrap();
    guard.config().providers.values().map(to_settings).collect()
}

/// Snapshot of the currently active provider + model.
#[flutter_rust_bridge::frb(sync)]
pub fn ai_active_provider() -> ActiveProviderInfo {
    let guard = manager().lock().unwrap();
    let a = guard.active();
    ActiveProviderInfo {
        kind: a.kind,
        model: a.model,
        base_url: a.base_url,
        has_api_key: a.has_api_key,
    }
}

/// Select the active provider and (optionally) model at runtime.
#[flutter_rust_bridge::frb(sync)]
pub fn ai_select_provider(
    kind: String,
    model: Option<String>,
) -> Result<ActiveProviderInfo, String> {
    let mut guard = manager().lock().unwrap();
    let model = model.unwrap_or_default();
    let a = guard.select(&kind, &model)?;
    Ok(ActiveProviderInfo {
        kind: a.kind,
        model: a.model,
        base_url: a.base_url,
        has_api_key: a.has_api_key,
    })
}

/// Save (upsert) a provider's configuration. Secrets are *not* included.
#[flutter_rust_bridge::frb(sync)]
pub fn ai_save_provider_settings(settings: ProviderSettings) -> Result<(), String> {
    let mut guard = manager().lock().unwrap();
    guard.upsert_provider(from_settings(settings))
}

/// Store an API key in the OS keychain for the given provider kind.
#[flutter_rust_bridge::frb(sync)]
pub fn ai_set_api_key(kind: String, key: String) -> Result<(), String> {
    ai::secrets::set_api_key(&kind, &key)
}

/// Remove a stored API key for the given provider kind.
#[flutter_rust_bridge::frb(sync)]
pub fn ai_remove_api_key(kind: String) -> Result<(), String> {
    ai::secrets::remove_api_key(&kind)
}

/// Generate text using the active provider.
#[flutter_rust_bridge::frb]
pub async fn ai_generate(req: GenerateRequestDto) -> Result<GenerateResponseDto, String> {
    // Snapshot the active provider handle + model, then release the lock before
    // awaiting (a `std::sync::MutexGuard` is not `Send`).
    let (handle, model) = {
        let guard = manager().lock().unwrap();
        (guard.active_handle(), guard.active().model)
    };
    let request = ai::GenerateRequest {
        model,
        prompt: req.prompt,
        system: req.system,
        mode: req.mode,
        max_tokens: req.max_tokens,
        temperature: req.temperature,
    };
    match handle.generate(request).await {
        Ok(resp) => Ok(GenerateResponseDto {
            content: resp.content,
            prompt_tokens: resp
                .usage
                .as_ref()
                .map(|u| u.prompt_tokens)
                .unwrap_or_default(),
            completion_tokens: resp
                .usage
                .as_ref()
                .map(|u| u.completion_tokens)
                .unwrap_or_default(),
        }),
        Err(e) => Err(e.to_string()),
    }
}

/// Classify text into one of `labels` using the active provider.
#[flutter_rust_bridge::frb]
pub async fn ai_classify(req: ClassifyRequestDto) -> Result<ClassifyResponseDto, String> {
    let (handle, model) = {
        let guard = manager().lock().unwrap();
        (guard.active_handle(), guard.active().model)
    };
    let request = ai::ClassifyRequest {
        model,
        text: req.text,
        labels: req.labels,
    };
    match handle.classify(request).await {
        Ok(resp) => Ok(ClassifyResponseDto {
            label: resp.label,
            scores: resp
                .scores
                .into_iter()
                .map(|c| LabelScore {
                    label: c.label,
                    score: c.score,
                })
                .collect(),
        }),
        Err(e) => Err(e.to_string()),
    }
}

/// Embed text using the active provider.
#[flutter_rust_bridge::frb]
pub async fn ai_embed(req: EmbedRequestDto) -> Result<EmbedResponseDto, String> {
    let (handle, model) = {
        let guard = manager().lock().unwrap();
        (guard.active_handle(), guard.active().model)
    };
    let request = ai::EmbedRequest {
        model,
        text: req.text,
    };
    match handle.embed(request).await {
        Ok(resp) => Ok(EmbedResponseDto {
            vector: resp.vector,
            dimensions: resp.dimensions as u32,
        }),
        Err(e) => Err(e.to_string()),
    }
}
