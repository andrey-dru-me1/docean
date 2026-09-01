//! Chat assistant with document references.
//!
//! **Boundary:** retrieval-augmented chat over the local library. The assistant
//! combines [`crate::search`] (retrieval) with an [`crate::ai::AiProvider`]
//! (generation) and returns answers together with cited document references.

use crate::domain::DocumentId;

/// A citation pointing at a document that supports part of an answer.
#[derive(Debug, Clone)]
pub struct DocumentRef {
    pub document_id: DocumentId,
    pub excerpt: String,
}

/// A complete assistant response.
#[derive(Debug, Clone)]
pub struct AssistantReply {
    pub answer: String,
    pub references: Vec<DocumentRef>,
}

/// Interface for the chat assistant.
pub trait Assistant {
    /// Answer a question, returning the answer and the documents it cites.
    fn ask(&mut self, question: &str) -> anyhow::Result<AssistantReply>;

    // Streaming generation (token-by-token) is planned; it is added when the UI
    // needs incremental output.
}
