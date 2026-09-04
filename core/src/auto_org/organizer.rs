//! The deterministic auto-organization pipeline (classic-ML first).
//!
//! Orchestrates the four steps required on ingest, entirely offline and with
//! **zero** dependency on the [`crate::ai`] layer:
//!
//! 1. **Tagging** — unsupervised: TF-IDF over the corpus, then (a) k-means
//!    clustering to surface emergent topic groups, and (b) k-NN tag reuse
//!    against already-tagged documents.
//! 2. **Placement** — deterministic: map predicted tags/topics to hierarchy
//!    paths via user-editable rules/templates.
//! 3. **Renaming** — deterministic from keywords/metadata via template.
//!    (The generative tier is a separate, opt-in module.)
//! 4. **De-duplication** — MinHash/LSH against the existing corpus.
//!
//! Beyond the single best suggestion, [`DeterministicOrganizer::organize`]
//! also produces ranked **alternatives** (`alt_tags` / `alt_titles`) so the
//! review UI in the document detail view can offer the user a few choices
//! instead of a single forced outcome. When the feedback-learning model is
//! enabled, candidates are re-ranked toward terms the user has accepted
//! before.
//!
//! The generative LLM filename tier lives in [`crate::auto_org::generative`] and
//! is called by the caller only when a provider is enabled; this module never
//! imports `crate::ai`.

use std::collections::HashMap;

use crate::auto_org::cluster::{self, vectorize_dense};
use crate::auto_org::config::{FilenameSource, OrgConfig, OrgPlan};
use crate::auto_org::feedback::PreferenceModel;
use crate::auto_org::keywords::{self, sanitize_filename};
use crate::auto_org::knn::{self, TagVote};
use crate::auto_org::minhash::{self, LshIndex, Signature};
use crate::auto_org::rules::{self, DocSignals};
use crate::auto_org::text::TfIdfModel;

/// How many title / tag-set alternatives the organizer produces at most.
const MAX_TITLE_ALTS: usize = 5;
const MAX_TAG_SET_ALTS: usize = 5;

/// One document in the corpus the organizer reasons over.
#[derive(Debug, Clone)]
pub struct CorpusDoc {
    pub id: String,
    pub title: String,
    pub text: String,
    pub mime_type: String,
    /// Existing tags (may be empty for a freshly ingested doc).
    pub tags: Vec<String>,
}

/// The in-memory corpus (all documents + their extracted text).
#[derive(Debug, Clone, Default)]
pub struct Corpus {
    pub docs: Vec<CorpusDoc>,
}

impl Corpus {
    /// Build a TF-IDF model from all documents in the corpus.
    pub fn tfidf_model(&self) -> TfIdfModel {
        TfIdfModel::fit(self.docs.iter().map(|d| (d.id.as_str(), d.text.clone())))
    }

    /// A lookup of document id → tags, for k-NN tag reuse.
    pub fn tags_by_id(&self) -> HashMap<String, Vec<String>> {
        self.docs
            .iter()
            .map(|d| (d.id.clone(), d.tags.clone()))
            .collect()
    }

    /// Build a MinHash/LSH index over the corpus (excluding `exclude`, typically
    /// the document being organized).
    pub fn lsh_index(
        &self,
        k: usize,
        exclude: Option<&str>,
    ) -> (LshIndex, HashMap<String, Signature>) {
        let mut signatures = HashMap::new();
        for d in &self.docs {
            if Some(d.id.as_str()) == exclude {
                continue;
            }
            if d.text.trim().is_empty() {
                continue;
            }
            signatures.insert(d.id.clone(), minhash::signature(&d.text, k));
        }
        let entries: Vec<(&str, &Signature)> = signatures
            .iter()
            .map(|(id, sig)| (id.as_str(), sig))
            .collect();
        (LshIndex::build(entries), signatures)
    }
}

/// An internal tag candidate (term + confidence weight) before flattening.
#[derive(Debug, Clone)]
struct TopicTag {
    term: String,
    #[allow(dead_code)]
    weight: f64,
}

impl TopicTag {
    fn tag(&self) -> String {
        self.term.clone()
    }
}

/// Extract a file extension from a MIME type or title (without the dot).
fn extension_of(mime: &str, title: &str) -> String {
    let from_mime = match mime {
        "application/pdf" => "pdf",
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "text/plain" => "txt",
        "text/markdown" => "md",
        "text/csv" => "csv",
        _ => "",
    };
    if !from_mime.is_empty() {
        return from_mime.to_owned();
    }
    title
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_owned())
        .unwrap_or_default()
}

/// The deterministic, offline, non-generative organizer.
#[derive(Debug, Clone)]
pub struct DeterministicOrganizer {
    pub config: OrgConfig,
}

impl DeterministicOrganizer {
    pub fn new(config: OrgConfig) -> Self {
        Self { config }
    }

    /// Organize the document `doc_id` within `corpus`, producing an [`OrgPlan`].
    ///
    /// Purely deterministic and synchronous; never touches the AI layer or the
    /// network. When `model` is provided (doesn't matter whether `Off` or
    /// `Basic` — the model itself is neutral when empty), alternative
    /// candidates are re-ranked by learned preferences.
    pub fn organize(&self, corpus: &Corpus, doc_id: &str) -> OrgPlan {
        self.organize_with_model(corpus, doc_id, &PreferenceModel::neutral())
    }

    /// [`Self::organize`] with an explicit preference model for re-ranking
    /// alternative candidates.
    pub fn organize_with_model(
        &self,
        corpus: &Corpus,
        doc_id: &str,
        prefs: &PreferenceModel,
    ) -> OrgPlan {
        let Some(doc) = corpus.docs.iter().find(|d| d.id == doc_id) else {
            return OrgPlan {
                document_id: doc_id.to_owned(),
                ..Default::default()
            };
        };

        let model = corpus.tfidf_model();

        // --- Step 1a: emergent tags via clustering -----------------------
        let cluster_tags = self.emergent_tags(corpus, &model);

        // --- Step 1b: tag reuse via k-NN --------------------------------
        let reused_tags = self.reused_tags(corpus, doc, &model);

        // Combine: reused (voted) tags first, then emergent cluster tags as
        // fallback, de-duplicated.
        let mut tags: Vec<String> = Vec::new();
        for t in reused_tags.iter().chain(cluster_tags.iter()) {
            if tags.len() >= 8 {
                break;
            }
            if !tags.contains(&t.tag()) {
                tags.push(t.tag());
            }
        }

        // Fallback to keyword rules when the statistical paths produced nothing
        // (e.g. the *first* document ingested into an empty corpus: clustering
        // needs >= 2 docs and k-NN needs already-tagged neighbors). Non-empty
        // tags are required by the ingestion auto-organization contract.
        if tags.is_empty() {
            let kw =
                keywords::extract_keywords(&doc.text, Some(&model), None, keywords::DEFAULT_TOP_K);
            for term in kw {
                if tags.len() >= 8 {
                    break;
                }
                if !tags.contains(&term) {
                    tags.push(term);
                }
            }
        }

        // Re-rank the rank-0 tag set by preference model (only when learning).
        let is_learning = self.config.learning_mode.is_enabled();
        let mut ranked_tags = tags
            .into_iter()
            .map(|t| {
                let score = if is_learning {
                    prefs.score(crate::domain::SuggestionKind::Tags, &t)
                } else {
                    1.0
                };
                (t, score)
            })
            .collect::<Vec<_>>();
        ranked_tags.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let tags: Vec<String> = ranked_tags.into_iter().map(|(t, _)| t).collect();

        // --- Step 3: deterministic rename via keywords ------------------
        let kw = keywords::extract_keywords(&doc.text, Some(&model), None, keywords::DEFAULT_TOP_K);
        let extension = extension_of(&doc.mime_type, &doc.title);
        let signals = DocSignals {
            tags: tags.clone(),
            keywords: kw,
            title: doc.title.clone(),
            extension,
            date: String::new(),
        };
        let template = &self.config.rules.filename_template;
        let suggested_title = sanitize_filename(&rules::render_filename(template, &signals));

        // Build alternative titles (dedup, max MAX_TITLE_ALTS).
        let alt_titles = self.alt_titles(doc, &model, &suggested_title, prefs, is_learning);

        // Build alternative tag sets (dedup, max MAX_TAG_SET_ALTS).
        let alt_tag_sets = self.alt_tag_sets(
            corpus,
            doc,
            &model,
            &cluster_tags,
            &tags,
            prefs,
            is_learning,
        );

        // --- Step 2: placement ------------------------------------------
        let suggested_path = rules::resolve_path(&self.config.rules, &signals);

        // --- Step 4: de-duplication -------------------------------------
        let (lsh, signatures) = corpus.lsh_index(self.config.shingle_k, Some(doc_id));
        let is_duplicate_of = if doc.text.trim().is_empty() {
            None
        } else {
            minhash::find_duplicate(
                &doc.text,
                self.config.shingle_k,
                self.config.dedup_threshold,
                &lsh,
                &signatures,
            )
            .map(|(id, _)| id)
        };

        OrgPlan {
            document_id: doc_id.to_owned(),
            tags,
            alt_tag_sets,
            suggested_path,
            suggested_title: Some(suggested_title),
            alt_titles,
            is_duplicate_of,
            confidence: 1.0,
            filename_source: FilenameSource::Template,
        }
    }

    /// Build ranked title alternatives (besides the rank-0 template title).
    ///
    /// Variants: `{kw1}-{kw2}`, `{kw1}-{kw2}-{kw3}`, the raw-keyword-only
    /// title, and (when learning is on) the same list re-ranked by the
    /// preference model. Deterministic; dedup'd; capped at [`MAX_TITLE_ALTS`].
    fn alt_titles(
        &self,
        doc: &CorpusDoc,
        model: &TfIdfModel,
        rank0: &str,
        prefs: &PreferenceModel,
        is_learning: bool,
    ) -> Vec<String> {
        let kw = keywords::extract_keywords(&doc.text, Some(model), None, keywords::DEFAULT_TOP_K);
        let mut candidates = Vec::new();
        if kw.len() >= 2 {
            candidates.push(format!("{}-{}", kw[0], kw[1]));
        }
        if kw.len() >= 3 {
            candidates.push(format!("{}-{}-{}", kw[0], kw[1], kw[2]));
        }
        if let Some(first) = kw.first() {
            candidates.push(first.clone());
        }
        // The rank-0 template title itself is not an "alternative", but the
        // raw cleanup of the original title is a useful fallback.
        let cleaned = sanitize_filename(doc.title.trim());
        if !cleaned.is_empty() && cleaned != rank0 && !candidates.contains(&cleaned) {
            candidates.push(cleaned);
        }

        if is_learning {
            candidates = prefs.rerank_titles(candidates);
        }
        // De-dup against rank0 and cap.
        candidates
            .into_iter()
            .filter(|c| c != rank0)
            .take(MAX_TITLE_ALTS)
            .collect()
    }

    /// Build ranked alternative tag sets (besides the rank-0 `rank0_tags`).
    fn alt_tag_sets(
        &self,
        corpus: &Corpus,
        doc: &CorpusDoc,
        model: &TfIdfModel,
        cluster_tags: &[TopicTag],
        rank0_tags: &[String],
        prefs: &PreferenceModel,
        is_learning: bool,
    ) -> Vec<Vec<String>> {
        let mut sets: Vec<Vec<String>> = Vec::new();

        // The k-NN-only set (borrowed tags only).
        let reused = self.reused_tags_and_term(corpus, doc, model);
        if !reused.is_empty() && reused != rank0_tags {
            sets.push(reused);
        }

        // The cluster-only set (emergent topics only).
        let cluster = cluster_tags.iter().map(|t| t.tag()).collect::<Vec<_>>();
        if !cluster.is_empty() && cluster != rank0_tags {
            sets.push(cluster);
        }

        // The keyword set (top keywords as tags).
        let kw = keywords::extract_keywords(&doc.text, Some(model), None, 4);
        if !kw.is_empty() && kw != rank0_tags {
            sets.push(kw);
        }

        // A conservative top-3 of the rank-0 set.
        if rank0_tags.len() > 3 {
            sets.push(rank0_tags.iter().take(3).cloned().collect::<Vec<_>>());
        }

        // De-dup exact-equal sets (order-insensitive).
        let mut seen: HashMap<Vec<String>, ()> = HashMap::new();
        sets.retain(|s| {
            let mut key = s.clone();
            key.sort();
            let first = seen.insert(key, ());
            first.is_none()
        });

        if is_learning {
            // Re-rank sets by summed preference scores (descending).
            let mut scored = sets
                .into_iter()
                .map(|s| {
                    let sum: f64 = s
                        .iter()
                        .map(|t| prefs.score(crate::domain::SuggestionKind::Tags, t))
                        .sum();
                    (s, sum)
                })
                .collect::<Vec<_>>();
            scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
            sets = scored.into_iter().map(|(s, _)| s).collect();
        }

        sets.into_iter().take(MAX_TAG_SET_ALTS).collect()
    }

    /// Like [`Self::reused_tags`] but returns the actual tag strings (not
    /// `TopicTag`s), so alternative sets stay comparable.
    fn reused_tags_and_term(&self, corpus: &Corpus, doc: &CorpusDoc, model: &TfIdfModel) -> Vec<String> {
        self.reused_tags(corpus, doc, model)
            .into_iter()
            .map(|t| t.tag())
            .collect()
    }

    /// Emergent topic tags from k-means clustering of TF-IDF vectors.
    fn emergent_tags(&self, corpus: &Corpus, model: &TfIdfModel) -> Vec<TopicTag> {
        if corpus.docs.len() < 2 {
            return Vec::new();
        }
        let mut vec_vocab: Vec<String> = model.vocabulary().cloned().collect();
        vec_vocab.sort();
        let vocab = vec_vocab;
        let vectors: Vec<cluster::Dense> = corpus
            .docs
            .iter()
            .map(|d| vectorize_dense(&model.vectorize(&d.text), &vocab))
            .collect();

        let k = if self.config.cluster_k > 0 {
            self.config.cluster_k
        } else {
            cluster::default_k(corpus.docs.len())
        };

        let Some(clusters) = cluster::kmeans(&vectors, &vocab, k, 50) else {
            return Vec::new();
        };

        let mut tags = Vec::new();
        for topic in clusters.topics(&vocab, 1) {
            for term in topic {
                if !tags.iter().any(|t: &TopicTag| t.tag() == term) {
                    tags.push(TopicTag { term, weight: 1.0 });
                }
            }
        }
        tags
    }

    /// Reused tags from k-NN against already-tagged documents.
    fn reused_tags(&self, corpus: &Corpus, doc: &CorpusDoc, model: &TfIdfModel) -> Vec<TopicTag> {
        let query = model.vectorize(&doc.text);
        if query.is_empty() {
            return Vec::new();
        }

        let candidates: Vec<(String, HashMap<String, f64>)> = corpus
            .docs
            .iter()
            .filter(|d| d.id != doc.id)
            .filter(|d| !d.tags.is_empty())
            .map(|d| (d.id.clone(), model.vectorize(&d.text)))
            .collect();

        let neighbors = knn::nearest_neighbors(&query, &candidates, 5);
        let tags_by_id = corpus.tags_by_id();
        let votes = knn::reuse_tags(&neighbors, &tags_by_id);
        votes
            .into_iter()
            .map(|TagVote { tag, weight }| TopicTag { term: tag, weight })
            .collect()
    }
}
