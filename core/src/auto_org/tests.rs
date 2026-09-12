//! End-to-end tests for the auto-organization pipeline, driven by a fixed
//! deterministic fixture corpus and a mock generative provider.
//!
//! These verify orchestration: tagging (emergent + reused), deterministic
//! rename, deduplication, and the opt-in generative tier.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use crate::ai::{
    AiProvider, CompletionResponse, EmbedRequest, EmbedResponse, GenerateRequest, Usage,
};
use crate::auto_org::config::{FilenameSource, OrgConfig, OrgPlan};
use crate::auto_org::generative::{apply_generated, generate_filename};
use crate::auto_org::organizer::{Corpus, CorpusDoc, DeterministicOrganizer};
use crate::auto_org::rules::RuleSet;

/// The deterministic fixture corpus: two finance docs + a recipe doc.
fn fixture_corpus() -> Corpus {
    Corpus {
        docs: vec![
            CorpusDoc {
                id: "inv-1".to_owned(),
                title: "Acme Invoice January".to_owned(),
                text: "invoice payable to acme corporation for office supplies total due"
                    .to_owned(),
                mime_type: "application/pdf".to_owned(),
                tags: vec!["invoice".to_owned(), "finance".to_owned()],
            },
            CorpusDoc {
                id: "inv-2".to_owned(),
                title: "Globex Invoice February".to_owned(),
                text: "invoice receivable from globex for consulting services amount owed"
                    .to_owned(),
                mime_type: "application/pdf".to_owned(),
                tags: vec!["invoice".to_owned()],
            },
            CorpusDoc {
                id: "recipe-1".to_owned(),
                title: "Chocolate Cake Recipe".to_owned(),
                text: "recipe for chocolate cake with buttercream frosting and cocoa powder"
                    .to_owned(),
                mime_type: "text/markdown".to_owned(),
                tags: vec!["recipe".to_owned(), "dessert".to_owned()],
            },
        ],
    }
}

/// A corpus with a near-duplicate of `inv-1` to exercise the dedup path.
fn fixture_with_duplicate() -> Corpus {
    let mut corpus = fixture_corpus();
    corpus.docs.push(CorpusDoc {
        id: "inv-1-copy".to_owned(),
        title: "Acme Invoice January (copy)".to_owned(),
        text: "invoice payable to acme corporation for office supplies total due".to_owned(),
        mime_type: "application/pdf".to_owned(),
        tags: vec![],
    });
    corpus
}

#[test]
fn organize_reuses_tags_from_corpus() {
    let config = OrgConfig {
        rules: RuleSet {
            filename_template: "{keywords}-{date}.{ext}".to_owned(),
        },
        ..Default::default()
    };
    let organizer = DeterministicOrganizer::new(config);

    let mut corpus = fixture_corpus();
    corpus.docs.push(CorpusDoc {
        id: "inv-3".to_owned(),
        title: "Stark Invoice March".to_owned(),
        text: "invoice payable to stark industries for office supplies".to_owned(),
        mime_type: "application/pdf".to_owned(),
        tags: vec![],
    });

    let plan = organizer.organize(&corpus, "inv-3");

    assert!(
        plan.tags.contains(&"invoice".to_owned()),
        "tags: {:?}",
        plan.tags
    );
    assert_eq!(plan.filename_source, FilenameSource::Template);
    let title = plan.suggested_title.as_deref().unwrap();
    let title_lower = title.to_lowercase();
    assert!(
        title_lower.contains("invoice")
            || title_lower.contains("stark")
            || title_lower.contains("office"),
        "title should be content-derived, got {title:?}"
    );
    assert!(
        !title.contains('-') && !title.contains('_'),
        "title must be space-joined (no '-' or '_'), got {title:?}"
    );
    assert!(plan.is_duplicate_of.is_none());
}

#[test]
fn organize_is_deterministic_across_runs() {
    let organizer = DeterministicOrganizer::new(OrgConfig::default());
    let mut corpus = fixture_corpus();
    corpus.docs.push(CorpusDoc {
        id: "x".to_owned(),
        title: "misc".to_owned(),
        text: "some novel content about gardening and plants".to_owned(),
        mime_type: "text/plain".to_owned(),
        tags: vec![],
    });

    let a: OrgPlan = organizer.organize(&corpus, "x");
    let b = organizer.organize(&corpus, "x");
    assert_eq!(a.tags, b.tags);
    assert_eq!(a.suggested_title, b.suggested_title);
    assert_eq!(a.is_duplicate_of, b.is_duplicate_of);
}

#[test]
fn organize_flags_near_duplicate() {
    let organizer = DeterministicOrganizer::new(OrgConfig {
        dedup_threshold: 0.7,
        ..Default::default()
    });
    let corpus = fixture_with_duplicate();

    let plan = organizer.organize(&corpus, "inv-1-copy");
    assert_eq!(plan.is_duplicate_of.as_deref(), Some("inv-1"));

    // A genuinely distinct document is not flagged, even in a corpus with dupes.
    let plan = organizer.organize(&corpus, "recipe-1");
    assert!(plan.is_duplicate_of.is_none());
}

#[test]
fn missing_document_yields_default_plan() {
    let organizer = DeterministicOrganizer::new(OrgConfig::default());
    let corpus = fixture_corpus();
    let plan = organizer.organize(&corpus, "nope");
    assert_eq!(plan.document_id, "nope");
    assert!(plan.tags.is_empty());
    assert!(plan.suggested_title.is_none());
}

// --- Generative filename tier (mock provider) -----------------------------

/// A deterministic mock provider that emits a fixed filename.
struct MockFilenameProvider {
    calls: Arc<AtomicUsize>,
}

impl AiProvider for MockFilenameProvider {
    fn name(&self) -> &'static str {
        "mock-filename"
    }

    async fn complete(
        &self,
        _req: &crate::ai::CompletionRequest,
    ) -> anyhow::Result<CompletionResponse> {
        unimplemented!("not exercised by generate_filename")
    }

    async fn generate(&self, _req: &GenerateRequest) -> anyhow::Result<CompletionResponse> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(CompletionResponse {
            content: "acme supplier invoice".to_owned(),
            usage: Some(Usage {
                prompt_tokens: 4,
                completion_tokens: 3,
            }),
        })
    }

    async fn classify(
        &self,
        _req: &crate::ai::ClassifyRequest,
    ) -> anyhow::Result<crate::ai::ClassifyResponse> {
        unimplemented!("not exercised by generate_filename")
    }

    async fn embed(&self, _req: &EmbedRequest) -> anyhow::Result<EmbedResponse> {
        unimplemented!("not exercised by generate_filename")
    }
}

#[test]
fn generative_filename_tier_uses_provider_and_marks_source() {
    let calls = Arc::new(AtomicUsize::new(0));
    let provider = crate::ai::erase(MockFilenameProvider {
        calls: calls.clone(),
    });
    let doc = CorpusDoc {
        id: "inv-1".to_owned(),
        title: "Acme Invoice January".to_owned(),
        text: "invoice payable to acme corporation".to_owned(),
        mime_type: "application/pdf".to_owned(),
        tags: vec![],
    };

    let filename = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(generate_filename(&provider, "docean-tiny", &doc))
        .unwrap();
    assert_eq!(filename, "acme_supplier_invoice");
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let mut plan = OrgPlan::default();
    apply_generated(&mut plan, filename);
    assert_eq!(plan.filename_source, FilenameSource::Generative);
    assert_eq!(
        plan.suggested_title.as_deref(),
        Some("acme_supplier_invoice")
    );
}

#[test]
fn suggested_title_uses_spaces_only() {
    let organizer = DeterministicOrganizer::new(OrgConfig::default());
    let mut corpus = fixture_corpus();
    corpus.docs.push(CorpusDoc {
        id: "doc-x".to_owned(),
        title: "Some Title".to_owned(),
        text: "invoice for acme corporation quarterly report".to_owned(),
        mime_type: "text/plain".to_owned(),
        tags: vec![],
    });
    let plan = organizer.organize(&corpus, "doc-x");
    let title = plan.suggested_title.as_deref().unwrap();
    assert!(
        !title.contains('-') && !title.contains('_'),
        "title must be space-joined, got {title:?}"
    );
    // Alt titles must also be space-joined.
    for alt in &plan.alt_titles {
        assert!(
            !alt.contains('-') && !alt.contains('_'),
            "alt title must be space-joined, got {alt:?}"
        );
    }
}

#[test]
fn cyrillic_filename_latin_content_title_from_content() {
    let organizer = DeterministicOrganizer::new(OrgConfig::default());
    let mut corpus = fixture_corpus();
    corpus.docs.push(CorpusDoc {
        id: "doc-cyr".to_owned(),
        title: "Привет Документ".to_owned(), // Cyrillic filename
        text: "invoice report quarterly".to_owned(), // Latin content
        mime_type: "text/plain".to_owned(),
        tags: vec![],
    });
    let plan = organizer.organize(&corpus, "doc-cyr");
    let title = plan.suggested_title.as_deref().unwrap();
    let title_lower = title.to_lowercase();
    // Rank-0 title must be built from content (Latin) tokens.
    assert!(
        title_lower.contains("invoice")
            || title_lower.contains("report")
            || title_lower.contains("quarterly"),
        "title should be built from Latin content tokens, got {title:?}"
    );
    // Cyrillic filename tokens must NOT appear at rank 0 when content tokens exist.
    assert!(
        !title.contains("привет") && !title.contains("документ"),
        "Cyrillic filename tokens must not appear at rank 0, got {title:?}"
    );
}

#[test]
fn symmetric_latin_filename_cyrillic_content_title_from_content() {
    let organizer = DeterministicOrganizer::new(OrgConfig::default());
    let mut corpus = fixture_corpus();
    corpus.docs.push(CorpusDoc {
        id: "doc-lat".to_owned(),
        title: "Invoice Document".to_owned(), // Latin filename
        text: "Привет мир отчёт".to_owned(),  // Cyrillic content
        mime_type: "text/plain".to_owned(),
        tags: vec![],
    });
    let plan = organizer.organize(&corpus, "doc-lat");
    let title = plan.suggested_title.as_deref().unwrap();
    let title_lower = title.to_lowercase();
    // Rank-0 title must be built from Cyrillic content tokens.
    assert!(
        title_lower.contains("привет")
            || title_lower.contains("мир")
            || title_lower.contains("отчёт"),
        "title should be built from Cyrillic content tokens, got {title:?}"
    );
}

#[test]
fn filename_template_behavior_unchanged() {
    // The filename render (rules::render_filename) still uses `-`.
    use crate::auto_org::rules::{self, DocSignals, RuleSet};
    let signals = DocSignals {
        tags: vec![],
        keywords: vec!["invoice".to_owned(), "acme".to_owned()],
        title: "Acme Invoice".to_owned(),
        extension: "pdf".to_owned(),
        date: "2026-09-01".to_owned(),
    };
    let template = RuleSet::default_template();
    let filename = rules::render_filename(&template, &signals);
    assert!(
        filename.contains('-'),
        "filename render still uses '-', got {filename:?}"
    );
}

#[test]
fn determinism_same_corpus_same_output() {
    let organizer = DeterministicOrganizer::new(OrgConfig::default());
    let mut corpus = fixture_corpus();
    corpus.docs.push(CorpusDoc {
        id: "det".to_owned(),
        title: "Det".to_owned(),
        text: "invoice for acme corporation".to_owned(),
        mime_type: "text/plain".to_owned(),
        tags: vec![],
    });
    let a = organizer.organize(&corpus, "det");
    let b = organizer.organize(&corpus, "det");
    assert_eq!(a.suggested_title, b.suggested_title);
    assert_eq!(a.alt_titles, b.alt_titles);
    assert_eq!(a.tags, b.tags);
}
