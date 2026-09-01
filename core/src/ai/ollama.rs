//! Local [Ollama](https://ollama.com) server over its HTTP API.
//!
//! Endpoints used:
//! * `POST /api/generate` — text generation (single-shot).
//! * `POST /api/embeddings` — embeddings.
//! * `GET  /api/tags` — list locally available models.

use serde::{Deserialize, Serialize};

use crate::ai::{
    AiProvider, Classification, ClassifyRequest, ClassifyResponse, CompletionRequest,
    CompletionResponse, EmbedRequest, EmbedResponse, GenerateRequest, Usage,
};

const DEFAULT_BASE_URL: &str = "http://127.0.0.1:11434";

/// An Ollama provider pointed at a local server.
pub struct OllamaProvider {
    base_url: String,
    client: reqwest::Client,
}

impl OllamaProvider {
    /// Create a provider for `base_url` (empty → default localhost).
    pub fn new(base_url: Option<String>, client: reqwest::Client) -> Self {
        let base_url = base_url
            .filter(|u| !u.is_empty())
            .unwrap_or_else(|| DEFAULT_BASE_URL.to_owned())
            .trim_end_matches('/')
            .to_owned();
        OllamaProvider { base_url, client }
    }

    /// List model names available on the server (best-effort).
    pub async fn list_models(&self) -> anyhow::Result<Vec<String>> {
        let resp = self
            .client
            .get(format!("{}/api/tags", self.base_url))
            .send()
            .await?;
        let body: TagsResponse = resp.error_for_status()?.json().await?;
        Ok(body.models.into_iter().map(|m| m.name).collect())
    }
}

#[derive(Deserialize)]
struct TagsResponse {
    models: Vec<TagsModel>,
}

#[derive(Deserialize)]
struct TagsModel {
    name: String,
}

#[derive(Serialize)]
struct GenerateBody<'a> {
    model: &'a str,
    prompt: &'a str,
    system: Option<&'a str>,
    stream: bool,
    options: GenerateOptions,
}

#[derive(Serialize, Default)]
struct GenerateOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    num_predict: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f32>,
}

#[derive(Deserialize)]
struct GenerateResponse {
    response: String,
    #[allow(unused)]
    prompt_eval_count: Option<u32>,
    eval_count: Option<u32>,
}

#[derive(Serialize)]
struct EmbedBody<'a> {
    model: &'a str,
    prompt: &'a str,
}

#[derive(Deserialize)]
struct EmbedResponseBody {
    embedding: Vec<f32>,
}

impl AiProvider for OllamaProvider {
    fn name(&self) -> &'static str {
        "ollama"
    }

    async fn complete(&self, req: &CompletionRequest) -> anyhow::Result<CompletionResponse> {
        let prompt = req
            .messages
            .iter()
            .map(|m| format!("{}: {}", m.role, m.content))
            .collect::<Vec<_>>()
            .join("\n");
        let system = req
            .messages
            .iter()
            .find(|m| m.role == "system")
            .map(|m| m.content.as_str());
        let body = GenerateBody {
            model: &req.model,
            prompt: &prompt,
            system,
            stream: false,
            options: GenerateOptions {
                num_predict: req.max_tokens,
                temperature: req.temperature,
            },
        };
        let resp = self
            .client
            .post(format!("{}/api/generate", self.base_url))
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        let out: GenerateResponse = resp.json().await?;
        Ok(CompletionResponse {
            content: out.response,
            usage: Some(Usage {
                prompt_tokens: out.prompt_eval_count.unwrap_or_default(),
                completion_tokens: out.eval_count.unwrap_or_default(),
            }),
        })
    }

    async fn generate(&self, req: &GenerateRequest) -> anyhow::Result<CompletionResponse> {
        let body = GenerateBody {
            model: &req.model,
            prompt: &req.prompt,
            system: req.system.as_deref(),
            stream: false,
            options: GenerateOptions {
                num_predict: req.max_tokens,
                temperature: req.temperature,
            },
        };
        let resp = self
            .client
            .post(format!("{}/api/generate", self.base_url))
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        let out: GenerateResponse = resp.json().await?;
        Ok(CompletionResponse {
            content: out.response,
            usage: Some(Usage {
                prompt_tokens: out.prompt_eval_count.unwrap_or_default(),
                completion_tokens: out.eval_count.unwrap_or_default(),
            }),
        })
    }

    async fn classify(&self, req: &ClassifyRequest) -> anyhow::Result<ClassifyResponse> {
        // Ollama has no native classification endpoint; use embeddings to pick
        // the closest label, then fall back to a single-label response.
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
            model: &req.model,
            prompt: &req.text,
        };
        let resp = self
            .client
            .post(format!("{}/api/embeddings", self.base_url))
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        let out: EmbedResponseBody = resp.json().await?;
        let dimensions = out.embedding.len();
        Ok(EmbedResponse {
            vector: out.embedding,
            dimensions,
        })
    }
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    // Vectors from Ollama are usually normalized; clamp to [0, 1].
    dot.clamp(0.0, 1.0)
}
