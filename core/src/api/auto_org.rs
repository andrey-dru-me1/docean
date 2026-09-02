//! Flutter bridge surface for the automatic document organization pipeline.
//!
//! Exposes the deterministic classic-ML organizer and the optional generative
//! filename tier. The classic-ML path runs synchronously and never touches the
//! AI layer; the generative rename is an explicit, separate async call gated on
//! a configured provider.

use crate::api::storage::DocumentRepository;
use crate::auto_org::config::{OrgConfig, OrgPlan};
use crate::auto_org::generative::generate_filename;
use crate::auto_org::organizer::{Corpus, CorpusDoc, DeterministicOrganizer};
use crate::auto_org::rules::RuleSet;
use crate::domain::PathAssignment;
use crate::storage::DocumentQuery;

/// Build an in-memory corpus from every document in the repository, including
/// their extracted text content (falling back to the title when no content).
fn build_corpus(repo: &DocumentRepository) -> Result<Corpus, String> {
    let docs = repo.query(DocumentQuery::default())?;
    let mut corpus = Corpus::default();
    for doc in docs {
        let text = repo
            .get_content(doc.id.clone())?
            .map(|c| c.text)
            .filter(|t| !t.trim().is_empty())
            .unwrap_or_else(|| doc.title.clone());
        corpus.docs.push(CorpusDoc {
            id: doc.id,
            title: doc.title,
            text,
            mime_type: doc.mime_type,
            tags: doc.tags,
        });
    }
    Ok(corpus)
}

/// Run the deterministic (non-generative) organizer on `document_id` and apply
/// the resulting [`OrgPlan`] to the persisted metadata.
///
/// This is the **auto-organization entry point used by the ingestion pipeline**:
/// it takes the repository by *reference* (no ownership transfer, so the shared
/// `Arc<Mutex<_>>` handle is not disposed), runs [`DeterministicOrganizer`]
/// against the current corpus, and then durably applies the suggestions:
///
/// * **Tags** — replace the document's tags with `plan.tags`.
/// * **Title** — set it to `plan.suggested_title` when present and non-empty.
///   The original source file on disk is **never** renamed, only the document's
///   title metadata.
/// * **Placement** — when the plan resolves a hierarchy path, assign the
///   document to it (many-to-many) so it is browsable and searchable there too.
///
/// The pipeline is deterministic and needs **no AI provider**: [`OrgConfig`]
/// defaults disable the generative tier, falling back to the keyword rules in
/// [`crate::auto_org`]. Returns the applied plan (callers may log it or use it
/// to feed the search index).
pub(crate) fn organize_document(
    repo: &DocumentRepository,
    document_id: &str,
    config: OrgConfig,
) -> Result<OrgPlan, String> {
    let corpus = build_corpus(repo)?;
    let organizer = DeterministicOrganizer::new(config);
    let plan = organizer.organize(&corpus, document_id);

    let mut doc = repo.get(document_id.to_owned())?;
    doc.tags = plan.tags.clone();
    if let Some(title) = plan.suggested_title.as_ref().filter(|t| !t.trim().is_empty()) {
        // Trim trailing separators: templates like `{keywords}-{date}` can leave
        // a dangling `-` when a placeholder (e.g. `{date}`) is empty. Never let
        // the trimming produce an empty title — fall back to the raw suggestion.
        let trimmed = title.trim().trim_end_matches(['-', '_', '.', ' ']).to_owned();
        doc.title = if trimmed.is_empty() { title.clone() } else { trimmed };
    }
    repo.put(doc, repo.read_bytes(document_id.to_owned())?)?;

    if let Some(path) = plan.suggested_path.as_ref().filter(|p| !p.trim().is_empty()) {
        repo.assign_path(PathAssignment {
            document_id: document_id.to_owned(),
            path: path.clone(),
            position: 0,
        })?;
    }

    Ok(plan)
}

/// Run the deterministic (non-generative) organizer on `document_id`, returning
/// the [`OrgPlan`] of suggested tags, placement, rename, and dedup.
#[flutter_rust_bridge::frb(sync)]
pub fn auto_org_organize(
    repo: DocumentRepository,
    document_id: String,
    config: OrgConfig,
) -> Result<OrgPlan, String> {
    // Build a fresh corpus snapshot from the repository (borrowed, then released)
    // so the shared handle is never moved/disposed across the FRB boundary.
    let corpus = build_corpus(&repo)?;
    let organizer = DeterministicOrganizer::new(config);
    Ok(organizer.organize(&corpus, &document_id))
}

/// Regenerate just the filename via the generative LLM tier, returning the new
/// suggested title. Fails if no generative provider is configured; the caller
/// should fall back to the deterministic template title.
#[flutter_rust_bridge::frb]
pub async fn auto_org_generate_filename(
    repo: DocumentRepository,
    document_id: String,
    model: String,
) -> Result<String, String> {
    let corpus = build_corpus(&repo)?;
    let Some(doc) = corpus.docs.iter().find(|d| d.id == document_id) else {
        return Err(format!("document {document_id} not found"));
    };

    let (handle, active_model) = {
        let guard = crate::ai::manager::default_manager().lock().unwrap();
        let model = if model.is_empty() {
            guard.active().model
        } else {
            model
        };
        (guard.active_handle(), model)
    };

    generate_filename(&handle, &active_model, doc)
        .await
        .map_err(|e| e.to_string())
}

/// A convenience default [`OrgConfig`] for Dart, populated with the default rule
/// set and templates.
#[flutter_rust_bridge::frb(sync)]
pub fn auto_org_default_config() -> OrgConfig {
    OrgConfig::default()
}

/// A convenience default [`RuleSet`] (empty placement rules + `/inbox` fallback).
#[flutter_rust_bridge::frb(sync)]
pub fn auto_org_default_rules() -> RuleSet {
    RuleSet {
        placement: Vec::new(),
        fallback_path: Some("/inbox".to_owned()),
        filename_template: RuleSet::default_template(),
    }
}
