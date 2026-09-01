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
//! The generative LLM filename tier lives in [`crate::auto_org::generative`] and
//! is called by the caller only when a provider is enabled; this module never
//! imports `crate::ai`.

use std::collections::HashMap;

use crate::auto_org::cluster::{self, vectorize_dense};
use crate::auto_org::config::{FilenameSource, OrgConfig, OrgPlan};
use crate::auto_org::keywords::{self, sanitize_filename};
use crate::auto_org::knn::{self, TagVote};
use crate::auto_org::minhash::{self, LshIndex, Signature};
use crate::auto_org::rules::{self, DocSignals};
use crate::auto_org::text::TfIdfModel;

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
    /// network.
    pub fn organize(&self, corpus: &Corpus, doc_id: &str) -> OrgPlan {
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
        for t in reused_tags.into_iter().chain(cluster_tags) {
            if tags.len() >= 8 {
                break;
            }
            if !tags.contains(&t.tag()) {
                tags.push(t.tag());
            }
        }

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
        let suggested_title = Some(sanitize_filename(&rules::render_filename(
            template, &signals,
        )));

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
            suggested_path,
            suggested_title,
            is_duplicate_of,
            confidence: 1.0,
            filename_source: FilenameSource::Template,
        }
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
