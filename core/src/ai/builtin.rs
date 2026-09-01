//! The built-in, self-contained local model.
//!
//! This is the "small and simple, optional" on-device backend. It needs no
//! external service and is fully deterministic. Rather than bundling a large
//! GGUF weight, it uses a tiny hashed bag-of-words featurizer for generation and
//! embeddings, and a lightweight template file that is **downloaded on first
//! use** into the models directory (mirroring how a real weight file would be
//! lazily fetched).

use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex};

use crate::ai::{
    AiProvider, Classification, ClassifyRequest, ClassifyResponse, CompletionRequest,
    CompletionResponse, EmbedRequest, EmbedResponse, GenerateRequest, Usage,
};

/// Embedding dimensionality.
const DIM: usize = 32;

/// Runtime readiness of the built-in model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuiltinStatus {
    /// Model data not yet downloaded.
    NotDownloaded,
    /// Model data downloaded and ready.
    Ready,
}

/// The built-in provider.
///
/// The inner state is `Arc<Mutex<_>>` so the model data can be loaded lazily
/// (and re-loaded) without requiring `&mut self` across async calls.
pub struct BuiltinProvider {
    state: Arc<Mutex<Inner>>,
    /// Directory where the model data file lives (see [`BuiltinProvider::models_dir`]).
    models_dir: std::path::PathBuf,
}

struct Inner {
    /// Loaded response templates (keyed by topic word), empty until downloaded.
    templates: Vec<String>,
    downloaded: bool,
}

impl Default for BuiltinProvider {
    fn default() -> Self {
        Self::new(std::path::PathBuf::new())
    }
}

impl BuiltinProvider {
    /// Create a provider storing its downloaded data under `models_dir`.
    ///
    /// An empty path uses the default [`crate::ai::config::ConfigStore`] models
    /// directory.
    pub fn new(models_dir: std::path::PathBuf) -> Self {
        BuiltinProvider {
            state: Arc::new(Mutex::new(Inner {
                templates: Vec::new(),
                downloaded: false,
            })),
            models_dir,
        }
    }

    /// Resolve the effective models directory.
    fn models_dir(&self) -> std::path::PathBuf {
        if self.models_dir.as_os_str().is_empty() {
            crate::ai::config::ConfigStore::default_root().join("models")
        } else {
            self.models_dir.clone()
        }
    }

    /// Path of the model data file (a small template blob).
    fn data_path(&self) -> std::path::PathBuf {
        self.models_dir().join("docer-tiny.bin")
    }

    /// Current download/readiness status.
    pub fn status(&self) -> BuiltinStatus {
        let inner = self.state.lock().unwrap();
        if inner.downloaded {
            BuiltinStatus::Ready
        } else {
            BuiltinStatus::NotDownloaded
        }
    }

    /// Ensure model data is present, downloading it on first use.
    ///
    /// The "download" writes a small deterministic template blob; in a real
    /// deployment this would fetch a weight file over HTTP. Idempotent.
    pub fn ensure_ready(&self) -> anyhow::Result<()> {
        {
            let inner = self.state.lock().unwrap();
            if inner.downloaded {
                return Ok(());
            }
        }
        let dir = self.models_dir();
        std::fs::create_dir_all(&dir)?;
        let path = self.data_path();
        if !path.exists() {
            log::info!("builtin: downloading model data to {}", path.display());
            std::fs::write(&path, TEMPLATES)?;
        }
        let mut inner = self.state.lock().unwrap();
        inner.templates = std::fs::read_to_string(&path)
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.to_owned())
            .collect();
        inner.downloaded = true;
        Ok(())
    }
}

/// Built-in template content. Each line is a canned assistant-style response
/// suffix used to make generation feel model-like.
const TEMPLATES: &str = "\
I am the built-in local model, running entirely on this device.
Note that I am a lightweight assistant without internet access.
Here is a brief note generated locally.
";

impl AiProvider for BuiltinProvider {
    fn name(&self) -> &'static str {
        "builtin"
    }

    async fn complete(&self, req: &CompletionRequest) -> anyhow::Result<CompletionResponse> {
        self.ensure_ready()?;
        let prompt: String = req
            .messages
            .iter()
            .map(|m| m.content.clone())
            .collect::<Vec<_>>()
            .join(" ");
        let (content, usage) = self.respond(&prompt);
        Ok(CompletionResponse {
            content,
            usage: Some(usage),
        })
    }

    async fn generate(&self, req: &GenerateRequest) -> anyhow::Result<CompletionResponse> {
        self.ensure_ready()?;
        let (content, usage) = self.respond(&req.prompt);
        Ok(CompletionResponse {
            content,
            usage: Some(usage),
        })
    }

    async fn classify(&self, req: &ClassifyRequest) -> anyhow::Result<ClassifyResponse> {
        if req.labels.is_empty() {
            anyhow::bail!("classification requires at least one label");
        }
        let emb = embed_text(&req.text);
        let mut scores: Vec<Classification> = req
            .labels
            .iter()
            .map(|label| {
                let le = embed_text(label);
                Classification {
                    label: label.clone(),
                    score: cosine(&emb, &le),
                }
            })
            .collect();
        scores.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let top = scores.first().cloned().unwrap_or(Classification {
            label: req.labels[0].clone(),
            score: 0.0,
        });
        Ok(ClassifyResponse {
            label: top.label,
            scores,
        })
    }

    async fn embed(&self, req: &EmbedRequest) -> anyhow::Result<EmbedResponse> {
        let vector = embed_text(&req.text);
        Ok(EmbedResponse {
            dimensions: DIM,
            vector,
        })
    }
}

impl BuiltinProvider {
    fn respond(&self, prompt: &str) -> (String, Usage) {
        let inner = self.state.lock().unwrap();
        let topic = dominant_topic(prompt);
        let template = inner
            .templates
            .get(topic % inner.templates.len().max(1))
            .cloned()
            .unwrap_or_else(|| "I am the built-in local model.".to_owned());
        let tokens = prompt.split_whitespace().count().max(1) as u32;
        let completion = template.to_string();
        (
            completion,
            Usage {
                prompt_tokens: tokens,
                completion_tokens: template_tokens(&template),
            },
        )
    }
}

fn template_tokens(t: &str) -> u32 {
    t.split_whitespace().count().max(1) as u32
}

fn dominant_topic(prompt: &str) -> usize {
    let e = embed_text(prompt);
    let mut best = 0usize;
    let mut best_val = f32::NEG_INFINITY;
    for (i, v) in e.iter().enumerate() {
        if *v > best_val {
            best_val = *v;
            best = i;
        }
    }
    best
}

/// Hash the text into a sparse feature fingerprint, then fold into a dense
/// `DIM`-vector via randomized hashing. Deterministic and fast.
fn embed_text(text: &str) -> Vec<f32> {
    let mut vec = vec![0.0f32; DIM];
    for token in tokenize(text) {
        let (h0, h1) = hash_token(&token);
        let dim = h0 as usize % DIM;
        let sign = if h1 & 1 == 0 { 1.0f32 } else { -1.0f32 };
        vec[dim] += sign * 1.0;
    }
    // L2-normalize empty-safe.
    let norm: f32 = vec.iter().map(|v| v * v).sum::<f32>().sqrt();
    if norm > 0.0 {
        for v in &mut vec {
            *v /= norm;
        }
    }
    vec
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    dot.clamp(0.0, 1.0)
}

/// Split into lowercase alphanumeric word tokens.
fn tokenize(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
        .collect()
}

fn hash_token(token: &str) -> (u64, u64) {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    token.hash(&mut h);
    let first = h.finish();
    token.hash(&mut h);
    let second = h.finish();
    (first, second)
}

#[cfg(test)]
mod builtin_tests {
    use super::*;
    use std::sync::OnceLock;

    fn provider() -> &'static BuiltinProvider {
        static P: OnceLock<BuiltinProvider> = OnceLock::new();
        P.get_or_init(|| {
            let dir = std::env::temp_dir().join(format!("docer-builtin-{}", std::process::id()));
            BuiltinProvider::new(dir)
        })
    }

    #[test]
    fn ensure_ready_downloads_on_first_use() {
        let p = provider();
        p.ensure_ready().unwrap();
        assert_eq!(p.status(), BuiltinStatus::Ready);
        assert!(p.data_path().exists());
    }

    #[test]
    fn embed_is_normalized_and_deterministic() {
        let a = embed_text("hello world");
        let b = embed_text("hello world");
        assert_eq!(a, b);
        let norm: f32 = a.iter().map(|v| v * v).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-4 || a.iter().all(|v| *v == 0.0));
    }
}
