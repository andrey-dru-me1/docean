//! OpenAI-compatible HTTP API (user-provided key + base URL).
//!
//! Endpoints used:
//! * `POST /chat/completions` — text generation.
//! * `POST /embeddings` — embeddings.
//! * `GET  /models` — list available models.
//!
//! The API key is read from the keychain (see [`crate::ai::secrets`]) and sent
//! as a `Bearer` token; it never leaves Rust side otherwise.

use serde::{Deserialize, Serialize};

use crate::ai::secrets;
use crate::ai::{
    AiProvider, Classification, ClassifyRequest, ClassifyResponse, CompletionRequest,
    CompletionResponse, EmbedRequest, EmbedResponse, GenerateRequest, Usage,
};

const DEFAULT_BASE_URL: &str = "https://api.openai.com/v1";

/// An OpenAI-compatible provider.
pub struct OpenAiProvider {
    base_url: String,
    client: reqwest::Client,
}

impl OpenAiProvider {
    /// Create a provider for `base_url` (empty → OpenAI default).
    pub fn new(base_url: Option<String>, client: reqwest::Client) -> Self {
        let base_url = base_url
            .filter(|u| !u.is_empty())
            .unwrap_or_else(|| DEFAULT_BASE_URL.to_owned())
            .trim_end_matches('/')
            .to_owned();
        OpenAiProvider { base_url, client }
    }

    /// List model ids available at the endpoint (best-effort).
    pub async fn list_models(&self) -> anyhow::Result<Vec<String>> {
        let resp = self
            .client
            .get(format!("{}/models", self.base_url))
            .bearer_auth(self.api_key()?)
            .send()
            .await?
            .error_for_status()?;
        let body: ModelsResponse = resp.json().await?;
        Ok(body.data.into_iter().map(|m| m.id).collect())
    }

    fn api_key(&self) -> anyhow::Result<String> {
        secrets::get_api_key("openai").ok_or_else(|| {
            anyhow::anyhow!("no OpenAI-compatible API key stored; configure one first")
        })
    }
}

#[derive(Deserialize)]
struct ModelsResponse {
    data: Vec<ModelsItem>,
}

#[derive(Deserialize)]
struct ModelsItem {
    id: String,
}

#[derive(Serialize, Deserialize)]
struct ChatMessageWire {
    role: String,
    content: String,
}

#[derive(Serialize)]
struct ChatBody {
    model: String,
    messages: Vec<ChatMessageWire>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f32>,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
    usage: Option<UsageWire>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatMessageWire,
}

#[derive(Deserialize)]
struct UsageWire {
    prompt_tokens: Option<u32>,
    completion_tokens: Option<u32>,
}

#[derive(Serialize)]
struct EmbedBody {
    model: String,
    input: String,
}

#[derive(Deserialize)]
struct EmbedResponseBody {
    data: Vec<EmbedDatum>,
}

#[derive(Deserialize)]
struct EmbedDatum {
    embedding: Vec<f32>,
}

impl AiProvider for OpenAiProvider {
    fn name(&self) -> &'static str {
        "openai"
    }

    async fn complete(&self, req: &CompletionRequest) -> anyhow::Result<CompletionResponse> {
        let body = ChatBody {
            model: req.model.clone(),
            messages: req
                .messages
                .iter()
                .map(|m| ChatMessageWire {
                    role: m.role.clone(),
                    content: m.content.clone(),
                })
                .collect(),
            max_tokens: req.max_tokens,
            temperature: req.temperature,
        };
        let resp = self
            .client
            .post(format!("{}/chat/completions", self.base_url))
            .bearer_auth(self.api_key()?)
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        let out: ChatResponse = resp.json().await?;
        let content = out
            .choices
            .into_iter()
            .next()
            .map(|c| c.message.content)
            .unwrap_or_default();
        Ok(CompletionResponse {
            content,
            usage: out.usage.map(|u| Usage {
                prompt_tokens: u.prompt_tokens.unwrap_or_default(),
                completion_tokens: u.completion_tokens.unwrap_or_default(),
            }),
        })
    }

    async fn generate(&self, req: &GenerateRequest) -> anyhow::Result<CompletionResponse> {
        let mut messages = Vec::new();
        if let Some(system) = &req.system {
            messages.push(ChatMessageWire {
                role: "system".to_owned(),
                content: system.clone(),
            });
        }
        messages.push(ChatMessageWire {
            role: "user".to_owned(),
            content: req.prompt.clone(),
        });
        let body = ChatBody {
            model: req.model.clone(),
            messages,
            max_tokens: req.max_tokens,
            temperature: req.temperature,
        };
        let resp = self
            .client
            .post(format!("{}/chat/completions", self.base_url))
            .bearer_auth(self.api_key()?)
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        let out: ChatResponse = resp.json().await?;
        let content = out
            .choices
            .into_iter()
            .next()
            .map(|c| c.message.content)
            .unwrap_or_default();
        Ok(CompletionResponse {
            content,
            usage: out.usage.map(|u| Usage {
                prompt_tokens: u.prompt_tokens.unwrap_or_default(),
                completion_tokens: u.completion_tokens.unwrap_or_default(),
            }),
        })
    }

    async fn classify(&self, req: &ClassifyRequest) -> anyhow::Result<ClassifyResponse> {
        // OpenAI has no dedicated classification endpoint; embed text+labels
        // and pick the nearest label (mirrors Ollama/Builtin behaviour).
        let emb = self
            .embed(&EmbedRequest {
                model: req.model.clone(),
                text: req.text.clone(),
            })
            .await?;
        let mut scored: Vec<(f32, String)> = Vec::new();
        for label in &req.labels {
            let le = self
                .embed(&EmbedRequest {
                    model: req.model.clone(),
                    text: label.clone(),
                })
                .await?;
            scored.push((cosine(&emb.vector, &le.vector), label.clone()));
        }
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        let top = scored
            .first()
            .cloned()
            .map(|(s, l)| Classification { label: l, score: s })
            .unwrap_or(Classification {
                label: req.labels[0].clone(),
                score: 0.0,
            });
        Ok(ClassifyResponse {
            label: top.label,
            scores: scored
                .into_iter()
                .map(|(s, l)| Classification { label: l, score: s })
                .collect(),
        })
    }

    async fn embed(&self, req: &EmbedRequest) -> anyhow::Result<EmbedResponse> {
        let body = EmbedBody {
            model: req.model.clone(),
            input: req.text.clone(),
        };
        let resp = self
            .client
            .post(format!("{}/embeddings", self.base_url))
            .bearer_auth(self.api_key()?)
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        let out: EmbedResponseBody = resp.json().await?;
        let mut vec = out
            .data
            .into_iter()
            .next()
            .map(|d| d.embedding)
            .unwrap_or_default();
        let dimensions = vec.len();
        normalize_in_place(&mut vec);
        Ok(EmbedResponse {
            vector: vec,
            dimensions,
        })
    }
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    dot.clamp(0.0, 1.0)
}

fn normalize_in_place(v: &mut [f32]) {
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
}
