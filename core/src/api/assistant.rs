//! Flutter bridge surface for the retrieval-augmented chat assistant.
//!
//! Thin facade over [`crate::assistant::Assistant`]. It combines an in-memory
//! retrieval index (populated from Dart via [`assistant_index_document`]) with the
//! active AI provider from the shared [`crate::ai::AiManager`] to answer questions
//! with cited document references.
//!
//! Streaming answers are surfaced over [`assistant_ask_stream`]'s Dart `Stream`,
//! one token chunk per event followed by a final `Done` event carrying the
//! citations. When no AI provider is active, answers fall back to the retrieved
//! excerpts with their source references.

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::assistant::{Assistant, DocumentRef, StreamEvent};
use crate::search::{SearchIndex, SharedMemorySearch};

// ---------------------------------------------------------------------------
// Dart DTOs
// ---------------------------------------------------------------------------

/// A citation pointing at a document that supports part of an answer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentRefDto {
    pub document_id: String,
    pub excerpt: String,
}

/// A complete assistant response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantReplyDto {
    pub answer: String,
    pub references: Vec<DocumentRefDto>,
}

/// The kind of an [`AssistantStreamEventDto`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AssistantEventKindDto {
    Token,
    Done,
}

/// An incremental answer chunk (or the final citations), delivered over the
/// [`assistant_ask_stream`] Dart `Stream`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantStreamEventDto {
    pub kind: AssistantEventKindDto,
    /// Populated for [`AssistantEventKindDto::Token`].
    pub token: Option<String>,
    /// Populated for [`AssistantEventKindDto::Done`].
    pub references: Vec<DocumentRefDto>,
}

fn to_ref_dto(r: &DocumentRef) -> DocumentRefDto {
    DocumentRefDto {
        document_id: r.document_id.clone(),
        excerpt: r.excerpt.clone(),
    }
}

// ---------------------------------------------------------------------------
// Process-wide state
// ---------------------------------------------------------------------------

/// The singleton shared index handle (also owned by the assistant).
fn search_index() -> &'static Arc<SharedMemorySearch> {
    use std::sync::OnceLock;
    static SEARCH: OnceLock<Arc<SharedMemorySearch>> = OnceLock::new();
    SEARCH.get_or_init(|| Arc::new(SharedMemorySearch::new()))
}

/// The process-wide assistant (interior-mutable history), shared behind an `Arc`.
fn assistant() -> &'static Arc<Assistant> {
    use std::sync::OnceLock;
    static ASSISTANT: OnceLock<Arc<Assistant>> = OnceLock::new();
    ASSISTANT.get_or_init(|| {
        let idx: Arc<dyn SearchIndex + Send + Sync> = search_index().clone();
        Arc::new(Assistant::new(idx))
    })
}

/// Snapshot the active provider handle + model from the shared AI manager.
fn active_provider() -> anyhow::Result<(Option<Arc<dyn crate::ai::DynAiProvider>>, String)> {
    let guard = crate::ai::manager::default_manager().lock().unwrap();
    Ok((Some(guard.active_handle()), guard.active().model))
}

// ---------------------------------------------------------------------------
// Bridge functions
// ---------------------------------------------------------------------------

/// Index (or re-index) a document's extracted text into the assistant's
/// retrieval store. Call after content extraction so the chunk is searchable.
#[flutter_rust_bridge::frb(sync)]
pub fn assistant_index_document(document_id: String, text: String) {
    let mut idx = search_index().as_ref().clone();
    let _ = idx.index(&document_id, &text);
}

/// Remove a document from the assistant's retrieval store.
#[flutter_rust_bridge::frb(sync)]
pub fn assistant_remove_document(document_id: String) {
    let mut idx = search_index().as_ref().clone();
    let _ = idx.remove(&document_id);
}

/// Clear the assistant's conversational history.
#[flutter_rust_bridge::frb(sync)]
pub fn assistant_clear_history() {
    assistant().clear_history();
}

/// Answer a question with citations, using the active AI provider.
///
/// Falls back to retrieved excerpts (with source references) when no provider is
/// available.
#[flutter_rust_bridge::frb]
pub async fn assistant_ask(question: String) -> Result<AssistantReplyDto, String> {
    let (provider, model) = active_provider().map_err(|e| e.to_string())?;
    assistant()
        .ask(&question, &provider, &model)
        .await
        .map(|reply| AssistantReplyDto {
            answer: reply.answer,
            references: reply.references.iter().map(to_ref_dto).collect(),
        })
        .map_err(|e| e.to_string())
}

/// Ask a question, streaming answer tokens to Dart over `sink`, then a final
/// [`AssistantEventKindDto::Done`] event carrying the citations.
///
/// The stream stays open until generation completes (or the Dart side closes it).
#[flutter_rust_bridge::frb]
pub fn assistant_ask_stream(
    sink: crate::frb_generated::StreamSink<AssistantStreamEventDto>,
    question: String,
) {
    let assistant = assistant().clone();
    std::thread::spawn(move || {
        // Dedicated current-thread runtime: the provider completion future is
        // driven to completion on this thread, so no lock is held across an await
        // on the FFI thread.
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                let _ = sink.add_error(e.to_string());
                return;
            }
        };

        let (provider, model) = match active_provider() {
            Ok(x) => x,
            Err(e) => {
                let _ = sink.add_error(e.to_string());
                return;
            }
        };

        let result =
            rt.block_on(
                assistant.ask_stream(&question, &provider, &model, |event| match event {
                    StreamEvent::Token(t) => {
                        let _ = sink.add(AssistantStreamEventDto {
                            kind: AssistantEventKindDto::Token,
                            token: Some(t),
                            references: vec![],
                        });
                    }
                    StreamEvent::Done { references } => {
                        let _ = sink.add(AssistantStreamEventDto {
                            kind: AssistantEventKindDto::Done,
                            token: None,
                            references: references.iter().map(to_ref_dto).collect(),
                        });
                    }
                }),
            );
        if let Err(e) = result {
            let _ = sink.add_error(e.to_string());
        }
    });
}
