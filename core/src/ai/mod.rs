//! Pluggable AI providers.
//!
//! **Boundary:** a uniform client interface over heterogeneous model backends
//! (OpenAI-compatible HTTP APIs, Anthropic, local Ollama, ...). The rest of the
//! system depends only on [`AiProvider`]; concrete providers are selected via
//! configuration and injected at runtime.
//!
//! **Planned crates:**
//! * [`tokio`](https://crates.io/crates/tokio) — async runtime.
//! * [`reqwest`](https://crates.io/crates/reqwest) — async HTTP client.
//! * [`serde`](https://crates.io/crates/serde) / `serde_json` — wire format.

/// A single message in a provider-agnostic chat/completion request.
#[derive(Debug, Clone, PartialEq)]
pub struct ChatMessage {
    /// `system`, `user`, or `assistant`.
    pub role: String,
    pub content: String,
}

/// A provider-agnostic completion request.
#[derive(Debug, Clone, Default)]
pub struct CompletionRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f32>,
}

/// Token usage reported by a provider.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Usage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
}

/// A provider-agnostic completion response.
#[derive(Debug, Clone, Default)]
pub struct CompletionResponse {
    pub content: String,
    pub usage: Option<Usage>,
}

/// A single provider implementation (e.g. `OpenAiCompatible`, `Anthropic`, `Ollama`).
///
/// Native `async fn` in traits is used (stable since Rust 1.75); implementations
/// are consumed via generic bounds rather than `dyn` to stay object-safe.
pub trait AiProvider: Send + Sync {
    /// Stable identifier for this provider (e.g. `"openai"`, `"ollama"`).
    fn name(&self) -> &'static str;

    /// Run a single completion request.
    ///
    /// The returned future is `Send` so it can be spawned on a multi-threaded
    /// async runtime (e.g. `tokio`).
    fn complete(
        &self,
        req: &CompletionRequest,
    ) -> impl std::future::Future<Output = anyhow::Result<CompletionResponse>> + Send;

    // Streaming generation is planned (return a channel of deltas); it is added
    // when the chat assistant needs token-by-token output.
}
