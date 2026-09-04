//! Deterministic text processing: tokenization + TF-IDF.
//!
//! Hand-rolled (no single mature Rust crate for TF-IDF/NMF), fully offline and
//! deterministic so results are reproducible across runs and testable against
//! fixed fixtures. This module has **no** dependency on the [`crate::ai`] layer.

use std::collections::{HashMap, HashSet};

/// A lightweight, deterministic token stream from a document's text.
///
/// Lowercases ASCII, splits on non-alphanumeric boundaries, and drops common
/// English stop words and very short tokens. No external tokenizer dependency.
pub struct Tokenizer;

impl Tokenizer {
    /// Split `text` into normalized tokens.
    pub fn tokenize(text: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut current = String::new();

        for ch in text.chars() {
            if ch.is_alphanumeric() {
                current.push(ch.to_ascii_lowercase());
            } else if !current.is_empty() {
                out.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() {
            out.push(current);
        }

        out.into_iter()
            .filter(|t| t.chars().count() > 1)
            .filter(|t| !STOP_WORDS.contains(&t.as_str()))
            .collect()
    }
}

/// A small built-in English stop-word list (kept inline to avoid an external
/// dependency). Not exhaustive; sufficient for topic/keyword extraction.
static STOP_WORDS: &[&str] = &[
    "the", "and", "for", "with", "that", "this", "are", "was", "were", "has", "have", "had", "not",
    "but", "from", "into", "onto", "you", "your", "they", "them", "their", "will", "would",
    "should", "could", "can", "shall", "may", "might", "must", "about", "than", "then", "these",
    "those", "been", "being", "a", "an", "of", "to", "in", "on", "at", "by", "as", "is", "it",
    "its", "be", "do", "does", "did", "done", "or", "if", "when", "where", "how", "what", "which",
    "who", "whom", "whose", "there", "here", "also", "such", "more", "most", "some", "any", "all",
    "each", "both", "our", "your", "his", "her", "its", "he", "she", "we", "i", "me", "my", "so",
    "very", "just", "only", "too",
];

/// A term-frequency map for a single document.
pub type TermFreq = HashMap<String, f64>;

/// Compute raw term frequencies for `text`.
pub fn term_frequencies(text: &str) -> TermFreq {
    let tokens = Tokenizer::tokenize(text);
    let mut freq = TermFreq::new();
    for token in tokens {
        *freq.entry(token).or_insert(0.0) += 1.0;
    }
    freq
}

/// The inverse document frequency table over a corpus: maps term &rarr; idf.
pub struct TfIdfModel {
    /// idf[term] = ln((N+1) / (df[term]+1)) + 1  (smoothed, non-negative).
    idf: HashMap<String, f64>,
    /// Number of documents the model was fit on.
    num_docs: usize,
}

impl TfIdfModel {
    /// Fit an IDF model over a corpus of already-tokenized document texts.
    ///
    /// `documents` is a slice of `(id, text)` pairs.
    pub fn fit<I, S>(documents: I) -> Self
    where
        I: IntoIterator<Item = (S, String)>,
        S: AsRef<str>,
    {
        let mut doc_freq: HashMap<String, usize> = HashMap::new();
        let mut num_docs = 0usize;

        for (_id, text) in documents {
            num_docs += 1;
            let mut seen = HashSet::new();
            for token in Tokenizer::tokenize(&text) {
                if seen.insert(token.clone()) {
                    *doc_freq.entry(token).or_insert(0) += 1;
                }
            }
        }

        let idf = doc_freq
            .into_iter()
            .map(|(term, df)| {
                let value = ((num_docs as f64 + 1.0) / (df as f64 + 1.0)).ln() + 1.0;
                (term, value)
            })
            .collect();

        TfIdfModel { idf, num_docs }
    }

    /// Number of documents used to fit the model.
    pub fn num_docs(&self) -> usize {
        self.num_docs
    }

    /// The vocabulary terms, for dimension alignment.
    pub fn vocabulary(&self) -> impl Iterator<Item = &String> {
        self.idf.keys()
    }

    /// Encode `text` into a sparse TF-IDF vector as a term &rarr; weight map.
    pub fn vectorize(&self, text: &str) -> HashMap<String, f64> {
        let tf = term_frequencies(text);
        let mut vec = HashMap::with_capacity(tf.len());
        for (term, count) in tf {
            if let Some(idf) = self.idf.get(&term) {
                vec.insert(term, count * idf);
            }
        }
        vec
    }

    /// Cosine similarity between two sparse weight vectors (over the shared
    /// vocabulary). Returns `0.0` if either vector is empty.
    pub fn cosine(a: &HashMap<String, f64>, b: &HashMap<String, f64>) -> f64 {
        // Iterate the smaller map for efficiency.
        let (small, large) = if a.len() <= b.len() { (a, b) } else { (b, a) };

        let mut dot = 0.0;
        for (term, w) in small {
            if let Some(other) = large.get(term) {
                dot += w * other;
            }
        }

        let norm_a = norm(a);
        let norm_b = norm(b);
        if norm_a == 0.0 || norm_b == 0.0 {
            return 0.0;
        }
        dot / (norm_a * norm_b)
    }
}

/// Euclidean norm of a sparse weight vector.
fn norm(vec: &HashMap<String, f64>) -> f64 {
    vec.values().map(|v| v * v).sum::<f64>().sqrt()
}

/// A coarse writing-system classifier used to decide whether a filename and a
/// document's content are likely in different scripts (which betrays a weak
/// filename-to-content correspondence worth down-weighting).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Script {
    /// Primarily Cyrillic (Cyrillic supplement/extension blocks included).
    Cyrillic,
    /// Primarily Latin / ASCII.
    Latin,
    /// No clear dominant script (mixed or neither).
    Other,
}

/// Detect the dominant script of `sample` via coarse Unicode range checks.
///
/// Counts characters in the Basic Cyrillic block (U+0400–U+04FF) and ASCII
/// letters (Latin). `Other` is returned when there is no clear dominance
/// (e.g. no letters, or a near-even mix).
pub fn detect_script(sample: &str) -> Script {
    let mut cyr = 0usize;
    let mut lat = 0usize;
    for c in sample.chars() {
        match c {
            '\u{0400}'..='\u{04FF}' => cyr += 1,
            'a'..='z' | 'A'..='Z' => lat += 1,
            _ => {}
        }
    }
    let total = cyr + lat;
    if total == 0 {
        return Script::Other;
    }
    // A clear majority of Cyrillic, or solely Cyrillic.
    if cyr * 2 >= total && cyr > lat {
        Script::Cyrillic
    } else if cyr == 0 && lat > 0 {
        Script::Latin
    } else {
        Script::Other
    }
}

/// True when `filename` and `content` resolve to different concrete scripts.
///
/// A mismatch requires *both* to detect to a concrete script (Cyrillic or
/// Latin) and for those to differ. If either side is [`Script::Other`] there
/// is no signal, so no mismatch is reported.
pub fn scripts_mismatch(filename: &str, content: &str) -> bool {
    let a = detect_script(filename);
    let b = detect_script(content);
    a != Script::Other && b != Script::Other && a != b
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-6
    }

    #[test]
    fn tokenizer_lowercases_strips_stopwords_and_punct() {
        let tokens = Tokenizer::tokenize("The Quick, Brown foxes jump OVER-the lazy dogs!");
        assert!(!tokens.contains(&"the".to_owned()));
        assert!(tokens.contains(&"over".to_owned()));
        assert!(tokens.contains(&"quick".to_owned()));
        assert!(tokens.contains(&"foxes".to_owned()));
    }

    #[test]
    fn term_frequencies_count_occurrences() {
        let tf = term_frequencies("invoice invoice receipt");
        assert_eq!(tf.get("invoice"), Some(&2.0));
        assert_eq!(tf.get("receipt"), Some(&1.0));
    }

    #[test]
    fn tfidf_similar_docs_are_closer_than_different() {
        let docs = vec![
            ("d1", "invoice for office supplies".to_owned()),
            ("d2", "office supplies invoice total due".to_owned()),
            ("d3", "recipe for chocolate cake".to_owned()),
        ];
        let model = TfIdfModel::fit(docs);

        let a = model.vectorize("invoice for office supplies");
        let b = model.vectorize("office supplies invoice total due");
        let c = model.vectorize("recipe for chocolate cake");

        assert!(TfIdfModel::cosine(&a, &b) > TfIdfModel::cosine(&a, &c));
    }

    #[test]
    fn cosine_is_zero_for_empty_vectors() {
        let a: HashMap<String, f64> = HashMap::new();
        let b: HashMap<String, f64> = HashMap::new();
        assert!(approx(TfIdfModel::cosine(&a, &b), 0.0));
    }

    #[test]
    fn detect_script_cyrillic() {
        assert_eq!(detect_script("Привет мир"), Script::Cyrillic);
        assert_eq!(detect_script("Документ"), Script::Cyrillic);
    }

    #[test]
    fn detect_script_latin() {
        assert_eq!(detect_script("Hello world"), Script::Latin);
        assert_eq!(detect_script("Invoice 2026"), Script::Latin);
    }

    #[test]
    fn detect_script_other() {
        assert_eq!(detect_script("12345"), Script::Other);
        assert_eq!(detect_script(""), Script::Other);
        assert_eq!(detect_script("αβγ"), Script::Other); // Greek not handled
    }

    #[test]
    fn scripts_mismatch_cyrillic_vs_latin() {
        assert!(scripts_mismatch("Привет", "Hello"));
        assert!(!scripts_mismatch("Привет", "Привет"));
        assert!(!scripts_mismatch("Hello", "Hello"));
        // Other does not trigger mismatch
        assert!(!scripts_mismatch("Привет", "123"));
        assert!(!scripts_mismatch("Hello", "123"));
    }
}
