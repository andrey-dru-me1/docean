//! Chat assistant with document references (retrieval-augmented generation).
//!
//! **Boundary:** retrieval-augmented chat over the local library. The assistant
//! combines [`crate::search`] (retrieval) with an [`crate::ai::AiProvider`]
//! (generation): the question is used to find relevant document chunks, those
//! chunks are sent to the active provider as context, and the provider's answer
//! is returned together with citations linking back to the source documents.
//!
//! When no AI provider is available, the assistant falls back to returning the
//! retrieved excerpts themselves together with their source references, so the
//! user always gets *something* grounded in their library.
//!
//! # Conversational history
//!
//! [`Assistant::ask`] and [`Assistant::ask_stream`] append both the question and
//! the resulting answer to an internal history, so follow-up questions can be
//! contextual. The provider is supplied separately in each call (it may be
//! swapped at runtime by the AI manager), allowing the assistant to be shared
//! immutably behind an `Arc`.

use std::sync::{Arc, Mutex};

use crate::ai::{ChatMessage, CompletionRequest, DynAiProvider};
use crate::domain::DocumentId;
use crate::search::{Query, SearchHit, SearchIndex};

/// A citation pointing at a document that supports part of an answer.
#[derive(Debug, Clone, PartialEq)]
pub struct DocumentRef {
    pub document_id: DocumentId,
    pub excerpt: String,
}

/// One prior turn in the conversation (used to give the provider context).
#[derive(Debug, Clone, PartialEq)]
pub struct ChatTurn {
    /// `"user"` or `"assistant"`.
    pub role: String,
    pub content: String,
}

/// A complete assistant response.
#[derive(Debug, Clone, PartialEq)]
pub struct AssistantReply {
    pub answer: String,
    pub references: Vec<DocumentRef>,
}

/// An incremental token plus the (final) citations, emitted while streaming.
#[derive(Debug, Clone, PartialEq)]
pub enum StreamEvent {
    /// A chunk of generated answer text (may be empty).
    Token(String),
    /// The generation finished; `references` is the complete, ordered citation list.
    Done { references: Vec<DocumentRef> },
}

/// A retrieval-augmented chat assistant.
///
/// Holds a boxed [`SearchIndex`] for retrieval plus the running conversation
/// history. It is `Send + Sync` and cheap to share behind an `Arc`; the provider
/// is passed in per call, so the same assistant follows whichever backend is
/// active in the AI manager.
pub struct Assistant {
    search: Arc<dyn SearchIndex + Send + Sync>,
    history: Mutex<Vec<ChatTurn>>,
    /// How many top search hits to feed the provider as context.
    top_k: usize,
    /// Maximum tokens for the generated answer.
    max_tokens: Option<u32>,
}

impl Assistant {
    /// Build an assistant over `search` with default settings (5 context chunks,
    /// uncapped answer length).
    pub fn new(search: Arc<dyn SearchIndex + Send + Sync>) -> Self {
        Self {
            search,
            history: Mutex::new(Vec::new()),
            top_k: 5,
            max_tokens: None,
        }
    }

    /// Set how many top search hits are used as context (default `5`).
    pub fn set_top_k(&mut self, top_k: usize) {
        self.top_k = top_k;
    }

    /// Cap the generated answer length in tokens.
    pub fn set_max_tokens(&mut self, max_tokens: Option<u32>) {
        self.max_tokens = max_tokens;
    }

    /// The running conversation history (oldest first).
    pub fn history(&self) -> Vec<ChatTurn> {
        self.history.lock().unwrap().clone()
    }

    /// Clear the conversation history.
    pub fn clear_history(&self) {
        self.history.lock().unwrap().clear();
    }

    /// Retrieve the top [`Self::top_k`] relevant document chunks for `question`.
    fn retrieve(&self, question: &str) -> anyhow::Result<Vec<DocumentRef>> {
        let hits = self
            .search
            .search(&Query::Text(question.to_owned()), self.top_k)?;
        Ok(hits
            .into_iter()
            .filter(|h| h.snippet.as_ref().is_some_and(|s| !s.is_empty()))
            .map(DocumentRef::from_hit)
            .collect())
    }

    /// Build the provider messages: a grounded system prompt, prior history, and
    /// the current question framed with the retrieved context.
    fn build_messages(
        &self,
        snapshot: &[ChatTurn],
        question: &str,
        refs: &[DocumentRef],
    ) -> Vec<ChatMessage> {
        let mut messages = vec![ChatMessage {
            role: "system".to_owned(),
            content: RAG_SYSTEM_PROMPT.to_owned(),
        }];
        for turn in snapshot {
            messages.push(ChatMessage {
                role: turn.role.clone(),
                content: turn.content.clone(),
            });
        }
        let context = format_context(refs);
        messages.push(ChatMessage {
            role: "user".to_owned(),
            content: format_answer_prompt(question, &context),
        });
        messages
    }

    /// Answer a question, returning the answer and the documents it cites.
    ///
    /// This is the non-streaming form; it appends the exchange to the internal
    /// conversational history. When `provider` is `None`, it falls back to the
    /// retrieved excerpts.
    pub async fn ask(
        &self,
        question: &str,
        provider: &Option<Arc<dyn DynAiProvider>>,
        model: &str,
    ) -> anyhow::Result<AssistantReply> {
        let refs = self.retrieve(question)?;
        let snapshot = {
            let mut h = self.history.lock().unwrap();
            h.push(ChatTurn {
                role: "user".to_owned(),
                content: question.to_owned(),
            });
            h.clone()
        };

        let reply = match provider {
            Some(p) => {
                let messages = self.build_messages(&snapshot, question, &refs);
                let resp = p
                    .complete(CompletionRequest {
                        model: model.to_owned(),
                        messages,
                        max_tokens: self.max_tokens,
                        temperature: Some(0.2),
                    })
                    .await?;
                AssistantReply {
                    answer: rewrite_citations(&resp.content, &refs),
                    references: refs,
                }
            }
            None => fallback_reply(&refs),
        };

        self.history.lock().unwrap().push(ChatTurn {
            role: "assistant".to_owned(),
            content: reply.answer.clone(),
        });
        Ok(reply)
    }

    /// Answer a question, streaming decoded answer tokens to `on_token`, then
    /// emitting the final citations via [`StreamEvent::Done`].
    ///
    /// Providers that cannot stream return their whole answer as a single token
    /// chunk. Like [`Assistant::ask`], this appends to the history. On any error
    /// or when no provider is available it falls back to excerpts (delivered as a
    /// single token followed by `Done`).
    pub async fn ask_stream<F>(
        &self,
        question: &str,
        provider: &Option<Arc<dyn DynAiProvider>>,
        model: &str,
        mut on_token: F,
    ) -> anyhow::Result<Vec<DocumentRef>>
    where
        F: FnMut(StreamEvent),
    {
        let refs = self.retrieve(question)?;
        let snapshot = {
            let mut h = self.history.lock().unwrap();
            h.push(ChatTurn {
                role: "user".to_owned(),
                content: question.to_owned(),
            });
            h.clone()
        };

        let answer = match provider {
            Some(p) => {
                let messages = self.build_messages(&snapshot, question, &refs);
                match stream_completion(
                    p.as_ref(),
                    CompletionRequest {
                        model: model.to_owned(),
                        messages,
                        max_tokens: self.max_tokens,
                        temperature: Some(0.2),
                    },
                )
                .await
                {
                    Ok(tokens) => {
                        let mut acc = String::new();
                        for token in tokens {
                            acc.push_str(&token);
                            on_token(StreamEvent::Token(token));
                        }
                        rewrite_citations(&acc, &refs)
                    }
                    Err(_) => {
                        let fb = fallback_text(&refs);
                        on_token(StreamEvent::Token(fb.clone()));
                        fb
                    }
                }
            }
            None => {
                let fb = fallback_text(&refs);
                on_token(StreamEvent::Token(fb.clone()));
                fb
            }
        };

        self.history.lock().unwrap().push(ChatTurn {
            role: "assistant".to_owned(),
            content: answer,
        });
        on_token(StreamEvent::Done {
            references: refs.clone(),
        });
        Ok(refs)
    }
}

impl DocumentRef {
    fn from_hit(hit: SearchHit) -> Self {
        DocumentRef {
            document_id: hit.document_id,
            excerpt: hit.snippet.unwrap_or_default(),
        }
    }
}

/// The system prompt instructing the provider to answer from context and emit
/// `[n]` citation markers.
const RAG_SYSTEM_PROMPT: &str = "\
You are Docean's document assistant. Answer the user's question using only the \
retrieved document excerpts provided with each message. When you use information \
from an excerpt, cite it inline with a bracketed number matching its position in \
the provided context (e.g. [1], [2]). Do not fabricate facts not present in the \
excerpts. If the excerpts are insufficient, say so.\n";

/// Render retrieved excerpts as a numbered context block the provider can cite.
fn format_context(refs: &[DocumentRef]) -> String {
    let mut out = String::from("Context (number: excerpt):\n");
    for (i, r) in refs.iter().enumerate() {
        out.push_str(&format!(
            "[{}] (document {}) {}\n",
            i + 1,
            r.document_id,
            r.excerpt
        ));
    }
    out
}

/// Wrap the question with an instruction to answer and cite, plus the context.
fn format_answer_prompt(question: &str, context: &str) -> String {
    format!(
        "Answer the following question using the context below and cite sources \
         inline with [n] markers.\n\nQuestion: {question}\n\n{context}"
    )
}

/// Replace provider-issued `[n]` markers with the stable `⟨src doc⟩` citation form.
fn rewrite_citations(answer: &str, refs: &[DocumentRef]) -> String {
    let mut out = answer.to_owned();
    for (i, r) in refs.iter().enumerate() {
        let marker = format!("[{}]", i + 1);
        let replacement = format!("⟨src {}⟩", r.document_id);
        out = out.replace(&marker, &replacement);
    }
    out
}

/// The fallback answer: the retrieved excerpts laid out with their sources.
fn fallback_text(refs: &[DocumentRef]) -> String {
    if refs.is_empty() {
        return "I couldn't find any matching documents in your library.".to_owned();
    }
    let mut out =
        String::from("No AI provider is available. Here are the matching document excerpts:\n");
    for r in refs {
        out.push_str(&format!("⟨src {}⟩ {}\n", r.document_id, r.excerpt));
    }
    out
}

fn fallback_reply(refs: &[DocumentRef]) -> AssistantReply {
    AssistantReply {
        answer: fallback_text(refs),
        references: refs.to_vec(),
    }
}

/// Stream a completion token-by-token.
///
/// This default adapter yields the full response as a single chunk (providers
/// that expose native streaming can be special-cased later by the caller).
async fn stream_completion(
    provider: &dyn DynAiProvider,
    req: CompletionRequest,
) -> anyhow::Result<Vec<String>> {
    let resp = provider.complete(req).await?;
    if resp.content.is_empty() {
        Ok(Vec::new())
    } else {
        Ok(vec![resp.content])
    }
}

#[cfg(test)]
mod tests;
