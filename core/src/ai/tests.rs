//! Tests for the AI provider abstraction, driven by a mock provider.
//!
//! `MockProvider` implements [`AiProvider`] with deterministic, in-memory
//! behaviour so the manager's dispatch and configuration logic can be verified
//! without any network or local model.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use crate::ai::config::{ConfigStore, ProviderConfig, ProviderKind};
use crate::ai::{
    AiManager, AiProvider, BuiltinProvider, Classification, ClassifyRequest, ClassifyResponse,
    CompletionRequest, CompletionResponse, EmbedRequest, EmbedResponse, GenerateRequest, Usage,
};

/// A deterministic mock provider.
struct MockProvider {
    /// Number of calls observed, for asserting dispatch happened.
    calls: Arc<AtomicUsize>,
    /// Prefix prepended to generated content to identify this provider.
    tag: &'static str,
}

impl MockProvider {
    fn new(tag: &'static str) -> (Self, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        (
            MockProvider {
                calls: calls.clone(),
                tag,
            },
            calls,
        )
    }
}

impl AiProvider for MockProvider {
    fn name(&self) -> &'static str {
        self.tag
    }

    async fn complete(&self, req: &CompletionRequest) -> anyhow::Result<CompletionResponse> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let joined = req
            .messages
            .iter()
            .map(|m| m.content.clone())
            .collect::<Vec<_>>()
            .join(" | ");
        Ok(CompletionResponse {
            content: format!("[{tag}] {joined}", tag = self.tag),
            usage: Some(Usage {
                prompt_tokens: 1,
                completion_tokens: 1,
            }),
        })
    }

    async fn generate(&self, req: &GenerateRequest) -> anyhow::Result<CompletionResponse> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(CompletionResponse {
            content: format!("[{tag}] {prompt}", tag = self.tag, prompt = req.prompt),
            usage: Some(Usage {
                prompt_tokens: 1,
                completion_tokens: 1,
            }),
        })
    }

    async fn classify(&self, req: &ClassifyRequest) -> anyhow::Result<ClassifyResponse> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let label = req.labels.first().cloned().unwrap_or_default();
        Ok(ClassifyResponse {
            label: label.clone(),
            scores: req
                .labels
                .iter()
                .map(|l| Classification {
                    label: l.clone(),
                    score: 1.0,
                })
                .collect(),
        })
    }

    async fn embed(&self, req: &EmbedRequest) -> anyhow::Result<EmbedResponse> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let dims = req.text.len().max(1);
        Ok(EmbedResponse {
            vector: vec![0.5; dims],
            dimensions: dims,
        })
    }
}

/// Build a manager whose active provider is the mock, over a temp config dir.
fn mock_manager() -> (AiManager, Arc<AtomicUsize>, tempdir::TempDir) {
    let dir = tempdir::TempDir::new("docean-ai-test").unwrap();
    let store = ConfigStore::new(dir.path().to_path_buf());
    let (mock, calls) = MockProvider::new("mock");
    let manager = AiManager::with_provider(store, crate::ai::erase(mock));
    (manager, calls, dir)
}

#[test]
fn mock_generate_round_trips() {
    let (mgr, calls, _dir) = mock_manager();
    let out = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(mgr.generate(&GenerateRequest {
            prompt: "hi".to_owned(),
            ..Default::default()
        }))
        .unwrap();
    assert_eq!(out.content, "[mock] hi");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn mock_classify_returns_first_label() {
    let (mgr, calls, _dir) = mock_manager();
    let out = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(mgr.classify(&ClassifyRequest {
            model: "m".to_owned(),
            text: "x".to_owned(),
            labels: vec!["a".to_owned(), "b".to_owned()],
        }))
        .unwrap();
    assert_eq!(out.label, "a");
    assert_eq!(out.scores.len(), 2);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn mock_embed_dimension_matches_text_len() {
    let (mgr, calls, _dir) = mock_manager();
    let out = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(mgr.embed(&EmbedRequest {
            model: "m".to_owned(),
            text: "abc".to_owned(),
        }))
        .unwrap();
    assert_eq!(out.dimensions, 3);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn mock_complete_joins_messages() {
    let (mgr, calls, _dir) = mock_manager();
    let out = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(mgr.complete(&CompletionRequest {
            model: "m".to_owned(),
            messages: vec![
                crate::ai::ChatMessage::user("hello"),
                crate::ai::ChatMessage::user("world"),
            ],
            ..Default::default()
        }))
        .unwrap();
    assert_eq!(out.content, "[mock] hello | world");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn config_select_persists_and_switches() {
    let dir = tempdir::TempDir::new("docean-ai-config").unwrap();
    let store = ConfigStore::new(dir.path().to_path_buf());
    let (mock, _calls) = MockProvider::new("mock");
    let mut mgr = AiManager::with_provider(store, crate::ai::erase(mock));

    let active = mgr.select("ollama", "llama3.2").unwrap();
    assert_eq!(active.kind, "ollama");
    assert_eq!(active.model, "llama3.2");

    let cfg = mgr.config();
    assert_eq!(cfg.active_provider.as_deref(), Some("ollama"));
    assert_eq!(cfg.providers["ollama"].model, "llama3.2");
}

#[test]
fn select_unknown_kind_errors() {
    let dir = tempdir::TempDir::new("docean-ai-unknown").unwrap();
    let store = ConfigStore::new(dir.path().to_path_buf());
    let (mock, _calls) = MockProvider::new("mock");
    let mut mgr = AiManager::with_provider(store, crate::ai::erase(mock));
    assert!(mgr.select("bogus", "x").is_err());
}

#[test]
fn upsert_provider_persists() {
    let dir = tempdir::TempDir::new("docean-ai-upsert").unwrap();
    let store = ConfigStore::new(dir.path().to_path_buf());
    let (mock, _calls) = MockProvider::new("mock");
    let mut mgr = AiManager::with_provider(store, crate::ai::erase(mock));

    let mut cfg = ProviderConfig::default_for(ProviderKind::OpenAi);
    cfg.model = "deepseek-chat".to_owned();
    mgr.upsert_provider(cfg.clone()).unwrap();

    let stored = mgr.config().providers["openai"].clone();
    assert_eq!(stored.model, "deepseek-chat");
    assert_eq!(stored.kind, ProviderKind::OpenAi);
}

#[test]
fn builtin_provider_generates_without_network() {
    let dir = tempdir::TempDir::new("docean-builtin-gen").unwrap();
    let provider = BuiltinProvider::new(dir.path().join("models"));
    let out = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(provider.generate(&GenerateRequest {
            prompt: "what is this document about".to_owned(),
            ..Default::default()
        }))
        .unwrap();
    assert!(!out.content.is_empty());
    assert!(out.usage.is_some());
}

#[test]
fn builtin_classify_picks_closest_label() {
    let dir = tempdir::TempDir::new("docean-builtin-class").unwrap();
    let provider = BuiltinProvider::new(dir.path().join("models"));
    let out = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(provider.classify(&ClassifyRequest {
            model: "docean-tiny".to_owned(),
            text: "invoice for office supplies".to_owned(),
            labels: vec!["invoice".to_owned(), "recipe".to_owned()],
        }))
        .unwrap();
    assert_eq!(out.label, "invoice");
    assert_eq!(out.scores.len(), 2);
}

/// Minimal tempdir helper to avoid pulling in a dev-dependency.
mod tempdir {
    use std::path::{Path, PathBuf};

    pub struct TempDir(PathBuf);

    impl TempDir {
        pub fn new(name: &str) -> std::io::Result<Self> {
            let mut p = std::env::temp_dir();
            p.push(format!(
                "{name}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(&p)?;
            Ok(TempDir(p))
        }

        pub fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}
