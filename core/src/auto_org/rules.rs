//! User-editable filename templates.
//!
//! (Placement rules and hierarchy-path fallbacks were removed: folder layout
//! is derived from tags by the library mirror, not from a logical path table.)

use serde::{Deserialize, Serialize};

/// The template configuration used when generating filenames.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleSet {
    /// Supported placeholders: `{keywords}`, `{tags}`, `{title}`, `{date}`, `{ext}`.
    pub filename_template: String,
}

impl RuleSet {
    pub fn default_template() -> String {
        "{keywords}-{date}".to_owned()
    }
}

/// The document signals available to templates.
#[derive(Debug, Clone, Default)]
pub struct DocSignals {
    pub tags: Vec<String>,
    pub keywords: Vec<String>,
    pub title: String,
    pub extension: String,
    pub date: String,
}

/// Render the filename template with the document signals.
pub fn render_filename(template: &str, signals: &DocSignals) -> String {
    let keywords = join_top(&signals.keywords, 3, "-");
    let tags = join_top(&signals.tags, 3, "-");

    let mut out = template
        .replace("{keywords}", &keywords)
        .replace("{tags}", &tags)
        .replace("{title}", &signals.title)
        .replace("{date}", &signals.date)
        .replace("{ext}", &signals.extension);

    if out.is_empty() {
        out = "document".to_owned();
    }
    out
}

fn join_top(items: &[String], n: usize, sep: &str) -> String {
    items.iter().take(n).cloned().collect::<Vec<_>>().join(sep)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signals() -> DocSignals {
        DocSignals {
            tags: vec!["invoice".to_owned(), "receipt".to_owned()],
            keywords: vec!["invoice".to_owned(), "acme".to_owned(), "2026".to_owned()],
            title: "Acme Invoice Q1".to_owned(),
            extension: "pdf".to_owned(),
            date: "2026-09-01".to_owned(),
        }
    }

    #[test]
    fn render_filename_substitutes_placeholders() {
        assert_eq!(
            render_filename("{keywords}-{date}.{ext}", &signals()),
            "invoice-acme-2026-2026-09-01.pdf"
        );
        assert_eq!(render_filename("{tags}", &signals()), "invoice-receipt");
    }
}
