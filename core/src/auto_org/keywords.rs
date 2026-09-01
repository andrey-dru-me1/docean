//! Deterministic keyword/entity extraction for tagging and filename templates.
//!
//! No LLM: scores terms by TF-IDF (or plain TF when no corpus is available) and
//! returns the top terms. Also provides the default keyword-rule fallback used
//! when the statistical path produces nothing (e.g. empty / near-empty text).

use crate::auto_org::text::{term_frequencies, TfIdfModel};
use crate::domain::Document;

/// Default number of keywords to surface.
pub const DEFAULT_TOP_K: usize = 5;

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
}
