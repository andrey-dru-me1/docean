//! Pluggable AI providers.
//!
//! **Boundary:** a uniform client interface over heterogeneous model backends.
//! The rest of the system depends only on [`AiProvider`]; concrete providers are
//! selected via configuration and injected at runtime (see [`AiManager`]).
//!
//! # Providers
//!
//! * [`builtin::BuiltinProvider`] — a small, self-contained local model (no
//!   external service). It ships a tiny generative/embedding pipeline and
//!   downloads its vocab data on first use. This is the "small + simple,
//!   optional" on-device default.
//! * [`ollama::OllamaProvider`] — a local [Ollama](https://ollama.com) server
//!   reached over its HTTP API.
//! * [`openai::OpenAiProvider`] — any OpenAI-compatible endpoint, given a
//!   user-provided API key and base URL.
//!
//! # Configuration & secrets
//!
//! Provider configuration (kind, base URL, active model, enabled flag) is
//! persisted as JSON on disk; secrets (API keys) are stored in the **OS
//! keychain** via the `keyring` crate and are never written to the JSON file —
//! see [`config`] and [`secrets`].
//!
//! # Async notes
//!
//! The [`AiProvider`] trait uses native `async fn` in traits (stable since Rust
//! 1.75). The [`AiManager`] holds a boxed, object-safe erased provider
//! ([`BoxAiProvider`]) so the active provider can be switched at runtime.

pub mod builtin;
pub mod config;
pub mod manager;
pub mod ollama;
pub mod openai;
pub mod secrets;

#[cfg(test)]
mod tests;

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

pub use builtin::{BuiltinProvider, BuiltinStatus};
pub use config::{
    load_config, save_provider_config, AiConfig, ConfigStore, ModelInfo, ProviderConfig,
    ProviderKind,
};
pub use manager::{ActiveProvider, AiManager};
pub use ollama::OllamaProvider;
pub use openai::OpenAiProvider;
pub use secrets::{remove_api_key, set_api_key, API_KEY_SERVICE, KEYCHAIN_FALLBACK_ENV};

/// A single message in a provider-agnostic chat/completion request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    /// `system`, `user`, or `assistant`.
    pub role: String,
    pub content: String,
}

impl ChatMessage {
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: "user".to_owned(),
            content: content.into(),
        }
    }

    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: "system".to_owned(),
            content: content.into(),
        }
    }
}

/// A provider-agnostic completion request.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CompletionRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f32>,
}

/// Token usage reported by a provider.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
}

/// A provider-agnostic completion response.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CompletionResponse {
    pub content: String,
    pub usage: Option<Usage>,
}

/// How text generation should shape its output.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum GenerateMode {
    /// A short, deterministic answer (used by the classifier and assistant).
    #[default]
    Answer,
    /// A longer, more creative completion.
    Creative,
    /// A terse heading/label (used by the auto-organizer).
    Summary,
}

/// A provider-agnostic text generation request.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GenerateRequest {
    pub model: String,
    pub prompt: String,
    pub system: Option<String>,
    pub mode: GenerateMode,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f32>,
}

/// A provider-agnostic classification request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClassifyRequest {
    pub model: String,
    pub text: String,
    pub labels: Vec<String>,
}

/// A single label and its confidence in `[0, 1]`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Classification {
    pub label: String,
    pub score: f32,
}

/// A provider-agnostic classification response (labels with confidences).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClassifyResponse {
    pub label: String,
    pub scores: Vec<Classification>,
}

/// A provider-agnostic embedding request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbedRequest {
    pub model: String,
    pub text: String,
}

/// A provider-agnostic embedding response (one dense vector).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EmbedResponse {
    pub vector: Vec<f32>,
    pub dimensions: usize,
}

/// A single provider implementation (e.g. [`openai::OpenAiProvider`],
/// [`ollama::OllamaProvider`], [`builtin::BuiltinProvider`]).
///
/// Native `async fn` in traits is used (stable since Rust 1.75). Implementations
/// are consumed via generic bounds rather than `dyn` to stay object-safe; the
/// [`AiManager`] erases this trait into [`BoxAiProvider`].
pub trait AiProvider: Send + Sync {
    /// Stable identifier for this provider (e.g. `"openai"`, `"ollama"`, `"builtin"`).
    fn name(&self) -> &'static str;

    /// Run a single chat/completion request.
    fn complete(
        &self,
        req: &CompletionRequest,
    ) -> impl Future<Output = anyhow::Result<CompletionResponse>> + Send;

    /// Generate text from a single prompt.
    ///
    /// Defaults to wrapping [`AiProvider::complete`] with a single user message.
    fn generate(
        &self,
        req: &GenerateRequest,
    ) -> impl Future<Output = anyhow::Result<CompletionResponse>> + Send {
        let mut messages = Vec::new();
        if let Some(system) = &req.system {
            messages.push(ChatMessage::system(system.clone()));
        }
        messages.push(ChatMessage::user(req.prompt.clone()));
        let request = CompletionRequest {
            model: req.model.clone(),
            messages,
            max_tokens: req.max_tokens,
            temperature: req.temperature,
        };
        async move { self.complete(&request).await }
    }

    /// Classify `text` into the closest of `labels`, returning scores.
    fn classify(
        &self,
        req: &ClassifyRequest,
    ) -> impl Future<Output = anyhow::Result<ClassifyResponse>> + Send;

    /// Embed `text` into a dense vector.
    fn embed(
        &self,
        req: &EmbedRequest,
    ) -> impl Future<Output = anyhow::Result<EmbedResponse>> + Send;
}

/// Object-safe form of [`AiProvider`], shared behind an `Arc`.
///
/// The [`AiManager`] stores the active provider as this erased handle so it can
/// be swapped at runtime, and so callers can clone the `Arc` and drop any lock
/// before `await`ing (avoiding `!Send` `MutexGuard`-across-await issues).
pub type BoxAiProvider = Arc<dyn DynAiProvider>;

/// Object-safe, erased twin of [`AiProvider`] implementing the same surface via
/// `Pin<Box<dyn Future>>`. Requests are taken **by value** so the returned
/// futures are `'static` (the erased box is stored long-lived in the manager).
pub trait DynAiProvider: Send + Sync {
    fn name(&self) -> &'static str;
    fn complete(
        &self,
        req: CompletionRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<CompletionResponse>> + Send>>;
    fn generate(
        &self,
        req: GenerateRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<CompletionResponse>> + Send>>;
    fn classify(
        &self,
        req: ClassifyRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<ClassifyResponse>> + Send>>;
    fn embed(
        &self,
        req: EmbedRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<EmbedResponse>> + Send>>;
}

/// Erase any [`AiProvider`] into a [`BoxAiProvider`], sharing it behind an `Arc`
/// so the returned futures can be `'static` without cloning the provider.
///
/// This is a free function rather than a blanket `From` impl because the orphan
/// rule forbids `impl<P> From<P> for Arc<dyn DynAiProvider>` (`P` is not local
/// to the `Arc` target type).
pub fn erase<P: AiProvider + 'static>(p: P) -> BoxAiProvider {
    Arc::new(Erased(Arc::new(p)))
}

struct Erased<P>(Arc<P>);

impl<P: AiProvider + 'static> DynAiProvider for Erased<P> {
    fn name(&self) -> &'static str {
        self.0.name()
    }

    fn complete(
        &self,
        req: CompletionRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<CompletionResponse>> + Send>> {
        let this = self.0.clone();
        Box::pin(async move { this.complete(&req).await })
    }

    fn generate(
        &self,
        req: GenerateRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<CompletionResponse>> + Send>> {
        let this = self.0.clone();
        Box::pin(async move { this.generate(&req).await })
    }

    fn classify(
        &self,
        req: ClassifyRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<ClassifyResponse>> + Send>> {
        let this = self.0.clone();
        Box::pin(async move { this.classify(&req).await })
    }

    fn embed(
        &self,
        req: EmbedRequest,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<EmbedResponse>> + Send>> {
        let this = self.0.clone();
        Box::pin(async move { this.embed(&req).await })
    }
}
