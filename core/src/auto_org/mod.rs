//! AI auto-organization pipeline.
//!
//! **Boundary:** a staged, resumable pipeline that ingests new documents,
//! extracts text/embeddings, asks an [`crate::ai::AiProvider`] for suggested tags
//! and folder placement, and applies approved suggestions to storage, taxonomy,
//! and search.
//!
//! The AI call itself lives in the *orchestrator* (which is async); the pipeline
//! trait only consumes the resulting [`Suggestion`]s as plain data, keeping the
//! interface decoupled from any specific provider.

use crate::domain::DocumentId;

/// Current stage of a document in the pipeline (persisted for resume-ability).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Ingested,
    Extracted,
    Classified,
    Applied,
    Failed,
}

/// A proposed organization decision produced by an AI provider.
#[derive(Debug, Clone, Default)]
pub struct Suggestion {
    pub suggested_tags: Vec<String>,
    pub suggested_parent: Option<DocumentId>,
    pub confidence: f32,
    pub rationale: Option<String>,
}

/// A single unit of work for the pipeline.
#[derive(Debug, Clone)]
pub struct PipelineJob {
    pub document_id: DocumentId,
    pub stage: Stage,
    pub attempt: u32,
}

/// Interface for the auto-organization pipeline.
pub trait AutoOrganizer {
    fn enqueue(&mut self, doc: DocumentId) -> anyhow::Result<()>;

    /// Next job ready for processing, if any.
    fn next(&self) -> Option<PipelineJob>;

    /// Apply a provider's suggestion to the given job, advancing its stage.
    fn process(&mut self, job: PipelineJob, suggestion: Suggestion) -> anyhow::Result<()>;
}
