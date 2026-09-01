//! Tests for the retrieval-augmented assistant, driven by a mock provider and a
//! mock search index.
//!
//! The mock provider emits a citation-bearing answer when the retrieved context
//! is present, so the tests can assert that citations are produced and linked back
//! to the source document ids.

use std::sync::Arc;

use crate::ai::{AiProvider, CompletionRequest, CompletionResponse, Usage};
use crate::assistant::{Assistant, DocumentRef, StreamEvent};
use crate::domain::DocumentId;
use crate::search::{Query, SearchHit, SearchIndex};

/// A deterministic mock AI provider that cites context positions.
///
/// It inspects the last user message; if that message embeds `[n] (document <id>)`
/// context lines, it answers with a canned sentence that cites `[1]`, so citation
/// rewriting to `<src <id>>` can be asserted.
struct MockProvider {
    tag: &'static str,
}

impl AiProvider for MockProvider {
    fn name(&self) -> &'static str {
        self.tag
    }

    async fn complete(&self, req: &CompletionRequest) -> anyhow::Result<CompletionResponse> {
        // Collect the document ids present in the context block.
        let mut ids: Vec<String> = Vec::new();
        for msg in &req.messages {
            if msg.role == "user" {
                for line in msg.content.lines() {
                    // Context lines look like `[1] (document doc-1) <excerpt>`.
                    if let Some(rest) = line.strip_prefix('[') {
                        if let Some(close) = rest.find(']') {
                            if rest[..close].parse::<usize>().is_ok() {
                                if let Some(start) = rest[close..].find("(document ") {
                                    let idpart = &rest[close + start + "(document ".len()..];
                                    let id = idpart.split(')').next().unwrap_or("").to_owned();
                                    ids.push(id);
                                }
                            }
                        }
                    }
                }
            }
        }
        let content = if ids.is_empty() {
            "I have nothing to cite.".to_owned()
        } else {
            // Cite the first context excerpt with [1].
            format!("Based on the documents: [1] {}. End.", ids.join(","))
        };
        Ok(CompletionResponse {
            content,
            usage: Some(Usage {
                prompt_tokens: 1,
                completion_tokens: 1,
            }),
        })
    }

    async fn generate(
        &self,
        _req: &crate::ai::GenerateRequest,
    ) -> anyhow::Result<CompletionResponse> {
        unreachable!("assistant uses complete, not generate")
    }

    async fn classify(
        &self,
        req: &crate::ai::ClassifyRequest,
    ) -> anyhow::Result<crate::ai::ClassifyResponse> {
        Ok(crate::ai::ClassifyResponse {
            label: req.labels.first().cloned().unwrap_or_default(),
            scores: Vec::new(),
        })
    }

    async fn embed(
        &self,
        _req: &crate::ai::EmbedRequest,
    ) -> anyhow::Result<crate::ai::EmbedResponse> {
        Ok(crate::ai::EmbedResponse {
            vector: Vec::new(),
            dimensions: 0,
        })
    }
}

/// A search index returning a fixed set of hits for any query.
struct MockSearch {
    hits: Vec<SearchHit>,
}

impl SearchIndex for MockSearch {
    fn index(&mut self, _doc: &DocumentId, _text: &str) -> anyhow::Result<()> {
        Ok(())
    }

    fn remove(&mut self, _doc: &DocumentId) -> anyhow::Result<()> {
        Ok(())
    }

    fn search(&self, _query: &Query, _limit: usize) -> anyhow::Result<Vec<SearchHit>> {
        Ok(self.hits.clone())
    }
}

fn hits() -> Vec<SearchHit> {
    vec![
        SearchHit {
            document_id: "doc-1".to_owned(),
            score: 1.0,
            snippet: Some("doc-1 says the sky is blue.".to_owned()),
        },
        SearchHit {
            document_id: "doc-2".to_owned(),
            score: 0.8,
            snippet: Some("doc-2 adds that it is daytime.".to_owned()),
        },
    ]
}

fn search() -> Arc<dyn SearchIndex + Send + Sync> {
    Arc::new(MockSearch { hits: hits() })
}

fn provider() -> Option<Arc<dyn crate::ai::DynAiProvider>> {
    Some(crate::ai::erase(MockProvider { tag: "mock" }))
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
}

#[test]
fn ask_produces_citations_linked_to_sources() {
    let a = Assistant::new(search());
    let reply = runtime()
        .block_on(a.ask("what color is the sky?", &provider(), "mock-model"))
        .unwrap();

    // The mock cites [1], which must be rewritten to the source doc id.
    assert!(
        reply.answer.contains("⟨src doc-1⟩"),
        "answer: {}",
        reply.answer
    );
    assert!(
        !reply.answer.contains("[1]"),
        "marker should be rewritten: {}",
        reply.answer
    );

    // References point at the retrieved documents.
    assert_eq!(reply.references.len(), 2);
    assert_eq!(reply.references[0].document_id, "doc-1");
    assert_eq!(reply.references[1].document_id, "doc-2");
}

#[test]
fn ask_appends_to_history() {
    let a = Assistant::new(search());
    let _ = runtime().block_on(a.ask("hi", &provider(), "m")).unwrap();
    let h = a.history();
    assert_eq!(h.len(), 2);
    assert_eq!(h[0].role, "user");
    assert_eq!(h[1].role, "assistant");
}

#[test]
fn ask_falls_back_to_excerpts_without_provider() {
    let a = Assistant::new(search());
    let reply = runtime().block_on(a.ask("anything", &None, "")).unwrap();

    assert!(reply.answer.contains("No AI provider is available"));
    assert!(reply.answer.contains("⟨src doc-1⟩"));
    assert!(reply.answer.contains("doc-1 says the sky is blue."));
    assert_eq!(reply.references.len(), 2);
}

#[test]
fn fallback_with_no_hits_is_graceful() {
    let empty: Arc<dyn SearchIndex + Send + Sync> = Arc::new(MockSearch { hits: vec![] });
    let a = Assistant::new(empty);
    let reply = runtime().block_on(a.ask("zzz", &None, "")).unwrap();
    assert!(reply.answer.contains("couldn't find any matching"));
    assert!(reply.references.is_empty());
}

#[test]
fn stream_emits_tokens_then_done_with_citations() {
    let a = Assistant::new(search());
    let mut events: Vec<StreamEvent> = Vec::new();
    let refs = runtime()
        .block_on(
            a.ask_stream("what color is the sky?", &provider(), "mock-model", |e| {
                events.push(e)
            }),
        )
        .unwrap();

    assert_eq!(refs.len(), 2);

    // Last event must be Done carrying the citations.
    match events.last().unwrap() {
        StreamEvent::Done { references } => {
            assert_eq!(references.len(), 2);
            assert_eq!(references[0].document_id, "doc-1");
        }
        other => panic!("expected Done, got {other:?}"),
    }

    // At least one Token was emitted.
    assert!(events.iter().any(|e| matches!(e, StreamEvent::Token(_))));
}

#[test]
fn stream_falls_back_without_provider() {
    let a = Assistant::new(search());
    let mut events: Vec<StreamEvent> = Vec::new();
    let refs = runtime()
        .block_on(a.ask_stream("anything", &None, "", |e| events.push(e)))
        .unwrap();

    assert_eq!(refs.len(), 2);
    let joined: String = events
        .iter()
        .filter_map(|e| match e {
            StreamEvent::Token(t) => Some(t.as_str()),
            _ => None,
        })
        .collect();
    assert!(joined.contains("No AI provider is available"));
    assert!(joined.contains("⟨src doc-1⟩"));
}

#[test]
fn rewrite_citations_handles_multiple_markers() {
    let refs = hits()
        .iter()
        .map(|h| DocumentRef {
            document_id: h.document_id.clone(),
            excerpt: h.snippet.clone().unwrap_or_default(),
        })
        .collect::<Vec<_>>();
    let answer = "See [1] and [2] for details.";
    let out = super::rewrite_citations(answer, &refs);
    assert_eq!(out, "See ⟨src doc-1⟩ and ⟨src doc-2⟩ for details.");
}
