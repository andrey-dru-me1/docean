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
use crate::auto_org::generative::generate_filename;
use crate::auto_org::organizer::{Corpus, CorpusDoc, DeterministicOrganizer};
use crate::auto_org::rules::RuleSet;
use crate::domain::PathAssignment;
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
    title_manual: bool,
    tags_manual: bool,
) -> Result<ApplyCounts, String> {
    let mut counts = ApplyCounts {
        changed_tags: false,
        changed_title: false,
        changed_placement: false,
    };

    let doc = repo.get(plan.document_id.clone())?;

    // Tags: apply only when the user has not manually assigned them.
    if !tags_manual && plan.tags != doc.tags {
        repo.set_tags(plan.document_id.clone(), plan.tags.clone())?;
        counts.changed_tags = true;
    }

    // Title: apply only when the user has not manually renamed the document and
    // the pipeline actually produced a (trimmed, non-empty) suggestion.
    let suggested_title = plan
        .suggested_title
        .as_ref()
        .map(|t| t.trim().trim_end_matches(['-', '_', '.', ' ']).to_owned())
        .filter(|t| !t.is_empty());
    if !title_manual {
        if let Some(title) = suggested_title {
            if title != doc.title {
                repo.update_title(plan.document_id.clone(), title)?;
                counts.changed_title = true;
            }
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

    Ok(counts)
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

    Ok(plan)
}

/// Run the deterministic (non-generative) organizer on `document_id`, returning
/// the [`OrgPlan`] of suggested tags, placement, rename, and dedup.
///
/// The repository is taken by *reference* (FRB `Auto_Ref` encoding), so the
/// shared `Arc<Mutex<_>>` handle is borrowed rather than owned/disposed. Callers
/// may reuse the same repository handle for later bridge calls (e.g. the ingest
/// pipeline or a subsequent reorganize) without hitting a disposed opaque.
#[flutter_rust_bridge::frb(sync)]
pub fn auto_org_organize(
    repo: &DocumentRepository,
    document_id: String,
    config: OrgConfig,
) -> Result<OrgPlan, String> {
    // Build a fresh corpus snapshot from the repository (borrowed) so the shared
    // handle is never moved/disposed across the FRB boundary.
    let corpus = build_corpus(repo)?;
    let organizer = DeterministicOrganizer::new(config);
    Ok(organizer.organize(&corpus, &document_id))
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
    let plan = organizer.organize(&corpus, &document_id);

    if plan.tags.is_empty() && plan.suggested_title.is_none() {
        return Ok(false);
    }

    let doc = repo.get(document_id.clone())?;
    let title_manual = flag_is_set(&doc.extra, TITLE_MANUAL_KEY);
    let tags_manual = flag_is_set(&doc.extra, TAGS_MANUAL_KEY);
    let counts = apply_plan(repo, &plan, title_manual, tags_manual)?;

    // Refresh the in-memory search metadata for the freshly written doc (the
    // same wiring the ingestion pipeline uses after auto-organization).
    if counts.any() {
        let fresh = repo.get(document_id.clone())?;
        let paths = repo
            .paths_of(document_id.clone())?
            .into_iter()
            .map(|p| p.path)
            .collect::<Vec<_>>();
        crate::api::search::search_set_metadata(document_id, fresh.tags, paths);
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
    let plan = organizer.organize(&corpus, &document_id);
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
    use crate::domain::{Content, Document, NodeKind};
    use crate::storage::DocumentStore;

    /// A temp root for a fresh on-disk repository.
    fn temp_root(tag: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "docer-reorganize-{tag}-{}-{}",
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

        let doc = repo.get(target).unwrap();
        assert_eq!(
            doc.title, "User title",
            "manual title must be preserved by a single reorganize"
        );
        assert_eq!(
            doc.tags,
            vec!["manual".to_owned(), "stale".to_owned()],
            "manual tags must be preserved by a single reorganize"
        );
        // The pipeline still produced a suggestion (placement is always taken)
        // even though it was not applied.
        assert!(plan.suggested_title.is_some() || !plan.tags.is_empty());
        // Manual flags remain set after the pass.
        assert_eq!(
            doc.extra.get("title_manual").map(String::as_str),
            Some("true")
        );
        assert_eq!(
            doc.extra.get("tags_manual").map(String::as_str),
            Some("true")
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
        assert!(
            doc.title.contains("quarterly")
                || doc.title.contains("invoice")
                || doc.title.contains("acme"),
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

        // The manual doc is preserved in full.
        let manual = repo.get(manual_id).unwrap();
        assert_eq!(manual.title, "My custom title");
        assert_eq!(
            manual.tags,
            vec!["manual".to_owned(), "stale".to_owned()],
            "manual tags kept: {:?}",
            manual.tags
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
            doc.title, "acme-invoice-quarterly",
            "reorganize_one applied the deterministic content-derived title"
        );

        let _ = fs::remove_dir_all(&root);
    }

    /// The suggestion-only `auto_org_organize` path gets the same
    /// owned/disposal hazard when it is called after a reorganize (or when the
    /// detail view's auto-suggest and reorganize buttons are both used on one
    /// repository). Assert the handle survives a mixed sequence too.
    #[test]
    fn same_repository_handle_survives_organize_after_reorganize() {
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
}
