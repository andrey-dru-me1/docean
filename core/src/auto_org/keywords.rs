//! Deterministic keyword/entity extraction for tagging and filename templates.
//!
//! No LLM: scores terms by TF-IDF (or plain TF when no corpus is available) and
//! returns the top terms. Also provides the default keyword-rule fallback used
//! when the statistical path produces nothing (e.g. empty / near-empty text).

use std::collections::HashMap;

use crate::auto_org::text::{scripts_mismatch, term_frequencies, TfIdfModel};
use crate::domain::Document;

/// Default number of keywords to surface.
pub const DEFAULT_TOP_K: usize = 5;

/// Relative weight of content-derived (TF-IDF) terms in the title pool.
pub const CONTENT_WEIGHT: f64 = 1.0;

/// Relative weight of filename-derived terms when the filename and content
/// share a script. Content terms always outrank filename terms because a
/// content term's weight is `>= CONTENT_WEIGHT` per occurrence while a filename
/// term is at most this value.
pub const FILENAME_WEIGHT: f64 = 0.25;

/// Extra-strong down-weight applied to filename-derived terms when the
/// filename and content resolve to *different* concrete scripts. Kept strictly
/// above zero so filename tokens are never dropped from the title pool.
pub const FILENAME_SCRIPT_MISMATCH_WEIGHT: f64 = 0.01;

/// Extract the top-scoring keywords from `text`.
///
/// * `model` — optional TF-IDF model for corpus-aware weighting.
/// * `metadata` — document metadata (title/mime) that may contribute fallback
///   terms when the body text is empty.
/// * `top_k` — how many keywords to return.
pub fn extract_keywords(
    text: &str,
    model: Option<&TfIdfModel>,
    metadata: Option<&Document>,
    top_k: usize,
) -> Vec<String> {
    let mut scored: Vec<(String, f64)> = if let Some(tfidf) = model {
        weighted_terms(tfidf, text)
    } else {
        // No corpus: fall back to plain term frequency.
        term_frequencies(text).into_iter().collect()
    };

    // Add the title as a high-priority source of keywords if body is sparse.
    if scored.is_empty() {
        if let Some(doc) = metadata {
            for (term, _) in term_frequencies(&doc.title) {
                scored.push((term, f64::MAX / 2.0));
            }
        }
    }

    // Deterministic sort: weight desc, then term asc.
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    scored
        .into_iter()
        .take(top_k)
        .map(|(term, _)| term)
        .collect()
}

/// Weight terms by TF-IDF, returning `(term, weight)` pairs sorted later.
fn weighted_terms(model: &TfIdfModel, text: &str) -> Vec<(String, f64)> {
    let vec = model.vectorize(text);
    vec.into_iter().collect()
}

/// The deterministic keyword-rule fallback (also the default): produce a
/// normalized slug/title from metadata and the raw tokens present, without any
/// corpus statistics or models.
pub fn rule_fallback_keywords(doc: &Document) -> Vec<String> {
    let mut keys: Vec<String> = term_frequencies(&doc.title).into_keys().collect();
    keys.sort();
    keys
}

/// Sanitize a candidate filename: collapse whitespace, strip path separators and
/// illegal characters, and truncate.
pub fn sanitize_filename(input: &str) -> String {
    let cleaned: String = input
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\n' | '\r' | '\t' => ' ',
            _ => c,
        })
        .collect();
    let words: Vec<&str> = cleaned.split_whitespace().collect();
    let joined = words.join("_");
    let mut out = joined.trim_matches(|c| c == '.' || c == '_').to_owned();
    if out.is_empty() {
        out = "document".to_owned();
    }
    if out.chars().count() > 120 {
        out = out.chars().take(117).collect::<String>() + "...";
    }
    out
}

/// Build a weighted `(term, weight)` pool for TITLE candidates.
///
/// Content-derived (TF-IDF) terms are blended at [`CONTENT_WEIGHT`] and
/// filename-derived terms (tokenized from `filename`) at [`FILENAME_WEIGHT`] —
/// or [`FILENAME_SCRIPT_MISMATCH_WEIGHT`] when the filename and the content
/// detect to *different* concrete scripts. Filename terms are **never dropped**
/// from the pool; they are only down-weighted, so any content term (weight
/// `>= CONTENT_WEIGHT` per occurrence) always outranks every filename term.
///
/// The result is deterministically sorted (weight desc, then term asc) and
/// truncated to `top_k`.
pub fn weighted_title_terms(
    content_text: &str,
    model: Option<&TfIdfModel>,
    filename: &str,
    top_k: usize,
) -> Vec<(String, f64)> {
    let mut out: HashMap<String, f64> = HashMap::new();

    // Content: TF-IDF (or plain TF without a model).
    if let Some(model) = model {
        for (term, w) in model.vectorize(content_text) {
            *out.entry(term).or_insert(0.0) += w * CONTENT_WEIGHT;
        }
    } else {
        for (term, w) in term_frequencies(content_text) {
            *out.entry(term).or_insert(0.0) += w * CONTENT_WEIGHT;
        }
    }

    // Filename: never excluded, only down-weighted.
    let fw = if scripts_mismatch(filename, content_text) {
        FILENAME_SCRIPT_MISMATCH_WEIGHT
    } else {
        FILENAME_WEIGHT
    };
    for (term, w) in term_frequencies(filename) {
        *out.entry(term).or_insert(0.0) += w * fw;
    }

    // Deterministic order: weight desc, then term asc.
    let mut scored: Vec<(String, f64)> = out.into_iter().collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    scored.truncate(top_k);
    scored
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn doc(title: &str) -> Document {
        Document {
            id: "x".to_owned(),
            parent_id: None,
            kind: crate::domain::NodeKind::Document,
            title: title.to_owned(),
            mime_type: "text/plain".to_owned(),
            size_bytes: 0,
            checksum_sha256: String::new(),
            tags: vec![],
            created_at_ms: 0,
            updated_at_ms: 0,
            extra: HashMap::new(),
        }
    }

    #[test]
    fn extract_keywords_with_tfidf_prefers_discriminative_terms() {
        let model = TfIdfModel::fit([
            ("a", "invoice office supplies".to_owned()),
            ("b", "invoice receipt office".to_owned()),
            ("c", "chocolate cake recipe".to_owned()),
        ]);
        let kws = extract_keywords("office invoice supplies total due", Some(&model), None, 3);
        assert!(!kws.is_empty());
        assert!(kws.iter().any(|k| k == "invoice"));
    }

    #[test]
    fn extract_keywords_without_model_uses_tf() {
        let kws = extract_keywords("invoice invoice receipt", None, None, 2);
        assert_eq!(kws, vec!["invoice".to_owned(), "receipt".to_owned()]);
    }

    #[test]
    fn fallback_uses_title_tokens() {
        let d = doc("Quarterly Financial Report");
        let kws = rule_fallback_keywords(&d);
        assert!(kws.contains(&"quarterly".to_owned()));
        assert!(kws.contains(&"report".to_owned()));
    }

    #[test]
    fn sanitize_filename_strips_illegal_chars() {
        assert_eq!(
            sanitize_filename("a/b\\c:d*e?f\"g<h>i|j"),
            "a_b_c_d_e_f_g_h_i_j"
        );
        assert_eq!(sanitize_filename(""), "document");
    }

    #[test]
    fn weighted_title_terms_content_dominates() {
        // Content term "invoice" appears with weight >= 1.0, filename "doc" gets at most 0.25.
        let terms = weighted_title_terms("invoice invoice invoice", None, "doc", 5);
        // Content terms must come first.
        let pos_invoice = terms.iter().position(|(t, _)| t == "invoice").unwrap();
        let pos_doc = terms.iter().position(|(t, _)| t == "doc");
        if let Some(p) = pos_doc {
            assert!(pos_invoice < p, "content term must outrank filename term");
        }
    }

    #[test]
    fn weighted_title_terms_filename_never_dropped() {
        // Empty content → filename terms should still appear.
        let terms = weighted_title_terms("", None, "Привет документ", 5);
        let has_filename = terms.iter().any(|(t, _)| t == "привет" || t == "документ");
        assert!(has_filename, "filename tokens must not be dropped");
    }

    #[test]
    fn weighted_title_terms_script_mismatch_penalizes() {
        // Cyrillic filename + Latin content.
        let terms = weighted_title_terms("invoice report", None, "Привет документ", 10);
        // Latin content terms must outrank Cyrillic filename terms.
        let pos_invoice = terms.iter().position(|(t, _)| t == "invoice").unwrap();
        let pos_privet = terms.iter().position(|(t, _)| t == "привет");
        if let Some(p) = pos_privet {
            assert!(
                pos_invoice < p,
                "Latin content term must outrank Cyrillic filename term under mismatch"
            );
        }
    }
}
