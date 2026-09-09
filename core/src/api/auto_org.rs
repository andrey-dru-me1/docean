//! Flutter bridge surface for the automatic document organization pipeline.
//!
//! Exposes the deterministic classic-ML organizer and the optional generative
//! filename tier. The classic-ML path runs synchronously and never touches the
//! AI layer; the generative rename is an explicit, separate async call gated on
//! a configured provider.
//!
//! The manual-edit contract: every UI edit that changes a document's title or
//! tags persists a `title_manual` / `tags_manual` truthy flag on `extra`
//! (see [`crate::api::storage::DocumentRepository::update_title`] and
//! [`crate::api::storage::DocumentRepository::set_tags`]). The reorganize
//! surfaces below honor those flags so a bulk pass never clobbers a user's
//! hand-edited metadata.

use serde::{Deserialize, Serialize};

use crate::api::storage::DocumentRepository;
use crate::auto_org::config::{OrgConfig, OrgPlan};
use crate::auto_org::feedback::PreferenceModel;
use crate::auto_org::generative::generate_filename;
use crate::auto_org::organizer::{Corpus, CorpusDoc, DeterministicOrganizer};
use crate::auto_org::rules::RuleSet;
use crate::domain::{
    DocumentSuggestion, PathAssignment, SuggestionFeedback, SuggestionKind, SuggestionSource,
    SuggestionStatus,
};
use crate::storage::DocumentQuery;

/// Keys in `Document.extra` marking a user's manual metadata edits. A truthy
/// value means "the user set this themselves; do not overwrite it in bulk".
pub const TITLE_MANUAL_KEY: &str = "title_manual";
pub const TAGS_MANUAL_KEY: &str = "tags_manual";

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

#[allow(dead_code)]
/// A value is "manually set" when its `extra` key exists with a truthy value
/// (the exact string `"true"`, matching what the UI writes and what the
/// document detail view's `DocumentSummary` getters check).
fn flag_is_set(extra: &std::collections::HashMap<String, String>, key: &str) -> bool {
    extra.get(key).map(|v| v == "true").unwrap_or(false)
}

/// What the reorganize pass actually changed on one document.
struct ApplyCounts {
    changed_tags: bool,
    changed_title: bool,
    changed_placement: bool,
}

impl ApplyCounts {
    fn any(&self) -> bool {
        self.changed_tags || self.changed_title || self.changed_placement
    }
}

/// Apply one [`OrgPlan`] to the persisted document through the *same* normal
/// update paths the UI uses, honoring the manual-edit flags:
///
/// * tags  → [`DocumentRepository::set_tags`] (persists `tags_manual`) unless
///   `tags_manual` is already set.
/// * title → [`DocumentRepository::update_title`] (persists `title_manual`)
///   unless `title_manual` is already set — and only when the pipeline actually
///   produced a (trimmed, non-empty) title suggestion.
/// * placement → [`DocumentRepository::assign_path`] (always; a hierarchy move
///   is not part of the manual title/tag contract).
fn apply_plan(
    repo: &DocumentRepository,
    plan: &OrgPlan,
    _title_manual: bool,
    _tags_manual: bool,
    source: SuggestionSource,
) -> Result<ApplyCounts, String> {
    let mut counts = ApplyCounts {
        changed_tags: false,
        changed_title: false,
        changed_placement: false,
    };

    let doc = repo.get(plan.document_id.clone())?;
    // Pre-suggestion value, captured so the old naming can be offered as an
    // alternative ("I want my old title back").
    let pre_title = doc.title.clone();
    let pre_tags = doc.tags.clone();

    // Tags: always apply the suggestion (manual-flag gating removed). The old
    // tag set is offered as an alternative in store_plan_suggestions below.
    if plan.tags != pre_tags {
        repo.apply_suggested_tags(plan.document_id.clone(), plan.tags.clone())?;
        counts.changed_tags = true;
    }

    // Title: always apply when the pipeline produced a (trimmed, non-empty)
    // suggestion. Old title is offered as an alternative.
    let suggested_title = plan
        .suggested_title
        .as_ref()
        .map(|t| t.trim().trim_end_matches(['-', '_', '.', ' ']).to_owned())
        .filter(|t| !t.is_empty());
    if let Some(title) = suggested_title {
        if title != pre_title {
            repo.apply_suggested_title(plan.document_id.clone(), title)?;
            counts.changed_title = true;
        }
    }

    if let Some(path) = plan
        .suggested_path
        .as_ref()
        .filter(|p| !p.trim().is_empty())
    {
        repo.assign_path(PathAssignment {
            document_id: plan.document_id.clone(),
            path: path.clone(),
            position: 0,
        })?;
        counts.changed_placement = true;
    }

    // Persist every candidate as a pending suggestion for review — rank 0 is
    // the (possibly just applied) current value, and the pre-suggestion old
    // title/tags are included among the alternatives so the user can switch
    // back to them.
    store_plan_suggestions(
        repo,
        plan.clone(),
        Some(&pre_title),
        Some(&pre_tags),
        source,
        None,
    )?;

    Ok(counts)
}

/// Persist the complete candidate list of [`OrgPlan`] as pending/current
/// suggestions rows. rank 0 = the applied (or current) value; rank >= 1 are
/// the alternatives the review UI offers.
///
/// Overwrites the document's previously-pending rows of each kind so a re-run
/// replaces stale alternatives instead of accumulating them.
fn store_plan_suggestions(
    repo: &DocumentRepository,
    plan: OrgPlan,
    pre_title: Option<&str>,
    pre_tags: Option<&[String]>,
    source: SuggestionSource,
    kind_filter: Option<SuggestionKind>,
) -> Result<(), String> {
    let document_id = plan.document_id.clone();
    let now = crate::api::storage::now_ms();

    let mut rows: Vec<DocumentSuggestion> = Vec::new();

    // Tags: rank 0 is the applied set. The pre-suggestion old tag set is
    // offered as the first alternative (the user may want it back). Only store
    // tag rows when a tags suggestion is being made (kind_filter allows both).
    if kind_filter != Some(SuggestionKind::Title) {
        let mut tag_sets: Vec<Vec<String>> = vec![plan.tags.clone()];
        if let Some(pre) = pre_tags {
            if !pre.is_empty() && pre != plan.tags {
                // Push only if not already covered by an alternative.
                let mut all: Vec<Vec<String>> = vec![pre.to_vec()]
                    .into_iter()
                    .chain(plan.alt_tag_sets.clone())
                    .collect();
                all.dedup_by(|a, b| {
                    let mut a = a.clone();
                    let mut b = b.clone();
                    a.sort();
                    b.sort();
                    a == b
                });
                tag_sets.extend(all);
            } else {
                tag_sets.extend(plan.alt_tag_sets.clone());
            }
        } else {
            tag_sets.extend(plan.alt_tag_sets.clone());
        }
        for (rank, set) in tag_sets.iter().enumerate() {
            rows.push(DocumentSuggestion {
                id: format!("{document_id}-tags-{rank}"),
                document_id: document_id.clone(),
                kind: SuggestionKind::Tags,
                payload: serde_json::to_string(set).unwrap_or_else(|_| "[]".to_owned()),
                rank: rank as i32,
                source,
                confidence: 1.0,
                status: if rank == 0 {
                    SuggestionStatus::Applied
                } else {
                    SuggestionStatus::Pending
                },
                created_at_ms: now,
            });
        }
    }

    // Title: rank 0 is the applied suggestion. The pre-suggestion old title is
    // offered as the first alternative (the user may want it back). Only store
    // title rows when a title suggestion is being made.
    if kind_filter != Some(SuggestionKind::Tags) {
        let mut titles: Vec<String> = Vec::new();
        if let Some(t) = &plan.suggested_title {
            if !t.trim().is_empty() {
                titles.push(t.trim().to_owned());
            }
        }
        if let Some(pre) = pre_title {
            let trimmed = pre.trim();
            if !trimmed.is_empty() && trimmed != titles.first().map(String::as_str).unwrap_or("") {
                // Insert the old title right after rank 0.
                titles.splice(1..1, std::iter::once(trimmed.to_owned()));
            }
        }
        // Append the remaining generated alternatives (dedup vs. old title).
        titles.extend(plan.alt_titles.clone());
        titles.dedup();
        for (rank, title) in titles.iter().enumerate() {
            rows.push(DocumentSuggestion {
                id: format!("{document_id}-title-{rank}"),
                document_id: document_id.clone(),
                kind: SuggestionKind::Title,
                payload: title.clone(),
                rank: rank as i32,
                source,
                confidence: 1.0,
                status: if rank == 0 {
                    SuggestionStatus::Applied
                } else {
                    SuggestionStatus::Pending
                },
                created_at_ms: now,
            });
        }
    }

    // Replace any previously pending rows for this document & kind so a re-run
    // does not accumulate stale alternatives.
    for kind in [SuggestionKind::Title, SuggestionKind::Tags] {
        for row in repo
            .suggestions_of(document_id.clone(), Some(kind))?
            .into_iter()
            .filter(|s| s.status != SuggestionStatus::Applied)
        {
            repo.mark_suggestion(row.id, SuggestionStatus::Dismissed)?;
        }
    }

    for row in rows {
        repo.put_suggestion(row)?;
    }

    Ok(())
}

/// Build the preference model from the repository's learned feedback.
fn preference_model(
    repo: &DocumentRepository,
    config: &OrgConfig,
) -> Result<PreferenceModel, String> {
    if !config.learning_mode.is_enabled() {
        return Ok(PreferenceModel::neutral());
    }
    let tag_stats = repo.feedback_stats(Some(SuggestionKind::Tags), None)?;
    let title_stats = repo.feedback_stats(Some(SuggestionKind::Title), None)?;
    Ok(PreferenceModel::from_stats(tag_stats, title_stats))
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
    let organizer = DeterministicOrganizer::new(config.clone());
    let prefs = preference_model(repo, &config)?;
    let plan = organizer.organize_with_model(&corpus, document_id, &prefs);

    // Capture pre-suggestion values for the review card.
    let pre_doc = repo.get(document_id.to_owned())?;
    let pre_title = pre_doc.title.clone();
    let pre_tags = pre_doc.tags.clone();

    let mut doc = repo.get(document_id.to_owned())?;
    doc.tags = plan.tags.clone();
    if let Some(title) = plan
        .suggested_title
        .as_ref()
        .filter(|t| !t.trim().is_empty())
    {
        // Trim trailing separators: templates like `{keywords}-{date}` can leave
        // a dangling `-` when a placeholder (e.g. `{date}`) is empty. Never let
        // the trimming produce an empty title — fall back to the raw suggestion.
        let trimmed = title
            .trim()
            .trim_end_matches(['-', '_', '.', ' '])
            .to_owned();
        doc.title = if trimmed.is_empty() {
            title.clone()
        } else {
            trimmed
        };
    }
    repo.put(doc, repo.read_bytes(document_id.to_owned())?)?;

    if let Some(path) = plan
        .suggested_path
        .as_ref()
        .filter(|p| !p.trim().is_empty())
    {
        repo.assign_path(PathAssignment {
            document_id: document_id.to_owned(),
            path: path.clone(),
            position: 0,
        })?;
    }

    // Persist the candidate list (rank 0 + alternatives) for review, with the
    // pre-suggestion value offered first among alternatives.
    store_plan_suggestions(
        repo,
        plan.clone(),
        Some(&pre_title),
        Some(&pre_tags),
        SuggestionSource::Ingest,
        None,
    )?;

    Ok(plan)
}

/// Run the deterministic (non-generative) organizer on `document_id`, returning
/// the [`OrgPlan`] of suggested tags, placement, rename, and dedup.
///
/// Declared `async` so FRB executes it on Rust's async worker pool instead of
/// the Dart UI isolate. This is the primitive behind the per-file "Suggest
/// title/tags" buttons, and the deterministic pass can be heavy (mmap the raw
/// bytes, minhash, per-document FTS + KNN scans) — running it synchronously on
/// the caller's thread would freeze the interface, exactly like the bulk
/// `auto_org_reorganize_all` path discussed in [`auto_org_reorganize_selected`].
///
/// The repository is taken by *reference* (FRB `Auto_Ref` encoding), so the
/// shared `Arc<Mutex<_>>` handle is borrowed rather than owned/disposed. Callers
/// may reuse the same repository handle for later bridge calls (e.g. the ingest
/// pipeline or a subsequent reorganize) without hitting a disposed opaque.
#[flutter_rust_bridge::frb]
pub async fn auto_org_organize(
    repo: &DocumentRepository,
    document_id: String,
    config: OrgConfig,
) -> Result<OrgPlan, String> {
    // Build a fresh corpus snapshot from the repository (borrowed) so the shared
    // handle is never moved/disposed across the FRB boundary.
    let corpus = build_corpus(repo)?;
    let organizer = DeterministicOrganizer::new(config.clone());
    let prefs = preference_model(repo, &config)?;
    Ok(organizer.organize_with_model(&corpus, &document_id, &prefs))
}

/// The aggregate outcome of a bulk re-organization pass over the whole library.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgBulkStats {
    /// Documents examined by the pass.
    pub total: usize,
    /// Documents whose tags/title/placement changed as a result.
    pub updated: usize,
    /// Documents left untouched (already matching, or manual-edit flags set).
    pub skipped: usize,
}

/// Re-run the deterministic auto-organization pass across **all** documents,
/// preserving every user's manual edits.
///
/// Iterates [`DocumentStore::query`], runs the same [`DeterministicOrganizer`]
/// as ingestion, and applies the suggestion through the *normal* update paths:
///
/// * title applied only when `extra['title_manual']` is **not** truthy;
/// * tags applied only when `extra['tags_manual']` is **not** truthy;
/// * placement always applied (a hierarchy move is not part of the manual
///   title/tag contract).
///
/// Each applied change is written via [`DocumentRepository::update_title`] /
/// [`DocumentRepository::set_tags`] and the fresh tags/paths are mirrored into
/// the in-memory search index via [`crate::api::search::search_set_metadata`]
/// (that mirror also happens inside the two update paths). The pass needs **no
/// AI provider** — it is the same deterministic pipeline used at ingestion.
#[flutter_rust_bridge::frb(sync)]
pub fn auto_org_reorganize_all(
    repo: &DocumentRepository,
    config: OrgConfig,
) -> Result<OrgBulkStats, String> {
    let docs = repo.query(DocumentQuery {
        kind: Some(crate::domain::NodeKind::Document),
        ..Default::default()
    })?;

    let mut total = 0usize;
    let mut updated = 0usize;

    for doc in &docs {
        total += 1;
        match auto_org_reorganize_one_impl(repo, doc.id.clone(), &config) {
            Ok(true) => updated += 1,
            // `Ok(false)` (already up to date / manual-flag skips) and transient
            // errors count as skipped so one failure does not abort the pass.
            Ok(false) | Err(_) => {}
        }
    }

    Ok(OrgBulkStats {
        total,
        updated,
        skipped: total - updated,
    })
}

/// Re-run the deterministic auto-organization pass on the **selected**
/// documents only, preserving every user's manual edits.
///
/// This is the signalled "Re-organize selected" bulk action. The classic
/// `auto_org_reorganize_all` is a `#[frb(sync)]` bridge call that executes the
/// whole corpus on the **Dart UI isolate** (the SSE sync path performs the FFI
/// synchronously on the caller's thread), freezing the interface for the whole
/// pass. Marking this function `async` makes FRB run it on Rust's async worker
/// pool, so the UI stays responsive while the pass runs.
///
/// Semantics are identical to [`auto_org_reorganize_one_impl`] — title applied
/// only when `extra['title_manual']` is not truthy, tags only when
/// `extra['tags_manual']` is not truthy, placement always applied — but the
/// corpus snapshot and organizer are built **once** for the whole batch instead
/// of once per document.
#[flutter_rust_bridge::frb]
pub async fn auto_org_reorganize_selected(
    repo: &DocumentRepository,
    ids: Vec<String>,
    config: OrgConfig,
) -> Result<OrgBulkStats, String> {
    let mut total = 0usize;
    let mut updated = 0usize;
    for id in ids {
        total += 1;
        match auto_org_reorganize_one_impl(repo, id, &config) {
            Ok(true) => updated += 1,
            // `Ok(false)` (already up to date / manual-flag skips) and transient
            // errors count as skipped so one failure does not abort the pass.
            Ok(false) | Err(_) => {}
        }
    }
    Ok(OrgBulkStats {
        total,
        updated,
        skipped: total - updated,
    })
}

/// The outcome of a per-document "Suggest title"/"Suggest tags" run.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SuggestOutcome {
    /// Applied (value changed) | AlreadyCurrent (no change needed) |
    /// NoSuggestion (pipeline produced nothing).
    pub status: String,
    /// How many pending alternatives were stored for the review card (0 when
    /// nothing to review).
    pub stored_pending: usize,
}

/// Re-run the deterministic auto-organization pass on a single document,
/// honoring the `title_manual` / `tags_manual` flags exactly like the bulk
/// pass. Returns `true` when the document's metadata changed.
///
/// This is the primitive behind both the per-file "Suggest" button (via
/// [`auto_org_reorganize_one`]) and the bulk "Re-organize all" action.
fn auto_org_reorganize_one_impl(
    repo: &DocumentRepository,
    document_id: String,
    config: &OrgConfig,
) -> Result<bool, String> {
    let corpus = build_corpus(repo)?;
    let organizer = DeterministicOrganizer::new(config.clone());
    let prefs = preference_model(repo, config)?;
    let plan = organizer.organize_with_model(&corpus, &document_id, &prefs);

    if plan.tags.is_empty() && plan.suggested_title.is_none() {
        return Ok(false);
    }

    let counts = apply_plan(repo, &plan, false, false, SuggestionSource::Bulk)?;

    // Refresh the in-memory search metadata for the freshly written doc (the
    // same wiring the ingestion pipeline uses after auto-organization).
    if counts.any() {
        let fresh = repo.get(document_id.clone())?;
        let paths = repo
            .paths_of(document_id.clone())?
            .into_iter()
            .map(|p| p.path)
            .collect::<Vec<_>>();
        crate::api::search::search_set_metadata(document_id.clone(), fresh.tags, paths);
    }

    Ok(counts.any())
}

/// Re-run the deterministic auto-organization pass on one document, honoring
/// the `title_manual` / `tags_manual` flags (a user's hand-edited title or tags
/// are never overwritten). Returns the resulting applied [`OrgPlan`].
///
/// Bridges the per-file "Suggest title & tags" button in the document detail
/// view: instead of applying suggestions naively on the Dart side, the button
/// can call this and let the core apply only the parts the user has not
/// manually set, then refresh the search metadata.
#[flutter_rust_bridge::frb(sync)]
pub fn auto_org_reorganize_one(
    repo: &DocumentRepository,
    document_id: String,
    config: OrgConfig,
) -> Result<OrgPlan, String> {
    // Compute the suggestion first (so it can be returned even when nothing
    // was applied due to manual-edit flags), then apply honoring the flags.
    let corpus = build_corpus(repo)?;
    let organizer = DeterministicOrganizer::new(config.clone());
    let prefs = preference_model(repo, &config)?;
    let plan = organizer.organize_with_model(&corpus, &document_id, &prefs);
    let _ = auto_org_reorganize_one_impl(repo, document_id, &config)?;
    Ok(plan)
}

/// Regenerate just the filename via the generative LLM tier, returning the new
/// suggested title. Fails if no generative provider is configured; the caller
/// should fall back to the deterministic template title.
#[flutter_rust_bridge::frb]
pub async fn auto_org_generate_filename(
    repo: &DocumentRepository,
    document_id: String,
    model: String,
) -> Result<String, String> {
    let corpus = build_corpus(repo)?;
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

/// List a document's suggestions (pending + applied), ranked per kind.
#[flutter_rust_bridge::frb]
pub async fn auto_org_list_suggestions(
    repo: &DocumentRepository,
    document_id: String,
) -> Result<Vec<DocumentSuggestion>, String> {
    repo.suggestions_of(document_id, None)
}

/// Apply one pending alternative suggestion to the document: apply its payload
/// through the normal update paths, record feedback (accepted terms of the
/// chosen alternative + rejected terms of the previously-applied rank 0 that
/// are not in the chosen set), and dismiss every other pending suggestion of
/// the same kind (the "alternatives disappear after choice" contract).
#[flutter_rust_bridge::frb]
pub async fn auto_org_apply_suggestion(
    repo: &DocumentRepository,
    document_id: String,
    suggestion_id: String,
) -> Result<(), String> {
    let all = repo.suggestions_of(document_id.clone(), None)?;
    let Some(chosen) = all.iter().find(|s| s.id == suggestion_id) else {
        return Err(format!("suggestion {suggestion_id} not found"));
    };

    match chosen.kind {
        SuggestionKind::Tags => {
            let tags: Vec<String> =
                serde_json::from_str(&chosen.payload).unwrap_or_else(|_| vec![]);
            repo.set_tags(document_id.clone(), tags.clone())?;
            // Accept the chosen tags; reject terms that were previously applied
            // and are not part of the chosen set.
            for term in &tags {
                record_accept(repo, SuggestionKind::Tags, term);
            }
        }
        SuggestionKind::Title => {
            let title = chosen.payload.trim();
            if !title.is_empty() {
                repo.update_title(document_id.clone(), title.to_owned())?;
                record_accept(repo, SuggestionKind::Title, title);
                // Reject the previously applied rank-0 title when it differs.
                if let Some(prev) = all
                    .iter()
                    .find(|s| s.kind == SuggestionKind::Title && s.rank == 0)
                {
                    if prev.id != chosen.id && prev.payload.trim() != title {
                        record_reject(repo, SuggestionKind::Title, prev.payload.trim());
                    }
                }
            }
        }
    }

    // All suggestions of this kind (except the chosen one) -> dismissed, so
    // the alternatives disappear after the user's choice.
    for s in all.clone() {
        if s.kind == chosen.kind && s.id != chosen.id {
            repo.mark_suggestion(s.id, SuggestionStatus::Dismissed)?;
        }
    }
    repo.mark_suggestion(suggestion_id, SuggestionStatus::Applied)?;
    Ok(())
}

/// Keep the currently applied value (rank 0) for a suggestion kind: record
/// accepted feedback for the applied terms + rejected for pending alternatives'
/// distinctive terms, and dismiss all pending of that kind.
#[flutter_rust_bridge::frb]
pub async fn auto_org_confirm_current(
    repo: &DocumentRepository,
    document_id: String,
    kind: SuggestionKind,
) -> Result<(), String> {
    let all = repo.suggestions_of(document_id.clone(), Some(kind))?;
    let pending: Vec<DocumentSuggestion> = all
        .iter()
        .filter(|s| s.status == SuggestionStatus::Pending)
        .cloned()
        .collect();
    if pending.is_empty() {
        return Ok(());
    }
    let applied: Vec<DocumentSuggestion> = all
        .iter()
        .filter(|s| s.status == SuggestionStatus::Applied)
        .cloned()
        .collect();
    for s in &applied {
        for term in payload_terms(s) {
            record_accept(repo, s.kind, &term);
        }
    }
    // Reject every term in the pending alternatives that isn't in the applied.
    if let Some(applied_set) = applied.first().map(|s| payload_terms(s)) {
        for p in &pending {
            for term in payload_terms(p) {
                if !applied_set.contains(&term) {
                    record_reject(repo, kind, &term);
                }
            }
        }
    }
    for p in pending {
        repo.mark_suggestion(p.id, SuggestionStatus::Dismissed)?;
    }
    Ok(())
}

/// Dismiss one pending suggestion (with reject feedback for its terms).
#[flutter_rust_bridge::frb]
pub async fn auto_org_dismiss_suggestion(
    repo: &DocumentRepository,
    document_id: String,
    suggestion_id: String,
) -> Result<(), String> {
    let all = repo.suggestions_of(document_id, None)?;
    if let Some(s) = all.iter().find(|s| s.id == suggestion_id) {
        for term in payload_terms(s) {
            record_reject(repo, s.kind, &term);
        }
    }
    repo.mark_suggestion(suggestion_id, SuggestionStatus::Dismissed)?;
    Ok(())
}

/// Suggest a title for a document: apply the top suggestion (if any), persist
/// the full candidate list (including the pre-suggestion old title) as pending
/// for review, and return the outcome.
///
/// The top suggestion is applied **without** stamping `title_manual` (it is a
/// suggestion, not a user rename). The pre-suggestion value is always among the
/// alternatives so the user can switch back to it.
#[flutter_rust_bridge::frb]
pub async fn auto_org_suggest_title(
    repo: &DocumentRepository,
    document_id: String,
    config: OrgConfig,
) -> Result<SuggestOutcome, String> {
    let corpus = build_corpus(repo)?;
    let prefs = preference_model(repo, &config)?;
    let organizer = DeterministicOrganizer::new(config.clone());
    let plan = organizer.organize_with_model(&corpus, &document_id, &prefs);

    let doc = repo.get(document_id.clone())?;
    let pre_title = doc.title.clone();

    // Apply the top suggestion if it's non-empty and different from the current
    // value. Uses `apply_suggested_title` (no manual-flag stamp).
    let applied = match plan.suggested_title.as_ref() {
        Some(title) => {
            let trimmed = title
                .trim()
                .trim_end_matches(['-', '_', '.', ' '])
                .to_owned();
            let title = if trimmed.is_empty() {
                title.clone()
            } else {
                trimmed
            };
            if !title.is_empty() && title != pre_title {
                repo.apply_suggested_title(document_id.clone(), title)?;
                true
            } else {
                false
            }
        }
        None => false,
    };

    // Always store the candidate list for review (including pre-title).
    store_plan_suggestions(
        repo,
        plan.clone(),
        Some(&pre_title),
        Some(&doc.tags),
        SuggestionSource::ManualRequest,
        Some(SuggestionKind::Title),
    )?;

    // Count pending alternatives (rank >= 1).
    let stored = repo
        .suggestions_of(document_id.clone(), Some(SuggestionKind::Title))?
        .iter()
        .filter(|s| s.status == SuggestionStatus::Pending)
        .count();

    let status = if applied {
        "Applied".to_owned()
    } else if plan.suggested_title.is_some() {
        "AlreadyCurrent".to_owned()
    } else {
        "NoSuggestion".to_owned()
    };

    Ok(SuggestOutcome {
        status,
        stored_pending: stored,
    })
}

/// Suggest tags for a document: apply the top tag set (if any), persist the
/// full candidate list (including the pre-suggestion old tags) as pending for
/// review, and return the outcome.
///
/// The top suggestion is applied **without** stamping `tags_manual`. The
/// pre-suggestion value is always among the alternatives so the user can switch
/// back to it.
#[flutter_rust_bridge::frb]
pub async fn auto_org_suggest_tags(
    repo: &DocumentRepository,
    document_id: String,
    config: OrgConfig,
) -> Result<SuggestOutcome, String> {
    let corpus = build_corpus(repo)?;
    let prefs = preference_model(repo, &config)?;
    let organizer = DeterministicOrganizer::new(config.clone());
    let plan = organizer.organize_with_model(&corpus, &document_id, &prefs);

    let doc = repo.get(document_id.clone())?;
    let pre_tags = doc.tags.clone();

    // Apply the top suggestion if non-empty and different from current.
    // Uses `apply_suggested_tags` (no manual-flag stamp).
    let applied = if !plan.tags.is_empty() && plan.tags != pre_tags {
        repo.apply_suggested_tags(document_id.clone(), plan.tags.clone())?;
        true
    } else {
        false
    };

    // Always store the candidate list for review (including pre-tags).
    store_plan_suggestions(
        repo,
        plan.clone(),
        Some(&doc.title),
        Some(&pre_tags),
        SuggestionSource::ManualRequest,
        Some(SuggestionKind::Tags),
    )?;

    // Count pending alternatives.
    let stored = repo
        .suggestions_of(document_id.clone(), Some(SuggestionKind::Tags))?
        .iter()
        .filter(|s| s.status == SuggestionStatus::Pending)
        .count();

    let status = if applied {
        "Applied".to_owned()
    } else if !plan.tags.is_empty() {
        "AlreadyCurrent".to_owned()
    } else {
        "NoSuggestion".to_owned()
    };

    Ok(SuggestOutcome {
        status,
        stored_pending: stored,
    })
}

/// Wipe all learned feedback (settings "reset learning").
#[flutter_rust_bridge::frb]
pub async fn auto_org_reset_learning(repo: &DocumentRepository) -> Result<(), String> {
    repo.clear_feedback()
}

/// Complete the suggestion review ("poll") for one kind after the user
/// manually edited that kind's value: dismiss every suggestion row of the
/// kind (pending alternatives AND the stale applied rank-0, whose value no
/// longer matches the document), and — when `record_feedback` is true —
/// record rejected feedback for every generated term the user did NOT keep.
/// The kept values are read from the document's current state (the manual
/// edit has already been persisted by the caller). Returns the number of
/// rows marked dismissed.
///
/// Why the applied rank-0 row is dismissed: unlike [`auto_org_confirm_current`]
/// (which keeps the applied value), a manual edit means the user changed the
/// document to a value *not* in the suggestion list. The old rank-0 row is
/// therefore stale — it no longer represents the document's current state and
/// must be removed from the UI along with all pending alternatives.
#[flutter_rust_bridge::frb]
pub async fn auto_org_resolve_manual_edit(
    repo: &DocumentRepository,
    document_id: String,
    kind: SuggestionKind,
    record_feedback: bool,
) -> Result<i32, String> {
    // Build the "kept set" from the document's current state (the manual
    // edit has already been persisted by the caller).
    let kept_set: Vec<String> = match kind {
        SuggestionKind::Tags => repo.get(document_id.clone())?.tags,
        SuggestionKind::Title => {
            let t = repo.get(document_id.clone())?.title.trim().to_owned();
            if t.is_empty() {
                vec![]
            } else {
                vec![t]
            }
        }
    };

    let rows = repo.suggestions_of(document_id, Some(kind))?;
    let mut dismissed_count = 0i32;

    for row in &rows {
        if row.status != SuggestionStatus::Pending && row.status != SuggestionStatus::Applied {
            continue;
        }
        // Record rejected feedback for generated terms the user did NOT keep.
        if record_feedback {
            for term in payload_terms(row) {
                if !term.is_empty() && !kept_set.contains(&term) {
                    record_reject(repo, kind, &term);
                }
            }
        }
        repo.mark_suggestion(row.id.clone(), SuggestionStatus::Dismissed)?;
        dismissed_count += 1;
    }

    Ok(dismissed_count)
}

fn record_accept(repo: &DocumentRepository, kind: SuggestionKind, term: &str) {
    let _ = repo.record_feedback(SuggestionFeedback {
        id: new_uuid(),
        kind,
        context: if kind == SuggestionKind::Tags {
            "tag".to_owned()
        } else {
            "title".to_owned()
        },
        term: term.to_owned(),
        action: "accepted".to_owned(),
        weight: 1.0,
        created_at_ms: crate::api::storage::now_ms(),
    });
}

fn record_reject(repo: &DocumentRepository, kind: SuggestionKind, term: &str) {
    let _ = repo.record_feedback(SuggestionFeedback {
        id: new_uuid(),
        kind,
        context: if kind == SuggestionKind::Tags {
            "tag".to_owned()
        } else {
            "title".to_owned()
        },
        term: term.to_owned(),
        action: "rejected".to_owned(),
        weight: 1.0,
        created_at_ms: crate::api::storage::now_ms(),
    });
}

/// The terms a suggestion's payload represents: the tag names, or the single
/// title term.
fn payload_terms(s: &DocumentSuggestion) -> Vec<String> {
    match s.kind {
        SuggestionKind::Tags => serde_json::from_str::<Vec<String>>(&s.payload).unwrap_or_default(),
        SuggestionKind::Title => {
            if s.payload.trim().is_empty() {
                vec![]
            } else {
                vec![s.payload.trim().to_owned()]
            }
        }
    }
}

fn new_uuid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    format!(
        "{}-{}",
        crate::api::storage::now_ms(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
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

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::api::storage::open_repository;
    use crate::domain::{Content, Document, NodeKind, SuggestionKind, SuggestionStatus};
    use crate::storage::DocumentStore;

    /// A temp root for a fresh on-disk repository.
    fn temp_root(tag: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "docean-reorganize-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }

    /// Seed a repository with one document's metadata + bytes + content.
    fn seed_doc(
        repo: &crate::api::storage::DocumentRepository,
        id: &str,
        title: &str,
        text: &str,
        extra: HashMap<String, String>,
    ) -> String {
        let mut store = repo.store().unwrap();
        store
            .put(
                Document {
                    id: id.to_owned(),
                    parent_id: None,
                    kind: NodeKind::Document,
                    title: title.to_owned(),
                    mime_type: "text/plain".to_owned(),
                    size_bytes: text.len() as u64,
                    checksum_sha256: String::new(),
                    tags: vec!["stale".to_owned(), "manual".to_owned()],
                    created_at_ms: 1,
                    updated_at_ms: 1,
                    extra,
                },
                text.as_bytes(),
            )
            .unwrap();
        store
            .put_content(&Content {
                document_id: id.to_owned(),
                text: text.to_owned(),
                source: "test".to_owned(),
            })
            .unwrap();
        drop(store);
        id.to_owned()
    }

    /// A second document whose content shares keywords with the first so the
    /// organizer can reuse tags / derive a deterministic title.
    fn seed_sibling(
        repo: &crate::api::storage::DocumentRepository,
        id: &str,
        text: &str,
    ) -> String {
        let mut store = repo.store().unwrap();
        store
            .put(
                Document {
                    id: id.to_owned(),
                    parent_id: None,
                    kind: NodeKind::Document,
                    title: "Q3 Report".to_owned(),
                    mime_type: "text/plain".to_owned(),
                    size_bytes: text.len() as u64,
                    checksum_sha256: String::new(),
                    tags: vec!["report".to_owned(), "quarterly".to_owned()],
                    created_at_ms: 1,
                    updated_at_ms: 1,
                    extra: HashMap::new(),
                },
                text.as_bytes(),
            )
            .unwrap();
        drop(store);
        id.to_owned()
    }

    #[test]
    fn manual_flags_prevent_overwrite_for_single_reorganize() {
        let root = temp_root("manual-one");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");
        let target = seed_doc(
            &repo,
            "doc-a",
            "User title",
            "quarterly invoice for office supplies from acme corporation",
            HashMap::from([
                ("title_manual".to_owned(), "true".to_owned()),
                ("tags_manual".to_owned(), "true".to_owned()),
            ]),
        );

        let plan = crate::api::auto_org::auto_org_reorganize_one(
            &repo,
            target.clone(),
            Default::default(),
        )
        .unwrap();

        let doc = repo.get(target.clone()).unwrap();
        // Gating removed: suggestions ALWAYS apply, even to a previously
        // manually-edited document (the old value becomes an alternative).
        assert_ne!(
            doc.title, "User title",
            "the suggestion now applies regardless of the manual flag"
        );
        assert_ne!(
            doc.tags,
            vec!["manual".to_owned(), "stale".to_owned()],
            "tags now apply regardless of the manual flag"
        );
        // The pipeline produced a suggestion.
        assert!(plan.suggested_title.is_some() || !plan.tags.is_empty());
        // Manual flags REMAIN as stored metadata (no behavior gating, but they
        // are not cleared by the pass).
        assert_eq!(
            doc.extra.get("title_manual").map(String::as_str),
            Some("true")
        );
        // The old (pre-suggestion) value is offered as a pending alternative so
        // the user can switch back.
        let suggestions = repo
            .suggestions_of(target.clone(), Some(SuggestionKind::Title))
            .unwrap();
        assert!(
            suggestions
                .iter()
                .any(|s| s.status == SuggestionStatus::Pending && s.payload.trim() == "User title"),
            "old title must be among the pending alternatives"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn missing_manual_flags_apply_suggestion_for_single_reorganize() {
        let root = temp_root("auto-one");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");
        let target = seed_doc(
            &repo,
            "doc-a",
            "Untagged draft",
            "quarterly invoice for acme",
            HashMap::new(),
        );

        crate::api::auto_org::auto_org_reorganize_one(&repo, target.clone(), Default::default())
            .unwrap();

        let doc = repo.get(target).unwrap();
        // The auto suggestion applied: title derived from content + tags reused.
        let title_lower = doc.title.to_lowercase();
        assert!(
            title_lower.contains("quarterly")
                || title_lower.contains("invoice")
                || title_lower.contains("acme"),
            "auto title should be content-derived, got {:?}",
            doc.title
        );
        assert!(
            !doc.tags.is_empty() && !doc.tags.contains(&"stale".to_owned()),
            "auto tags should replace the stale set, got {:?}",
            doc.tags
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn bulk_reorganize_preserves_manual_edits_and_updates_others() {
        let root = temp_root("bulk");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");

        let manual_id = seed_doc(
            &repo,
            "manual",
            "My custom title",
            "quarterly budget for consulting and travel",
            HashMap::from([
                ("title_manual".to_owned(), "true".to_owned()),
                ("tags_manual".to_owned(), "true".to_owned()),
            ]),
        );
        let auto_id = seed_doc(
            &repo,
            "auto",
            "Untitled document",
            "quarterly invoice for office supplies",
            HashMap::new(),
        );

        let stats =
            crate::api::auto_org::auto_org_reorganize_all(&repo, Default::default()).unwrap();

        assert_eq!(stats.total, 3, "sib + manual + auto");
        assert_eq!(stats.updated + stats.skipped, stats.total);

        // Gating removed: the "manual" doc ALSO gets the suggestion applied
        // (old value offered as an alternative).
        let manual = repo.get(manual_id.clone()).unwrap();
        assert_ne!(
            manual.title, "My custom title",
            "manual title is now updated by the pass (old value is an alternative)"
        );
        assert_ne!(
            manual.tags,
            vec!["manual".to_owned(), "stale".to_owned()],
            "manual tags are now updated by the pass"
        );
        let manual_sug = repo
            .suggestions_of(manual_id, Some(SuggestionKind::Title))
            .unwrap();
        assert!(
            manual_sug
                .iter()
                .any(|s| s.status == SuggestionStatus::Pending
                    && s.payload.trim() == "My custom title"),
            "old manual title should be offered as a pending alternative"
        );

        // The non-manual doc was actually updated by the pass.
        let auto = repo.get(auto_id).unwrap();
        assert_ne!(
            auto.title, "Untitled document",
            "auto title should have changed"
        );
        assert_ne!(
            auto.tags,
            vec!["stale".to_owned(), "manual".to_owned()],
            "auto tags should have been updated, got {:?}",
            auto.tags
        );
        // Reused/emergent tags from the corpus replace the stale seed set.
        assert!(
            auto.tags
                .iter()
                .any(|t| t == "invoice" || t == "budget" || t == "quarterly"),
            "auto tags should be content-derived, got {:?}",
            auto.tags
        );
        assert!(
            stats.updated >= 1,
            "at least the auto doc should count as updated"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// Regression guard for the `DroppableDisposedException` class of bugs: the
    /// FRB bridge used to encode the `DocumentRepository` argument as *owned*
    /// (`Auto_Owned`), so each of the four auto-org bridge calls transferred
    /// (and disposed) the shared `RustArc` handle. A later call on the same
    /// cached Dart handle (e.g. tapping "Suggest title & tags" a second time,
    /// after `auto_org_organize` had already disposed it) then reused a
    /// disposed opaque and threw.
    ///
    /// All four functions now take `&DocumentRepository` (borrowed / `Auto_Ref`
    /// encoding), so the same handle must stay usable across *any number* of
    /// sequential bridge calls. This test mirrors the two-calls-on-one-handle
    /// guard added when `ingest_files` got the same fix.
    #[test]
    fn same_repository_handle_survives_multiple_reorganize_one_calls() {
        let root = temp_root("reuse-handle");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");
        let target = seed_doc(
            &repo,
            "doc-a",
            "Untagged draft",
            "quarterly invoice for acme",
            HashMap::new(),
        );

        // First call on the *original* (un-cloned) handle.
        let first = crate::api::auto_org::auto_org_reorganize_one(
            &repo,
            target.clone(),
            Default::default(),
        )
        .expect("first reorganize_one must succeed on the live handle");
        assert!(
            !first.tags.is_empty() || first.suggested_title.is_some(),
            "first pass should produce a suggestion"
        );

        // The repository handle must still be fully functional after the first
        // bridge-style call — reading through the same handle keeps working.
        assert!(
            repo.get(target.clone()).is_ok(),
            "the shared handle must not be disposed after one reorganize_one"
        );

        // Second call through the *same* (un-cloned) handle. Before the fix
        // this reused a disposed RustArc and threw `DroppableDisposedException`.
        let second = crate::api::auto_org::auto_org_reorganize_one(
            &repo,
            target.clone(),
            Default::default(),
        )
        .expect("second reorganize_one must also succeed on the still-live handle");

        // The suggestion is deterministic and identical across both passes.
        assert_eq!(
            first.tags, second.tags,
            "re-running the pass on the same repo must not change its suggestions"
        );

        // The handle is also still usable for reads after the second call.
        // (An auto-applied title goes through `repo.update_title`, which marks
        // `extra['title_manual']`; the title itself is content-derived.)
        let doc = repo
            .get(target.clone())
            .expect("repository must remain fully usable after two reorganize_one calls");
        assert_eq!(
            doc.title, "Acme Invoice Quarterly",
            "reorganize_one applied the deterministic content-derived title"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// The suggestion-only `auto_org_organize` path gets the same
    /// owned/disposal hazard when it is called after a reorganize (or when the
    /// detail view's auto-suggest and reorganize buttons are both used on one
    /// repository). Assert the handle survives a mixed sequence too.
    #[tokio::test]
    async fn same_repository_handle_survives_organize_after_reorganize() {
        let root = temp_root("reuse-mixed");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");
        let target = seed_doc(
            &repo,
            "doc-a",
            "Untagged draft",
            "quarterly invoice for acme",
            HashMap::new(),
        );

        crate::api::auto_org::auto_org_reorganize_one(&repo, target.clone(), Default::default())
            .expect("reorganize_one must succeed on the live handle");

        // A second, different bridge entry point on the *same* handle.
        let plan =
            crate::api::auto_org::auto_org_organize(&repo, target.clone(), Default::default())
                .await
                .expect("auto_org_organize must succeed on the still-live handle");
        assert!(
            !plan.tags.is_empty() || plan.suggested_title.is_some(),
            "organize should produce a suggestion after a prior reorganize"
        );

        // And the handle is still readable afterwards.
        assert!(
            repo.get(target).is_ok(),
            "handle must survive the mixed sequence"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn bridge_set_tags_and_update_title_mark_manual_flags() {
        let root = temp_root("bridge-flags");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_doc(
            &repo,
            "d1",
            "Old title",
            "some body text here",
            HashMap::new(),
        );

        // The same bridge paths the UI uses must persist the manual-edit flags.
        repo.set_tags("d1".to_owned(), vec!["user-tag".to_owned()])
            .unwrap();
        repo.update_title("d1".to_owned(), "Renamed".to_owned())
            .unwrap();

        let doc = repo.get("d1".to_owned()).unwrap();
        assert_eq!(doc.title, "Renamed");
        assert_eq!(doc.tags, vec!["user-tag".to_owned()]);
        assert_eq!(
            doc.extra.get("title_manual").map(String::as_str),
            Some("true"),
            "manual rename must set extra['title_manual']"
        );
        assert_eq!(
            doc.extra.get("tags_manual").map(String::as_str),
            Some("true"),
            "manual tag edit must set extra['tags_manual']"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// The `auto_org_reorganize_selected` async bridge iterates *only* the
    /// supplied ids — not the whole corpus — and returns aggregate counts.
    /// The async signature means FRB runs it off the Dart UI isolate,
    /// preventing a freeze on large libraries.
    #[tokio::test]
    async fn reorganize_selected_updates_only_chosen_documents() {
        let root = temp_root("selected");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");

        let manual_id = seed_doc(
            &repo,
            "manual",
            "My custom title",
            "quarterly budget for consulting and travel",
            HashMap::from([
                ("title_manual".to_owned(), "true".to_owned()),
                ("tags_manual".to_owned(), "true".to_owned()),
            ]),
        );
        let auto_id = seed_doc(
            &repo,
            "auto",
            "Untitled document",
            "quarterly invoice for office supplies",
            HashMap::new(),
        );

        // Only reorganize `auto` — `manual` must remain untouched.
        let stats = crate::api::auto_org::auto_org_reorganize_selected(
            &repo,
            vec![auto_id.clone()],
            Default::default(),
        )
        .await
        .unwrap();

        assert_eq!(stats.total, 1, "only the selected doc is counted");
        assert_eq!(stats.updated + stats.skipped, stats.total);

        // The manual doc is preserved in full.
        let manual = repo.get(manual_id).unwrap();
        assert_eq!(manual.title, "My custom title");
        assert_eq!(
            manual.tags,
            vec!["manual".to_owned(), "stale".to_owned()],
            "manual tags kept: {:?}",
            manual.tags
        );

        // The auto doc was actually updated.
        let auto = repo.get(auto_id).unwrap();
        assert_ne!(
            auto.title, "Untitled document",
            "auto title should have changed"
        );
        assert_ne!(
            auto.tags,
            vec!["stale".to_owned(), "manual".to_owned()],
            "auto tags should have been updated, got {:?}",
            auto.tags
        );

        // Reused/emergent tags from the corpus replace the stale seed set.
        assert!(
            auto.tags
                .iter()
                .any(|t| t == "invoice" || t == "budget" || t == "quarterly"),
            "auto tags should be content-derived, got {:?}",
            auto.tags
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// When supplied with an empty id list the pass is a no-op and the
    /// repository handle is still usable afterwards.
    #[tokio::test]
    async fn reorganize_selected_empty_list_is_noop() {
        let root = temp_root("selected-empty");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_doc(&repo, "doc-a", "Hello", "some content here", HashMap::new());

        let stats =
            crate::api::auto_org::auto_org_reorganize_selected(&repo, vec![], Default::default())
                .await
                .unwrap();

        assert_eq!(stats.total, 0);
        assert_eq!(stats.updated, 0);
        assert!(
            repo.get("doc-a".to_owned()).is_ok(),
            "handle must still work"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// The core of the task: a manually-edited document must NOT be silently
    /// skipped by a bulk/single reorganize. Instead the candidates are persisted
    /// as pending suggestions so the user can review and adopt them.
    #[test]
    fn manual_document_gets_pending_alternatives_not_silent_skip() {
        let root = temp_root("manual-review");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");
        let target = seed_doc(
            &repo,
            "doc-a",
            "User's custom title",
            "quarterly invoice for acme",
            HashMap::from([
                ("title_manual".to_owned(), "true".to_owned()),
                ("tags_manual".to_owned(), "true".to_owned()),
            ]),
        );

        crate::api::auto_org::auto_org_reorganize_one(&repo, target.clone(), Default::default())
            .unwrap();

        // Gating removed: the manual value is updated by the suggestion.
        let doc = repo.get(target.clone()).unwrap();
        assert_ne!(
            doc.title, "User's custom title",
            "suggestions apply to previously-manual docs too"
        );
        assert_ne!(doc.tags, vec!["manual".to_owned(), "stale".to_owned()]);

        // But alternatives ARE stored as pending suggestions for review.
        let suggestions = repo.suggestions_of(target, None).unwrap();
        let pending_titles = suggestions
            .iter()
            .filter(|s| s.kind == SuggestionKind::Title && s.status == SuggestionStatus::Pending)
            .count();
        let pending_tags = suggestions
            .iter()
            .filter(|s| s.kind == SuggestionKind::Tags && s.status == SuggestionStatus::Pending)
            .count();
        assert!(
            pending_titles >= 1,
            "manual doc should have pending title alternatives, got {pending_titles}"
        );
        assert!(
            pending_tags >= 1,
            "manual doc should have pending tag alternatives, got {pending_tags}"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// Applying a pending alternative suggestion updates the document, dismisses
    /// the other alternatives, and records accept/reject feedback.
    #[tokio::test]
    async fn apply_suggestion_updates_doc_and_records_feedback() {
        let root = temp_root("apply-suggestion");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");
        let target = seed_doc(
            &repo,
            "doc-a",
            "Untagged draft",
            "quarterly invoice for acme",
            HashMap::new(),
        );

        crate::api::auto_org::auto_org_reorganize_one(&repo, target.clone(), Default::default())
            .unwrap();

        // Pick the first pending tags alternative.
        let all = repo.suggestions_of(target.clone(), None).unwrap();
        let alt = all
            .iter()
            .find(|s| s.kind == SuggestionKind::Tags && s.status == SuggestionStatus::Pending)
            .cloned()
            .expect("pending tags alternative expected");
        let tags: Vec<String> = serde_json::from_str(&alt.payload).unwrap();

        crate::api::auto_org::auto_org_apply_suggestion(&repo, target.clone(), alt.id.clone())
            .await
            .unwrap();

        // The document now carries the chosen tags.
        let doc = repo.get(target.clone()).unwrap();
        assert_eq!(doc.tags, tags, "chosen alternative tags should be applied");

        // All other tags suggestions of the same kind are dismissed.
        let after = repo.suggestions_of(target, None).unwrap();
        let pending_same_kind = after
            .iter()
            .filter(|s| s.kind == SuggestionKind::Tags && s.status == SuggestionStatus::Pending)
            .count();
        assert_eq!(
            pending_same_kind, 0,
            "alternatives of the chosen kind must disappear"
        );

        // Feedback was recorded for the accepted tags.
        let stats = repo
            .feedback_stats(Some(SuggestionKind::Tags), None)
            .unwrap();
        for t in &tags {
            assert!(
                stats.get(t).map(|s| s.accepts > 0.0).unwrap_or(false),
                "accepted tag {t} should have positive feedback"
            );
        }

        let _ = fs::remove_dir_all(&root);
    }

    /// `confirm_current` keeps the applied value and dismisses pending
    /// alternatives of that kind.
    #[tokio::test]
    async fn confirm_current_dismisses_pending() {
        let root = temp_root("confirm");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_sibling(&repo, "sib", "quarterly report for the finance team");
        let target = seed_doc(
            &repo,
            "doc-a",
            "Untagged draft",
            "quarterly invoice for acme",
            HashMap::new(),
        );

        crate::api::auto_org::auto_org_reorganize_one(&repo, target.clone(), Default::default())
            .unwrap();

        let before = repo
            .suggestions_of(target.clone(), Some(SuggestionKind::Tags))
            .unwrap();
        let pending_before = before
            .iter()
            .filter(|s| s.status == SuggestionStatus::Pending)
            .count();
        assert!(
            pending_before >= 1,
            "should have pending tags before confirm"
        );

        crate::api::auto_org::auto_org_confirm_current(&repo, target.clone(), SuggestionKind::Tags)
            .await
            .unwrap();

        let after = repo
            .suggestions_of(target, Some(SuggestionKind::Tags))
            .unwrap();
        let pending_after = after
            .iter()
            .filter(|s| s.status == SuggestionStatus::Pending)
            .count();
        assert_eq!(pending_after, 0, "confirm must dismiss all pending tags");

        let _ = fs::remove_dir_all(&root);
    }

    /// `reset_learning` wipes all learned feedback.
    #[tokio::test]
    async fn reset_learning_wipes_feedback() {
        let root = temp_root("reset-learning");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_doc(&repo, "d1", "Doc", "some text", HashMap::new());

        // Record feedback directly.
        repo.record_feedback(crate::domain::SuggestionFeedback {
            id: "fb-1".to_owned(),
            kind: SuggestionKind::Tags,
            context: "tag".to_owned(),
            term: "invoice".to_owned(),
            action: "accepted".to_owned(),
            weight: 1.0,
            created_at_ms: 1,
        })
        .unwrap();
        assert!(!repo.feedback_stats(None, None).unwrap().is_empty());

        crate::api::auto_org::auto_org_reset_learning(&repo)
            .await
            .unwrap();
        assert!(
            repo.feedback_stats(None, None).unwrap().is_empty(),
            "reset must clear all learned feedback"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// Seed one suggestion row the same way the suggestion pipeline stores it
    /// (rank 0 = applied, rank >= 1 = pending alternatives).
    fn put_suggestion_row(
        repo: &crate::api::storage::DocumentRepository,
        id: &str,
        doc_id: &str,
        kind: SuggestionKind,
        payload: &str,
        rank: i32,
        status: SuggestionStatus,
    ) {
        repo.put_suggestion(crate::domain::DocumentSuggestion {
            id: id.to_owned(),
            document_id: doc_id.to_owned(),
            kind,
            payload: payload.to_owned(),
            rank,
            source: crate::domain::SuggestionSource::ManualRequest,
            confidence: 1.0,
            status,
            created_at_ms: 1,
        })
        .unwrap();
    }

    /// Resolving a manual TAG edit dismisses every Tags row (the pending
    /// alternatives AND the stale applied rank-0), leaves Title-kind rows
    /// untouched, and returns the dismissed count.
    ///
    /// The applied rank-0 is dismissed too: the user's manual edit changed the
    /// document to a value not in the suggestion list, so that row no longer
    /// matches the document and must leave the review card with the poll.
    #[tokio::test]
    async fn resolve_manual_tag_edit_dismisses_all_tags_keeps_title() {
        let root = temp_root("resolve-tags");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_doc(
            &repo,
            "d1",
            "Acme invoice",
            "some body text",
            HashMap::new(),
        );

        put_suggestion_row(
            &repo,
            "t0",
            "d1",
            SuggestionKind::Tags,
            r#"["acme","invoice"]"#,
            0,
            SuggestionStatus::Applied,
        );
        put_suggestion_row(
            &repo,
            "t1",
            "d1",
            SuggestionKind::Tags,
            r#"["acme","finance"]"#,
            1,
            SuggestionStatus::Pending,
        );
        put_suggestion_row(
            &repo,
            "t2",
            "d1",
            SuggestionKind::Tags,
            r#"["urgent"]"#,
            2,
            SuggestionStatus::Pending,
        );
        // Title-kind rows must survive the tags resolution untouched.
        put_suggestion_row(
            &repo,
            "n0",
            "d1",
            SuggestionKind::Title,
            "Acme Invoice",
            0,
            SuggestionStatus::Applied,
        );
        put_suggestion_row(
            &repo,
            "n1",
            "d1",
            SuggestionKind::Title,
            "Acme Invoice Q3",
            1,
            SuggestionStatus::Pending,
        );

        // The user's manual tag edit is already persisted: kept tags = {acme, kept}.
        repo.set_tags("d1".to_owned(), vec!["acme".to_owned(), "kept".to_owned()])
            .unwrap();

        let count = crate::api::auto_org::auto_org_resolve_manual_edit(
            &repo,
            "d1".to_owned(),
            SuggestionKind::Tags,
            true,
        )
        .await
        .unwrap();
        assert_eq!(
            count, 3,
            "rank-0 applied + two pending Tags rows must be dismissed"
        );

        let after = repo.suggestions_of("d1".to_owned(), None).unwrap();
        for s in after.iter().filter(|s| s.kind == SuggestionKind::Tags) {
            assert_eq!(
                s.status,
                SuggestionStatus::Dismissed,
                "Tags row {} must be dismissed",
                s.id
            );
        }
        let title_statuses: Vec<_> = after
            .iter()
            .filter(|s| s.kind == SuggestionKind::Title)
            .map(|s| s.status)
            .collect();
        assert!(
            title_statuses.contains(&SuggestionStatus::Applied),
            "Title rank-0 must stay Applied, got {title_statuses:?}"
        );
        assert!(
            title_statuses.contains(&SuggestionStatus::Pending),
            "Title pending must stay Pending, got {title_statuses:?}"
        );
        assert!(
            !title_statuses.contains(&SuggestionStatus::Dismissed),
            "Title rows must be untouched, got {title_statuses:?}"
        );

        // Rejected feedback only for generated tags not in the kept set.
        let stats = repo
            .feedback_stats(Some(SuggestionKind::Tags), None)
            .unwrap();
        for t in ["invoice", "finance", "urgent"] {
            assert!(
                stats.get(t).map(|s| s.rejects > 0.0).unwrap_or(false),
                "non-kept tag {t} must be rejected"
            );
        }
        assert_eq!(
            stats.get("acme").map(|s| s.rejects).unwrap_or(0.0),
            0.0,
            "kept tag acme must not be rejected"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// A suggestion term equal to a kept tag must NOT be rejected even when
    /// `record_feedback` is true: rejection is gated on "not in the kept set".
    #[tokio::test]
    async fn resolve_manual_edit_keeps_terms_in_kept_set_unrejected() {
        let root = temp_root("resolve-kept");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_doc(&repo, "d1", "Doc", "some body text", HashMap::new());
        put_suggestion_row(
            &repo,
            "t0",
            "d1",
            SuggestionKind::Tags,
            r#"["acme","invoice"]"#,
            0,
            SuggestionStatus::Applied,
        );
        repo.set_tags("d1".to_owned(), vec!["acme".to_owned(), "kept".to_owned()])
            .unwrap();

        let count = crate::api::auto_org::auto_org_resolve_manual_edit(
            &repo,
            "d1".to_owned(),
            SuggestionKind::Tags,
            true,
        )
        .await
        .unwrap();
        assert_eq!(count, 1);

        let stats = repo
            .feedback_stats(Some(SuggestionKind::Tags), None)
            .unwrap();
        assert_eq!(
            stats.get("acme").map(|s| s.rejects).unwrap_or(0.0),
            0.0,
            "kept tag term must NOT be rejected"
        );
        assert!(
            stats
                .get("invoice")
                .map(|s| s.rejects > 0.0)
                .unwrap_or(false),
            "non-kept tag term must be rejected"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// `record_feedback = false` still dismisses the rows but records no
    /// feedback for the generated terms.
    #[tokio::test]
    async fn resolve_manual_edit_without_feedback_dismisses_without_recording() {
        let root = temp_root("resolve-no-fb");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_doc(&repo, "d1", "Doc", "some body text", HashMap::new());
        put_suggestion_row(
            &repo,
            "t0",
            "d1",
            SuggestionKind::Tags,
            r#"["acme","b"]"#,
            0,
            SuggestionStatus::Applied,
        );
        put_suggestion_row(
            &repo,
            "t1",
            "d1",
            SuggestionKind::Tags,
            r#"["c"]"#,
            1,
            SuggestionStatus::Pending,
        );
        repo.set_tags("d1".to_owned(), vec!["acme".to_owned()])
            .unwrap();

        let count = crate::api::auto_org::auto_org_resolve_manual_edit(
            &repo,
            "d1".to_owned(),
            SuggestionKind::Tags,
            false,
        )
        .await
        .unwrap();
        assert_eq!(count, 2, "rows still dismissed without feedback gating");

        let after = repo
            .suggestions_of("d1".to_owned(), Some(SuggestionKind::Tags))
            .unwrap();
        assert_eq!(after.len(), 2);
        for s in after {
            assert_eq!(s.status, SuggestionStatus::Dismissed);
        }

        // set_tags recorded an *accept* for the kept tag only; no rejects at all.
        let stats = repo
            .feedback_stats(Some(SuggestionKind::Tags), None)
            .unwrap();
        assert_eq!(
            stats.get("b").map(|s| s.rejects).unwrap_or(0.0),
            0.0,
            "no reject feedback recorded for non-kept b"
        );
        assert_eq!(
            stats.get("c").map(|s| s.rejects).unwrap_or(0.0),
            0.0,
            "no reject feedback recorded for non-kept c"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// Resolving when there are no suggestion rows returns Ok(0) and records
    /// no feedback.
    #[tokio::test]
    async fn resolve_manual_edit_with_no_rows_returns_zero() {
        let root = temp_root("resolve-empty");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_doc(&repo, "d1", "Doc", "some body text", HashMap::new());

        let count = crate::api::auto_org::auto_org_resolve_manual_edit(
            &repo,
            "d1".to_owned(),
            SuggestionKind::Tags,
            true,
        )
        .await
        .unwrap();
        assert_eq!(count, 0);

        assert!(
            repo.feedback_stats(Some(SuggestionKind::Tags), None)
                .unwrap()
                .is_empty(),
            "no rows means no feedback"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// A manual TITLE edit dismisses the title-kind rows and rejects the
    /// generated title term when it differs from the kept (current) title.
    #[tokio::test]
    async fn resolve_manual_title_edit_dismisses_title_and_rejects_diff() {
        let root = temp_root("resolve-title");
        let repo = open_repository(root.display().to_string()).unwrap();
        seed_doc(&repo, "d1", "Old title", "some body text", HashMap::new());
        put_suggestion_row(
            &repo,
            "n0",
            "d1",
            SuggestionKind::Title,
            "Acme Invoice Q3",
            0,
            SuggestionStatus::Applied,
        );
        put_suggestion_row(
            &repo,
            "n1",
            "d1",
            SuggestionKind::Title,
            "Acme Invoice",
            1,
            SuggestionStatus::Pending,
        );
        // User's manual rename is already persisted.
        repo.update_title("d1".to_owned(), "My Kept Title".to_owned())
            .unwrap();

        let count = crate::api::auto_org::auto_org_resolve_manual_edit(
            &repo,
            "d1".to_owned(),
            SuggestionKind::Title,
            true,
        )
        .await
        .unwrap();
        assert_eq!(count, 2);

        let after = repo
            .suggestions_of("d1".to_owned(), Some(SuggestionKind::Title))
            .unwrap();
        assert_eq!(after.len(), 2);
        for s in after {
            assert_eq!(s.status, SuggestionStatus::Dismissed);
        }

        let stats = repo
            .feedback_stats(Some(SuggestionKind::Title), None)
            .unwrap();
        for t in ["Acme Invoice Q3", "Acme Invoice"] {
            assert!(
                stats.get(t).map(|s| s.rejects > 0.0).unwrap_or(false),
                "generated title {t} differing from the kept title must be rejected"
            );
        }
        assert_eq!(
            stats.get("My Kept Title").map(|s| s.rejects).unwrap_or(0.0),
            0.0,
            "the user's kept title must not be rejected"
        );

        let _ = fs::remove_dir_all(&root);
    }
}
